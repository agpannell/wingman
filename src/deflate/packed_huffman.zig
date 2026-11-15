//! Flat canonical Huffman tables for complete, full-window DEFLATE blocks. Entries cache code and
//! payload widths with literal, continuation and end markers. This representation owns its packed
//! bit cursor: its upper count bits carry entry flags and are not an ordinary count of available
//! bits.

const std = @import("std");
const OrdinaryBitReader = @import("BitReader.zig");
const huffman = @import("huffman.zig");
const protocol = @import("format.zig");

/// Invalid codebooks or encoded tokens in the packed representation.
pub const Error = error{InvalidStream};
const IndexShift = std.math.Log2Int(usize);
const TableKind = huffman.TableKind;
const distance_base = protocol.distance_base;
const distance_extra = protocol.distance_extra;
const length_base = protocol.length_base;
const length_extra = protocol.length_extra;

/// Packed canonical tables and bounded construction scratch for complete books. The decoder admits
/// this representation only for whole-buffer, full-window calls. Primary and secondary entries
/// cache bases and consumed/code widths.
pub const Tables = extern struct {
    const Self = @This();

    /// Direct literal leaf; bits 16..23 contain its byte value.
    pub const literal_flag: u32 = 0x80000000;
    /// Entry carries a continuation or end-of-block marker rather than a match base.
    pub const exceptional: u32 = 0x8000;
    /// Continuation entry; its high halfword indexes a flat secondary table.
    pub const subtable: u32 = 0x4000;
    /// End-of-block marker, combined with exceptional.
    pub const end_flag: u32 = 0x2000;

    const Built = struct { bits: u8, used: u16 };

    /// Flat literal/length primary and secondary entries; only literal_used slots are live.
    literal: [2342]u32,
    /// Flat distance entries with an eight-bit primary root; only distance_used slots are live.
    distance: [402]u32,
    /// Construction scratch holding symbols ordered by code length, then canonical ordinal.
    sorted: [288]u16,
    /// Construction offsets for code widths zero through fifteen.
    offsets: [16]u16,
    /// Initialized literal/length entries after successful construction.
    literal_used: u16,
    /// Initialized distance entries after successful construction.
    distance_used: u16,
    /// Primary literal/length lookup width, reduced for complete short-code books.
    literal_bits: u8,

    /// Resolved packed leaf with the original low bits available for payload extraction.
    pub const Decoded = struct {
        /// Resolved packed leaf, including base, flags and consumption widths.
        entry: u32,
        /// Original low encoded bits before code and payload consumption.
        saved: u64,

        /// Adds the extra payload to a resolved length/distance base. Literal, continuation and
        /// end-of-block entries must be handled before calling.
        pub fn matchValue(self: Decoded) usize {
            std.debug.assert(self.entry & (literal_flag | exceptional) == 0);
            const total: u8 = @truncate(self.entry);
            const code: u8 = @truncate(self.entry >> 8);
            const mask = (@as(u64, 1) << @as(u6, @intCast(total))) - 1;
            const payload: usize = @intCast((self.saved & mask) >> @as(u6, @intCast(code)));
            const base: usize = self.entry >> 16;
            return base + payload;
        }
    };

    /// Reads one checked leaf, retaining its original bits for extra payload. Zero-filled lookahead
    /// may select a replicated leaf near EOF; every consumed code and payload bit must be present
    /// in the supplied input.
    pub fn read(
        self: *const Self,
        comptime distances: bool,
        bits: *OrdinaryBitReader,
    ) Error!Decoded {
        const table: []const u32 = if (distances) &self.distance else &self.literal;
        const root_bits: u8 = if (distances) 8 else self.literal_bits;
        bits.refill(root_bits);
        const root_mask = (@as(usize, 1) << @as(IndexShift, @intCast(root_bits))) - 1;
        var value = table[@as(usize, @truncate(bits.value)) & root_mask];
        if (value & subtable != 0) {
            if (bits.count < root_bits) return error.InvalidStream;
            bits.drop(root_bits);
            const suffix: u8 = @intCast((value >> 8) & 63);
            bits.refill(suffix);
            const mask = (@as(usize, 1) << @as(IndexShift, @intCast(suffix))) - 1;
            value = table[(value >> 16) + (@as(usize, @truncate(bits.value)) & mask)];
        }
        const consumed: u8 = @truncate(value);
        bits.refill(consumed);
        if (bits.count < consumed) return error.InvalidStream;
        const saved = bits.value;
        bits.drop(consumed);
        return .{ .entry = value, .saved = saved };
    }

    /// Builds both tables without allocation. False declines a valid book that needs another
    /// representation; invalid code lengths return InvalidStream. A refusal may change scratch, so
    /// read only after successful construction.
    pub fn build(self: *Self, lengths: []const u8, distances: []const u8) Error!bool {
        if (lengths.len < 257 or lengths.len > 286 or distances.len == 0 or distances.len > 32)
            return error.InvalidStream;
        if (lengths[256] == 0) return error.InvalidStream;
        const literal_counts = try huffman.countCodeLengths(288, lengths, false, true);
        const distance_counts = try huffman.countCodeLengths(32, distances, true, true);
        if (!literal_counts.complete or !distance_counts.complete) return false;
        if (distances.len > 30 and distances[30] != 0) return false;
        if (distances.len > 31 and distances[31] != 0) return false;

        const built_distance = self.buildFlat(
            &self.distance,
            distances,
            distance_counts.counts,
            .distance,
            8,
            false,
        ) orelse return false;
        const built_literal = self.buildFlat(
            &self.literal,
            lengths,
            literal_counts.counts,
            .literal_length,
            11,
            true,
        ) orelse return false;
        self.literal_bits = built_literal.bits;
        self.literal_used = built_literal.used;
        self.distance_used = built_distance.used;
        return true;
    }

    fn entry(comptime kind: TableKind, symbol: usize, width: u8) u32 {
        if (kind == .distance) {
            std.debug.assert(symbol < 30);
            const base = @as(u32, distance_base[symbol]) << 16;
            const code = @as(u32, width) << 8;
            const total = @as(u32, width) + distance_extra[symbol];
            return base | code | total;
        }
        if (symbol < 256) return literal_flag | (@as(u32, @intCast(symbol)) << 16) | width;
        if (symbol == 256) return exceptional | end_flag | width;
        std.debug.assert(symbol < 286);
        const index = symbol - 257;
        const base = @as(u32, length_base[index]) << 16;
        const code = @as(u32, width) << 8;
        const total = @as(u32, width) + length_extra[index];
        return base | code | total;
    }

    // The caller has already excluded the all-ones final codeword.
    fn advance(word: usize, width: u8) usize {
        const mask = (@as(usize, 1) << @as(IndexShift, @intCast(width))) - 1;
        const flipped = word ^ mask;
        std.debug.assert(flipped != 0);
        const shift: IndexShift = @intCast(@bitSizeOf(usize) - 1 - @clz(flipped));
        const bit = @as(usize, 1) << shift;
        return (word & (bit - 1)) | bit;
    }

    fn buildFlat(
        self: *Self,
        table: []u32,
        lengths: []const u8,
        counts: [16]u16,
        comptime kind: TableKind,
        comptime root_max: u8,
        comptime shrink: bool,
    ) ?Built {
        var maximum: u8 = 15;
        while (maximum > 1 and counts[maximum] == 0) maximum -= 1;
        const root_bits = if (shrink) @min(root_max, maximum) else root_max;
        const root_size = @as(usize, 1) << @as(IndexShift, @intCast(root_bits));
        if (root_size > table.len) return null;
        // Skip the zero bucket when at least three quarters of the alphabet has no code. Denser
        // books keep a branchless scan; both spans preserve canonical order among active symbols.
        const sparse = lengths.len - counts[0] <= lengths.len / 4;
        self.offsets[0] = 0;
        self.offsets[1] = if (sparse) 0 else counts[0];
        for (2..16) |i| self.offsets[i] = self.offsets[i - 1] + counts[i - 1];
        if (sparse) {
            for (lengths, 0..) |width, symbol| {
                if (width == 0) continue;
                self.sorted[self.offsets[width]] = @intCast(symbol);
                self.offsets[width] += 1;
            }
        } else {
            for (lengths, 0..) |width, symbol| {
                self.sorted[self.offsets[width]] = @intCast(symbol);
                self.offsets[width] += 1;
            }
        }
        var sorted: usize = self.offsets[0];
        var width: u8 = 1;
        while (counts[width] == 0) width += 1;
        var remaining: usize = counts[width];
        var word: usize = 0;
        var table_end = @as(usize, 1) << @as(IndexShift, @intCast(width));
        while (width <= root_bits) {
            while (remaining != 0) : (remaining -= 1) {
                table[word] = entry(kind, self.sorted[sorted], width);
                sorted += 1;
                if (word == table_end - 1) {
                    while (width < root_bits) : (width += 1) {
                        @memcpy(table[table_end..][0..table_end], table[0..table_end]);
                        table_end *= 2;
                    }
                    return .{ .bits = root_bits, .used = @intCast(table_end) };
                }
                word = advance(word, width);
            }
            while (true) {
                width += 1;
                if (width <= root_bits) {
                    // As-yet-unfilled words may be transported by this byte copy. Complete Kraft
                    // coverage fills every reachable word before use.
                    @memcpy(table[table_end..][0..table_end], table[0..table_end]);
                    table_end *= 2;
                }
                remaining = counts[width];
                if (remaining != 0) break;
            }
        }
        table_end = root_size;
        var prefix: usize = std.math.maxInt(usize);
        var start: usize = 0;
        while (true) {
            const next_prefix = word & (root_size - 1);
            if (next_prefix != prefix) {
                prefix = next_prefix;
                start = table_end;
                var suffix_bits = width - root_bits;
                var space = remaining;
                while (space < (@as(usize, 1) << @as(IndexShift, @intCast(suffix_bits)))) {
                    suffix_bits += 1;
                    space = space * 2 + counts[root_bits + suffix_bits];
                }
                const slots = @as(usize, 1) << @as(IndexShift, @intCast(suffix_bits));
                if (slots > table.len - start) return null;
                table_end = start + slots;
                const child_index = @as(u32, @intCast(start)) << 16;
                const child_width = @as(u32, suffix_bits) << 8;
                table[prefix] = child_index | exceptional | subtable | child_width | root_bits;
            }
            const suffix = width - root_bits;
            const value = entry(kind, self.sorted[sorted], suffix);
            sorted += 1;
            var index = start + (word >> @as(IndexShift, @intCast(root_bits)));
            const stride = @as(usize, 1) << @as(IndexShift, @intCast(suffix));
            while (index < table_end) : (index += stride) table[index] = value;
            const last_word = (@as(usize, 1) << @as(IndexShift, @intCast(width))) - 1;
            if (word == last_word) return .{ .bits = root_bits, .used = @intCast(table_end) };
            word = advance(word, width);
            remaining -= 1;
            while (remaining == 0) {
                width += 1;
                remaining = counts[width];
            }
        }
    }
};

