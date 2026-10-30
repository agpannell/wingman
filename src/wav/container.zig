//! WAVE form admission and RF64 replacement sizes over shared RIFF framing. Views borrow source;
//! each active RF64 pass reserves an exclusive byte-aligned index. Small directories scan directly;
//! larger directories sort lazily by ID and authored ordinal, preserving repeated-ID consumption.

const std = @import("std");
const riff = @import("../riff.zig");
const memory = @import("storage.zig");

/// Malformed headers, directories, chunk extents, padding, or sentinel reuse.
pub const ParseError = error{ InvalidWave, InsufficientScratch, Aliasing };

/// Caller-owned state for one RF64 directory record. Reserve at least `scratchCount()` entries. The
/// iterator manages their contents. Keep them disjoint from source bytes and exclusive to one
/// active traversal. Treat the fields as private iterator state. Byte alignment keeps the complete
/// scratch reservation reclaimable in byte-backed allocators.
pub const ChunkIndexEntry = extern struct {
    /// Encoded directory ordinal used by indexed lookup.
    table_index: u32 align(1),
    /// Consumption flag or matching-group cursor, managed by the iterator.
    next_match: u32 align(1),
};

/// RF64 directory values; `table` borrows complete twelve-byte directory records.
pub const Rf64Sizes = struct {
    /// Replacement container length minus eight, used only when the outer u32 size is a sentinel.
    riff_size: u64,
    /// Replacement length for the single sentinel-sized `data` chunk.
    data_size: u64,
    /// Decoded frame count used by root admission when an ADPCM fact count is a sentinel.
    sample_count: u64,
    /// Borrowed twelve-byte records: four ID bytes followed by a little-endian u64 length.
    table: []const u8,
};

/// Header-admitted container. Keep the complete source unchanged while borrowed.
pub const Container = struct {
    /// Complete borrowed container, including the outer header and word padding.
    source: []const u8,
    /// First traversed chunk offset; RF64 traversal begins after its required `ds64`.
    chunks_start: usize,
    /// Validated borrowed RF64 directory, or null for RIFF.
    rf64_sizes: ?Rf64Sizes,

    /// RF64 directory entries required by each active pass; RIFF needs none. The separate sentinel
    /// data size uses no table entry. This count does not admit later chunk contents.
    pub fn scratchCount(self: Container) usize {
        return if (self.rf64_sizes) |sizes| sizes.table.len / 12 else 0;
    }

    /// Starts an exclusive traversal using at least scratchCount() entries. Capacity/overlap
    /// failures precede clearing. Extra entries are untouched. Retire the pass before reusing its
    /// used scratch; copying an active iterator does not create independent state.
    pub fn iterator(self: Container, directory_index: []ChunkIndexEntry) ParseError!ChunkIterator {
        const count = self.scratchCount();
        if (directory_index.len < count) return error.InsufficientScratch;
        const scratch = directory_index[0..count];
        if (memory.overlaps(self.source, std.mem.sliceAsBytes(scratch))) return error.Aliasing;
        if (count <= 32) @memset(scratch, .{ .table_index = 0, .next_match = 0 });
        return .{ .view = self, .offset = self.chunks_start, .directory_index = scratch };
    }
};

