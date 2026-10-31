//! ETC1 RGB block reconstruction and packing. Base colors and intensity tables describe two halves;
//! selectors advance down columns on the wire and across rows in the caller's tile.

const std = @import("std");
const memory = @import("../common/byte_ranges.zig");
const format = @import("format.zig");

const DecodeError = format.DecodeError;

/// Reads the first eight source bytes and writes the first 64 destination bytes. Extra capacity is
/// untouched. The used spans must be disjoint, and every error preserves the entire destination. No
/// allocation occurs. Each output texel has R, G, B and opaque alpha, in that order.
pub fn decodeBlock(encoded: []const u8, destination: []u8) DecodeError!void {
    if (encoded.len < 8) return error.TruncatedBlock;
    if (destination.len < 64) return error.DestinationTooSmall;
    const source = encoded[0..8];
    const output = destination[0..64];
    if (memory.overlaps(source, output)) return error.OverlappingStorage;
    const high = std.mem.readInt(u32, source[0..4], .big);
    const low = std.mem.readInt(u32, source[4..8], .big);

    var colors: [2][3]u8 = undefined;
    if (high & 2 == 0) {
        for ([_]u5{ 28, 20, 12 }, [_]u5{ 24, 16, 8 }, 0..) |first, second, channel| {
            const first_nibble: u8 = @intCast((high >> first) & 15);
            const second_nibble: u8 = @intCast((high >> second) & 15);
            colors[0][channel] = first_nibble * 17;
            colors[1][channel] = second_nibble * 17;
        }
    } else {
        for ([_]u5{ 27, 19, 11 }, [_]u5{ 24, 16, 8 }, 0..) |base_shift, delta_shift, channel| {
            const base: i16 = @intCast((high >> base_shift) & 31);
            const delta: i3 = @bitCast(@as(u3, @truncate(high >> delta_shift)));
            const second = base + delta;
            if (second < 0 or second > 31) return error.InvalidBlock;
            colors[0][channel] = format.expand5(@intCast(base));
            colors[1][channel] = format.expand5(@intCast(second));
        }
    }

    const tables = [_]u3{ @truncate(high >> 5), @truncate(high >> 2) };
    var palettes: [2][4][4]u8 = undefined;
    for (&palettes, colors, tables) |*palette, color, table| {
        for (palette, format.color_modifiers[table]) |*texel, adjustment| {
            for (color, 0..) |base, channel| {
                texel[channel] = @intCast(std.math.clamp(@as(i16, base) + adjustment, 0, 255));
            }
            texel[3] = 255;
        }
    }

    const horizontal = high & 1 != 0;
    for (0..4) |y| for (0..4) |x| {
        // ETC1 numbers selector bits down columns, while RGBA output advances across rows.
        const bit: u5 = @intCast(x * 4 + y);
        const selector_low = (low >> bit) & 1;
        const selector_high = (low >> (bit + 16)) & 1;
        const selector = selector_low | (selector_high << 1);
        const half = @intFromBool(if (horizontal) y >= 2 else x >= 2);
        const texel = (y * 4 + x) * 4;
        @memcpy(output[texel..][0..4], &palettes[half][selector]);
    };
}

test decodeBlock {
    const encoded = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var rgba: [64]u8 = undefined;
    try decodeBlock(&encoded, &rgba);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 255 }, rgba[0..4]);
}

test "ETC1 all intensity tables and selector signs follow the independent wire tables" {
    const expected = [4][8]u8{ .{
        138, 141, 145, 149, 154, 160, 169, 183,
    }, .{
        144, 153, 165, 178, 196, 216, 242, 255,
    }, .{
        134, 131, 127, 123, 118, 112, 103, 89,
    }, .{
        128, 119, 107, 94, 76, 56, 30, 0,
    } };
    for (0..4) |selector| for (0..8) |table| {
        var encoded = [_]u8{ 0x88, 0x88, 0x88, 0, 0, 0, 0, 0 };
        encoded[3] = @as(u8, @intCast(table)) * 36;
        if (selector & 1 != 0) encoded[6..8].* = .{ 0xff, 0xff };
        if (selector & 2 != 0) encoded[4..6].* = .{ 0xff, 0xff };
        var rgba: [64]u8 = undefined;
        try decodeBlock(&encoded, &rgba);
        for (0..16) |texel| {
            const value = expected[selector][table];
            try std.testing.expectEqualSlices(u8, &.{
                value, value, value, 255,
            }, rgba[texel * 4 ..][0..4]);
        }
    };
}

