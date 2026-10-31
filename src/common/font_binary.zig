//! Checked big-endian font reads and array positions, without allocation or source mutation.

const std = @import("std");

/// Arithmetic overflow or an integer whose complete bytes are not present.
pub const Error = error{InvalidFont};

/// Reads a whole-byte signed or unsigned integer in big-endian order. Rejects overflow and
/// truncation before reading caller-owned bytes. The integer representation must be accepted by
/// std.mem.readInt with its storage byte count. Use fixed-width integers whose storage size equals
/// their encoded width, such as i16 or u32; variable-width and packed encodings need their own
/// reader.
pub fn read(comptime T: type, bytes: []const u8, offset: usize) Error!T {
    const end = std.math.add(usize, offset, @sizeOf(T)) catch return error.InvalidFont;
    if (end > bytes.len) return error.InvalidFont;
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .big);
}

/// Computes an array record's start or an array's exclusive end without wrapping. `count` is the
/// preceding element count; zero count or stride keeps `start`. The caller checks the returned
/// position and complete record against source bytes.
pub fn arrayOffset(start: usize, count: usize, stride: usize) Error!usize {
    const bytes = std.math.mul(usize, count, stride) catch return error.InvalidFont;
    return std.math.add(usize, start, bytes) catch return error.InvalidFont;
}

test "big-endian reads preserve signed values and reject incomplete ranges" {
    const bytes = [_]u8{ 0x54, 0x61, 0x67, 0x21, 0xff, 0x80 };
    try std.testing.expectEqual(0x5461, try read(u16, &bytes, 0));
    try std.testing.expectEqual(0x54616721, try read(u32, &bytes, 0));
    try std.testing.expectEqual(0x6167, try read(u16, &bytes, 1));
    try std.testing.expectEqual(-128, try read(i16, &bytes, 4));
    try std.testing.expectEqual(-128, try read(i8, &bytes, 5));
    try std.testing.expectError(error.InvalidFont, read(u8, &.{}, 0));
    try std.testing.expectError(error.InvalidFont, read(u16, &bytes, 5));
    try std.testing.expectError(error.InvalidFont, read(u32, &bytes, 3));
    try std.testing.expectError(error.InvalidFont, read(u64, &bytes, 0));
    try std.testing.expectError(error.InvalidFont, read(u8, &bytes, std.math.maxInt(usize)));
    try std.testing.expectError(error.InvalidFont, read(u16, &bytes, std.math.maxInt(usize) - 1));
}

test "array positions preserve empty ranges and reject arithmetic overflow" {
    try std.testing.expectEqual(17, try arrayOffset(5, 3, 4));
    try std.testing.expectEqual(5, try arrayOffset(5, 0, std.math.maxInt(usize)));
    try std.testing.expectEqual(5, try arrayOffset(5, std.math.maxInt(usize), 0));
    try std.testing.expectError(error.InvalidFont, arrayOffset(0, std.math.maxInt(usize), 2));
    try std.testing.expectError(error.InvalidFont, arrayOffset(std.math.maxInt(usize), 1, 1));
}
