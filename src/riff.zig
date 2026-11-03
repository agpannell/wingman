//! Borrowed RIFF containers and bounded chunk traversal, independent of their payload format. RIFF
//! identifies a form, such as WAVE or WEBP, whose chunks carry format-specific data. This module
//! handles RIFF and RIFX size fields, four-byte IDs, lists and word padding. It does not interpret
//! audio, images or RF64 directories. Views borrow immutable input; operations allocate nothing.
//! The declared container extent excludes trailing input. Each form decides whether to permit it.
//! https://learn.microsoft.com/en-us/windows/win32/multimedia/resource-interchange-file-format-services

const std = @import("std");
const testing = std.testing;

/// Four exact bytes, including significant spaces and case. No character normalization is applied.
pub const FourCc = [4]u8;

/// Malformed/truncated framing or a declared extent that cannot fit the selected address space.
pub const ParseError = error{ InvalidRiff, SizeOverflow };

/// A payload cannot fit a RIFF size field, or the supplied writer cannot complete its output.
pub const WriteError = error{SizeOverflow} || std.Io.Writer.Error;

/// Byte order of the container's size fields. Chunk IDs remain exact bytes.
pub const ByteOrder = std.builtin.Endian;

/// Selects RIFF little-endian or RIFX big-endian framing when writing.
pub const WriteOptions = struct {
    /// Use little endian for RIFF or big endian for RIFX size fields.
    byte_order: ByteOrder = .little,
};

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
    /// Byte order of the chunk header in its containing form.
    byte_order: ByteOrder = .little,

    /// Admits a RIFF, RIFX or LIST parent and returns its copied type and bounded child region.
    /// Child chunks inherit byte order and remain unchecked until iteration.
    pub fn list(self: Chunk) ParseError!List {
        const is_list = std.mem.eql(u8, self.id, "LIST");
        const is_riff = std.mem.eql(u8, self.id, "RIFF");
        const is_rifx = std.mem.eql(u8, self.id, "RIFX");
        if ((!is_list and !is_riff and !is_rifx) or self.data.len < 4) {
            return error.InvalidRiff;
        }
        return .{
            .list_type = self.data[0..4].*,
            .data = self.data[4..],
            .byte_order = self.byte_order,
        };
    }
};

/// A borrowed list's child bytes, excluding its four-byte list type.
pub const List = struct {
    /// Copied four-byte type from the beginning of the parent's payload.
    list_type: FourCc,
    /// Borrowed child region, excluding the type and the parent's outer padding.
    data: []const u8,
    /// Byte order for the size fields of this list’s child chunks.
    byte_order: ByteOrder = .little,

    /// Starts an independent bounded traversal without changing this view.
    pub fn iterator(self: List) ChunkIterator {
        return .{ .source = self.data, .byte_order = self.byte_order };
    }
};

/// Header-admitted RIFF form. Its source is the declared prefix, including its twelve-byte header.
/// Later chunks remain fallible during iteration; views survive iterator advancement.
pub const Container = struct {
    /// Borrowed declared prefix, including the complete twelve-byte form header.
    source: []const u8,
    /// Copied form identifier, such as WAVE or WEBP.
    form_type: FourCc,
    /// Byte order declared by RIFF or RIFX.
    byte_order: ByteOrder = .little,

    /// Starts an independent traversal of chunks inside the declared container extent.
    pub fn iterator(self: Container) ChunkIterator {
        return .{ .source = self.source[12..], .byte_order = self.byte_order };
    }
};

