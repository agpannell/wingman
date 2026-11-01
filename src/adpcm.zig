//! Encode and decode Microsoft and IMA/DVI four-bit WAVE ADPCM blocks in caller-owned storage.
//! ADPCM stores corrections to predicted amplitudes and adapts their scale as decoding proceeds. It
//! reduces payload size by discarding amplitude precision. This raw block codec takes metadata and
//! byte framing from its caller. Microsoft prediction uses signed division toward zero and unsigned
//! initial delta words. Blocks whose adaptive delta exceeds signed 32-bit range are rejected; this
//! is a decoder limit, not a format validity rule. A prefix never skips validation of encoded
//! blocks. Operations allocate nothing and retain no input. Block-layout reference: Microsoft
//! Multimedia Standards Update revision 3, pages 23–25 and 31–32.
//! https://www.mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/Docs/RIFFNEW.pdf

const std = @import("std");
const overlaps = @import("common/byte_ranges.zig").overlaps;
const sample_rounding = @import("common/round.zig");
const testing = std.testing;

/// Specific block layouts, rather than a claim to support every ADPCM dialect.
pub const Encoding = enum { microsoft_wave, ima_wave };

/// Block layout supplied by a container parser or protocol. A frame has one sample per channel.
/// Channels must be one or two; every encoded block has exactly block_bytes bytes and represents
/// frames_per_block frames. No rate, container or allocation policy is retained.
pub const Format = struct {
    /// Select one of the supported four-bit WAVE layouts.
    encoding: Encoding,
    /// One for mono or two for stereo. Samples are interleaved in channel order.
    channels: u16,
    /// Complete encoded block extent, including the seed headers.
    block_bytes: usize,
    /// Exact number of complete frames represented by one block, including its seed samples.
    frames_per_block: usize,
    /// Borrow signed little-endian i16 coefficient pairs, four bytes per pair. Required and read
    /// only for Microsoft blocks; no implicit default table is supplied. Keep storage immutable
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

/// Invalid geometry, incomplete frames or blocks, or an unrepresentable count.
pub const CountError = error{ InvalidFormat, InvalidData, SizeOverflow };

/// Malformed geometry/blocks, Microsoft delta beyond its supported range, size overflow, or
/// insufficient/aliased output. The delta range restriction returns InvalidData.
pub const DecodeError = error{
    InvalidFormat,
    InvalidData,
    SizeOverflow,
    DestinationTooSmall,
    Aliasing,
};

/// Deterministic block initialization and greedy nibble selection. Each channel is independent;
/// equal-error choices use the lowest nibble, and a preview/fast tie uses fast.
pub const Strategy = enum {
    /// Start IMA at step index zero; start Microsoft at predictor zero with the initial difference
    /// clamped to 16...32767.
    fast,
    /// Try up to 89 IMA indices or 256 Microsoft predictors with seven initial deltas, each on up
    /// to 16 supplied coded samples. Keep the candidate only when its decoded PCM16 squared error
    /// over the caller's supplied frames in that channel and block is lower than fast. Zero padding
    /// is excluded from this score. This does not guarantee lower error on a shorter prefix or
    /// better perceptual quality. Additional candidate passes trade speed for potentially lower
    /// error.
    preview,
};

/// Treatment of an input that ends before a complete block.
pub const Tail = enum {
    /// Encode a final block with zero PCM samples after the supplied frames.
    pad,
    /// Reject input that does not contain a whole number of blocks.
    strict,
};

/// Per-call encoder choices. The strategy is selected explicitly by the caller.
pub const EncodeOptions = struct {
    /// Block quality and work tradeoff.
    strategy: Strategy,
    /// How to handle a final partial block.
    tail: Tail = .pad,
};

/// Required byte storage and the actual and encoded frame counts.
pub const EncodeRequirements = struct {
    /// Bytes required for all complete encoded blocks.
    byte_count: usize,
    /// Whole frames actually supplied by the caller.
    frame_count: usize,
    /// Total frames represented by the encoded blocks, including padding.
    encoded_frame_count: usize,
};

/// Encoded bytes borrow the supplied destination; frame counts are per channel.
pub const EncodeResult = struct {
    /// The used destination prefix.
    bytes: []u8,
    /// Whole frames consumed from the caller.
    frame_count: usize,
    /// Total frames represented by the encoded blocks, including padding.
    encoded_frame_count: usize,
};

/// Invalid geometry or samples, unrepresentable size, insufficient output capacity or overlap.
pub const EncodeError = CountError || error{ InvalidSamples, DestinationTooSmall, Aliasing };

/// Computes complete-block output size without inspecting sample values. `sample_count` counts
/// interleaved samples, not frames. A padded block represents `encoded_frame_count` frames; retain
/// `frame_count` separately when a container must trim the decoded result. The encoded byte count,
/// frame count and total interleaved samples represented by those frames must each fit in usize.
pub fn encodeRequirements(
    sample_count: usize,
    format: Format,
    tail: Tail,
) CountError!EncodeRequirements {
    try format.validate();
    const channels: usize = format.channels;
    if (sample_count % channels != 0) return error.InvalidData;
    const frames = sample_count / channels;
    const partial = frames % format.frames_per_block != 0;
    if (partial and tail == .strict) return error.InvalidData;
    const blocks = std.math.add(
        usize,
        frames / format.frames_per_block,
        @intFromBool(partial),
    ) catch return error.SizeOverflow;
    const bytes = std.math.mul(usize, blocks, format.block_bytes) catch return error.SizeOverflow;
    const encoded_frames = std.math.mul(
        usize,
        blocks,
        format.frames_per_block,
    ) catch return error.SizeOverflow;
    _ = std.math.mul(usize, encoded_frames, channels) catch return error.SizeOverflow;
    return .{ .byte_count = bytes, .frame_count = frames, .encoded_frame_count = encoded_frames };
}

test encodeRequirements {
    // Three mono samples occupy one nine-frame block when padded; strict mode rejects the tail.
    const format: Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 8,
        .frames_per_block = 9,
    };
    const requirements = try encodeRequirements(3, format, .pad);
    try testing.expectEqual(@as(usize, 8), requirements.byte_count);
    try testing.expectEqual(@as(usize, 3), requirements.frame_count);
    try testing.expectEqual(@as(usize, 9), requirements.encoded_frame_count);
    try testing.expectError(error.InvalidData, encodeRequirements(3, format, .strict));
}