/// Validates the outer size and mandatory first RF64 directory without allocation. Later chunk
/// boundaries remain fallible during iterator traversal. The source must contain exactly one
/// container, without trailing bytes.
pub fn parse(source: []const u8) ParseError!Container {
    if (source.len < 12 or (!std.mem.eql(
        u8,
        source[0..4],
        "RIFF",
    ) and !std.mem.eql(u8, source[0..4], "RF64")) or !std.mem.eql(u8, source[8..12], "WAVE")) {
        return error.InvalidWave;
    }
    const is_rf64 = std.mem.eql(u8, source[0..4], "RF64");
    if (!is_rf64) {
        const outer = riff.parse(source) catch return error.InvalidWave;
        if (outer.source.len != source.len) return error.InvalidWave;
    }
    var rf64_sizes: ?Rf64Sizes = null;
    var offset: usize = 12;
    if (is_rf64) rf64_sizes = try parseRf64Sizes(source, &offset);
    const chunks_start = offset;

    const expected_riff_size = std.math.cast(u64, source.len - 8) orelse return error.InvalidWave;
    const riff_size_field = readU32(source, 4);
    // RF64 applies the same sentinel rule to the outer length, data length and fact count. An
    // explicit u32 length takes precedence over its otherwise unused ds64 replacement.
    const riff_size: u64 = if (riff_size_field == std.math.maxInt(
        u32,
    )) if (rf64_sizes) |sizes| sizes.riff_size else return error.InvalidWave else riff_size_field;
    if (riff_size != expected_riff_size) return error.InvalidWave;

    return .{ .source = source, .chunks_start = chunks_start, .rf64_sizes = rf64_sizes };
}

/// One mutable traversal borrowing its Container's source and the caller's scratch. Construct with
/// `Container.iterator`; copying an active iterator shares its scratch and does not create an
/// independent traversal.
pub const ChunkIterator = struct {
    /// Borrowed header-admitted container used by this pass.
    view: Container,
    /// Current chunk offset, advanced only after a successful `next` call.
    offset: usize,
    /// Mutable directory state reserved exclusively for this iterator's active lifetime.
    directory_index: []ChunkIndexEntry,
    /// Tracks consumption of the directory's one sentinel data size.
    used_rf64_data_size: bool = false,
    /// Whether the large-directory scratch has been ordered for lookup.
    directory_index_ready: bool = false,

    /// Returns the next bounded payload, or null at the complete container end. Failure ends this
    /// traversal; start a fresh iterator before retrying. Payloads continue to borrow the source
    /// after the iterator advances or retires.
    pub fn next(self: *ChunkIterator) ParseError!?riff.Chunk {
        if (self.offset == self.view.source.len) return null;
        const chunk = try nextChunk(self);
        self.offset = chunk.next_offset;
        return .{ .id = chunk.id, .data = chunk.data, .padding = chunk.padding };
    }

    /// Reports consumption of an encoded RF64 directory ordinal, or null when out of range.
    /// Ordinary chunk sizes and the separate data-size field do not consume table entries. This
    /// iterator and its exclusive scratch must remain alive and unchanged by another pass. The
    /// query allocates nothing and does not advance traversal.
    pub fn tableEntryUsed(self: *const ChunkIterator, ordinal: usize) ?bool {
        if (ordinal >= self.directory_index.len) return null;
        if (self.directory_index.len <= 32) {
            return self.directory_index[ordinal].next_match != 0;
        }
        if (!self.directory_index_ready) return false;
        const sizes = self.view.rf64_sizes orelse return null;
        const key = readU32(sizes.table, ordinal * 12);
        const first = lowerBoundDirectory(sizes.table, self.directory_index, key, 0);
        const position = lowerBoundDirectory(
            sizes.table,
            self.directory_index,
            key,
            @intCast(ordinal),
        );
        if (first == self.directory_index.len or position == self.directory_index.len) return null;
        return position < self.directory_index[first].next_match;
    }
};

/// Internal complete-file pass restart. The previous successful pass must be retired and the same
/// source and exclusive scratch kept live. This reuses lookup ordering, never pass consumption.
/// Public Container.iterator always starts fresh, including when callers reuse scratch storage.
pub fn restart(iterator: *ChunkIterator) void {
    std.debug.assert(iterator.offset == iterator.view.source.len);
    iterator.offset = iterator.view.chunks_start;
    iterator.used_rf64_data_size = false;
    if (iterator.directory_index.len <= 32) {
        @memset(iterator.directory_index, .{ .table_index = 0, .next_match = 0 });
    } else if (iterator.directory_index_ready) {
        resetDirectoryCursors(iterator.directory_index);
    }
}