/// Bit input specialized for whole-buffer packed entries. The low byte of count holds available
/// bits; upper bits may contain wrapped entry flags. Subtracting an entire entry consumes its
/// low-byte width without masking. Refills and publication use only the actual bit count.
pub const BitReader = struct {
    /// Immutable encoded input shared with the ordinary reader at prefix entry and handoff.
    source: []const u8,
    /// Low encoded bits before the next packed-entry consumption.
    value: u64,
    /// Low byte counts available bits; upper bits carry wrapped packed-entry flags.
    count: u32,
    /// Next source byte to load, excluding already buffered lookahead.
    position: usize,

    /// Refills from eight in-range source bytes. The caller proves that margin before entering.
    pub fn refill(self: *BitReader) void {
        std.debug.assert(self.source.len - self.position >= 8);
        std.debug.assert(@as(u8, @truncate(self.count)) <= 63);
        const word = std.mem.readInt(u64, self.source[self.position..][0..8], .little);
        self.value |= word << @as(u6, @truncate(self.count));
        self.position += 7 - ((self.count >> 3) & 7);
        self.count |= 56;
    }

    /// Consumes entry's low-byte width by subtracting the complete packed entry.
    pub fn drop(self: *BitReader, entry: u32) void {
        std.debug.assert(@as(u8, @truncate(self.count)) >= @as(u8, @truncate(entry)));
        self.value >>= @as(u6, @truncate(entry));
        self.count -%= entry;
    }

    /// Restores ordinary bit state for a reader borrowing the same source bytes.
    pub fn publish(self: *const BitReader, bits: *OrdinaryBitReader) void {
        bits.value = self.value;
        bits.position = self.position;
        bits.count = @truncate(self.count);
    }
};

