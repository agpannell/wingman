//! Decode Microsoft and IMA/DVI ADPCM blocks, then encode a partial IMA block.
//!
//! Run `zig build adpcm-example` from the repository root. The bytes in this example are raw
//! WAVE-layout ADPCM blocks: they do not contain a WAVE header, sample rate or other container
//! metadata. A WAVE parser or another protocol normally supplies the block format and bytes.
//!
//! ADPCM represents audio as predicted samples and compact corrections. A frame has one sample per
//! channel; stereo samples are interleaved left, right, then the next frame. These examples are
//! mono, so each frame contains one sample. Both codecs write into caller-owned storage.
const std = @import("std");
const adpcm = @import("wingman").adpcm;
const pcm = @import("wingman").pcm;

pub fn main(init: std.process.Init) !void {
    // Microsoft blocks use a coefficient pair selected by each block header. This pair is (256, 0)
    // as signed little-endian i16 values; it predicts from the previous sample. IMA blocks use
    // their own index-based prediction and do not need the coefficient slice.
    const coefficients = [_]u8{ 0, 1, 0, 0 };
    const microsoft = [_]u8{ 0, 16, 0, 100, 0, 0x9c, 0xff, 0x12 };
    const ima = [_]u8{ 0, 0, 0, 0xff, 0x11, 0x11, 0x11, 0x11 };

    const cases = [_]struct {
        bytes: []const u8,
        format: adpcm.Format,
        expected: []const i16,
    }{ .{
        .bytes = &microsoft,
        .format = .{
            .encoding = .microsoft_wave,
            .channels = 1,
            .block_bytes = 8,
            .frames_per_block = 4,
            .coefficients = &coefficients,
        },
        .expected = &.{ -100, 100, 116, 148 },
    }, .{
        .bytes = &ima,
        .format = .{
            .encoding = .ima_wave,
            .channels = 1,
            .block_bytes = 8,
            .frames_per_block = 9,
        },
        .expected = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 },
    } };

    var output_buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &output_buffer);

    // Both inputs are complete eight-byte blocks, but the layouts represent different numbers of
    // frames because their headers and coded payloads have different geometry.
    for (cases) |case| {
        const block = case.bytes;
        const format = case.format;

        // frameCount validates the format and complete-block size without reading the headers. Each
        // frame needs one output slot per channel. Nine slots suffice for these mono blocks.
        const frame_count = try adpcm.frameCount(block.len, format);
        const sample_count = frame_count * format.channels;
        var sample_storage: [9]f32 = undefined;
        if (sample_storage.len < sample_count) return error.DestinationTooSmall;

        // decodeInto validates the block contents and returns the part of storage it used.
        const decoded_samples = try adpcm.decodeInto(block, &sample_storage, format);

        // Decoding yields normalized f32 samples on the exact PCM16 grid. This optional conversion
        // demonstrates writing those samples as two little-endian bytes each.
        var pcm_storage: [18]u8 = undefined;
        const pcm_format: pcm.Format = .{ .encoding = .signed16 };
        const pcm_bytes = try pcm.encodeInto(decoded_samples, &pcm_storage, pcm_format);

        for (case.expected, decoded_samples, 0..) |expected, sample, sample_index| {
            const normalized_expected = @as(f32, @floatFromInt(expected)) / 32768;
            if (sample != normalized_expected) return error.SampleMismatch;

            const byte_offset = sample_index * @sizeOf(i16);
            const pcm_value = std.mem.readInt(i16, pcm_bytes[byte_offset..][0..2], .little);
            if (pcm_value != expected) return error.PcmMismatch;
        }

        // A caller can request fewer frames to trim padding or save output space. The decoder still
        // validates the complete source, including blocks after the requested prefix.
        const prefix_frames: usize = 3;
        var prefix_storage: [3]f32 = undefined;
        const prefix_samples = try adpcm.decodePrefixInto(
            block,
            &prefix_storage,
            prefix_frames,
            format,
        );
        const decoded_prefix = decoded_samples[0..prefix_samples.len];
        if (!std.mem.eql(f32, decoded_prefix, prefix_samples)) return error.PrefixMismatch;

        // The returned slice counts interleaved samples, so divide by channels to count frames.
        const returned_frames = prefix_samples.len / format.channels;
        try output.interface.print(
            "{s}: {d} bytes -> {d} frames; prefix {d} frames validated\n",
            .{ @tagName(format.encoding), block.len, frame_count, returned_frames },
        );
        try output.interface.writeAll("PCM16:");
        for (case.expected) |value| try output.interface.print(" {d}", .{value});
        try output.interface.writeAll("\nlittle-endian bytes:");
        for (pcm_bytes) |byte| try output.interface.print(" {x:0>2}", .{byte});
        try output.interface.writeByte('\n');
    }

    // Encode three mono frames into an IMA block that represents nine frames. The .pad tail fills
    // the missing input frames with zero samples; .strict would reject this short input. Decoded
    // padding is lossy and is not guaranteed to be silent.
    const format: adpcm.Format = .{
        .encoding = .ima_wave,
        .channels = 1,
        .block_bytes = 8,
        .frames_per_block = 9,
    };
    const input_samples = [_]i16{ 1000, 1100, 1200 };
    const options: adpcm.EncodeOptions = .{ .strategy = .preview, .tail = .pad };

    // Requirements count interleaved samples and report exact output bytes and frame counts without
    // examining sample values. Check the caller-owned buffer before asking the encoder to write.
    const requirements = try adpcm.encodeRequirements(input_samples.len, format, options.tail);
    var encoded_storage: [8]u8 = undefined;
    if (encoded_storage.len < requirements.byte_count) return error.DestinationTooSmall;

    // Preview searches additional initial states. It keeps a candidate only when its squared error
    // on supplied frames is lower than fast; ties keep fast. It takes more work and does not
    // guarantee better perceived audio.
    const encoded = try adpcm.encodeI16Into(&input_samples, &encoded_storage, format, options);
    if (encoded.bytes.len != requirements.byte_count) return error.SizeMismatch;

    // The block represents nine frames even though the caller supplied three. Keep the original
    // frame count outside the raw bytes, then request that prefix. A WAVE container can carry the
    // count separately; this example does not write a WAVE file.
    const original_frames = encoded.frame_count;
    const encoded_frames = encoded.encoded_frame_count;
    var decoded_storage: [input_samples.len]f32 = undefined;
    const decoded_samples = try adpcm.decodePrefixInto(
        encoded.bytes,
        &decoded_storage,
        original_frames,
        format,
    );
    const returned_frames = decoded_samples.len / format.channels;
    try output.interface.print(
        "encoded {d} supplied frames in {d} bytes; {d} encoded frames, {d} returned\n",
        .{ original_frames, encoded.bytes.len, encoded_frames, returned_frames },
    );
    try output.interface.flush();
}