const ChunkView = struct { id: []const u8, data: []const u8, padding: ?u8, next_offset: usize };

fn nextChunk(iterator: *ChunkIterator) ParseError!ChunkView {
    const source = iterator.view.source;
    const offset = iterator.offset;
    if (offset > source.len) return error.InvalidWave;
    const header = riff.readHeader(source[offset..]) catch return error.InvalidWave;
    const size = if (iterator.view.rf64_sizes) |sizes| try resolveRf64ChunkSize(
        sizes,
        &header.id,
        header.size,
        iterator.directory_index,
        &iterator.used_rf64_data_size,
        &iterator.directory_index_ready,
    ) else @as(u64, header.size);
    var cursor: riff.ChunkIterator = .{ .source = source, .offset = offset };
    const chunk = (cursor.nextResolved(
        size,
    ) catch return error.InvalidWave) orelse return error.InvalidWave;
    return .{
        .id = chunk.id,
        .data = chunk.data,
        .padding = chunk.padding,
        .next_offset = cursor.offset,
    };
}

fn parseRf64Sizes(source: []const u8, offset: *usize) ParseError!Rf64Sizes {
    if (source.len - offset.* < 8 or !std.mem.eql(
        u8,
        source[offset.*..][0..4],
        "ds64",
    )) return error.InvalidWave;
    const chunk_size = readU32(source, offset.* + 4);
    if (chunk_size < 28 or chunk_size == std.math.maxInt(u32)) return error.InvalidWave;
    var cursor: riff.ChunkIterator = .{ .source = source, .offset = offset.* };
    const chunk = (cursor.next() catch return error.InvalidWave) orelse return error.InvalidWave;
    const payload = chunk.data;
    const next = cursor.offset;
    const table_count = readU32(payload, 24);
    const table_bytes = std.math.mul(
        usize,
        @as(usize, table_count),
        12,
    ) catch return error.InvalidWave;
    const expected_size = std.math.add(usize, 28, table_bytes) catch return error.InvalidWave;
    if (payload.len != expected_size) return error.InvalidWave;
    offset.* = next;
    return .{
        .riff_size = readU64(payload, 0),
        .data_size = readU64(payload, 8),
        .sample_count = readU64(payload, 16),
        .table = payload[28..],
    };
}

fn resolveRf64ChunkSize(
    sizes: Rf64Sizes,
    chunk_id: []const u8,
    field: u32,
    directory_index: []ChunkIndexEntry,
    used_rf64_data_size: *bool,
    index_ready: *bool,
) ParseError!u64 {
    if (field != std.math.maxInt(u32)) return field;
    if (std.mem.eql(u8, chunk_id, "data")) {
        // ds64 has one dataSize field; its table only names other chunk types.
        if (used_rf64_data_size.*) return error.InvalidWave;
        used_rf64_data_size.* = true;
        return sizes.data_size;
    }
    // Keep small directories on a direct scan with a fixed comparison bound.
    if (directory_index.len <= 32) {
        for (directory_index, 0..) |*entry, index| {
            if (entry.next_match != 0) continue;
            const offset = index * 12;
            if (std.mem.eql(u8, sizes.table[offset..][0..4], chunk_id)) {
                entry.next_match = 1;
                return readU64(sizes.table, offset + 4);
            }
        }
        return error.InvalidWave;
    }
    return indexedChunkSize(sizes.table, chunk_id, directory_index, index_ready);
}

// Keep directory setup and binary lookup out of the ordinary RIFF/small-RF64 path.
noinline fn indexedChunkSize(
    table: []const u8,
    chunk_id: []const u8,
    entries: []ChunkIndexEntry,
    ready: *bool,
) ParseError!u64 {
    if (!ready.*) {
        prepareDirectoryIndex(table, entries);
        ready.* = true;
    }
    const key = readU32(chunk_id, 0);
    const first = lowerBoundDirectory(table, entries, key, 0);
    if (first == entries.len) return error.InvalidWave;
    const next: usize = entries[first].next_match;
    if (next == entries.len) return error.InvalidWave;
    const offset = @as(usize, entries[next].table_index) * 12;
    if (readU32(table, offset) != key) return error.InvalidWave;
    entries[first].next_match = @intCast(next + 1);
    return readU64(table, offset + 4);
}

