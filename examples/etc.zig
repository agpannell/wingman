//! Fit and reconstruct a varying 4x4 tile, comparing bounded effort and component error.
const std = @import("std");
const etc = @import("wingman").etc;

pub fn main(init: std.process.Init) !void {
    // Row-major texels form a color gradient, a repeating blue pattern and an alpha ramp. Complete
    // tiles include any edge padding chosen by the caller.
    var pixels: [16][4]u8 = undefined;
    var alpha: [16]u8 = undefined;
    var red: [16]u8 = undefined;
    for (&pixels, &alpha, &red, 0..) |*pixel, *alpha_sample, *red_sample, index| {
        const x = index % 4;
        const y = index / 4;
        pixel.* = .{
            @intCast(x * 64 + 15),
            @intCast(y * 64 + 9),
            @intCast((x + y) % 4 * 53 + 17),
            @intCast(index * 17),
        };
        alpha_sample.* = pixel[3];
        red_sample.* = pixel[0];
    }

    var buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.writeAll(
        "4x4 tile; squared error sums (RGB/alpha8: byte values, R11: 11-bit values):\n",
    );
    var previous_error: [3]u64 = @splat(std.math.maxInt(u64));
    for ([_]etc.Effort{ .fast, .balanced, .refined }) |effort| {
        const options: etc.EncodeOptions = .{ .effort = effort };
        var color_block: [8]u8 = undefined;
        var alpha_block: [8]u8 = undefined;
        var red_block: [8]u8 = undefined;
        try etc.encodeBlock(&pixels, &color_block, options);
        try etc.encodeAlphaBlock(&alpha, &alpha_block, options);
        try etc.encodeR11Block(&red, &red_block, options);

        var reconstructed: [64]u8 = undefined;
        var reconstructed_alpha: [16]u8 = undefined;
        var reconstructed_red: [16]u16 = undefined;
        try etc.decodeBlock(&color_block, &reconstructed);
        try etc.decodeAlphaBlock(&alpha_block, &reconstructed_alpha);
        try etc.decodeR11Block(&red_block, &reconstructed_red);

        var error_squared: [3]u64 = @splat(0);
        for (pixels, 0..) |pixel, index| {
            for (pixel[0..3], reconstructed[index * 4 ..][0..3]) |original, decoded| {
                error_squared[0] += squaredDifference(original, decoded);
            }
            error_squared[1] += squaredDifference(alpha[index], reconstructed_alpha[index]);
            // R11 fitting rounds normalized input bytes to the nearest eleven-bit value.
            const target_red = (@as(u32, red[index]) * 2047 + 127) / 255;
            error_squared[2] += squaredDifference(target_red, reconstructed_red[index]);
            if (reconstructed_red[index] > 2047 or reconstructed[index * 4 + 3] != 255)
                return error.WrongResult;
            // ETC1 color is opaque; assemble separately decoded alpha8 into RGBA explicitly.
            reconstructed[index * 4 + 3] = reconstructed_alpha[index];
        }
        for (error_squared, previous_error) |current, previous| {
            if (current > previous) return error.WrongResult;
        }
        if (error_squared[0] == 0 or error_squared[1] == 0) return error.ExpectedLossyTile;
        previous_error = error_squared;
        try output.interface.print(
            "{s}: RGB8 {d}, alpha8 {d}, R11 {d}\n",
            .{ @tagName(effort), error_squared[0], error_squared[1], error_squared[2] },
        );
        try output.interface.print(
            "  first RGBA {d}/{d}/{d}/{d}, R11 {d}\n",
            .{
                reconstructed[0],
                reconstructed[1],
                reconstructed[2],
                reconstructed[3],
                reconstructed_red[0],
            },
        );
    }
    try output.interface.flush();
}

fn squaredDifference(a: u32, b: u32) u64 {
    const difference = @as(i64, a) - b;
    return @intCast(difference * difference);
}
