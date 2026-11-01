//! PCM conversion using f64 samples. Integer and finite binary32 input is represented exactly.
//! Finite binary64 wire samples retain every bit, including the sign of zero. Encoding to integer
//! PCM rounds halfway away from zero and clamps at the positive endpoint; binary32 output rounds to
//! nearest with ties to even. Float output accepts finite values outside [-1, 1], but narrowing
//! that would produce infinity is rejected. Operations allocate nothing and retain no storage.

const std = @import("std");
const builtin = @import("builtin");
const pcm = @import("../pcm.zig");
const rounding = @import("round.zig");
const sample_rounding = @import("../common/round.zig");
const float = @import("../common/float.zig");
const memory = @import("../common/byte_ranges.zig");
const testing = std.testing;
const Format = pcm.Format;

/// Invalid representation or extent, insufficient or overlapping output, or invalid float input.
pub const DecodeError = pcm.DecodeError;

/// Invalid representation, unrepresentable extent, or invalid or unrepresentable samples.
pub const ValidateError = pcm.ValidateError;

/// Encoding also rejects insufficient or aliased output.
pub const EncodeError = pcm.EncodeError;

/// The wire representation used for encoding.
pub const EncodeOptions = struct { format: Format };

/// Decodes into a borrowed f64 prefix. Integer and finite float32 inputs are exact. Float64 wire
/// values retain their bits, including signed zero. Format, extent, capacity and used-output
/// overlap failures precede writes. A nonfinite wire sample leaves the failing slot unchanged;
/// preceding samples may have been written.
pub fn decodeInto(source: []const u8, destination: []f64, format: Format) DecodeError![]f64 {
    const bits = try precision(format);
    const width = format.encoding.byteCount();
    if (source.len % width != 0) return error.InvalidData;
    const count = source.len / width;
    if (destination.len < count) return error.DestinationTooSmall;

    const output = destination[0..count];
    if (memory.overlaps(source, std.mem.sliceAsBytes(output))) return error.Aliasing;

    if (format.encoding == .signed32 and bits == 32) {
        switch (format.endian) {
            .little => decodeSigned32(source, output, .little),
            .big => decodeSigned32(source, output, .big),
        }
        return output;
    }
    if (format.encoding == .float32) {
        switch (format.endian) {
            .little => try decodeFloat32(source, output, .little),
            .big => try decodeFloat32(source, output, .big),
        }
        return output;
    }

    for (output, 0..) |*sample, index| {
        const bytes = source[index * width ..][0..width];
        switch (format.encoding) {
            .float64 => {
                const value: f64 = @bitCast(std.mem.readInt(u64, bytes[0..8], format.endian));
                if (!std.math.isFinite(value)) return error.InvalidSamples;
                sample.* = value;
            },
            .float32 => unreachable,
            else => {
                const raw: u32 = switch (width) {
                    1 => bytes[0],
                    2 => std.mem.readInt(u16, bytes[0..2], format.endian),
                    3 => std.mem.readInt(u24, bytes[0..3], format.endian),
                    4 => std.mem.readInt(u32, bytes[0..4], format.endian),
                    else => unreachable,
                };
                const alignment: u5 = @intCast(32 - width * 8);
                const padding: u5 = @intCast(32 - bits);
                var word = raw << alignment;
                switch (format.encoding) {
                    .unsigned8, .unsigned16, .unsigned24, .unsigned32 => word ^= 0x8000_0000,
                    else => {},
                }
                word &= @as(u32, std.math.maxInt(u32)) << padding;
                const signed: i32 = @bitCast(word);
                sample.* = @as(f64, @floatFromInt(signed)) / 2_147_483_648.0;
            },
        }
    }
    return output;
}

test decodeInto {
    const bytes = [_]u8{ 0x80, 0, 0, 0x7f, 0xff, 0xff };
    var samples: [2]f64 = undefined;
    const output = try decodeInto(&bytes, &samples, .{ .encoding = .signed24, .endian = .big });
    try testing.expectEqualSlices(f64, &.{ -1, 8_388_607.0 / 8_388_608.0 }, output);
}

