//! Bounded PNG chunk framing, payload writers and CRC completion.

const std = @import("std");

const Crc32 = @import("../crc.zig").Crc32IsoHdlc;

const FramingError = error{ InvalidChunkType, ChunkTooLarge, OutputTooSmall };

/// Invalid chunk declarations, bounded destination failures and incomplete payloads.
pub const Error = std.Io.Writer.Error || FramingError || error{
    IncompletePayload,
    PayloadComplete,
};

/// Small address-stable writer for one payload within a declared capacity.
const ChunkWriter = @This();

/// Borrowed Writer for payload bytes; use only between successful init and finish.
writer: std.Io.Writer,
/// Private bounded buffering, including DEFLATE's eight-byte lookahead.
buffer: [64]u8,
/// Private exact chunk span, borrowed through finish.
destination: []u8,
/// Private count of payload bytes already drained.
produced: usize,
/// Private checksum over chunk name and drained payload bytes.
crc: Crc32,
/// Private finalization discriminator.
complete: bool,

/// Checks type, PNG length and complete destination capacity before writing the header. Keep this
/// owner at this address and destination live until finish; no allocator is retained.
pub fn init(self: *ChunkWriter, destination: []u8, name: *const [4]u8, count: usize) Error!void {
    const chunk_name = name.*;
    try validateType(&chunk_name);
    const required = try byteCount(count);
    if (destination.len < required) return error.OutputTooSmall;
    self.destination = destination[0..required];
    self.produced = 0;
    self.complete = false;
    self.crc = Crc32.init();
    self.crc.update(&chunk_name);
    self.writer = .{ .buffer = &self.buffer, .vtable = &.{ .drain = drain } };
    std.mem.writeInt(u32, self.destination[0..4], @intCast(count), .big);
    @memcpy(self.destination[4..8], &chunk_name);
}

/// Flushes payload bytes and writes CRC only when the complete declared count was supplied. Returns
/// this chunk's exact byte count. Failure may leave a prefix; complete prevents reuse.
pub fn finish(self: *ChunkWriter) Error!usize {
    if (self.complete) return error.PayloadComplete;
    try self.writer.flush();
    if (self.produced != self.destination.len - 12) return error.IncompletePayload;
    std.mem.writeInt(
        u32,
        self.destination[self.destination.len - 4 ..][0..4],
        self.crc.final(),
        .big,
    );
    self.complete = true;
    return self.destination.len;
}

/// Flushes a complete shorter payload, replacing the capacity header with its actual size. Returns
/// bytes used, leaving the unused tail reusable by subsequent chunks. The reserved destination
/// remains borrowed through this call; failure may leave a prefix. Use finish when an exact payload
/// declaration must be enforced rather than shortened.
pub fn finishPrefix(self: *ChunkWriter) Error!usize {
    if (self.complete) return error.PayloadComplete;
    try self.writer.flush();
    std.mem.writeInt(u32, self.destination[0..4], @intCast(self.produced), .big);
    std.mem.writeInt(u32, self.destination[8 + self.produced ..][0..4], self.crc.final(), .big);
    self.complete = true;
    return self.produced + 12;
}

fn copy(self: *ChunkWriter, bytes: []const u8) std.Io.Writer.Error!void {
    const maximum = self.destination.len - 12;
    if (self.complete or bytes.len > maximum - self.produced) return error.WriteFailed;
    const out = self.destination[8 + self.produced ..][0..bytes.len];
    if (out.ptr != bytes.ptr) @memcpy(out, bytes);
    self.crc.update(bytes);
    self.produced += bytes.len;
}

fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *ChunkWriter = @fieldParentPtr("writer", writer);
    try self.copy(writer.buffered());
    writer.end = 0;
    var consumed: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        try self.copy(bytes);
        consumed += bytes.len;
    }
    const last = data[data.len - 1];
    if (last.len == 0) return consumed;
    for (0..splat) |_| try self.copy(last);
    return consumed + last.len * splat;
}

/// Data-stream policy, sequence and bounded chunk-emission failures.
pub const DataChunkWriteError = Error || error{ InvalidDataChunkSize, SequenceOverflow };

