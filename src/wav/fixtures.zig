//! Independent RIFF/WAVE PCM bytes and RF64 test-container construction. Stereo: 48 kHz, (-1, +1),
//! (-.5, +.5), (0, .25). Mono: empty, 8 kHz.
const std = @import("std");

/// One authored RF64 directory record, independent of physical chunk order.
pub const Rf64Size = struct {
    /// Four-byte ID matched by sentinel chunks.
    id: [4]u8,
    /// Declared replacement payload length.
    size: u64,
};

/// One physical metadata chunk. Explicit sizes bypass the RF64 directory.
pub const Rf64Chunk = struct {
    /// Four-byte physical chunk ID.
    id: [4]u8,
    /// Borrowed payload, excluding word padding.
    data: []const u8,
    /// Writes 0xffffffff instead of the payload length.
    sentinel: bool = true,
};

/// Builds allocator-owned RF64 bytes with the supplied directory and metadata, followed by a
/// literal mono PCM8 format and one `0xff` sample. Inputs are borrowed only during this call.
/// Directory sizes are written as supplied, including deliberately invalid test extents.
pub fn makeRf64Metadata(
    allocator: std.mem.Allocator,
    table: []const Rf64Size,
    chunks: []const Rf64Chunk,
) ![]u8 {
    const count = std.math.cast(u32, table.len) orelse return error.SizeOverflow;
    const table_bytes = std.math.mul(u32, count, 12) catch return error.SizeOverflow;
    const directory_size = std.math.add(u32, 28, table_bytes) catch return error.SizeOverflow;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("RF64\xff\xff\xff\xffWAVEds64");
    try writer.writeInt(u32, directory_size, .little);
    try writer.writeInt(u64, 0, .little); // Patched complete container size.
    try writer.writeInt(u64, 1, .little);
    try writer.writeInt(u64, 1, .little);
    try writer.writeInt(u32, count, .little);
    for (table) |entry| {
        try writer.writeAll(&entry.id);
        try writer.writeInt(u64, entry.size, .little);
    }
    for (chunks) |chunk| {
        const size = std.math.cast(u32, chunk.data.len) orelse return error.SizeOverflow;
        try writer.writeAll(&chunk.id);
        try writer.writeInt(u32, if (chunk.sentinel) std.math.maxInt(u32) else size, .little);
        try writer.writeAll(chunk.data);
        if (size & 1 != 0) try writer.writeByte(0);
    }
    try writer.writeAll(
        "fmt " ++
            "\x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00dat" ++
            "a\xff\xff\xff\xff\xff\x00",
    );
    const source = try output.toOwnedSlice();
    std.mem.writeInt(u64, source[20..28], @intCast(source.len - 8), .little);
    return source;
}

pub const stereo =
    "RIFF\x30\x00\x00\x00WAVEfmt " ++
    "\x10\x00\x00\x00\x01\x00\x02\x00\x80\xbb\x00\x00\x00\xee\x02\x00\x04\x00\x10\x00data" ++
    "\x0c\x00\x00\x00\x00\x80\xff\x7f\x00\xc0\x00\x40\x00\x00\x00\x20";

/// The same three stereo frames split across two frame-aligned data chunks.
pub const stereo_split_data =
    "RIFF\x38\x00\x00\x00WAVEfmt " ++
    "\x10\x00\x00\x00\x01\x00\x02\x00\x80\xbb\x00\x00\x00\xee\x02\x00\x04\x00\x10\x00data" ++
    "\x04\x00\x00\x00\x00\x80\xff\x7fdata\x08\x00\x00\x00\x00\xc0\x00\x40\x00\x00\x00\x20";

/// The same stereo samples as `stereo`, preceded by an empty data chunk.
pub const stereo_empty_data =
    "RIFF\x38\x00\x00\x00WAVEfmt " ++
    "\x10\x00\x00\x00\x01\x00\x02\x00\x80\xbb\x00\x00\x00\xee\x02\x00\x04\x00\x10\x00data" ++
    "\x00\x00\x00\x00data\x0c\x00\x00\x00\x00\x80\xff\x7f\x00\xc0\x00\x40\x00\x00\x00\x20";

/// Two data chunks whose combined length is valid but whose individual lengths do not contain whole
/// stereo frames.
pub const stereo_split_unaligned =
    "RIFF\x38\x00\x00\x00WAVEfmt " ++
    "\x10\x00\x00\x00\x01\x00\x02\x00\x80\xbb\x00\x00\x00\xee\x02\x00\x04\x00\x10\x00data" ++
    "\x02\x00\x00\x00\x00\x80data\x0a\x00\x00\x00\xff\x7f\x00\xc0\x00\x40\x00\x00\x00\x20";