fn decodeSigned32(source: []const u8, output: []f64, comptime endian: std.lang.Endian) void {
    const lanes = std.simd.suggestVectorLength(f64) orelse 1;
    const Values = @Vector(lanes, i32);
    const Floats = @Vector(lanes, f64);
    var index: usize = 0;
    while (index + lanes <= output.len) : (index += lanes) {
        var words: [lanes]i32 = undefined;
        inline for (0..lanes) |lane| {
            words[lane] = std.mem.readInt(i32, source[(index + lane) * 4 ..][0..4], endian);
        }
        const values: Values = words;
        const converted: Floats = @floatFromInt(values);
        output[index..][0..lanes].* = converted / @as(Floats, @splat(2_147_483_648.0));
    }
    while (index < output.len) : (index += 1) {
        const word = std.mem.readInt(i32, source[index * 4 ..][0..4], endian);
        output[index] = @as(f64, @floatFromInt(word)) / 2_147_483_648.0;
    }
}

fn decodeFloat32(
    source: []const u8,
    output: []f64,
    comptime endian: std.lang.Endian,
) error{InvalidSamples}!void {
    const lanes = std.simd.suggestVectorLength(f64) orelse 1;
    const Words = @Vector(lanes, u32);
    const Narrow = @Vector(lanes, f32);
    const Wide = @Vector(lanes, f64);
    const zero: Words = @splat(0);
    const min_normal: Words = @splat(0x0080_0000);
    var index: usize = 0;
    while (index + lanes <= output.len) : (index += lanes) {
        var array: [lanes]u32 = undefined;
        inline for (0..lanes) |lane| {
            array[lane] = std.mem.readInt(u32, source[(index + lane) * 4 ..][0..4], endian);
        }
        const words: Words = array;
        const magnitude = words & @as(Words, @splat(0x7fff_ffff));
        const subnormal = (magnitude != zero) & (magnitude < min_normal);
        const nonfinite = magnitude >= @as(Words, @splat(0x7f80_0000));

        if (@reduce(.Or, subnormal | nonfinite)) {
            // Widen subnormals without hardware flushing and preserve the failing-slot order.
            for (array, 0..) |word, lane| {
                const value: f32 = @bitCast(word);
                if (!std.math.isFinite(value)) return error.InvalidSamples;
                output[index + lane] = float.widen32(value);
            }
        } else {
            const values: Narrow = @bitCast(words);
            const widened: Wide = @floatCast(values);
            output[index..][0..lanes].* = widened;
        }
    }
    while (index < output.len) : (index += 1) {
        const value: f32 = @bitCast(std.mem.readInt(u32, source[index * 4 ..][0..4], endian));
        if (!std.math.isFinite(value)) return error.InvalidSamples;
        output[index] = float.widen32(value);
    }
}

test "float32 widening preserves the prefix and failing slot for every lane" {
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        for (0..37) |bad| {
            var bytes: [37 * 4 + 1]u8 = @splat(0);
            for (0..37) |index| {
                const word: u32 = if (index == bad) 0x7f80_0000 else 0x3f00_0000;
                std.mem.writeInt(u32, bytes[1 + index * 4 ..][0..4], word, endian);
            }
            var output: [37]f64 = @splat(42);
            try testing.expectError(
                error.InvalidSamples,
                decodeInto(bytes[1..], &output, .{ .encoding = .float32, .endian = endian }),
            );
            try testing.expect(std.mem.allEqual(f64, output[0..bad], 0.5));
            try testing.expect(std.mem.allEqual(f64, output[bad..], 42));
        }
    }
}

