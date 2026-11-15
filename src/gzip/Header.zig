//! Parsed header facts. Whole-buffer parsing borrows optional fields from the source. Streaming
//! parsing borrows caller capture buffers, or leaves views empty/null when capture is disabled;
//! lengths and flags remain available. Names/comments are uninterpreted bytes, never paths or UTF-8
//! assumptions.

const std = @import("std");
const Crc32IsoHdlc = @import("../crc.zig").Crc32IsoHdlc;
const format = @import("format.zig");
const fixtures = @import("decode_fixtures.zig");

const signature = format.signature;
const flag_header_crc = format.flag_header_crc;
const flag_extra = format.flag_extra;
const flag_name = format.flag_name;
const flag_comment = format.flag_comment;
const reserved_flags = format.reserved_flags;

const Header = @This();

/// RFC flags, including presence bits for optional fields.
flags: u8,
/// Unix timestamp in seconds; zero means the header provides no timestamp.
modification_time: u32,
/// Compressor's extra flags.
extra_flags: u8,
/// Operating-system identifier as an uninterpreted byte.
operating_system: u8,
/// Borrowed extra-field bytes, empty when uncaptured or absent.
extra: []const u8 = &.{},
/// Borrowed name without NUL; null when uncaptured or absent.
name: ?[]const u8 = null,
/// Borrowed comment without NUL; null when uncaptured or absent.
comment: ?[]const u8 = null,
/// Full extra-field length, even when uncaptured.
extra_length: usize = 0,
/// Full name length, excluding NUL, even when uncaptured.
name_length: usize = 0,
/// Full comment length, excluding NUL, even when uncaptured.
comment_length: usize = 0,

/// Bounds for optional fields, excluding their terminating NUL, and the entire header including its
/// fixed portion and CRC. Bounds never authorize storage.
pub const Limits = struct {
    /// Maximum bytes in each extra, name or comment field.
    field_bytes: usize = 65535,
    /// Maximum total header bytes.
    header_bytes: usize = 262144,
};

/// Header admission or caller capture capacity failure.
pub const Error = error{
    /// Wrong signature, method or flags; incomplete fields; or failed header CRC.
    InvalidStream,
    /// A field/header allowance or supplied capture capacity cannot admit the header.
    HeaderTooLong,
};

/// Parsed borrowed header and its exact byte boundary within supplied source.
pub const Result = struct {
    /// Metadata whose optional byte views borrow the supplied source.
    header: Header,
    /// Header bytes occupied, including the fixed header and optional CRC.
    consumed: usize,
};

/// Parses a bounded complete header without decoding payload. Returned views borrow source until it
/// retires. Reserved flags, wrong methods and FHCRC mismatch reject; optional fields cannot scan
/// beyond the configured bounds.
pub fn parse(source: []const u8, limits: Limits) Error!Result {
    if (source.len < 10) return error.InvalidStream;
    if (!std.mem.eql(u8, source[0..3], &signature)) return error.InvalidStream;
    if (source[3] & reserved_flags != 0) return error.InvalidStream;
    var header: Header = .{
        .flags = source[3],
        .modification_time = std.mem.readInt(u32, source[4..8], .little),
        .extra_flags = source[8],
        .operating_system = source[9],
    };
    var position: usize = 10;
    if (position > limits.header_bytes) return error.HeaderTooLong;
    if (header.flags & flag_extra != 0) {
        if (source.len - position < 2) return error.InvalidStream;
        const size = std.mem.readInt(u16, source[position..][0..2], .little);
        position += 2;
        if (size > limits.field_bytes or position > limits.header_bytes) return error.HeaderTooLong;
        if (size > limits.header_bytes - position) return error.HeaderTooLong;
        if (size > source.len - position) return error.InvalidStream;
        header.extra = source[position..][0..size];
        header.extra_length = size;
        position += size;
    }
    inline for (.{ "name", "comment" }, .{ flag_name, flag_comment }) |field, flag| {
        if (header.flags & flag != 0) {
            const available = @min(source.len - position, limits.header_bytes - position);
            const admitted = @min(available, limits.field_bytes +| 1);
            const length = std.mem.indexOfScalar(u8, source[position..][0..admitted], 0) orelse {
                if (available < source.len - position) return error.HeaderTooLong;
                if (admitted < available or admitted > limits.field_bytes)
                    return error.HeaderTooLong;
                return error.InvalidStream;
            };
            @field(header, field) = source[position..][0..length];
            @field(header, field ++ "_length") = length;
            position += length + 1;
        }
    }
    if (header.flags & flag_header_crc != 0) {
        if (limits.header_bytes - position < 2) return error.HeaderTooLong;
        if (source.len - position < 2) return error.InvalidStream;
        const expected: u16 = @truncate(Crc32IsoHdlc.hash(source[0..position]));
        const recorded = std.mem.readInt(u16, source[position..][0..2], .little);
        if (recorded != expected) return error.InvalidStream;
        position += 2;
    }
    return .{ .header = header, .consumed = position };
}

/// Caller-owned bounded copies for fragmented headers. Enable capture by supplying all desired
/// field capacities; an admitted field must fit in its corresponding buffer. The three spans stay
/// exclusively borrowed until reset or end of use, and must be disjoint from every other
/// reservation/fragment.
pub const CaptureBuffers = struct {
    /// Capacity for the complete extra field.
    extra: []u8 = &.{},
    /// Capacity for the complete name, excluding NUL.
    name: []u8 = &.{},
    /// Capacity for the complete comment, excluding NUL.
    comment: []u8 = &.{},
};

test parse {
    // Independent optional-field member: the complete header ends at byte 41, before DEFLATE.
    const source = &fixtures.optional_fields;
    const parsed = try parse(source, .{});
    try std.testing.expectEqual(41, parsed.consumed);
    try std.testing.expectEqual(123456, parsed.header.modification_time);
    try std.testing.expectEqualStrings("glyph.svg", parsed.header.name.?);
    try std.testing.expectEqualStrings("font comment", parsed.header.comment.?);
    try std.testing.expectEqual(source[12..16].ptr, parsed.header.extra.ptr);
    try std.testing.expectEqual(source[16..25].ptr, parsed.header.name.?.ptr);
    try std.testing.expectEqual(source[26..38].ptr, parsed.header.comment.?.ptr);
    try std.testing.expectError(error.HeaderTooLong, parse(source, .{ .field_bytes = 8 }));
    try std.testing.expectError(error.HeaderTooLong, parse(source, .{ .header_bytes = 20 }));
}