/// Exact nonempty data-record count for a compressed byte length and selected chunk limit. Empty
/// streams still own one record. Limits count compressed bytes, excluding fdAT sequence words; wire
/// length admission reserves those four bytes when sequenced is true.
pub fn dataRecordCount(
    length: usize,
    limit: usize,
    sequenced: bool,
) error{InvalidDataChunkSize}!usize {
    const maximum: usize = if (sequenced) 0x7fff_fffb else 0x7fff_ffff;
    if (limit == 0 or limit > maximum) return error.InvalidDataChunkSize;
    return if (length == 0) 1 else (length - 1) / limit + 1;
}

// Streaming chunk boundaries depend only on compressed byte count and selected capacity. Prefix
// completion shortens the final chunk, so count/replay needs no per-frame size array.
/// Address-stable bounded IDAT/fdAT stream over unpublished caller storage. Construct at self and
/// keep destination and optional sequence counter live until finish. No allocation occurs. Write
/// failures may leave a prefix; complete image writers own publication and rollback. This owner
/// retains only synchronous destination/counter borrows.
pub const DataStream = struct {
    /// Compressed-data writer, borrowed only between init and successful finish.
    writer: std.Io.Writer,
    /// Private bounded buffering; the owner stays at the address adopted by writer.
    buffer: [64]u8,
    /// Private borrowed destination through finalization.
    destination: []u8,
    /// Private finalized chunk byte prefix.
    offset: usize,
    /// Admitted compressed-data limit per record, excluding sequence words.
    limit: usize,
    /// Borrowed fdAT counter; null selects IDAT.
    sequence: ?*u64,
    /// Private current payload owner at its final nested address.
    chunk_writer: ChunkWriter,
    /// Whether one payload remains open.
    current: bool,
    /// Current compressed-data capacity, excluding sequence bytes.
    capacity: usize,
    /// Compressed bytes drained into the current payload.
    data_bytes: usize,
    /// Whether any complete or shortened record has been finalized.
    emitted: bool,

    /// Finalized data records, including a shortened or empty final record.
    record_count: usize,
    /// Finalized compressed bytes, excluding chunk framing and fdAT sequence words.
    compressed_bytes: usize,

    /// Admits a nonzero compressed-data chunk limit, then binds final caller storage. Null sequence
    /// emits IDAT; a counter emits fdAT with four additional sequence bytes. Invalid limits leave
    /// destination, counter and owner unchanged.
    pub fn init(
        self: *DataStream,
        destination: []u8,
        limit: usize,
        sequence: ?*u64,
    ) DataChunkWriteError!void {
        _ = try dataRecordCount(0, limit, sequence != null);
        self.destination = destination;
        self.offset = 0;
        self.limit = limit;
        self.sequence = sequence;
        self.current = false;
        self.emitted = false;
        self.record_count = 0;
        self.compressed_bytes = 0;
        self.writer = .{ .buffer = &self.buffer, .vtable = &.{ .drain = DataStream.drain } };
    }

    fn begin(self: *DataStream) DataChunkWriteError!void {
        const prefix: usize = if (self.sequence != null) 4 else 0;
        if (self.offset > self.destination.len or self.destination.len - self.offset < 12 + prefix)
            return error.OutputTooSmall;
        self.capacity = @min(self.limit, self.destination.len - self.offset - 12 - prefix);
        try self.chunk_writer.init(
            self.destination[self.offset..],
            if (prefix == 0) "IDAT" else "fdAT",
            self.capacity + prefix,
        );
        if (self.sequence) |sequence| {
            var word: [4]u8 = undefined;
            std.mem.writeInt(u32, &word, try nextSequence(sequence), .big);
            try self.chunk_writer.writer.writeAll(&word);
        }
        self.data_bytes = 0;
        self.current = true;
    }

    fn copy(self: *DataStream, bytes: []const u8) std.Io.Writer.Error!void {
        var remaining = bytes;
        while (remaining.len != 0) {
            if (!self.current) self.begin() catch return error.WriteFailed;
            const count = @min(self.capacity - self.data_bytes, remaining.len);
            if (count == 0) return error.WriteFailed;
            try self.chunk_writer.writer.writeAll(remaining[0..count]);
            self.data_bytes += count;
            remaining = remaining[count..];
            if (self.data_bytes == self.capacity) {
                self.offset += self.chunk_writer.finish() catch return error.WriteFailed;
                self.record_count += 1;
                self.compressed_bytes += self.data_bytes;
                self.current = false;
                self.emitted = true;
            }
        }
    }

    /// Flushes and seals the used prefix, shortening a final partial chunk. Empty input emits one
    /// empty data record. Repeated finish preserves bytes and sequence state.
    pub fn finish(self: *DataStream) DataChunkWriteError!usize {
        try self.writer.flush();
        if (!self.current and !self.emitted) try self.begin();
        if (self.current) {
            self.offset += try self.chunk_writer.finishPrefix();
            self.record_count += 1;
            self.compressed_bytes += self.data_bytes;
            self.current = false;
            // A shortened final chunk counts as emission, including an empty stream.
            self.emitted = true;
        }
        return self.offset;
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *DataStream = @fieldParentPtr("writer", writer);
        try self.copy(writer.buffered());
        writer.end = 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.copy(bytes);
            consumed += bytes.len;
        }
        const last = data[data.len - 1];
        if (last.len == 0) return consumed;
        for (0..splat) |_| try self.copy(last);
        return consumed + last.len * splat;
    }
};