/// RF64 stereo PCM with a `ds64` chunk-table entry for an odd-sized unknown chunk and a sentinel
/// `data` size resolved from the mandatory directory.
pub const rf64_stereo_with_table =
    "RF64\xff\xff\xff\xffWAVEds64\x28\x00\x00\x00\x6c\x00\x00\x00\x00\x00\x00\x00\x0c\x00\x00" ++
    "\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00JUNK\x03\x00\x00" ++
    "\x00\x00\x00\x00\x00JUNK\xff\xff\xff\xff\x7f\x01\x02\x00fmt " ++
    "\x10\x00\x00\x00\x01\x00\x02\x00\x80\xbb\x00\x00\x00\xee\x02\x00\x04\x00\x10\x00data" ++
    "\xff\xff\xff\xff\x00\x80\xff\x7f\x00\xc0\x00\x40\x00\x00\x00\x20";

/// Two mono PCM8 RF64 data chunks: the first uses ds64 dataSize and the second carries its own
/// 32-bit length.
pub const rf64_split_data =
    "RF64\xff\xff\xff\xffWAVEds64\x1c\x00\x00\x00\x54\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00" ++
    "\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00fmt " ++
    "\x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00data" ++
    "\xff\xff\xff\xff\x80\x00data\x01\x00\x00\x00\xff\x00";

/// Independently assembled 82-byte RF64: explicit outer size 74 and data size one take precedence
/// over the unused ds64 replacements (zero and nine). Mono PCM8 at 8 kHz carries 0xff plus a zero
/// pad. EBU Tech 3306 v1.1 section 3.4 applies this precedence to all three mandatory replacements.
/// https://tech.ebu.ch/docs/tech/tech3306v1_1.pdf
pub const rf64_explicit_lengths =
    "RF64\x4a\x00\x00\x00WAVEds64\x1c\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x09" ++
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00fmt " ++
    "\x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00data" ++
    "\x01\x00\x00\x00\xff\x00";

/// RF64 directory entries for repeated unknown chunk IDs with different sizes.
pub const rf64_repeated_unknown_chunks =
    "RF64\xff\xff\xff\xffWAVEds64\x40\x00\x00\x00\x94\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00" ++
    "\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00JUNK\x03\x00\x00" ++
    "\x00\x00\x00\x00\x00JUNK\x05\x00\x00\x00\x00\x00\x00\x00FILL\x04\x00\x00\x00\x00\x00" ++
    "\x00\x00JUNK\xff\xff\xff\xffabc\x00FILL\xff\xff\xff\xff1234JUNK\xff\xff\xff\xffdefgh" ++
    "\x00fmt " ++
    "\x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00data" ++
    "\x01\x00\x00\x00\x80\x00";

pub const empty_mono =
    "RIFF\x24\x00\x00\x00WAVEfmt " ++
    "\x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x80\x3e\x00\x00\x02\x00\x10\x00data" ++
    "\x00\x00\x00\x00";

/// Mono PCM8 data before its format chunk, with an odd-sized unknown chunk.
pub const padded_mono_u8 =
    "RIFF\x32\x00\x00\x00WAVEJUNK\x01\x00\x00\x00\x7f\x00data\x03\x00\x00\x00\x00\x80\xff\x00fm" ++
    "t \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00";

/// Mono 8-bit ITU-T G.711 mu-law samples in a WAVE_FORMAT_MULAW stream.
pub const mulaw_mono =
    "RIFF\x28\x00\x00\x00WAVEfmt " ++
    "\x10\x00\x00\x00\x07\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00data" ++
    "\x04\x00\x00\x00\xff\x7f\x00\x80";

/// Mono 8-bit ITU-T G.711 A-law samples in a WAVE_FORMAT_ALAW stream.
pub const alaw_mono =
    "RIFF\x28\x00\x00\x00WAVEfmt " ++
    "\x10\x00\x00\x00\x06\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00data" ++
    "\x04\x00\x00\x00\xd5\x55\x00\x80";