/// Encodes interleaved normalized f32 samples into raw blocks. Samples must be finite and in [-1,
/// 1]; conversion to PCM16 rounds halfway away from zero and clamps +1 to 32767. Format, frame
/// geometry and size are checked first, followed by all samples, capacity, then overlap. Admission
/// failures leave the destination unchanged. The used destination prefix must not overlap the
/// source or the complete coefficients slice; unused destination capacity may overlap either.
/// Padding uses zero PCM samples; their decoded lossy values are not necessarily silent. The source
/// and coefficients remain borrowed until return and are not retained.
pub fn encodeInto(
    source: []const f32,
    destination: []u8,
    format: Format,
    options: EncodeOptions,
) EncodeError!EncodeResult {
    const requirements = try encodeRequirements(source.len, format, options.tail);
    for (source) |sample| {
        const bits: u32 = @bitCast(sample);
        if (bits & 0x7fff_ffff > 0x3f80_0000) return error.InvalidSamples;
    }
    return encodeSamples(f32, source, destination, format, options, requirements);
}

test encodeInto {
    // Each IMA block contains only its seed: -1 and 0.5 become independent PCM16 headers.
    const format: Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 4,
        .frames_per_block = 1,
    };
    var bytes: [8]u8 = undefined;
    const result = try encodeInto(&.{ -1, 0.5 }, &bytes, format, .{ .strategy = .fast });
    try testing.expectEqual(@as(usize, 2), result.frame_count);
    try testing.expectEqual(@as(usize, 2), result.encoded_frame_count);
    try testing.expectEqualSlices(u8, &.{ 0, 128, 0, 0, 0, 64, 0, 0 }, result.bytes);
}

/// Encodes exact interleaved PCM16 samples into raw blocks using the same options and admission
/// rules as `encodeInto`, except that every i16 sample is valid without a value-validation pass.
pub fn encodeI16Into(
    source: []const i16,
    destination: []u8,
    format: Format,
    options: EncodeOptions,
) EncodeError!EncodeResult {
    const requirements = try encodeRequirements(source.len, format, options.tail);
    return encodeSamples(i16, source, destination, format, options, requirements);
}

test encodeI16Into {
    // One supplied Microsoft seed is followed by a zero seed; the header stores the later seed
    // first. Its initial delta is their absolute difference, clamped to 16...32767.
    const format: Format = .{
        .encoding = .microsoft_wave,
        .channels = 1,
        .block_bytes = 7,
        .frames_per_block = 2,
        .coefficients = &.{ 0, 1, 0, 0 },
    };
    var bytes: [7]u8 = undefined;
    const result = try encodeI16Into(&.{1234}, &bytes, format, .{ .strategy = .fast });
    try testing.expectEqual(@as(usize, 1), result.frame_count);
    try testing.expectEqual(@as(usize, 2), result.encoded_frame_count);
    try testing.expectEqualSlices(u8, &.{ 0, 210, 4, 0, 0, 210, 4 }, result.bytes);
}