/// Returns and advances one PNG 31-bit sequence value. Overflow preserves the counter.
pub fn nextSequence(sequence: *u64) error{SequenceOverflow}!u32 {
    if (sequence.* > 0x7fffffff) return error.SequenceOverflow;
    const value: u32 = @intCast(sequence.*);
    sequence.* += 1;
    return value;
}

/// Checked complete framing size for a PNG payload, including length/name/CRC.
pub fn byteCount(payload_count: usize) error{ChunkTooLarge}!usize {
    if (payload_count > 0x7fffffff) return error.ChunkTooLarge;
    return std.math.add(usize, payload_count, 12) catch error.ChunkTooLarge;
}

/// Appends disjoint immutable parts as one chunk and advances offset only after complete CRC. Each
/// part may already occupy its exact final payload range; arbitrary overlap is forbidden. Invalid
/// type, length or capacity preserves destination and offset. No storage is allocated.
pub fn appendParts(
    destination: []u8,
    offset: *usize,
    name: *const [4]u8,
    parts: []const []const u8,
) FramingError!void {
    var count: usize = 0;
    for (parts) |part| {
        count = std.math.add(usize, count, part.len) catch return error.ChunkTooLarge;
    }
    if (offset.* > destination.len) return error.OutputTooSmall;
    const chunk_name = name.*;
    try validateType(&chunk_name);
    const required = try byteCount(count);
    if (destination.len - offset.* < required) return error.OutputTooSmall;
    const chunk = destination[offset.*..][0..required];
    std.mem.writeInt(u32, chunk[0..4], @intCast(count), .big);
    @memcpy(chunk[4..8], &chunk_name);
    var crc = Crc32.init();
    crc.update(&chunk_name);
    var position: usize = 8;
    for (parts) |part| {
        const output = chunk[position..][0..part.len];
        if (output.ptr != part.ptr) @memcpy(output, part);
        crc.update(part);
        position += part.len;
    }
    std.mem.writeInt(u32, chunk[position..][0..4], crc.final(), .big);
    offset.* += required;
}

/// Appends one borrowed payload with the same capacity/overlap/publication contract as appendParts.
pub fn append(
    destination: []u8,
    offset: *usize,
    name: *const [4]u8,
    data: []const u8,
) FramingError!void {
    return appendParts(destination, offset, name, &.{data});
}

/// Appends the fixed empty IEND chunk, publishing the new offset only after admission.
pub fn appendEnd(destination: []u8, offset: *usize) error{OutputTooSmall}!void {
    const wire = [_]u8{ 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82 };
    if (offset.* > destination.len or destination.len - offset.* < wire.len)
        return error.OutputTooSmall;
    @memcpy(destination[offset.*..][0..wire.len], &wire);
    offset.* += wire.len;
}

fn validateType(name: *const [4]u8) error{InvalidChunkType}!void {
    for (name) |byte| if (!std.ascii.isAlphabetic(byte)) return error.InvalidChunkType;
    if (!std.ascii.isUpper(name[2])) return error.InvalidChunkType;
}