/// Mono 8-bit ITU-T G.711 samples in WAVEFORMATEXTENSIBLE subformat GUIDs.
pub const extensible_mulaw_mono =
    "RIFF\x40\x00\x00\x00WAVEfmt " ++
    "\x28\x00\x00\x00\xfe\xff\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00\x16" ++
    "\x00\x08\x00\x00\x00\x00\x00\x07\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38" ++
    "\x9b\x71data\x04\x00\x00\x00\xff\x7f\x00\x80";

pub const extensible_alaw_mono =
    "RIFF\x40\x00\x00\x00WAVEfmt " ++
    "\x28\x00\x00\x00\xfe\xff\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00\x16" ++
    "\x00\x08\x00\x00\x00\x00\x00\x06\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38" ++
    "\x9b\x71data\x04\x00\x00\x00\xd5\x55\x00\x80";

/// One negative and positive sample at the start of every G.711 A-law segment, with the segment-one
/// bias included in the expected decoder law.
pub const alaw_segment_boundaries =
    "RIFF\x34\x00\x00\x00WAVEfmt " ++
    "\x10\x00\x00\x00\x06\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00data" ++
    "\x10\x00\x00\x00\x55\xd5\x45\xc5\x75\xf5\x65\xe5\x15\x95\x05\x85\x35\xb5\x25\xa5";

/// Mono 24-bit PCM in a WAVEFORMATEXTENSIBLE PCM wrapper.
pub const extensible_pcm24 =
    "RIFF\x46\x00\x00\x00WAVEfmt " ++
    "\x28\x00\x00\x00\xfe\xff\x01\x00\x80\xbb\x00\x00\x80\x32\x02\x00\x03\x00\x18\x00\x16" ++
    "\x00\x18\x00\x04\x00\x00\x00\x01\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38" ++
    "\x9b\x71data\x09\x00\x00\x00\x00\x00\x80\x00\x00\x00\xff\xff\x7f\x00";

/// Mono 20-bit PCM left-aligned in a 24-bit WAVEFORMATEXTENSIBLE container.
pub const extensible_pcm20 =
    "RIFF\x42\x00\x00\x00WAVEfmt " ++
    "\x28\x00\x00\x00\xfe\xff\x01\x00\x80\xbb\x00\x00\x80\x32\x02\x00\x03\x00\x18\x00\x16" ++
    "\x00\x14\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38" ++
    "\x9b\x71data\x06\x00\x00\x00\x00\x00\x80\xf0\xff\x7f";

/// Mono 4-bit unsigned PCM left-aligned in an 8-bit WAVEFORMATEXTENSIBLE container.
pub const extensible_pcm4_u8 =
    "RIFF\x40\x00\x00\x00WAVEfmt " ++
    "\x28\x00\x00\x00\xfe\xff\x01\x00\x80\xbb\x00\x00\x80\xbb\x00\x00\x01\x00\x08\x00\x16" ++
    "\x00\x04\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38" ++
    "\x9b\x71data\x03\x00\x00\x00\x00\x80\xf0\x00";

/// One 5.1 PCM16 frame in a WAVEFORMATEXTENSIBLE channel order.
pub const extensible_pcm6 =
    "RIFF\x48\x00\x00\x00WAVEfmt " ++
    "\x28\x00\x00\x00\xfe\xff\x06\x00\x80\xbb\x00\x00\x00\xca\x08\x00\x0c\x00\x10\x00\x16" ++
    "\x00\x10\x00\x3f\x00\x00\x00\x01\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38" ++
    "\x9b\x71data\x0c\x00\x00\x00\x00\x80\x00\xc0\x00\x00\x00\x40\xff\x7f\xff\xff";

/// Mono 32-bit IEEE-float data in a WAVEFORMATEXTENSIBLE float wrapper.
pub const extensible_float32 =
    "RIFF\x40\x00\x00\x00WAVEfmt " ++
    "\x28\x00\x00\x00\xfe\xff\x01\x00\x00\xbb\x00\x00\x00\xee\x02\x00\x04\x00\x20" ++
    "\x00\x16\x00\x20" ++
    "\x00\x04\x00\x00\x00\x03\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71dat" ++
    "a\x04\x00\x00\x00\x00\x00\x00\x3f";

/// Regular WAVE_FORMAT_IEEE_FLOAT data, including a finite sample above 1.
pub const float32 =
    "RIFF\x30\x00\x00\x00WAVEfmt " ++
    "\x10\x00\x00\x00\x03\x00\x01\x00\x44\xac\x00\x00\x10\xb1\x02\x00\x04\x00\x20" ++
    "\x00data\x0c\x00\x00\x00\x00\x00\x00\xbf\x00\x00\x80\x3e\x00\x00\x00\x40";

