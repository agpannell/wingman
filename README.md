# Wingman

Zig libraries for checksums, hashing, compression, binary containers, audio, image metadata, font
containers, texture containers and motion capture.
Use each independently or compose their views and conversion APIs, with explicit storage, lifetimes
and format contracts.

## Libraries

Import libraries from `@import("wingman")`. The linked guides explain when to use each one, its
ownership and failure rules, and the ideas behind its implementation.

### Checksums and hashes

| Library and guide | Purpose | Example step |
| --- | --- | --- |
| [`adler32`](docs/adler32.md) | zlib checksums, streaming and checksum combination | `example` |
| [`crc32`](docs/crc32.md) | IEEE CRC-32 for gzip and PNG, streaming and combination | `crc32-example` |
| [`xxhash32`, `xxhash64`](docs/xxhash.md) | Classic seeded hashes with copied streaming state | `xxhash-example` |
| [`blake3`](docs/blake3.md) | Cryptographic digests, keyed hashing, key derivation and seekable output | `blake3-example` |

Adler-32, CRC-32 and classic xxHash detect accidental corruption or support lookups; their
noncryptographic values do not establish input identity or authenticate a message. BLAKE3 provides
a cryptographic digest and separate keyed and key-derivation modes. IEEE CRC-32 differs from
CRC-32C and the x86 instruction named CRC32.

### Compression

Use `lz4` for compatible raw blocks or standard frames, and `deflate` for raw RFC 1951 streams.
Raw encodings rely on their enclosing record for boundaries and integrity; an LZ4 frame records
block geometry and optional checksums.

| Library and guide | Purpose | Example step |
| --- | --- | --- |
| [`lz4`](docs/lz4.md) | Raw/frame encoding and decoding, dictionaries, resumable codecs and bounded HC search | `lz4-example` |
| [`deflate`](docs/deflate.md) | Raw DEFLATE encoding and decoding, dictionaries and resumable streams | `deflate-example` |

### Audio files and containers

Use `wav` when you have a WAVE/RF64 audio file. Use `riff` for generic chunk framing in RIFF
formats such as WAVE or WebP; inspecting that envelope alone does not validate its payload.

| Library and guide | Purpose | Example step |
| --- | --- | --- |
| [`wav`](docs/wav.md) | Supported WAVE/RF64 audio decoding and PCM16 RIFF writing | `wav-example` |
| [`riff`](docs/riff.md) | Borrowed container/chunk traversal, nested lists and checked writing | `riff-example` |

### Audio samples

Use these libraries when the sample representation or block geometry is already known. The WAVE
loader composes them with file metadata; they can also serve other containers or protocols.

| Library and guide | Purpose | Example step |
| --- | --- | --- |
| [`pcm`](docs/pcm.md) | Little-endian integer/float sample conversion and PCM16 writing | `pcm-example` |
| [`g711`](docs/g711.md) | A-law and mu-law decoding to exact PCM16 or normalized floats | `g711-example` |
| [`adpcm`](docs/adpcm.md) | Microsoft and IMA/DVI WAVE block decoding, including validated frame prefixes | `adpcm-example` |

The raw codecs convert samples or complete blocks without parsing a file. Callers own playback,
resampling and speaker placement. The linked guides state supported layouts and numerical limits.

### Image metadata

Use `exif` for classic TIFF image attributes and stored thumbnail data, or `icc` for uncompressed
color-profile headers and raw tag bodies. Callers extract metadata from its container and choose
orientation or color transforms; inspection alone does not validate a complete color profile.

| Library and guide | Purpose | Example step |
| --- | --- | --- |
| [`exif`](docs/exif.md) | Borrowed fields, orientation, thumbnail ranges and supported RGB/YCbCr thumbnail pixels | `exif-example` |
| [`icc`](docs/icc.md) | Bounded v2/v4 profile headers, raw tag lookup and shared body storage | `icc-example` |

### Textures

Use `ktx2` to inspect or write texture containers carrying supplied mip levels, metadata and
format descriptors. Use `etc` to encode or decode individual ETC1 color and unsigned EAC
component blocks. Applications assemble image tiles and handle GPU upload.

| Library and guide | Purpose | Example step |
| --- | --- | --- |
| [`ktx2`](docs/ktx2.md) | Borrowed texture levels, metadata, descriptors and supplied-level writing | `ktx2-example` |
| [`etc`](docs/etc.md) | ETC1 color and unsigned EAC alpha8/R11 block encoding and decoding | `etc-example` |

### Font containers

Use `dfont` to select an SFNT resource from a Macintosh data-fork container. Use `sfnt` to
enumerate opaque font tables or select a TTC/OTC collection member before handing
its bytes to a table-specific reader. Opening checks storage ranges; it does not establish that a
font can render text. Checksums are explicit, and glyphs, layout and rendering stay with callers.

| Library and guide | Purpose | Example step |
| --- | --- | --- |
| [`sfnt`](docs/sfnt.md) | Borrowed table directories, collection faces, raw tag lookup and checksums | `sfnt-example` |
| [`dfont`](docs/dfont.md) | Borrowed SFNT resources from Macintosh data-fork containers | `dfont-example` |

### Motion capture

Use `bvh` for self-contained skeleton/motion clips, or `acclaim` to pair one ASF skeleton with
multiple AMC clips. Both evaluate joint poses using the package's `RigidTransform` type for
row-major binary64 rotation and translation. Their guides explain intrinsic BVH rotations and
Acclaim's fixed-axis calibration; applications choose coordinate conversion, interpolation and playback.

