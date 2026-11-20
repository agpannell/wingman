//! Authored SFNT and collection storage for independent, fixed container assertions.

const std = @import("std");

pub fn write(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .big);
}

pub fn twoTables() [64]u8 {
    var bytes: [64]u8 = @splat(0);
    write(u32, &bytes, 0, 0x00010000);
    write(u16, &bytes, 4, 2);
    @memset(bytes[6..12], 255); // Ignore deliberately incorrect search accelerator fields.
    @memcpy(bytes[12..16], "DATA");
    @memcpy(bytes[28..32], "ZZZZ");
    for ([_]usize{ 12, 28 }) |offset| {
        write(u32, &bytes, offset + 4, 0x01020300);
        write(u32, &bytes, offset + 8, 49);
        write(u32, &bytes, offset + 12, 3);
    }
    @memcpy(bytes[49..52], &[_]u8{ 1, 2, 3 });
    return bytes;
}

pub fn collection() [104]u8 {
    var bytes: [104]u8 = @splat(0);
    @memcpy(bytes[0..4], "ttcf");
    write(u32, &bytes, 4, 0x00020000);
    write(u32, &bytes, 8, 2);
    write(u32, &bytes, 12, 36);
    write(u32, &bytes, 16, 64);
    inline for (.{ .{ 36, 0x00010000, 92 }, .{ 64, 0x4f54544f, 96 } }) |face| {
        write(u32, &bytes, face[0], face[1]);
        write(u16, &bytes, face[0] + 4, 1);
        @memcpy(bytes[face[0] + 12 ..][0..4], "DATA");
        write(u32, &bytes, face[0] + 20, face[2]);
        write(u32, &bytes, face[0] + 24, 3);
    }
    @memcpy(bytes[92..95], &[_]u8{ 1, 2, 3 });
    @memcpy(bytes[96..99], &[_]u8{ 4, 5, 6 });
    return bytes;
}