/// One mono IMA ADPCM block with nine samples and a nontrivial nibble stream.
pub const ima_adpcm_mono =
    "RIFF\x30\x00\x00\x00WAVEfmt " ++
    "\x14\x00\x00\x00\x11\x00\x01\x00\x40\x1f\x00\x00\xc7\x1b\x00\x00\x08\x00\x04\x00\x02" ++
    "\x00\x09\x00data\x08\x00\x00\x00\x00\x00\x00\x00\x11\x23\x48\x7f";

/// One stereo IMA ADPCM block. The four-byte encoded channel groups are interleaved after both
/// channel headers.
pub const ima_adpcm_stereo =
    "RIFF\x38\x00\x00\x00WAVEfmt " ++
    "\x14\x00\x00\x00\x11\x00\x02\x00\x40\x1f\x00\x00\x8e\x37\x00\x00\x10\x00\x04\x00\x02" ++
    "\x00\x09" ++
    "\x00data\x10\x00\x00\x00\x00\x00\x00\x00\xe8\x03\x00\x00\x11\x23\x48\x7f\x11\x23\x48" ++
    "\x7f";

/// One mono MS-ADPCM block using the standard seven coefficient pairs.
pub const ms_adpcm_mono =
    "RIFF\x50\x00\x00\x00WAVEfmt " ++
    "\x32\x00\x00\x00\x02\x00\x01\x00\x40\x1f\x00\x00\xe0\x2e\x00\x00\x09\x00\x04\x00\x20" ++
    "\x00\x06\x00\x07\x00\x00\x01\x00\x00\x00\x02\x00\xff\x00\x00\x00\x00\xc0\x00\x40\x00" ++
    "\xf0\x00\x00\x00\xcc\x01\x30\xff\x88\x01\x18\xffdata\x09" ++
    "\x00\x00\x00\x00\xe8\x03\xe8\x03\xd0\x07\x01\xf8\x00";

/// One stereo MS-ADPCM block with planar channel headers and interleaved
/// high-nibble-left/low-nibble-right samples.
pub const ms_adpcm_stereo =
    "RIFF\x56\x00\x00\x00WAVEfmt " ++
    "\x32\x00\x00\x00\x02\x00\x02\x00\x40\x1f\x00\x00\x00\x7d\x00\x00\x10\x00\x04\x00\x20" ++
    "\x00\x04\x00\x07\x00\x00\x01\x00\x00\x00\x02\x00\xff\x00\x00\x00\x00\xc0\x00\x40\x00" ++
    "\xf0\x00\x00\x00\xcc\x01\x30\xff\x88\x01\x18\xffdata\x10\x00\x00\x00\x00\x00\x00\x01" ++
    "\x00\x02\xe8\x03\x18\xfc\xd0\x07\x30\xf8\x00\x1f";

// Fixed ADPCM fact counts over independently authored encoded blocks. Microsoft Multimedia
// Standards Update revision 3.0 defines the count in frames; EBU Tech 3306 section 3.4 replaces its
// RF64 sentinel through ds64.
// https://mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/Docs/RIFFNEW.pdf, page 12.
// https://tech.ebu.ch/files/live/sites/tech/files/shared/tech/tech3306v1_1.pdf, section 3.4. The
// IMA geometry fixtures use revision 3.0 pages 31-32: each channel has a four-byte seed header,
// followed by zero or more complete four-byte data words. The Microsoft prediction fixtures use all
// seven standard coefficient pairs from pages 23-25, with positive and negative seeds and
// fractional predictions. Fixed little-endian PCM references use signed division toward zero and
// match FFmpeg n9.0.2. They cover 28 mono blocks and 14 stereo blocks, each with 18 frames. Blocks
// select predictors 4, 3, 5, 6, 0, 1, 2 with initial delta 37. Mono seed pairs (iSamp1, iSamp2) are
// (-1, -1), (1, 1), (-1001, -1000), (1001, 1000). Stereo uses the two negative pairs in its first
// channel and their opposites in its second. Each channel's nibbles are 0001ff1198700842 in time
// order.

/// Mono Microsoft ADPCM blocks exercising signed fractional prediction and feedback.
pub const ms_prediction_mono = @embedFile("fixtures/ms_prediction_mono.wav");

/// Independent signed PCM16 reference for every mono prediction-fixture sample.
pub const ms_prediction_mono_samples = @embedFile("fixtures/ms_prediction_mono.s16le");

