//! Convert G.711 voice samples using A-law or mu-law. Each byte represents one amplitude with finer
//! spacing near silence and coarser spacing for loud signals. Expand to exact signed PCM16 with
//! decodeAlaw/decodeMulaw, or normalized caller-owned f32 storage with decodeInto. Encode PCM16
//! amplitudes or directly convert between laws into caller-owned storage.
//!
//! Every byte is valid in either law. A-law has no exact zero; mu-law has two zero codes. These
//! operations allocate nothing and retain no input. Rate, channels, containers and packets belong
//! to the caller. Packet policy and the later G.711 extensions remain outside this library.
//!
//! Algorithm reference: https://www.itu.int/rec/T-REC-G.711/en

const std = @import("std");
const overlaps = @import("common/byte_ranges.zig").overlaps;
const testing = std.testing;

/// Select the byte representation declared by the input format or protocol; neither is detected.
pub const Law = enum { alaw, mulaw };

/// DestinationTooSmall is checked before Aliasing. Both refusals leave all output unchanged.
pub const Error = error{ DestinationTooSmall, Aliasing };

/// Expand source.len bytes into exactly that many f32 samples and return
/// destination[0..source.len]. Each result is the signed PCM16 value divided by 32768, exactly
/// representable in f32. Source order is preserved; this operation does not infer channels or
/// change the sampling rate.
///
/// Check destination capacity before aliasing. Source must be disjoint from the used output's byte
/// span; it may touch that span or overlap unused destination capacity. Both errors preserve the
/// whole destination, and successful conversion preserves spare output. Empty input succeeds. No
/// source or destination borrow is retained; the result borrows caller-owned destination.
pub fn decodeInto(source: []const u8, destination: []f32, law: Law) Error![]f32 {
    if (destination.len < source.len) return error.DestinationTooSmall;
    const output = destination[0..source.len];
    if (overlaps(source, std.mem.sliceAsBytes(output))) return error.Aliasing;
    const table = switch (law) {
        .alaw => &alaw_table,
        .mulaw => &mulaw_table,
    };
    for (source, output) |byte, *sample| sample.* = table[byte];
    return output;
}

test decodeInto {
    var output: [3]f32 = undefined;
    _ = try decodeInto(&.{ 0, 128, 255 }, &output, .mulaw);
    try testing.expectEqualSlices(f32, &.{ -32124.0 / 32768.0, 32124.0 / 32768.0, 0 }, &output);
}

/// Expand one mu-law byte to its exact signed PCM16 value, in [-32124, 32124]. All 256 codes are
/// valid. Both 0x7f and 0xff decode to zero; raw 0x00 decodes normally, without zero suppression.
pub fn decodeMulaw(encoded: u8) i16 {
    const value = ~encoded;
    const mantissa = @as(i32, value & 0x0f) << 3;
    const segment: u3 = @intCast((value >> 4) & 0x07);
    const magnitude = (mantissa + 0x84) << segment;
    const sample = if (value & 0x80 != 0) 0x84 - magnitude else magnitude - 0x84;
    return @intCast(sample);
}

test decodeMulaw {
    try testing.expectEqual(0, decodeMulaw(0x7f));
    try testing.expectEqual(0, decodeMulaw(0xff));
    try testing.expectEqual(-32124, decodeMulaw(0));
}

/// Expand one A-law byte to its exact signed PCM16 value, in [-32256, 32256]. All 256 codes are
/// valid. The closest values to silence are -8 (0x55) and +8 (0xd5); there is no exact zero.
pub fn decodeAlaw(encoded: u8) i16 {
    const value = encoded ^ 0x55;
    var magnitude: i32 = @as(i32, value & 0x0f) << 4;
    const segment = (value >> 4) & 0x07;
    if (segment == 0) {
        magnitude += 8;
    } else {
        magnitude += 0x108;
        magnitude <<= @intCast(segment - 1);
    }
    const sample = if (value & 0x80 != 0) magnitude else -magnitude;
    return @intCast(sample);
}

