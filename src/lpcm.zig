//! Convert integer PCM and finite IEEE binary32/binary64 samples using caller-owned storage. The
//! lpcm namespace covers both representations. A sample is one channel value. These operations do
//! not assign a rate or channel layout. Reduced integer precision occupies the high bits of its
//! byte container; low padding is ignored on decoding and cleared on encoding. The default
//! operations use normalized f32 samples, including finite float values outside [-1, 1]. Decoding
//! wide integers or binary64 to f32 can round. The int32 namespace decodes integer representations
//! exactly; the float64 namespace preserves finite binary64 wire values. Conversion allocates
//! nothing and retains no borrowed storage.

const std = @import("std");
const memory = @import("common/byte_ranges.zig");
const binary_float = @import("common/float.zig");
const rounding = @import("lpcm/round.zig");
const sample_rounding = @import("common/round.zig");
const testing = std.testing;

/// Encoded sample containers. Unsigned integers use a midpoint bias; signed integers use two's
/// complement. The sample's meaningful bits occupy the high end of its container.
pub const Encoding = enum {
    unsigned8,
    signed16,
    signed24,
    signed32,
    float32,
    float64,
    signed8,
    unsigned16,
    unsigned24,
    unsigned32,

    /// Byte width of one encoded sample, independent of its meaningful precision.
    pub fn byteCount(self: Encoding) usize {
        return switch (self) {
            .unsigned8, .signed8 => 1,
            .unsigned16, .signed16 => 2,
            .unsigned24, .signed24 => 3,
            .unsigned32, .signed32, .float32 => 4,
            .float64 => 8,
        };
    }
};

/// Sample representation and byte order. Byte order applies to the numerical container; meaningful
/// integer bits occupy its high end. Null precision uses every container bit. Integer precision is
/// 1 through the container width; floating-point formats require their full width. One-byte samples
/// ignore byte order. No rate or interleaving metadata is retained.
pub const Format = struct {
    encoding: Encoding,
    valid_bits: ?u7 = null,
    endian: std.lang.Endian = .little,

    fn precision(self: Format) error{InvalidFormat}!u16 {
        const width: u16 = @intCast(self.encoding.byteCount() * 8);
        const bits: u16 = self.valid_bits orelse @intCast(width);
        if (bits == 0 or bits > width) return error.InvalidFormat;
        switch (self.encoding) {
            .float32, .float64 => if (bits != width) return error.InvalidFormat,
            else => {},
        }
        return bits;
    }
};

/// Invalid representation, incomplete source, insufficient/aliased output or invalid float input.
pub const DecodeError = error{
    InvalidFormat,
    InvalidData,
    DestinationTooSmall,
    Aliasing,
    InvalidSamples,
};

/// Invalid representation, nonfinite/out-of-range samples or unrepresentable encoded extent.
pub const ValidateError = error{ InvalidFormat, InvalidSamples, SizeOverflow };

/// Encoding admission also rejects insufficient or aliased caller output.
pub const EncodeError = ValidateError || error{ DestinationTooSmall, Aliasing };

/// Exact integer PCM conversion with signed, left-aligned i32 samples.
pub const int32 = @import("lpcm/int32.zig");

/// PCM conversion with binary64 samples, including exact finite binary64 wire values.
pub const float64 = @import("lpcm/float64.zig");

test {
    _ = int32;
    _ = float64;
    _ = rounding;
    _ = sample_rounding;
}

/// Counts whole encoded samples after validating the representation. Does not inspect float values.
pub fn sampleCount(byte_count: usize, format: Format) DecodeError!usize {
    _ = try format.precision();
    const width = format.encoding.byteCount();
    if (byte_count % width != 0) return error.InvalidData;
    return byte_count / width;
}

test sampleCount {
    try testing.expectEqual(2, try sampleCount(6, .{ .encoding = .signed24 }));
    try testing.expectEqual(0, try sampleCount(0, .{ .encoding = .unsigned8 }));
    try testing.expectError(error.InvalidData, sampleCount(5, .{ .encoding = .signed24 }));
    try testing.expectError(
        error.InvalidFormat,
        sampleCount(0, .{ .encoding = .unsigned8, .valid_bits = 0 }),
    );
    try testing.expectError(
        error.InvalidFormat,
        sampleCount(0, .{ .encoding = .float32, .valid_bits = 24 }),
    );

    // Counting only inspects geometry; even the largest complete container needs no allocation.
    const largest_complete = std.math.maxInt(usize) - 3;
    try testing.expectEqual(
        largest_complete / 4,
        try sampleCount(largest_complete, .{ .encoding = .signed32 }),
    );
}

/// Converts all source samples into a used destination prefix. Capacity, format and alias failures
/// precede writes; a nonfinite float may leave partial output, which remains unpublished on error.
/// Source and the used destination must stay live and disjoint until return, and source must remain
/// unchanged. Integer samples with more than 25 meaningful bits can round to f32; the result can
/// depend on the executing thread's floating-point rounding mode and target. Binary64 samples
/// narrow to f32 using nearest-even rounding; very small values can become signed zero. A nonfinite
/// binary64 source or narrowed result fails before writing its destination slot.
pub fn decodeInto(source: []const u8, destination: []f32, format: Format) DecodeError![]f32 {
    // Establish shape and disjoint storage before decoding; a later bad float can leave writes.
    const count = try sampleCount(source.len, format);
    if (destination.len < count) return error.DestinationTooSmall;

    const output = destination[0..count];
    if (memory.overlaps(source, std.mem.sliceAsBytes(output))) return error.Aliasing;

    try decodeSamples(format, source, output);
    return output;
}

test decodeInto {
    var samples: [3]f32 = undefined;
    const source = [_]u8{ 0, 128, 255, 127, 0, 0 };
    const output = try decodeInto(&source, &samples, .{ .encoding = .signed16 });
    try testing.expectEqualSlices(f32, &.{ -1, 32767.0 / 32768.0, 0 }, output);
}

test "PCM admission preserves storage and finite float bits" {
    // Sentinels show that admission errors leave the output unchanged.
    var output: [2]f32 = .{ 123, 456 };
    try testing.expectError(
        error.InvalidData,
        decodeInto(&.{0}, &output, .{ .encoding = .signed16 }),
    );
    try testing.expectError(
        error.InvalidFormat,
        decodeInto(&.{0}, &output, .{ .encoding = .unsigned8, .valid_bits = 0 }),
    );
    try testing.expectEqualSlices(f32, &.{ 123, 456 }, &output);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], 0x80000000, .little);
    std.mem.writeInt(u32, bytes[4..8], @bitCast(@as(f32, 2)), .little);
    _ = try decodeInto(&bytes, &output, .{ .encoding = .float32 });
    try testing.expectEqual(0x80000000, @as(u32, @bitCast(output[0])));
    try testing.expectEqual(2, output[1]);
    std.mem.writeInt(u32, bytes[4..8], 0x7fc00000, .little);
    try testing.expectError(
        error.InvalidSamples,
        decodeInto(&bytes, &output, .{ .encoding = .float32 }),
    );
    var overlap: [2]f32 = undefined;
    try testing.expectError(
        error.Aliasing,
        decodeInto(std.mem.sliceAsBytes(&overlap), &overlap, .{ .encoding = .float32 }),
    );
}

test "binary64 narrowing checks the rounded value and preserves the failing slot" {
    // The overflow midpoint fails only after the preceding finite values have been decoded.
    const inputs = [_]u64{
        0x8000_0000_0000_0000, // negative zero
        0x3690_0000_0000_0001, // just above half the smallest f32 subnormal
        0x47ef_ffff_efff_ffff, // above f32 maximum, but still rounds to it
        0x47ef_ffff_f000_0000, // overflow midpoint
    };
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        var bytes: [inputs.len * 8]u8 = undefined;
        for (inputs, 0..) |word, index| {
            std.mem.writeInt(u64, bytes[index * 8 ..][0..8], word, endian);
        }
        var output = [_]f32{ 123, 123, 123, 123 };
        try testing.expectError(
            error.InvalidSamples,
            decodeInto(&bytes, &output, .{ .encoding = .float64, .endian = endian }),
        );
        try testing.expectEqual(@as(u32, 0x8000_0000), @as(u32, @bitCast(output[0])));
        try testing.expectEqual(@as(u32, 1), @as(u32, @bitCast(output[1])));
        try testing.expectEqual(@as(u32, 0x7f7f_ffff), @as(u32, @bitCast(output[2])));
        try testing.expectEqual(@as(f32, 123), output[3]);
    }
}

test "binary64 format validates precision and widens finite f32 values" {
    try testing.expectEqual(
        @as(usize, 1),
        try sampleCount(8, .{ .encoding = .float64, .valid_bits = 64 }),
    );
    try testing.expectError(
        error.InvalidFormat,
        sampleCount(0, .{ .encoding = .float64, .valid_bits = 32 }),
    );
    const samples = [_]f32{ -0.0, 0.5, -2 };
    var bytes: [24]u8 = undefined;
    const output = try encodeInto(&samples, &bytes, .{ .encoding = .float64, .endian = .big });
    try testing.expectEqual(
        @as(u64, 0x8000_0000_0000_0000),
        std.mem.readInt(u64, output[0..8], .big),
    );
    try testing.expectEqual(
        @as(u64, 0x3fe0_0000_0000_0000),
        std.mem.readInt(u64, output[8..16], .big),
    );
    try testing.expectEqual(
        @as(u64, 0xc000_0000_0000_0000),
        std.mem.readInt(u64, output[16..24], .big),
    );
    var short: [7]u8 = @splat(0);
    var writer: std.Io.Writer = .fixed(&short);
    try testing.expectError(
        error.WriteFailed,
        writeAll(samples[1..2], &writer, .{ .encoding = .float64, .endian = .big }),
    );
    try testing.expectEqualSlices(u8, output[8..15], writer.buffered());
}

