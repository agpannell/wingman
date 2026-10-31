//! ETC1 and unsigned EAC block fields and reconstruction palettes. UASTC hint interpretation
//! belongs to UASTC; these representations describe the actual GPU blocks.

const std = @import("std");

/// Incomplete source/output or overlapping used spans. ETC1 additionally refuses differential
/// endpoints outside 0..31, for which that format leaves reconstruction undefined.
pub const DecodeError = error{
    TruncatedBlock,
    DestinationTooSmall,
    OverlappingStorage,
    InvalidBlock,
};

/// Bounded fitting search. Wider efforts retain earlier complete-block candidates, so squared
/// component error cannot increase. This does not promise perceptual quality or a particular cost.
pub const Effort = enum { fast, balanced, refined };

pub const ColorEncoding = struct {
    colors: [2][3]u8,
    tables: [2]u3,
    differential: bool,
    horizontal: bool,
};

pub const ScalarEncoding = struct { base: u8, table: u4, multiplier: u4 };

pub fn expand5(value: u8) u8 {
    return (value << 3) | (value >> 2);
}

pub fn colorPalette(base: [3]u8, table: u3) [4][3]u8 {
    var result: [4][3]u8 = undefined;
    for (&result, color_modifiers[table]) |*entry, modifier| {
        for (entry, base) |*component, value| {
            component.* = @intCast(std.math.clamp(@as(i16, value) + modifier, 0, 255));
        }
    }
    return result;
}

pub fn scalarPalette(encoding: ScalarEncoding, comptime bits: u4) [8]u16 {
    std.debug.assert(bits == 8 or bits == 11);
    const base: i32 = if (bits == 8) encoding.base else @as(i32, encoding.base) * 8 + 4;
    const multiplier: i32 = blk: {
        if (bits == 8) break :blk encoding.multiplier;
        if (encoding.multiplier == 0) break :blk 1;
        break :blk @as(i32, encoding.multiplier) * 8;
    };
    var result: [8]u16 = undefined;
    for (&result, scalar_modifiers[encoding.table]) |*entry, modifier| {
        entry.* = @intCast(std.math.clamp(base + modifier * multiplier, 0, (1 << bits) - 1));
    }
    return result;
}

// ETC1 selector order from OES_compressed_ETC1_RGB8_texture, tables 3.17.2/3.17.3.
// https://registry.khronos.org/OpenGL/extensions/OES/OES_compressed_ETC1_RGB8_texture.txt
pub const color_modifiers = [8][4]i16{ .{
    2, 8, -2, -8,
}, .{
    5, 17, -5, -17,
}, .{
    9, 29, -9, -29,
}, .{
    13, 42, -13, -42,
}, .{
    18, 60, -18, -60,
}, .{
    24, 80, -24, -80,
}, .{
    33, 106, -33, -106,
}, .{
    47, 183, -47, -183,
} };

// EAC modifier values from OpenGL ES 3.0.6 appendix C, table C.10. Alpha8 and unsigned R11 share
// these facts, but use different base expansion and zero-multiplier rules.
// https://registry.khronos.org/OpenGL/specs/es/3.0/es_spec_3.0.pdf
pub const scalar_modifiers = [16][8]i16{ .{
    -3, -6, -9, -15, 2, 5, 8, 14,
}, .{
    -3, -7, -10, -13, 2, 6, 9, 12,
}, .{
    -2, -5, -8, -13, 1, 4, 7, 12,
}, .{
    -2, -4, -6, -13, 1, 3, 5, 12,
}, .{
    -3, -6, -8, -12, 2, 5, 7, 11,
}, .{
    -3, -7, -9, -11, 2, 6, 8, 10,
}, .{
    -4, -7, -8, -11, 3, 6, 7, 10,
}, .{
    -3, -5, -8, -11, 2, 4, 7, 10,
}, .{
    -2, -6, -8, -10, 1, 5, 7, 9,
}, .{
    -2, -5, -8, -10, 1, 4, 7, 9,
}, .{
    -2, -4, -8, -10, 1, 3, 7, 9,
}, .{
    -2, -5, -7, -10, 1, 4, 6, 9,
}, .{
    -3, -4, -7, -10, 2, 3, 6, 9,
}, .{
    -1, -2, -3, -10, 0, 1, 2, 9,
}, .{
    -4, -6, -8, -9, 3, 5, 7, 8,
}, .{
    -3, -5, -7, -9, 2, 4, 6, 8,
} };