test decodeAlaw {
    try testing.expectEqual(-8, decodeAlaw(0x55));
    try testing.expectEqual(8, decodeAlaw(0xd5));
}

/// Compresses one signed PCM16 sample to A-law using the G.191 decision-boundary convention. G.711
/// permits equipment to choose how exact decision values are assigned.
pub fn encodeAlaw(sample: i16) u8 {
    // One's complement gives the negative half the same quantizer intervals as G.191.
    const magnitude: u16 = @intCast(if (sample < 0) ~sample else sample);
    const value = magnitude >> 4;
    // Above the first segment the highest set bit gives the segment and mantissa shift.
    const segment: u4 = if (value < 16) 0 else @intCast(12 - @clz(value));
    const quantized: u16 = if (segment == 0) value else (value >> (segment - 1)) & 15;
    const sign: u8 = if (sample >= 0) 0x80 else 0;
    const fields: u8 = @intCast((@as(u16, segment) << 4) | quantized);
    return (fields | sign) ^ 0x55;
}

test encodeAlaw {
    try testing.expectEqual(@as(u8, 0x55), encodeAlaw(-1));
    try testing.expectEqual(@as(u8, 0xd5), encodeAlaw(0));
    try testing.expectEqual(@as(u8, 0x2a), encodeAlaw(-32768));
    try testing.expectEqual(@as(u8, 0xaa), encodeAlaw(32767));
}

/// Compresses one signed PCM16 sample to mu-law using the G.191 decision-boundary convention. G.711
/// permits equipment to choose how exact decision values are assigned. The ordinary all-zero code
/// is preserved; network zero-code suppression is caller policy.
pub fn encodeMulaw(sample: i16) u8 {
    const magnitude: u16 = @intCast(if (sample < 0) ~sample else sample);
    // The mu-law bias shifts segment boundaries; clamping keeps the largest input in segment 8.
    const biased: u16 = @min((magnitude >> 2) + 33, 0x1fff);
    // The leading bit of the biased value identifies the segment without a search loop.
    const segment: u4 = @intCast(@max(1, 11 - @as(i16, @intCast(@clz(biased)))));
    const exponent: u8 = @intCast(8 - segment);
    const mantissa: u8 = @intCast(15 - ((biased >> segment) & 15));
    const sign: u8 = if (sample >= 0) 0x80 else 0;
    return sign | (exponent << 4) | mantissa;
}

test encodeMulaw {
    try testing.expectEqual(@as(u8, 0x7f), encodeMulaw(-1));
    try testing.expectEqual(@as(u8, 0xff), encodeMulaw(0));
    try testing.expectEqual(@as(u8, 0), encodeMulaw(-32768));
    try testing.expectEqual(@as(u8, 0x80), encodeMulaw(32767));
}

/// Encodes signed PCM16 samples into a used destination prefix using the G.191 decision-boundary
/// convention. Mu-law uses ordinary codes without network zero-code suppression. Capacity is
/// checked before overlap; either refusal leaves the destination unchanged. The slices are borrowed
/// for the call.
pub fn encodeInto(source: []const i16, destination: []u8, law: Law) Error![]u8 {
    if (destination.len < source.len) return error.DestinationTooSmall;
    const output = destination[0..source.len];
    if (overlaps(std.mem.sliceAsBytes(source), output)) return error.Aliasing;

    switch (law) {
        .alaw => {
            for (source, output) |sample, *byte| {
                const bits: u16 = @bitCast(sample);
                byte.* = alaw_encoding[bits >> 4];
            }
        },
        .mulaw => {
            for (source, output) |sample, *byte| {
                const bits: u16 = @bitCast(sample);
                byte.* = mulaw_encoding[bits >> 2];
            }
        },
    }
    return output;
}