test "signed 8-bit PCM uses two's complement without an unsigned bias" {
    const source = [_]u8{ 0x80, 0xff, 0, 0x7f };
    const expected = [_]f32{ -1, -1.0 / 128.0, 0, 127.0 / 128.0 };
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        const format: Format = .{ .encoding = .signed8, .endian = endian };
        var samples: [4]f32 = undefined;
        try testing.expectEqualSlices(f32, &expected, try decodeInto(&source, &samples, format));
        var bytes: [4]u8 = undefined;
        try testing.expectEqualSlices(u8, &source, try encodeInto(&samples, &bytes, format));
        var writer: std.Io.Writer = .fixed(&bytes);
        try writeAll(&samples, &writer, format);
        try testing.expectEqualSlices(u8, &source, writer.buffered());

        const reduced: Format = .{ .encoding = .signed8, .valid_bits = 3, .endian = endian };
        const dirty = [_]u8{ 0x9f, 0xff, 0x1f, 0x7f };
        try testing.expectEqualSlices(f32, &.{
            -1, -0.25, 0, 0.75,
        }, try decodeInto(&dirty, &samples, reduced));
        try testing.expectEqualSlices(u8, &.{
            0x80, 0xe0, 0, 0x60,
        }, try encodeInto(&samples, &bytes, reduced));
    }
}

test "full-width signed 8-bit vector batches preserve endpoints and tails" {
    const pattern = [_]u8{ 0x80, 0xff, 0, 0x7f };
    const expected = [_]f32{ -1, -1.0 / 128.0, 0, 127.0 / 128.0 };
    var source: [37]u8 = undefined;
    var wanted: [37]f32 = undefined;
    for (&source, &wanted, 0..) |*byte, *sample, index| {
        byte.* = pattern[index % pattern.len];
        sample.* = expected[index % expected.len];
    }
    for (0..source.len + 1) |count| {
        for ([_]std.lang.Endian{ .little, .big }) |endian| {
            const format: Format = .{ .encoding = .signed8, .endian = endian };
            var samples: [37]f32 = @splat(42);
            try testing.expectEqualSlices(
                f32,
                wanted[0..count],
                try decodeInto(source[0..count], &samples, format),
            );
            try testing.expect(std.mem.allEqual(f32, samples[count..], 42));
            var encoded: [37]u8 = @splat(0xa5);
            try testing.expectEqualSlices(
                u8,
                source[0..count],
                try encodeInto(wanted[0..count], &encoded, format),
            );
            try testing.expect(std.mem.allEqual(u8, encoded[count..], 0xa5));
        }
    }
}

test "PCM vector bodies and exact unaligned tails agree with independent dyadic values" {
    // Lengths straddle typical vector boundaries and offsets exercise unaligned source. Dyadic
    // reference values are independent of the decoder; destination sentinels guard both ends.
    for ([_]Encoding{ .unsigned8, .signed16 }) |encoding| {
        const width = encoding.byteCount();
        for ([_]usize{ 0, 1, 3, 4, 5, 15, 16, 17, 31, 32, 33, 63, 65 }) |count| {
            for (0..8) |offset| {
                var storage: [8 + 65 * 2]u8 = undefined;
                const source = storage[offset..][0 .. count * width];
                var expected: [65]f32 = undefined;
                for (0..count) |i| {
                    if (encoding == .unsigned8) {
                        const raw: u8 = @intCast((i * 37 + offset * 11) % 256);
                        source[i] = raw;
                        expected[i] = @floatCast((@as(f64, @floatFromInt(raw)) - 128) / 128);
                    } else {
                        const raw: i16 = @bitCast(
                            @as(u16, @intCast((i * 257 + offset * 317) % 65536)),
                        );
                        std.mem.writeInt(i16, source[i * 2 ..][0..2], raw, .little);
                        expected[i] = @floatCast(@as(f64, @floatFromInt(raw)) / 32768);
                    }
                }

                var destination: [67]f32 = @splat(123);
                const result = try decodeInto(
                    source,
                    destination[1..66],
                    .{ .encoding = encoding },
                );
                try testing.expectEqual(count, result.len);
                try testing.expectEqualSlices(f32, expected[0..count], result);
                try testing.expectEqual(123, destination[0]);
                try testing.expect(std.mem.allEqual(f32, destination[1 + count ..], 123));
            }
        }
    }
}

test "PCM finite binary32 words survive exactly and failed output remains unpublished" {
    // Literal bits include signed zeros, subnormals and finite values outside the integer range.
    // The separate nonfinite cases also show that an earlier decoded sample can be written on
    // error.
    const words = [_]u32{ 0, 0x80000000, 1, 0x80000001, 0x7f7fffff, 0xff7fffff, 0x40000000 };
    var bytes: [words.len * 4]u8 = undefined;
    for (words, 0..) |word, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], word, .little);

    var output: [words.len]f32 = undefined;
    const result = try decodeInto(&bytes, &output, .{ .encoding = .float32 });
    for (words, result) |word, value| try testing.expectEqual(word, @as(u32, @bitCast(value)));

    var invalid: [8]u8 = undefined;
    std.mem.writeInt(u32, invalid[0..4], 0x3f000000, .little);
    for ([_]u32{ 0x7f800000, 0xff800000, 0x7fc00000 }) |word| {
        std.mem.writeInt(u32, invalid[4..8], word, .little);
        var guarded: [3]f32 = .{ 27, 31, 37 };
        try testing.expectError(
            error.InvalidSamples,
            decodeInto(&invalid, &guarded, .{ .encoding = .float32 }),
        );
        try testing.expectEqual(0.5, guarded[0]);
        try testing.expectEqual(37, guarded[2]);
    }
}

/// Validates the representation, output extent and all input without writing or retaining storage.
/// Integer input must be finite and in [-1, 1]; floating-point formats accept any finite f32.
pub fn validate(source: []const f32, format: Format) ValidateError!void {
    _ = try format.precision();
    const width = format.encoding.byteCount();
    if (source.len > std.math.maxInt(usize) / width) return error.SizeOverflow;

    // IEEE magnitude orders finite values and places infinities and NaNs above both limits, so one
    // integer comparison checks range and finiteness in every lane.
    const limit: u32 = if (format.encoding == .float32 or format.encoding == .float64)
        0x7f7f_ffff
    else
        0x3f80_0000;
    const Floats = @Vector(pcm_vector_lanes, f32);
    const Words = @Vector(pcm_vector_lanes, u32);
    var index: usize = 0;
    while (index + pcm_vector_lanes <= source.len) : (index += pcm_vector_lanes) {
        const samples: Floats = source[index..][0..pcm_vector_lanes].*;
        const words: Words = @bitCast(samples);
        const magnitude = words & @as(Words, @splat(0x7fff_ffff));
        if (@reduce(.Or, magnitude > @as(Words, @splat(limit)))) return error.InvalidSamples;
    }
    for (source[index..]) |sample| {
        const bits: u32 = @bitCast(sample);
        if (bits & 0x7fff_ffff > limit) return error.InvalidSamples;
    }
}

test validate {
    try validate(&.{ -1, 0, 1 }, .{ .encoding = .signed16 });
    try testing.expectError(error.InvalidSamples, validate(&.{2}, .{ .encoding = .signed16 }));
    try validate(&.{2}, .{ .encoding = .float32 });
}

test "PCM16 encoding validates every sample before changing caller bytes" {
    // A late NaN or short destination must leave every sentinel byte untouched.
    var bytes: [12]u8 = @splat(0xa5);
    try testing.expectError(
        error.InvalidSamples,
        encodeInto(&.{ 0, std.math.nan(f32) }, &bytes, .{ .encoding = .signed16 }),
    );
    try testing.expect(std.mem.allEqual(u8, &bytes, 0xa5));
    try testing.expectError(error.DestinationTooSmall, encodeInto(&.{
        -1, 1,
    }, bytes[0..3], .{ .encoding = .signed16 }));
    try testing.expect(std.mem.allEqual(u8, &bytes, 0xa5));
    const output = try encodeInto(&.{
        -1, 1, -0.5, 0.5, 0, 0.25,
    }, &bytes, .{ .encoding = .signed16 });
    try testing.expectEqualSlices(u8, &.{ 0, 128, 255, 127, 0, 192, 0, 64, 0, 0, 0, 32 }, output);
}

test "vector validation rejects every invalid lane and preserves caller output" {
    // Place each invalid value in every lane and tail position to exercise whole-input admission.
    const count = pcm_vector_lanes * 2 + 3;
    var input: [count]f32 = @splat(0.5);
    var output: [count * 4]u8 = undefined;
    const bad_values = [_]f32{
        std.math.nan(f32),
        std.math.inf(f32),
        -std.math.inf(f32),
        @bitCast(@as(u32, 0x3f80_0001)),
        @bitCast(@as(u32, 0xbf80_0001)),
    };
    for (bad_values) |bad| {
        for (0..count) |index| {
            input[index] = bad;
            @memset(&output, 0xa5);
            try testing.expectError(
                error.InvalidSamples,
                encodeInto(&input, &output, .{ .encoding = .signed16 }),
            );
            try testing.expect(std.mem.allEqual(u8, &output, 0xa5));
            input[index] = 0.5;
        }
    }
}

/// Encodes into a borrowed byte prefix, preserving the whole destination on admission failure.
/// Integer input is multiplied by 2^(valid bits - 1), rounded halfway away from zero and clamped to
/// the signed range. Unsigned formats are biased by the same power of two; low padding is zeroed.
/// Finite float32 samples retain their bits, including signed zero and values outside [-1, 1].
/// Encoding finite f32 samples as binary64 is exact.
pub fn encodeInto(source: []const f32, destination: []u8, format: Format) EncodeError![]u8 {
    // Validate before capacity and overlap checks, preserving admission order and output bytes.
    try validate(source, format);
    const bits = format.precision() catch unreachable;
    const bytes = source.len * format.encoding.byteCount();
    if (destination.len < bytes) return error.DestinationTooSmall;

    const output = destination[0..bytes];
    // Only the used prefix is written; unused destination capacity may overlap the source.
    if (memory.overlaps(std.mem.sliceAsBytes(source), output)) return error.Aliasing;

    encodeSamples(source, output, format, bits);
    return output;
}

