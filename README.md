# Wingman

Zig libraries for checksums, binary containers, audio and image metadata. Use each independently or
compose their views and conversion APIs, with explicit storage, lifetimes and format contracts.

## Libraries

Import libraries from `@import("wingman")`. The linked guides explain when to use each one, its
ownership and failure rules, and the ideas behind its implementation.

### Checksums and hashes

| Library and guide | Purpose | Example step |
| --- | --- | --- |
| [`adler32`](docs/adler32.md) | zlib checksums, streaming and checksum combination | `example` |
| [`crc32`](docs/crc32.md) | IEEE CRC-32 for gzip and PNG, streaming and combination | `crc32-example` |
| [`xxhash32`, `xxhash64`](docs/xxhash.md) | Classic seeded hashes with copied streaming state | `xxhash-example` |

These noncryptographic values detect accidental corruption or support lookups; matching values
do not establish input identity or authenticate a message. IEEE CRC-32 differs from CRC-32C and
the x86 instruction named CRC32.

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

Use `exif` for classic TIFF image attributes and stored thumbnail data. Callers extract the TIFF
payload from its enclosing image and choose orientation or profile transforms explicitly.

| Library and guide | Purpose | Example step |
| --- | --- | --- |
| [`exif`](docs/exif.md) | Borrowed fields, orientation, thumbnail ranges and supported RGB/YCbCr thumbnail pixels | `exif-example` |

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
Run one with `zig build <example-step>`; the checksum, hash and RIFF examples also accept text
after `--`.

The examples exercise complete public API calls: format-specific checksum bytes, seeded hashes,
nested chunks, sample quantization, compressed-block decoding, complete WAVE audio and image
attributes. Each checks its results as it runs. The [source files](examples/) are small standalone
starting points.

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
- RIFF and WAVE inspection views borrow encoded input. Keep it alive while using those views or
  the Microsoft coefficient bytes in a WAVE format description.
- Raw audio decoders write caller-provided storage. WAVE decoding offers either caller samples
  or an allocated `wav.Audio` owner independent of encoded input. Release that owner exactly once
  with the original allocator, after all sample views retire.
- Exif directories, field data and thumbnail rasters borrow TIFF input. Copied scalar values and
  returned RGB pixels are independent of those views.

Serial decoding needs no scheduler. Parallel WAVE conversion takes `std.Io`, caller-owned worker
storage and explicit options; every submitted job finishes before success, error or cancellation
returns. RIFF, PCM and WAVE writers use the caller's `std.Io.Writer`; callers choose its storage,
handle backend failures and flush it.

The guides specify numeric encoding, admitted regions and partial-output behavior for each API.
They also explain the mechanisms behind the contracts: vector sums, polynomial folding,
four-lane word mixing, checked chunk/directory extents, sample quantization, adaptive prediction
and precise thumbnail color.
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

Use `-Dtarget` and `-Dcpu` for a different compile-time target. Checksum kernels select portable
or SIMD implementations from that target; there is no runtime CPU dispatcher. A binary built
with additional CPU features requires those features on the machine that runs it. CI checks
baseline x86-64 Linux, including the separate consumer; its results do not establish support on
every architecture.

## License

[MIT](LICENSE). Algorithm and format references are credited beside the relevant source.