test "signed32 widening covers unaligned input, vector batches and tails" {
    const words = [_]i32{ std.math.minInt(i32), -1, 0, std.math.maxInt(i32) };
    const expected = [_]f64{ -1, -1.0 / 2_147_483_648.0, 0, 2_147_483_647.0 / 2_147_483_648.0 };
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        var bytes: [37 * 4 + 1]u8 = @splat(0);
        var wanted: [37]f64 = undefined;
        for (0..37) |index| {
            std.mem.writeInt(i32, bytes[1 + index * 4 ..][0..4], words[index % words.len], endian);
            wanted[index] = expected[index % expected.len];
        }
        for (0..38) |count| {
            var output: [37]f64 = @splat(42);
            const decoded = try decodeInto(
                bytes[1..][0 .. count * 4],
                &output,
                .{ .encoding = .signed32, .endian = endian },
            );
            try testing.expectEqualSlices(f64, wanted[0..count], decoded);
            try testing.expect(std.mem.allEqual(f64, output[count..], 42));
        }
    }
}

/// Checks the representation, encoded extent and every sample without writing. Integer samples must
/// be finite and in [-1, 1]. Float samples must be finite; binary32 output also rejects a sample
/// whose nearest-even f32 result is nonfinite. Tiny values may round to signed zero.
pub fn validate(source: []const f64, options: EncodeOptions) ValidateError!void {
    _ = try precision(options.format);
    const width = options.format.encoding.byteCount();
    if (source.len > std.math.maxInt(usize) / width) return error.SizeOverflow;
    if (options.format.encoding == .float64) return validateFinite(source);
    if (options.format.encoding == .float32) {
        for (source) |sample| {
            if (!rounding.isFiniteResult(@bitCast(sample))) return error.InvalidSamples;
        }
        return;
    }
    for (source) |sample| {
        if (!std.math.isFinite(sample) or sample < -1 or sample > 1) return error.InvalidSamples;
    }
}

test validate {
    try validate(&.{ -1, 0, 1 }, .{ .format = .{ .encoding = .signed32 } });
    try testing.expectError(
        error.InvalidSamples,
        validate(&.{2}, .{ .format = .{ .encoding = .signed32 } }),
    );
}

fn validateFinite(source: []const f64) error{InvalidSamples}!void {
    const lanes = std.simd.suggestVectorLength(u64) orelse 1;
    const Samples = @Vector(lanes, f64);
    const Words = @Vector(lanes, u64);
    const exponent: Words = @splat(0x7ff0_0000_0000_0000);
    var index: usize = 0;
    while (source.len - index >= lanes) : (index += lanes) {
        const values: Samples = source[index..][0..lanes].*;
        const words: Words = @bitCast(values);
        if (@reduce(.Or, (words & exponent) == exponent)) return error.InvalidSamples;
    }
    for (source[index..]) |sample| {
        if (!std.math.isFinite(sample)) return error.InvalidSamples;
    }
}

test "binary64 vector validation rejects every invalid position before output" {
    const lanes = std.simd.suggestVectorLength(u64) orelse 1;
    const count = lanes * 2 + 3;
    const options: EncodeOptions = .{ .format = .{ .encoding = .float64 } };
    const invalid = [_]u64{
        0x7ff0_0000_0000_0000, 0xfff0_0000_0000_0000, 0x7ff8_0000_0000_0001, 0x7ff0_0000_0000_0001,
    };
    var samples: [count]f64 = @splat(0.5);
    var bytes: [count * 8]u8 = undefined;
    for (invalid) |bits| {
        for (0..count) |index| {
            samples[index] = @bitCast(bits);
            @memset(&bytes, 0xa5);
            try testing.expectError(error.InvalidSamples, validate(&samples, options));
            try testing.expectError(error.InvalidSamples, encodeInto(&samples, &bytes, options));
            try testing.expectError(
                error.InvalidSamples,
                encodeInto(&samples, bytes[0..0], options),
            );
            try testing.expect(std.mem.allEqual(u8, &bytes, 0xa5));
            var writer: std.Io.Writer = .fixed(&bytes);
            try writer.writeByte(0x42);
            try testing.expectError(error.InvalidSamples, writeAll(&samples, &writer, options));
            try testing.expectEqualSlices(u8, &.{0x42}, writer.buffered());
            try testing.expect(std.mem.allEqual(u8, bytes[1..], 0xa5));
            samples[index] = 0.5;
        }
    }
}