test encodeInto {
    var storage: [6]u8 = undefined;
    const bytes = try encodeInto(&.{
        -1, 1,
    }, &storage, .{ .encoding = .signed24, .valid_bits = 20, .endian = .big });
    try testing.expectEqualSlices(u8, &.{ 0x80, 0, 0, 0x7f, 0xff, 0xf0 }, bytes);
}

test "integer encoding rounds half ties away from zero at every precision" {
    // Both signs expose tie direction; at one bit, the positive endpoint cannot represent +1.
    const count = pcm_vector_lanes * 2 + 3;
    for ([_]Encoding{ .unsigned8, .signed8, .signed16, .signed24, .signed32 }) |encoding| {
        const width = encoding.byteCount();
        for (1..width * 8 + 1) |bits| {
            const midpoint: i64 = @as(i64, 1) << @intCast(bits - 1);
            const half: f32 = @floatCast(0.5 / @as(f64, @floatFromInt(midpoint)));
            var samples: [count]f32 = undefined;
            for (&samples, 0..) |*sample, index| sample.* = if (index % 2 == 0) half else -half;
            for ([_]std.lang.Endian{ .little, .big }) |endian| {
                var expected: [count * 4]u8 = @splat(0);
                for (0..count) |index| {
                    const signed: i64 = if (index % 2 == 0) @min(1, midpoint - 1) else -1;
                    const biased = if (encoding == .unsigned8) signed + midpoint else signed;
                    const mask = (@as(u64, 1) << @intCast(bits)) - 1;
                    const word: u32 = @intCast(
                        (@as(u64, @bitCast(biased)) & mask) << @intCast(width * 8 - bits),
                    );
                    const dest = expected[index * width ..][0..width];
                    switch (width) {
                        1 => dest[0] = @intCast(word),
                        2 => std.mem.writeInt(u16, dest[0..2], @intCast(word), endian),
                        3 => std.mem.writeInt(u24, dest[0..3], @intCast(word), endian),
                        4 => std.mem.writeInt(u32, dest[0..4], word, endian),
                        else => unreachable,
                    }
                }
                const format: Format = .{
                    .encoding = encoding,
                    .valid_bits = @intCast(bits),
                    .endian = endian,
                };
                var bytes: [count * 4]u8 = @splat(0xa5);
                const actual = try encodeInto(&samples, &bytes, format);
                try testing.expectEqualSlices(u8, expected[0 .. count * width], actual);
                @memset(&bytes, 0xa5);
                var writer: std.Io.Writer = .fixed(&bytes);
                try writeAll(&samples, &writer, format);
                try testing.expectEqualSlices(u8, expected[0 .. count * width], writer.buffered());
            }
        }
    }
}

test "full-width output preserves endpoints across vector boundaries and tails" {
    // Counts around vector boundaries and trailing sentinels detect partial-lane overwrites.
    const count = pcm_vector_lanes * 2 + 3;
    var samples: [count]f32 = undefined;
    for (&samples, 0..) |*sample, i| sample.* = ([_]f32{ -1, 0, 1 })[i % 3];
    const cases = .{ .{ Encoding.unsigned8, 1, [3][4]u8{ .{
        0, 0, 0, 0,
    }, .{
        128, 0, 0, 0,
    }, .{
        255, 0, 0, 0,
    } } }, .{ Encoding.signed24, 3, [3][4]u8{ .{
        0, 0, 128, 0,
    }, .{
        0, 0, 0, 0,
    }, .{
        255, 255, 127, 0,
    } } }, .{ Encoding.signed32, 4, [3][4]u8{ .{
        0, 0, 0, 128,
    }, .{
        0, 0, 0, 0,
    }, .{
        255, 255, 255, 127,
    } } } };
    inline for (cases) |case| {
        const expected: [3][4]u8 = case[2];
        for ([_]std.lang.Endian{ .little, .big }) |endian| {
            for (0..count + 1) |length| {
                var output: [count * 4 + 1]u8 = @splat(0xa5);
                const used = try encodeInto(
                    samples[0..length],
                    &output,
                    .{ .encoding = case[0], .endian = endian },
                );
                try testing.expectEqual(length * case[1], used.len);
                for (used, 0..) |byte, offset| {
                    const lane = offset % case[1];
                    const wire_index = if (endian == .little) lane else case[1] - 1 - lane;
                    try testing.expectEqual(expected[(offset / case[1]) % 3][wire_index], byte);
                }
                try testing.expect(std.mem.allEqual(u8, output[used.len..], 0xa5));
            }
        }
    }
}

test "symmetric PCM encoding preserves endpoints, byte order and finite float bits" {
    var storage: [16]u8 = @splat(0xa5);
    const signed32 = try encodeInto(&.{
        -1, 1,
    }, &storage, .{ .encoding = .signed32, .endian = .big });
    try testing.expectEqualSlices(u8, &.{ 0x80, 0, 0, 0, 0x7f, 0xff, 0xff, 0xff }, signed32);
    const one_bit = try encodeInto(&.{
        -1, 0, 1,
    }, &storage, .{ .encoding = .unsigned8, .valid_bits = 1 });
    try testing.expectEqualSlices(u8, &.{ 0, 128, 128 }, one_bit);
    const input = [_]f32{ @bitCast(@as(u32, 0x8000_0000)), 2, @bitCast(@as(u32, 1)) };
    const float = try encodeInto(&input, &storage, .{ .encoding = .float32, .endian = .big });
    try testing.expectEqualSlices(u8, &.{ 128, 0, 0, 0, 0x40, 0, 0, 0, 0, 0, 0, 1 }, float);
    var decoded: [3]f32 = undefined;
    _ = try decodeInto(float, &decoded, .{ .encoding = .float32, .endian = .big });
    for (input, decoded) |expected, actual| {
        try testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(actual)));
    }
    try testing.expectError(
        error.InvalidFormat,
        encodeInto(&.{std.math.nan(f32)}, &.{}, .{ .encoding = .float32, .valid_bits = 1 }),
    );
}

/// Writes every sample in the chosen representation, after validating the complete source. Writer
/// failure may leave a byte prefix; the caller owns flushing and must keep source disjoint from
/// Writer storage. Integer samples use the quantization described by `encodeInto`.
pub fn writeAll(
    source: []const f32,
    writer: *std.Io.Writer,
    format: Format,
) (ValidateError || std.Io.Writer.Error)!void {
    try validate(source, format);
    const bits = format.precision() catch unreachable;
    const width = format.encoding.byteCount();
    var index: usize = 0;
    while (index < source.len) {
        const available = writer.unusedCapacitySlice();
        const count = @min(available.len / width, source.len - index);
        if (count == 0) {
            var bytes: [8]u8 = undefined;
            encodeSamples(source[index..][0..1], bytes[0..width], format, bits);
            try writer.writeAll(bytes[0..width]);
            index += 1;
            continue;
        }
        encodeSamples(source[index..][0..count], available[0 .. count * width], format, bits);
        writer.advance(count * width);
        index += count;
    }
}

test writeAll {
    var storage: [3]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try writeAll(&.{-1}, &writer, .{ .encoding = .signed24, .endian = .big });
    try testing.expectEqualSlices(u8, &.{ 0x80, 0, 0 }, writer.buffered());
}

test "PCM16 writer preserves complete and partial output at every fixed capacity" {
    // A fixed writer can publish a byte prefix before it reports exhaustion, even mid-sample.
    const samples = [_]f32{ -1, -0.5, 0, 0.25, 0.5, 1 };
    const expected = [_]u8{ 0, 128, 0, 192, 0, 0, 0, 32, 0, 64, 255, 127 };
    for (0..expected.len + 1) |capacity| {
        var storage: [expected.len + 1]u8 = @splat(0xa5);
        var writer: std.Io.Writer = .fixed(storage[0..capacity]);
        if (capacity == expected.len) {
            try writeAll(&samples, &writer, .{ .encoding = .signed16 });
        } else {
            try testing.expectError(
                error.WriteFailed,
                writeAll(&samples, &writer, .{ .encoding = .signed16 }),
            );
        }
        try testing.expectEqualSlices(u8, expected[0..capacity], writer.buffered());
        try testing.expect(std.mem.allEqual(u8, storage[capacity..], 0xa5));
    }
}

test "PCM16 ties round away from zero and backend failure follows validation" {
    const source = [_]f32{ 1.0 / 65536.0, -1.0 / 65536.0, 3.0 / 65536.0, -3.0 / 65536.0, 1, -1 };
    var bytes: [12]u8 = undefined;
    const encoded = try encodeInto(&source, &bytes, .{ .encoding = .signed16 });
    try testing.expectEqualSlices(u8, &.{
        1, 0, 255, 255, 2, 0, 254, 255, 255, 127, 0, 128,
    }, encoded);

    var failing: std.Io.Writer = .failing;
    try testing.expectError(
        error.InvalidSamples,
        writeAll(&.{std.math.nan(f32)}, &failing, .{ .encoding = .signed16 }),
    );
    try testing.expectError(
        error.WriteFailed,
        writeAll(&.{0}, &failing, .{ .encoding = .signed16 }),
    );
}

