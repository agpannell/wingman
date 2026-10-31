//! Unsigned EAC scalar blocks: alpha8 and R11 reconstruction, selector packing and bounded fitting.
//! Both formats store the same fields, but R11 expands the base and treats multiplier zero as 1/8.
//! Alpha8 decoders accept zero multipliers; alpha8 encoders must emit nonzero multipliers.

const std = @import("std");
const memory = @import("../common/byte_ranges.zig");
const format = @import("format.zig");

const DecodeError = format.DecodeError;
const Encoding = format.ScalarEncoding;

/// Reads the first eight bytes of an EAC alpha block and writes sixteen row-major alpha bytes. This
/// is the alpha half of ETC2 RGBA, not the R11 representation. Extra capacity is untouched; used
/// source/output spans must be disjoint. Every failure preserves all output. Allocates nothing.
pub fn decodeAlphaBlock(encoded: []const u8, destination: []u8) DecodeError!void {
    return decode(8, encoded, destination);
}

test decodeAlphaBlock {
    const encoded = [_]u8{ 103, 0x2d, 0x6d, 0xb6, 0xdb, 0x6d, 0xb6, 0xdb };
    var alpha: [16]u8 = undefined;
    try decodeAlphaBlock(&encoded, &alpha);
    try std.testing.expect(std.mem.allEqual(u8, &alpha, 83));
}

/// Reads one eight-byte unsigned EAC R11 block and writes sixteen row-major samples in 0..2047.
/// These are exact eleven-bit values in `u16` storage: divide by 2047 for normalized values, or
/// extend to UNORM16 with `(value << 5) | (value >> 6)`. An RG11 block contains red then green R11
/// blocks. Extra input/output is untouched; used spans must be disjoint. Every error preserves all
/// output, and no allocation occurs. Signed EAC is not interpreted by this operation.
pub fn decodeR11Block(encoded: []const u8, destination: []u16) DecodeError!void {
    return decode(11, encoded, destination);
}

test decodeR11Block {
    const encoded = [_]u8{ 103, 0x2d, 0x6d, 0xb6, 0xdb, 0x6d, 0xb6, 0xdb };
    var red: [16]u16 = undefined;
    try decodeR11Block(&encoded, &red);
    try std.testing.expect(std.mem.allEqual(u16, &red, 668));
}

fn decode(
    comptime bits: u4,
    encoded: []const u8,
    destination: [](if (bits == 8) u8 else u16),
) DecodeError!void {
    if (encoded.len < 8) return error.TruncatedBlock;
    if (destination.len < 16) return error.DestinationTooSmall;
    const source = encoded[0..8];
    const output = destination[0..16];
    if (memory.overlaps(source, std.mem.sliceAsBytes(output))) return error.OverlappingStorage;
    const encoding: Encoding = .{
        .base = source[0],
        .table = @truncate(source[1]),
        .multiplier = @truncate(source[1] >> 4),
    };
    const palette = format.scalarPalette(encoding, bits);
    const word = std.mem.readInt(u64, source, .big);
    for (output, 0..) |*value, pixel| {
        const offset: u6 = @intCast(45 - ((pixel % 4) * 4 + pixel / 4) * 3);
        const selector: u3 = @truncate(word >> offset);
        value.* = @intCast(palette[selector]);
    }
}

pub fn pack(encoding: Encoding, selectors: *const [16]u3, output: *[8]u8) void {
    const base_bits = @as(u16, encoding.base) << 8;
    const multiplier_bits = @as(u16, encoding.multiplier) << 4;
    const header = base_bits | multiplier_bits | encoding.table;
    var word = @as(u64, header) << 48;
    for (selectors, 0..) |selector, pixel| {
        const offset: u6 = @intCast(45 - ((pixel % 4) * 4 + pixel / 4) * 3);
        word |= @as(u64, selector) << offset;
    }
    std.mem.writeInt(u64, output, word, .big);
}