fn checkPackedTable(
    table: []const u32,
    root_bits: u8,
    lengths: []const u8,
    comptime distances: bool,
) !void {
    var counts: [16]u32 = @splat(0);
    for (lengths) |width| counts[width] += 1;
    var code: u32 = 0;
    for (1..16) |width| {
        code = (code + if (width == 1) 0 else counts[width - 1]) * 2;
        for (lengths, 0..) |actual_width, symbol| {
            if (actual_width != width) continue;
            const reversed = @bitReverse(@as(u16, @intCast(code))) >> @as(u4, @intCast(16 - width));
            code += 1;
            const extra: u8 = blk: {
                if (distances) break :blk if (symbol < 4) 0 else @intCast(symbol / 2 - 1);
                if (symbol < 265 or symbol == 285) break :blk 0;
                break :blk @intCast((symbol - 265) / 4 + 1);
            };
            const base: u32 = blk: {
                if (distances) {
                    if (symbol < 4) break :blk @intCast(symbol + 1);
                    const group = @as(u32, 1) << @as(u5, @intCast(extra + 1));
                    const side = @as(u32, @intCast(symbol & 1)) << @as(u5, @intCast(extra));
                    break :blk group + 1 + side;
                }
                if (symbol < 257) break :blk @intCast(symbol);
                if (symbol < 265) break :blk @intCast(symbol - 254);
                if (symbol == 285) break :blk 258;
                const group = @as(u32, 1) << @as(u5, @intCast(extra + 2));
                const offset = @as(u32, @intCast((symbol - 265) % 4)) << @as(u5, @intCast(extra));
                break :blk group + 3 + offset;
            };
            for (0..@as(usize, 1) << @as(IndexShift, @intCast(extra))) |payload| {
                const payload_bits = @as(u64, @intCast(payload)) << @as(u6, @intCast(width));
                const following = @as(u64, 0xd7a9) << @as(u6, @intCast(width + extra));
                const lookahead: u64 = reversed | payload_bits | following;
                const root_mask = (@as(usize, 1) << @as(IndexShift, @intCast(root_bits))) - 1;
                var value = table[@as(usize, @truncate(lookahead)) & root_mask];
                var consumed: u8 = 0;
                if (value & 0x4000 != 0) {
                    try std.testing.expect(value & 0x8000 != 0);
                    consumed = @truncate(value);
                    try std.testing.expectEqual(root_bits, consumed);
                    const suffix_bits: u8 = @intCast((value >> 8) & 63);
                    const suffix_mask = (@as(
                        usize,
                        1,
                    ) << @as(IndexShift, @intCast(suffix_bits))) - 1;
                    const suffix: usize = @truncate(lookahead >> @as(u6, @intCast(root_bits)));
                    const index = (value >> 16) + (suffix & suffix_mask);
                    try std.testing.expect(index < table.len);
                    value = table[index];
                }
                consumed += @as(u8, @truncate(value));
                try std.testing.expectEqual(@as(u8, @intCast(width)) + extra, consumed);
                if (!distances and symbol < 256) {
                    try std.testing.expectEqual(
                        @as(u32, 0x80000000),
                        value & 0xffff0000 & 0x80000000,
                    );
                    try std.testing.expectEqual(base, (value >> 16) & 255);
                } else if (!distances and symbol == 256) {
                    try std.testing.expectEqual(@as(u32, 0xa000), value & 0xe000);
                } else {
                    try std.testing.expectEqual(@as(u32, 0), value & 0xe000);
                    try std.testing.expectEqual(base, value >> 16);
                    const code_bits: u8 = @intCast((value >> 8) & 255);
                    try std.testing.expectEqual(
                        @as(u8, @intCast(width)),
                        code_bits + consumed - @as(u8, @truncate(value)),
                    );
                    const mask = (@as(u64, 1) << @as(u6, @intCast(extra))) - 1;
                    const extracted = (lookahead >> @as(u6, @intCast(width))) & mask;
                    try std.testing.expectEqual(
                        base + @as(u32, @intCast(payload)),
                        (value >> 16) + @as(u32, @intCast(extracted)),
                    );
                }
            }
        }
        // The next length starts after all codes of this width, not after a second count addition:
        // code already includes the symbols above.
        if (width < 15) code -= counts[width];
    }
}