test "PCM admission checks only the used destination and preserves alias refusals" {
    var shared: [4]f32 = .{ -1, 0.5, 55, 66 };
    const bytes = std.mem.sliceAsBytes(&shared);
    try testing.expectError(
        error.Aliasing,
        decodeInto(bytes[0..4], shared[0..2], .{ .encoding = .signed16 }),
    );
    try testing.expectError(
        error.Aliasing,
        encodeInto(shared[0..2], bytes[4..8], .{ .encoding = .signed16 }),
    );
    try testing.expectEqualSlices(f32, &.{ -1, 0.5, 55, 66 }, &shared);

    @memcpy(bytes[8..12], &[_]u8{ 0, 128, 0, 64 });
    const decoded = try decodeInto(bytes[8..12], &shared, .{ .encoding = .signed16 });
    try testing.expectEqualSlices(f32, &.{ -1, 0.5 }, decoded);
    try testing.expectEqualSlices(u8, &.{ 0, 128, 0, 64 }, bytes[8..12]);
    try testing.expectEqual(66, shared[3]);

    shared = .{ 55, 66, -1, 0.5 };
    const encoded = try encodeInto(shared[2..4], bytes, .{ .encoding = .signed16 });
    try testing.expectEqualSlices(u8, &.{ 0, 128, 0, 64 }, encoded);
    try testing.expectEqualSlices(f32, &.{ -1, 0.5 }, shared[2..4]);
}

fn encodeSamples(source: []const f32, output: []u8, format: Format, bits: u16) void {
    // The fast path has the same admitted format and wire bytes as the general typed path.
    if (format.encoding == .signed16 and bits == 16 and format.endian == .little) {
        encodePcm16Samples(source, output);
        return;
    }
    switch (format.encoding) {
        inline else => |encoding| switch (format.endian) {
            .little => encodeTyped(source, output, bits, encoding, .little),
            .big => encodeTyped(source, output, bits, encoding, .big),
        },
    }
}

fn encodeTyped(
    source: []const f32,
    output: []u8,
    bits: u16,
    comptime encoding: Encoding,
    comptime endian: std.lang.Endian,
) void {
    if (encoding == .float64) {
        encodeFloat64Samples(source, output, endian);
        return;
    }
    if (encoding == .float32) {
        const Floats = @Vector(pcm_vector_lanes, f32);
        const Words = @Vector(pcm_vector_lanes, u32);
        var index: usize = 0;
        while (index + pcm_vector_lanes <= source.len) : (index += pcm_vector_lanes) {
            const samples: Floats = source[index..][0..pcm_vector_lanes].*;
            const words: Words = @bitCast(samples);
            const array: [pcm_vector_lanes]u32 = words;
            inline for (0..pcm_vector_lanes) |lane| {
                std.mem.writeInt(u32, output[(index + lane) * 4 ..][0..4], array[lane], endian);
            }
        }
        for (source[index..], index..) |sample, i| {
            std.mem.writeInt(u32, output[i * 4 ..][0..4], @bitCast(sample), endian);
        }
        return;
    }
    if (encoding == .unsigned8 and bits == 8) {
        encodePcm8Samples(source, output);
        return;
    }
    if (encoding == .signed8 and bits == 8) {
        encodeSignedPcm8Samples(source, output);
        return;
    }
    if (encoding == .signed24 and bits == 24) {
        encodePcm24Samples(source, output, endian);
        return;
    }
    if (encoding == .signed32 and bits == 32) {
        encodePcm32Samples(source, output, endian);
        return;
    }
    encodeIntegerSamples(source, output, bits, encoding, endian);
}

fn encodeFloat64Samples(source: []const f32, output: []u8, comptime endian: std.lang.Endian) void {
    const lanes = std.simd.suggestVectorLength(f64) orelse 1;
    const Narrow = @Vector(lanes, f32);
    const Wide = @Vector(lanes, f64);
    const Words = @Vector(lanes, u32);
    const zero: Words = @splat(0);
    const min_normal: Words = @splat(0x0080_0000);
    var index: usize = 0;
    while (source.len - index >= lanes) : (index += lanes) {
        const samples: Narrow = source[index..][0..lanes].*;
        const words: Words = @bitCast(samples);
        const magnitude = words & @as(Words, @splat(0x7fff_ffff));
        const subnormal = (magnitude != zero) & (magnitude < min_normal);
        var widened: [lanes]f64 = undefined;
        if (@reduce(.Or, subnormal)) {
            // Hardware widening can flush f32 subnormals before conversion to f64.
            inline for (0..lanes) |lane| widened[lane] = binary_float.widen32(samples[lane]);
        } else {
            const values: Wide = @floatCast(samples);
            widened = values;
        }
        inline for (0..lanes) |lane| {
            std.mem.writeInt(
                u64,
                output[(index + lane) * 8 ..][0..8],
                @bitCast(widened[lane]),
                endian,
            );
        }
    }
    for (source[index..], index..) |sample, i| {
        std.mem.writeInt(
            u64,
            output[i * 8 ..][0..8],
            @bitCast(binary_float.widen32(sample)),
            endian,
        );
    }
}

fn encodeIntegerSamples(
    source: []const f32,
    output: []u8,
    bits: u16,
    comptime encoding: Encoding,
    comptime endian: std.lang.Endian,
) void {
    const width = encoding.byteCount();
    const midpoint: i64 = @as(i64, 1) << @intCast(bits - 1);
    const scale: f64 = @floatFromInt(midpoint);
    const mask = (@as(u64, 1) << @intCast(bits)) - 1;
    // Clamp the asymmetric signed range before biasing; shifting leaves low wire padding zero.
    for (source, 0..) |sample, index| {
        const rounded = sample_rounding.halfAwayScaled(sample, scale);
        const clamped = std.math.clamp(rounded, -midpoint, midpoint - 1);
        const number: i64 = switch (encoding) {
            .unsigned8, .unsigned16, .unsigned24, .unsigned32 => clamped + midpoint,
            else => clamped,
        };
        const word: u32 = @intCast(
            (@as(u64, @bitCast(number)) & mask) << @intCast(width * 8 - bits),
        );
        const dest = output[index * width ..][0..width];
        switch (width) {
            1 => dest[0] = @intCast(word),
            2 => std.mem.writeInt(u16, dest[0..2], @intCast(word), endian),
            3 => {
                const bytes = [3]u8{ @truncate(word), @truncate(word >> 8), @truncate(word >> 16) };
                if (endian == .little) {
                    dest[0..3].* = bytes;
                } else {
                    dest[0..3].* = .{ bytes[2], bytes[1], bytes[0] };
                }
            },
            4 => std.mem.writeInt(u32, dest[0..4], word, endian),
            else => unreachable,
        }
    }
}

fn encodePcm8Samples(source: []const f32, output: []u8) void {
    const Floats = @Vector(pcm_vector_lanes, f32);
    const Integers = @Vector(pcm_vector_lanes, i32);
    const Unsigned = @Vector(pcm_vector_lanes, u32);
    const Bytes = @Vector(pcm_vector_lanes, u8);
    var index: usize = 0;
    while (index + pcm_vector_lanes <= source.len) : (index += pcm_vector_lanes) {
        const samples: Floats = source[index..][0..pcm_vector_lanes].*;
        const rounded = roundPcmVector(samples * @as(Floats, @splat(128)));
        const integers = @min(rounded, @as(Integers, @splat(127)));
        // Values are in 0..255 after bias. Zig 0.17 LLVM baseline x86 can lower a direct signed
        // vector-to-u8 cast with signed saturation; truncating unsigned words preserves the range.
        const biased: Unsigned = @bitCast(integers + @as(Integers, @splat(128)));
        const bytes: Bytes = @truncate(biased);
        output[index..][0..pcm_vector_lanes].* = bytes;
    }
    encodeIntegerSamples(source[index..], output[index..], 8, .unsigned8, .little);
}

fn encodeSignedPcm8Samples(source: []const f32, output: []u8) void {
    const Floats = @Vector(pcm_vector_lanes, f32);
    const Signed = @Vector(pcm_vector_lanes, i32);
    const Unsigned = @Vector(pcm_vector_lanes, u32);
    const Bytes = @Vector(pcm_vector_lanes, u8);
    var index: usize = 0;
    while (index + pcm_vector_lanes <= source.len) : (index += pcm_vector_lanes) {
        const samples: Floats = source[index..][0..pcm_vector_lanes].*;
        const rounded = roundPcmVector(samples * @as(Floats, @splat(128)));
        const signed = @min(rounded, @as(Signed, @splat(127)));
        // Truncating unsigned bit patterns preserves the two's-complement bytes without casting
        // negative signed values to u8.
        const unsigned: Unsigned = @bitCast(signed);
        const bytes: Bytes = @truncate(unsigned);
        output[index..][0..pcm_vector_lanes].* = bytes;
    }
    encodeIntegerSamples(source[index..], output[index..], 8, .signed8, .little);
}

fn encodePcm24Samples(source: []const f32, output: []u8, comptime endian: std.lang.Endian) void {
    const Floats = @Vector(pcm_vector_lanes, f32);
    const Integers = @Vector(pcm_vector_lanes, i32);
    var index: usize = 0;
    while (index + pcm_vector_lanes <= source.len) : (index += pcm_vector_lanes) {
        const samples: Floats = source[index..][0..pcm_vector_lanes].*;
        const rounded = roundPcmVector(samples * @as(Floats, @splat(8_388_608)));
        const integers = @min(rounded, @as(Integers, @splat(8_388_607)));
        const words: [pcm_vector_lanes]i32 = integers;
        inline for (0..pcm_vector_lanes) |lane| {
            const word: u32 = @bitCast(words[lane]);
            const dest = output[(index + lane) * 3 ..][0..3];
            if (endian == .little) {
                dest.* = .{ @truncate(word), @truncate(word >> 8), @truncate(word >> 16) };
            } else {
                dest.* = .{ @truncate(word >> 16), @truncate(word >> 8), @truncate(word) };
            }
        }
    }
    encodeIntegerSamples(source[index..], output[index * 3 ..], 24, .signed24, endian);
}