// Alpha8 encoders require nonzero multipliers, including when the caller's hint contains zero.
// OpenGL ES 3.0.6 C.1.3 distinguishes this encoder restriction from the decoder's zero rule.
pub fn encodeAlphaHinted(samples: *const [16]u8, hint: u8, output: *[8]u8) void {
    const minimum = std.mem.min(u8, samples);
    const maximum = std.mem.max(u8, samples);
    if (minimum == maximum) {
        packAlphaConstant(minimum, output);
        return;
    }
    const table: u4 = @truncate(hint);
    const modifiers = format.scalar_modifiers[table];
    const span: u32 = @intCast(modifiers[7] - modifiers[3]);
    const negative: u32 = @intCast(-modifiers[3]);
    const weighted_minimum = @as(u32, minimum) * span;
    const offset = @as(u32, maximum - minimum) * negative;
    const center = (weighted_minimum + offset + span / 2) / span;
    const encoding: Encoding = .{
        .base = @intCast(center),
        .table = table,
        .multiplier = @max(1, @as(u4, @truncate(hint >> 4))),
    };
    var values: [16]u16 = undefined;
    for (samples, &values) |sample, *value| value.* = sample;
    const candidate = select(encoding, &values, 8);
    pack(candidate.encoding, &candidate.selectors, output);
}

pub fn encodeR11(samples: *const [16]u8, output: *[8]u8) void {
    encode(samples, 11, .fast, output);
}

/// Conservative scalar admission: 256 setup units plus 128 per candidate, with at most 8/32/160
/// candidates for fast/balanced/refined. Alpha8 and R11 share these bounds, not their palettes.
pub fn scalarWorkUnits(effort: format.Effort) u64 {
    const candidates: u64 = switch (effort) {
        .fast => 8,
        .balanced => 32,
        .refined => 160,
    };
    return 256 + 128 * candidates;
}

pub fn encode(
    samples: *const [16]u8,
    comptime bits: u4,
    effort: format.Effort,
    output: *[8]u8,
) void {
    const minimum = std.mem.min(u8, samples);
    const maximum = std.mem.max(u8, samples);
    if (minimum == maximum) {
        if (bits == 11) {
            const entry = constant_encodings[minimum];
            pack(entry.encoding, &@splat(entry.selector), output);
        } else {
            packAlphaConstant(minimum, output);
        }
        return;
    }
    var values: [16]u16 = undefined;
    for (samples, &values) |sample, *value| {
        value.* = if (bits == 11) normalized11(sample) else sample;
    }
    const low: u32 = if (bits == 11) normalized11(minimum) else minimum;
    const high: u32 = if (bits == 11) normalized11(maximum) else maximum;
    const range = high - low;
    var best: Candidate = .{ .error_squared = std.math.maxInt(u32) };
    // The original four-table R11 search stays first, preserving its fast words and tie order.
    const tables = [_]u4{ 2, 8, 11, 13, 0, 1, 3, 4, 5, 6, 7, 9, 10, 12, 14, 15 };
    const table_count: usize = if (effort == .fast) 4 else tables.len;
    var centers: [16]Encoding = undefined;
    for (tables[0..table_count]) |table| {
        const encoding = centerEncoding(low, range, table, bits);
        centers[table] = encoding;
        const candidate = select(encoding, &values, bits);
        if (candidate.error_squared < best.error_squared) best = candidate;
        if (bits == 11 and range <= 64) {
            var narrow = encoding;
            narrow.multiplier = 0;
            const candidate_zero = select(narrow, &values, bits);
            if (candidate_zero.error_squared < best.error_squared) best = candidate_zero;
        }
    }
    if (effort == .refined) {
        for (tables) |table| {
            const center = centers[table];
            for ([_]i16{ -1, 0, 1 }) |base_delta| {
                const base = @as(i16, center.base) + base_delta;
                for ([_]i16{ -1, 0, 1 }) |multiplier_delta| {
                    if (base_delta == 0 and multiplier_delta == 0) continue;
                    const multiplier = std.math.clamp(
                        @as(i16, center.multiplier) + multiplier_delta,
                        0,
                        15,
                    );
                    if (bits == 8 and multiplier == 0) continue;
                    const adjacent: Encoding = .{
                        .base = @intCast(std.math.clamp(base, 0, 255)),
                        .table = table,
                        .multiplier = @intCast(multiplier),
                    };
                    const candidate = select(adjacent, &values, bits);
                    if (candidate.error_squared < best.error_squared) best = candidate;
                }
            }
        }
    }
    pack(best.encoding, &best.selectors, output);
}