fn encodeSamples(
    comptime Sample: type,
    source: []const Sample,
    destination: []u8,
    format: Format,
    options: EncodeOptions,
    requirements: EncodeRequirements,
) EncodeError!EncodeResult {
    // Admission finishes before the first block write. Only the used output prefix must be disjoint
    // from the source and coefficients; spare destination capacity is not written.
    if (destination.len < requirements.byte_count) return error.DestinationTooSmall;
    const output = destination[0..requirements.byte_count];
    if (overlaps(
        std.mem.sliceAsBytes(source),
        output,
    ) or overlaps(format.coefficients, output)) return error.Aliasing;
    if (requirements.byte_count != 0) {
        const samples_per_block = format.frames_per_block * @as(usize, format.channels);
        var source_offset: usize = 0;
        for (0..requirements.byte_count / format.block_bytes) |block| {
            const available = @min(samples_per_block, source.len - source_offset);
            const input = source[source_offset..][0..available];
            encodeFullBlock(
                Sample,
                input,
                output[block * format.block_bytes ..][0..format.block_bytes],
                format,
                options.strategy,
            );
            source_offset += available;
        }
    }
    return .{
        .bytes = output,
        .frame_count = requirements.frame_count,
        .encoded_frame_count = requirements.encoded_frame_count,
    };
}