fn encodePcm32Samples(source: []const f32, output: []u8, comptime endian: std.lang.Endian) void {
    const Floats = @Vector(pcm_vector_lanes, f32);
    const Integers = @Vector(pcm_vector_lanes, i32);
    var index: usize = 0;
    while (index + pcm_vector_lanes <= source.len) : (index += pcm_vector_lanes) {
        const samples: Floats = source[index..][0..pcm_vector_lanes].*;
        // The largest f32 below one scales to a representable i32. The positive endpoint is
        // selected separately because 2^31 - 1 cannot itself be represented as f32.
        const below_one: f32 = @bitCast(@as(u32, 0x3f7f_ffff));
        const clipped = @min(samples, @as(Floats, @splat(below_one)));
        const integers = roundPcmVector(clipped * @as(Floats, @splat(2_147_483_648)));
        const corrected = @select(
            i32,
            samples == @as(Floats, @splat(1)),
            @as(Integers, @splat(std.math.maxInt(i32))),
            integers,
        );
        const words: [pcm_vector_lanes]i32 = corrected;
        inline for (0..pcm_vector_lanes) |lane| {
            std.mem.writeInt(i32, output[(index + lane) * 4 ..][0..4], words[lane], endian);
        }
    }
    encodeIntegerSamples(source[index..], output[index * 4 ..], 32, .signed32, endian);
}

fn encodePcm16Samples(source: []const f32, output: []u8) void {
    // Scaling maps -1 exactly to -32768; +1 must be clamped to the largest signed sample.
    const Floats = @Vector(pcm_vector_lanes, f32);
    const Integers = @Vector(pcm_vector_lanes, i32);
    const Samples = @Vector(pcm_vector_lanes, i16);
    var index: usize = 0;
    while (index + pcm_vector_lanes <= source.len) : (index += pcm_vector_lanes) {
        const samples: Floats = source[index..][0..pcm_vector_lanes].*;
        const rounded = roundPcmVector(samples * @as(Floats, @splat(32768)));
        const integers = @min(rounded, @as(Integers, @splat(32767)));
        const narrowed: Samples = @intCast(integers);
        const words: [pcm_vector_lanes]i16 = narrowed;
        inline for (0..pcm_vector_lanes) |lane| {
            std.mem.writeInt(i16, output[(index + lane) * 2 ..][0..2], words[lane], .little);
        }
    }
    for (source[index..], index..) |sample, i| {
        std.mem.writeInt(
            i16,
            output[i * 2 ..][0..2],
            @intCast(@min(32767, sample_rounding.halfAwayScaled(sample, 32768))),
            .little,
        );
    }
}

fn roundPcmVector(scaled: @Vector(pcm_vector_lanes, f32)) @Vector(pcm_vector_lanes, i32) {
    const Floats = @Vector(pcm_vector_lanes, f32);
    const Integers = @Vector(pcm_vector_lanes, i32);
    // Truncation supplies the integer toward zero; the residual decides whether to move one step
    // away. This avoids relying on the caller's floating-point rounding mode for halfway cases.
    const whole: Integers = @trunc(scaled);
    const fraction = @abs(scaled - @as(Floats, @floatFromInt(whole)));
    const direction = @select(
        i32,
        scaled < @as(Floats, @splat(0)),
        @as(Integers, @splat(-1)),
        @as(Integers, @splat(1)),
    );
    const adjustment = @select(
        i32,
        fraction >= @as(Floats, @splat(0.5)),
        direction,
        @as(Integers, @splat(0)),
    );
    return whole + adjustment;
}

const pcm_vector_lanes = std.simd.suggestVectorLength(f32) orelse 1;
const Pcm8Bytes = @Vector(pcm_vector_lanes, u8);
const Pcm8Wide = @Vector(pcm_vector_lanes, i32);
const Pcm8Floats = @Vector(pcm_vector_lanes, f32);
const Pcm16Bytes = @Vector(pcm_vector_lanes * 2, u8);
const Pcm16Samples = @Vector(pcm_vector_lanes, i16);
const Pcm16Wide = @Vector(pcm_vector_lanes, i32);
const Pcm16Floats = @Vector(pcm_vector_lanes, f32);
const pcm16_low_indices: [pcm_vector_lanes]i32 = blk: {
    var indices: [pcm_vector_lanes]i32 = undefined;
    for (&indices, 0..) |*index, lane| index.* = @intCast(lane * 2);
    break :blk indices;
};
const pcm16_high_indices: [pcm_vector_lanes]i32 = blk: {
    var indices: [pcm_vector_lanes]i32 = undefined;
    for (&indices, 0..) |*index, lane| index.* = @intCast(lane * 2 + 1);
    break :blk indices;
};
const pcm24_byte_indices: [3][pcm_vector_lanes]i32 = blk: {
    var indices: [3][pcm_vector_lanes]i32 = undefined;
    for (&indices, 0..) |*byte_indices, byte| {
        for (byte_indices, 0..) |*index, lane| index.* = @intCast(lane * 3 + byte);
    }
    break :blk indices;
};

fn decodeUnsignedPcm(raw: u8, valid_bits_per_sample: u16) f32 {
    const shift = 8 - valid_bits_per_sample;
    const sample: u8 = raw >> @intCast(shift);
    const midpoint: f32 = @floatFromInt(@as(u64, 1) << @intCast(valid_bits_per_sample - 1));
    return (@as(f32, @floatFromInt(sample)) - midpoint) / midpoint;
}

fn decodeSamples(format: Format, data: []const u8, output: []f32) DecodeError!void {
    const bits = try format.precision();
    // Full-width vector paths handle common formats; the scalar path also handles reduced precision
    // and either wire byte order without requiring aligned input.
    if (format.encoding == .unsigned8 and bits == 8) {
        decodePcm8Samples(data, output);
        return;
    }
    if (format.encoding == .signed8 and bits == 8) {
        decodeSignedPcm8Samples(data, output);
        return;
    }
    if (format.encoding == .signed16 and bits == 16 and format.endian == .little) {
        decodePcm16Samples(data, output);
        return;
    }
    if (format.encoding == .signed24 and bits == 24 and format.endian == .little) {
        decodePcm24Samples(data, output);
        return;
    }
    if (format.encoding == .signed32 and bits == 32 and format.endian == .little) {
        decodePcm32Samples(data, output);
        return;
    }
    if (format.encoding == .float64) {
        return switch (format.endian) {
            .little => decodeFloat64Samples(data, output, .little),
            .big => decodeFloat64Samples(data, output, .big),
        };
    }

    return switch (format.endian) {
        .little => decodeScalarSamples(data, output, format.encoding, bits, .little),
        .big => decodeScalarSamples(data, output, format.encoding, bits, .big),
    };
}

fn decodeScalarSamples(
    data: []const u8,
    output: []f32,
    encoding: Encoding,
    bits: u16,
    comptime endian: std.lang.Endian,
) DecodeError!void {
    switch (encoding) {
        .unsigned8 => for (output, 0..) |*sample, index| {
            sample.* = decodeUnsignedPcm(data[index], bits);
        },
        .unsigned16 => for (output, 0..) |*sample, index| {
            sample.* = decodeWideUnsignedPcm(
                std.mem.readInt(u16, data[index * 2 ..][0..2], endian),
                16,
                bits,
            );
        },
        .unsigned24 => for (output, 0..) |*sample, index| {
            sample.* = decodeWideUnsignedPcm(
                std.mem.readInt(u24, data[index * 3 ..][0..3], endian),
                24,
                bits,
            );
        },
        .unsigned32 => for (output, 0..) |*sample, index| {
            sample.* = decodeWideUnsignedPcm(
                std.mem.readInt(u32, data[index * 4 ..][0..4], endian),
                32,
                bits,
            );
        },
        .signed8 => for (output, 0..) |*sample, index| {
            sample.* = decodeSignedPcm(@as(i8, @bitCast(data[index])), 8, bits);
        },
        .signed16 => for (output, 0..) |*sample, index| {
            sample.* = decodeSignedPcm(
                std.mem.readInt(i16, data[index * 2 ..][0..2], endian),
                16,
                bits,
            );
        },
        .signed24 => for (output, 0..) |*sample, index| {
            sample.* = decodePcm24(data[index * 3 ..][0..3].*, bits, endian);
        },
        .signed32 => for (output, 0..) |*sample, index| {
            sample.* = decodeSignedPcm(
                std.mem.readInt(i32, data[index * 4 ..][0..4], endian),
                32,
                bits,
            );
        },
        .float32 => for (output, 0..) |*sample, index| {
            sample.* = @bitCast(std.mem.readInt(u32, data[index * 4 ..][0..4], endian));
            if (!std.math.isFinite(sample.*)) return error.InvalidSamples;
        },
        .float64 => unreachable,
    }
}

fn decodeWideUnsignedPcm(raw: u32, container_bits: u16, bits: u16) f32 {
    const midpoint: i64 = @as(i64, 1) << @intCast(bits - 1);
    const centered = @as(i64, raw >> @intCast(container_bits - bits)) - midpoint;
    return @as(f32, @floatFromInt(centered)) / @as(f32, @floatFromInt(midpoint));
}

fn decodeFloat64Samples(
    data: []const u8,
    output: []f32,
    comptime endian: std.lang.Endian,
) error{InvalidSamples}!void {
    for (output, 0..) |*sample, index| {
        const wide = std.mem.readInt(u64, data[index * 8 ..][0..8], endian);
        const narrowed = rounding.toF32Bits(wide) orelse return error.InvalidSamples;
        sample.* = @bitCast(narrowed);
    }
}