/// Encodes a borrowed byte prefix after validating the whole source. Format, size, sample validity,
/// capacity and used-prefix overlap are checked in that order. Admission failure leaves the whole
/// destination unchanged. Binary32 output uses nearest-even rounding, including signed underflow.
pub fn encodeInto(source: []const f64, destination: []u8, options: EncodeOptions) EncodeError![]u8 {
    try validate(source, options);
    const bytes = source.len * options.format.encoding.byteCount();
    if (destination.len < bytes) return error.DestinationTooSmall;
    const output = destination[0..bytes];
    if (memory.overlaps(std.mem.sliceAsBytes(source), output)) return error.Aliasing;
    encodeSamples(source, output, options.format);
    return output;
}

test encodeInto {
    var bytes: [8]u8 = undefined;
    const output = try encodeInto(&.{-0.0}, &bytes, .{ .format = .{ .encoding = .float64 } });
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0x80 }, output);
}

/// Writes the selected PCM representation after validating the entire source. Writer failure may
/// leave a byte prefix. The caller owns flushing and must keep source disjoint from Writer storage.
pub fn writeAll(
    source: []const f64,
    writer: *std.Io.Writer,
    options: EncodeOptions,
) (ValidateError || std.Io.Writer.Error)!void {
    try validate(source, options);
    const width = options.format.encoding.byteCount();
    var index: usize = 0;
    while (index < source.len) {
        const available = writer.unusedCapacitySlice();
        const count = @min(available.len / width, source.len - index);
        if (count == 0) {
            var bytes: [8]u8 = undefined;
            encodeSamples(source[index..][0..1], bytes[0..width], options.format);
            try writer.writeAll(bytes[0..width]);
            index += 1;
            continue;
        }
        encodeSamples(source[index..][0..count], available[0 .. count * width], options.format);
        writer.advance(count * width);
        index += count;
    }
}

test writeAll {
    var bytes: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writeAll(&.{0.5}, &writer, .{ .format = .{ .encoding = .float32, .endian = .big } });
    try testing.expectEqualSlices(u8, &.{ 0x3f, 0, 0, 0 }, writer.buffered());
}

fn precision(format: Format) error{InvalidFormat}!u16 {
    const width: u16 = @intCast(format.encoding.byteCount() * 8);
    const bits: u16 = format.valid_bits orelse @intCast(width);
    if (bits == 0 or bits > width) return error.InvalidFormat;
    switch (format.encoding) {
        .float32, .float64 => if (bits != width) return error.InvalidFormat,
        else => {},
    }
    return bits;
}

