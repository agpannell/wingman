//! Compute an IEEE checksum and show how gzip and PNG choose its bytes.
const std = @import("std");
const crc32 = @import("wingman").crc32;

/// The optional argument is the exact text to checksum; the default is the standard nine digits.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const input = if (args.len > 1) args[1] else "123456789";
    const split = input.len / 2;
    const complete = crc32.hash(input);
    var stream: crc32.Hasher = .init;
    stream.update(input[0..split]);
    stream.update(input[split..]);
    const combined = crc32.combine(
        crc32.hash(input[0..split]),
        crc32.hash(input[split..]),
        input.len - split,
    );
    if (stream.final() != complete or combined != complete) return error.ChecksumMismatch;

    var gzip_field: [4]u8 = undefined;
    std.mem.writeInt(u32, &gzip_field, complete, .little);
    var png_field: [4]u8 = undefined;
    std.mem.writeInt(u32, &png_field, crc32.hash("IEND"), .big);
    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print("IEEE CRC-32: {x:0>8}\n", .{complete});
    try output.interface.print("bytes: {d}; streaming and combination agree\n", .{input.len});
    try output.interface.print(
        "gzip CRC field: {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n",
        .{ gzip_field[0], gzip_field[1], gzip_field[2], gzip_field[3] },
    );
    try output.interface.print(
        "PNG IEND CRC field: {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n",
        .{ png_field[0], png_field[1], png_field[2], png_field[3] },
    );
    try output.interface.flush();
}