fn lowerBoundDirectory(
    table: []const u8,
    entries: []const ChunkIndexEntry,
    key: u32,
    ordinal: u32,
) usize {
    var first: usize = 0;
    var end = entries.len;
    while (first < end) {
        const middle = first + (end - first) / 2;
        const entry = entries[middle];
        const id = readU32(table, @as(usize, entry.table_index) * 12);
        if (id < key or (id == key and entry.table_index < ordinal)) {
            first = middle + 1;
        } else {
            end = middle;
        }
    }
    return first;
}

fn prepareDirectoryIndex(table: []const u8, entries: []ChunkIndexEntry) void {
    // The ds64 u32 payload length bounds both source ordinals and end cursors to u32.
    for (entries, 0..) |*entry, index| {
        entry.* = .{ .table_index = @intCast(index), .next_match = 0 };
    }
    std.sort.pdq(ChunkIndexEntry, entries, table, struct {
        fn less(bytes: []const u8, a: ChunkIndexEntry, b: ChunkIndexEntry) bool {
            const a_id = readU32(bytes, @as(usize, a.table_index) * 12);
            const b_id = readU32(bytes, @as(usize, b.table_index) * 12);
            return if (a_id == b_id) a.table_index < b.table_index else a_id < b_id;
        }
    }.less);
    // Equal IDs use a cursor at their first sorted slot. The remaining slots stay immutable lookup
    // keys, preserving the original order for each ID.
    resetDirectoryCursors(entries);
}

fn resetDirectoryCursors(entries: []ChunkIndexEntry) void {
    for (entries, 0..) |*entry, index| entry.next_match = @intCast(index);
}

fn readU32(source: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, source[offset..][0..4], .little);
}

fn readU64(source: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, source[offset..][0..8], .little);
}

test "RF64 explicit outer sizes take precedence over unused ds64 replacements" {
    var source = @import("fixtures.zig").rf64_explicit_lengths.*;
    try std.testing.expectEqual(82, source.len);
    for ([_]u64{ 0, 74, std.math.maxInt(u64) }) |replacement| {
        std.mem.writeInt(u64, source[20..28], replacement, .little);
        const view = try parse(&source);
        try std.testing.expectEqual(0, view.scratchCount());
        try std.testing.expectEqual(replacement, view.rf64_sizes.?.riff_size);
        var chunks = try view.iterator(&.{});
        try std.testing.expectEqualStrings("fmt ", (try chunks.next()).?.id);
        const data = (try chunks.next()).?;
        try std.testing.expectEqualSlices(u8, &.{0xff}, data.data);
        try std.testing.expectEqual(0, data.padding.?);
        try std.testing.expectEqual(null, try chunks.next());
    }
    std.mem.writeInt(u64, source[20..28], 74, .little);
    for ([_]u32{ 73, 75 }) |incorrect| {
        std.mem.writeInt(u32, source[4..8], incorrect, .little);
        try std.testing.expectError(error.InvalidWave, parse(&source));
    }
    std.mem.writeInt(u32, source[4..8], std.math.maxInt(u32), .little);
    _ = try parse(&source);
    std.mem.writeInt(u64, source[20..28], 0, .little);
    try std.testing.expectError(error.InvalidWave, parse(&source));
    std.mem.writeInt(u32, source[4..8], 74, .little);
    @memcpy(source[12..16], "JUNK");
    try std.testing.expectError(error.InvalidWave, parse(&source));
}