/// Count decoded frames from validated geometry and whole source blocks without inspecting
/// predictor headers, coefficient values or adaptive updates. Empty input still validates Format.
/// Reject malformed geometry, partial blocks and unrepresentable counts.
pub fn frameCount(byte_count: usize, format: Format) CountError!usize {
    try format.validate();
    if (byte_count % format.block_bytes != 0) return error.InvalidData;
    return std.math.mul(
        usize,
        byte_count / format.block_bytes,
        format.frames_per_block,
    ) catch error.SizeOverflow;
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

/// Decode all complete blocks to interleaved f32 samples and return the used destination prefix.
/// Each sample is a signed PCM16 integer divided by 32768, exactly representable as f32. Spare
/// destination remains unchanged. Source and coefficients are borrowed through the call; the
/// returned slice borrows the destination. No allocation or state is retained.
///
/// Geometry/count errors precede capacity, then alias checks. Capacity and alias refusals change no
/// output. Malformed blocks can leave partial output; disregard the used region on error. See
/// decodePrefixInto for the same admission and full-source validation with shorter output.
pub fn decodeInto(source: []const u8, destination: []f32, format: Format) DecodeError![]f32 {
    return decodePrefixInto(source, destination, try frameCount(source.len, format), format);
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
    // Check the bytes that can actually be written, before inspecting or decoding block content.
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
    // The first header supplies the returned sample. Index 89 in an omitted block remains invalid
    // even when no frames are requested.
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

// The block encoder reads absent final samples as zero after public admission has checked frames.

const BlockState = struct {
    sample_1: i32,
    sample_2: i32 = 0,
    delta: i32 = 16,
    index: u8 = 0,
    predictor: u8 = 0,
    coefficients: [2]i32 = .{ 0, 0 },
};

fn blockCoefficients(format: Format, predictor: u8) [2]i32 {
    const offset = @as(usize, predictor) * 4;
    return .{
        std.mem.readInt(i16, format.coefficients[offset..][0..2], .little),
        std.mem.readInt(i16, format.coefficients[offset + 2 ..][0..2], .little),
    };
}

fn blockSample(comptime Sample: type, source: []const Sample, index: usize) i16 {
    if (index >= source.len) return 0;
    if (Sample == i16) return source[index];
    return @intCast(@min(32767, sample_rounding.halfAwayScaled(source[index], 32768)));
}

fn blockInitial(
    comptime Sample: type,
    source: []const Sample,
    format: Format,
    channel: usize,
) BlockState {
    var state: BlockState = .{ .sample_1 = blockSample(Sample, source, channel) };
    if (format.encoding == .microsoft_wave) {
        // The first two samples seed prediction; sample_1 is the later sample even though the
        // Microsoft header stores it before sample_2. A missing tail seed is zero-padded.
        state.sample_2 = state.sample_1;
        state.sample_1 = blockSample(Sample, source, @as(usize, format.channels) + channel);
        state.delta = @intCast(std.math.clamp(@abs(state.sample_1 - state.sample_2), 16, 32767));
        state.coefficients = blockCoefficients(format, 0);
    }
    return state;
}

fn blockStep(format: Format, state: BlockState, nibble: u4) ?BlockState {
    // Evaluate on a copy through the decoder's exact feedback, including clipping and adaptation. A
    // Microsoft delta that cannot be represented makes this choice unavailable.
    var next = state;
    switch (format.encoding) {
        .ima_wave => _ = decodeImaNibble(&next.sample_1, &next.index, nibble),
        .microsoft_wave => _ = decodeMsAdpcmNibble(
            &next.sample_1,
            &next.sample_2,
            &next.delta,
            next.coefficients,
            nibble,
        ) catch return null,
    }
    return next;
}

fn blockChoice(format: Format, state: BlockState, sample: i16) struct { u4, BlockState } {
    var best_error: u64 = std.math.maxInt(u64);
    var best_nibble: u4 = 0;
    var best_state = state;
    var first: usize = 0;
    var end: usize = 16;
    if (format.encoding == .ima_wave) {
        if (sample >= state.sample_1) {
            // Code eight is the closest negative code. Clipping can make it beat code zero even
            // when the target equals the predictor, so include it after all positive codes.
            end = 9;
        } else {
            // Code zero is the nearest positive code and wins ties against negative codes.
            const zero = blockStep(format, state, 0).?;
            const difference = @as(i64, sample) - zero.sample_1;
            best_error = @intCast(difference * difference);
            best_state = zero;
            first = 8;
        }
    }
    // Ascending codes and a strict improvement preserve the lowest nibble on equal error. This also
    // preserves its next state when clipping makes different codes reconstruct the same value.
    for (first..end) |candidate| {
        const nibble: u4 = @intCast(candidate);
        const next = blockStep(format, state, nibble) orelse continue;
        const difference = @as(i64, sample) - next.sample_1;
        const error_squared: u64 = @intCast(difference * difference);
        if (error_squared < best_error) {
            best_error = error_squared;
            best_nibble = nibble;
            best_state = next;
        }
    }
    // Nibble zero always reduces a valid Microsoft delta and is valid for IMA.
    std.debug.assert(best_error != std.math.maxInt(u64));
    return .{ best_nibble, best_state };
}

test "greedy block choice preserves tie order and bounded state" {
    const ima: Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 4,
        .frames_per_block = 1,
    };
    const ms: Format = .{
        .encoding = .microsoft_wave,
        .channels = 1,
        .block_bytes = 7,
        .frames_per_block = 2,
        .coefficients = &.{ 0, 1, 0, 0 },
    };

    // With IMA step 7, codes 0 and 8 both reconstruct zero; the lower code wins.
    const zero = blockChoice(ima, .{ .sample_1 = 0 }, 0);
    try testing.expectEqual(@as(u4, 0), zero[0]);
    try testing.expectEqual(@as(i32, 0), zero[1].sample_1);
    const minus_one = blockChoice(ima, .{ .sample_1 = 0 }, -1);
    try testing.expectEqual(@as(u4, 9), minus_one[0]);
    try testing.expectEqual(@as(i32, -1), minus_one[1].sample_1);

    // Saturated equal samples can update the index differently; code zero leaves index 87.
    const saturated = blockChoice(ima, .{ .sample_1 = 32767, .index = 88 }, 32767);
    try testing.expectEqual(@as(u4, 0), saturated[0]);
    try testing.expectEqual(@as(u8, 87), saturated[1].index);
    const lower = blockChoice(ima, .{ .sample_1 = -32768, .index = 88 }, -32768);
    try testing.expectEqual(@as(u4, 8), lower[0]);
    try testing.expectEqual(@as(i32, -32768), lower[1].sample_1);

    // High adaptive deltas make several otherwise attractive Microsoft codes inadmissible.
    const state: BlockState = .{ .sample_1 = 0, .delta = 2147483647, .coefficients = .{ 256, 0 } };
    const high = blockChoice(ms, state, 32767);
    try testing.expectEqual(@as(u4, 1), high[0]);
    try testing.expectEqual(@as(i32, 32767), high[1].sample_1);
    try testing.expectEqual(@as(i32, 1929379839), high[1].delta);
    const low = blockChoice(ms, state, -32768);
    try testing.expectEqual(@as(u4, 13), low[0]);
    try testing.expectEqual(@as(i32, -32768), low[1].sample_1);
    try testing.expectEqual(@as(i32, 1929379839), low[1].delta);
}

fn expectImaChoiceMatchesAllCodes(format: Format, state: BlockState, sample: i16) !void {
    var best_error: u64 = std.math.maxInt(u64);
    var best_nibble: u4 = 0;
    var best_state = state;
    for (0..16) |code| {
        const nibble: u4 = @intCast(code);
        const next = blockStep(format, state, nibble).?;
        const difference = @as(i64, sample) - next.sample_1;
        const squared: u64 = @intCast(difference * difference);
        if (squared < best_error) {
            best_error = squared;
            best_nibble = nibble;
            best_state = next;
        }
    }
    const actual = blockChoice(format, state, sample);
    try testing.expectEqual(best_nibble, actual[0]);
    try testing.expectEqualDeep(best_state, actual[1]);
}

test "IMA sign pruning matches every transition at midpoint boundaries" {
    const format: Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 4,
        .frames_per_block = 1,
    };
    // Values around every pairwise reconstruction midpoint exercise exact ties and clipping.
    const predictors = [_]i16{ -32768, -32767, -1, 0, 1, 32766, 32767 };
    for (0..89) |index| for (predictors) |predictor| {
        const state: BlockState = .{ .sample_1 = predictor, .index = @intCast(index) };
        for (0..16) |a| for (a..16) |b| {
            const left = blockStep(format, state, @intCast(a)).?.sample_1;
            const right = blockStep(format, state, @intCast(b)).?.sample_1;
            const midpoint = @divFloor(@as(i64, left) + right, 2);
            for ([_]i64{ -1, 0, 1, 2 }) |offset| {
                const sample: i16 = @intCast(std.math.clamp(midpoint + offset, -32768, 32767));
                try expectImaChoiceMatchesAllCodes(format, state, sample);
            }
        };
    };
    // Check the chosen state over a sequence as well as individual boundary decisions.
    var random = std.Random.DefaultPrng.init(0xb10c_ada5);
    for (0..64) |_| {
        var state: BlockState = .{
            .sample_1 = random.random().int(i16),
            .index = random.random().int(u8) % 89,
        };
        for (0..128) |_| {
            const sample = random.random().int(i16);
            try expectImaChoiceMatchesAllCodes(format, state, sample);
            state = blockChoice(format, state, sample)[1];
        }
    }
}