test encodeInto {
    var bytes: [3]u8 = undefined;
    const encoded = try encodeInto(&.{ -1, 0, 32767 }, &bytes, .mulaw);
    try testing.expectEqualSlices(u8, &.{ 0x7f, 0xff, 0x80 }, encoded);
}

/// Expands bytes to exact signed PCM16 in a used destination prefix. Capacity is checked before
/// overlap; either refusal leaves the destination unchanged. The slices are borrowed for the call.
pub fn decodePcm16Into(source: []const u8, destination: []i16, law: Law) Error![]i16 {
    if (destination.len < source.len) return error.DestinationTooSmall;
    const output = destination[0..source.len];
    if (overlaps(source, std.mem.sliceAsBytes(output))) return error.Aliasing;

    const table = switch (law) {
        .alaw => &alaw_pcm16,
        .mulaw => &mulaw_pcm16,
    };

    for (source, output) |byte, *sample| sample.* = table[byte];
    return output;
}

test decodePcm16Into {
    var samples: [3]i16 = undefined;
    const decoded = try decodePcm16Into(&.{ 0, 128, 255 }, &samples, .mulaw);
    try testing.expectEqualSlices(i16, &.{ -32124, 32124, 0 }, decoded);
}

/// Direction of direct G.711 law conversion.
pub const TranscodeDirection = enum {
    /// Convert A-law bytes to mu-law bytes.
    alaw_to_mulaw,
    /// Convert mu-law bytes to A-law bytes.
    mulaw_to_alaw,
};

/// Converts one A-law code directly to mu-law according to G.711 Table 4. This is not generally
/// equivalent to decoding and re-encoding. The ordinary all-zero mu-law code is preserved.
pub fn alawToMulaw(encoded: u8) u8 {
    // Remove A-law alternating-bit inversion before applying the magnitude table.
    const raw = encoded ^ 0x55;
    const number = raw & 0x7f;
    const converted = if (number < a_to_mu.len) a_to_mu[number] else number;
    const sign: u8 = if (raw & 0x80 != 0) 0 else 0x80;
    return ~(converted | sign);
}

test alawToMulaw {
    // Table 4 deliberately selects mu-law value 79 for A-law value 80.
    try testing.expectEqual(@as(u8, 0xb0), alawToMulaw(0x9a));
}

/// Converts one mu-law code directly to A-law according to G.711 Table 3. This is not generally
/// equivalent to decoding and re-encoding.
pub fn mulawToAlaw(encoded: u8) u8 {
    const raw = ~encoded;
    const number = raw & 0x7f;
    const converted: u8 = if (number < mu_to_a.len) mu_to_a[number] else if (number < 80)
        number
    else
        number + 1;
    const sign: u8 = if (raw & 0x80 == 0) 0x80 else 0;
    const fields = (converted - 1) | sign;
    return fields ^ 0x55;
}

test mulawToAlaw {
    // Table 3 deliberately selects A-law value 81 for mu-law value 80.
    try testing.expectEqual(@as(u8, 0x85), mulawToAlaw(0xaf));
}

/// Converts law codes directly into a used destination prefix. Capacity is checked before overlap;
/// either refusal leaves destination unchanged. Source and output are borrowed for the call.
pub fn transcodeInto(
    source: []const u8,
    destination: []u8,
    direction: TranscodeDirection,
) Error![]u8 {
    if (destination.len < source.len) return error.DestinationTooSmall;
    const output = destination[0..source.len];
    if (overlaps(source, output)) return error.Aliasing;

    switch (direction) {
        .alaw_to_mulaw => {
            for (source, output) |byte, *result| result.* = alaw_to_mulaw[byte];
        },
        .mulaw_to_alaw => {
            for (source, output) |byte, *result| result.* = mulaw_to_alaw[byte];
        },
    }
    return output;
}