test "each container traversal resets its index and borrows ordered RF64 payloads" {
    const source = @import("fixtures.zig").rf64_repeated_unknown_chunks;
    const view = try parse(source);
    try std.testing.expectEqual(3, view.scratchCount());
    var scratch: [3]ChunkIndexEntry = undefined;
    for (0..2) |_| {
        var chunks = try view.iterator(&scratch);
        for (
            0..3,
        ) |index| try std.testing.expectEqual(@as(?bool, false), chunks.tableEntryUsed(index));
        for ([_][]const u8{ "JUNK", "FILL", "JUNK", "fmt ", "data" }, 0..) |id, index| {
            const chunk = (try chunks.next()).?;
            try std.testing.expectEqualStrings(id, chunk.id);
            const begin = @intFromPtr(chunk.data.ptr) - @intFromPtr(source.ptr);
            try std.testing.expect(begin + chunk.data.len <= source.len);
            if (index == 0) try std.testing.expectEqualStrings("abc", chunk.data);
            if (index == 1) try std.testing.expectEqualStrings("1234", chunk.data);
            if (index == 2) try std.testing.expectEqualStrings("defgh", chunk.data);
        }
        for (
            0..3,
        ) |index| try std.testing.expectEqual(@as(?bool, true), chunks.tableEntryUsed(index));
        try std.testing.expectEqual(null, try chunks.next());
        try std.testing.expectEqual(null, try chunks.next());
    }
}

test "RF64 directory index reserves eight bytes without hidden alignment padding" {
    try std.testing.expectEqual(8, @sizeOf(ChunkIndexEntry));
    try std.testing.expectEqual(1, @alignOf(ChunkIndexEntry));
}

test "complete-file restarts leave unused large RF64 ordering unprepared" {
    const fixture = @import("fixtures.zig");
    const allocator = std.testing.allocator;
    for ([_]usize{ 31, 32, 33, 97 }) |count| {
        const table = try allocator.alloc(fixture.Rf64Size, count);
        defer allocator.free(table);
        @memset(table, .{ .id = "JUNK".*, .size = 1 });
        const metadata = [_]fixture.Rf64Chunk{.{ .id = "JUNK".*, .data = "x", .sentinel = false }};
        const source = try fixture.makeRf64Metadata(allocator, table, &metadata);
        defer allocator.free(source);
        const scratch = try allocator.alloc(ChunkIndexEntry, count + 1);
        defer allocator.free(scratch);
        @memset(std.mem.sliceAsBytes(scratch), 0x5a);
        const view = try parse(source);
        var chunks = try view.iterator(scratch);
        for (0..3) |pass| {
            if (pass != 0) {
                restart(&chunks);
                try std.testing.expect(!chunks.used_rf64_data_size);
            }
            try std.testing.expectEqual(view.chunks_start, chunks.offset);
            while (try chunks.next()) |_| {}
            try std.testing.expect(chunks.used_rf64_data_size);
            try std.testing.expect(!chunks.directory_index_ready);
            for (0..count) |ordinal| {
                try std.testing.expectEqual(@as(?bool, false), chunks.tableEntryUsed(ordinal));
            }
            if (count > 32) {
                try std.testing.expect(std.mem.allEqual(u8, std.mem.sliceAsBytes(scratch), 0x5a));
            }
            try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&scratch[count]), 0x5a));
        }
    }
}

