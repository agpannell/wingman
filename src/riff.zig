//! Borrowed RIFF containers and bounded chunk traversal, independent of their payload format. RIFF
//! identifies a form, such as WAVE or WEBP, whose chunks carry format-specific data. This module
//! handles little-endian sizes, four-byte IDs, lists and word padding. It does not interpret audio,
//! images or RF64 directories. Views borrow immutable input; operations allocate nothing. The
//! declared container extent excludes trailing input. Each form decides whether to permit it.
//! https://learn.microsoft.com/en-us/windows/win32/multimedia/resource-interchange-file-format-services

const std = @import("std");
const testing = std.testing;

/// Four exact bytes, including significant spaces and case. No character normalization is applied.
pub const FourCc = [4]u8;

/// Malformed/truncated framing or a declared extent that cannot fit the selected address space.
pub const ParseError = error{ InvalidRiff, SizeOverflow };

/// A payload cannot fit a RIFF size field, or the supplied writer cannot complete its output.
pub const WriteError = error{SizeOverflow} || std.Io.Writer.Error;

/// Copied fields from one eight-byte chunk header. The size excludes header bytes and padding.
pub const ChunkHeader = struct { id: FourCc, size: u32 };

/// One borrowed payload. Its padding byte is exposed separately so a form can enforce its value.
pub const Chunk = struct {
    /// Four ID bytes borrowing the source.
    id: []const u8,
    /// Borrowed encoded payload, excluding header and padding.
    data: []const u8,
    /// Present for odd payload sizes. Framing validates its presence without constraining its
    /// value.
    padding: ?u8 = null,

    /// Admits a RIFF/LIST parent and returns its copied type and bounded child region. Child chunks
    /// remain unchecked until iteration. No recursive traversal or allocation occurs.
    pub fn list(self: Chunk) ParseError!List {
        if ((!std.mem.eql(
            u8,
            self.id,
            "LIST",
        ) and !std.mem.eql(u8, self.id, "RIFF")) or self.data.len < 4) return error.InvalidRiff;
        return .{ .list_type = self.data[0..4].*, .data = self.data[4..] };
    }
};

/// A borrowed list's child bytes, excluding its four-byte list type.
pub const List = struct {
    /// Copied four-byte type from the beginning of the parent's payload.
    list_type: FourCc,
    /// Borrowed child region, excluding the type and the parent's outer padding.
    data: []const u8,

    /// Starts an independent bounded traversal without changing this view.
    pub fn iterator(self: List) ChunkIterator {
        return .{ .source = self.data };
    }
};

/// Header-admitted RIFF form. Its source is the declared prefix, including its twelve-byte header.
/// Later chunks remain fallible during iteration; views survive iterator advancement.
pub const Container = struct {
    /// Borrowed declared prefix, including the complete twelve-byte form header.
    source: []const u8,
    /// Copied form identifier, such as WAVE or WEBP.
    form_type: FourCc,

    /// Starts an independent traversal of chunks inside the declared container extent.
    pub fn iterator(self: Container) ChunkIterator {
        return .{ .source = self.source[12..] };
    }
};

/// Reads one RIFF header and bounds its declared prefix. Returns its form type without interpreting
/// it. `result.source.len` is the consumed byte count; remaining input belongs to the caller.
pub fn parse(source: []const u8) ParseError!Container {
    if (source.len < 12 or !std.mem.eql(u8, source[0..4], "RIFF")) return error.InvalidRiff;
    const size = std.mem.readInt(u32, source[4..8], .little);
    if (size < 4) return error.InvalidRiff;
    const bytes = std.math.cast(usize, size) orelse return error.SizeOverflow;
    const end = std.math.add(usize, 8, bytes) catch return error.SizeOverflow;
    if (end > source.len) return error.InvalidRiff;
    return .{ .source = source[0..end], .form_type = source[8..12].* };
}

test parse {
    const bytes = "RIFF\x10\x00\x00\x00WEBPVP8 \x03\x00\x00\x00abc\x00tail";
    const container = try parse(bytes);
    try testing.expectEqualStrings("WEBP", &container.form_type);
    try testing.expectEqual(24, container.source.len);
    var chunks = container.iterator();
    const chunk = (try chunks.next()).?;
    try testing.expectEqualStrings("VP8 ", chunk.id);
    try testing.expectEqualStrings("abc", chunk.data);
    try testing.expectEqual(0, chunk.padding.?);
    try testing.expectEqual(null, try chunks.next());
}

