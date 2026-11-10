//! PNG records pair a four-byte type name with payload bytes and a CRC checksum. Iterator reads
//! these records from a complete encoded PNG; writeInto writes one record into caller storage.
//! Chunk copies its name and borrows its payload. Keep borrowed bytes alive and unchanged during
//! use. Iterator and writeInto check framing. Validator checks ordering, supported image layouts
//! and structural limits across a PNG chunk sequence; its caller checks CRCs and byte bounds.

const std = @import("std");
const chunks = @import("ChunkWriter.zig");
const Header = @import("Header.zig");
const metadata = @import("metadata.zig");

const format = @import("format.zig");
const Crc32 = @import("../crc.zig").Crc32IsoHdlc;
const Chunk = @This();

/// Four case-sensitive alphabetic type bytes, copied from input or supplied by the caller. Writers
/// require an uppercase third byte; iterators retain that byte as found.
name: [4]u8,
/// Borrowed payload without length, type or CRC fields. Empty payloads are valid. The length must
/// fit PNG's 31-bit bound when writing.
data: []const u8,

/// True for an ancillary chunk, which a decoder may ignore when it does not recognize the type.
pub fn isAncillary(self: Chunk) bool {
    return std.ascii.isLower(self.name[0]);
}

/// True when the type name uses PNG's private, application-defined namespace.
pub fn isPrivate(self: Chunk) bool {
    return std.ascii.isLower(self.name[1]);
}

/// True when an unrecognized ancillary chunk may survive changes to critical image chunks. It must
/// still remain on its original side of IDAT when copied. Critical chunks always return false.
pub fn isSafeToCopy(self: Chunk) bool {
    return self.isAncillary() and std.ascii.isLower(self.name[3]);
}

/// Encoded length including the length, type and CRC fields. The PNG length limit and host-size
/// overflow are checked; the chunk name is checked separately by writeInto.
pub fn byteCount(self: Chunk) error{ChunkTooLarge}!usize {
    return chunks.byteCount(self.data.len);
}

/// Writes one complete chunk and returns the used destination prefix. Source payload and
/// destination must be disjoint and live throughout the call. Type, length and capacity failures
/// precede all writes; unused destination capacity is preserved. The PNG reserved bit must be clear
/// when writing.
pub fn writeInto(
    self: Chunk,
    destination: []u8,
) (error{ InvalidChunkType, ChunkTooLarge, OutputTooSmall })![]u8 {
    var offset: usize = 0;
    try chunks.append(destination, &offset, &self.name, self.data);
    return destination[0..offset];
}

/// Iterates a complete immutable PNG byte slice without allocation. Each returned payload borrows
/// source through its use; the iterator itself may move. Initialization checks only the signature.
/// Each next validates one record's length, alphabetic type, bounds and CRC. IEND terminates the
/// sequence and must end the source. No PNG chunk-order, image, metadata or unknown-critical
/// semantics are admitted. The reader accepts a set reserved bit, as does Source.open.
///
/// A framing failure persists on subsequent calls; create a new iterator to retry. Null indicates
/// IEND was accepted and remains null on subsequent calls. Earlier returned payloads remain
/// borrowed from the unchanged source even if a later record fails.
pub const Iterator = struct {
    /// Complete encoded input borrowed by init; keep it alive and unchanged through payload use.
    source: []const u8,
    /// Internal byte offset of the next record, including the eight-byte PNG signature. Only init
    /// and next may update this cursor.
    offset: usize = 8,
    /// Internal traversal state. Completion follows IEND; failure persists until reinitialization.
    state: enum { active, done, failed } = .active,

    /// Invalid signature, framing, type bytes or CRC; also missing IEND or bytes after IEND.
    pub const Error = error{InvalidPng};

    /// Borrows complete source bytes after verifying the PNG signature.
    pub fn init(source: []const u8) Error!Iterator {
        if (!std.mem.startsWith(u8, source, format.signature)) return error.InvalidPng;
        return .{ .source = source };
    }

    /// Returns the next checked record, including IEND, then null. A failure publishes no record
    /// from that call and permanently fails this iterator.
    pub fn next(self: *Iterator) Error!?Chunk {
        switch (self.state) {
            .done => return null,
            .failed => return error.InvalidPng,
            .active => {},
        }
        return self.readNext() catch {
            self.state = .failed;
            return error.InvalidPng;
        };
    }

    fn readNext(self: *Iterator) Error!Chunk {
        if (self.offset > self.source.len or self.source.len - self.offset < 12)
            return error.InvalidPng;
        const rest = self.source[self.offset..];
        const length = std.mem.readInt(u32, rest[0..4], .big);
        if (length > 0x7fff_ffff or length > rest.len - 12) return error.InvalidPng;
        const name = rest[4..8].*;
        for (name) |byte| if (!std.ascii.isAlphabetic(byte)) return error.InvalidPng;
        const end = 8 + @as(usize, length);
        const data = rest[8..end];
        var crc = Crc32.init();
        crc.update(&name);
        crc.update(data);
        if (crc.final() != std.mem.readInt(u32, rest[end..][0..4], .big)) return error.InvalidPng;
        const after = self.offset + end + 4;
        if (std.mem.eql(u8, &name, "IEND")) {
            if (after != self.source.len) return error.InvalidPng;
            self.state = .done;
        }
        self.offset = after;
        return .{ .name = name, .data = data };
    }
};