/// Stereo Microsoft ADPCM blocks with opposite seed signs and independent channel state.
pub const ms_prediction_stereo = @embedFile("fixtures/ms_prediction_stereo.wav");

/// Independent interleaved signed PCM16 reference for the stereo prediction fixture.
pub const ms_prediction_stereo_samples = @embedFile("fixtures/ms_prediction_stereo.s16le");

/// Two mono blocks containing only their seed headers, one frame in each block.
pub const ima_header_mono = @embedFile("fixtures/ima_header_mono.wav");

/// Two stereo seed-only blocks with independent headers in source channel order.
pub const ima_header_stereo = @embedFile("fixtures/ima_header_stereo.wav");

/// One published stereo frame; the second seed-only block is encoded padding.
pub const ima_header_stereo_fact = @embedFile("fixtures/ima_header_stereo_fact.wav");

/// A malformed mono block declares three frames but supplies only one data-word byte.
pub const ima_partial_word =
    "RIFF\x2e\x00\x00\x00WAVEfmt " ++
    "\x14\x00\x00\x00\x11\x00\x01\x00\x40\x1f\x00\x00\x15\x34\x00\x00\x05\x00\x04\x00\x02" ++
    "\x00\x03\x00data\x05\x00\x00\x00\x00\x00\x00\x00\x11\x00";

/// Three valid mono frames within a complete nine-frame IMA block.
pub const ima_mono = "RIFF\x3c\x00\x00\x00" ++
    ima_adpcm_mono[8..40] ++
    "fact\x04\x00\x00\x00\x03\x00\x00\x00" ++
    ima_adpcm_mono[40..];

/// Unknown fact extension bytes follow the count and do not change its meaning.
pub const extended_fact = "RIFF\x3e\x00\x00\x00" ++
    ima_adpcm_mono[8..40] ++
    "fact\x06\x00\x00\x00\x03\x00\x00\x00\xff\x80" ++
    ima_adpcm_mono[40..];

/// Five valid stereo frames, with the fact chunk following the data chunk.
pub const ima_stereo = "RIFF\x44\x00\x00\x00" ++
    ima_adpcm_stereo[8..] ++
    "fact\x04\x00\x00\x00\x05\x00\x00\x00";

/// Five valid mono frames within a complete six-frame Microsoft block.
pub const ms_mono = "RIFF\x5c\x00\x00\x00WAVEfact\x04\x00\x00\x00\x05\x00\x00\x00" ++
    ms_adpcm_mono[12..];

/// Three valid stereo frames within a complete four-frame Microsoft block.
pub const ms_stereo = "RIFF\x62\x00\x00\x00" ++
    ms_adpcm_stereo[8..70] ++
    "fact\x04\x00\x00\x00\x03\x00\x00\x00" ++
    ms_adpcm_stereo[70..];

/// RF64 fact sentinel resolves to three frames through ds64's sampleCount.
pub const rf64_ima_mono =
    ("RF64\xff\xff\xff\xffWAVEds64\x1c\x00\x00\x00\x60\x00\x00\x00\x00\x00\x00\x00\x08\x00" ++
        "\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00") ++
    ima_adpcm_mono[12..40] ++
    "fact\x04\x00\x00\x00\xff\xff\xff\xff" ++
    ima_adpcm_mono[40..];

/// Twelve valid frames spanning two complete nine-frame blocks in one chunk.
pub const ima_two_blocks = @embedFile("fixtures/ima_two_blocks.wav");

/// The same two encoded blocks in separate data chunks share one fact count.
pub const ima_split_data = "RIFF\x4c\x00\x00\x00" ++
    ima_adpcm_mono[8..40] ++
    "fact\x04\x00\x00\x00\x0c\x00\x00\x00" ++
    ima_adpcm_mono[40..] ++
    ima_adpcm_mono[40..];

/// A fact chunk truncated before its four-byte sample count.
pub const short_fact = "RIFF\x3a\x00\x00\x00" ++
    ima_adpcm_mono[8..40] ++
    "fact\x02\x00\x00\x00\x03\x00" ++
    ima_adpcm_mono[40..];

/// Two fact chunks cannot describe one unambiguous output length.
pub const duplicate_fact = "RIFF\x48\x00\x00\x00" ++
    ima_mono[8..] ++
    "fact\x04\x00\x00\x00\x03\x00\x00\x00";