/// Reads copied header fields from the beginning of a span; does not admit its payload extent.
pub fn readHeader(source: []const u8) ParseError!ChunkHeader {
    if (source.len < 8) return error.InvalidRiff;
    return .{ .id = source[0..4].*, .size = std.mem.readInt(u32, source[4..8], .little) };
}

/// One bounded traversal. Initialize with `.source = child_bytes` after skipping any form-specific
/// payload header. Keep the source immutable. Failure preserves the cursor, permitting a retry with
/// a corrected externally resolved size. Malformed source needs a new valid source/traversal. No
/// implicit recursion, allocation or external state is used.
pub const ChunkIterator = struct {
    /// Complete borrowed region containing encoded child chunks.
    source: []const u8,
    /// Current chunk-header offset; source.len denotes the exact end.
    offset: usize = 0,

    /// Returns the next padded chunk or null at the exact end of this region.
    pub fn next(self: *ChunkIterator) ParseError!?Chunk {
        return self.nextSized(null);
    }

    /// Uses an externally resolved payload size, for example an RF64 adapter's directory result.
    /// This admits geometry only; the caller owns the replacement-size rules and directory state.
    pub fn nextResolved(self: *ChunkIterator, payload_bytes: u64) ParseError!?Chunk {
        return self.nextSized(payload_bytes);
    }

    fn nextSized(self: *ChunkIterator, resolved: ?u64) ParseError!?Chunk {
        if (self.offset == self.source.len) return null;
        if (self.offset > self.source.len) return error.InvalidRiff;
        const remaining = self.source[self.offset..];
        const header = try readHeader(remaining);
        const bytes = std.math.cast(
            usize,
            resolved orelse header.size,
        ) orelse return error.SizeOverflow;
        const end = std.math.add(usize, 8, bytes) catch return error.SizeOverflow;
        const padded = std.math.add(usize, end, bytes & 1) catch return error.SizeOverflow;
        if (padded > remaining.len) return error.InvalidRiff;
        self.offset += padded;
        return .{
            .id = remaining[0..4],
            .data = remaining[8..end],
            .padding = if (bytes & 1 != 0) remaining[end] else null,
        };
    }
};

/// Returns a chunk's complete encoded extent, including its header and required padding. The
/// payload must fit a 32-bit RIFF field; address-space overflow is checked independently.
pub fn chunkSize(payload_bytes: usize) error{SizeOverflow}!usize {
    _ = std.math.cast(u32, payload_bytes) orelse return error.SizeOverflow;
    const end = std.math.add(usize, 8, payload_bytes) catch return error.SizeOverflow;
    return std.math.add(usize, end, payload_bytes & 1) catch error.SizeOverflow;
}

/// Writes a twelve-byte RIFF header. `body_bytes` counts all encoded child chunks, including their
/// headers and padding, but excludes the form type. Size refusal precedes writing.
pub fn writeHeader(form_type: FourCc, body_bytes: usize, writer: *std.Io.Writer) WriteError!void {
    const bytes = std.math.add(usize, 4, body_bytes) catch return error.SizeOverflow;
    const size = std.math.cast(u32, bytes) orelse return error.SizeOverflow;
    try writer.writeAll("RIFF");
    try writer.writeInt(u32, size, .little);
    try writer.writeAll(&form_type);
}

/// Writes one eight-byte header. The caller must then write exactly the payload and its padding.
/// Writer failure may leave a prefix; no data or allocation is retained.
pub fn writeChunkHeader(id: FourCc, payload_bytes: usize, writer: *std.Io.Writer) WriteError!void {
    _ = try chunkSize(payload_bytes);
    try writer.writeAll(&id);
    try writer.writeInt(u32, @intCast(payload_bytes), .little);
}