test "RF64 directories preserve per-ID source order across lookup sizes and unaligned storage" {
    const fixture = @import("fixtures.zig");
    const allocator = std.testing.allocator;
    for ([_]usize{ 0, 1, 16, 31, 32, 33, 64, 97 }) |count| {
        for (0..4) |distribution| {
            const table = try allocator.alloc(fixture.Rf64Size, count);
            defer allocator.free(table);
            const payloads = try allocator.alloc([2]u8, count);
            defer allocator.free(payloads);
            const unused = @intFromBool(distribution == 3 and count != 0);
            const order = try allocator.alloc(usize, count - unused);
            defer allocator.free(order);
            const metadata = try allocator.alloc(fixture.Rf64Chunk, order.len);
            defer allocator.free(metadata);
            const expected_used = try allocator.alloc(bool, count);
            defer allocator.free(expected_used);
            const half = count / 2;
            for (table, payloads, 0..) |*entry, *payload, ordinal| {
                var id = "JUNK".*;
                if (distribution == 1) {
                    std.mem.writeInt(u32, &id, @intCast(ordinal), .little);
                } else if (distribution == 2 and ordinal >= half) {
                    id = "FILL".*;
                } else if (distribution == 3 and ordinal == 0) {
                    id = "KEEP".*;
                }
                entry.* = .{ .id = id, .size = ordinal % 3 };
                payload.* = .{ @intCast(ordinal), @intCast(255 - ordinal) };
            }
            var first: usize = 0;
            var second = half;
            for (order, metadata, 0..) |*ordinal, *chunk, position| {
                ordinal.* = switch (distribution) {
                    1 => count - position - 1,
                    2 => block: {
                        if ((position % 2 == 0 and first < half) or second == count) {
                            defer first += 1;
                            break :block first;
                        }
                        defer second += 1;
                        break :block second;
                    },
                    else => position + unused,
                };
                chunk.* = .{
                    .id = table[ordinal.*].id,
                    .data = payloads[ordinal.*][0..@intCast(table[ordinal.*].size)],
                };
            }
            const encoded = try fixture.makeRf64Metadata(allocator, table, metadata);
            defer allocator.free(encoded);
            const source_storage = try allocator.alloc(u8, encoded.len + 3);
            defer allocator.free(source_storage);
            const scratch_storage = try allocator.alloc(u8, count * @sizeOf(ChunkIndexEntry) + 3);
            defer allocator.free(scratch_storage);
            for (0..4) |alignment_offset| {
                @memset(source_storage, 0xa5);
                const source = source_storage[alignment_offset..][0..encoded.len];
                @memcpy(source, encoded);
                @memset(scratch_storage, 0x5a);
                const scratch_pointer: [*]ChunkIndexEntry = @ptrCast(
                    scratch_storage[alignment_offset..].ptr,
                );
                const scratch = scratch_pointer[0..count];
                const view = try parse(source);
                try std.testing.expectEqual(count, view.scratchCount());
                for (0..2) |_| {
                    var chunks = try view.iterator(scratch);
                    for (0..3) |pass| {
                        if (pass != 0) restart(&chunks);
                        @memset(expected_used, false);
                        try std.testing.expectEqual(@as(?bool, null), chunks.tableEntryUsed(count));
                        for (0..count) |ordinal| {
                            try std.testing.expectEqual(
                                @as(?bool, false),
                                chunks.tableEntryUsed(ordinal),
                            );
                        }
                        var payload_offset = view.chunks_start + 8;
                        for (metadata, order) |expected, ordinal| {
                            const chunk = (try chunks.next()).?;
                            try std.testing.expectEqualSlices(u8, &expected.id, chunk.id);
                            try std.testing.expectEqualSlices(u8, expected.data, chunk.data);
                            try std.testing.expectEqual(
                                @intFromPtr(source.ptr) + payload_offset,
                                @intFromPtr(chunk.data.ptr),
                            );
                            expected_used[ordinal] = true;
                            for (expected_used, 0..) |used, index| {
                                try std.testing.expectEqual(
                                    @as(?bool, used),
                                    chunks.tableEntryUsed(index),
                                );
                            }
                            payload_offset += 8 + expected.data.len + (expected.data.len & 1);
                        }
                        try std.testing.expectEqualStrings("fmt ", (try chunks.next()).?.id);
                        const data = (try chunks.next()).?;
                        try std.testing.expectEqualStrings("data", data.id);
                        try std.testing.expectEqualSlices(u8, &.{0xff}, data.data);
                        try std.testing.expectEqual(null, try chunks.next());
                        try std.testing.expectEqual(null, try chunks.next());
                    }
                }
                try std.testing.expectEqualSlices(u8, encoded, source);
                for (
                    source_storage[0..alignment_offset],
                ) |byte| try std.testing.expectEqual(0xa5, byte);
                for (
                    source_storage[alignment_offset + encoded.len ..],
                ) |byte| try std.testing.expectEqual(0xa5, byte);
                for (
                    scratch_storage[0..alignment_offset],
                ) |byte| try std.testing.expectEqual(0x5a, byte);
                for (
                    scratch_storage[alignment_offset + count * @sizeOf(ChunkIndexEntry) ..],
                ) |byte| {
                    try std.testing.expectEqual(0x5a, byte);
                }
            }
        }
    }
}

