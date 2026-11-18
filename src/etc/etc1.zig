//! ETC1 RGB blocks: individual mode stores two four-bit base colors; differential mode stores a
//! five-bit first base and signed deltas to its partner. A horizontal or vertical split assigns
//! eight texels to each base. Each texel selects one of four clamped intensity adjustments.
//!
//! Decoding maps column-major wire selectors into row-major opaque RGBA8. Fitting considers both
//! splits and endpoint modes, scores eight RGB texels in parallel, and keeps earlier whole-block
//! candidates as effort increases. This matters because a changed first endpoint restricts its
//! legal differential partner. Packing, palettes and fitting models belong to this format owner.
const std = @import("std");
const memory = @import("../common/byte_ranges.zig");
const etc = @import("../etc.zig");

// Quantized endpoint pairs and their wire mode. Fitting admits field ranges before packing.
const Encoding = struct {
    /// RGB codes for both halves: four bits in individual mode, five bits in differential mode.
    colors: [2][3]u8,
    /// Intensity-table indices for the two halves.
    tables: [2]u3,
    /// Five-bit first endpoint with a signed -4..3 delta to the second endpoint when true.
    differential: bool,
    /// Top/bottom halves when true, left/right halves when false.
    horizontal: bool,

    fn pack(self: Encoding, selectors: *const [16]u2, output: *[8]u8) void {
        for (0..3) |channel| {
            const first = self.colors[0][channel];
            const second = self.colors[1][channel];
            if (self.differential) {
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
        const first_table = @as(u8, self.tables[0]) << 5;
        const second_table = @as(u8, self.tables[1]) << 2;
        const differential = @as(u8, @intFromBool(self.differential)) << 1;
        output[3] = first_table | second_table | differential | @intFromBool(self.horizontal);
        var word: u32 = 0;
        for (selectors, 0..) |selector, pixel| {
            const column_bit: u5 = @intCast((pixel % 4) * 4 + pixel / 4);
            word |= @as(u32, selector & 1) << column_bit;
            word |= @as(u32, selector >> 1) << (column_bit + 16);
        }
        std.mem.writeInt(u32, output[4..8], word, .big);
    }
};

/// Reads the first eight source bytes and writes the first 64 destination bytes. Extra capacity is
/// untouched. The used spans must be disjoint, and every error preserves the entire destination. No
/// allocation occurs. Each output texel has R, G, B and opaque alpha, in that order.
pub fn decodeBlock(encoded: []const u8, destination: []u8) etc.DecodeError!void {
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
            colors[0][channel] = expand5(@intCast(base));
            colors[1][channel] = expand5(@intCast(second));
        }
    }

    const tables = [_]u3{ @truncate(high >> 5), @truncate(high >> 2) };
    var palettes: [2][4][4]u8 = undefined;
    for (&palettes, colors, tables) |*palette, color, table| {
        for (palette, intensity_modifiers[table]) |*texel, adjustment| {
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
    const expected = [4][8]u8{
        .{ 138, 141, 145, 149, 154, 160, 169, 183 },
        .{ 144, 153, 165, 178, 196, 216, 242, 255 },
        .{ 134, 131, 127, 123, 118, 112, 103, 89 },
        .{ 128, 119, 107, 94, 76, 56, 30, 0 },
    };
    for (0..4) |selector| for (0..8) |table| {
        var encoded = [_]u8{ 0x88, 0x88, 0x88, 0, 0, 0, 0, 0 };
        encoded[3] = @as(u8, @intCast(table)) * 36;
        if (selector & 1 != 0) encoded[6..8].* = .{ 0xff, 0xff };
        if (selector & 2 != 0) encoded[4..6].* = .{ 0xff, 0xff };
        var rgba: [64]u8 = undefined;
        try decodeBlock(&encoded, &rgba);
        for (0..16) |texel| {
            const value = expected[selector][table];
            try std.testing.expectEqualSlices(
                u8,
                &.{ value, value, value, 255 },
                rgba[texel * 4 ..][0..4],
            );
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
    try std.testing.expectError(
        error.InvalidBlock,
        decodeBlock(&.{ 4, 0, 0, 2, 0, 0, 0, 0 }, &output),
    );
    try std.testing.expectEqualSlices(u8, &before, &output);
    try decodeBlock(&@as([8]u8, @splat(0)), &output);
    try std.testing.expectEqualSlices(u8, before[64..], output[64..]);
}

fn expand5(value: u8) u8 {
    return (value << 3) | (value >> 2);
}

fn makePalette(base: [3]u8, table: u3) [4][3]u8 {
    var result: [4][3]u8 = undefined;
    for (&result, intensity_modifiers[table]) |*entry, modifier| {
        for (entry, base) |*component, value| {
            component.* = @intCast(std.math.clamp(@as(i16, value) + modifier, 0, 255));
        }
    }
    return result;
}

/// Conservative per-block admission: 1024 setup units plus 128 per half-block candidate, with at
/// most 64/192/704 candidates for fast/balanced/refined. Units are policy, not elapsed time.
pub fn colorWorkUnits(effort: etc.Effort) u64 {
    const candidates: u64 = switch (effort) {
        .fast => 64,
        .balanced => 192,
        .refined => 704,
    };
    return 1024 + 128 * candidates;
}

/// Fits an admitted RGBA tile using stored-byte RGB error; alpha does not participate.
pub fn fitBlock(texels: *const [16][4]u8, effort: etc.Effort, output: *[8]u8) void {
    if (hasConstantRgb(texels)) {
        fitConstantRgb(texels[0][0..3].*, output);
        return;
    }

    var best_error: u32 = std.math.maxInt(u32);
    // A refined first base can restrict its differential partner. Retain earlier whole-block
    // candidates, rather than assuming that improving each half improves the legal pair.
    for (0..@as(usize, @backingInt(effort)) + 1) |stage| {
        for ([_]bool{ false, true }) |horizontal| {
            var halves: [2][8][3]u8 = undefined;
            for (&halves, 0..) |*half, part| {
                for (half, 0..) |*pixel, i| {
                    const index = halfTexelIndex(horizontal, part, i);
                    pixel.* = texels[index][0..3].*;
                }
            }
            for ([_]bool{ false, true }) |differential| {
                const limit: u8 = if (differential) 31 else 15;
                const first = fitHalf(&halves[0], differential, @splat(0), @splat(limit), stage);
                var low: [3]u8 = @splat(0);
                var high: [3]u8 = @splat(limit);
                if (differential) {
                    for (&low, &high, first.base) |*minimum, *maximum, base| {
                        minimum.* = base -| 4;
                        maximum.* = @min(31, base + 3);
                    }
                }
                const second = fitHalf(&halves[1], differential, low, high, stage);
                const error_squared = first.error_squared + second.error_squared;
                if (error_squared >= best_error) continue;
                best_error = error_squared;
                var selectors: [16]u2 = undefined;
                for ([_]FittedHalf{ first, second }, 0..) |half, part| {
                    for (half.selectors, 0..) |selector, i| {
                        selectors[halfTexelIndex(horizontal, part, i)] = selector;
                    }
                }
                const encoding: Encoding = .{
                    .colors = .{ first.base, second.base },
                    .tables = .{ first.table, second.table },
                    .differential = differential,
                    .horizontal = horizontal,
                };
                encoding.pack(&selectors, output);
            }
        }
    }
}

// One half's quantized base, chosen table/selectors and complete RGB squared error.
const FittedHalf = struct { base: [3]u8, table: u3, selectors: [8]u2, error_squared: u32 };

// Each lane keeps one texel's position within the half-block. Loading channels once lets every
// palette candidate score those eight texels together without transposing them again.
const HalfBlockSamples = struct {
    channels: [3]@Vector(8, i32),
    sums: [3]i32,

    fn init(pixels: *const [8][3]u8) HalfBlockSamples {
        var result: HalfBlockSamples = .{ .channels = undefined, .sums = @splat(0) };
        inline for (pixels, 0..) |pixel, index| {
            for (&result.channels, &result.sums, pixel) |*channel, *sum, value| {
                channel.*[index] = value;
                sum.* += value;
            }
        }
        return result;
    }
};

// Start each table from the quantized mean. Stage one refits after subtracting selected modifiers;
// stage two also scores adjacent channel codes. Bounds keep differential partners legal.
fn fitHalf(
    pixels: *const [8][3]u8,
    differential: bool,
    low: [3]u8,
    high: [3]u8,
    stage: usize,
) FittedHalf {
    const samples = HalfBlockSamples.init(pixels);
    const limit: u8 = if (differential) 31 else 15;
    var mean: [3]u8 = undefined;
    for (&mean, samples.sums, low, high) |*value, sum, minimum, maximum| {
        value.* = std.math.clamp(quantizeSum(sum, limit), minimum, maximum);
    }

    var best: FittedHalf = undefined;
    best.error_squared = std.math.maxInt(u32);
    for (0..8) |table_index| {
        const table: u3 = @intCast(table_index);
        var candidate = scoreHalf(&samples, mean, table, differential);
        if (stage >= 1) {
            var adjusted = samples.sums;
            for (candidate.selectors) |selector| {
                const modifier = intensity_modifiers[table][selector];
                for (&adjusted) |*sum| sum.* -= modifier;
            }
            var refitted: [3]u8 = undefined;
            for (&refitted, adjusted, low, high) |*value, sum, minimum, maximum| {
                value.* = std.math.clamp(quantizeSum(sum, limit), minimum, maximum);
            }
            const next = scoreHalf(&samples, refitted, table, differential);
            if (next.error_squared < candidate.error_squared) candidate = next;
        }
        if (stage >= 2) {
            const center = candidate.base;
            for (0..3) |channel| {
                for ([_]i16{ -1, 1 }) |delta| {
                    var adjacent = center;
                    const code = @as(i16, center[channel]) + delta;
                    adjacent[channel] = @intCast(std.math.clamp(code, low[channel], high[channel]));
                    const next = scoreHalf(&samples, adjacent, table, differential);
                    if (next.error_squared < candidate.error_squared) candidate = next;
                }
            }
        }
        if (candidate.error_squared < best.error_squared) best = candidate;
    }
    return best;
}

fn quantizeSum(sum: i32, limit: u8) u8 {
    const bounded: u32 = @intCast(std.math.clamp(sum, 0, 8 * 255));
    return @intCast((bounded * limit + 4 * 255) / (8 * 255));
}

fn scoreHalf(
    pixels: *const HalfBlockSamples,
    base: [3]u8,
    table: u3,
    differential: bool,
) FittedHalf {
    var expanded: [3]u8 = undefined;
    for (&expanded, base) |*value, code| {
        value.* = if (differential) expand5(code) else code * 17;
    }
    const palette = makePalette(expanded, table);
    var least: @Vector(8, u32) = @splat(std.math.maxInt(u32));
    var selectors: @Vector(8, u32) = @splat(0);
    inline for (palette, 0..) |entry, index| {
        var error_squared: @Vector(8, u32) = @splat(0);
        inline for (0..3) |channel| {
            const difference = pixels.channels[channel] - @as(
                @Vector(8, i32),
                @splat(entry[channel]),
            );
            error_squared += @intCast(difference * difference);
        }
        // Strict improvement retains the first wire selector on equal error, including palettes
        // whose entries coincide after clamping. Integer reduction preserves exact tile scores.
        const improved = error_squared < least;
        selectors = @select(u32, improved, @as(@Vector(8, u32), @splat(index)), selectors);
        least = @min(least, error_squared);
    }
    const indices: @Vector(8, u2) = @intCast(selectors);
    return .{
        .base = base,
        .table = table,
        .selectors = indices,
        .error_squared = @reduce(.Add, least),
    };
}

fn squaredError(a: [3]u8, b: [3]u8) u32 {
    var result: u32 = 0;
    for (a, b) |x, y| {
        const difference = @as(i32, x) - y;
        result += @intCast(difference * difference);
    }
    return result;
}

fn halfTexelIndex(horizontal: bool, half: usize, index: usize) usize {
    if (horizontal) return half * 8 + index;
    return (index / 2) * 4 + half * 2 + index % 2;
}

fn hasConstantRgb(texels: *const [16][4]u8) bool {
    for (texels[1..]) |texel| {
        if (!std.mem.eql(u8, texel[0..3], texels[0][0..3])) return false;
    }
    return true;
}

// Constant RGB can search one shared base/selector for both halves, including clamped endpoints.
fn fitConstantRgb(rgb: [3]u8, output: *[8]u8) void {
    var least: u32 = std.math.maxInt(u32);
    for ([_]bool{ false, true }) |differential| {
        const limit: u32 = if (differential) 31 else 15;
        for (intensity_modifiers, 0..) |modifiers, table| {
            for (modifiers, 0..) |modifier, selector| {
                var codes: [3]u8 = undefined;
                var reconstructed: [3]u8 = undefined;
                for (rgb, &codes, &reconstructed) |value, *code, *sample| {
                    const desired: u32 = @intCast(std.math.clamp(
                        @as(i32, value) - modifier,
                        0,
                        255,
                    ));
                    const center: i32 = @intCast((desired * limit + 127) / 255);
                    var distance: i32 = 256;
                    for ([_]i32{ 0, -1, 1 }) |delta| {
                        const adjacent: u8 = @intCast(std.math.clamp(center + delta, 0, limit));
                        const base: i32 = if (differential) expand5(adjacent) else adjacent * 17;
                        const decoded: u8 = @intCast(std.math.clamp(base + modifier, 0, 255));
                        const error_magnitude: i32 = @intCast(@abs(@as(i32, decoded) - value));
                        if (error_magnitude < distance) {
                            distance = error_magnitude;
                            code.* = adjacent;
                            sample.* = decoded;
                        }
                    }
                }
                const error_squared = squaredError(rgb, reconstructed);
                if (error_squared >= least) continue;
                least = error_squared;
                Encoding.pack(
                    .{
                        .colors = .{ codes, codes },
                        .tables = @splat(@intCast(table)),
                        .differential = differential,
                        .horizontal = false,
                    },
                    &@splat(@intCast(selector)),
                    output,
                );
            }
        }
    }
}

test "ETC1 palette ties retain the first wire selector in each parallel texel" {
    var pixels: [8][3]u8 = undefined;
    for (&pixels, [_]u8{ 136, 141, 131, 128, 144, 134, 138, 137 }) |*pixel, value| {
        pixel.* = @splat(value);
    }
    // Four-bit base 8 expands to 136. Table zero produces gray 138/144/134/128.
    const samples = HalfBlockSamples.init(&pixels);
    const fitted = scoreHalf(&samples, @splat(8), 0, false);
    try std.testing.expectEqualSlices(u2, &.{ 0, 0, 2, 3, 1, 2, 0, 0 }, &fitted.selectors);
    try std.testing.expectEqual(69, fitted.error_squared);

    for (&pixels, 0..) |*pixel, value| pixel.* = @splat(@intCast(value));
    // Black clamps the last two entries to zero; exact and midpoint ties keep wire order.
    const dark = HalfBlockSamples.init(&pixels);
    const clamped = scoreHalf(&dark, @splat(0), 0, false);
    try std.testing.expectEqualSlices(u2, &.{ 2, 0, 0, 0, 0, 0, 1, 1 }, &clamped.selectors);
    try std.testing.expectEqual(60, clamped.error_squared);
}

// Wire selector order from OES_compressed_ETC1_RGB8_texture, tables 3.17.2/3.17.3.
// https://registry.khronos.org/OpenGL/extensions/OES/OES_compressed_ETC1_RGB8_texture.txt
const intensity_modifiers = [8][4]i16{
    .{ 2, 8, -2, -8 },
    .{ 5, 17, -5, -17 },
    .{ 9, 29, -9, -29 },
    .{ 13, 42, -13, -42 },
    .{ 18, 60, -18, -60 },
    .{ 24, 80, -24, -80 },
    .{ 33, 106, -33, -106 },
    .{ 47, 183, -47, -183 },
};