fn completeCodeLengths(lengths: []u8, seed: u32) void {
    @memset(lengths, 0);
    lengths[0] = 1;
    lengths[1] = 1;
    var state = seed;
    var used: usize = 2;
    while (used < lengths.len) : (used += 1) {
        var choice: usize = 0;
        if (seed == 0) {
            for (lengths[0..used], 0..) |width, index| {
                if (width < lengths[choice]) choice = index;
            }
        } else if (used < 16) {
            choice = used - 1;
        } else {
            state = state *% 1664525 +% 1013904223;
            choice = state % used;
            while (lengths[choice] == 15) choice = (choice + 1) % used;
        }
        const child = lengths[choice] + 1;
        lengths[choice] = child;
        lengths[used] = child;
    }
}

fn packedLeafAt(table: []const u32, root_bits: u8, lookahead: u64) !u64 {
    const mask = (@as(usize, 1) << @as(IndexShift, @intCast(root_bits))) - 1;
    var value = table[@as(usize, @truncate(lookahead)) & mask];
    var consumed: u8 = 0;
    if (value & 0x4000 != 0) {
        consumed = @truncate(value);
        try std.testing.expectEqual(root_bits, consumed);
        const suffix: u8 = @intCast((value >> 8) & 63);
        const suffix_mask = (@as(usize, 1) << @as(IndexShift, @intCast(suffix))) - 1;
        const following: usize = @truncate(lookahead >> @as(u6, @intCast(root_bits)));
        const index = (value >> 16) + (following & suffix_mask);
        try std.testing.expect(index < table.len);
        value = table[index];
    }
    return (@as(u64, consumed) << 32) | value;
}

