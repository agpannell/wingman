# Wingman

Zig libraries for checksums, binary containers and audio samples. Use each library independently,
with explicit input lifetimes, caller-owned storage and documented format contracts.

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

### Containers and audio

| Library and guide | Purpose | Example step |
| --- | --- | --- |
| [`riff`](docs/riff.md) | Borrowed container/chunk traversal, nested lists and checked writing | `riff-example` |
| [`pcm`](docs/pcm.md) | Little-endian integer/float sample conversion and PCM16 writing | `pcm-example` |
| [`g711`](docs/g711.md) | A-law and mu-law decoding to exact PCM16 or normalized floats | `g711-example` |
| [`adpcm`](docs/adpcm.md) | Microsoft and IMA/DVI WAVE block decoding, including validated frame prefixes | `adpcm-example` |

RIFF handles container framing; payload interpretation belongs to its caller. The audio libraries
convert sample representations. Callers supply the required layout or block geometry and own
container, sample-rate and playback policy. A valid RIFF envelope alone does not establish a valid
media file, and the ADPCM library accepts complete blocks rather than parsing a WAVE file.

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
nested chunks, sample quantization and compressed-block decoding with PCM16 output. Each checks
its results as it runs. The [source files](examples/) are small standalone starting points.

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

The libraries accept exact, unaligned input bytes and perform no hidden allocation. Hash and
checksum states copy what they need, so an input chunk can be released after `update` returns.
RIFF views borrow their input; keep that storage alive while using the views. Audio conversion
writes caller-provided output. RIFF and PCM writing use the caller's `std.Io.Writer`; callers
choose its storage, handle backend failures and flush it.

The guides specify numeric encoding, admitted regions and partial-output behavior for each API.
They also explain the mechanisms behind the contracts: vector sums, polynomial folding,
four-lane word mixing, checked chunk extents, sample quantization and adaptive prediction.
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