test transcodeInto {
    var result: [2]u8 = undefined;
    const converted = try transcodeInto(&.{ 0xaf, 0x2f }, &result, .mulaw_to_alaw);
    try testing.expectEqualSlices(u8, &.{ 0x85, 0x05 }, converted);
}

// The bulk maps are generated from the scalar conversions, so one set of table rules owns both.
const alaw_to_mulaw = transcodeTable(.alaw_to_mulaw);
const mulaw_to_alaw = transcodeTable(.mulaw_to_alaw);

fn transcodeTable(comptime direction: TranscodeDirection) [256]u8 {
    var table: [256]u8 = undefined;
    for (&table, 0..) |*result, index| {
        const byte: u8 = @intCast(index);
        result.* = switch (direction) {
            .alaw_to_mulaw => alawToMulaw(byte),
            .mulaw_to_alaw => mulawToAlaw(byte),
        };
    }
    return table;
}

// G.711 Tables 3 and 4 use one-based A-law and zero-based mu-law decoder value numbers. Above these
// explicit nonuniform ranges the conversion is linear, except the specified tandem pair.
const mu_to_a = [_]u8{
    1,  1,  2,  2,  3,  3,  4,  4,  5,  5,  6,  6,  7,  7,  8,  8,  9,  10, 11, 12, 13, 14, 15, 16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 27, 29, 31, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44,
    46, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62,
};
const a_to_mu = [_]u8{
    1,  3,  5,  7,  9,  11, 13, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    32, 32, 33, 33, 34, 34, 35, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 48, 49, 49,
    50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 64, 65, 66, 67, 68, 69, 70, 71, 72,
    73, 74, 75, 76, 77, 78, 79, 79,
};

// G.191 ignores four A-law or two mu-law low PCM bits, so the bulk tables cover every distinct
// input while keeping scalar calls free of table lookup and large retained state.
const alaw_encoding = encodingTable(.alaw);
const mulaw_encoding = encodingTable(.mulaw);

fn encodingTable(comptime law: Law) [if (law == .alaw) 4096 else 16384]u8 {
    @setEvalBranchQuota(2_000_000);
    var result: [if (law == .alaw) 4096 else 16384]u8 = undefined;
    for (&result, 0..) |*byte, index| {
        const bits: u16 = @intCast(index << (if (law == .alaw) 4 else 2));
        const sample: i16 = @bitCast(bits);
        byte.* = switch (law) {
            .alaw => encodeAlaw(sample),
            .mulaw => encodeMulaw(sample),
        };
    }
    return result;
}

const alaw_pcm16 = pcm16Samples(.alaw);
const mulaw_pcm16 = pcm16Samples(.mulaw);

fn pcm16Samples(comptime law: Law) [256]i16 {
    @setEvalBranchQuota(10_000);
    var samples: [256]i16 = undefined;
    for (&samples, 0..) |*sample, index| {
        sample.* = switch (law) {
            .alaw => decodeAlaw(@intCast(index)),
            .mulaw => decodeMulaw(@intCast(index)),
        };
    }
    return samples;
}

// Normalizing the exact integer expansion once also preserves positive zero for both mu-law zeros.
const alaw_table = normalizedSamples(.alaw);
const mulaw_table = normalizedSamples(.mulaw);

fn normalizedSamples(comptime law: Law) [256]f32 {
    @setEvalBranchQuota(10_000);
    var samples: [256]f32 = undefined;
    for (&samples, 0..) |*sample, index| {
        const byte: u8 = @intCast(index);
        const expanded = switch (law) {
            .alaw => decodeAlaw(byte),
            .mulaw => decodeMulaw(byte),
        };
        sample.* = @as(f32, @floatFromInt(expanded)) / 32768;
    }
    return samples;
}

