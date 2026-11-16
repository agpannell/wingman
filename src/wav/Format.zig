//! Parsed WAVE sample representation, rate, channel count and optional speaker mask. Construct with
//! parse and preserve its admitted metadata. Each encoding carries the raw codec description used
//! for conversion; frame and block queries describe encoded geometry without validating samples or
//! applying a file's fact prefix. Microsoft coefficient bytes borrow the immutable fmt payload.
//! Copying this value copies that borrow. No allocation or cleanup is required.

const std = @import("std");
const lpcm = @import("../lpcm.zig");
const g711 = @import("../g711.zig");
const adpcm = @import("../adpcm.zig");
const fixtures = @import("fixtures.zig");
const Format = @This();
const testing = std.testing;

/// Source frame rate in frames per second.
sample_rate: u32,
/// Raw extensible speaker mask; null for ordinary formats, zero for unspecified speakers.
channel_mask: ?u32 = null,
/// Admitted codec and its complete sample or block description, including channel count.
encoding: Encoding,

/// InvalidWave is malformed format metadata; UnsupportedWave is an unimplemented encoding or
/// admitted-profile choice.
pub const Error = error{ InvalidWave, UnsupportedWave };

/// Incomplete encoded frames/blocks or a decoded frame count that cannot fit usize.
pub const CountError = error{ InvalidWave, SizeOverflow };

/// Encoded channel count. Decoding permits any nonzero extensible count; writePcm16 supports mono
/// and stereo. Use @backingInt for frame width; admitted multichannel values need not have a named
/// enum tag. This count carries no speaker-mask mapping.
pub const Channels = enum(u16) { mono = 1, stereo = 2, _ };

/// Validated representation selecting the conversion kernel. Only the active description applies.
pub const Encoding = union(enum) {
    /// Little-endian integer PCM or binary32 containers; conversion checks finite float values.
    lpcm: Lpcm,
    /// Eight-bit A-law or mu-law samples in interleaved channel order.
    g711: G711,
    /// Complete Microsoft or IMA/DVI WAVE blocks; coefficient bytes remain borrowed.
    adpcm: adpcm.Format,

    /// Channel layout and admitted raw LPCM representation.
    pub const Lpcm = struct {
        /// Interleaved sample values per decoded frame.
        channels: Channels,
        /// Container, high-aligned valid bits and little-endian byte order.
        sample_format: lpcm.Format,
    };

    /// Channel layout and admitted companding law.
    pub const G711 = struct {
        /// Interleaved sample values per decoded frame.
        channels: Channels,
        /// Selects the A-law or mu-law expansion table.
        law: g711.Law,
    };
};

/// One independent encoded unit. LPCM/G.711 units represent one frame; ADPCM units are complete
/// blocks containing seed headers and several frames.
pub const BlockLayout = struct {
    /// Complete encoded unit extent, including ADPCM headers.
    block_bytes: usize,
    /// Decoded frames per encoded unit, including ADPCM seed samples.
    frames_per_block: usize,
};

/// Returns the number of interleaved sample values in one decoded frame.
pub fn channels(self: Format) Channels {
    return switch (self.encoding) {
        .lpcm => |pcm| pcm.channels,
        .g711 => |companded| companded.channels,
        .adpcm => |block| @fromBackingInt(block.channels),
    };
}

/// Returns the complete unit used for data-chunk admission and parallel partitioning.
pub fn blockLayout(self: Format) BlockLayout {
    return switch (self.encoding) {
        .lpcm => |pcm| .{
            .block_bytes = @as(
                usize,
                @backingInt(pcm.channels),
            ) * pcm.sample_format.encoding.byteCount(),
            .frames_per_block = 1,
        },
        .g711 => |companded| .{
            .block_bytes = @backingInt(companded.channels),
            .frames_per_block = 1,
        },
        .adpcm => |block| .{
            .block_bytes = block.block_bytes,
            .frames_per_block = block.frames_per_block,
        },
    };
}

/// Counts complete decoded frames in one whole-frame or whole-block data chunk. ADPCM counts
/// include encoded padding frames. Zero bytes return zero frames. This does not inspect sample
/// bytes or apply a fact count; it describes geometry rather than successful sample conversion.
pub fn frameCount(self: Format, byte_count: usize) CountError!usize {
    // Parsing admitted codec geometry; each data chunk needs whole-unit and count checks.
    const layout = self.blockLayout();
    if (layout.block_bytes == 0 or byte_count % layout.block_bytes != 0) return error.InvalidWave;
    const blocks = byte_count / layout.block_bytes;
    if (self.encoding != .adpcm) return blocks;
    return std.math.mul(usize, blocks, layout.frames_per_block) catch error.SizeOverflow;
}