/// Sums payload bytes in a complete sequence of admitted or just-emitted PNG chunks. No signature
/// is included. Framing is already valid and remains unchanged through this query. This supports
/// actual ancillary-byte accounting without re-reading payloads or checking CRCs.
pub fn payloadByteCount(framed: []const u8) usize {
    var offset: usize = 0;
    var total: usize = 0;
    while (offset != framed.len) {
        const count = std.mem.readInt(u32, framed[offset..][0..4], .big);
        total += count;
        offset += 12 + @as(usize, count);
        std.debug.assert(offset <= framed.len);
    }
    return total;
}

test "PNG data stream refuses invalid capacities before changing initialized storage" {
    var destination: [40]u8 = @splat(0xa5);
    var sequence: u64 = 17;
    var stream: DataStream = undefined;
    try stream.init(&destination, 13, &sequence);
    for ([_]usize{ 0, 0x7fff_fffc, std.math.maxInt(usize) }) |limit| {
        try std.testing.expectError(
            error.InvalidDataChunkSize,
            stream.init(&destination, limit, &sequence),
        );
        try std.testing.expectEqual(17, sequence);
        try std.testing.expectEqual(13, stream.limit);
        try std.testing.expectEqual(0, stream.offset);
        try std.testing.expect(!stream.current and !stream.emitted);
        try std.testing.expectEqual(@as(?*u64, &sequence), stream.sequence);
        try std.testing.expectEqualSlices(u8, &@as([40]u8, @splat(0xa5)), &destination);
    }
    try std.testing.expectError(
        error.InvalidDataChunkSize,
        stream.init(&destination, 0x8000_0000, null),
    );
    try stream.writer.writeAll("A");
    try std.testing.expectEqual(17, try stream.finish());
    try std.testing.expectEqual(18, sequence);
    try std.testing.expectEqualStrings("fdAT", destination[4..8]);
    try std.testing.expectEqual('A', destination[12]);
}

// Independent literal PNG/APNG data-chunk framing expectations. CRCs and framing were calculated
// with Python's zlib 1.3.2 CRC32, network-order field packing and the PNG Third Edition
// chunk/sequence rules, independently of the production checksum, payload writer and APNG encoder.
// No assertion suite or production declarations contribute to these facts.

