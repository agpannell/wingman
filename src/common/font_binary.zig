//! Checked big-endian font reads, array positions and disjoint storage admission.

const std = @import("std");

/// Arithmetic overflow or an integer whose complete bytes are not present.
pub const Error = error{InvalidFont};

/// Checks two byte spans without reading them. Empty and adjacent spans are disjoint. Overlap or an
/// unrepresentable exclusive address end returns StorageOverlap before mutation. Use this for
/// immutable source, descriptors and caller working storage at allocation-free reader boundaries;
/// the owning operation still selects every span whose lifetime it protects.
pub fn admitDisjoint(first: []const u8, second: []const u8) error{StorageOverlap}!void {
    if (first.len == 0 or second.len == 0) return;
    const a = @intFromPtr(first.ptr);
    const b = @intFromPtr(second.ptr);
    const a_end = std.math.add(usize, a, first.len) catch return error.StorageOverlap;
    const b_end = std.math.add(usize, b, second.len) catch return error.StorageOverlap;
    if (a < b_end and b < a_end) return error.StorageOverlap;
}

test "checked byte storage admits empty adjacency and rejects overlap or wrapped addresses" {
    var bytes: [24]u8 = undefined;
    try admitDisjoint(bytes[0..8], bytes[8..16]);
    try admitDisjoint(bytes[0..8], bytes[16..24]);
    try admitDisjoint(bytes[0..0], &bytes);
    try std.testing.expectError(error.StorageOverlap, admitDisjoint(bytes[0..8], bytes[7..16]));
    try std.testing.expectError(error.StorageOverlap, admitDisjoint(&bytes, bytes[8..16]));
    const wrapped = @as([*]const u8, @ptrFromInt(std.math.maxInt(usize) - 3))[0..8];
    try std.testing.expectError(error.StorageOverlap, admitDisjoint(wrapped, bytes[0..1]));
}

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
