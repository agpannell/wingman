//! A borrowed TTC/OTC collection of font directories. Opening checks every directory extent and the
//! optional signature range. Selecting a face admits that directory's flavor and table ranges; an
//! unsupported or malformed sibling does not prevent another face from being selected.
//!
//! Selected directories borrow complete immutable collection bytes, with absolute table offsets.
//! Construct with open and preserve the admitted fields while those bytes remain alive.

const std = @import("std");
const binary = @import("../common/font_binary.zig");
const Directory = @import("Directory.zig");
const directory_layout = @import("directory_layout.zig");
const fixtures = @import("fixtures.zig");

const Collection = @This();
const header_size = 12;
const collection_tag = 0x74746366;
const signature_tag = 0x44534947;

/// Complete immutable collection bytes, also borrowed by selected directories.
source: []const u8,
/// Borrowed array of big-endian absolute directory offsets; preserve its admitted extent.
face_offsets: []const u8,
/// Nonzero directory count; recorded aliases remain separate face selections.
face_count: u32,
/// Copied framing version; version two carries a digital-signature descriptor.
version: Version,
/// Optional borrowed DSIG bytes, range-checked without interpreting or authenticating them.
signature: ?[]const u8,

/// Malformed collection framing or an unsupported collection signature/version.
pub const OpenError = Directory.OpenError;

/// Opening failures from the selected directory, or an index outside the recorded face count.
pub const FaceError = OpenError || error{InvalidFace};

/// TTC/OTC header version; version two adds a digital-signature descriptor.
pub const Version = enum(u32) {
    /// The fixed header is followed by face offsets, without a signature descriptor.
    v1 = 0x00010000,
    /// Face offsets are followed by a DSIG descriptor; all-zero fields declare no signature.
    v2 = 0x00020000,
};

/// Opens version 1/2 framing without interpreting any member's tables. Every directory must fit,
/// even if the caller will select only one face. Signature bytes are range-checked without
/// cryptographic authentication. Work is linear in the face count, including aliased offsets.
pub fn open(source: []const u8) OpenError!Collection {
    if (source.len < header_size) return error.InvalidFont;
    if (try binary.read(u32, source, 0) != collection_tag) return error.UnsupportedFormat;
    const version = std.enums.fromInt(
        Version,
        try binary.read(u32, source, 4),
    ) orelse return error.UnsupportedFormat;
    const face_count = try binary.read(u32, source, 8);
    if (face_count == 0) return error.InvalidFont;
    const face_count_usize = std.math.cast(usize, face_count) orelse return error.InvalidFont;
    const face_offsets_end = try binary.arrayOffset(header_size, face_count_usize, 4);
    const signature_descriptor_count: usize = @intFromBool(version == .v2);
    const header_end = try binary.arrayOffset(face_offsets_end, signature_descriptor_count, 12);
    if (header_end > source.len) return error.InvalidFont;

    const signature_bytes: ?[]const u8 = blk: {
        if (version == .v1) break :blk null;
        const signature_kind = try binary.read(u32, source, face_offsets_end);
        const signature_length = try binary.read(u32, source, face_offsets_end + 4);
        const signature_offset = try binary.read(u32, source, face_offsets_end + 8);
        if (signature_kind == 0) {
            if (signature_length != 0 or signature_offset != 0) return error.InvalidFont;
            break :blk null;
        }
        if (signature_kind != signature_tag or signature_length == 0) return error.InvalidFont;
        break :blk try binary.slice(source, signature_offset, signature_length);
    };
    const face_offsets = source[header_size..face_offsets_end];
    // Check directory framing for every face now. An unsupported flavor or malformed table in a
    // sibling is checked only if that face is selected.
    for (0..face_count_usize) |index| {
        const directory_offset = std.mem.readInt(u32, face_offsets[index * 4 ..][0..4], .big);
        const directory_position = std.math.cast(
            usize,
            directory_offset,
        ) orelse return error.InvalidFont;
        _ = try directory_layout.endOffset(source, directory_position);
    }
    return .{
        .source = source,
        .face_offsets = face_offsets,
        .face_count = face_count,
        .version = version,
        .signature = signature_bytes,
    };
}

