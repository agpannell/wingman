//! Encode and decode a two-pixel RGBA PNG.
const std = @import("std");
const png = @import("wingman").png;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const pixels = [_]u8{ 255, 0, 0, 128, 0, 100, 200, 255 };
    const image = try png.ImageInput.rgba8(&pixels, 2, 1);
    const encoded = try png.encode.alloc(allocator, image, .{});
    defer allocator.free(encoded);
    const source = try png.Source.open(encoded, .{});
    var decoded = try png.decode.rgbaAlloc(u8, allocator, encoded, .{});
    defer decoded.deinit(allocator);
    if (!std.mem.eql(u8, &pixels, decoded.texels)) return error.RoundTripMismatch;
    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "PNG: {d} x {d}, {d} encoded bytes; RGBA samples verified\n",
        .{ source.width, source.height, encoded.len },
    );
    try output.interface.flush();
}