/// Writes one complete chunk and zero padding. Payload and writer storage must be disjoint. Size
/// refusal precedes output; writer failure may leave a prefix. The caller owns flushing.
pub fn writeChunk(id: FourCc, source: []const u8, writer: *std.Io.Writer) WriteError!void {
    try writeChunkHeader(id, source.len, writer);
    try writer.writeAll(source);
    if (source.len & 1 != 0) try writer.writeByte(0);
}

test "bounded lists preserve exact IDs padding and child extents" {
    const bytes = "LIST\x0e\x00\x00\x00INFOaBc \x01\x00\x00\x00x\xa5NEXT\x00\x00\x00\x00";
    var outer: ChunkIterator = .{ .source = bytes };
    const parent = (try outer.next()).?;
    const view = try parent.list();
    try testing.expectEqualStrings("INFO", &view.list_type);
    var children = view.iterator();
    const child = (try children.next()).?;
    try testing.expectEqualStrings("aBc ", child.id);
    try testing.expectEqual(0xa5, child.padding.?);
    try testing.expectEqual(null, try children.next());
    try testing.expectEqualStrings("NEXT", (try outer.next()).?.id);
    try testing.expectEqual(null, try outer.next());
}

test "truncated and resolved chunk extents refuse without advancing" {
    const malformed = [_][]const u8{ "x", "ABCD\x02\x00\x00\x00x", "ABCD\x01\x00\x00\x00x" };
    for (malformed) |bytes| {
        var chunks: ChunkIterator = .{ .source = bytes };
        try testing.expectError(error.InvalidRiff, chunks.next());
        try testing.expectEqual(0, chunks.offset);
    }
    var resolved: ChunkIterator = .{ .source = "ABCD\xff\xff\xff\xffx\x00" };
    try testing.expectError(error.SizeOverflow, resolved.nextResolved(std.math.maxInt(u64)));
    try testing.expectEqual(0, resolved.offset);
    try testing.expectEqualStrings("x", (try resolved.nextResolved(1)).?.data);
    try testing.expectEqual(null, try resolved.next());
}

test "headers and writing share checked RIFF framing" {
    var output: [22]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try writeHeader("TEST".*, try chunkSize(1), &writer);
    try writeChunk("raw ".*, "x", &writer);
    try testing.expectEqualStrings("RIFF\x0e\x00\x00\x00TESTraw \x01\x00\x00\x00x\x00", &output);
    const form = try parse(&output);
    var chunks = form.iterator();
    const chunk = (try chunks.next()).?;
    try testing.expectEqualStrings("raw ", chunk.id);
    try testing.expectEqualStrings("x", chunk.data);
    try testing.expectEqual(0, chunk.padding.?);
    try testing.expectError(error.InvalidRiff, parse("RIFF\x03\x00\x00\x00TEST"));
    try testing.expectError(error.InvalidRiff, parse("RIFF\x05\x00\x00\x00TEST"));
    try testing.expectError(error.InvalidRiff, parse("RIFX\x00\x00\x00\x04TEST"));
}

test readHeader {
    var bytes = [_]u8{ 0, 0xff, ' ', 'a', 0x78, 0x56, 0x34, 0x12 };
    const header = try readHeader(&bytes);
    @memset(&bytes, 0);
    try testing.expectEqual(FourCc{ 0, 0xff, ' ', 'a' }, header.id);
    try testing.expectEqual(0x12345678, header.size);
}

test writeChunk {
    var bytes: [10]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writeChunk("note".*, "x", &writer);
    try testing.expectEqualStrings("note\x01\x00\x00\x00x\x00", writer.buffered());
}

test "RIFF outer admission leaves malformed children lazy and trailing bytes outside" {
    const bytes = "RIFF\x05\x00\x00\x00TESTxignored";
    const form = try parse(bytes);
    try testing.expectEqualStrings("TEST", &form.form_type);
    try testing.expectEqual(13, form.source.len);
    var chunks = form.iterator();
    try testing.expectError(error.InvalidRiff, chunks.next());
    try testing.expectEqual(0, chunks.offset);
    for (0..form.source.len) |cut| {
        try testing.expectError(error.InvalidRiff, parse(bytes[0..cut]));
    }
    try testing.expectError(error.InvalidRiff, parse("RF64\x04\x00\x00\x00TEST"));
    try testing.expectError(error.InvalidRiff, (Chunk{ .id = "data", .data = "INFO" }).list());
    try testing.expectError(error.InvalidRiff, (Chunk{ .id = "LIST", .data = "INF" }).list());
}

