//! Decode Microsoft and IMA/DVI four-bit WAVE ADPCM blocks to caller-owned f32 samples. ADPCM
//! stores corrections to predicted amplitudes and adapts their scale as decoding proceeds. It
//! reduces payload size by discarding amplitude precision. This raw block codec takes metadata and
//! byte framing from its caller. Microsoft prediction uses signed division toward zero and unsigned
//! initial delta words. Blocks whose adaptive delta exceeds signed 32-bit range are rejected; this
//! is a decoder limit, not a format validity rule. A prefix never skips validation of encoded
//! blocks. Operations allocate nothing and retain no input. Block-layout reference: Microsoft
//! Multimedia Standards Update revision 3, pages 23–25 and 31–32.
//! https://www.mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/Docs/RIFFNEW.pdf

const std = @import("std");
const overlaps = @import("common/byte_ranges.zig").overlaps;
const testing = std.testing;

/// Specific block layouts, rather than a claim to support every ADPCM dialect.
pub const Encoding = enum { microsoft_wave, ima_wave };

/// Block layout supplied by a container parser or protocol. A frame has one sample per channel.
/// Channels must be one or two; every source block has exactly block_bytes bytes and produces
/// frames_per_block frames. No rate, container or allocation policy is retained.
pub const Format = struct {
    /// Select one of the supported four-bit WAVE layouts.
    encoding: Encoding,
    /// One for mono or two for stereo. Output is interleaved in channel order.
    channels: u16,
    /// Complete encoded block extent, including the seed headers.
    block_bytes: usize,
    /// Exact number of complete frames represented by one block, including its seed samples.
    frames_per_block: usize,
    /// Borrow signed little-endian i16 coefficient pairs, four bytes per pair. Required and read
    /// only for Microsoft decoding; no implicit default table is supplied. Keep storage immutable
    /// through the call. For either encoding this span must be disjoint from used output bytes.
    coefficients: []const u8 = &.{},

    fn validate(self: Format) error{ InvalidFormat, SizeOverflow }!void {
        if (self.channels == 0 or self.channels > 2) return error.InvalidFormat;
        const channels: usize = self.channels;
        const header = channels * @as(usize, if (self.encoding == .ima_wave) 4 else 7);
        if (self.block_bytes < header) return error.InvalidFormat;
        const encoded = self.block_bytes - header;
        const frames = switch (self.encoding) {
            .ima_wave => blk: {
                if (encoded % (channels * 4) != 0) return error.InvalidFormat;
                const samples = std.math.mul(
                    usize,
                    encoded / channels,
                    2,
                ) catch return error.SizeOverflow;
                break :blk std.math.add(usize, samples, 1) catch return error.SizeOverflow;
            },
            .microsoft_wave => blk: {
                if (self.coefficients.len == 0 or self.coefficients.len % 4 != 0)
                    return error.InvalidFormat;
                const samples = std.math.mul(
                    usize,
                    encoded,
                    2 / channels,
                ) catch return error.SizeOverflow;
                break :blk std.math.add(usize, samples, 2) catch return error.SizeOverflow;
            },
        };
        if (self.frames_per_block != frames) return error.InvalidFormat;
    }
};

/// Malformed geometry/blocks, Microsoft delta beyond its supported range, size overflow, or
/// insufficient/aliased output. The delta range restriction returns InvalidData.
pub const DecodeError = error{
    InvalidFormat,
    InvalidData,
    SizeOverflow,
    DestinationTooSmall,
    Aliasing,
};

/// Count frames from validated geometry and a whole number of source blocks. Reject malformed
/// Format, partial blocks or unrepresentable counts. No source, predictor header, coefficient value
/// or adaptive update is inspected. An empty byte count still validates Format.
pub fn frameCount(
    byte_count: usize,
    format: Format,
) error{ InvalidFormat, InvalidData, SizeOverflow }!usize {
    try format.validate();
    if (byte_count % format.block_bytes != 0) return error.InvalidData;
    return std.math.mul(
        usize,
        byte_count / format.block_bytes,
        format.frames_per_block,
    ) catch error.SizeOverflow;
}