fn checkPackedCoverage(
    expected: []u64,
    table: []const u32,
    root_bits: u8,
    lengths: []const u8,
    comptime distances: bool,
) !void {
    @memset(expected, std.math.maxInt(u64));
    var counts: [16]u32 = @splat(0);
    for (lengths) |width| counts[width] += 1;
    var start: u32 = 0;
    var previous: u32 = 0;
    for (1..16) |width| {
        start = (start + previous) * 2;
        var code = start;
        for (lengths, 0..) |actual, symbol| {
            if (actual != width) continue;
            const reversed = @bitReverse(@as(u16, @intCast(code))) >> @as(u4, @intCast(16 - width));
            code += 1;
            const extra: u8 = blk: {
                if (distances) break :blk if (symbol < 4) 0 else @intCast(symbol / 2 - 1);
                if (symbol < 265 or symbol == 285) break :blk 0;
                break :blk @intCast((symbol - 265) / 4 + 1);
            };
            const anchor = try packedLeafAt(
                table,
                root_bits,
                reversed | (@as(u64, 0xd7a9) << @as(u6, @intCast(width + extra))),
            );
            const stride = @as(usize, 1) << @as(IndexShift, @intCast(width));
            var index: usize = reversed;
            while (index < expected.len) : (index += stride) {
                try std.testing.expectEqual(std.math.maxInt(u64), expected[index]);
                expected[index] = anchor;
            }
        }
        previous = counts[width];
    }
    for (expected, 0..) |value, lookahead| {
        try std.testing.expect(value != std.math.maxInt(u64));
        try std.testing.expectEqual(
            value,
            try packedLeafAt(table, root_bits, lookahead | (@as(u64, 0xc3) << 15)),
        );
    }
}