const testing_data_chunks = struct {
    /// abcde split into IDAT payloads ab/cd/e, with complete framing.
    pub const idat_chunks = &[_]u8{
        0x00, 0x00, 0x00, 0x02, 0x49, 0x44, 0x41, 0x54,
        0x61, 0x62, 0xa3, 0xa1, 0xe7, 0x28, 0x00, 0x00,
        0x00, 0x02, 0x49, 0x44, 0x41, 0x54, 0x63, 0x64,
        0x78, 0xf4, 0x20, 0x9f, 0x00, 0x00, 0x00, 0x01,
        0x49, 0x44, 0x41, 0x54, 0x65, 0x15, 0xe0, 0xe8,
        0x3f,
    };

    /// abcde split into fdAT payloads ab/cd/e at sequence numbers seven through nine.
    pub const fdat_chunks = &[_]u8{
        0x00, 0x00, 0x00, 0x06, 0x66, 0x64, 0x41, 0x54,
        0x00, 0x00, 0x00, 0x07, 0x61, 0x62, 0xd6, 0x44,
        0x8f, 0x29, 0x00, 0x00, 0x00, 0x06, 0x66, 0x64,
        0x41, 0x54, 0x00, 0x00, 0x00, 0x08, 0x63, 0x64,
        0x06, 0x4d, 0x0f, 0xa3, 0x00, 0x00, 0x00, 0x05,
        0x66, 0x64, 0x41, 0x54, 0x00, 0x00, 0x00, 0x09,
        0x65, 0x04, 0xa8, 0x58, 0x73,
    };

    /// Twenty abcde patterns split at thirteen compressed bytes and sequence zero.
    pub const fdat_fragmented = &[_]u8{
        0x00, 0x00, 0x00, 0x11, 0x66, 0x64, 0x41, 0x54,
        0x00, 0x00, 0x00, 0x00, 0x61, 0x62, 0x63, 0x64,
        0x65, 0x61, 0x62, 0x63, 0x64, 0x65, 0x61, 0x62,
        0x63, 0x84, 0x70, 0x8b, 0xcb, 0x00, 0x00, 0x00,
        0x11, 0x66, 0x64, 0x41, 0x54, 0x00, 0x00, 0x00,
        0x01, 0x64, 0x65, 0x61, 0x62, 0x63, 0x64, 0x65,
        0x61, 0x62, 0x63, 0x64, 0x65, 0x61, 0x9b, 0x80,
        0x8e, 0xb0, 0x00, 0x00, 0x00, 0x11, 0x66, 0x64,
        0x41, 0x54, 0x00, 0x00, 0x00, 0x02, 0x62, 0x63,
        0x64, 0x65, 0x61, 0x62, 0x63, 0x64, 0x65, 0x61,
        0x62, 0x63, 0x64, 0xda, 0xa2, 0xd8, 0xc5, 0x00,
        0x00, 0x00, 0x11, 0x66, 0x64, 0x41, 0x54, 0x00,
        0x00, 0x00, 0x03, 0x65, 0x61, 0x62, 0x63, 0x64,
        0x65, 0x61, 0x62, 0x63, 0x64, 0x65, 0x61, 0x62,
        0x54, 0x5e, 0x71, 0xb2, 0x00, 0x00, 0x00, 0x11,
        0x66, 0x64, 0x41, 0x54, 0x00, 0x00, 0x00, 0x04,
        0x63, 0x64, 0x65, 0x61, 0x62, 0x63, 0x64, 0x65,
        0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x66, 0xc8,
        0xfb, 0x00, 0x00, 0x00, 0x11, 0x66, 0x64, 0x41,
        0x54, 0x00, 0x00, 0x00, 0x05, 0x61, 0x62, 0x63,
        0x64, 0x65, 0x61, 0x62, 0x63, 0x64, 0x65, 0x61,
        0x62, 0x63, 0x00, 0xd3, 0xe5, 0xa6, 0x00, 0x00,
        0x00, 0x11, 0x66, 0x64, 0x41, 0x54, 0x00, 0x00,
        0x00, 0x06, 0x64, 0x65, 0x61, 0x62, 0x63, 0x64,
        0x65, 0x61, 0x62, 0x63, 0x64, 0x65, 0x61, 0xfe,
        0x4d, 0x24, 0x70, 0x00, 0x00, 0x00, 0x0d, 0x66,
        0x64, 0x41, 0x54, 0x00, 0x00, 0x00, 0x07, 0x62,
        0x63, 0x64, 0x65, 0x61, 0x62, 0x63, 0x64, 0x65,
        0x17, 0xa1, 0xf8, 0xcc,
    };

    /// The largest legal PNG sequence number followed by payload abc.
    pub const last_sequence = &[_]u8{
        0x00, 0x00, 0x00, 0x07, 0x66, 0x64, 0x41, 0x54,
        0x7f, 0xff, 0xff, 0xff, 0x61, 0x62, 0x63, 0x33,
        0x8f, 0xf1, 0x46,
    };
};

test "APNG data chunks skip an empty repeated suffix after draining buffered fragments" {
    var guarded: [512]u8 = @splat(0xa5);
    var output: DataStream = undefined;
    var sequence: u64 = 0;
    try output.init(guarded[3..], 13, &sequence);
    try output.writer.writeAll("abcdeabcdeabcdeabcdeabcdeabcdeabcdeabcdeabcdeabcde");
    try std.testing.expectEqual(
        50,
        try output.writer.writeSplat(
            &.{ "", "abcdeabcdeabcdeabcdeabcde", "", "abcdeabcdeabcdeabcdeabcde", "" },
            std.math.maxInt(usize),
        ),
    );
    const used = try output.finish();
    try std.testing.expectEqual(8, sequence);
    try std.testing.expectEqualSlices(
        u8,
        testing_data_chunks.fdat_fragmented,
        guarded[3..][0..used],
    );
    for (guarded[0..3]) |byte| try std.testing.expectEqual(0xa5, byte);
    for (guarded[3 + used ..]) |byte| try std.testing.expectEqual(0xa5, byte);
}