/// Decode all complete blocks to interleaved f32 samples and return the used destination prefix.
/// Each sample is a signed PCM16 integer divided by 32768, exactly representable as f32. Spare
/// destination remains unchanged. Input, coefficients and output borrow only for the call; the
/// result borrows caller-owned output. No allocation or state is retained.
///
/// Geometry/count errors precede capacity, then alias checks. Capacity and alias refusals change no
/// output. Malformed blocks can leave partial output; disregard the used region on error. See
/// decodePrefixInto for the same admission and full-source validation with shorter output.
pub fn decodeInto(source: []const u8, destination: []f32, format: Format) DecodeError![]f32 {
    return decodePrefixInto(source, destination, try frameCount(source.len, format), format);
}

/// Publishes the requested whole-frame prefix while validating every block, including omitted
/// headers and adaptive state. Zero frames still validate all source blocks. The used destination
/// must be disjoint from source and coefficients; unused output capacity may overlap either input.
/// Keep both inputs alive until return. No borrow is retained internally.
pub fn decodePrefixInto(
    source: []const u8,
    destination: []f32,
    frames: usize,
    format: Format,
) DecodeError![]f32 {
    const complete = try frameCount(source.len, format);
    if (frames > complete) return error.InvalidData;
    const count = std.math.mul(usize, frames, format.channels) catch return error.SizeOverflow;
    if (destination.len < count) return error.DestinationTooSmall;
    const output = destination[0..count];
    const output_bytes = std.mem.sliceAsBytes(output);
    if (overlaps(
        source,
        output_bytes,
    ) or overlaps(format.coefficients, output_bytes)) return error.Aliasing;
    // Empty input has no block whose complete decoded size must be represented.
    if (source.len == 0) return output;
    switch (format.encoding) {
        .microsoft_wave => try decodeMsAdpcmBlocks(format, source, output),
        .ima_wave => try decodeImaBlocks(format, source, output),
    }
    return output;
}

test decodePrefixInto {
    const format: Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 4,
        .frames_per_block = 1,
    };
    var output: [1]f32 = undefined;
    _ = try decodePrefixInto(&.{ 0, 128, 0, 0, 255, 127, 0, 0 }, &output, 1, format);
    try testing.expectEqual(-1, output[0]);
    try testing.expectError(error.InvalidData, decodePrefixInto(&.{
        0, 0, 89, 0,
    }, &.{}, 0, format));
}

const ms_adpcm_adaptation_table = [_]i32{
    230, 230, 230, 230, 307, 409, 512, 614, 768, 614, 512, 409, 307, 230, 230, 230,
};

fn decodeMsAdpcmBlocks(format: Format, data: []const u8, output: []f32) DecodeError!void {
    const channel_count = @as(usize, format.channels);
    const block_sample_count = std.math.mul(
        usize,
        format.frames_per_block,
        channel_count,
    ) catch return error.SizeOverflow;
    const block_count = data.len / format.block_bytes;
    var output_offset: usize = 0;
    var block_start: usize = 0;
    for (0..block_count) |_| {
        const block = data[block_start..][0..format.block_bytes];
        const complete_output_end = std.math.add(
            usize,
            output_offset,
            block_sample_count,
        ) catch return error.SizeOverflow;
        const output_end = @min(complete_output_end, output.len);
        try decodeMsAdpcmBlock(format, block, output[output_offset..output_end]);
        output_offset = output_end;
        block_start += format.block_bytes;
    }
    if (output_offset != output.len) return error.InvalidData;
}