test "RIFF borrowed chunks survive independent iterator advancement" {
    const bytes = "aBc \x01\x00\x00\x00x\xa5ZERO\x00\x00\x00\x00";
    var chunks: ChunkIterator = .{ .source = bytes };
    var independent = chunks;
    const first = (try chunks.next()).?;
    try testing.expectEqualStrings("aBc ", first.id);
    try testing.expectEqual(0xa5, first.padding.?);
    try testing.expectEqual(bytes[0..4].ptr, first.id.ptr);
    try testing.expectEqual(bytes[8..9].ptr, first.data.ptr);
    const empty = (try chunks.next()).?;
    try testing.expectEqualStrings("ZERO", empty.id);
    try testing.expectEqual(0, empty.data.len);
    try testing.expectEqual(null, empty.padding);
    try testing.expectEqual(bytes.len, chunks.offset);
    try testing.expectEqual(null, try chunks.next());
    try testing.expectEqualStrings("x", first.data);
    try testing.expectEqualStrings("aBc ", (try independent.next()).?.id);
}

test "RIFF fixed writer failures preserve guards and an honest output prefix" {
    const expected = "RIFF\x0e\x00\x00\x00TESTnote\x01\x00\x00\x00x\x00";
    for (0..expected.len + 1) |capacity| {
        var storage: [expected.len + 2]u8 = @splat(0xa7);
        var writer: std.Io.Writer = .fixed(storage[1..][0..capacity]);
        const result = writeHeader("TEST".*, try chunkSize(1), &writer);
        if (result) |_| {
            if (writeChunk("note".*, "x", &writer)) |_| {
                try testing.expectEqual(expected.len, capacity);
            } else |err| try testing.expectEqual(error.WriteFailed, err);
        } else |err| try testing.expectEqual(error.WriteFailed, err);
        try testing.expectEqualStrings(expected[0..writer.buffered().len], writer.buffered());
        try testing.expect(std.mem.allEqual(u8, storage[0..1], 0xa7));
        try testing.expect(std.mem.allEqual(u8, storage[1 + capacity ..], 0xa7));
        if (capacity == expected.len) try testing.expectEqualStrings(expected, writer.buffered());
    }
}

test "RIFF size and address-space refusals happen before output" {
    var bytes: [16]u8 = @splat(0xa7);
    var writer: std.Io.Writer = .fixed(&bytes);
    try testing.expectError(
        error.SizeOverflow,
        writeHeader("TEST".*, std.math.maxInt(usize), &writer),
    );
    try testing.expectError(
        error.SizeOverflow,
        writeChunkHeader("data".*, std.math.maxInt(usize), &writer),
    );
    try testing.expectEqual(0, writer.buffered().len);
    try testing.expect(std.mem.allEqual(u8, &bytes, 0xa7));
    try testing.expectEqual(8, try chunkSize(0));
    try testing.expectEqual(10, try chunkSize(1));
    if (@bitSizeOf(usize) > 32) {
        try testing.expectEqual(@as(usize, 0x1_0000_0008), try chunkSize(0xffffffff));
        try testing.expectError(error.SizeOverflow, chunkSize(0x1_0000_0000));
    } else {
        try testing.expectError(error.SizeOverflow, chunkSize(0xffffffff));
    }
}

test "RIFF externally resolved lengths preserve the failed cursor and exact end" {
    const bytes = "data\xff\xff\xff\xffx\x00";
    var chunks: ChunkIterator = .{ .source = bytes };
    try testing.expectError(error.InvalidRiff, chunks.nextResolved(3));
    try testing.expectEqual(0, chunks.offset);
    const chunk = (try chunks.nextResolved(1)).?;
    try testing.expectEqualStrings("x", chunk.data);
    try testing.expectEqual(0, chunk.padding.?);
    try testing.expectEqual(null, try chunks.nextResolved(std.math.maxInt(u64)));
    chunks.offset += 1;
    const failed_offset = chunks.offset;
    try testing.expectError(error.InvalidRiff, chunks.next());
    try testing.expectEqual(failed_offset, chunks.offset);
}
