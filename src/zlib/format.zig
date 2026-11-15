//! RFC 1950 header admission shared by complete and fragmented decoding.

const std = @import("std");

/// Validates exactly the two-byte header without changing caller storage. Requires DEFLATE method
/// 8, CINFO 0..7, valid FCHECK and no preset dictionary. This checks only framing admission; decode
/// also checks payload and checksum.
pub fn validateDictionaryFreeHeader(header: *const [2]u8) error{InvalidStream}!void {
    if (header[1] & 32 != 0) return error.InvalidStream;
    return admitHeader(header);
}

pub fn admitHeader(header: *const [2]u8) error{InvalidStream}!void {
    if (header[0] & 15 != 8 or header[0] >> 4 > 7) return error.InvalidStream;
    const encoded = std.mem.readInt(u16, header, .big);
    if (encoded % 31 != 0) return error.InvalidStream;
}

test "dictionary-free zlib header admission rejects unsupported framing" {
    const valid_headers = [_][2]u8{ .{ 0x08, 0x1d }, .{ 0x18, 0x19 }, .{ 0x78, 0x01 } };
    for (valid_headers) |header| try validateDictionaryFreeHeader(&header);
    for ([_][2]u8{
        .{ 0x00, 0x00 }, // Unsupported compression method.
        .{ 0x88, 0x00 }, // Declared window exceeds 32 KiB.
        .{ 0x78, 0x20 }, // Valid FCHECK with a preset dictionary.
        .{ 0x78, 0x00 }, // Invalid FCHECK.
    }) |header| try std.testing.expectError(
        error.InvalidStream,
        validateDictionaryFreeHeader(&header),
    );
}