fn decodeMsAdpcmBlock(format: Format, block: []const u8, output: []f32) DecodeError!void {
    const channel_count = @as(usize, format.channels);
    const header_size = std.math.mul(usize, channel_count, 7) catch return error.InvalidData;
    if (block.len < header_size) return error.InvalidData;
    const expected_output_count = std.math.mul(
        usize,
        format.frames_per_block,
        channel_count,
    ) catch return error.SizeOverflow;
    if (output.len > expected_output_count or output.len % channel_count != 0)
        return error.InvalidData;
    if (format.coefficients.len % 4 != 0) return error.InvalidData;

    var predictors: [2]u8 = @splat(0);
    var deltas: [2]i32 = @splat(0);
    var samples_1: [2]i32 = @splat(0);
    var samples_2: [2]i32 = @splat(0);
    var coefficients: [2][2]i32 = undefined;
    for (0..channel_count) |channel| {
        predictors[channel] = block[channel];
        const coefficient_offset = std.math.mul(
            usize,
            @as(usize, predictors[channel]),
            4,
        ) catch return error.InvalidData;
        if (coefficient_offset + 4 > format.coefficients.len) return error.InvalidData;
        coefficients[channel] = .{
            std.mem.readInt(i16, format.coefficients[coefficient_offset..][0..2], .little),
            std.mem.readInt(i16, format.coefficients[coefficient_offset + 2 ..][0..2], .little),
        };
    }

    var offset = channel_count;
    for (0..channel_count) |channel| {
        deltas[channel] = readU16(block, offset + channel * 2);
    }
    offset += channel_count * 2;
    for (0..channel_count) |channel| {
        samples_1[channel] = std.mem.readInt(i16, block[offset + channel * 2 ..][0..2], .little);
    }
    offset += channel_count * 2;
    for (0..channel_count) |channel| {
        samples_2[channel] = std.mem.readInt(i16, block[offset + channel * 2 ..][0..2], .little);
    }

    for (0..channel_count) |channel| {
        // MS ADPCM stores iSamp1 (the second output sample) before iSamp2 (the first output
        // sample). The predictor state below intentionally keeps that header order, so publish the
        // seed samples in time order.
        if (channel < output.len) output[channel] = msAdpcmSample(samples_2[channel]);
        if (channel_count + channel < output.len) output[channel_count + channel] = msAdpcmSample(
            samples_1[channel],
        );
    }

    const encoded = block[header_size..];
    const expected_encoded_byte_count = if (channel_count == 1) (format.frames_per_block - 2) /
        2 else format.frames_per_block - 2;
    if (encoded.len != expected_encoded_byte_count) return error.InvalidData;

    var frame: usize = 2;
    var output_offset = 2 * channel_count;
    while (frame < format.frames_per_block) : (frame += 1) {
        const byte_index = if (channel_count == 1) (frame - 2) / 2 else frame - 2;
        const encoded_byte = encoded[byte_index];
        for (0..channel_count) |channel| {
            const high_nibble = if (channel_count == 1) (frame - 2) % 2 == 0 else channel == 0;
            const nibble: u4 = @truncate(if (high_nibble) encoded_byte >> 4 else encoded_byte);
            const sample = try decodeMsAdpcmNibble(
                &samples_1[channel],
                &samples_2[channel],
                &deltas[channel],
                coefficients[channel],
                nibble,
            );
            if (output_offset + channel < output.len) output[output_offset + channel] =
                msAdpcmSample(
                    sample,
                );
        }
        output_offset += channel_count;
    }
}