fn blockRun(
    comptime Sample: type,
    source: []const Sample,
    format: Format,
    channel: usize,
    initial: BlockState,
    count: usize,
    output: ?[]u8,
) u128 {
    var state = initial;
    var total: u128 = 0;
    const channels: usize = format.channels;
    const seeds: usize = if (format.encoding == .ima_wave) 1 else 2;
    for (0..count) |index| {
        const sample = blockSample(Sample, source, (seeds + index) * channels + channel);
        const choice = blockChoice(format, state, sample);
        const nibble = choice[0];
        state = choice[1];
        const difference = @as(i64, sample) - state.sample_1;
        total += @as(u64, @intCast(difference * difference));
        // The same transitions score a trial and emit the final block. Microsoft mono uses the high
        // nibble first; in stereo the high and low nibbles belong to channels 0 and 1. IMA uses low
        // nibble first in four-byte groups for each channel.
        if (output) |bytes| switch (format.encoding) {
            .microsoft_wave => {
                const offset = channels * 7 + if (channels == 1) index / 2 else index;
                const high = if (channels == 1) index % 2 == 0 else channel == 0;
                bytes[offset] |= if (high) @as(u8, nibble) << 4 else nibble;
            },
            .ima_wave => {
                const offset = channels * 4 + (index / 8) * channels * 4 + channel * 4 + (index %
                    8) / 2;
                bytes[offset] |= if (index % 2 == 0) nibble else @as(u8, nibble) << 4;
            },
        };
    }
    return total;
}

fn blockPreview(
    comptime Sample: type,
    source: []const Sample,
    format: Format,
    channel: usize,
    initial: BlockState,
    count: usize,
) BlockState {
    if (count == 0) return initial;
    // Pick a promising initial state from at most 16 supplied coded samples. The caller compares it
    // with fast over all supplied coded samples before accepting it.
    const preview_count = @min(count, 16);
    var best = initial;
    var best_error: u128 = std.math.maxInt(u128);
    switch (format.encoding) {
        .ima_wave => for (0..89) |index| {
            var state = initial;
            state.index = @intCast(index);
            const score = blockRun(Sample, source, format, channel, state, preview_count, null);
            if (score < best_error) {
                best_error = score;
                best = state;
            }
        },
        .microsoft_wave => {
            const deltas = [_]i32{ 16, 64, 256, 1024, 4096, 16384, 32767 };
            const predictor_count = @min(format.coefficients.len / 4, 256);
            for (0..predictor_count) |predictor| for (deltas) |delta| {
                var state = initial;
                state.predictor = @intCast(predictor);
                state.coefficients = blockCoefficients(format, state.predictor);
                state.delta = delta;
                const score = blockRun(Sample, source, format, channel, state, preview_count, null);
                if (score < best_error) {
                    best_error = score;
                    best = state;
                }
            };
        },
    }
    return best;
}

fn encodeFullBlock(
    comptime Sample: type,
    source: []const Sample,
    output: []u8,
    format: Format,
    strategy: Strategy,
) void {
    const channels: usize = format.channels;
    const seeds: usize = if (format.encoding == .ima_wave) 1 else 2;
    const count = format.frames_per_block - seeds;
    // Score only supplied frames after the seeds. The output pass still encodes absent frames from
    // zero-valued input samples. Saturating subtraction covers tails shorter than the Microsoft
    // two-sample seed.
    const scored_count = source.len / channels -| seeds;
    // Nibbles are ORed into shared bytes; zeroing also supplies IMA's reserved header byte.
    @memset(output, 0);
    for (0..channels) |channel| {
        var state = blockInitial(Sample, source, format, channel);
        if (strategy == .preview and scored_count != 0) {
            const candidate = blockPreview(Sample, source, format, channel, state, scored_count);
            const fast_error = blockRun(Sample, source, format, channel, state, scored_count, null);
            const candidate_error = blockRun(
                Sample,
                source,
                format,
                channel,
                candidate,
                scored_count,
                null,
            );
            // Keep fast on a tie so preview never worsens this channel's supplied-frame score.
            if (candidate_error < fast_error) state = candidate;
        }
        switch (format.encoding) {
            .ima_wave => {
                const header = output[channel * 4 ..][0..4];
                std.mem.writeInt(i16, header[0..2], blockSample(Sample, source, channel), .little);
                header[2] = state.index;
            },
            .microsoft_wave => {
                output[channel] = state.predictor;
                std.mem.writeInt(
                    u16,
                    output[channels + channel * 2 ..][0..2],
                    @intCast(state.delta),
                    .little,
                );
                std.mem.writeInt(
                    i16,
                    output[channels * 3 + channel * 2 ..][0..2],
                    blockSample(Sample, source, channels + channel),
                    .little,
                );
                std.mem.writeInt(
                    i16,
                    output[channels * 5 + channel * 2 ..][0..2],
                    blockSample(Sample, source, channel),
                    .little,
                );
            },
        }
        _ = blockRun(Sample, source, format, channel, state, count, output);
    }
}