/// Validates PNG chunk ordering, supported layouts and structural budgets while copying header and
/// sample-affecting declarations. Call start, optionally validateChunkHeader, then complete only
/// after the caller accepts the chunk CRC. Validation borrows no input and allocates nothing. A
/// failed mutating operation ends this validation; initialize a new validator before continuing.
/// Change state only through its methods. Copied header facts remain independent of this owner.
pub const Validator = struct {
    pub const Error = format.Error;

    /// Required/sample-affecting payload handling, or another chunk name. `other` includes
    /// ancillary records and unknown critical names; payload admission rejects the latter. This
    /// discriminator alone does not establish chunk properties.
    pub const Kind = enum { ihdr, plte, trns, idat, iend, other };

    /// Complete copied geometry, present only after a checked IHDR completes.
    header: ?Header = null,
    /// Indexed/suggested palette entries admitted by the latest completed PLTE.
    palette_entries: usize = 0,
    /// Indexed alpha entries admitted by the completed tRNS, with omitted entries opaque.
    alpha_entries: usize = 0,
    /// Stored-depth grayscale transparency code; upper unused bits are ignored.
    transparent_gray: ?u16 = null,
    /// Stored-depth truecolor transparency codes, without precision reduction.
    transparent_rgb: ?[3]u16 = null,
    /// Chunks started so far, including the current unfinished record.
    record_count: usize = 0,
    /// Ancillary payload admission, counting only up to four bytes per fdAT.
    metadata_bytes: usize = 0,
    /// Copied declarations observed after each complete checked chunk.
    metadata_presence: metadata.Metadata.Presence = .{},
    /// Copied dimension, chunk-count and metadata-byte limits for this sequence.
    options: Options,
    /// Recognized role of the most recently started chunk; other includes ancillary chunk types.
    kind: Kind = .other,
    /// Copied, case-sensitive type bytes of the most recently started chunk. Undefined before the
    /// first successful start; no source-byte borrow is retained.
    name: [4]u8 = undefined,
    /// Declared payload length in bytes, excluding the length/type fields and CRC.
    length: usize = 0,
    /// A chunk has started but has not completed. Prevents starting another chunk or finishing the
    /// PNG.
    pending: bool = false,
    /// Ordering and payload-length checks passed for the most recently started chunk. Repeated
    /// validateChunkHeader calls can reuse those checks; start clears this flag for the next chunk.
    chunk_header_validated: bool = false,
    /// A PLTE chunk has completed. Enforces one palette and requires it before indexed IDAT/tRNS.
    saw_palette: bool = false,
    /// A tRNS chunk has completed. Prevents duplicate transparency and a later PLTE.
    saw_transparency: bool = false,
    /// At least one IDAT chunk has completed. IEND requires image data; PLTE/tRNS must precede it.
    saw_image_data: bool = false,
    /// An ancillary chunk completed after IDAT, closing the contiguous IDAT run. Later IDAT chunks
    /// are invalid even though further ancillary chunks may follow.
    image_data_ended: bool = false,
    /// IEND has completed. No further chunk may start, and finish can return the copied header.
    ended: bool = false,

    /// Structural limits enforced while validating a PNG chunk sequence.
    pub const Options = struct {
        /// Largest admitted stored width or height; PNG's 31-bit format bound also applies.
        maximum_source_extent: u32 = format.default_maximum_source_extent,
        /// Maximum visited chunks, including image-data chunks.
        maximum_records: usize = 1024 * 1024,
        /// Aggregate ancillary payload bytes; fdAT contributes only its sequence word.
        maximum_metadata_bytes: usize = 1024 * 1024,
    };

    /// Creates a fresh validator with copied policy and no borrowed input or allocated storage.
    pub fn init(options: Options) Validator {
        return .{ .options = options };
    }

    /// Checks length/name and structural policy before a caller traverses payload/CRC. The returned
    /// kind alone does not imply ordering or sample-layout admission.
    pub fn start(self: *Validator, name: *const [4]u8, length: usize) Error!Kind {
        if (self.pending or self.ended or length > 0x7fff_ffff) return error.InvalidPng;
        for (name) |byte| if (!std.ascii.isAlphabetic(byte)) return error.InvalidPng;
        // The decoder ignores unknown ancillary names even with the reserved bit set. Writers
        // retain uppercase third bytes when emitting records.
        if (self.record_count == self.options.maximum_records) return error.MetadataLimitExceeded;
        self.record_count += 1;

        // fdAT carries a four-byte sequence number followed by compressed frame data. Only the
        // sequence number counts toward the metadata budget.
        if (std.ascii.isLower(name[0])) {
            const count = if (std.mem.eql(u8, name, "fdAT")) @min(length, 4) else length;
            self.metadata_bytes = std.math.add(
                usize,
                self.metadata_bytes,
                count,
            ) catch return error.MetadataLimitExceeded;
            if (self.metadata_bytes > self.options.maximum_metadata_bytes)
                return error.MetadataLimitExceeded;
        }

        self.name = name.*;
        self.length = length;
        self.kind = kind: {
            if (std.mem.eql(u8, name, "IHDR")) break :kind .ihdr;
            if (std.mem.eql(u8, name, "PLTE")) break :kind .plte;
            if (std.mem.eql(u8, name, "tRNS")) break :kind .trns;
            if (std.mem.eql(u8, name, "IDAT")) break :kind .idat;
            if (std.mem.eql(u8, name, "IEND")) break :kind .iend;
            break :kind .other;
        };
        self.pending = true;
        self.chunk_header_validated = false;
        return self.kind;
    }

    /// Checks chunk order, declared length and layout readiness before optional provisional IDAT
    /// reconstruction. A whole-source caller instead lets complete perform this after the chunk CRC
    /// accepts. No metadata observations or source/table pointers are published here.
    pub fn validateChunkHeader(self: *Validator) Error!void {
        if (!self.pending) return error.InvalidPng;
        if (self.chunk_header_validated) return;
        if (self.header == null) {
            if (self.kind != .ihdr or self.record_count != 1 or self.length != 13)
                return error.InvalidPng;
        } else switch (self.kind) {
            .ihdr => return error.InvalidPng,
            .idat => {
                if (self.image_data_ended) return error.InvalidPng;
                if (self.header.?.color_type == 3 and !self.saw_palette) return error.InvalidPng;
            },
            .plte => {
                const header = self.header.?;
                if (self.saw_image_data or self.saw_palette or self.saw_transparency or (header
                    .color_type != 2 and header.color_type != 3 and header.color_type != 6) or self
                    .length == 0 or self.length % 3 != 0 or self.length / 3 > 256)
                    return error.InvalidPng;
                // An indexed image cannot name more palette entries than its bit depth permits.
                if (header.color_type == 3) {
                    const depth: std.math.Log2Int(usize) = @intCast(header.bit_depth);
                    const maximum_entries = @as(usize, 1) << depth;
                    if (self.length / 3 > maximum_entries) return error.InvalidPng;
                }
            },
            .trns => {
                if (self.saw_image_data or self.saw_transparency) return error.InvalidPng;
                switch (self.header.?.color_type) {
                    0 => if (self.length != 2) return error.InvalidPng,
                    2 => if (self.length != 6) return error.InvalidPng,
                    3,
                    => if (!self.saw_palette or self.length > self.palette_entries)
                        return error.InvalidPng,
                    4, 6 => return error.InvalidPng,
                    else => unreachable,
                }
            },
            .iend => if (!self.saw_image_data or self.length != 0) return error.InvalidPng,
            .other => if (std.ascii.isUpper(self.name[0])) return error.UnsupportedPng,
        }
        self.chunk_header_validated = true;
    }

    /// Completes one CRC-admitted chunk, copying facts without retaining payloads. IHDR/tRNS
    /// require their exact complete payload; other kinds need no capture here. PLTE contents stay
    /// with the caller. Optional ancillary semantic queries stay separate.
    pub fn complete(self: *Validator, captured: []const u8) Error!void {
        try self.validateChunkHeader();
        switch (self.kind) {
            .ihdr => {
                if (captured.len != self.length) return error.InvalidPng;
                self.header = try Header.fromIhdr(captured, self.options.maximum_source_extent);
            },
            .plte => {
                self.palette_entries = self.length / 3;
                self.saw_palette = true;
            },
            .trns => {
                if (captured.len != self.length) return error.InvalidPng;
                const header = self.header.?;
                switch (header.color_type) {
                    0 => self.transparent_gray = transparentSample(
                        readU16(captured[0..2]),
                        header.bit_depth,
                    ),
                    2 => self.transparent_rgb = .{
                        transparentSample(readU16(captured[0..2]), header.bit_depth),
                        transparentSample(readU16(captured[2..4]), header.bit_depth),
                        transparentSample(readU16(captured[4..6]), header.bit_depth),
                    },
                    3 => self.alpha_entries = self.length,
                    else => unreachable,
                }
                self.saw_transparency = true;
            },
            .idat => self.saw_image_data = true,
            .iend => self.ended = true,
            .other => if (self.saw_image_data) {
                self.image_data_ended = true;
            },
        }
        metadata.observeChunk(&self.metadata_presence, &self.name);
        self.header.?.metadata_presence = self.metadata_presence;
        self.pending = false;
    }

    /// Copies the accepted header after completed IEND without changing this validator's state.
    /// Incomplete validation returns InvalidPng; this query does not end active validation. The
    /// caller separately establishes real EOF/no trailing bytes, CRCs and pixel validity.
    pub fn finish(self: Validator) Error!Header {
        if (self.pending or !self.ended) return error.InvalidPng;
        return self.header.?;
    }

    fn readU16(bytes: *const [2]u8) u16 {
        return std.mem.readInt(u16, bytes, .big);
    }

    fn transparentSample(sample: u16, bit_depth: u8) u16 {
        const significant_bits: u16 = @intCast((@as(u32, 1) << @intCast(bit_depth)) - 1);
        return sample & significant_bits;
    }
};