fn decodePcm8Samples(data: []const u8, output: []f32) void {
    var sample_index: usize = 0;
    while (sample_index + pcm_vector_lanes <= output.len) : (sample_index += pcm_vector_lanes) {
        const bytes: Pcm8Bytes = data[sample_index..][0..pcm_vector_lanes].*;
        const wide: Pcm8Wide = @intCast(bytes);
        const centered = wide - @as(Pcm8Wide, @splat(128));
        const values: Pcm8Floats = @floatFromInt(centered);
        output[sample_index..][0..pcm_vector_lanes].* = values / @as(Pcm8Floats, @splat(128));
    }
    while (sample_index < output.len) : (sample_index += 1) {
        output[sample_index] = decodeUnsignedPcm(data[sample_index], 8);
    }
}

fn decodeSignedPcm8Samples(data: []const u8, output: []f32) void {
    const Signed = @Vector(pcm_vector_lanes, i8);
    var index: usize = 0;
    while (index + pcm_vector_lanes <= output.len) : (index += pcm_vector_lanes) {
        const bytes: Pcm8Bytes = data[index..][0..pcm_vector_lanes].*;
        const signed: Signed = @bitCast(bytes);
        const wide: Pcm8Wide = @intCast(signed);
        const values: Pcm8Floats = @floatFromInt(wide);
        output[index..][0..pcm_vector_lanes].* = values / @as(Pcm8Floats, @splat(128));
    }
    while (index < output.len) : (index += 1) {
        output[index] = decodeSignedPcm(@as(i8, @bitCast(data[index])), 8, 8);
    }
}

fn decodePcm16Samples(data: []const u8, output: []f32) void {
    var sample_index: usize = 0;
    var source_offset: usize = 0;
    while (sample_index + pcm_vector_lanes <= output.len) : (sample_index += pcm_vector_lanes) {
        const bytes: Pcm16Bytes = data[source_offset..][0 .. pcm_vector_lanes * 2].*;
        const low: @Vector(
            pcm_vector_lanes,
            u8,
        ) = @shuffle(u8, bytes, undefined, pcm16_low_indices);
        const high: @Vector(
            pcm_vector_lanes,
            u8,
        ) = @shuffle(u8, bytes, undefined, pcm16_high_indices);
        const low_wide: @Vector(pcm_vector_lanes, u16) = @intCast(low);
        const high_wide: @Vector(pcm_vector_lanes, u16) = @intCast(high);
        const encoded: @Vector(
            pcm_vector_lanes,
            u16,
        ) = low_wide | (high_wide << @as(@Vector(pcm_vector_lanes, u16), @splat(8)));
        const samples: Pcm16Samples = @bitCast(encoded);
        const wide: Pcm16Wide = @intCast(samples);
        const values: Pcm16Floats = @floatFromInt(wide);
        output[sample_index..][0..pcm_vector_lanes].* = values / @as(Pcm16Floats, @splat(32_768));
        source_offset += pcm_vector_lanes * 2;
    }
    while (sample_index < output.len) : (sample_index += 1) {
        const raw = std.mem.readInt(i16, data[source_offset..][0..2], .little);
        output[sample_index] = @as(f32, @floatFromInt(raw)) / 32_768;
        source_offset += @sizeOf(i16);
    }
}

fn decodePcm24Samples(data: []const u8, output: []f32) void {
    const Bytes = @Vector(pcm_vector_lanes * 3, u8);
    const ByteLanes = @Vector(pcm_vector_lanes, u8);
    const Words = @Vector(pcm_vector_lanes, u32);
    const Samples = @Vector(pcm_vector_lanes, i32);
    const Floats = @Vector(pcm_vector_lanes, f32);
    var sample_index: usize = 0;
    var source_offset: usize = 0;
    while (sample_index + pcm_vector_lanes <= output.len) : (sample_index += pcm_vector_lanes) {
        const bytes: Bytes = data[source_offset..][0 .. pcm_vector_lanes * 3].*;
        const low: ByteLanes = @shuffle(u8, bytes, undefined, pcm24_byte_indices[0]);
        const middle: ByteLanes = @shuffle(u8, bytes, undefined, pcm24_byte_indices[1]);
        const high: ByteLanes = @shuffle(u8, bytes, undefined, pcm24_byte_indices[2]);
        const low_words: Words = @intCast(low);
        const middle_words: Words = @intCast(middle);
        const high_words: Words = @intCast(high);
        // Left alignment preserves the sign without an extra sign-extension shift. Every aligned
        // PCM24 integer is still exact in f32; dividing by 2^31 gives the same sample.
        const samples: Samples = @bitCast(
            (low_words << @splat(8)) | (middle_words << @splat(16)) | (high_words << @splat(24)),
        );
        const values: Floats = @floatFromInt(samples);
        output[sample_index..][0..pcm_vector_lanes].* = values / @as(Floats, @splat(2_147_483_648));
        source_offset += pcm_vector_lanes * 3;
    }
    while (sample_index < output.len) : (sample_index += 1) {
        output[sample_index] = decodePcm24(data[source_offset..][0..3].*, 24, .little);
        source_offset += 3;
    }
}

fn decodePcm32Samples(data: []const u8, output: []f32) void {
    const Samples = @Vector(pcm_vector_lanes, i32);
    const Floats = @Vector(pcm_vector_lanes, f32);
    var sample_index: usize = 0;
    var source_offset: usize = 0;
    while (sample_index + pcm_vector_lanes <= output.len) : (sample_index += pcm_vector_lanes) {
        var words: [pcm_vector_lanes]i32 = undefined;
        inline for (0..pcm_vector_lanes) |lane| {
            words[lane] = std.mem.readInt(i32, data[source_offset + lane * 4 ..][0..4], .little);
        }
        const samples: Samples = words;
        // Native conversion avoids fixed-rounding work; wide results can follow the executing
        // thread's floating-point environment.
        const values: Floats = @floatFromInt(samples);
        output[sample_index..][0..pcm_vector_lanes].* = values / @as(Floats, @splat(2_147_483_648));
        source_offset += pcm_vector_lanes * 4;
    }
    while (sample_index < output.len) : (sample_index += 1) {
        const raw = std.mem.readInt(i32, data[source_offset..][0..4], .little);
        output[sample_index] = @as(f32, @floatFromInt(raw)) / 2_147_483_648;
        source_offset += 4;
    }
}

fn decodePcm24(bytes: [3]u8, valid_bits_per_sample: u16, comptime endian: std.lang.Endian) f32 {
    const signed = std.mem.readInt(i24, &bytes, endian);
    return decodeSignedPcm(signed, 24, valid_bits_per_sample);
}

fn decodeSignedPcm(raw: i32, container_bits: u16, valid_bits_per_sample: u16) f32 {
    const shift = container_bits - valid_bits_per_sample;
    const sample = raw >> @intCast(shift);
    const scale: f32 = @floatFromInt(@as(u64, 1) << @intCast(valid_bits_per_sample - 1));
    return @as(f32, @floatFromInt(sample)) / scale;
}

test "full-width PCM24 and PCM32 preserve rounding at vector boundaries and unaligned tails" {
    // Odd offsets exercise unaligned reads; the output sentinel detects writes past the prefix.
    const maximum_samples = pcm_vector_lanes * 2 + 3;
    const patterns = [_]u32{
        0,           1,           0x7fff_ffff, 0x8000_0000, 0xffff_ffff, 0x7fff_ff80, 0x8000_0001,
        0x7fff_ffc0, 0x007f_ffff, 0x0080_0000, 0x00ff_ffff,
    };
    var source: [maximum_samples * 4 + 8]u8 = undefined;
    var output: [maximum_samples + 1]f32 = undefined;
    var expected: [maximum_samples]f32 = undefined;
    for ([_]Encoding{ .signed24, .signed32 }) |encoding| {
        const width = encoding.byteCount();
        const bits = width * 8;
        const modulus: i64 = @as(i64, 1) << @intCast(bits);
        const midpoint = @divExact(modulus, 2);
        const mask: u32 = @truncate(@as(u64, @intCast(modulus - 1)));
        for (0..8) |offset| {
            for (0..maximum_samples + 1) |count| {
                @memset(&source, 0x5a);
                for (0..count) |sample| {
                    const raw = patterns[sample % patterns.len] & mask;
                    var bytes: [4]u8 = undefined;
                    std.mem.writeInt(u32, &bytes, raw, .little);
                    @memcpy(source[offset + sample * width ..][0..width], bytes[0..width]);
                    const integer: i64 = if (raw >= midpoint) @as(i64, raw) - modulus else raw;
                    // The integer and power-of-two scale are exact in f64 before f32 conversion.
                    expected[sample] = @floatCast(
                        @as(f64, @floatFromInt(integer)) / @as(f64, @floatFromInt(midpoint)),
                    );
                }
                for ([_]?u7{ null, @intCast(bits) }) |valid_bits| {
                    @memset(&output, 42);
                    const result = try decodeInto(
                        source[offset..][0 .. count * width],
                        &output,
                        .{ .encoding = encoding, .valid_bits = valid_bits },
                    );
                    try testing.expectEqual(count, result.len);
                    for (result, expected[0..count]) |actual, reference| {
                        try testing.expectEqual(
                            @as(u32, @bitCast(reference)),
                            @as(u32, @bitCast(actual)),
                        );
                    }
                    try testing.expect(std.mem.allEqual(f32, output[count..], 42));
                }
            }
        }
    }
}