test open {
    // Authored collection framing with two directories and absolute table offsets.
    const source = storage: {
        var bytes: [104]u8 = @splat(0);
        @memcpy(bytes[0..4], "ttcf");
        std.mem.writeInt(u32, bytes[4..8], 0x00020000, .big);
        std.mem.writeInt(u32, bytes[8..12], 2, .big);
        std.mem.writeInt(u32, bytes[12..16], 36, .big);
        std.mem.writeInt(u32, bytes[16..20], 64, .big);
        inline for (
            [_]usize{ 36, 64 },
            [_]u32{ 0x00010000, 0x4f54544f },
            [_]u32{ 92, 96 },
        ) |directory_offset, signature, table_offset| {
            std.mem.writeInt(u32, bytes[directory_offset..][0..4], signature, .big);
            std.mem.writeInt(u16, bytes[directory_offset + 4 ..][0..2], 1, .big);
            @memcpy(bytes[directory_offset + 12 ..][0..4], "DATA");
            std.mem.writeInt(u32, bytes[directory_offset + 20 ..][0..4], table_offset, .big);
            std.mem.writeInt(u32, bytes[directory_offset + 24 ..][0..4], 3, .big);
        }
        @memcpy(bytes[92..95], &[_]u8{ 1, 2, 3 });
        @memcpy(bytes[96..99], &[_]u8{ 4, 5, 6 });
        break :storage bytes;
    };
    const collection = try Collection.open(&source);
    const second = try collection.face(1);
    try std.testing.expectEqual(2, collection.face_count);
    try std.testing.expectEqual(.opentype_cff, second.flavor);
    const data = (try second.find("DATA".*)).?.data;
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, data);
}

/// Admits one member directory and its opaque table ranges. Indices follow recorded order; an index
/// outside face_count returns InvalidFace. The result borrows complete collection bytes, keeping
/// its table offsets absolute. No font semantics or glyph data are decoded.
pub fn face(self: Collection, index: u32) FaceError!Directory {
    if (index >= self.face_count) return error.InvalidFace;
    const offset_record_start = @as(usize, index) * 4;
    const directory_offset = std.mem.readInt(
        u32,
        self.face_offsets[offset_record_start..][0..4],
        .big,
    );
    return Directory.openAt(self.source, directory_offset);
}

test "SFNT collections select absolute shared table ranges and retain unsupported siblings" {
    var source = fixtures.collection();
    const collection = try Collection.open(&source);
    try std.testing.expectEqual(.v2, collection.version);
    try std.testing.expectEqual(null, collection.signature);
    const first_face = try collection.face(0);
    const second_face = try collection.face(1);
    try std.testing.expectEqual(36, first_face.offset);
    try std.testing.expectEqual(64, second_face.offset);
    const data = (try first_face.find("DATA".*)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, data.data);
    try std.testing.expectError(error.InvalidFace, collection.face(2));
    try std.testing.expectError(error.InvalidFace, collection.face(std.math.maxInt(u32)));
    try std.testing.expectError(error.UnsupportedFormat, Directory.open(&source));
    try std.testing.expectError(error.UnsupportedFormat, Collection.open(&fixtures.twoTables()));

    // Valid framing admits both directories before either sibling's flavor or tables are selected.
    fixtures.write(u32, &source, 64, 0xabcdef01);
    const mixed = try Collection.open(&source);
    try std.testing.expectEqual(.truetype, (try mixed.face(0)).flavor);
    try std.testing.expectError(error.UnsupportedFormat, mixed.face(1));

    fixtures.write(u32, &source, 64, 0x4f54544f);
    fixtures.write(u32, &source, 84, 0xffffffff);
    const malformed_payload = try Collection.open(&source);
    _ = try malformed_payload.face(0);
    try std.testing.expectError(error.InvalidFont, malformed_payload.face(1));
}

test "SFNT collection framing checks offsets versions signatures and every truncation" {
    const source = fixtures.collection();
    for (0..92) |length|
        try std.testing.expectError(error.InvalidFont, Collection.open(source[0..length]));
    var signed = source;
    fixtures.write(u32, &signed, 20, signature_tag);
    fixtures.write(u32, &signed, 24, 4);
    fixtures.write(u32, &signed, 28, 100);
    const signature = (try Collection.open(&signed)).signature.?;
    try std.testing.expectEqualSlices(u8, signed[100..104], signature);
    for ([_]struct {
        field: usize,
        value: u32,
        expected: OpenError,
    }{
        .{ .field = 4, .value = 0x00030000, .expected = error.UnsupportedFormat },
        .{ .field = 8, .value = 0, .expected = error.InvalidFont },
        .{ .field = 8, .value = 0xffffffff, .expected = error.InvalidFont },
        .{ .field = 12, .value = 0xfffffff0, .expected = error.InvalidFont },
        .{ .field = 20, .value = 1, .expected = error.InvalidFont },
        .{ .field = 24, .value = 0, .expected = error.InvalidFont },
        .{ .field = 28, .value = 0xffffffff, .expected = error.InvalidFont },
    }) |case| {
        var invalid = signed;
        fixtures.write(u32, &invalid, case.field, case.value);
        try std.testing.expectError(case.expected, Collection.open(&invalid));
    }
    var orphan = source;
    fixtures.write(u32, &orphan, 24, 1);
    try std.testing.expectError(error.InvalidFont, Collection.open(&orphan));
    var version_one = source;
    fixtures.write(u32, &version_one, 4, 0x00010000);
    try std.testing.expectEqual(.v1, (try Collection.open(&version_one)).version);
}
