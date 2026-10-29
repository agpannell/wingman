//! Independent libraries for checksums, binary containers and audio samples.
//!
//! Use adler32 or crc32 for format-specific checksums, and xxhash32 or xxhash64 for seeded hashes.
//! Each supports complete input and caller-owned streaming state; the checksum libraries also
//! combine separately processed sequences.
//!
//! Use riff for container framing, pcm for raw sample conversion, and g711 or adpcm for compressed
//! sample decoding. Callers supply the format geometry and own container and playback policy.
//!
//! RIFF views borrow input. Hash states copy pending bytes, and audio decoders write caller-owned
//! output. No library hides allocation. RIFF and PCM writing use the caller's std.Io.Writer.

pub const adler32 = @import("adler32.zig");
pub const crc32 = @import("crc32.zig");
pub const xxhash32 = @import("xxhash32.zig");
pub const xxhash64 = @import("xxhash64.zig");

pub const riff = @import("riff.zig");
pub const pcm = @import("pcm.zig");
pub const g711 = @import("g711.zig");
pub const adpcm = @import("adpcm.zig");

test {
    _ = adler32;
    _ = crc32;
    _ = xxhash32;
    _ = xxhash64;

    _ = riff;
    _ = pcm;
    _ = g711;
    _ = adpcm;
}
