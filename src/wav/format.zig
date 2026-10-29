//! WAVE format records and decoded-frame geometry. Metadata is copied except Microsoft predictor
//! coefficients, which borrow immutable fmt payload bytes through conversion. Meaningful integer
//! precision occupies the high bits of its container. Counting frames does not validate samples or
//! apply a file's fact prefix. Construct Format values with parseFormat.

const std = @import("std");

/// InvalidWave is malformed format/extent; UnsupportedWave is an unimplemented encoding or
/// admitted-profile choice. SizeOverflow means the requested output extent cannot fit usize.
pub const FormatError = error{ InvalidWave, UnsupportedWave, SizeOverflow };

/// Encoded channel count. Decoding permits any nonzero extensible count; `writePcm16` supports mono
/// and stereo. Use `@backingInt(channels)` for frame width; admitted multichannel values need not
/// have a named enum tag. This count carries no speaker-mask mapping.
pub const Channels = enum(u16) { mono = 1, stereo = 2, _ };

const wave_format_pcm = 1;
const wave_format_adpcm = 2;
const wave_format_alaw = 6;
const wave_format_mulaw = 7;
const wave_format_ima_adpcm = 0x11;
const wave_format_ieee_float = 3;
const wave_format_extensible = 0xfffe;

const pcm_subformat_guid = [_]u8{
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71,
};
const ieee_float_subformat_guid = [_]u8{
    0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71,
};
const alaw_subformat_guid = [_]u8{
    0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71,
};
const mulaw_subformat_guid = [_]u8{
    0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71,
};

/// Accepted sample representation after format validation.
pub const Encoding = enum {
    /// Unsigned eight-bit PCM container, centered around its valid-bit midpoint.
    pcm_u8,
    /// Signed little-endian sixteen-bit PCM container.
    pcm_s16,
    /// Signed little-endian twenty-four-bit PCM container.
    pcm_s24,
    /// Signed little-endian thirty-two-bit PCM container.
    pcm_s32,
    /// Little-endian IEEE f32; conversion rejects nonfinite values.
    ieee_f32,
    /// Four-bit Microsoft ADPCM using coefficients borrowed from the format.
    ms_adpcm,
    /// Eight-bit G.711 A-law companded samples.
    g711_alaw,
    /// Eight-bit G.711 mu-law companded samples.
    g711_mulaw,
    /// Four-bit IMA ADPCM in complete channel headers and four-byte data words.
    ima_adpcm,
};

/// Validated channel, rate, precision, and encoded-block geometry. Construct with `parseFormat`;
/// coefficient bytes remain borrowed from that source. This metadata admits representation/geometry
/// only; conversion validates sample/block contents. Copying Format copies the coefficient slice,
/// not its bytes. No deinit is needed.
pub const Format = struct {
    /// Source frame rate in frames per second.
    sample_rate: u32,
    /// Raw extensible speaker mask; null for ordinary formats, zero for unspecified speakers.
    channel_mask: ?u32 = null,
    /// Interleaved sample values per decoded frame.
    channels: Channels,
    /// Encoded bytes per uncompressed/G.711 frame, or per complete ADPCM block.
    block_align: usize,
    /// Bytes per uncompressed/G.711 sample; ADPCM uses a placeholder of one. Use `frameCount` and
    /// `block_align` for compressed storage geometry.
    bytes_per_sample: usize,
    /// Meaningful PCM precision, excluding low container padding bits. Float, G.711, and ADPCM
    /// report their encoded bit depth.
    valid_bits_per_sample: u16,
    /// Validated representation selecting the conversion kernel.
    encoding: Encoding,
    /// Decoded frames per ADPCM block; one for uncompressed/G.711 frames.
    samples_per_block: usize = 1,
    /// Borrowed Microsoft ADPCM pairs of signed little-endian i16 coefficients. Empty for other
    /// encodings; four bytes per predictor pair.
    adpcm_coefficients: []const u8 = &.{},
};

const ExtensibleFormat = struct { encoding: Encoding, valid_bits_per_sample: u16 };

/// Counts complete decoded frames in one whole-frame or whole-block data chunk. `info` must come
/// from `parseFormat`. ADPCM counts include encoded padding frames. Zero bytes return zero frames.
/// An incomplete frame/block returns `InvalidWave`; counting ADPCM frames can return
/// `SizeOverflow`. Does not inspect sample bytes or apply a fact count; this is allocation
/// geometry, not proof that conversion will succeed.
pub fn frameCount(info: Format, byte_count: usize) FormatError!usize {
    if (byte_count % info.block_align != 0) return error.InvalidWave;
    const block_count = byte_count / info.block_align;
    if (info.encoding != .ima_adpcm and info.encoding != .ms_adpcm) return block_count;
    return std.math.mul(usize, block_count, info.samples_per_block) catch return error.SizeOverflow;
}