fn decodeMsAdpcmNibble(
    sample_1: *i32,
    sample_2: *i32,
    delta: *i32,
    coefficients: [2]i32,
    nibble: u4,
) DecodeError!i32 {
    const signed_nibble: i32 = if (nibble >= 8) @as(i32, nibble) - 16 else @as(i32, nibble);
    // Microsoft Multimedia Standards Update revision 3.0, pages 23-25, specifies signed division by
    // the 8.8 coefficient base. A right shift rounds negative fractional predictions down, changing
    // the sample and subsequent feedback.
    // https://www.mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/Docs/RIFFNEW.pdf
    const prediction = @divTrunc(
        @as(i64, sample_1.*) * coefficients[0] + @as(i64, sample_2.*) * coefficients[1],
        256,
    );
    const decoded = std.math.clamp(
        prediction + @as(i64, signed_nibble) * delta.*,
        @as(i64, -32768),
        @as(i64, 32767),
    );
    sample_2.* = sample_1.*;
    sample_1.* = @intCast(decoded);
    const next_delta = (@as(i64, delta.*) * ms_adpcm_adaptation_table[nibble]) >> 8;
    // Encoded nibbles can increase delta without a format-level upper bound. Reject a value we
    // cannot retain rather than trap or wrap the predictor.
    delta.* = std.math.cast(i32, @max(@as(i64, 16), next_delta)) orelse return error.InvalidData;
    return sample_1.*;
}

fn msAdpcmSample(sample: i32) f32 {
    return @as(f32, @floatFromInt(sample)) / 32768;
}

const ima_index_table = [_]i8{ -1, -1, -1, -1, 2, 4, 6, 8 };

const ima_step_table = [_]i32{
    7,     8,     9,     10,    11,    12,   13,    14,    16,    17,    19,    21,    23,    25,
    28,    31,    34,    37,    41,    45,   50,    55,    60,    66,    73,    80,    88,    97,
    107,   118,   130,   143,   157,   173,  190,   209,   230,   253,   279,   307,   337,   371,
    408,   449,   494,   544,   598,   658,  724,   796,   876,   963,   1060,  1166,  1282,  1411,
    1552,  1707,  1878,  2066,  2272,  2499, 2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,
    5894,  6484,  7132,  7845,  8630,  9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350,
    22385, 24623, 27086, 29794, 32767,
};

fn decodeImaBlocks(format: Format, data: []const u8, output: []f32) DecodeError!void {
    const channel_count = @as(usize, format.channels);
    const block_sample_count = std.math.mul(
        usize,
        format.frames_per_block,
        channel_count,
    ) catch return error.SizeOverflow;
    const block_count = data.len / format.block_bytes;
    var output_offset: usize = 0;
    var block_start: usize = 0;
    for (0..block_count) |_| {
        const block = data[block_start..][0..format.block_bytes];
        const complete_output_end = std.math.add(
            usize,
            output_offset,
            block_sample_count,
        ) catch return error.SizeOverflow;
        const output_end = @min(complete_output_end, output.len);
        try decodeImaBlock(format, block, output[output_offset..output_end]);
        output_offset = output_end;
        block_start += format.block_bytes;
    }
    if (output_offset != output.len) return error.InvalidData;
}

fn decodeImaBlock(format: Format, block: []const u8, output: []f32) DecodeError!void {
    const channel_count = @as(usize, format.channels);
    const header_size = std.math.mul(usize, channel_count, 4) catch return error.InvalidData;
    if (block.len < header_size) return error.InvalidData;
    const expected_output_count = std.math.mul(
        usize,
        format.frames_per_block,
        channel_count,
    ) catch return error.SizeOverflow;
    if (output.len > expected_output_count or output.len % channel_count != 0)
        return error.InvalidData;

    var predictors: [2]i32 = @splat(0);
    var step_indices: [2]u8 = @splat(0);
    for (0..channel_count) |channel| {
        const header = block[channel * 4 ..][0..4];
        predictors[channel] = std.mem.readInt(i16, header[0..2], .little);
        step_indices[channel] = header[2];
        if (step_indices[channel] > 88) return error.InvalidData;
        if (channel < output.len) output[channel] = imaSample(predictors[channel]);
    }

    const encoded = block[header_size..];
    const encoded_bytes_per_channel = encoded.len / channel_count;
    if (encoded.len % channel_count != 0 or encoded_bytes_per_channel % 4 != 0) {
        return error.InvalidData;
    }
    if (format.frames_per_block != 1 + encoded_bytes_per_channel * 2) {
        return error.InvalidData;
    }

    var frame: usize = 1;
    var group_offset: usize = 0;
    while (frame < format.frames_per_block) {
        const sample_count = @min(8, format.frames_per_block - frame);
        const group_bytes = if (channel_count == 2) 4 else (sample_count + 1) / 2;
        const frame_output_offset = frame * channel_count;
        for (0..channel_count) |channel| {
            const group = encoded[group_offset + channel * group_bytes ..][0..group_bytes];
            var output_offset = frame_output_offset + channel;
            for (0..sample_count) |sample_in_group| {
                const encoded_byte = group[sample_in_group / 2];
                const nibble: u4 = if (sample_in_group % 2 == 0) @truncate(
                    encoded_byte,
                ) else @truncate(encoded_byte >> 4);
                const sample = decodeImaNibble(
                    &predictors[channel],
                    &step_indices[channel],
                    nibble,
                );
                if (output_offset < output.len) output[output_offset] = imaSample(sample);
                output_offset += channel_count;
            }
        }
        frame += sample_count;
        group_offset += channel_count * group_bytes;
    }
    if (group_offset != encoded.len) return error.InvalidData;
}

