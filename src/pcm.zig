//! Little-endian integer and finite IEEE binary32 PCM conversion with caller-owned storage. A
//! sample is one channel value. These operations do not assign a rate or channel layout. Reduced
//! integer precision occupies the high bits of its byte container; low padding is ignored. Integer
//! output is normalized to f32. Float input preserves every finite value, including values outside
//! [-1, 1]. Conversion allocates nothing and retains no borrowed storage.

const std = @import("std");
const testing = std.testing;

/// Encoded little-endian sample containers supported by the decoder.
pub const Encoding = enum {
    unsigned8,
    signed16,
    signed24,
    signed32,
    float32,

    /// Byte width of one encoded sample, independent of its meaningful precision.
    pub fn byteCount(self: Encoding) usize {
        return switch (self) {
            .unsigned8 => 1,
            .signed16 => 2,
            .signed24 => 3,
            .signed32, .float32 => 4,
        };
    }
};

/// Sample representation. Null precision uses every container bit. Integer precision is 1 through
/// the container width; float32 permits only 32. No rate or interleaving metadata is retained.
pub const Format = struct {
    encoding: Encoding,
    valid_bits: ?u6 = null,

    fn precision(self: Format) DecodeError!u16 {
        const width: u16 = @intCast(self.encoding.byteCount() * 8);
        const bits: u16 = self.valid_bits orelse @intCast(width);
        if (bits == 0 or bits > width or (self.encoding == .float32 and bits != 32))
            return error.InvalidFormat;
        return bits;
    }
};

/// Invalid representation, incomplete source, insufficient/aliased output or nonfinite float input.
pub const DecodeError = error{
    InvalidFormat,
    InvalidData,
    DestinationTooSmall,
    Aliasing,
    InvalidSamples,
};

/// Invalid normalized samples, encoded extent overflow or insufficient/aliased output.
pub const EncodeError = error{ InvalidSamples, SizeOverflow, DestinationTooSmall, Aliasing };

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
    const largest_complete = std.math.maxInt(usize) - 3;
    try testing.expectEqual(
        largest_complete / 4,
        try sampleCount(largest_complete, .{ .encoding = .signed32 }),
    );
}

/// Converts all source samples into a used destination prefix. Capacity, format and alias failures
/// precede writes; a nonfinite float may leave partial output, which remains unpublished on error.
/// Source and the used destination must be disjoint and live until return. Keep source unchanged;
/// it can retire afterward. The returned prefix borrows destination storage.
pub fn decodeInto(source: []const u8, destination: []f32, format: Format) DecodeError![]f32 {
    const count = try sampleCount(source.len, format);
    if (destination.len < count) return error.DestinationTooSmall;
    const output = destination[0..count];
    if (overlaps(source, std.mem.sliceAsBytes(output))) return error.Aliasing;
    try decodeSamples(format, source, output);
    return output;
}

test decodeInto {
    var samples: [3]f32 = undefined;
    const source = [_]u8{ 0, 128, 255, 127, 0, 0 };
    const output = try decodeInto(&source, &samples, .{ .encoding = .signed16 });
    try testing.expectEqualSlices(f32, &.{ -1, 32767.0 / 32768.0, 0 }, output);
}

/// Writes normalized samples as signed little-endian PCM16. Validates the entire source before
/// writing; finite values must be in [-1, 1]. Rounds to nearest, without dithering, and clamps the
/// positive endpoint to 32767. Writer failure may leave a prefix; the caller owns flushing. Samples
/// must not overlap writer storage.
pub fn writePcm16(
    source: []const f32,
    writer: *std.Io.Writer,
) (error{ InvalidSamples, SizeOverflow } || std.Io.Writer.Error)!void {
    try validatePcm16(source);
    for (source) |sample| {
        try writer.writeInt(i16, @intFromFloat(@min(32767, @round(sample * 32768))), .little);
    }
}

/// Validates all normalized PCM16 input before any output is written. Retains no borrow.
pub fn validatePcm16(source: []const f32) error{ InvalidSamples, SizeOverflow }!void {
    if (source.len > std.math.maxInt(usize) / 2) return error.SizeOverflow;
    for (source) |sample| {
        if (!std.math.isFinite(sample) or sample < -1 or sample > 1) return error.InvalidSamples;
    }
}

