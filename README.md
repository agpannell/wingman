# Wingman

Focused Zig libraries for byte processing, with explicit ownership and documented format contracts.
The package provides **Adler-32** for zlib and **IEEE CRC-32** for gzip and PNG. Both detect
accidental changes to data and support complete buffers, incremental input and checksum combination.

Wingman accepts exact, unaligned byte slices, allocates no memory for checksumming and selects
portable or SIMD implementations from the compile-time target. Input chunks can be released as
soon as an update returns.

## Try it

Use **Zig 0.17.0**, available from the [official downloads](https://ziglang.org/download/).
From this checkout:

```sh
zig version
zig build test --seed=0 --summary all
zig build example
zig build example -- Wikipedia
zig build crc32-example
```

The Adler-32 example prints checksum `091e01de` for `123456789`, checks that streaming and
concatenation give the same result, and shows the four bytes used in a zlib footer.
The CRC example prints `cbf43926` for the same input, shows gzip's little-endian CRC field and
computes the big-endian checksum of PNG's empty `IEND` chunk.

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

The guides explain results, state and input lifetimes, byte order, checksum combination and how
vector sums or polynomial folding preserve the checksum arithmetic. The source includes independent
fixed values, scalar comparisons, state-boundary tests and protected-page input checks.

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
