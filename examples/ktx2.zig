//! Write and inspect a small texture container with one supplied R8 level.
const std = @import("std");
const wingman = @import("wingman");
const ktx2 = wingman.ktx2;
const KhronosDataFormatDescriptor = wingman.KhronosDataFormatDescriptor;

// Vulkan R8_UNORM and Khronos RGBSDA describe one unsigned normalized red byte per texel.
const vk_format_r8_unorm = 9;
const color_model_rgbsda = 1;

pub fn main(init: std.process.Init) !void {
    const samples = [_]KhronosDataFormatDescriptor.Sample{
        .{ .bit_offset = 0, .bit_length = 8, .channel_type = 0, .lower = 0, .upper = 255 },
    };
    const descriptor = KhronosDataFormatDescriptor.BasicInput{
        .color_model = color_model_rgbsda,
        .bytes_plane = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
        .samples = &samples,
    };
    // Four-byte total size, 24-byte basic header and one 16-byte sample record.
    var descriptor_storage: [44]u8 = undefined;
    const descriptor_bytes = try descriptor.encodeInto(&descriptor_storage);
    const pixels = [_]u8{ 23, 42 };
    const levels = [_]ktx2.Level{.{ .data = &pixels, .uncompressed_size = pixels.len }};
    const texture: ktx2.TextureInput = .{
        .header = .{ .vk_format = vk_format_r8_unorm, .width = 2, .height = 1 },
        .descriptor = descriptor_bytes,
        .levels = &levels,
    };
    var storage: [256]u8 = @splat(0xa5);
    const file = try texture.encodeInto(&storage, .{});
    const container = try ktx2.Container.open(file, .{});
    const mip = container.level(0) orelse return error.MissingLevel;
    if (!std.mem.eql(u8, &pixels, mip.data) or storage[file.len] != 0xa5) {
        return error.WrongResult;
    }
    var buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "KTX2: {d} x {d}, {d} level, {d} encoded bytes\n",
        .{
            container.header.width,
            container.header.height,
            container.header.levelCount(),
            mip.data.len,
        },
    );
    try output.interface.flush();
}