test "complete block strategies preserve seeds and preview fallback" {
    const coefficients = [_]u8{
        0, 1,  0,   0, 0, 2, 0, 255, 0, 0, 0, 0, 192, 0, 64, 0, 240, 0, 0, 0, 204, 1, 48, 255, 136,
        1, 24, 255,
    };
    // The fixed sequence exercises both layouts and channel counts with repeatable input. Compare
    // decoded channel errors, not compressed bytes: preview may choose different valid states.
    var source: [242]i16 = undefined;
    var random = std.Random.DefaultPrng.init(0xada5_01);
    for (&source) |*sample| sample.* = random.random().int(i16);
    for ([_]Encoding{ .ima_wave, .microsoft_wave }) |encoding| {
        for ([_]u16{ 1, 2 }) |channels| {
            const payload = 64 - @as(
                usize,
                channels,
            ) * @as(usize, if (encoding == .ima_wave) 4 else 7);
            const frames = if (encoding == .ima_wave) 1 + payload * 2 / channels else 2 + payload *
                2 / channels;
            const format: Format = .{
                .encoding = encoding,
                .channels = channels,
                .block_bytes = 64,
                .frames_per_block = frames,
                .coefficients = &coefficients,
            };
            try format.validate();
            var fast: [64]u8 = undefined;
            var preview: [64]u8 = undefined;
            var decoded_fast: [242]f32 = undefined;
            var decoded_preview: [242]f32 = undefined;
            const input = source[0 .. frames * channels];
            encodeFullBlock(i16, input, &fast, format, .fast);
            encodeFullBlock(i16, input, &preview, format, .preview);
            const a = try decodeInto(&fast, &decoded_fast, format);
            const b = try decodeInto(&preview, &decoded_preview, format);
            const seeds: usize = if (encoding == .ima_wave) 1 else 2;
            for (0..channels) |channel| {
                var fast_error: u128 = 0;
                var preview_error: u128 = 0;
                for (0..frames) |frame| {
                    const offset = frame * channels + channel;
                    const fast_sample: i32 = @intFromFloat(a[offset] * 32768);
                    const preview_sample: i32 = @intFromFloat(b[offset] * 32768);
                    if (frame < seeds) {
                        try testing.expectEqual(input[offset], fast_sample);
                        try testing.expectEqual(input[offset], preview_sample);
                    }
                    const da = @as(i64, input[offset]) - fast_sample;
                    const db = @as(i64, input[offset]) - preview_sample;
                    fast_error += @as(u64, @intCast(da * da));
                    preview_error += @as(u64, @intCast(db * db));
                }
                try testing.expect(preview_error <= fast_error);
            }
        }
    }
}

test "ADPCM encoding pads whole frames and reports both frame counts" {
    const coefficients = [_]u8{ 0, 1, 0, 0, 0, 2, 0, 255 };
    for ([_]Encoding{ .ima_wave, .microsoft_wave }) |encoding| {
        for ([_]u16{ 1, 2 }) |channels| {
            const block_bytes: usize = if (encoding == .ima_wave) channels * 8 else channels * 8;
            const frames: usize = if (encoding == .ima_wave) 9 else 4;
            const format: Format = .{
                .encoding = encoding,
                .channels = channels,
                .block_bytes = block_bytes,
                .frames_per_block = frames,
                .coefficients = &coefficients,
            };
            for ([_]Strategy{ .fast, .preview }) |strategy| {
                for (
                    [_]usize{ 0, 1, frames - 1, frames, frames + 1, frames * 2 - 1, frames * 2 },
                ) |count| {
                    var integer: [36]i16 = @splat(0);
                    var floating: [36]f32 = @splat(0);
                    for (integer[0 .. count * channels], 0..) |*sample, i| {
                        sample.* = @intCast(@as(i32, @intCast(i)) * 733 - 12000);
                        floating[i] = @as(f32, @floatFromInt(sample.*)) / 32768;
                    }
                    var output: [32]u8 = @splat(0xa5);
                    var float_output: [32]u8 = @splat(0xa5);
                    var extended_output: [32]u8 = @splat(0xa5);
                    const blocks = count / frames + @intFromBool(count % frames != 0);
                    const actual = try encodeI16Into(
                        integer[0 .. count * channels],
                        &output,
                        format,
                        .{ .strategy = strategy },
                    );
                    const converted = try encodeInto(
                        floating[0 .. count * channels],
                        &float_output,
                        format,
                        .{ .strategy = strategy },
                    );
                    const extended = try encodeI16Into(
                        integer[0 .. blocks * frames * channels],
                        &extended_output,
                        format,
                        .{ .strategy = strategy, .tail = .strict },
                    );
                    try testing.expectEqual(count, actual.frame_count);
                    try testing.expectEqual(blocks * frames, actual.encoded_frame_count);
                    try testing.expectEqual(blocks * block_bytes, actual.bytes.len);
                    try testing.expectEqualSlices(u8, actual.bytes, converted.bytes);
                    // A partial preview scores caller input, not the zeros in an explicitly
                    // extended block. Fast and complete blocks have the same coded input.
                    if (strategy == .fast or count % frames == 0) try testing.expectEqualSlices(
                        u8,
                        actual.bytes,
                        extended.bytes,
                    );
                    try testing.expect(std.mem.allEqual(u8, output[actual.bytes.len..], 0xa5));
                    if (count % frames != 0) {
                        @memset(&output, 0xa5);
                        try testing.expectError(
                            error.InvalidData,
                            encodeI16Into(
                                integer[0 .. count * channels],
                                &output,
                                format,
                                .{ .strategy = strategy, .tail = .strict },
                            ),
                        );
                        try testing.expect(std.mem.allEqual(u8, &output, 0xa5));
                    }
                }
            }
        }
    }
}