test "integer precision ignores low padding and normalizes both signed endpoints" {
    // Valid precision changes the scale while discarded low container bits cannot affect samples.
    for ([_]Encoding{ .unsigned8, .signed16, .signed24, .signed32 }) |encoding| {
        const width = encoding.byteCount();
        const bits = width * 8;
        var encoded: [36]u8 = undefined;
        var output: [9]f32 = undefined;
        for (1..bits + 1) |precision| {
            const midpoint: i64 = @as(i64, 1) << @intCast(precision - 1);
            for ([_]i64{ -midpoint, -midpoint + 1, -1, 0, midpoint - 1 }, 0..) |signed, sample| {
                const raw: u32 = if (encoding == .unsigned8) @intCast(
                    (signed + midpoint) << @intCast(bits - precision),
                ) else @truncate(@as(u64, @bitCast(signed << @intCast(bits - precision))));
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, raw, .little);
                @memcpy(encoded[sample * width ..][0..width], bytes[0..width]);
            }
            const result = try decodeInto(
                encoded[0 .. 5 * width],
                &output,
                .{ .encoding = encoding, .valid_bits = @intCast(precision) },
            );
            const expected = [_]i64{ -midpoint, -midpoint + 1, -1, 0, midpoint - 1 };
            for (result, expected) |actual, integer| {
                const reference: f32 = @floatCast(
                    @as(f64, @floatFromInt(integer)) / @as(f64, @floatFromInt(midpoint)),
                );
                try testing.expectEqual(@as(u32, @bitCast(reference)), @as(u32, @bitCast(actual)));
            }
        }
    }
}

fn verifyInteger() !void {
    const count = 35;
    for ([_]Encoding{
        .unsigned8, .unsigned16, .unsigned24, .unsigned32, .signed8, .signed16, .signed24,
        .signed32,
    }) |encoding| {
        const width = encoding.byteCount();
        for (1..width * 8 + 1) |bits| {
            const midpoint: i64 = @as(i64, 1) << @intCast(bits - 1);
            // 2^-bits is half a quantization step. Adjacent encodings exercise both sides of each
            // signed tie, along with endpoints, signed subnormals and signed zeros. A one-bit
            // signed format clamps the positive endpoint to zero.
            const half32: u32 = @as(u32, @intCast(127 - bits)) << 23;
            const half64: u64 = @as(u64, @intCast(1023 - bits)) << 52;

            const pattern32 = [_]u32{
                half32 - 1,
                half32,
                half32 + 1,
                (1 << 31) | (half32 - 1),
                (1 << 31) | half32,
                (1 << 31) | (half32 + 1),
                0x3f80_0000,
                0xbf80_0000,
                1,
                0x8000_0001,
                0,
                0x8000_0000,
            };
            const pattern64 = [_]u64{
                half64 - 1,
                half64,
                half64 + 1,
                (1 << 63) | (half64 - 1),
                (1 << 63) | half64,
                (1 << 63) | (half64 + 1),
                0x3ff0_0000_0000_0000,
                0xbff0_0000_0000_0000,
                1,
                0x8000_0000_0000_0001,
                0,
                0x8000_0000_0000_0000,
            };
            const signed_values = [_]i64{
                0,
                @min(1, midpoint - 1),
                @min(1, midpoint - 1),
                0,
                -1,
                -1,
                midpoint - 1,
                -midpoint,
                0,
                0,
                0,
                0,
            };
            var root: [count]f32 = undefined;
            var wide: [count]f64 = undefined;
            for (&root, &wide, 0..) |*a, *b, i| {
                a.* = @bitCast(pattern32[i % pattern32.len]);
                b.* = @bitCast(pattern64[i % pattern64.len]);
            }
            const saved_root = root;
            const saved_wide = wide;

            for ([_]std.lang.Endian{ .little, .big }) |endian| {
                const format: Format = .{
                    .encoding = encoding,
                    .valid_bits = @intCast(bits),
                    .endian = endian,
                };
                var expected: [count * 4]u8 = @splat(0);
                for (0..count) |i| {
                    const sample = signed_values[i % signed_values.len];
                    const biased = switch (encoding) {
                        .unsigned8, .unsigned16, .unsigned24, .unsigned32 => sample + midpoint,
                        else => sample,
                    };
                    const value: u32 = @intCast(
                        (@as(
                            u64,
                            @bitCast(biased),
                        ) & ((@as(u64, 1) << @intCast(bits)) - 1)) << @intCast(width * 8 - bits),
                    );
                    switch (width) {
                        1 => expected[i] = @intCast(value),
                        2 => std.mem.writeInt(
                            u16,
                            expected[i * 2 ..][0..2],
                            @intCast(value),
                            endian,
                        ),
                        3 => std.mem.writeInt(
                            u24,
                            expected[i * 3 ..][0..3],
                            @intCast(value),
                            endian,
                        ),
                        4 => std.mem.writeInt(u32, expected[i * 4 ..][0..4], value, endian),
                        else => unreachable,
                    }
                }

                for ([_]usize{ 0, 1, 3, 7, 16, 31, count }) |n| {
                    for ([_]bool{ false, true }) |use_wide| {
                        var out: [count * 4 + 2]u8 = @splat(0xa5);
                        const output = if (use_wide) try float64.encodeInto(
                            wide[0..n],
                            out[1..],
                            .{ .format = format },
                        ) else try encodeInto(root[0..n], out[1..], format);
                        try testing.expectEqualSlices(u8, expected[0 .. n * width], output);
                        try testing.expectEqual(@as(u8, 0xa5), out[0]);
                        try testing.expect(std.mem.allEqual(u8, out[1 + output.len ..], 0xa5));

                        @memset(&out, 0xa5);
                        var writer: std.Io.Writer = .fixed(out[1 .. 1 + n * width]);
                        if (use_wide) try float64.writeAll(
                            wide[0..n],
                            &writer,
                            .{ .format = format },
                        ) else try writeAll(root[0..n], &writer, format);
                        try testing.expectEqualSlices(
                            u8,
                            expected[0 .. n * width],
                            writer.buffered(),
                        );
                        try testing.expectEqual(@as(u8, 0xa5), out[0]);
                        try testing.expect(std.mem.allEqual(u8, out[1 + n * width ..], 0xa5));
                    }
                }
            }
            try testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(&saved_root),
                std.mem.sliceAsBytes(&root),
            );
            try testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(&saved_wide),
                std.mem.sliceAsBytes(&wide),
            );
        }
    }
}

test "integer PCM half neighbors across every valid precision" {
    try verifyInteger();
}

test "integer PCM half neighbors ignore all x86-64 rounding modes" {
    const Control = @import("common/float.zig").test_support.FloatControl;
    const original = try Control.read();
    defer Control.set(original);
    for (0..4) |mode| {
        Control.set((original & ~@as(u32, 3 << 13)) | (@as(u32, @intCast(mode)) << 13));
        try verifyInteger();
    }
}

fn verifyNarrow() !void {
    // Signed midpoint ties, values just below overflow, and the signed underflow midpoint have
    // fixed f32 results. The extra overflow midpoint must fail before writing its output slot;
    // decoding retains its valid prefix, while encoding validates the whole input before writing.
    const bits = [_]u64{
        0x3ff0_0000_1000_0000, 0xbff0_0000_1000_0000, 0x47ef_ffff_efff_ffff, 0xc7ef_ffff_efff_ffff,
        0x3690_0000_0000_0000, 0xb690_0000_0000_0000,
    };
    const words = [_]u32{ 0x3f80_0000, 0xbf80_0000, 0x7f7f_ffff, 0xff7f_ffff, 0, 0x8000_0000 };
    var values: [bits.len + 1]f64 = undefined;
    for (bits, 0..) |word, i| values[i] = @bitCast(word);
    values[bits.len] = @bitCast(@as(u64, 0x47ef_ffff_f000_0000));
    std.mem.doNotOptimizeAway(&values);
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        var wire: [values.len * 8]u8 = undefined;
        for (
            values,
            0..,
        ) |value, i| std.mem.writeInt(u64, wire[i * 8 ..][0..8], @bitCast(value), endian);
        var dest: [values.len]f32 = @splat(42);
        try testing.expectError(
            error.InvalidSamples,
            decodeInto(&wire, &dest, .{ .encoding = .float64, .endian = endian }),
        );
        for (words, 0..) |word, i| try testing.expectEqual(word, @as(u32, @bitCast(dest[i])));
        try testing.expectEqual(@as(f32, 42), dest[bits.len]);

        var expected: [bits.len * 4]u8 = undefined;
        for (words, 0..) |word, i| std.mem.writeInt(u32, expected[i * 4 ..][0..4], word, endian);
        const options: float64.EncodeOptions = .{
            .format = .{ .encoding = .float32, .endian = endian },
        };
        var output: [values.len * 4]u8 = @splat(0xa5);
        const result = try float64.encodeInto(values[0..bits.len], &output, options);
        try testing.expectEqualSlices(u8, &expected, result);

        @memset(&output, 0xa5);
        var writer: std.Io.Writer = .fixed(&output);
        try float64.writeAll(values[0..bits.len], &writer, options);
        try testing.expectEqualSlices(u8, &expected, writer.buffered());

        @memset(&output, 0xa5);
        try testing.expectError(
            error.InvalidSamples,
            float64.encodeInto(&values, &output, options),
        );
        try testing.expect(std.mem.allEqual(u8, &output, 0xa5));
        writer = .fixed(&output);
        try writer.writeByte(0x42);
        try testing.expectError(error.InvalidSamples, float64.writeAll(&values, &writer, options));
        try testing.expectEqualSlices(u8, &.{0x42}, writer.buffered());
        try testing.expect(std.mem.allEqual(u8, output[1..], 0xa5));
    }
}

test "binary32 narrowing preserves output and errors in every x86-64 rounding mode" {
    // Changing caller rounding mode must not change nearest-even narrowing or failure placement.
    const Control = @import("common/float.zig").test_support.FloatControl;
    const original = try Control.read();
    defer Control.set(original);
    for (0..4) |mode| {
        Control.set((original & ~@as(u32, 3 << 13)) | (@as(u32, @intCast(mode)) << 13));
        try verifyNarrow();
    }
}

fn putUnsignedTestWord(bytes: []u8, width: usize, value: u32, endian: std.lang.Endian) void {
    switch (width) {
        2 => std.mem.writeInt(u16, bytes[0..2], @intCast(value), endian),
        3 => std.mem.writeInt(u24, bytes[0..3], @intCast(value), endian),
        4 => std.mem.writeInt(u32, bytes[0..4], value, endian),
        else => unreachable,
    }
}