test "bulk expansion preserves every scalar law value and unused output" {
    var source: [256]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @intCast(index);
    var output: [257]f32 = undefined;
    for ([_]Law{ .alaw, .mulaw }) |law| {
        for (0..source.len + 1) |count| {
            @memset(&output, 42);
            const decoded = try decodeInto(source[0..count], &output, law);
            for (decoded, source[0..count]) |sample, byte| {
                const expanded = switch (law) {
                    .alaw => decodeAlaw(byte),
                    .mulaw => decodeMulaw(byte),
                };
                const expected = @as(f32, @floatFromInt(expanded)) / 32768;
                try testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(sample)));
            }
            try testing.expect(std.mem.allEqual(f32, output[count..], 42));
        }
    }
}

test "G.711 endpoints zero signs and segment boundaries" {
    for (
        [_]struct {
            byte: u8,
            alaw: i16,
            mulaw: i16,
        }{
            .{ .byte = 0, .alaw = -5504, .mulaw = -32124 },
            .{ .byte = 128, .alaw = 5504, .mulaw = 32124 },
            .{ .byte = 85, .alaw = -8, .mulaw = -716 },
            .{ .byte = 213, .alaw = 8, .mulaw = 716 },
            .{ .byte = 127, .alaw = -848, .mulaw = 0 },
            .{ .byte = 255, .alaw = 848, .mulaw = 0 },
        },
    ) |case| {
        try testing.expectEqual(case.alaw, decodeAlaw(case.byte));
        try testing.expectEqual(case.mulaw, decodeMulaw(case.byte));
    }
}

test "all scalar codes and normalized words match independent segment centers" {
    // PCM16 centers and spacing for the eight quantizer segments, in increasing magnitude.
    // Construct transmitted codes from segment/position/sign, independently of decoder shifts.
    const alaw_centers = [_]i16{ 8, 264, 528, 1056, 2112, 4224, 8448, 16896 };
    const alaw_steps = [_]i16{ 16, 16, 32, 64, 128, 256, 512, 1024 };
    const mulaw_centers = [_]i16{ 0, 132, 396, 924, 1980, 4092, 8316, 16764 };
    const mulaw_steps = [_]i16{ 8, 16, 32, 64, 128, 256, 512, 1024 };
    var alaw_samples: [256]f32 = undefined;
    var mulaw_samples: [256]f32 = undefined;
    for (0..8) |segment| {
        for (0..16) |position| {
            const field: u8 = @intCast(segment * 16 + position);
            const a = alaw_centers[segment] + @as(i16, @intCast(position)) * alaw_steps[segment];
            const m = mulaw_centers[segment] + @as(i16, @intCast(position)) * mulaw_steps[segment];
            for ([_]bool{ false, true }) |positive| {
                const a_code = field ^ @as(u8, if (positive) 0xd5 else 0x55);
                const m_code = field ^ @as(u8, if (positive) 0xff else 0x7f);
                const a_sample = if (positive) a else -a;
                const m_sample = if (positive) m else -m;
                try testing.expectEqual(a_sample, decodeAlaw(a_code));
                try testing.expectEqual(m_sample, decodeMulaw(m_code));
                alaw_samples[a_code] = @as(f32, @floatFromInt(a_sample)) / 32768;
                mulaw_samples[m_code] = @as(f32, @floatFromInt(m_sample)) / 32768;
            }
        }
    }
    var source: [256]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @intCast(i);
    var output: [256]f32 = undefined;
    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(&alaw_samples),
        std.mem.sliceAsBytes(try decodeInto(&source, &output, .alaw)),
    );
    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(&mulaw_samples),
        std.mem.sliceAsBytes(try decodeInto(&source, &output, .mulaw)),
    );
}