fn decodeImaNibble(predictor: *i32, step_index: *u8, nibble: u4) i32 {
    const step = ima_step_table[step_index.*];
    var difference = step >> 3;
    if ((nibble & 1) != 0) difference += step >> 2;
    if ((nibble & 2) != 0) difference += step >> 1;
    if ((nibble & 4) != 0) difference += step;
    predictor.* = std.math.clamp(
        predictor.* + if ((nibble & 8) != 0) -difference else difference,
        -32768,
        32767,
    );
    const next_index = @as(i32, step_index.*) + ima_index_table[nibble & 7];
    step_index.* = @intCast(std.math.clamp(next_index, 0, 88));
    return predictor.*;
}

fn imaSample(sample: i32) f32 {
    return @as(f32, @floatFromInt(sample)) / 32768;
}

fn readU16(source: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, source[offset..][0..2], .little);
}

test "Microsoft signed fractional prediction truncates toward zero before feedback" {
    var first: i32 = -1;
    var second: i32 = -1;
    var delta: i32 = 37;
    try testing.expectEqual(0, try decodeMsAdpcmNibble(&first, &second, &delta, .{ 240, 0 }, 0));
    try testing.expectEqual(0, try decodeMsAdpcmNibble(&first, &second, &delta, .{ 240, 0 }, 0));
}

test "ADPCM geometry refuses overflow before touching sample storage" {
    const format: Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 8,
        .frames_per_block = 9,
    };
    const bytes = std.math.maxInt(usize) / 8 * 8;
    try testing.expectError(error.SizeOverflow, frameCount(bytes, format));
    var destination: [9]f32 = @splat(123);
    try testing.expectError(
        error.InvalidFormat,
        decodeInto(
            &.{0},
            &destination,
            .{ .encoding = .ima_wave, .channels = 0, .block_bytes = 4, .frames_per_block = 1 },
        ),
    );
    try testing.expect(std.mem.allEqual(f32, &destination, 123));
}

test "ADPCM empty input does not size absent blocks" {
    const midpoint = std.math.maxInt(usize) / 2 + 1;
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    for (
        [_]Format{
            .{
                .encoding = .microsoft_wave,
                .channels = 2,
                .block_bytes = midpoint + 12,
                .frames_per_block = midpoint,
                .coefficients = &coefficients,
            },
            .{
                .encoding = .ima_wave,
                .channels = 2,
                .block_bytes = midpoint + 8,
                .frames_per_block = midpoint + 1,
            },
        },
    ) |format| {
        try testing.expectEqual(0, try frameCount(0, format));
        var storage: [2]f32 = @splat(123);
        const destination: []f32 = &storage;
        const complete = try decodeInto(&.{}, destination, format);
        try testing.expectEqual(0, complete.len);
        try testing.expectEqual(destination.ptr, complete.ptr);
        const prefix = try decodePrefixInto(&.{}, destination, 0, format);
        try testing.expectEqual(0, prefix.len);
        try testing.expectEqual(destination.ptr, prefix.ptr);
        try testing.expectError(error.InvalidData, decodePrefixInto(&.{}, destination, 1, format));
        try testing.expect(std.mem.allEqual(f32, &storage, 123));
    }
}