test "packed tables preserve canonical symbols payloads and storage bounds" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(Tables);
    defer allocator.destroy(tables);
    var lengths: [286]u8 = undefined;
    var distances: [32]u8 = @splat(0);
    for (0..17) |seed| {
        completeCodeLengths(&lengths, @intCast(seed));
        completeCodeLengths(distances[0..30], @intCast(seed));
        try std.testing.expect(try tables.build(&lengths, &distances));
        try std.testing.expect(tables.literal_used <= tables.literal.len);
        try std.testing.expect(tables.distance_used <= tables.distance.len);
        try checkPackedTable(
            tables.literal[0..tables.literal_used],
            tables.literal_bits,
            &lengths,
            false,
        );
        try checkPackedTable(tables.distance[0..tables.distance_used], 8, &distances, true);
    }
    // Complete books on either side of the sparse-sort boundary retain independent canonical
    // expectations while reusing scratch from the preceding dense books.
    for ([_]usize{ 71, 72 }) |active| {
        @memset(&lengths, 0);
        completeCodeLengths(lengths[0..active], 0);
        lengths[256] = lengths[active - 1];
        lengths[active - 1] = 0;
        try std.testing.expect(try tables.build(&lengths, &distances));
        try checkPackedTable(
            tables.literal[0..tables.literal_used],
            tables.literal_bits,
            &lengths,
            false,
        );
        try checkPackedTable(tables.distance[0..tables.distance_used], 8, &distances, true);
    }
    @memset(&lengths, 0);
    lengths[0] = 1;
    lengths[256] = 2;
    lengths[257] = 2;
    distances = @splat(0);
    distances[0] = 1;
    distances[1] = 1;
    try std.testing.expect(try tables.build(&lengths, &distances));
    try std.testing.expectEqual(@as(u8, 2), tables.literal_bits);
    try checkPackedTable(
        tables.literal[0..tables.literal_used],
        tables.literal_bits,
        &lengths,
        false,
    );
    try checkPackedTable(tables.distance[0..tables.distance_used], 8, &distances, true);
}

test "packed admission preserves strict incomplete and reserved fallbacks" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(Tables);
    defer allocator.destroy(tables);
    @memset(std.mem.asBytes(tables), 0x5a);
    const untouched = std.hash.Wyhash.hash(0, std.mem.asBytes(tables));
    var lengths: [286]u8 = @splat(0);
    lengths[0] = 1;
    lengths[256] = 2;
    lengths[257] = 2;
    try std.testing.expect(!try tables.build(&lengths, &.{ 0, 0 }));
    try std.testing.expect(!try tables.build(&lengths, &.{ 1, 0 }));
    var reserved: [32]u8 = @splat(5);
    try std.testing.expect(!try tables.build(&lengths, &reserved));
    reserved[0] = 16;
    try std.testing.expectError(error.InvalidStream, tables.build(&lengths, &reserved));
    try std.testing.expectError(error.InvalidStream, tables.build(&lengths, &.{ 1, 1, 1 }));
    try std.testing.expectError(error.InvalidStream, tables.build(&lengths, &.{ 2, 2 }));
    @memset(&lengths, 0);
    lengths[256] = 1;
    try std.testing.expect(!try tables.build(&lengths, &.{ 1, 1 }));
    lengths[256] = 0;
    try std.testing.expectError(error.InvalidStream, tables.build(&lengths, &.{ 1, 1 }));
    try std.testing.expectEqual(untouched, std.hash.Wyhash.hash(0, std.mem.asBytes(tables)));
}

