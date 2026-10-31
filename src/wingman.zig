//! Independent libraries for checksums, hashing, compression, containers, audio, image metadata,
//! font containers, texture containers and motion capture.
//!
//! adler32 and crc32 provide format-specific checksums; xxhash32 and xxhash64 provide seeded
//! hashes. Each supports complete input and caller-owned streaming state, and the checksum
//! libraries combine separately processed sequences. blake3 provides cryptographic hashing, keyed
//! authentication and context-separated key derivation with seekable output.
//!
//! lz4 provides raw blocks and standard frames, with dictionaries, bounded HC encoding and
//! resumable codecs using caller-owned storage. deflate encodes and decodes raw RFC 1951 streams;
//! zlib adds RFC 1950 framing, checksum verification and dictionary negotiation; gzip provides RFC
//! 1952 members with CRC-32, optional metadata and concatenation.
//!
//! wav connects WAVE/RF64 containers to sample decoding and PCM16 RIFF writing. riff provides
//! generic chunk framing. pcm, g711 and adpcm convert raw sample representations or complete codec
//! blocks when the layout is already known; playback and resampling stay with callers.
//!
//! exif borrows classic TIFF attributes and thumbnail storage, including supported RGB/YCbCr
//! thumbnail samples. icc inspects bounded uncompressed color-profile headers and opaque tag
//! bodies. Orientation, complete profile validation and color transforms stay with callers.
//!
//! dfont selects borrowed SFNT resources from Macintosh data-fork resource containers. sfnt borrows
//! SFNT table directories and TTC/OTC collection members. Table payloads remain opaque, with
//! explicit checksums; glyph interpretation, shaping and rendering stay with callers.
//!
//! ktx2 inspects and writes texture containers with caller-supplied encoded mip levels. etc encodes
//! and decodes ETC1 color and unsigned EAC component blocks.
//!
//! bvh owns self-contained skeletal motion; acclaim pairs reusable ASF skeletons with AMC clips and
//! cached pose calibration. Both write local/global RigidTransform values into caller storage,
//! retaining their distinct rotation and unit contracts. Playback, interpolation, retargeting and
//! producer coordinate conversion stay with callers.
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
pub const deflate = @import("deflate.zig");
pub const zlib = @import("zlib.zig");
pub const gzip = @import("gzip.zig");

pub const wav = @import("wav.zig");
pub const riff = @import("riff.zig");

pub const pcm = @import("pcm.zig");
pub const g711 = @import("g711.zig");
pub const adpcm = @import("adpcm.zig");

pub const exif = @import("exif.zig");
pub const icc = @import("icc.zig");

pub const ktx2 = @import("ktx2.zig");
pub const etc = @import("etc.zig");

pub const dfont = @import("dfont.zig");
pub const sfnt = @import("sfnt.zig");

pub const bvh = @import("bvh.zig");
pub const acclaim = @import("acclaim.zig");
pub const RigidTransform = @import("common/rigid_transform.zig").RigidTransform;

test {
    _ = adler32;
    _ = crc32;
    _ = xxhash32;
    _ = xxhash64;
    _ = blake3;

    _ = lz4;
    _ = deflate;
    _ = zlib;
    _ = gzip;

    _ = wav;
    _ = riff;

    _ = pcm;
    _ = g711;
    _ = adpcm;

    _ = exif;
    _ = icc;

    _ = ktx2;
    _ = etc;

    _ = dfont;
    _ = sfnt;

    _ = bvh;
    _ = acclaim;
    _ = @import("common/rigid_transform.zig");
}