/// Encodes into a borrowed byte prefix, preserving the whole destination on any admission failure.
/// Used output occupies two bytes per sample; spare bytes are untouched. Source and used output
/// must be disjoint. The returned prefix borrows destination storage.
pub fn encodePcm16Into(source: []const f32, destination: []u8) EncodeError![]u8 {
    try validatePcm16(source);
    const bytes = source.len * 2;
    if (destination.len < bytes) return error.DestinationTooSmall;
    const output = destination[0..bytes];
    if (overlaps(std.mem.sliceAsBytes(source), output)) return error.Aliasing;
    var writer = std.Io.Writer.fixed(output);
    writePcm16(source, &writer) catch unreachable;
    return output;
}

test encodePcm16Into {
    var bytes: [6]u8 = undefined;
    const output = try encodePcm16Into(&.{ -1, 0, 1 }, &bytes);
    try testing.expectEqualSlices(u8, &.{ 0, 128, 0, 0, 255, 127 }, output);
}

test writePcm16 {
    var bytes: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writePcm16(&.{ -0.5, 0.5 }, &writer);
    try testing.expectEqualSlices(u8, &.{ 0, 192, 0, 64 }, writer.buffered());
}

/// Reports whether two borrowed byte spans share any byte; empty spans never overlap. Reads only
/// addresses and lengths, without inspecting or retaining either span. Pointer-end addition is
/// avoided so the comparison cannot overflow.
fn overlaps(first: []const u8, second: []const u8) bool {
    if (first.len == 0 or second.len == 0) return false;
    const a = @intFromPtr(first.ptr);
    const b = @intFromPtr(second.ptr);
    return if (a <= b) b - a < first.len else a - b < second.len;
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

fn decodeUnsignedPcm(raw: u8, valid_bits_per_sample: u16) f32 {
    const shift = 8 - valid_bits_per_sample;
    const sample: u8 = raw >> @intCast(shift);
    const midpoint: f32 = @floatFromInt(@as(u64, 1) << @intCast(valid_bits_per_sample - 1));
    return (@as(f32, @floatFromInt(sample)) - midpoint) / midpoint;
}

fn decodeSamples(format: Format, data: []const u8, output: []f32) DecodeError!void {
    const bits = try format.precision();
    if (format.encoding == .unsigned8 and bits == 8) {
        decodePcm8Samples(data, output);
        return;
    }
    if (format.encoding == .signed16 and bits == 16) {
        decodePcm16Samples(data, output);
        return;
    }

    var offset: usize = 0;
    for (output) |*sample| {
        sample.* = switch (format.encoding) {
            .unsigned8 => decodeUnsignedPcm(data[offset], bits),
            .signed16 => decodeSignedPcm(
                std.mem.readInt(i16, data[offset..][0..2], .little),
                16,
                bits,
            ),
            .signed24 => decodePcm24(data[offset..][0..3].*, bits),
            .signed32 => decodeSignedPcm(
                std.mem.readInt(i32, data[offset..][0..4], .little),
                32,
                bits,
            ),
            .float32 => @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little)),
        };
        if (format.encoding == .float32 and !std.math.isFinite(sample.*)) {
            return error.InvalidSamples;
        }
        offset += format.encoding.byteCount();
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

fn decodePcm24(bytes: [3]u8, valid_bits_per_sample: u16) f32 {
    const raw: u32 = @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
    const signed: i32 = if (raw & 0x0080_0000 != 0) @bitCast(raw | 0xff00_0000) else @intCast(raw);
    return decodeSignedPcm(signed, 24, valid_bits_per_sample);
}

fn decodeSignedPcm(raw: i32, container_bits: u16, valid_bits_per_sample: u16) f32 {
    const shift = container_bits - valid_bits_per_sample;
    const sample = raw >> @intCast(shift);
    const scale: f32 = @floatFromInt(@as(u64, 1) << @intCast(valid_bits_per_sample - 1));
    return @as(f32, @floatFromInt(sample)) / scale;
}

test "integer precision ignores low padding and normalizes both signed endpoints" {
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

test "PCM admission preserves storage and finite float bits" {
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

test "PCM16 encoding validates every sample before changing caller bytes" {
    var bytes: [12]u8 = @splat(0xa5);
    try testing.expectError(
        error.InvalidSamples,
        encodePcm16Into(&.{ 0, std.math.nan(f32) }, &bytes),
    );
    try testing.expect(std.mem.allEqual(u8, &bytes, 0xa5));
    try testing.expectError(error.DestinationTooSmall, encodePcm16Into(&.{ -1, 1 }, bytes[0..3]));
    try testing.expect(std.mem.allEqual(u8, &bytes, 0xa5));
    const output = try encodePcm16Into(&.{ -1, 1, -0.5, 0.5, 0, 0.25 }, &bytes);
    try testing.expectEqualSlices(u8, &.{ 0, 128, 255, 127, 0, 192, 0, 64, 0, 0, 0, 32 }, output);
}

test "PCM vector bodies and exact unaligned tails agree with independent dyadic values" {
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

test "PCM16 ties round away from zero and backend failure follows validation" {
    const source = [_]f32{ 1.0 / 65536.0, -1.0 / 65536.0, 3.0 / 65536.0, -3.0 / 65536.0, 1, -1 };
    var bytes: [12]u8 = undefined;
    const encoded = try encodePcm16Into(&source, &bytes);
    try testing.expectEqualSlices(u8, &.{
        1, 0, 255, 255, 2, 0, 254, 255, 255, 127, 0, 128,
    }, encoded);
    var failing: std.Io.Writer = .failing;
    try testing.expectError(error.InvalidSamples, writePcm16(&.{std.math.nan(f32)}, &failing));
    try testing.expectError(error.WriteFailed, writePcm16(&.{0}, &failing));
}

test "PCM admission checks only the used destination and preserves alias refusals" {
    var shared: [4]f32 = .{ -1, 0.5, 55, 66 };
    const bytes = std.mem.sliceAsBytes(&shared);
    try testing.expectError(
        error.Aliasing,
        decodeInto(bytes[0..4], shared[0..2], .{ .encoding = .signed16 }),
    );
    try testing.expectError(error.Aliasing, encodePcm16Into(shared[0..2], bytes[4..8]));
    try testing.expectEqualSlices(f32, &.{ -1, 0.5, 55, 66 }, &shared);

    @memcpy(bytes[8..12], &[_]u8{ 0, 128, 0, 64 });
    const decoded = try decodeInto(bytes[8..12], &shared, .{ .encoding = .signed16 });
    try testing.expectEqualSlices(f32, &.{ -1, 0.5 }, decoded);
    try testing.expectEqualSlices(u8, &.{ 0, 128, 0, 64 }, bytes[8..12]);
    try testing.expectEqual(66, shared[3]);

    shared = .{ 55, 66, -1, 0.5 };
    const encoded = try encodePcm16Into(shared[2..4], bytes);
    try testing.expectEqualSlices(u8, &.{ 0, 128, 0, 64 }, encoded);
    try testing.expectEqualSlices(f32, &.{ -1, 0.5 }, shared[2..4]);
}

test "byte spans distinguish empty touching and overlapping storage" {
    var storage: [16]u8 = undefined;
    try std.testing.expect(!overlaps(storage[0..0], &storage));
    try std.testing.expect(!overlaps(&storage, storage[16..16]));
    try std.testing.expect(!overlaps(storage[0..4], storage[4..8]));
    try std.testing.expect(!overlaps(storage[4..8], storage[0..4]));
    try std.testing.expect(overlaps(storage[0..4], storage[3..8]));
    try std.testing.expect(overlaps(storage[3..8], storage[0..4]));
    try std.testing.expect(overlaps(storage[0..8], storage[2..6]));
    try std.testing.expect(overlaps(storage[2..6], storage[0..8]));
}

test "separate live byte objects never overlap" {
    var first: [16]u8 = undefined;
    var second: [16]u8 = undefined;
    try std.testing.expect(!overlaps(&first, &second));
    try std.testing.expect(!overlaps(&second, &first));
}