test "RF64 directory matching bypasses explicit sizes and refuses missing or exhausted IDs" {
    const fixture = @import("fixtures.zig");
    const allocator = std.testing.allocator;
    for ([_]usize{ 1, 40 }) |count| {
        const table = try allocator.alloc(fixture.Rf64Size, count);
        defer allocator.free(table);
        @memset(table, .{ .id = "KEEP".*, .size = 0 });
        table[0] = .{ .id = "JUNK".*, .size = 1 };
        const scratch = try allocator.alloc(ChunkIndexEntry, count);
        defer allocator.free(scratch);
        const explicit = try fixture.makeRf64Metadata(
            allocator,
            table,
            &.{
                .{ .id = "JUNK".*, .data = "abc", .sentinel = false },
                .{ .id = "JUNK".*, .data = "x" },
            },
        );
        defer allocator.free(explicit);
        const explicit_view = try parse(explicit);
        var chunks = try explicit_view.iterator(scratch);
        try std.testing.expectEqualStrings("abc", (try chunks.next()).?.data);
        try std.testing.expectEqual(@as(?bool, false), chunks.tableEntryUsed(0));
        try std.testing.expectEqualStrings("x", (try chunks.next()).?.data);
        try std.testing.expectEqual(@as(?bool, true), chunks.tableEntryUsed(0));
        while (try chunks.next()) |_| {}
        for (
            1..count,
        ) |ordinal| try std.testing.expectEqual(@as(?bool, false), chunks.tableEntryUsed(ordinal));

        for ([_]bool{ false, true }) |exhausted| {
            const metadata = [_]fixture.Rf64Chunk{
                .{ .id = "JUNK".*, .data = "x" },
                .{ .id = if (exhausted) "JUNK".* else "NONE".*, .data = "x" },
            };
            const invalid = try fixture.makeRf64Metadata(allocator, table, &metadata);
            defer allocator.free(invalid);
            const view = try parse(invalid);
            for (0..2) |_| {
                var retry = try view.iterator(scratch);
                try std.testing.expectEqual(@as(?bool, false), retry.tableEntryUsed(0));
                try std.testing.expectEqualStrings("x", (try retry.next()).?.data);
                const before = retry.offset;
                try std.testing.expectError(error.InvalidWave, retry.next());
                try std.testing.expectEqual(before, retry.offset);
                try std.testing.expectEqual(@as(?bool, true), retry.tableEntryUsed(0));
            }
        }
    }
}

test "container traversal rejects missing word padding and repeated data sentinels" {
    const unpadded = "RIFF\x0d\x00\x00\x00WAVEJUNK\x01\x00\x00\x00x";
    const view = try parse(unpadded);
    var chunks = try view.iterator(&.{});
    try std.testing.expectError(error.InvalidWave, chunks.next());

    const source = @import("fixtures.zig").rf64_split_data;
    var repeated = source[0..source.len].*;
    // This fixture's second data chunk normally has an explicit size.
    std.mem.writeInt(u32, repeated[86..90], std.math.maxInt(u32), .little);
    const repeated_view = try parse(&repeated);
    var repeated_chunks = try repeated_view.iterator(&.{});
    try std.testing.expectEqualStrings("fmt ", (try repeated_chunks.next()).?.id);
    try std.testing.expectEqualStrings("data", (try repeated_chunks.next()).?.id);
    try std.testing.expectError(error.InvalidWave, repeated_chunks.next());
}
