//! Fit and reconstruct one ETC1 color block and one EAC alpha block.
const std = @import("std");
const etc = @import("wingman").etc;

pub fn main(init: std.process.Init) !void {
    // Complete 4x4 tiles include edge padding chosen by the caller.
    const pixels: [16][4]u8 = @splat(.{ 0, 0, 0, 103 });
    const alpha: [16]u8 = @splat(103);
    var color_block: [8]u8 = undefined;
    var alpha_block: [8]u8 = undefined;
    try etc.encodeBlock(&pixels, &color_block, .{ .effort = .balanced });
    try etc.encodeAlphaBlock(&alpha, &alpha_block, .{});

    var reconstructed: [64]u8 = undefined;
    var reconstructed_alpha: [16]u8 = undefined;
    try etc.decodeBlock(&color_block, &reconstructed);
    try etc.decodeAlphaBlock(&alpha_block, &reconstructed_alpha);
    if (!std.mem.eql(u8, reconstructed[0..4], &.{
        0, 0, 0, 255,
    }) or !std.mem.eql(u8, &reconstructed_alpha, &alpha)) return error.WrongResult;

    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "ETC1: {d} bytes, first RGB {d}/{d}/{d}; EAC alpha: {d} bytes, first {d}\n",
        .{
            color_block.len,
            reconstructed[0],
            reconstructed[1],
            reconstructed[2],
            alpha_block.len,
            reconstructed_alpha[0],
        },
    );
    try output.interface.flush();
}