test "unsigned wide endpoints, dirty padding and exact integer round trip" {
    const cases = [_]struct {
        encoding: Encoding,
        width: usize,
        bits: u7,
        dirty: [3]u32,
        clean: [3]u32,
        maximum: i32,
    }{ .{ .encoding = .unsigned16, .width = 2, .bits = 12, .dirty = .{
        0x000f, 0x800f,
        0xffff,
    }, .clean = .{
        0, 0x8000, 0xfff0,
    }, .maximum = 0x7ff0_0000 }, .{ .encoding = .unsigned24, .width = 3, .bits = 20, .dirty = .{
        0x00000f, 0x80000f,
        0xffffff,
    }, .clean = .{
        0, 0x800000, 0xfffff0,
    }, .maximum = 0x7ffff000 }, .{ .encoding = .unsigned32, .width = 4, .bits = 28, .dirty = .{
        0x0000000f, 0x8000000f,
        0xffffffff,
    }, .clean = .{
        0, 0x80000000, 0xfffffff0,
    }, .maximum = 0x7ffffff0 } };
    for (cases) |case| for ([_]std.lang.Endian{ .little, .big }) |endian| {
        const format: Format = .{
            .encoding = case.encoding,
            .valid_bits = case.bits,
            .endian = endian,
        };
        var dirty: [12]u8 = @splat(0);
        var clean: [12]u8 = @splat(0);
        for (case.dirty, case.clean, 0..) |a, b, i| {
            putUnsignedTestWord(dirty[i * case.width ..], case.width, a, endian);
            putUnsignedTestWord(clean[i * case.width ..], case.width, b, endian);
        }
        const length = 3 * case.width;
        const integers = [_]i32{ std.math.minInt(i32), 0, case.maximum };
        var i32_out: [3]i32 = undefined;
        try testing.expectEqualSlices(
            i32,
            &integers,
            try int32.decodeInto(dirty[0..length], &i32_out, format),
        );
        var bytes: [12]u8 = @splat(0xa5);
        try testing.expectEqualSlices(
            u8,
            clean[0..length],
            try int32.encodeInto(&integers, &bytes, .{ .format = format }),
        );
        var writer: std.Io.Writer = .fixed(&bytes);
        try int32.writeAll(&integers, &writer, .{ .format = format });
        try testing.expectEqualSlices(u8, clean[0..length], writer.buffered());
        try testing.expectError(
            error.PrecisionLoss,
            int32.encodeInto(&.{1}, &bytes, .{ .format = format }),
        );
        const midpoint: f64 = @floatFromInt(@as(u32, 1) << @intCast(case.bits - 1));
        const values = [_]f64{ -1, 0, (midpoint - 1) / midpoint };
        var f64_out: [3]f64 = undefined;
        try testing.expectEqualSlices(
            f64,
            &values,
            try float64.decodeInto(dirty[0..length], &f64_out, format),
        );
        try testing.expectEqualSlices(
            u8,
            clean[0..length],
            try float64.encodeInto(&values, &bytes, .{ .format = format }),
        );
        writer = .fixed(&bytes);
        try float64.writeAll(&values, &writer, .{ .format = format });
        try testing.expectEqualSlices(u8, clean[0..length], writer.buffered());
        var f32_out: [3]f32 = undefined;
        const expected_f32 = [_]f32{ -1, 0, @floatCast(values[2]) };
        try testing.expectEqualSlices(
            f32,
            &expected_f32,
            try decodeInto(dirty[0..length], &f32_out, format),
        );
        try testing.expectEqualSlices(
            u8,
            clean[0..length],
            try encodeInto(&expected_f32, &bytes, format),
        );
        writer = .fixed(&bytes);
        try writeAll(&expected_f32, &writer, format);
        try testing.expectEqualSlices(u8, clean[0..length], writer.buffered());
    };
}

test "unsigned32 binary32 rounding and exact integer precision" {
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        const format: Format = .{ .encoding = .unsigned32, .endian = endian };
        var bytes: [12]u8 = undefined;
        for ([_]u32{ 0x8100_0000, 0x8100_0001, 0x8100_0003 }, 0..) |word, i| {
            std.mem.writeInt(u32, bytes[i * 4 ..][0..4], word, endian);
        }
        var wide: [3]f64 = undefined;
        try testing.expectEqualSlices(f64, &.{
            0x1p-7, 0x1.000001p-7, 0x1.000003p-7,
        }, try float64.decodeInto(&bytes, &wide, format));
        var narrow: [3]f32 = undefined;
        _ = try decodeInto(&bytes, &narrow, format);
        try testing.expectEqual(@as(u32, 0x3c00_0000), @as(u32, @bitCast(narrow[0])));
        try testing.expectEqual(@as(u32, 0x3c00_0000), @as(u32, @bitCast(narrow[1])));
        try testing.expectEqual(@as(u32, 0x3c00_0002), @as(u32, @bitCast(narrow[2])));
        var exact: [3]i32 = undefined;
        try testing.expectEqualSlices(i32, &.{
            0x0100_0000, 0x0100_0001,
            0x0100_0003,
        }, try int32.decodeInto(&bytes, &exact, format));
    }
}

fn checkExactFloat32Widening() !void {
    // Literal wire bits cover both zero signs, subnormal boundaries, minimum normals and +/-1;
    // independent f64 encodings catch hardware flushing without using the conversion under test.
    const words = [_]u32{
        0,           0x8000_0000, 1,           0x8000_0001, 0x007f_ffff, 0x807f_ffff, 0x0080_0000,
        0x8080_0000, 0x3f80_0000, 0xbf80_0000,
    };
    const expected = [_]u64{
        0,                     0x8000_0000_0000_0000, 0x36a0_0000_0000_0000, 0xb6a0_0000_0000_0000,
        0x380f_ffff_c000_0000, 0xb80f_ffff_c000_0000, 0x3810_0000_0000_0000, 0xb810_0000_0000_0000,
        0x3ff0_0000_0000_0000, 0xbff0_0000_0000_0000,
    };
    const count = 33;
    var samples: [count]f32 = undefined;
    for (&samples, 0..) |*sample, i| sample.* = @bitCast(words[i % words.len]);
    std.mem.doNotOptimizeAway(&samples);
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        var wire: [count * 4]u8 = undefined;
        var expected_wire: [count * 8]u8 = undefined;
        for (0..count) |i| {
            std.mem.writeInt(u32, wire[i * 4 ..][0..4], words[i % words.len], endian);
            std.mem.writeInt(u64, expected_wire[i * 8 ..][0..8], expected[i % words.len], endian);
        }
        // Lengths and bad positions straddle typical vector boundaries and odd tails. The offset
        // and sentinels check unaligned output and preserve the failing slot and suffix.
        for ([_]usize{ 1, 3, 7, 8, 9, 16, 17, count }) |n| {
            var encoded: [count * 8 + 2]u8 = @splat(0xa5);
            const format: Format = .{ .encoding = .float64, .endian = endian };
            const result = try encodeInto(samples[0..n], encoded[1..], format);
            try testing.expectEqualSlices(u8, expected_wire[0 .. n * 8], result);
            try testing.expectEqual(@as(u8, 0xa5), encoded[0]);
            try testing.expect(std.mem.allEqual(u8, encoded[1 + n * 8 ..], 0xa5));

            @memset(&encoded, 0xa5);
            var writer: std.Io.Writer = .fixed(encoded[1 .. 1 + n * 8]);
            try writeAll(samples[0..n], &writer, format);
            try testing.expectEqualSlices(u8, expected_wire[0 .. n * 8], writer.buffered());
            try testing.expectEqual(@as(u8, 0xa5), encoded[0]);
            try testing.expect(std.mem.allEqual(u8, encoded[1 + n * 8 ..], 0xa5));

            var decoded: [count]f64 = @splat(42);
            const values = try float64.decodeInto(
                wire[0 .. n * 4],
                &decoded,
                .{ .encoding = .float32, .endian = endian },
            );
            for (values, 0..) |value, i| {
                try testing.expectEqual(expected[i % expected.len], @as(u64, @bitCast(value)));
            }
            try testing.expect(std.mem.allEqual(f64, decoded[n..], 42));
        }

        for ([_]usize{ 0, 1, 7, 8, 15, 16, 32 }) |bad| {
            var invalid = wire;
            std.mem.writeInt(u32, invalid[bad * 4 ..][0..4], 0x7f80_0000, endian);
            var decoded: [count]f64 = @splat(42);
            try testing.expectError(
                error.InvalidSamples,
                float64.decodeInto(&invalid, &decoded, .{ .encoding = .float32, .endian = endian }),
            );
            for (decoded[0..bad], 0..) |value, i| {
                try testing.expectEqual(expected[i % expected.len], @as(u64, @bitCast(value)));
            }
            try testing.expect(std.mem.allEqual(f64, decoded[bad..], 42));
        }
    }
}

test "binary32 widening preserves encoded values and failure prefixes in caller float modes" {
    // DAZ and FTZ can flush subnormal inputs in hardware, so exercise both independently.
    try checkExactFloat32Widening();
    const Control = @import("common/float.zig").test_support.FloatControl;
    const original = Control.read() catch return;
    defer Control.set(original);
    const flush_mask: u32 = (1 << 6) | (1 << 15);
    const round_mask: u32 = 3 << 13;
    for (0..4) |rounding_mode| {
        for ([_]u32{ 0, 1 << 6, 1 << 15, flush_mask }) |flush| {
            const control = (original & ~(flush_mask | round_mask)) | (@as(
                u32,
                @intCast(rounding_mode),
            ) << 13) | flush;
            Control.set(control);
            try checkExactFloat32Widening();
        }
    }
}