test "APNG data chunk completion retains one finalized stream across repeated finish" {
    // Independent CRC-32 framing for empty data; fragmented nonempty fixtures are below.
    const empty_idat = &[_]u8{
        0x00, 0x00, 0x00, 0x00, 0x49, 0x44, 0x41, 0x54,
        0x35, 0xaf, 0x06, 0x1e,
    };
    const empty_fdat = &[_]u8{
        0x00, 0x00, 0x00, 0x04, 0x66, 0x64, 0x41, 0x54,
        0x00, 0x00, 0x00, 0x07, 0x9b, 0xac, 0x3b, 0xc2,
    };
    const short_idat = &[_]u8{
        0x00, 0x00, 0x00, 0x01, 0x49, 0x44, 0x41, 0x54,
        0x61, 0x12, 0x8d, 0x2c, 0x26,
    };
    const short_fdat = &[_]u8{
        0x00, 0x00, 0x00, 0x05, 0x66, 0x64, 0x41, 0x54,
        0x00, 0x00, 0x00, 0x07, 0x61, 0x9d, 0x46, 0xb1,
        0xe4,
    };
    for ([_]bool{ false, true }) |sequenced| {
        for ([_][]const u8{ "", "a", "abcde" }) |data| {
            var guarded: [96]u8 = @splat(0xa5);
            var sequence: u64 = 7;
            var output: DataStream = undefined;
            try output.init(guarded[3..], 2, if (sequenced) &sequence else null);
            try output.writer.writeAll(data);
            const used = try output.finish();
            const expected: []const u8 = if (data.len == 0) if (sequenced)
                empty_fdat
            else
                empty_idat else if (data.len == 1) if (sequenced)
                short_fdat
            else
                short_idat else if (sequenced) testing_data_chunks
                .fdat_chunks else testing_data_chunks.idat_chunks;
            try std.testing.expectEqual(expected.len, used);
            try std.testing.expectEqualSlices(u8, expected, guarded[3..][0..used]);
            const complete = guarded;
            const final_sequence = sequence;
            try std.testing.expectEqual(used, try output.finish());
            try std.testing.expectEqual(final_sequence, sequence);
            try std.testing.expectEqual(complete, guarded);
        }
    }
}

test "APNG data chunks preserve independent sequences CRCs partial tails and buffered fragments" {
    var guarded: [512]u8 = @splat(0xa5);
    var output: DataStream = undefined;
    try output.init(guarded[3..], 2, null);
    try output.writer.writeAll("abcde");
    var used = try output.finish();
    try std.testing.expectEqualSlices(u8, testing_data_chunks.idat_chunks, guarded[3..][0..used]);
    for (guarded[0..3]) |byte| try std.testing.expectEqual(0xa5, byte);
    for (guarded[3 + used ..]) |byte| try std.testing.expectEqual(0xa5, byte);

    var sequence: u64 = 7;
    try output.init(guarded[3..], 2, &sequence);
    try output.writer.writeAll("abcde");
    used = try output.finish();
    try std.testing.expectEqual(10, sequence);
    try std.testing.expectEqualSlices(u8, testing_data_chunks.fdat_chunks, guarded[3..][0..used]);
    sequence = 0;
    try output.init(guarded[3..], 13, &sequence);
    try output.writer.writeAll(&@as([50]u8, @bitCast(@as([10][5]u8, @splat("abcde".*)))));
    var parts = [_][]const u8{ "abcde", "abcde" };
    try output.writer.writeSplatAll(&parts, 9);
    used = try output.finish();
    try std.testing.expectEqualSlices(
        u8,
        testing_data_chunks.fdat_fragmented,
        guarded[3..][0..used],
    );
    sequence = 0x7fffffff;
    try output.init(guarded[3..], 3, &sequence);
    try output.writer.writeAll("abc");
    used = try output.finish();
    try std.testing.expectEqualSlices(u8, testing_data_chunks.last_sequence, guarded[3..][0..used]);
    try std.testing.expectEqual(0x80000000, sequence);
    try std.testing.expectError(error.SequenceOverflow, nextSequence(&sequence));
    try output.init(guarded[0..17], 2, &sequence);
    try output.writer.writeAll("a");
    try std.testing.expectError(error.WriteFailed, output.finish());
    sequence = 0;
    try output.init(guarded[0..17], 2, &sequence);
    try output.writer.writeAll("ab");
    try std.testing.expectError(error.WriteFailed, output.finish());
}

