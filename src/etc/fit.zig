//! Bounded ETC1 RGB fitting. Search legal splits, endpoint precisions and intensity tables; compare
//! the actual clamped palette in stored-byte RGB space. Alpha does not affect the fit.

const std = @import("std");
const format = @import("format.zig");
const color = @import("color.zig");

/// Conservative per-block admission: 1024 setup units plus 128 per half-block candidate, with at
/// most 64/192/704 candidates for fast/balanced/refined. Units are policy, not elapsed time.
pub fn colorWorkUnits(effort: format.Effort) u64 {
    const candidates: u64 = switch (effort) {
        .fast => 64,
        .balanced => 192,
        .refined => 704,
    };
    return 1024 + 128 * candidates;
}

pub fn encode(texels: *const [16][4]u8, effort: format.Effort, output: *[8]u8) void {
    if (solid(texels)) {
        encodeSolid(texels[0][0..3].*, output);
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
                    const index = pixelIndex(horizontal, part, i);
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
                for ([_]Half{ first, second }, 0..) |half, part| {
                    for (half.selectors, 0..) |selector, i| {
                        selectors[pixelIndex(horizontal, part, i)] = selector;
                    }
                }
                const encoding: format.ColorEncoding = .{ .colors = .{
                    first.base, second.base,
                }, .tables = .{
                    first.table, second.table,
                }, .differential = differential, .horizontal = horizontal };
                color.pack(encoding, &selectors, output);
            }
        }
    }
}

const Half = struct { base: [3]u8, table: u3, selectors: [8]u2, error_squared: u32 };

// Each lane keeps one texel's position within the half-block. Loading channels once lets every
// palette candidate score those eight texels together without transposing them again.
const HalfPixels = struct {
    channels: [3]@Vector(8, i32),
    sums: [3]i32,

    fn init(pixels: *const [8][3]u8) HalfPixels {
        var result: HalfPixels = .{ .channels = undefined, .sums = @splat(0) };
        inline for (pixels, 0..) |pixel, index| {
            for (&result.channels, &result.sums, pixel) |*channel, *sum, value| {
                channel.*[index] = value;
                sum.* += value;
            }
        }
        return result;
    }
};

fn fitHalf(
    pixels: *const [8][3]u8,
    differential: bool,
    low: [3]u8,
    high: [3]u8,
    stage: usize,
) Half {
    const samples = HalfPixels.init(pixels);
    const limit: u8 = if (differential) 31 else 15;
    var mean: [3]u8 = undefined;
    for (&mean, samples.sums, low, high) |*value, sum, minimum, maximum| {
        value.* = std.math.clamp(quantizeSum(sum, limit), minimum, maximum);
    }

    var best: Half = undefined;
    best.error_squared = std.math.maxInt(u32);
    for (0..8) |table_index| {
        const table: u3 = @intCast(table_index);
        var candidate = score(&samples, mean, table, differential);
        if (stage >= 1) {
            var adjusted = samples.sums;
            for (candidate.selectors) |selector| {
                const modifier = format.color_modifiers[table][selector];
                for (&adjusted) |*sum| sum.* -= modifier;
            }
            var refitted: [3]u8 = undefined;
            for (&refitted, adjusted, low, high) |*value, sum, minimum, maximum| {
                value.* = std.math.clamp(quantizeSum(sum, limit), minimum, maximum);
            }
            const next = score(&samples, refitted, table, differential);
            if (next.error_squared < candidate.error_squared) candidate = next;
        }
        if (stage >= 2) {
            const center = candidate.base;
            for (0..3) |channel| {
                for ([_]i16{ -1, 1 }) |delta| {
                    var adjacent = center;
                    const code = @as(i16, center[channel]) + delta;
                    adjacent[channel] = @intCast(std.math.clamp(code, low[channel], high[channel]));
                    const next = score(&samples, adjacent, table, differential);
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

fn score(pixels: *const HalfPixels, base: [3]u8, table: u3, differential: bool) Half {
    var expanded: [3]u8 = undefined;
    for (&expanded, base) |*value, code| {
        value.* = if (differential) format.expand5(code) else code * 17;
    }
    const palette = format.colorPalette(expanded, table);
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

fn pixelIndex(horizontal: bool, half: usize, index: usize) usize {
    if (horizontal) return half * 8 + index;
    return (index / 2) * 4 + half * 2 + index % 2;
}

fn solid(texels: *const [16][4]u8) bool {
    for (texels[1..]) |texel| {
        if (!std.mem.eql(u8, texel[0..3], texels[0][0..3])) return false;
    }
    return true;
}

fn encodeSolid(rgb: [3]u8, output: *[8]u8) void {
    var least: u32 = std.math.maxInt(u32);
    for ([_]bool{ false, true }) |differential| {
        const limit: u32 = if (differential) 31 else 15;
        for (format.color_modifiers, 0..) |modifiers, table| {
            for (modifiers, 0..) |modifier, selector| {
                var codes: [3]u8 = undefined;
                var reconstructed: [3]u8 = undefined;
                for (rgb, &codes, &reconstructed) |value, *code, *sample| {
                    const desired: u32 = @intCast(
                        std.math.clamp(@as(i32, value) - modifier, 0, 255),
                    );
                    const center: i32 = @intCast((desired * limit + 127) / 255);
                    var distance: i32 = 256;
                    for ([_]i32{ 0, -1, 1 }) |delta| {
                        const adjacent: u8 = @intCast(std.math.clamp(center + delta, 0, limit));
                        const base: i32 = if (differential) format.expand5(
                            adjacent,
                        ) else adjacent * 17;
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
                color.pack(.{ .colors = .{ codes, codes }, .tables = @splat(
                    @intCast(table),
                ), .differential = differential, .horizontal = false }, &@splat(
                    @intCast(selector),
                ), output);
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
    const samples = HalfPixels.init(&pixels);
    const fitted = score(&samples, @splat(8), 0, false);
    try std.testing.expectEqualSlices(u2, &.{ 0, 0, 2, 3, 1, 2, 0, 0 }, &fitted.selectors);
    try std.testing.expectEqual(69, fitted.error_squared);

    for (&pixels, 0..) |*pixel, value| pixel.* = @splat(@intCast(value));
    // Black clamps the last two entries to zero; exact and midpoint ties keep wire order.
    const dark = HalfPixels.init(&pixels);
    const clamped = score(&dark, @splat(0), 0, false);
    try std.testing.expectEqualSlices(u2, &.{ 2, 0, 0, 0, 0, 0, 1, 1 }, &clamped.selectors);
    try std.testing.expectEqual(60, clamped.error_squared);
}