test "validator preserves normalized keys, ancillary framing and record policy" {
    var validator = Validator.init(.{ .maximum_records = 5, .maximum_metadata_bytes = 6 });
    _ = try validator.start("IHDR", 13);
    try validator.complete(&.{ 0, 0, 0, 3, 0, 0, 0, 1, 2, 0, 0, 0, 0 });
    _ = try validator.start("tRNS", 2);
    try validator.complete(&.{ 0xff, 0xfd });
    try std.testing.expectEqual(1, validator.transparent_gray.?);
    _ = try validator.start("IDAT", 100);
    try validator.validateChunkHeader();
    try validator.complete(&.{});
    _ = try validator.start("vpag", 4);
    try validator.complete(&.{});
    try std.testing.expectEqual(6, validator.metadata_bytes);
    _ = try validator.start("IEND", 0);
    try validator.complete(&.{});
    const header = try validator.finish();
    try std.testing.expectEqual(2, header.bit_depth);
    try std.testing.expectEqual(2, header.filtered_byte_count);
    try std.testing.expectError(error.InvalidPng, validator.start("IDAT", 0));
    var frame_data = Validator.init(.{ .maximum_metadata_bytes = 4 });
    _ = try frame_data.start("IHDR", 13);
    try frame_data.complete(&.{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0 });
    _ = try frame_data.start("IDAT", 0);
    try frame_data.complete(&.{});
    _ = try frame_data.start("fdAT", 1_000_000);
    try frame_data.complete(&.{});
    try std.testing.expectEqual(4, frame_data.metadata_bytes);
    _ = try frame_data.start("IDAT", 1);
    try std.testing.expectError(error.InvalidPng, frame_data.validateChunkHeader());
    var bounded = Validator.init(.{ .maximum_records = 0 });
    try std.testing.expectError(error.MetadataLimitExceeded, bounded.start("IHDR", 13));
    bounded = Validator.init(.{});
    _ = try bounded.start("IHDR", 13);
    try bounded.complete(&.{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0 });
    _ = try bounded.start("HIDE", 0);
    try std.testing.expectError(error.UnsupportedPng, bounded.complete(&.{}));
}