fn packAlphaConstant(value: u8, output: *[8]u8) void {
    // Table 13's selector 4 has modifier zero, preserving any constant with a nonzero multiplier.
    pack(.{ .base = value, .table = 13, .multiplier = 1 }, &@splat(4), output);
}

fn centerEncoding(low: u32, range: u32, table: u4, comptime bits: u4) Encoding {
    const modifiers = format.scalar_modifiers[table];
    const span: u32 = @intCast(modifiers[7] - modifiers[3]);
    const negative: u32 = @intCast(-modifiers[3]);
    const center = low * span + range * negative;
    // Keep R11's established floor/nearest rules; alpha8 uses an unexpanded base and modifier.
    const scale: u32 = if (bits == 11) 8 else 1;
    const rounding: u32 = if (bits == 11) 0 else span / 2;
    return .{
        .base = @intCast(@min(255, (center + rounding) / (span * scale))),
        .table = table,
        .multiplier = @intCast(std.math.clamp((range + span * scale / 2) / (span * scale), 1, 15)),
    };
}

fn normalized11(value: u8) u16 {
    return @intCast((@as(u32, value) * 2047 + 127) / 255);
}

const Candidate = struct {
    encoding: Encoding = undefined,
    selectors: [16]u3 = undefined,
    error_squared: u32,
};

fn select(encoding: Encoding, values: *const [16]u16, comptime bits: u4) Candidate {
    const palette = format.scalarPalette(encoding, bits);
    const samples: @Vector(16, i32) = @intCast(@as(@Vector(16, u16), values.*));
    var least: @Vector(16, u32) = @splat(std.math.maxInt(u32));
    var selectors: @Vector(16, u32) = @splat(0);
    inline for (palette, 0..) |entry, index| {
        const difference = @as(@Vector(16, i32), @splat(entry)) - samples;
        const squared: @Vector(16, u32) = @intCast(difference * difference);
        // Palette order determines ties, even when clamping makes several entries identical.
        const improved = squared < least;
        selectors = @select(u32, improved, @as(@Vector(16, u32), @splat(index)), selectors);
        least = @min(least, squared);
    }
    const indices: @Vector(16, u3) = @intCast(selectors);
    return .{ .encoding = encoding, .selectors = indices, .error_squared = @reduce(.Add, least) };
}

const ConstantEncoding = struct { encoding: Encoding, selector: u3 };

// Derive exact constant mappings from EAC's zero-multiplier rule. No encoder lookup data is
// imported. For each table/selector, the nearest legal base is sufficient; ties keep the first.
const constant_encodings = blk: {
    @setEvalBranchQuota(4_000_000);
    var result: [256]ConstantEncoding = undefined;
    for (&result, 0..) |*entry, value| {
        const target: i32 = normalized11(@intCast(value));
        var best: u32 = std.math.maxInt(u32);
        for (format.scalar_modifiers, 0..) |modifiers, table| {
            for (modifiers, 0..) |modifier, selector| {
                const base = std.math.clamp(@divFloor(target - modifier, 8), 0, 255);
                const reconstructed = std.math.clamp(base * 8 + 4 + modifier, 0, 2047);
                const difference = target - reconstructed;
                const squared: u32 = @intCast(difference * difference);
                if (squared < best) {
                    best = squared;
                    entry.* = .{
                        .encoding = .{
                            .base = @intCast(base),
                            .table = @intCast(table),
                            .multiplier = 0,
                        },
                        .selector = @intCast(selector),
                    };
                }
            }
        }
        std.debug.assert(best == 0);
    }
    break :blk result;
};

