//! Independent libraries for checksums, hashing, compression, containers, audio and image metadata.
//!
//! adler32 and crc32 provide format-specific checksums; xxhash32 and xxhash64 provide seeded
//! hashes. Each supports complete input and caller-owned streaming state, and the checksum
//! libraries combine separately processed sequences. blake3 provides cryptographic hashing, keyed
//! authentication and context-separated key derivation with seekable output.
//!
//! lz4 provides raw blocks and standard frames, with dictionaries, bounded HC encoding and
//! resumable codecs using caller-owned storage.
//!
//! wav connects WAVE/RF64 containers to sample decoding and PCM16 RIFF writing. riff provides
//! generic chunk framing. pcm, g711 and adpcm convert raw sample representations or complete codec
//! blocks when the layout is already known; playback and resampling stay with callers.
//!
//! exif borrows classic TIFF image attributes and thumbnail storage without allocation. It samples
//! supported uncompressed RGB/YCbCr thumbnails; orientation and profile transforms stay with
//! callers.
//!
//! Container views and WAVE format coefficients can borrow encoded input. Decoded WAVE views borrow
//! output samples; allocated Audio owners are released with the original allocator. Parallel WAVE
//! conversion and BLAKE3 updates use std.Io and bounded caller workers, joining every job before
//! return. Writer APIs use the caller's std.Io.Writer and leave flushing to the caller.

pub const adler32 = @import("adler32.zig");
pub const crc32 = @import("crc32.zig");
pub const xxhash32 = @import("xxhash32.zig");
pub const xxhash64 = @import("xxhash64.zig");
pub const blake3 = @import("blake3.zig");

pub const lz4 = @import("lz4.zig");

pub const wav = @import("wav.zig");
pub const riff = @import("riff.zig");

pub const pcm = @import("pcm.zig");
pub const g711 = @import("g711.zig");
pub const adpcm = @import("adpcm.zig");

pub const exif = @import("exif.zig");

test {
    _ = adler32;
    _ = crc32;
    _ = xxhash32;
    _ = xxhash64;
    _ = blake3;

    _ = lz4;

    _ = wav;
    _ = riff;

    _ = pcm;
    _ = g711;
    _ = adpcm;

    _ = exif;
}