// Keep this implementation support private. Only the used destination span is compared.

// Independent literal PCM16 facts are normalized here; this helper does not decode compressed data.
fn expectSamples(expected: []const i16, actual: []const f32) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |value, sample| {
        const normalized = @as(f32, @floatFromInt(value)) / 32768;
        try testing.expectEqual(@as(u32, @bitCast(normalized)), @as(u32, @bitCast(sample)));
    }
}

test frameCount {
    const format: Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 8,
        .frames_per_block = 9,
    };
    try testing.expectEqual(18, try frameCount(16, format));
    try testing.expectError(error.InvalidData, frameCount(15, format));
}

test decodeInto {
    // Coefficient (256, 0) predicts the previous sample. Codes 1 and 2 add 16 and 32.
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    const block = [_]u8{ 0, 16, 0, 100, 0, 0x9c, 0xff, 0x12 };
    var destination: [6]f32 = @splat(42);
    const samples = try decodeInto(
        &block,
        &destination,
        .{
            .encoding = .microsoft_wave,
            .channels = 1,
            .block_bytes = block.len,
            .frames_per_block = 4,
            .coefficients = &coefficients,
        },
    );
    try expectSamples(&.{ -100, 100, 116, 148 }, samples);
    try testing.expectEqualSlices(f32, &.{ 42, 42 }, destination[4..]);
}

test "IMA mono and stereo words have independent state and reserved bytes" {
    const mono = [_]u8{ 0, 0, 0, 0xff, 0x11, 0x11, 0x11, 0x11 };
    var output: [20]f32 = @splat(42);
    try expectSamples(&.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 }, try decodeInto(
        &mono,
        &output,
        .{ .encoding = .ima_wave, .channels = 1, .block_bytes = 8, .frames_per_block = 9 },
    ));
    const stereo = [_]u8{
        0, 0, 0, 0xaa, 100, 0, 0, 0xbb, 0x11, 0x11, 0x11, 0x11, 0x99, 0x99, 0x99, 0x99,
    };
    try expectSamples(&.{
        0, 100, 1, 99, 2, 98, 3, 97, 4, 96, 5, 95, 6, 94, 7, 93, 8, 92,
    }, try decodeInto(
        &stereo,
        &output,
        .{ .encoding = .ima_wave, .channels = 2, .block_bytes = 16, .frames_per_block = 9 },
    ));
    try testing.expectEqualSlices(f32, &.{ 42, 42 }, output[18..]);
}

test "Microsoft stereo seed order signed feedback and unsigned initial delta" {
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    const stereo = [_]u8{ 0, 0, 16, 0, 32, 0, 100, 0, 0x9c, 0xff, 90, 0, 0xa6, 0xff, 0x1f };
    var output: [6]f32 = undefined;
    try expectSamples(&.{ 90, -90, 100, -100, 116, -132 }, try decodeInto(
        &stereo,
        &output,
        .{
            .encoding = .microsoft_wave,
            .channels = 2,
            .block_bytes = 15,
            .frames_per_block = 3,
            .coefficients = &coefficients,
        },
    ));
    const high_delta = [_]u8{ 0, 0xff, 0xff, 0, 0, 0, 0, 0x10 };
    try expectSamples(&.{ 0, 0, 32767, 32767 }, try decodeInto(
        &high_delta,
        &output,
        .{
            .encoding = .microsoft_wave,
            .channels = 1,
            .block_bytes = 8,
            .frames_per_block = 4,
            .coefficients = &coefficients,
        },
    ));
    const fractional_coefficients = [_]u8{ 240, 0, 0, 0 };
    const fractional = [_]u8{ 0, 37, 0, 0xff, 0xff, 0xff, 0xff, 0 };
    try expectSamples(&.{ -1, -1, 0, 0 }, try decodeInto(
        &fractional,
        &output,
        .{
            .encoding = .microsoft_wave,
            .channels = 1,
            .block_bytes = 8,
            .frames_per_block = 4,
            .coefficients = &fractional_coefficients,
        },
    ));
}

