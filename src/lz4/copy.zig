//! Copies for LZ4's nonoverlapping spans, selected by the compile-time target.

const std = @import("std");

/// Vector width follows the selected target; unaligned spans need no padding.
pub fn nonOverlapping(destination: []u8, source: []const u8) void {
    std.debug.assert(destination.len == source.len);
    if (comptime std.simd.suggestVectorLength(u8)) |width| {
        const Vector = @Vector(width, u8);
        var cursor: usize = 0;

        while (source.len - cursor >= width) : (cursor += width) {
            const from: *align(1) const Vector = @ptrCast(source.ptr + cursor);
            const to: *align(1) Vector = @ptrCast(destination.ptr + cursor);
            to.* = from.*;
        }
        // The final partial vector must not read or write beyond either span.
        @memcpy(destination[cursor..], source[cursor..]);
    } else {
        @memcpy(destination, source);
    }
}

test "vector copy preserves unaligned output boundaries" {
    var source: [65537 + 5]u8 = undefined;
    var destination: [65537 + 11]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index *% 137);
    for (
        [_]usize{ 0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 8191, 8192, 8193, 65535, 65536, 65537 },
    ) |length| {
        @memset(&destination, 0xa5);
        nonOverlapping(destination[3..][0..length], source[5..][0..length]);
        try std.testing.expectEqualSlices(u8, source[5..][0..length], destination[3..][0..length]);
        for (destination[0..3]) |byte| {
            try std.testing.expectEqual(@as(u8, 0xa5), byte);
        }
        for (destination[3 + length ..]) |byte| {
            try std.testing.expectEqual(@as(u8, 0xa5), byte);
        }
    }
}