| Library and guide | Purpose | Example step |
| --- | --- | --- |
| [`bvh`](docs/bvh.md) | Owned skeletons and motion channels, caller-output local/global joint poses | `bvh-example` |
| [`acclaim`](docs/acclaim.md) | Paired ASF/AMC ownership, sparse samples and reusable prepared bone poses | `acclaim-example` |

## Try it

Use **Zig 0.17.0**, available from the [official downloads](https://ziglang.org/download/).
From this checkout:

```sh
zig version
zig build test --seed=0 --summary all
zig build example -- Wikipedia
zig build examples
```

The Adler-32 example checks streaming and checksum combination, then shows the zlib footer bytes
`11 e6 03 98` for `Wikipedia`. `zig build examples` runs every example in the tables above.
Run one with `zig build <example-step>`; the checksum, hash, LZ4, DEFLATE and RIFF examples also
accept text after `--`.

The examples exercise complete public API calls: format-specific checksum bytes, seeded hashes,
compressed blocks and frames, nested chunks, sample quantization, complete WAVE audio, image
attributes, shared font tables and skeletal movement. Each checks its results as it runs.
The [source files](examples/)
are small standalone starting points.

## Use it in a project

The [standalone consumer](examples/consumer/) shows a complete Zig build with a named `wingman`
dependency. It runs independently of the root test build:

```sh
cd examples/consumer
zig build test -Doptimize=ReleaseSafe --summary all
```

Use `dependency.module("wingman")` to import the package. The current API is pre-release; pin a
specific revision when taking a source dependency. For example:

```zig
const std = @import("std");
const adler32 = @import("wingman").adler32;

test "complete and streaming checksums" {
    const checksum = adler32.hash("Wikipedia");
    var stream: adler32.Hasher = .init;
    stream.update("Wiki");
    stream.update("pedia");
    try std.testing.expectEqual(@as(u32, 0x11e60398), checksum);
    try std.testing.expectEqual(checksum, stream.final());
}
```

## Ownership and implementation

Input byte slices need no padding or extra alignment. Storage and lifetimes are explicit:

- Checksum and hash states copy what they need; input chunks can be released after `update` returns.
- LZ4 complete calls retain no input; resumable owners borrow their workspace and copy accepted
  fragments. Output stays private until completion and any required integrity checks succeed.
- RIFF and WAVE inspection views borrow encoded input. Keep it alive while using those views or
  the Microsoft coefficient bytes in a WAVE format description.
- Raw audio decoders write caller-provided storage. WAVE decoding offers either caller samples
  or an allocated `wav.Audio` owner independent of encoded input. Release that owner exactly once
  with the original allocator, after all sample views retire.
- KTX2 source views borrow the complete input; allocating writes return caller-owned bytes.
- DFONT containers and selected font resources borrow complete immutable resource-file bytes.
  SFNT directories, collection faces and raw tables borrow complete immutable font/container bytes.
  Copied tags, checksums and flavor values are independent; no allocator or cleanup is retained.
- Exif directories, field data and thumbnail rasters borrow TIFF input; ICC profiles and tag bodies
  borrow complete uncompressed profile bytes. Copied headers/scalars and returned RGB pixels are
  independent of those views.
- BVH motions own their skeleton and samples. Acclaim skeletons own shared backing; clips and
  evaluators borrow it and must retire first. Each owner is released once with its construction
  allocator. Views borrow their owner; completed pose output is independent caller storage.
  Rigid transforms retain no storage or allocator.

Serial hashing and decoding need no scheduler. Parallel BLAKE3 updates and WAVE conversion take
`std.Io`, caller-owned worker storage and explicit options; every submitted job finishes before
success, error or cancellation returns. RIFF, PCM and WAVE writers use the caller's `std.Io.Writer`;
callers choose its storage, handle backend failures and flush it.

The guides specify numeric encoding, admitted regions and partial-output behavior for each API.
They also explain the mechanisms behind the contracts: vector sums, polynomial folding,
four-lane word mixing, binary hash trees, checked chunk/directory extents, sample quantization,
adaptive prediction, overlapping LZ4 matches and bounded HC parsing, precise thumbnail color,
declared-order skeletal rotations, sparse-frame completion and reusable axis calibration.
Tests stay with their implementations and include independent values, scalar comparisons,
state and storage boundaries, and protected-page input checks where applicable.

Generate the API reference with `zig build docs`. Serve `zig-out/docs` over HTTP, for example
with `python3 -m http.server --directory zig-out/docs 8000`, then open
`http://localhost:8000`.

## Contributing and validation

Tests and examples use Zig 0.17.0 with LLVM. Format Zig and Markdown to 100 columns. Run the tests
in checked and optimized modes, every example, and the generated reference:

```sh
zig fmt --check build.zig build.zig.zon src examples
zig build test -Doptimize=ReleaseSafe --seed=0 --summary all
zig build test -Doptimize=ReleaseFast --seed=0 --summary all
zig build examples
zig build docs
```

Use `-Dtarget` and `-Dcpu` for a different compile-time target. Hash and checksum kernels select portable
or SIMD implementations from that target; there is no runtime CPU dispatcher. A binary built
with additional CPU features requires those features on the machine that runs it. CI checks
baseline x86-64 Linux, including the separate consumer; its results do not establish support on
every architecture.

## License

[MIT](LICENSE). Algorithm and format references are credited beside the relevant source.