test "ETC1 selector columns, half orientation and differential expansion remain distinct" {
    var rgba: [64]u8 = undefined;
    try decodeBlock(&.{ 0x88, 0x88, 0x88, 0, 0x40, 0, 0, 2 }, &rgba);
    try std.testing.expectEqual(144, rgba[(1 * 4 + 0) * 4]);
    try std.testing.expectEqual(134, rgba[(2 * 4 + 3) * 4]);
    try std.testing.expectEqual(138, rgba[4]);

    for ([_]u8{ 0, 1 }) |flip| {
        try decodeBlock(&.{ 0xf0, 0, 0, flip, 0, 0, 0, 0 }, &rgba);
        for (0..4) |y| for (0..4) |x| {
            const first = if (flip != 0) y < 2 else x < 2;
            try std.testing.expectEqual(if (first) @as(u8, 255) else 2, rgba[(y * 4 + x) * 4]);
        };
    }

    const high: u32 = (16 << 27) | (4 << 24) | (15 << 19) | (3 << 16) | (7 << 11) | 2;
    var encoded: [8]u8 = @splat(0);
    std.mem.writeInt(u32, encoded[0..4], high, .big);
    try decodeBlock(&encoded, &rgba);
    try std.testing.expectEqualSlices(u8, &.{ 134, 125, 59, 255 }, rgba[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 101, 150, 59, 255 }, rgba[8..12]);
}

test "ETC1 admission preserves destination and spare capacity" {
    var output: [80]u8 = @splat(0xa5);
    const before = output;
    try std.testing.expectError(error.TruncatedBlock, decodeBlock(&.{ 0, 0 }, &output));
    try std.testing.expectError(
        error.DestinationTooSmall,
        decodeBlock(&@as([8]u8, @splat(0)), output[0..63]),
    );
    try std.testing.expectError(error.OverlappingStorage, decodeBlock(output[0..8], &output));
    try std.testing.expectError(error.InvalidBlock, decodeBlock(&.{
        4, 0, 0, 2, 0, 0, 0, 0,
    }, &output));
    try std.testing.expectEqualSlices(u8, &before, &output);
    try decodeBlock(&@as([8]u8, @splat(0)), &output);
    try std.testing.expectEqualSlices(u8, before[64..], output[64..]);
}

/// Packs admitted quantized colors and row-major selectors. Differential endpoints must already
/// differ by -4..3 in each channel; individual endpoints must fit four bits.
pub fn pack(encoding: format.ColorEncoding, selectors: *const [16]u2, output: *[8]u8) void {
    for (0..3) |channel| {
        const first = encoding.colors[0][channel];
        const second = encoding.colors[1][channel];
        if (encoding.differential) {
            std.debug.assert(first <= 31 and second <= 31);
            const delta = @as(i16, second) - first;
            std.debug.assert(delta >= -4 and delta <= 3);
            const bits: u3 = @bitCast(@as(i3, @intCast(delta)));
            output[channel] = (first << 3) | bits;
        } else {
            std.debug.assert(first <= 15 and second <= 15);
            output[channel] = (first << 4) | second;
        }
    }
    const first_table = @as(u8, encoding.tables[0]) << 5;
    const second_table = @as(u8, encoding.tables[1]) << 2;
    const differential = @as(u8, @intFromBool(encoding.differential)) << 1;
    output[3] = first_table | second_table | differential | @intFromBool(encoding.horizontal);
    var word: u32 = 0;
    for (selectors, 0..) |selector, pixel| {
        const column_bit: u5 = @intCast((pixel % 4) * 4 + pixel / 4);
        word |= @as(u32, selector & 1) << column_bit;
        word |= @as(u32, selector >> 1) << (column_bit + 16);
    }
    std.mem.writeInt(u32, output[4..8], word, .big);
}

/// Selects the nearest palette entry in weighted luma, using stored RGB weights 54:183:19. Equal
/// distances choose the brighter entry. Quantized endpoints are the actual values to be packed.
pub fn select(encoding: format.ColorEncoding, pixels: *const [16][4]u8) [16]u2 {
    var boundaries: [2][3]u32 = undefined;
    for (encoding.colors, encoding.tables, &boundaries) |quantized, table, *half| {
        var base: [3]u8 = undefined;
        for (quantized, &base) |value, *expanded| {
            expanded.* = if (encoding.differential) format.expand5(value) else value * 17;
        }
        const palette = format.colorPalette(base, table);
        const order = [_]u2{ 3, 2, 0, 1 };
        for (half, 0..) |*boundary, index| {
            boundary.* = luma(palette[order[index]]) + luma(palette[order[index + 1]]);
        }
    }
    var result: [16]u2 = undefined;
    for (pixels, &result, 0..) |pixel, *selector, index| {
        const half = if (encoding.horizontal) index / 8 else (index % 4) / 2;
        const doubled = 2 * luma(pixel[0..3].*);
        selector.* = blk: {
            if (doubled < boundaries[half][0]) break :blk 3;
            if (doubled < boundaries[half][1]) break :blk 2;
            if (doubled < boundaries[half][2]) break :blk 0;
            break :blk 1;
        };
    }
    return result;
}

fn luma(rgb: [3]u8) u32 {
    return @as(u32, rgb[0]) * 54 + @as(u32, rgb[1]) * 183 + @as(u32, rgb[2]) * 19;
}