/// Admits one complete `fmt ` payload without allocation or sample conversion. Extension
/// coefficients are borrowed; speaker-mask metadata is copied when present. The returned
/// description needs no cleanup. It does not validate data chunks, enforce a container's fact
/// count, or establish an output-storage lifetime.
pub fn parseFormat(source: []const u8) FormatError!Format {
    if (source.len < 16) return error.InvalidWave;
    const tag = readU16(source, 0);
    const channels = try parseChannels(readU16(source, 2));
    const sample_rate = readU32(source, 4);
    const block_align = readU16(source, 12);
    const bits_per_sample = readU16(source, 14);
    if (sample_rate == 0 or block_align == 0 or bits_per_sample == 0) {
        return error.InvalidWave;
    }

    var valid_bits_per_sample = bits_per_sample;
    var samples_per_block: usize = 1;
    var adpcm_coefficients: []const u8 = &.{};
    const encoding: Encoding = switch (tag) {
        wave_format_pcm => try pcmEncoding(bits_per_sample),
        wave_format_adpcm => blk: {
            if (bits_per_sample != 4 or @backingInt(channels) > 2) {
                return error.UnsupportedWave;
            }
            const adpcm = try parseMsAdpcmFormat(source);
            samples_per_block = adpcm.samples_per_block;
            adpcm_coefficients = adpcm.coefficients;
            break :blk .ms_adpcm;
        },
        wave_format_alaw => if (bits_per_sample == 8) .g711_alaw else return error.UnsupportedWave,
        wave_format_mulaw,
        => if (bits_per_sample == 8) .g711_mulaw else return error.UnsupportedWave,
        wave_format_ima_adpcm => blk: {
            if (bits_per_sample != 4 or @backingInt(channels) > 2) {
                return error.UnsupportedWave;
            }
            samples_per_block = try parseImaAdpcmSamplesPerBlock(source);
            break :blk .ima_adpcm;
        },
        wave_format_ieee_float,
        => if (bits_per_sample == 32) .ieee_f32 else return error.UnsupportedWave,
        wave_format_extensible => blk: {
            const extensible = try parseExtensibleFormat(source, bits_per_sample);
            valid_bits_per_sample = extensible.valid_bits_per_sample;
            break :blk extensible.encoding;
        },
        else => return error.UnsupportedWave,
    };
    if (@backingInt(channels) > 2 and tag != wave_format_extensible) return error.UnsupportedWave;
    const bytes_per_sample = bytesPerSample(encoding);
    const channel_count = @as(usize, @backingInt(channels));
    const expected_align: usize = blk: {
        if (encoding == .ima_adpcm) {
            const header_size = std.math.mul(
                usize,
                channel_count,
                4,
            ) catch return error.InvalidWave;
            if (block_align < header_size) return error.InvalidWave;
            const encoded_byte_count = block_align - header_size;
            if (encoded_byte_count % channel_count != 0) return error.InvalidWave;
            const encoded_bytes_per_channel = encoded_byte_count / channel_count;
            if (encoded_bytes_per_channel % 4 != 0) {
                return error.InvalidWave;
            }
            const expected_samples = std.math.add(
                usize,
                1,
                std.math.mul(usize, encoded_bytes_per_channel, 2) catch return error.InvalidWave,
            ) catch return error.InvalidWave;
            if (samples_per_block != expected_samples) return error.InvalidWave;
            break :blk @as(usize, block_align);
        }
        if (encoding == .ms_adpcm) {
            const header_size = std.math.mul(
                usize,
                channel_count,
                7,
            ) catch return error.InvalidWave;
            if (block_align < header_size) return error.InvalidWave;
            const encoded_byte_count = block_align - header_size;
            const encoded_sample_count = if (channel_count == 1) std.math.mul(
                usize,
                encoded_byte_count,
                2,
            ) catch return error.InvalidWave else encoded_byte_count;
            const expected_samples = std.math.add(
                usize,
                2,
                encoded_sample_count,
            ) catch return error.InvalidWave;
            if (samples_per_block != expected_samples) return error.InvalidWave;
            break :blk @as(usize, block_align);
        }
        break :blk std.math.mul(
            usize,
            channel_count,
            bytes_per_sample,
        ) catch return error.InvalidWave;
    };
    if (block_align != expected_align) return error.InvalidWave;
    return .{
        .sample_rate = sample_rate,
        .channel_mask = if (tag == wave_format_extensible) readU32(source, 20) else null,
        .channels = channels,
        .block_align = block_align,
        .bytes_per_sample = bytes_per_sample,
        .valid_bits_per_sample = valid_bits_per_sample,
        .encoding = encoding,
        .samples_per_block = samples_per_block,
        .adpcm_coefficients = adpcm_coefficients,
    };
}

const MsAdpcmFormat = struct { samples_per_block: usize, coefficients: []const u8 };

fn parseMsAdpcmFormat(source: []const u8) FormatError!MsAdpcmFormat {
    const extra_byte_count = if (source.len >= 18) readU16(source, 16) else 0;
    if (extra_byte_count < 4 or source.len < 18 + @as(usize, extra_byte_count)) {
        return error.InvalidWave;
    }

    const samples_per_block = readU16(source, 18);
    const coefficient_count = readU16(source, 20);
    if (samples_per_block < 2 or coefficient_count == 0) return error.InvalidWave;
    const coefficient_byte_count = std.math.mul(
        usize,
        @as(usize, coefficient_count),
        4,
    ) catch return error.InvalidWave;
    const required_extra_byte_count = std.math.add(
        usize,
        4,
        coefficient_byte_count,
    ) catch return error.InvalidWave;
    if (required_extra_byte_count > extra_byte_count) return error.InvalidWave;

    return .{
        .samples_per_block = samples_per_block,
        .coefficients = source[22..][0..coefficient_byte_count],
    };
}