test "preview scores supplied frames rather than padding" {
    const coefficients = [_]u8{
        0, 1,  0,   0, 0, 2, 0, 255, 0, 0, 0, 0, 192, 0, 64, 0, 240, 0, 0, 0, 204, 1, 48, 255, 136,
        1, 24, 255,
    };
    // These short tails distinguish the supplied-frame score from scoring the padded suffix.
    const cases = [_]struct {
        format: Format,
        samples: []const i16,
        fast_error: u64,
        preview_error: u64,
    }{
        .{
            .format = .{
                .encoding = .ima_wave,
                .channels = 1,
                .block_bytes = 12,
                .frames_per_block = 17,
            },
            .samples = &.{ 6469, 6390 },
            .fast_error = 4624,
            .preview_error = 1,
        },
        .{
            .format = .{
                .encoding = .microsoft_wave,
                .channels = 1,
                .block_bytes = 15,
                .frames_per_block = 18,
                .coefficients = &coefficients,
            },
            .samples = &.{ -9025, 20316, 31669, 3792 },
            .fast_error = 8038600,
            .preview_error = 143554,
        },
    };
    for (cases) |case| {
        for ([_]Strategy{ .fast, .preview }) |strategy| {
            var bytes: [15]u8 = undefined;
            const encoded = try encodeI16Into(
                case.samples,
                &bytes,
                case.format,
                .{ .strategy = strategy },
            );
            var decoded: [18]f32 = undefined;
            const output = try decodePrefixInto(
                encoded.bytes,
                &decoded,
                case.samples.len,
                case.format,
            );
            var error_squared: u64 = 0;
            for (case.samples, output) |input, sample| {
                const converted: i32 = @intFromFloat(sample * 32768);
                const difference = @as(i64, input) - converted;
                error_squared += @as(u64, @intCast(difference * difference));
            }
            try testing.expectEqual(
                if (strategy == .fast) case.fast_error else case.preview_error,
                error_squared,
            );
        }
    }
}

test "ADPCM float admission precedes capacity and overlap" {
    const format: Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 4,
        .frames_per_block = 1,
    };
    // NaN wins over a simultaneous short-destination error; no admission failure may write.
    var source = [_]f32{ 0, std.math.nan(f32) };
    var output: [8]u8 = @splat(0xa5);
    try testing.expectError(
        error.InvalidSamples,
        encodeInto(&source, output[0..0], format, .{ .strategy = .fast }),
    );
    try testing.expect(std.mem.allEqual(u8, &output, 0xa5));
    source[1] = 0.5;
    try testing.expectError(
        error.DestinationTooSmall,
        encodeInto(&source, output[0..7], format, .{ .strategy = .fast }),
    );
    try testing.expectError(
        error.Aliasing,
        encodeInto(&source, std.mem.sliceAsBytes(&source), format, .{ .strategy = .fast }),
    );
    try testing.expectEqualSlices(f32, &.{ 0, 0.5 }, &source);
}