fn encodeSamples(source: []const f64, output: []u8, format: Format) void {
    if (format.encoding == .float64 and format.endian == builtin.cpu.arch.endian()) {
        // Byte-vector loads preserve lane order on big-endian targets; the two-lane cap can use
        // 128-bit stores on x86-64.
        const lanes = @min(std.simd.suggestVectorLength(f64) orelse 1, 2);
        const Bytes = @Vector(lanes * 8, u8);
        const source_bytes = std.mem.sliceAsBytes(source);
        var index: usize = 0;
        while (source.len - index >= lanes) : (index += lanes) {
            const bytes: Bytes = source_bytes[index * 8 ..][0 .. lanes * 8].*;
            output[index * 8 ..][0 .. lanes * 8].* = bytes;
        }
        if (index < source.len) {
            std.mem.writeInt(
                u64,
                output[index * 8 ..][0..8],
                @bitCast(source[index]),
                format.endian,
            );
        }
        return;
    }
    const width = format.encoding.byteCount();
    const bits = precision(format) catch unreachable;
    if (format.encoding == .signed32 and bits == 32) {
        switch (format.endian) {
            .little => encodeSigned32(source, output, .little),
            .big => encodeSigned32(source, output, .big),
        }
        return;
    }
    if (format.encoding == .float32) {
        switch (format.endian) {
            .little => encodeFloat32(source, output, .little),
            .big => encodeFloat32(source, output, .big),
        }
        return;
    }
    for (source, 0..) |sample, index| {
        const bytes = output[index * width ..][0..width];
        switch (format.encoding) {
            .float64 => std.mem.writeInt(u64, bytes[0..8], @bitCast(sample), format.endian),
            .float32 => unreachable,
            else => {
                const midpoint: i64 = @as(i64, 1) << @intCast(bits - 1);
                const scale: f64 = @floatFromInt(midpoint);
                const rounded = sample_rounding.halfAwayScaled(sample, scale);
                const clamped = std.math.clamp(rounded, -midpoint, midpoint - 1);
                const number = switch (format.encoding) {
                    .unsigned8, .unsigned16, .unsigned24, .unsigned32 => clamped + midpoint,
                    else => clamped,
                };
                const mask = (@as(u64, 1) << @intCast(bits)) - 1;
                const word: u32 = @intCast(
                    (@as(u64, @bitCast(number)) & mask) << @intCast(width * 8 - bits),
                );
                switch (width) {
                    1 => bytes[0] = @intCast(word),
                    2 => std.mem.writeInt(u16, bytes[0..2], @intCast(word), format.endian),
                    3 => std.mem.writeInt(u24, bytes[0..3], @intCast(word), format.endian),
                    4 => std.mem.writeInt(u32, bytes[0..4], word, format.endian),
                    else => unreachable,
                }
            },
        }
    }
}

fn encodeFloat32(source: []const f64, output: []u8, comptime endian: std.lang.Endian) void {
    // Both callers validate the entire source before entering this routine. In particular, every
    // value has a finite nearest-even f32 result, so no per-sample admission is needed here.
    for (source, 0..) |sample, index| {
        const bits: u32 = @bitCast(float.narrow32(sample));
        std.mem.writeInt(u32, output[index * 4 ..][0..4], bits, endian);
    }
}

fn encodeSigned32(source: []const f64, output: []u8, comptime endian: std.lang.Endian) void {
    const lanes = std.simd.suggestVectorLength(f64) orelse 1;
    const Floats = @Vector(lanes, f64);
    const Integers = @Vector(lanes, i32);
    var index: usize = 0;
    while (source.len - index >= lanes) : (index += lanes) {
        const values: Floats = source[index..][0..lanes].*;
        // +1 scales to 2^31, so round in i64 and clamp before narrowing to i32. Truncation and the
        // residual implement half-away rounding without an ambient-mode-sensitive @round.
        const WideIntegers = @Vector(lanes, i64);
        const scaled = values * @as(Floats, @splat(2_147_483_648.0));
        const whole: WideIntegers = @trunc(scaled);
        const fraction = @abs(scaled - @as(Floats, @floatFromInt(whole)));

        const direction = @select(
            i64,
            scaled < @as(Floats, @splat(0)),
            @as(WideIntegers, @splat(-1)),
            @as(WideIntegers, @splat(1)),
        );
        const adjustment = @select(
            i64,
            fraction >= @as(Floats, @splat(0.5)),
            direction,
            @as(WideIntegers, @splat(0)),
        );

        const clamped = @min(
            @max(whole + adjustment, @as(WideIntegers, @splat(-2_147_483_648))),
            @as(WideIntegers, @splat(2_147_483_647)),
        );
        const words: Integers = @intCast(clamped);
        inline for (0..lanes) |lane| {
            std.mem.writeInt(i32, output[(index + lane) * 4 ..][0..4], words[lane], endian);
        }
    }
    for (source[index..], index..) |sample, position| {
        const rounded = sample_rounding.halfAwayScaled(sample, 2_147_483_648.0);
        const clamped: i32 = @intCast(std.math.clamp(rounded, -2_147_483_648, 2_147_483_647));
        std.mem.writeInt(i32, output[position * 4 ..][0..4], clamped, endian);
    }
}