test "every mono prefix and source residue preserves guards and block resets" {
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    const ms = [_]u8{ 0, 16, 0, 100, 0, 0x9c, 0xff, 0x12 };
    const ima = [_]u8{ 0, 0, 0, 0xff, 0x11, 0x11, 0x11, 0x11 };
    const cases = [_]struct {
        block: []const u8,
        format: Format,
        expected: []const i16,
    }{
        .{
            .block = &ms,
            .format = .{
                .encoding = .microsoft_wave,
                .channels = 1,
                .block_bytes = 8,
                .frames_per_block = 4,
                .coefficients = &coefficients,
            },
            .expected = &.{ -100, 100, 116, 148, -100, 100, 116, 148 },
        },
        .{
            .block = &ima,
            .format = .{
                .encoding = .ima_wave,
                .channels = 1,
                .block_bytes = 8,
                .frames_per_block = 9,
            },
            .expected = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 1, 2, 3, 4, 5, 6, 7, 8 },
        },
    };
    for (cases) |case| {
        for (0..8) |offset| {
            var source: [23]u8 = @splat(0xa5);
            const blocks = source[offset..][0..16];
            @memcpy(blocks[0..8], case.block);
            @memcpy(blocks[8..16], case.block);
            const before = source;
            for (0..case.expected.len + 1) |frames| {
                var destination: [20]f32 = @splat(42);
                const samples = try decodePrefixInto(blocks, &destination, frames, case.format);
                try testing.expectEqual(@intFromPtr(&destination), @intFromPtr(samples.ptr));
                try expectSamples(case.expected[0..frames], samples);
                for (destination[frames..]) |sample| try testing.expectEqual(42, sample);
                if (frames != 0) {
                    @memset(&destination, 42);
                    try testing.expectError(
                        error.DestinationTooSmall,
                        decodePrefixInto(blocks, destination[0 .. frames - 1], frames, case.format),
                    );
                    for (destination) |sample| try testing.expectEqual(42, sample);
                }
            }
            try testing.expectEqualSlices(u8, &before, &source);
        }
    }
}

test "omitted headers and adaptive overflow are still validated" {
    const format: Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 4,
        .frames_per_block = 1,
    };
    const invalid_later = [_]u8{ 0xff, 0xff, 0, 0, 0, 0, 89, 0 };
    var output: [2]f32 = @splat(42);
    try testing.expectError(
        error.InvalidData,
        decodePrefixInto(&invalid_later, &output, 0, format),
    );
    try testing.expectEqualSlices(f32, &.{ 42, 42 }, &output);
    try testing.expectError(
        error.InvalidData,
        decodePrefixInto(&invalid_later, &output, 1, format),
    );
    try expectSamples(&.{-1}, output[0..1]);
    try testing.expectEqual(42, output[1]);
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    var overflow: [23]u8 = undefined;
    @memcpy(overflow[0..7], &[_]u8{ 0, 0xff, 0xff, 0, 0, 0, 0 });
    @memset(overflow[7..], 0x77);
    try testing.expectError(
        error.InvalidData,
        decodePrefixInto(
            &overflow,
            &output,
            0,
            .{
                .encoding = .microsoft_wave,
                .channels = 1,
                .block_bytes = overflow.len,
                .frames_per_block = 34,
                .coefficients = &coefficients,
            },
        ),
    );
}

