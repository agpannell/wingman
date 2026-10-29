//! Decode G.711 voice samples using A-law or mu-law. Each byte represents one amplitude with finer
//! spacing near silence and coarser spacing for loud signals. Expand to exact signed PCM16 with
//! decodeAlaw/decodeMulaw, or normalized caller-owned f32 storage with decodeInto.
//!
//! Every byte is valid in either law. A-law has no exact zero; mu-law has two zero codes. These
//! operations allocate nothing and retain no input. Rate, channels, containers and packets belong
//! to the caller. Encoding and the later G.711 extensions are outside this decoder's scope.
//!
//! Algorithm reference: https://www.itu.int/rec/T-REC-G.711/en

const std = @import("std");
const testing = std.testing;

/// Select the byte representation declared by the input format or protocol; neither is detected.
pub const Law = enum { alaw, mulaw };

/// DestinationTooSmall is checked before Aliasing. Both refusals leave all output unchanged.
pub const DecodeError = error{ DestinationTooSmall, Aliasing };

/// Expand source.len bytes into exactly that many f32 samples and return
/// destination[0..source.len]. Each result is the signed PCM16 value divided by 32768, exactly
/// representable in f32. Source order is preserved; this operation does not infer channels or
/// change the sampling rate.
///
/// Check destination capacity before aliasing. Source must be disjoint from the used output's byte
/// span; it may touch that span or overlap unused destination capacity. Both errors preserve the
/// whole destination, and successful conversion preserves spare output. Empty input succeeds. No
/// source or destination borrow is retained; the result borrows caller-owned destination.
pub fn decodeInto(source: []const u8, destination: []f32, law: Law) DecodeError![]f32 {
    if (destination.len < source.len) return error.DestinationTooSmall;
    const output = destination[0..source.len];
    if (overlaps(source, std.mem.sliceAsBytes(output))) return error.Aliasing;
    for (source, output) |byte, *sample| {
        const expanded = switch (law) {
            .alaw => decodeAlaw(byte),
            .mulaw => decodeMulaw(byte),
        };
        sample.* = @as(f32, @floatFromInt(expanded)) / 32768;
    }
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
    // Invert transmitted bits, then expand the four-bit position within an exponential segment.
    const value = ~encoded;
    const magnitude = (((@as(i32, value & 0x0f) << 3) + 0x84) << @intCast((value >> 4) & 0x07));
    const sample = if (value & 0x80 != 0) 0x84 - magnitude else magnitude - 0x84;
    return @intCast(sample);
}

/// Expand one A-law byte to its exact signed PCM16 value, in [-32256, 32256]. All 256 codes are
/// valid. The closest values to silence are -8 (0x55) and +8 (0xd5); there is no exact zero.
pub fn decodeAlaw(encoded: u8) i16 {
    // Undo alternating-bit inversion. The first segment has uniform 16-unit spacing.
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

// Compare address differences rather than adding lengths to possibly high addresses.
fn overlaps(first: []const u8, second: []const u8) bool {
    if (first.len == 0 or second.len == 0) return false;
    const a = @intFromPtr(first.ptr);
    const b = @intFromPtr(second.ptr);
    return if (a <= b) b - a < first.len else a - b < second.len;
}

test decodeAlaw {
    try testing.expectEqual(-8, decodeAlaw(0x55));
    try testing.expectEqual(8, decodeAlaw(0xd5));
}

test decodeMulaw {
    try testing.expectEqual(0, decodeMulaw(0x7f));
    try testing.expectEqual(0, decodeMulaw(0xff));
    try testing.expectEqual(-32124, decodeMulaw(0));
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