test "short lengths and source residues preserve spare capacity and source" {
    var bytes: [73]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i * 109 + 23);
    const original = bytes;
    for ([_]Law{ .alaw, .mulaw }) |law| {
        for (0..8) |offset| {
            for (0..66) |len| {
                const source = bytes[offset..][0..len];
                var output: [67]f32 = @splat(12.5);
                const samples = try decodeInto(source, &output, law);
                try testing.expectEqual(@intFromPtr(&output), @intFromPtr(samples.ptr));
                try testing.expectEqual(len, samples.len);
                for (source, samples) |byte, sample| {
                    const expected = switch (law) {
                        .alaw => decodeAlaw(byte),
                        .mulaw => decodeMulaw(byte),
                    };
                    try testing.expectEqual(@as(f32, @floatFromInt(expected)) / 32768, sample);
                }
                for (output[len..]) |sample| try testing.expectEqual(12.5, sample);
                if (len != 0) {
                    @memset(&output, 12.5);
                    try testing.expectError(
                        error.DestinationTooSmall,
                        decodeInto(source, output[0 .. len - 1], law),
                    );
                    for (output) |sample| try testing.expectEqual(12.5, sample);
                }
            }
        }
    }
    try testing.expectEqualSlices(u8, &original, &bytes);
}

test "capacity precedes overlap and refusals leave all storage unchanged" {
    var shared: [8]f32 = @splat(0.5);
    const before = shared;
    const bytes = std.mem.sliceAsBytes(&shared);
    for ([_]Law{ .alaw, .mulaw }) |law| {
        try testing.expectError(
            error.DestinationTooSmall,
            decodeInto(bytes[4..8], shared[0..3], law),
        );
        try testing.expectError(error.Aliasing, decodeInto(bytes[4..8], shared[0..4], law));
        try testing.expectError(error.Aliasing, decodeInto(bytes[0..8], &shared, law));
        try testing.expectError(error.Aliasing, decodeInto(bytes[3..7], shared[1..5], law));
        try testing.expectEqualSlices(f32, &before, &shared);
    }
}

test "touching spans unused output capacity and empty aliasing are admitted" {
    const source = [_]u8{ 0, 128, 127, 255 };
    const expected = [_]f32{ -32124.0 / 32768.0, 32124.0 / 32768.0, 0, 0 };
    for ([_]usize{ 16, 28 }) |offset| {
        var shared: [8]f32 = @splat(0.5);
        const bytes = std.mem.sliceAsBytes(&shared);
        @memcpy(bytes[offset..][0..source.len], &source);
        const spare = shared[4..8].*;
        const result = try decodeInto(bytes[offset..][0..source.len], &shared, .mulaw);
        try testing.expectEqualSlices(f32, &expected, result);
        try testing.expectEqualSlices(u8, &source, bytes[offset..][0..source.len]);
        try testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&spare),
            std.mem.sliceAsBytes(shared[4..]),
        );
    }
    var shared: [8]f32 = @splat(0.5);
    const bytes = std.mem.sliceAsBytes(&shared);
    @memcpy(bytes[0..4], &source);
    try testing.expectEqualSlices(f32, &expected, try decodeInto(bytes[0..4], shared[1..], .mulaw));
    try testing.expectEqualSlices(u8, &source, bytes[0..4]);
    const before = shared;
    try testing.expectEqual(0, (try decodeInto(bytes[0..0], &shared, .alaw)).len);
    try testing.expectEqual(0, (try decodeInto(bytes[0..0], shared[0..0], .mulaw)).len);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&before), bytes);
}

