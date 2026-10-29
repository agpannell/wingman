# Wingman

Focused Zig libraries for byte processing, with explicit ownership and documented format contracts.
The package provides **Adler-32** for zlib, **IEEE CRC-32** for gzip and PNG, and classic
**XXH32/XXH64** hashes for lookup keys and content checksums. Each supports complete buffers and
incremental input; the checksum libraries also combine independently processed sequences.
**RIFF** reads and writes bounded containers and chunks used by formats such as WAVE and WebP.

Wingman accepts exact, unaligned byte slices and allocates no memory for these calculations or
container inspection. RIFF writing uses the caller's `std.Io.Writer` and its storage policy.
The checksum kernels select portable or SIMD implementations from the compile-time target.
Input chunks can be released as soon as an update returns.

## Try it

Use **Zig 0.17.0**, available from the [official downloads](https://ziglang.org/download/).
From this checkout:

```sh
zig version
zig build test --seed=0 --summary all
zig build example
zig build example -- Wikipedia
zig build crc32-example
zig build xxhash-example
zig build riff-example
```

The Adler-32 example prints checksum `091e01de` for `123456789`, checks that streaming and
concatenation give the same result, and shows the four bytes used in a zlib footer.
The CRC example prints `cbf43926` for the same input, shows gzip's little-endian CRC field and
computes the big-endian checksum of PNG's empty `IEND` chunk.
The xxHash example prints both widths with zero and nonzero seeds and checks fragmented input.
The RIFF example writes a nested generic container, then prints its form, list and payload extents.

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

## Use it in a project

The [standalone consumer](examples/consumer/) shows a complete Zig build with a named `wingman`
dependency. It runs independently of the root test build:

```sh
cd examples/consumer
zig build test -Doptimize=ReleaseSafe --summary all
```

Use `dependency.module("wingman")` to import the package. The current API is pre-release; pin a
specific revision when taking a source dependency.

## Library and engineering guide

| Library | Purpose | Guide |
| --- | --- | --- |
| `wingman.adler32` | Complete and incremental checksums; combine independently processed sequences | [Adler-32](docs/adler32.md) |
| `wingman.crc32` | IEEE checksums for gzip content and PNG chunks, including streaming and combination | [CRC-32](docs/crc32.md) |
| `wingman.xxhash32`, `wingman.xxhash64` | Seeded and seed-zero classic xxHash, with copied streaming state | [xxHash](docs/xxhash.md) |
| `wingman.riff` | Borrowed container/chunk traversal, nested lists and checked writing through `std.Io.Writer` | [RIFF](docs/riff.md) |

The guides explain results, state and input lifetimes, byte order, checksum combination and how
vector sums, polynomial folding and four-lane word mixing work. The source includes independent
fixed values, scalar comparisons, state-boundary tests and protected-page input checks.
The RIFF guide explains declared extents, lazy child validation, word padding and caller-owned
payload policy; a valid envelope alone does not establish a valid media file.

Generate the API reference with `zig build docs`. Open `zig-out/docs/index.html` through a local
HTTP server. Run `python3 -m http.server --directory zig-out/docs 8000`, then visit
`http://localhost:8000`.

## Contributing

Tests and examples use Zig 0.17.0 with LLVM.

Format Zig and Markdown to 100 columns. Before sending a change, run the tests in both checked and
optimized modes:

```sh
zig fmt --check build.zig build.zig.zon src examples
zig build test -Doptimize=ReleaseSafe --seed=0 --summary all
zig build test -Doptimize=ReleaseFast --seed=0 --summary all
zig build docs
```

Use `-Dtarget` and `-Dcpu` for a different compile-time target. A binary built for additional CPU
features requires hardware with those features. The implementation has no runtime CPU dispatcher.
The CI configuration checks baseline x86-64 Linux; its results do not establish support on every
architecture. These noncryptographic checksums detect accidental corruption; matching values do
not establish that two inputs are identical. CRC-32 here uses the IEEE polynomial, which differs
from CRC-32C and the x86 instruction named CRC32.

## License

[MIT](LICENSE). Algorithm references are credited beside the relevant source.