test "EAC scalar examples retain precision, selector columns and zero multipliers" {
    const encoded = [_]u8{ 103, 0x2d, 0x05, 0x39, 0x77, 0x05, 0x39, 0x77 };
    const expected_alpha = [_]u8{
        101, 103, 101, 103, 99, 105, 99, 105, 97, 107, 97, 107, 83, 121, 83, 121,
    };
    const expected_red = [_]u16{
        812, 828, 812, 828, 796, 844, 796, 844, 780, 860, 780, 860, 668, 972, 668, 972,
    };
    var alpha: [16]u8 = undefined;
    var red: [16]u16 = undefined;
    try decodeAlphaBlock(&encoded, &alpha);
    try decodeR11Block(&encoded, &red);
    try std.testing.expectEqualSlices(u8, &expected_alpha, &alpha);
    try std.testing.expectEqualSlices(u16, &expected_red, &red);

    const zero = [_]u8{ 103, 0x0d, 0x6d, 0xb6, 0xdb, 0x6d, 0xb6, 0xdb };
    try decodeAlphaBlock(&zero, &alpha);
    try decodeR11Block(&zero, &red);
    try std.testing.expect(std.mem.allEqual(u8, &alpha, 103));
    try std.testing.expect(std.mem.allEqual(u16, &red, 818));
}

test "EAC scalar admission preserves output and spare samples" {
    var output: [40]u16 = @splat(0xa5a5);
    const before = output;
    const encoded = [_]u8{ 103, 0x2d, 0x6d, 0xb6, 0xdb, 0x6d, 0xb6, 0xdb };
    try std.testing.expectError(error.TruncatedBlock, decodeR11Block(encoded[0..7], &output));
    try std.testing.expectError(error.DestinationTooSmall, decodeR11Block(&encoded, output[0..15]));
    const bytes = std.mem.sliceAsBytes(&output);
    try std.testing.expectError(error.OverlappingStorage, decodeR11Block(bytes[0..8], &output));
    try std.testing.expectError(error.TruncatedBlock, decodeAlphaBlock(encoded[0..7], bytes));
    try std.testing.expectError(
        error.DestinationTooSmall,
        decodeAlphaBlock(&encoded, bytes[0..15]),
    );
    try std.testing.expectError(error.OverlappingStorage, decodeAlphaBlock(bytes[0..8], bytes));
    try std.testing.expectEqualSlices(u16, &before, &output);
    try decodeR11Block(&encoded, &output);
    try std.testing.expectEqualSlices(u16, before[16..], output[16..]);
    output = before;
    try decodeAlphaBlock(&encoded, bytes);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&before)[16..], bytes[16..]);
}

test "EAC constant byte mappings preserve alpha and normalized R11 at all values" {
    for (0..256) |value| {
        const samples: [16]u8 = @splat(@intCast(value));
        var encoded: [8]u8 = undefined;
        var alpha: [16]u8 = undefined;
        var red: [16]u16 = undefined;
        encodeAlphaHinted(&samples, 0, &encoded);
        try decodeAlphaBlock(&encoded, &alpha);
        try std.testing.expect(std.mem.allEqual(u8, &alpha, @intCast(value)));
        try std.testing.expect(encoded[1] >> 4 != 0);
        encodeR11(&samples, &encoded);
        try decodeR11Block(&encoded, &red);
        try std.testing.expect(std.mem.allEqual(u16, &red, normalized11(@intCast(value))));
    }
}

test "EAC alpha repairs a zero multiplier for varying input" {
    const samples = [_]u8{
        0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255,
    };
    var encoded: [8]u8 = undefined;
    encodeAlphaHinted(&samples, 13, &encoded);
    try std.testing.expectEqual(1, encoded[1] >> 4);
    var alpha: [16]u8 = undefined;
    try decodeAlphaBlock(&encoded, &alpha);
    try std.testing.expect(!std.mem.allEqual(u8, &alpha, alpha[0]));
}

test "EAC palette ties retain the first wire selector after clamping" {
    const half = [_]u16{ 0, 2, 4, 64, 124, 184, 244, 664 };
    const values = half ++ half;
    // Base zero, table 13 and multiplier 15 reconstruct 0/0/0/0/4/124/244/1084. Midpoints and
    // repeated entries select the first matching wire index.
    const fitted = select(.{ .base = 0, .table = 13, .multiplier = 15 }, &values, 11);
    const selectors = [_]u3{ 0, 0, 4, 4, 5, 5, 6, 6 };
    const expected = selectors ++ selectors;
    try std.testing.expectEqualSlices(u3, &expected, &fitted.selectors);
    try std.testing.expectEqual(367208, fitted.error_squared);
}