test "G.711 PCM16 and direct bulk operations preserve unused output" {
    const samples = [_]i16{ -32768, -1, 0, 32767 };
    var encoded: [5]u8 = @splat(0x23);
    var decoded: [5]i16 = @splat(1234);
    var converted: [5]u8 = @splat(0x42);
    for ([_]Law{ .alaw, .mulaw }) |law| {
        const bytes = try encodeInto(&samples, &encoded, law);
        const expanded = try decodePcm16Into(bytes, &decoded, law);
        for (samples, bytes, expanded) |sample, byte, value| {
            try testing.expectEqual(switch (law) {
                .alaw => encodeAlaw(sample),
                .mulaw => encodeMulaw(sample),
            }, byte);
            try testing.expectEqual(switch (law) {
                .alaw => decodeAlaw(byte),
                .mulaw => decodeMulaw(byte),
            }, value);
        }
        try testing.expectEqual(@as(u8, 0x23), encoded[4]);
        try testing.expectEqual(@as(i16, 1234), decoded[4]);
        const direction: TranscodeDirection = if (law == .alaw) .alaw_to_mulaw else .mulaw_to_alaw;
        const result = try transcodeInto(bytes, &converted, direction);
        for (bytes, result) |byte, value| {
            try testing.expectEqual(switch (direction) {
                .alaw_to_mulaw => alawToMulaw(byte),
                .mulaw_to_alaw => mulawToAlaw(byte),
            }, value);
        }
        try testing.expectEqual(@as(u8, 0x42), converted[4]);
    }
}

test "G.711 bulk capacity and alias admission do not mutate storage" {
    var words = [_]i16{ 0x1234, 0x5678, 0x1234, 0x5678 };
    const bytes = std.mem.sliceAsBytes(&words);
    const before = words;

    // Capacity takes precedence even when the used output would overlap the input.
    try testing.expectError(error.DestinationTooSmall, encodeInto(words[0..3], bytes[0..2], .alaw));
    try testing.expectEqualSlices(i16, &before, &words);
    try testing.expectError(error.Aliasing, encodeInto(words[0..3], bytes[1..4], .mulaw));
    try testing.expectEqualSlices(i16, &before, &words);
    try testing.expectError(
        error.DestinationTooSmall,
        decodePcm16Into(bytes[0..3], words[0..2], .alaw),
    );
    try testing.expectEqualSlices(i16, &before, &words);
    try testing.expectError(error.Aliasing, decodePcm16Into(bytes[0..3], words[0..3], .mulaw));
    try testing.expectEqualSlices(i16, &before, &words);
    try testing.expectError(
        error.DestinationTooSmall,
        transcodeInto(bytes[0..3], bytes[1..3], .alaw_to_mulaw),
    );
    try testing.expectEqualSlices(i16, &before, &words);
    try testing.expectError(
        error.Aliasing,
        transcodeInto(bytes[0..3], bytes[1..4], .mulaw_to_alaw),
    );
    try testing.expectEqualSlices(i16, &before, &words);

    // Only the used prefix participates: an unused destination tail may overlap the input.
    const result = try transcodeInto(bytes[4..6], bytes[0..8], .alaw_to_mulaw);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(before[1..]), bytes[2..]);
    try testing.expectEqual(
        @as(usize, 0),
        (try transcodeInto(bytes[0..0], bytes, .mulaw_to_alaw)).len,
    );
}

test "G.711 direct conversions preserve the specified tandem bits" {
    // Tables 3 and 4 deliberately permit only these value numbers to change on a round trip.
    const mulaw_exceptions = [_]u8{ 0, 2, 4, 6, 8, 10, 12, 14 };
    const alaw_exceptions = [_]u8{ 26, 28, 30, 32, 45, 47, 63, 80 };
    for (0..256) |index| {
        const byte: u8 = @intCast(index);
        const mulaw_number = ~byte & 0x7f;
        const mulaw_change = std.mem.indexOfScalar(u8, &mulaw_exceptions, mulaw_number) != null;
        try testing.expectEqual(
            byte ^ @as(u8, @intFromBool(mulaw_change)),
            alawToMulaw(mulawToAlaw(byte)),
        );

        const alaw_number = ((byte ^ 0x55) & 0x7f) + 1;
        const alaw_change = std.mem.indexOfScalar(u8, &alaw_exceptions, alaw_number) != null;
        try testing.expectEqual(
            byte ^ @as(u8, @intFromBool(alaw_change)),
            mulawToAlaw(alawToMulaw(byte)),
        );
    }
}