/// Reads one RIFF or RIFX header and bounds its declared prefix. Returns its byte order and form
/// type without interpreting the payload. Remaining input belongs to the caller.
pub fn parse(source: []const u8) ParseError!Container {
    if (source.len < 12) return error.InvalidRiff;
    const byte_order: ByteOrder = if (std.mem.eql(
        u8,
        source[0..4],
        "RIFF",
    )) .little else if (std.mem.eql(u8, source[0..4], "RIFX")) .big else return error.InvalidRiff;
    const size = std.mem.readInt(u32, source[4..8], byte_order);
    if (size < 4) return error.InvalidRiff;
    const bytes = std.math.cast(usize, size) orelse return error.SizeOverflow;
    const end = std.math.add(usize, 8, bytes) catch return error.SizeOverflow;
    if (end > source.len) return error.InvalidRiff;
    return .{ .source = source[0..end], .form_type = source[8..12].*, .byte_order = byte_order };
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

test "RIFX traversal inherits byte order through lists and preserves padding" {
    const bytes =
        "RIFX\x00\x00\x00\x22DEMOLIST\x00\x00\x00\x0eINFOxtra\x00\x00\x00\x01z\xa5ZERO\x00\x00" ++
        "\x00\x00";
    const form = try parse(bytes);
    try testing.expectEqual(.big, form.byte_order);
    var chunks = form.iterator();
    const list = try (try chunks.next()).?.list();
    try testing.expectEqualStrings("INFO", &list.list_type);
    var children = list.iterator();
    const child = (try children.next()).?;
    try testing.expectEqualStrings("xtra", child.id);
    try testing.expectEqualStrings("z", child.data);
    try testing.expectEqual(0xa5, child.padding.?);
    try testing.expectEqual(null, try children.next());
    try testing.expectEqualStrings("ZERO", (try chunks.next()).?.id);
    try testing.expectEqual(null, try chunks.next());
}

test "RIFX writers emit big-endian sizes and reject truncated children" {
    var bytes: [22]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    const options: WriteOptions = .{ .byte_order = .big };
    try writeHeader("DEMO".*, try chunkSize(1), &writer, options);
    try writeChunk("note".*, "x", &writer, options);
    try testing.expectEqualStrings("RIFX\x00\x00\x00\x0eDEMOnote\x00\x00\x00\x01x\x00", &bytes);
    const header = try readHeader(bytes[12..], .big);
    try testing.expectEqual(1, header.size);
    var chunks = (try parse(&bytes)).iterator();
    try testing.expectEqualStrings("x", (try chunks.next()).?.data);
    var truncated: ChunkIterator = .{ .source = "note\x00\x00\x00\x01x", .byte_order = .big };
    try testing.expectError(error.InvalidRiff, truncated.next());
    try testing.expectEqual(0, truncated.offset);
    var resolved: ChunkIterator = .{ .source = "note\xff\xff\xff\xffx\x00", .byte_order = .big };
    const oversized_error: ParseError = if (@sizeOf(
        usize,
    ) == 4) error.SizeOverflow else error.InvalidRiff;
    try testing.expectError(oversized_error, resolved.next());
    try testing.expectEqual(0, resolved.offset);
    try testing.expectEqualStrings("x", (try resolved.nextResolved(1)).?.data);
    try testing.expectEqual(null, try resolved.next());
}

test "nested form views retain the enclosing byte order" {
    const body = "DEMOdata\x00\x00\x00\x01x\x00";
    for ([_][]const u8{ "RIFF", "RIFX", "LIST" }) |id| {
        const view = try (Chunk{ .id = id, .data = body, .byte_order = .big }).list();
        var children = view.iterator();
        try testing.expectEqualStrings("x", (try children.next()).?.data);
        try testing.expectEqual(null, try children.next());
    }
}

/// Reads copied header fields in the supplied byte order; does not admit the payload extent.
pub fn readHeader(source: []const u8, byte_order: ByteOrder) ParseError!ChunkHeader {
    if (source.len < 8) return error.InvalidRiff;
    return .{ .id = source[0..4].*, .size = std.mem.readInt(u32, source[4..8], byte_order) };
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
    /// Byte order for the headers in source.
    byte_order: ByteOrder = .little,

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
        const header = try readHeader(remaining, self.byte_order);
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
            .byte_order = self.byte_order,
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

/// Writes a twelve-byte RIFF or RIFX header. `body_bytes` counts all encoded child chunks,
/// including headers and padding, but excludes the form type. Size refusal precedes writing.
pub fn writeHeader(
    form_type: FourCc,
    body_bytes: usize,
    writer: *std.Io.Writer,
    options: WriteOptions,
) WriteError!void {
    const bytes = std.math.add(usize, 4, body_bytes) catch return error.SizeOverflow;
    const size = std.math.cast(u32, bytes) orelse return error.SizeOverflow;
    try writer.writeAll(if (options.byte_order == .little) "RIFF" else "RIFX");
    try writer.writeInt(u32, size, options.byte_order);
    try writer.writeAll(&form_type);
}

/// Writes one eight-byte header in the selected byte order. The caller must then write exactly the
/// payload and padding. Writer failure may leave a prefix; no data or allocation is retained.
pub fn writeChunkHeader(
    id: FourCc,
    payload_bytes: usize,
    writer: *std.Io.Writer,
    options: WriteOptions,
) WriteError!void {
    _ = try chunkSize(payload_bytes);
    try writer.writeAll(&id);
    try writer.writeInt(u32, @intCast(payload_bytes), options.byte_order);
}

/// Writes one complete chunk and zero padding. Payload and writer storage must be disjoint. Size
/// refusal precedes output; writer failure may leave a prefix. The caller owns flushing.
pub fn writeChunk(
    id: FourCc,
    source: []const u8,
    writer: *std.Io.Writer,
    options: WriteOptions,
) WriteError!void {
    try writeChunkHeader(id, source.len, writer, options);
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
    try writeHeader("TEST".*, try chunkSize(1), &writer, .{});
    try writeChunk("raw ".*, "x", &writer, .{});
    try testing.expectEqualStrings("RIFF\x0e\x00\x00\x00TESTraw \x01\x00\x00\x00x\x00", &output);
    const form = try parse(&output);
    var chunks = form.iterator();
    const chunk = (try chunks.next()).?;
    try testing.expectEqualStrings("raw ", chunk.id);
    try testing.expectEqualStrings("x", chunk.data);
    try testing.expectEqual(0, chunk.padding.?);
    try testing.expectError(error.InvalidRiff, parse("RIFF\x03\x00\x00\x00TEST"));
    try testing.expectError(error.InvalidRiff, parse("RIFF\x05\x00\x00\x00TEST"));
    try testing.expectError(error.InvalidRiff, parse("RIFX\x00\x00\x00\x03TEST"));
}

test readHeader {
    var bytes = [_]u8{ 0, 0xff, ' ', 'a', 0x78, 0x56, 0x34, 0x12 };
    const header = try readHeader(&bytes, .little);
    @memset(&bytes, 0);
    try testing.expectEqual(FourCc{ 0, 0xff, ' ', 'a' }, header.id);
    try testing.expectEqual(0x12345678, header.size);
}

test writeChunk {
    var bytes: [10]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writeChunk("note".*, "x", &writer, .{});
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

test "RIFF and RIFX fixed writer failures preserve guards and an honest output prefix" {
    const cases = [_]struct {
        bytes: []const u8,
        options: WriteOptions,
    }{
        .{ .bytes = "RIFF\x0e\x00\x00\x00TESTnote\x01\x00\x00\x00x\x00", .options = .{} },
        .{
            .bytes = "RIFX\x00\x00\x00\x0eTESTnote\x00\x00\x00\x01x\x00",
            .options = .{ .byte_order = .big },
        },
    };
    for (cases) |case| {
        for (0..case.bytes.len + 1) |capacity| {
            const expected = case.bytes;
            var storage: [24]u8 = @splat(0xa7);
            var writer: std.Io.Writer = .fixed(storage[1..][0..capacity]);
            const result = writeHeader("TEST".*, try chunkSize(1), &writer, case.options);
            if (result) |_| {
                if (writeChunk("note".*, "x", &writer, case.options)) |_| {
                    try testing.expectEqual(expected.len, capacity);
                } else |err| try testing.expectEqual(error.WriteFailed, err);
            } else |err| try testing.expectEqual(error.WriteFailed, err);
            try testing.expectEqualStrings(expected[0..writer.buffered().len], writer.buffered());
            try testing.expect(std.mem.allEqual(u8, storage[0..1], 0xa7));
            try testing.expect(std.mem.allEqual(u8, storage[1 + capacity ..], 0xa7));
            if (capacity == expected.len) try testing.expectEqualStrings(
                expected,
                writer.buffered(),
            );
        }
    }
}

test "RIFF size and address-space refusals happen before output" {
    var bytes: [16]u8 = @splat(0xa7);
    var writer: std.Io.Writer = .fixed(&bytes);
    try testing.expectError(
        error.SizeOverflow,
        writeHeader("TEST".*, std.math.maxInt(usize), &writer, .{}),
    );
    try testing.expectError(
        error.SizeOverflow,
        writeChunkHeader("data".*, std.math.maxInt(usize), &writer, .{}),
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