test "PNG data record count preserves byte-fit sizes and wire limits without padding overflow" {
    const maximum = std.math.maxInt(usize);
    const lengths = [_]usize{
        0,
        1,
        2,
        127,
        128,
        129,
        0x7fff_ffff,
        0x8000_0000,
        maximum - 1,
        maximum,
    };
    for ([_]bool{ false, true }) |sequenced| {
        const limit: usize = if (sequenced) 0x7fff_fffb else 0x7fff_ffff;
        for (lengths) |length| for ([_]usize{ 1, 2, 13, 64, limit }) |chunk_limit| {
            const expected: usize = @intCast(
                @max(1, (@as(u128, length) + chunk_limit - 1) / chunk_limit),
            );
            try std.testing.expectEqual(
                expected,
                try dataRecordCount(length, chunk_limit, sequenced),
            );
        };
        try std.testing.expectError(error.InvalidDataChunkSize, dataRecordCount(1, 0, sequenced));
        try std.testing.expectError(
            error.InvalidDataChunkSize,
            dataRecordCount(1, limit + 1, sequenced),
        );
    }
    try std.testing.expectEqual(2, try dataRecordCount(0x8000_0000, 0x7fff_ffff, false));
    try std.testing.expectEqual(2, try dataRecordCount(0x8000_0000, 0x7fff_fffb, true));
    try std.testing.expectEqual(2, try dataRecordCount(0xffff_fff7, 0x7fff_ffff, false));
    try std.testing.expectEqual(3, try dataRecordCount(0xffff_fff7, 0x7fff_fffb, true));
}

test "PNG chunks skip an empty repeated suffix after draining buffered fragments" {
    const body = "ppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppabcde";
    // Independent zlib CRC-32 over IDAT plus these 69 payload bytes.
    const expected = &[_]u8{ 0x00, 0x00, 0x00, 0x45, 0x49, 0x44, 0x41, 0x54 } ++
        body ++
        &[_]u8{ 0x0f, 0xc7, 0x14, 0x2e };
    for ([_]usize{ 69, 80 }) |capacity| {
        var guarded: [96]u8 = @splat(0xa5);
        var chunk_writer: ChunkWriter = undefined;
        try chunk_writer.init(guarded[3..], "IDAT", capacity);
        try chunk_writer.writer.writeAll(body[0..64]);
        try std.testing.expectEqual(
            5,
            try chunk_writer.writer.writeSplat(
                &.{ "", "ab", "", "cde", "" },
                std.math.maxInt(usize),
            ),
        );
        const used = if (capacity == body.len) try chunk_writer.finish() else try chunk_writer
            .finishPrefix();
        try std.testing.expectEqual(expected.len, used);
        try std.testing.expectEqual(body.len, chunk_writer.produced);
        try std.testing.expectEqualSlices(u8, expected, guarded[3..][0..used]);
        for (guarded[0..3]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (guarded[3 + used ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "PNG chunks preserve independent CRC framing and exact payload boundaries" {
    // Literal PNG IEND framing, independent of the checksum implementation.
    var bytes: [24]u8 = @splat(0xa5);
    var offset: usize = 3;
    try append(&bytes, &offset, "IEND", &.{});
    try std.testing.expectEqual(15, offset);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 },
        bytes[3..15],
    );
    for (bytes[0..3]) |byte| try std.testing.expectEqual(0xa5, byte);
    for (bytes[15..]) |byte| try std.testing.expectEqual(0xa5, byte);
    const unchanged = bytes;
    try std.testing.expectError(error.OutputTooSmall, append(bytes[0..14], &offset, "IEND", &.{}));
    try std.testing.expectEqual(unchanged, bytes);
    try std.testing.expectError(error.InvalidChunkType, append(&bytes, &offset, "idat", &.{}));
    try std.testing.expectError(error.InvalidChunkType, append(&bytes, &offset, "a1CD", &.{}));
    try std.testing.expectError(error.ChunkTooLarge, byteCount(0x80000000));

    var chunk_writer: ChunkWriter = undefined;
    try chunk_writer.init(&bytes, "tEXt", 3);
    try chunk_writer.writer.writeAll("a");
    try std.testing.expectError(error.IncompletePayload, chunk_writer.finish());
    try chunk_writer.writer.writeAll("bc");
    try std.testing.expectEqual(15, try chunk_writer.finish());
    try std.testing.expectError(error.PayloadComplete, chunk_writer.finish());
    try std.testing.expectEqualSlices(u8, "abc", bytes[8..11]);
    // A copied name may originate in the destination header that init overwrites.
    @memcpy(bytes[0..4], "IEND");
    try chunk_writer.init(&bytes, bytes[0..4], 0);
    try std.testing.expectEqual(12, try chunk_writer.finish());
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 },
        bytes[0..12],
    );
}

test "fixed PNG end chunk matches general framing at every capacity and offset" {
    for (0..41) |capacity| {
        for (0..42) |initial| {
            var expected: [48]u8 = @splat(0xa5);
            var actual = expected;
            var expected_offset = initial;
            var actual_offset = initial;
            append(expected[3..][0..capacity], &expected_offset, "IEND", &.{}) catch |err| {
                try std.testing.expectError(
                    err,
                    appendEnd(actual[3..][0..capacity], &actual_offset),
                );
                try std.testing.expectEqual(expected_offset, actual_offset);
                try std.testing.expectEqualSlices(u8, &expected, &actual);
                continue;
            };
            try appendEnd(actual[3..][0..capacity], &actual_offset);
            try std.testing.expectEqual(expected_offset, actual_offset);
            try std.testing.expectEqualSlices(u8, &expected, &actual);
        }
    }
}

test "complete PNG chunks accept exact payload aliases and preserve admission errors" {
    const expected = [_]u8{
        0x00, 0x00, 0x00, 0x03, 0x74, 0x45, 0x58, 0x74,
        0x61, 0x62, 0x63, 0xfc, 0x85, 0x9b, 0x88,
    };
    var guarded: [40]u8 = @splat(0xa5);
    const chunk = guarded[3..];
    @memcpy(chunk[0..4], "tEXt");
    chunk[9] = 'b';
    const name: *const [4]u8 = chunk[0..4];
    const parts = [_][]const u8{ "a", chunk[9..10], "", "c" };
    var offset: usize = 0;
    try appendParts(chunk, &offset, name, &parts);
    try std.testing.expectEqual(expected.len, offset);
    try std.testing.expectEqualSlices(u8, &expected, chunk[0..offset]);
    for (guarded[0..3]) |byte| try std.testing.expectEqual(0xa5, byte);
    for (guarded[3 + offset ..]) |byte| try std.testing.expectEqual(0xa5, byte);

    var empty: [12]u8 = undefined;
    offset = 0;
    try appendParts(&empty, &offset, "IEND", &.{});
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82 },
        &empty,
    );
    const unchanged = empty;
    offset = empty.len;
    try std.testing.expectError(error.InvalidChunkType, append(&empty, &offset, "idat", ""));
    try std.testing.expectEqual(empty.len, offset);
    try std.testing.expectEqual(unchanged, empty);
    try std.testing.expectError(error.OutputTooSmall, append(&empty, &offset, "IEND", ""));
    try std.testing.expectEqual(empty.len, offset);
    offset = empty.len + 1;
    try std.testing.expectError(error.OutputTooSmall, append(&empty, &offset, "idat", ""));
    try std.testing.expectEqual(empty.len + 1, offset);
    try std.testing.expectEqual(unchanged, empty);
}

