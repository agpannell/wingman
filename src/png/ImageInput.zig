//! Borrowed image description supplied to the PNG encoder. Keep rows, palette and transparency live
//! and unchanged throughout encoding. Samples are stored channel codes; no color conversion is
//! implied.

const std = @import("std");
const format = @import("format.zig");
const ColorType = format.ColorType;
const Samples = format.Samples;
const Transparency = format.Transparency;

const ImageInput = @This();
const Error = error{ InvalidImageExtent, SizeOverflow, InvalidTexelCount };

/// Nonzero PNG width, at most 2^31-1.
width: u32,
/// Nonzero PNG height, at most 2^31-1.
height: u32,
/// Stored channel layout.
color_type: ColorType,
/// PNG-defined sample depth for this layout; word input requires sixteen.
bit_depth: u8,
/// Borrowed packed bytes or native words with an explicit optional row stride.
samples: Samples,
/// Required indexed RGB table; optional suggested palette for RGB/RGBA only.
palette: []const [3]u8 = &.{},
/// Explicit transparent source codes or palette alpha, never inferred from samples.
transparency: Transparency = .none,

/// Borrows exactly width * height * 4 tightly packed RGBA8 bytes. Alpha is unassociated. Invalid
/// dimensions, count overflow or a mismatched sample count are rejected.
pub fn rgba8(texels: []const u8, width: u32, height: u32) Error!ImageInput {
    try validateRgbaCount(texels.len, width, height);
    return .{
        .width = width,
        .height = height,
        .color_type = .rgba,
        .bit_depth = 8,
        .samples = .{ .packed_bytes = .{ .bytes = texels } },
    };
}

test rgba8 {
    try std.testing.expectError(error.InvalidImageExtent, rgba8(&.{}, 0, 1));
    try std.testing.expectError(error.InvalidImageExtent, rgba8(&.{}, 0x80000000, 1));
    try std.testing.expectError(error.InvalidTexelCount, rgba8(&.{}, 1, 1));
}

/// Borrows exactly width * height * 4 tightly packed native RGBA words. Alpha is unassociated.
/// Returns InvalidImageExtent for zero or oversized axes, SizeOverflow if the required count does
/// not fit usize, and InvalidTexelCount if the slice length differs.
pub fn rgba16(texels: []const u16, width: u32, height: u32) Error!ImageInput {
    try validateRgbaCount(texels.len, width, height);
    return .{
        .width = width,
        .height = height,
        .color_type = .rgba,
        .bit_depth = 16,
        .samples = .{ .words = .{ .values = texels } },
    };
}

fn validateRgbaCount(count: usize, width: u32, height: u32) Error!void {
    if (width == 0 or height == 0 or width > 0x7fffffff or height > 0x7fffffff)
        return error.InvalidImageExtent;
    const pixels_count = std.math.mul(usize, width, height) catch return error.SizeOverflow;
    const required = std.math.mul(usize, pixels_count, 4) catch return error.SizeOverflow;
    if (count != required) return error.InvalidTexelCount;
}