test "ADPCM encoding rejects incomplete frames, overflow and coefficient overlap" {
    // A single stereo sample is not a whole frame; an extreme whole-frame count overflows its
    // encoded size. The guarded shared storage below checks the separate coefficient alias rule.
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    const stereo: Format = .{
        .encoding = .microsoft_wave,
        .channels = 2,
        .block_bytes = 14,
        .frames_per_block = 2,
        .coefficients = &coefficients,
    };
    try testing.expectError(error.InvalidData, encodeRequirements(1, stereo, .pad));
    try testing.expectError(
        error.SizeOverflow,
        encodeRequirements(std.math.maxInt(usize) - 1, stereo, .pad),
    );
    const empty = try encodeRequirements(0, stereo, .pad);
    try testing.expectEqual(@as(usize, 0), empty.byte_count);
    try testing.expectEqual(@as(usize, 0), empty.frame_count);
    try testing.expectEqual(@as(usize, 0), empty.encoded_frame_count);

    var storage: [14]u8 = .{ 0, 1, 0, 0 } ++ @as([10]u8, @splat(0xa5));
    const original = storage;
    var aliased = stereo;
    aliased.coefficients = storage[0..4];
    try testing.expectError(error.Aliasing, encodeI16Into(&.{
        1, 2,
    }, &storage, aliased, .{ .strategy = .fast }));
    try testing.expectEqualSlices(u8, &original, &storage);
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
        // An empty suffix suppresses writes, not validation: every later block is still decoded.
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
        // Continue through omitted blocks so malformed headers and state remain errors.
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
    // Each contribution is truncated separately. Combining the fractions before shifting changes
    // reconstruction at small odd step sizes and therefore later predictor feedback.
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
    // -240/256 truncates to zero, unlike an arithmetic shift to -1; the next sample uses that
    // state.
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
    // One enormous stereo block would overflow its sample count, but no block exists to size when
    // input is empty. Both decoding entry points must return the empty borrowed destination.
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

// Independent literal PCM16 facts are normalized here; this helper does not decode compressed data.
fn expectSamples(expected: []const i16, actual: []const f32) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |value, sample| {
        const normalized = @as(f32, @floatFromInt(value)) / 32768;
        try testing.expectEqual(@as(u32, @bitCast(normalized)), @as(u32, @bitCast(sample)));
    }
}

test "IMA mono and stereo words have independent state and reserved bytes" {
    // Nonzero reserved bytes must not affect output. Stereo channel groups carry opposite codes, so
    // their independent predictors advance in opposite directions.
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
    // The header stores the newer seed first, while decoded samples must be in time order. The
    // remaining witnesses distinguish an unsigned high-bit delta and truncation toward zero.
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
    // Repeat a block at every byte residue to exercise unaligned input and verify that each block
    // restarts its predictor. Guarded prefixes include zero and the complete result.
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
    // Index 89 occurs only in the omitted block, but even a zero-frame prefix must reject it.
    const invalid_later = [_]u8{ 0xff, 0xff, 0, 0, 0, 0, 89, 0 };
    var output: [2]f32 = @splat(42);
    try testing.expectError(
        error.InvalidData,
        decodePrefixInto(&invalid_later, &output, 0, format),
    );
    try testing.expectEqualSlices(f32, &.{ 42, 42 }, &output);
    // Requesting one frame allows the valid first block to write before the later error.
    try testing.expectError(
        error.InvalidData,
        decodePrefixInto(&invalid_later, &output, 1, format),
    );
    try expectSamples(&.{-1}, output[0..1]);
    try testing.expectEqual(42, output[1]);
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    // Repeated high-adaptation nibbles eventually overflow the supported Microsoft delta, including
    // when no decoded samples are requested.
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
    // Exercise prefix, capacity and source/coefficients alias refusals against the same guarded
    // destination. These admission errors happen before any decoded samples are written.
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
    // The input and coefficient bytes begin after the used output prefix, even though all three
    // spans share backing storage. A second case makes the input and output merely touch.
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
    // Every prefix must end after a complete interleaved channel pair and leave spare output
    // intact.
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

test "Microsoft high-bit initial delta is an unsigned word" {
    // 0xffff is 65535, so the positive correction clips high instead of acting like a negative
    // delta.
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    const format: Format = .{
        .encoding = .microsoft_wave,
        .channels = 1,
        .block_bytes = 8,
        .frames_per_block = 4,
        .coefficients = &coefficients,
    };
    const block = [_]u8{ 0, 0xff, 0xff, 0, 0, 0, 0, 0x10 };
    var output: [5]f32 = @splat(123);
    const decoded = try decodeInto(&block, &output, format);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 32767.0 / 32768.0, 32767.0 / 32768.0 }, decoded);
    try testing.expectEqual(@as(f32, 123), output[4]);
}

test "ADPCM prefix validates malformed later blocks" {
    // A one-frame IMA prefix still checks the later block's invalid step index.
    const ima: Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 4,
        .frames_per_block = 1,
    };
    const ima_blocks = [_]u8{ 0, 0, 0, 0, 0, 0, 89, 0 };
    var ima_output: [2]f32 = @splat(123);
    try testing.expectError(error.InvalidData, decodePrefixInto(&ima_blocks, &ima_output, 1, ima));
    try testing.expectEqual(@as(f32, 123), ima_output[1]);

    // A zero-frame Microsoft prefix still checks the later block's predictor index.
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    const ms: Format = .{
        .encoding = .microsoft_wave,
        .channels = 1,
        .block_bytes = 8,
        .frames_per_block = 4,
        .coefficients = &coefficients,
    };
    const ms_blocks = [_]u8{ 0, 16, 0, 0, 0, 0, 0, 0, 1, 16, 0, 0, 0, 0, 0, 0 };
    var ms_output: [1]f32 = @splat(123);
    try testing.expectError(error.InvalidData, decodePrefixInto(&ms_blocks, &ms_output, 0, ms));
    try testing.expectEqual(@as(f32, 123), ms_output[0]);
}