/// Admits one complete fmt payload without allocation or sample conversion. Extension coefficients
/// are borrowed; speaker-mask metadata is copied when present. The result needs no cleanup. Data
/// chunks, a container's fact count and output storage are admitted by complete-file decoding.
pub fn parse(source: []const u8) Error!Format {
    if (source.len < 16) return error.InvalidWave;
    const tag = readU16(source, 0);
    const channel_count = readU16(source, 2);
    if (channel_count == 0) return error.InvalidWave;
    const channel_layout: Channels = @fromBackingInt(channel_count);
    const sample_rate = readU32(source, 4);
    const block_bytes = readU16(source, 12);
    const bits_per_sample = readU16(source, 14);
    if (sample_rate == 0 or block_bytes == 0 or bits_per_sample == 0) return error.InvalidWave;

    const encoding: Encoding = switch (tag) {
        wave_format_pcm => try pcmDescription(channel_layout, bits_per_sample, bits_per_sample),
        wave_format_adpcm => blk: {
            if (bits_per_sample != 4 or channel_count > 2) return error.UnsupportedWave;
            const extension = try parseMsAdpcmExtension(source);
            break :blk .{
                .adpcm = .{
                    .encoding = .microsoft_wave,
                    .channels = channel_count,
                    .block_bytes = block_bytes,
                    .frames_per_block = extension.frames_per_block,
                    .coefficients = extension.coefficients,
                },
            };
        },
        wave_format_ima_adpcm => blk: {
            if (bits_per_sample != 4 or channel_count > 2) return error.UnsupportedWave;
            break :blk .{
                .adpcm = .{
                    .encoding = .ima_wave,
                    .channels = channel_count,
                    .block_bytes = block_bytes,
                    .frames_per_block = try parseImaFramesPerBlock(source),
                },
            };
        },
        wave_format_alaw, wave_format_mulaw => if (bits_per_sample == 8) .{
            .g711 = .{
                .channels = channel_layout,
                .law = if (tag == wave_format_alaw) .alaw else .mulaw,
            },
        } else return error.UnsupportedWave,
        wave_format_ieee_float => if (bits_per_sample == 32) .{
            .lpcm = .{
                .channels = channel_layout,
                .sample_format = .{ .encoding = .float32, .valid_bits = 32 },
            },
        } else return error.UnsupportedWave,
        wave_format_extensible => try parseExtensibleFormat(
            source,
            bits_per_sample,
            channel_layout,
        ),
        else => return error.UnsupportedWave,
    };
    if (channel_count > 2 and tag != wave_format_extensible) return error.UnsupportedWave;
    const result: Format = .{
        .sample_rate = sample_rate,
        .channel_mask = if (tag == wave_format_extensible) readU32(source, 20) else null,
        .encoding = encoding,
    };
    switch (encoding) {
        .adpcm => |block| {
            // WAVE admits extension records; the raw codec owns complete block geometry.
            block.validate() catch return error.InvalidWave;
        },
        .lpcm => |pcm| {
            const expected = std.math.mul(
                usize,
                channel_count,
                pcm.sample_format.encoding.byteCount(),
            ) catch return error.InvalidWave;
            if (block_bytes != expected) return error.InvalidWave;
        },
        .g711 => if (block_bytes != channel_count) return error.InvalidWave,
    }
    return result;
}

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

const MsAdpcmExtension = struct { frames_per_block: usize, coefficients: []const u8 };

fn parseMsAdpcmExtension(source: []const u8) Error!MsAdpcmExtension {
    const extra_byte_count = if (source.len >= 18) readU16(source, 16) else 0;
    if (extra_byte_count < 4 or source.len < 18 + @as(usize, extra_byte_count)) {
        return error.InvalidWave;
    }

    const frames_per_block = readU16(source, 18);
    const coefficient_count = readU16(source, 20);
    if (frames_per_block < 2 or coefficient_count == 0) return error.InvalidWave;
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
        .frames_per_block = frames_per_block,
        .coefficients = source[22..][0..coefficient_byte_count],
    };
}

fn parseImaFramesPerBlock(source: []const u8) Error!usize {
    const extra_byte_count = if (source.len >= 18) readU16(source, 16) else 0;
    if (extra_byte_count < 2 or source.len < 18 + @as(usize, extra_byte_count)) {
        return error.InvalidWave;
    }
    const frames_per_block = readU16(source, 18);
    if (frames_per_block == 0) return error.InvalidWave;
    return frames_per_block;
}