// CRCs in these independent wire records were computed with Python zlib.crc32.
const test_wire = [_]u8{
    0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n', 0,   0,   0,   3,    'v',  'p',  'A',  'g',
    'a',  'b',  'c',  0x10, 0xf1, 0x11, 0x3d, 0,    0,   0,   0,   'A',  'B',  'c',  'D',  0x4e,
    0x93, 0x04, 0x07, 0,    0,    0,    0,    'I',  'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82,
};

test "chunk iteration admits independent CRCs unknown types and empty records" {
    var it = try Iterator.init(&test_wire);
    const custom = (try it.next()).?;
    try std.testing.expectEqualStrings("vpAg", &custom.name);
    try std.testing.expectEqualStrings("abc", custom.data);
    try std.testing.expect(custom.isAncillary());
    try std.testing.expect(custom.isPrivate());
    try std.testing.expect(custom.isSafeToCopy());
    const reserved = (try it.next()).?;
    try std.testing.expectEqualStrings("ABcD", &reserved.name);
    try std.testing.expectEqual(@as(usize, 0), reserved.data.len);
    try std.testing.expect(!reserved.isAncillary());
    try std.testing.expect(!reserved.isPrivate());
    try std.testing.expect(!reserved.isSafeToCopy());
    try std.testing.expectEqualStrings("IEND", &(try it.next()).?.name);
    try std.testing.expectEqual(null, try it.next());
    try std.testing.expectEqual(null, try it.next());
}