test "PNG chunk buffered overflow publishes only admitted payload bytes" {
    var bytes: [32]u8 = @splat(0xa5);
    var chunk_writer: ChunkWriter = undefined;
    try chunk_writer.init(&bytes, "tEXt", 3);
    try chunk_writer.writer.writeAll("longer");
    try std.testing.expectError(error.WriteFailed, chunk_writer.finish());
    for (bytes[8..]) |byte| try std.testing.expectEqual(0xa5, byte);
}

test "PNG chunk prefix completion frames independent payload bytes and reuses its tail" {
    var bytes: [32]u8 = @splat(0xa5);
    var chunk_writer: ChunkWriter = undefined;
    try chunk_writer.init(&bytes, "tEXt", 12);
    try chunk_writer.writer.writeAll("abc");
    const used = try chunk_writer.finishPrefix();
    // Independently frozen CRC32 over tEXt followed by abc.
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x00, 0x00, 0x00, 0x03, 0x74, 0x45, 0x58, 0x74,
            0x61, 0x62, 0x63, 0xfc, 0x85, 0x9b, 0x88,
        },
        bytes[0..used],
    );
    try std.testing.expectError(error.PayloadComplete, chunk_writer.finishPrefix());
    var offset = used;
    try append(&bytes, &offset, "IEND", &.{});
    try std.testing.expectEqual(27, offset);
    for (bytes[offset..]) |byte| try std.testing.expectEqual(0xa5, byte);
}