fn parseImaAdpcmSamplesPerBlock(source: []const u8) FormatError!usize {
    const extra_byte_count = if (source.len >= 18) readU16(source, 16) else 0;
    if (extra_byte_count < 2 or source.len < 18 + @as(usize, extra_byte_count)) {
        return error.InvalidWave;
    }
    const samples_per_block = readU16(source, 18);
    if (samples_per_block == 0) return error.InvalidWave;
    return samples_per_block;
}

fn parseChannels(value: u16) FormatError!Channels {
    if (value == 0) return error.InvalidWave;
    return @fromBackingInt(@intCast(value));
}

fn pcmEncoding(bits_per_sample: u16) FormatError!Encoding {
    return switch (bits_per_sample) {
        8 => .pcm_u8,
        16 => .pcm_s16,
        24 => .pcm_s24,
        32 => .pcm_s32,
        else => error.UnsupportedWave,
    };
}

fn parseExtensibleFormat(source: []const u8, bits_per_sample: u16) FormatError!ExtensibleFormat {
    const extra_byte_count = if (source.len >= 18) readU16(source, 16) else 0;
    const extension_end = std.math.add(
        usize,
        18,
        @as(usize, extra_byte_count),
    ) catch return error.InvalidWave;
    if (extra_byte_count < 22 or source.len < 40 or source.len < extension_end) {
        return error.InvalidWave;
    }
    const valid_bits_per_sample = readU16(source, 18);
    const subformat = source[24..40];
    if (std.mem.eql(u8, subformat, &alaw_subformat_guid)) {
        if (bits_per_sample != 8) return error.UnsupportedWave;
        // WAVEFORMATEXTENSIBLE reuses this field as wSamplesPerBlock for compressed subformats, so
        // it is not a G.711 precision field.
        return .{ .encoding = .g711_alaw, .valid_bits_per_sample = bits_per_sample };
    }
    if (std.mem.eql(u8, subformat, &mulaw_subformat_guid)) {
        if (bits_per_sample != 8) return error.UnsupportedWave;
        return .{ .encoding = .g711_mulaw, .valid_bits_per_sample = bits_per_sample };
    }
    if (valid_bits_per_sample == 0 or valid_bits_per_sample > bits_per_sample)
        return error.InvalidWave;
    if (std.mem.eql(u8, subformat, &pcm_subformat_guid)) {
        return .{
            .encoding = try pcmEncoding(bits_per_sample),
            .valid_bits_per_sample = valid_bits_per_sample,
        };
    }
    if (std.mem.eql(u8, subformat, &ieee_float_subformat_guid)) {
        if (bits_per_sample == 32 and valid_bits_per_sample == bits_per_sample) return .{
            .encoding = .ieee_f32,
            .valid_bits_per_sample = valid_bits_per_sample,
        };
        return error.UnsupportedWave;
    }
    return error.UnsupportedWave;
}

fn bytesPerSample(encoding: Encoding) usize {
    return switch (encoding) {
        .pcm_u8 => 1,
        .pcm_s16 => 2,
        .pcm_s24 => 3,
        .pcm_s32, .ieee_f32 => 4,
        .g711_alaw, .g711_mulaw => 1,
        .ms_adpcm, .ima_adpcm => 1,
    };
}

fn readU16(source: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, source[offset..][0..2], .little);
}

fn readU32(source: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, source[offset..][0..4], .little);
}

test "format descriptions borrow coefficients and share exact block geometry" {
    const pcm = @import("fixtures.zig");
    const ms = try parseFormat(pcm.ms_adpcm_mono[20..70]);
    try std.testing.expectEqual(Encoding.ms_adpcm, ms.encoding);
    try std.testing.expectEqual(6, ms.samples_per_block);
    try std.testing.expectEqual(9, ms.block_align);
    try std.testing.expectEqual(12, try frameCount(ms, 18));
    try std.testing.expectError(error.InvalidWave, frameCount(ms, 17));
    try std.testing.expectEqual(pcm.ms_adpcm_mono[42..].ptr, ms.adpcm_coefficients.ptr);
    try std.testing.expectEqual(28, ms.adpcm_coefficients.len);

    const reduced = try parseFormat(pcm.extensible_pcm20[20..60]);
    try std.testing.expectEqual(Encoding.pcm_s24, reduced.encoding);
    try std.testing.expectEqual(20, reduced.valid_bits_per_sample);
    try std.testing.expectEqual(3, reduced.bytes_per_sample);
    try std.testing.expectEqual(2, try frameCount(reduced, 6));
    try std.testing.expectError(error.InvalidWave, frameCount(reduced, 5));
}