test "geometry capacity and both input aliases precede malformed block content" {
    var shared: [8]f32 = @splat(0.5);
    const before = shared;
    const bytes = std.mem.sliceAsBytes(&shared);
    const ima: Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 4,
        .frames_per_block = 1,
    };
    try testing.expectError(error.InvalidData, decodePrefixInto(bytes[0..4], &.{}, 2, ima));
    try testing.expectError(error.DestinationTooSmall, decodeInto(bytes[0..4], &.{}, ima));
    try testing.expectError(error.Aliasing, decodeInto(bytes[0..4], shared[0..1], ima));
    const block = [_]u8{ 0, 16, 0, 100, 0, 0x9c, 0xff, 0x12 };
    const ms: Format = .{
        .encoding = .microsoft_wave,
        .channels = 1,
        .block_bytes = 8,
        .frames_per_block = 4,
        .coefficients = bytes[0..4],
    };
    try testing.expectError(error.DestinationTooSmall, decodeInto(&block, shared[0..3], ms));
    try testing.expectError(error.Aliasing, decodeInto(&block, shared[0..4], ms));
    try testing.expectEqualSlices(f32, &before, &shared);
}

test "source and coefficients may touch output or occupy unused capacity" {
    const block = [_]u8{ 0, 16, 0, 100, 0, 0x9c, 0xff, 0x12 };
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    var shared: [16]f32 = @splat(0.5);
    const bytes = std.mem.sliceAsBytes(&shared);
    @memcpy(bytes[16..20], &coefficients);
    @memcpy(bytes[20..28], &block);
    const spare = shared[4..16].*;
    try expectSamples(&.{ -100, 100, 116, 148 }, try decodeInto(
        bytes[20..28],
        &shared,
        .{
            .encoding = .microsoft_wave,
            .channels = 1,
            .block_bytes = 8,
            .frames_per_block = 4,
            .coefficients = bytes[16..20],
        },
    ));
    try testing.expectEqualSlices(u8, std.mem.asBytes(&spare), bytes[16..]);
    @memcpy(bytes[0..8], &block);
    try expectSamples(&.{ -100, 100, 116, 148 }, try decodeInto(
        bytes[0..8],
        shared[2..6],
        .{
            .encoding = .microsoft_wave,
            .channels = 1,
            .block_bytes = 8,
            .frames_per_block = 4,
            .coefficients = &coefficients,
        },
    ));
    try testing.expectEqualSlices(u8, &block, bytes[0..8]);
}

test "stereo prefixes always end on complete frames" {
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    const ms = [_]u8{ 0, 0, 16, 0, 32, 0, 100, 0, 0x9c, 0xff, 90, 0, 0xa6, 0xff, 0x1f };
    const ima = [_]u8{
        0, 0, 0, 0xaa, 100, 0, 0, 0xbb, 0x11, 0x11, 0x11, 0x11, 0x99, 0x99, 0x99, 0x99,
    };
    const cases = [_]struct {
        source: []const u8,
        format: Format,
        expected: []const i16,
    }{
        .{
            .source = &ms,
            .format = .{
                .encoding = .microsoft_wave,
                .channels = 2,
                .block_bytes = 15,
                .frames_per_block = 3,
                .coefficients = &coefficients,
            },
            .expected = &.{ 90, -90, 100, -100, 116, -132 },
        },
        .{
            .source = &ima,
            .format = .{
                .encoding = .ima_wave,
                .channels = 2,
                .block_bytes = 16,
                .frames_per_block = 9,
            },
            .expected = &.{ 0, 100, 1, 99, 2, 98, 3, 97, 4, 96, 5, 95, 6, 94, 7, 93, 8, 92 },
        },
    };
    for (cases) |case| {
        for (0..case.format.frames_per_block + 1) |frames| {
            var destination: [20]f32 = @splat(42);
            const result = try decodePrefixInto(case.source, &destination, frames, case.format);
            try expectSamples(case.expected[0 .. frames * 2], result);
            for (destination[frames * 2 ..]) |sample| try testing.expectEqual(42, sample);
        }
    }
}