test "packed secondary capacity refusal stays inside supplied backing" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(Tables);
    defer allocator.destroy(tables);
    var lengths: [286]u8 = undefined;
    completeCodeLengths(&lengths, 1);
    const counts = try huffman.countCodeLengths(288, &lengths, false, false);
    const backing = try allocator.alloc(u32, 2048 + 16);
    defer allocator.free(backing);
    @memset(backing, 0xfaceb00c);
    try std.testing.expect(
        tables.buildFlat(
            backing[8..][0..2048],
            &lengths,
            counts.counts,
            .literal_length,
            11,
            true,
        ) == null,
    );
    for (backing[0..8]) |word| try std.testing.expectEqual(@as(u32, 0xfaceb00c), word);
    for (backing[2056..]) |word| try std.testing.expectEqual(@as(u32, 0xfaceb00c), word);
    // Reusing the same constructor scratch after a refusal reconstructs a full book.
    try std.testing.expect(try tables.build(&lengths, &.{ 1, 1 }));
    try checkPackedTable(
        tables.literal[0..tables.literal_used],
        tables.literal_bits,
        &lengths,
        false,
    );
}

test "packed exhaustive lookahead covers every replicated leaf" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(Tables);
    defer allocator.destroy(tables);
    const expected = try allocator.alloc(u64, 32768);
    defer allocator.free(expected);
    var lengths: [286]u8 = undefined;
    var distances: [30]u8 = undefined;
    for (0..17) |seed| {
        completeCodeLengths(&lengths, @intCast(seed));
        completeCodeLengths(&distances, @intCast(seed));
        try std.testing.expect(try tables.build(&lengths, &distances));
        try checkPackedCoverage(
            expected,
            tables.literal[0..tables.literal_used],
            tables.literal_bits,
            &lengths,
            false,
        );
        try checkPackedCoverage(
            expected,
            tables.distance[0..tables.distance_used],
            8,
            &distances,
            true,
        );
    }
}

test "packed wide counter agrees with checked bit state after full entry subtraction" {
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 256);
    defer allocator.free(source);
    for (source, 0..) |*byte, index| byte.* = @truncate(index * 37 + 11);
    var ordinary = OrdinaryBitReader{ .source = source };
    var fast = BitReader{ .source = source, .value = 0, .count = 0, .position = 0 };
    for (0..96) |index| {
        ordinary.refillWide();
        fast.refill();
        try std.testing.expectEqual(ordinary.value, fast.value);
        try std.testing.expectEqual(ordinary.position, fast.position);
        try std.testing.expectEqual(ordinary.count, @as(u8, @truncate(fast.count)));
        const width: u8 = @intCast(1 + index % 28);
        const flags: u32 = if (index % 2 == 0) 0x80000000 else 0xc000;
        const entry = flags | (@as(u32, @intCast(index)) << 16) | 0x300 | width;
        ordinary.drop(width);
        fast.drop(entry);
        try std.testing.expectEqual(ordinary.value, fast.value);
        try std.testing.expectEqual(ordinary.count, @as(u8, @truncate(fast.count)));
    }
    var published = OrdinaryBitReader{ .source = source };
    fast.publish(&published);
    try std.testing.expectEqual(ordinary.value, published.value);
    try std.testing.expectEqual(ordinary.position, published.position);
    try std.testing.expectEqual(ordinary.count, published.count);
}