test "finite binary64 bits round trip and nonfinite input leaves its slot" {
    // Negative zero, the smallest subnormal and the largest finite value must retain their bits
    // before the following infinity fails without changing its destination slot.
    const words = [_]u64{
        0x8000_0000_0000_0000, 0x0000_0000_0000_0001, 0x7fef_ffff_ffff_ffff, 0x7ff0_0000_0000_0000,
    };
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        var bytes: [words.len * 8]u8 = undefined;
        for (words, 0..) |word, index| {
            std.mem.writeInt(u64, bytes[index * 8 ..][0..8], word, endian);
        }
        var output = [_]f64{ 42, 42, 42, 42 };
        const format: Format = .{ .encoding = .float64, .endian = endian };
        try testing.expectError(error.InvalidSamples, decodeInto(&bytes, &output, format));
        for (words[0..3], output[0..3]) |word, sample| {
            try testing.expectEqual(word, @as(u64, @bitCast(sample)));
        }
        try testing.expectEqual(@as(f64, 42), output[3]);

        var encoded: [24]u8 = undefined;
        _ = try encodeInto(output[0..3], &encoded, .{ .format = format });
        try testing.expectEqualSlices(u8, bytes[0..24], &encoded);
    }
}

test "binary64 writing handles unaligned storage, overlap and Writer prefixes" {
    const source = [_]f64{
        @bitCast(@as(u64, 0x8000_0000_0000_0000)),
        @bitCast(@as(u64, 0x0000_0000_0000_0001)),
        @bitCast(@as(u64, 0x7fef_ffff_ffff_ffff)),
    };
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        const options: EncodeOptions = .{ .format = .{ .encoding = .float64, .endian = endian } };
        var expected: [source.len * 8]u8 = undefined;
        for (source, 0..) |sample, index| {
            std.mem.writeInt(u64, expected[index * 8 ..][0..8], @bitCast(sample), endian);
        }
        var storage: [expected.len + 1]u8 = @splat(0xa5);
        try testing.expectEqualSlices(
            u8,
            &expected,
            try encodeInto(&source, storage[1..], options),
        );
        try testing.expectEqual(@as(u8, 0xa5), storage[0]);
        var overlap = source;
        const before = overlap;
        try testing.expectError(
            error.Aliasing,
            encodeInto(&overlap, std.mem.sliceAsBytes(&overlap), options),
        );
        try testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(&before),
            std.mem.sliceAsBytes(&overlap),
        );
        for (0..expected.len + 1) |capacity| {
            @memset(&storage, 0xa5);
            var writer: std.Io.Writer = .fixed(storage[1..][0..capacity]);
            if (capacity == expected.len) {
                try writeAll(&source, &writer, options);
            } else {
                try testing.expectError(error.WriteFailed, writeAll(&source, &writer, options));
            }
            try testing.expectEqualSlices(u8, expected[0..capacity], writer.buffered());
            try testing.expectEqual(@as(u8, 0xa5), storage[0]);
            try testing.expect(std.mem.allEqual(u8, storage[1 + capacity ..], 0xa5));
        }
    }
}

