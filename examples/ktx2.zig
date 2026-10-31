//! Write and inspect a small texture container with one supplied R8 level.
const std = @import("std");
const ktx2 = @import("wingman").ktx2;

pub fn main(init: std.process.Init) !void {
    const samples = [_]ktx2.Sample{
        .{ .bit_offset = 0, .bit_length = 8, .channel_type = 0, .lower = 0, .upper = 255 },
    };
    const descriptor = ktx2.BasicDescriptor{ .color_model = 1, .bytes_plane = .{
        1, 0, 0, 0, 0, 0, 0, 0,
    }, .samples = &samples };
    var descriptor_storage: [44]u8 = undefined;
    const descriptor_bytes = try descriptor.encodeInto(&descriptor_storage);
    const pixels = [_]u8{ 23, 42 };
    const levels = [_]ktx2.Level{.{ .data = &pixels, .uncompressed_size = pixels.len }};
    const texture: ktx2.EncodeTexture = .{
        .header = .{ .vk_format = 9, .width = 2, .height = 1 },
        .descriptor = descriptor_bytes,
        .levels = &levels,
    };
    var storage: [256]u8 = @splat(0xa5);
    const file = try ktx2.encodeInto(&texture, &storage, .{});
    const source = try ktx2.Source.open(file, .{});
    const mip = source.level(0) orelse return error.MissingLevel;
    if (!std.mem.eql(u8, &pixels, mip.data) or storage[file.len] != 0xa5) {
        return error.WrongResult;
    }
    var buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "KTX2: {d} x {d}, {d} level, {d} encoded bytes\n",
        .{ source.header.width, source.header.height, source.header.levelCount(), mip.data.len },
    );
    try output.interface.flush();
}