fn pcmDescription(channel_layout: Channels, bits_per_sample: u16, valid_bits: u16) Error!Encoding {
    // WAVE accepts a narrower profile than raw LPCM. Admit the container before narrowing
    // valid_bits.
    const encoding = try pcmEncoding(bits_per_sample);
    return .{
        .lpcm = .{
            .channels = channel_layout,
            .sample_format = .{ .encoding = encoding, .valid_bits = @intCast(valid_bits) },
        },
    };
}

fn pcmEncoding(bits_per_sample: u16) Error!lpcm.Format.Encoding {
    return switch (bits_per_sample) {
        8 => .unsigned8,
        16 => .signed16,
        24 => .signed24,
        32 => .signed32,
        else => error.UnsupportedWave,
    };
}

fn parseExtensibleFormat(
    source: []const u8,
    bits_per_sample: u16,
    channel_layout: Channels,
) Error!Encoding {
    const extra_byte_count = if (source.len >= 18) readU16(source, 16) else 0;
    const extension_end = std.math.add(
        usize,
        18,
        @as(usize, extra_byte_count),
    ) catch return error.InvalidWave;
    if (extra_byte_count < 22 or source.len < 40 or source.len < extension_end)
        return error.InvalidWave;
    const valid_bits = readU16(source, 18);
    const subformat = source[24..40];
    if (std.mem.eql(
        u8,
        subformat,
        &alaw_subformat_guid,
    ) or std.mem.eql(u8, subformat, &mulaw_subformat_guid)) {
        if (bits_per_sample != 8) return error.UnsupportedWave;
        // This union field is wSamplesPerBlock for compressed subformats, not PCM valid bits.
        return .{
            .g711 = .{
                .channels = channel_layout,
                .law = if (std.mem.eql(u8, subformat, &alaw_subformat_guid)) .alaw else .mulaw,
            },
        };
    }
    // Preserve wire-metadata refusal before selecting even an unsupported subformat.
    if (valid_bits == 0 or valid_bits > bits_per_sample) return error.InvalidWave;
    if (std.mem.eql(u8, subformat, &pcm_subformat_guid)) {
        return pcmDescription(channel_layout, bits_per_sample, valid_bits);
    }
    if (std.mem.eql(u8, subformat, &ieee_float_subformat_guid)) {
        if (bits_per_sample == 32 and valid_bits == bits_per_sample) return .{
            .lpcm = .{
                .channels = channel_layout,
                .sample_format = .{ .encoding = .float32, .valid_bits = 32 },
            },
        };
    }
    return error.UnsupportedWave;
}

fn readU16(source: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, source[offset..][0..2], .little);
}

fn readU32(source: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, source[offset..][0..4], .little);
}

test parse {
    const ms = try parse(fixtures.ms_adpcm_mono[20..70]);
    try testing.expect(ms.encoding == .adpcm);
    const block = ms.encoding.adpcm;
    try testing.expectEqual(adpcm.Format.Encoding.microsoft_wave, block.encoding);
    try testing.expectEqual(Channels.mono, ms.channels());
    try testing.expectEqual(
        BlockLayout{ .block_bytes = 9, .frames_per_block = 6 },
        ms.blockLayout(),
    );
    try testing.expectEqual(12, try ms.frameCount(18));
    try testing.expectError(error.InvalidWave, ms.frameCount(17));
    try testing.expectEqual(fixtures.ms_adpcm_mono[42..].ptr, block.coefficients.ptr);
    try testing.expectEqual(28, block.coefficients.len);

    const reduced = try parse(fixtures.extensible_pcm20[20..60]);
    try testing.expect(reduced.encoding == .lpcm);
    const sample_format = reduced.encoding.lpcm.sample_format;
    try testing.expectEqual(lpcm.Format.Encoding.signed24, sample_format.encoding);
    try testing.expectEqual(20, try sample_format.validBitCount());
    try testing.expectEqual(std.lang.Endian.little, sample_format.endian);
    try testing.expectEqual(
        BlockLayout{ .block_bytes = 3, .frames_per_block = 1 },
        reduced.blockLayout(),
    );
    try testing.expectEqual(2, try reduced.frameCount(6));
    try testing.expectError(error.InvalidWave, reduced.frameCount(5));
}

test frameCount {
    const ima = try parse(fixtures.ima_two_blocks[20..40]);
    try testing.expectEqual(
        BlockLayout{ .block_bytes = 8, .frames_per_block = 9 },
        ima.blockLayout(),
    );
    try testing.expectEqual(0, try ima.frameCount(0));
    try testing.expectEqual(18, try ima.frameCount(16));
    const largest_whole = std.math.maxInt(usize) - std.math.maxInt(usize) % 8;
    try testing.expectError(error.SizeOverflow, ima.frameCount(largest_whole));
}