test "binary64 writing covers vector lengths and odd tails" {
    var source: [33]f64 = undefined;
    for (&source, 0..) |*sample, index| {
        sample.* = @bitCast(@as(u64, 0x8000_0000_0000_0000) | @as(u64, @intCast(index)));
    }
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        const options: EncodeOptions = .{ .format = .{ .encoding = .float64, .endian = endian } };
        for (0..source.len + 1) |count| {
            var storage: [source.len * 8 + 2]u8 = @splat(0xa5);
            const result = try encodeInto(source[0..count], storage[1..], options);
            try testing.expectEqual(count * 8, result.len);
            for (source[0..count], 0..) |sample, index| {
                try testing.expectEqual(
                    @as(u64, @bitCast(sample)),
                    std.mem.readInt(u64, result[index * 8 ..][0..8], endian),
                );
            }
            try testing.expectEqual(@as(u8, 0xa5), storage[0]);
            try testing.expect(std.mem.allEqual(u8, storage[1 + result.len ..], 0xa5));
        }
    }
}

test "signed 8-bit samples round trip through f64" {
    const source = [_]u8{ 0x80, 0xff, 0, 0x7f };
    const format: Format = .{ .encoding = .signed8 };
    var samples: [source.len]f64 = undefined;
    try testing.expectEqualSlices(
        f64,
        &.{ -1, -1.0 / 128.0, 0, 127.0 / 128.0 },
        try decodeInto(&source, &samples, format),
    );
    var encoded: [source.len]u8 = undefined;
    try testing.expectEqualSlices(
        u8,
        &source,
        try encodeInto(&samples, &encoded, .{ .format = format }),
    );
}

test "binary32 narrowing validates the complete source before output" {
    const below: f64 = @bitCast(@as(u64, 0x47ef_ffff_efff_ffff));
    const midpoint: f64 = @bitCast(@as(u64, 0x47ef_ffff_f000_0000));
    const tiny_negative: f64 = -0x1p-150;
    const options: EncodeOptions = .{ .format = .{ .encoding = .float32 } };
    var storage: [8]u8 = @splat(0xa5);
    const bytes = try encodeInto(&.{ below, tiny_negative }, &storage, options);
    try testing.expectEqual(@as(u32, 0x7f7f_ffff), std.mem.readInt(u32, bytes[0..4], .little));
    try testing.expectEqual(@as(u32, 0x8000_0000), std.mem.readInt(u32, bytes[4..8], .little));
    const before = storage;
    try testing.expectError(error.InvalidSamples, encodeInto(&.{ 0, midpoint }, &storage, options));
    try testing.expectEqualSlices(u8, &before, &storage);
    var writer: std.Io.Writer = .fixed(&storage);
    try writer.writeByte(0x42);
    const written = storage;
    try testing.expectError(error.InvalidSamples, writeAll(&.{ 0, midpoint }, &writer, options));
    try testing.expectEqual(@as(usize, 1), writer.buffered().len);
    try testing.expectEqualSlices(u8, &written, &storage);
}

test "signed32 f64 encoding preserves endpoints and half-away rounding" {
    const half: f64 = 0.5 / 2_147_483_648.0;
    const half_bits: u64 = @bitCast(half);
    const below: f64 = @bitCast(half_bits - 1);
    const above: f64 = @bitCast(half_bits + 1);
    const values = [_]f64{ -1, 1, -above, -half, -below, -0.0, 0.0, below, half, above };
    const expected = [_]i32{ std.math.minInt(i32), std.math.maxInt(i32), -1, -1, 0, 0, 0, 0, 1, 1 };
    for ([_]std.lang.Endian{ .little, .big }) |endian| {
        const options: EncodeOptions = .{ .format = .{ .encoding = .signed32, .endian = endian } };
        for (0..values.len + 1) |count| {
            var bytes: [values.len * 4 + 2]u8 = @splat(0xa5);
            const encoded = try encodeInto(values[0..count], bytes[1..], options);
            for (expected[0..count], 0..) |word, index| {
                try testing.expectEqual(
                    word,
                    std.mem.readInt(i32, encoded[index * 4 ..][0..4], endian),
                );
            }
            try testing.expectEqual(@as(u8, 0xa5), bytes[0]);
            try testing.expect(std.mem.allEqual(u8, bytes[1 + encoded.len ..], 0xa5));
        }
    }
}