test "unknown critical chunks are never safe to copy" {
    // Independently framed with Python zlib.crc32. The lowercase fourth letter alone must not
    // authorize preservation of an unknown critical chunk during editing.
    const wire = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x00, 0x41, 0x42, 0x43, 0x64,
        0xe0, 0x79, 0x00, 0x6d, 0x00, 0x00, 0x00, 0x00,
        0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    var records = try Iterator.init(&wire);
    const critical = (try records.next()).?;
    try std.testing.expectEqualStrings("ABCd", &critical.name);
    try std.testing.expect(!critical.isAncillary());
    try std.testing.expect(!critical.isSafeToCopy());
    try std.testing.expectEqualStrings("IEND", &(try records.next()).?.name);
    try std.testing.expectEqual(null, try records.next());
}

test "chunk writing uses independent wire bytes and preserves guards" {
    const chunk: Chunk = .{ .name = "vpAg".*, .data = "abc" };
    try std.testing.expectEqual(@as(usize, 15), try chunk.byteCount());
    var output: [20]u8 = @splat(0xa5);
    const written = try chunk.writeInto(output[2..]);
    try std.testing.expectEqualSlices(u8, test_wire[8..23], written);
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, output[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5 }, output[17..]);
    @memset(&output, 0xa5);
    try std.testing.expectError(error.OutputTooSmall, chunk.writeInto(output[0..14]));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
    try std.testing.expectError(
        error.InvalidChunkType,
        (Chunk{ .name = "ABcD".*, .data = "" }).writeInto(&output),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
    try std.testing.expectError(
        error.InvalidChunkType,
        (Chunk{ .name = "A1CD".*, .data = "" }).writeInto(&output),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
}

test "chunk iteration rejects bad framing CRC truncation and trailing bytes persistently" {
    try std.testing.expectError(error.InvalidPng, Iterator.init("not a PNG"));
    for (0..test_wire.len) |end| {
        var it = try Iterator.init(test_wire[0..@max(end, 8)]);
        var failed = false;
        while (it.next() catch {
            failed = true;
            break;
        }) |_| {}
        try std.testing.expect(failed);
        try std.testing.expectError(error.InvalidPng, it.next());
    }
    var bad = test_wire;
    bad[16] ^= 1;
    var bad_crc = try Iterator.init(&bad);
    try std.testing.expectError(error.InvalidPng, bad_crc.next());
    bad = test_wire;
    bad[12] = '1';
    var bad_name = try Iterator.init(&bad);
    try std.testing.expectError(error.InvalidPng, bad_name.next());
    bad = test_wire;
    bad[8] = 0x80;
    var bad_length = try Iterator.init(&bad);
    try std.testing.expectError(error.InvalidPng, bad_length.next());
    var trailing = try Iterator.init(&(test_wire ++ [_]u8{0}));
    _ = try trailing.next();
    _ = try trailing.next();
    try std.testing.expectError(error.InvalidPng, trailing.next());
}
