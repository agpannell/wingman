# Classic xxHash

XXH32 and XXH64 turn a byte sequence and a seed into a 32-bit or 64-bit integer. Use these classic
xxHash algorithms for lookup keys, cached data and compatible content checksums. They can process
a complete buffer or accept fragments without keeping the original bytes.

The seed selects another deterministic mapping; it is not a secret key. These are noncryptographic
hashes. Matching numbers do not establish that two inputs are identical, so a lookup that requires
exact identity must also compare the original keys.

| Library | Result and seed | Full stripe size | Empty result with seed zero |
| --- | --- | --- | --- |
| `wingman.xxhash32` | `u32` | 16 bytes | `02cc5d05` |
| `wingman.xxhash64` | `u64` | 32 bytes | `ef46db3751d8e999` |

The algorithms have different mixing rules; truncating XXH64 does not produce XXH32. Choose the
algorithm and seed required by your application or format. These namespaces implement XXH32 and
XXH64; XXH3 is a separate algorithm.

Use [the package setup](../README.md#use-it-in-a-project) with Zig 0.17.0. From the checkout root,
run `zig build xxhash-example` or `zig build xxhash-example -- "your text"`. The runnable
[example](../examples/xxhash.zig) prints both widths with seeds zero and 42 and verifies that
incremental input agrees with the complete-buffer result.

## Complete input and seeds

Both libraries provide `hash(bytes)` for seed zero and `hashSeeded(seed, bytes)` for any seed of
their word width. The seed comes first, matching the standard library's argument order.

```zig
const std = @import("std");
const wingman = @import("wingman");

test "classic hashes and explicit seeds" {
    try std.testing.expectEqual(@as(u32, 0x32d153ff), wingman.xxhash32.hash("abc"));
    try std.testing.expectEqual(@as(u64, 0x44bc2cf5ad770999), wingman.xxhash64.hash("abc"));
    try std.testing.expectEqual(@as(u32, 0xaa3da8ff), wingman.xxhash32.hashSeeded(1, "abc"));
    try std.testing.expectEqual(@as(u64, 0x13c1d910702770e6), wingman.xxhash64.hashSeeded(42, "abc"));
}
```

Empty and unaligned slices are accepted. Every read stays within the supplied extent, without
padding. Calls allocate nothing, retain no input and need no cleanup. Their results are integers
that do not depend on host byte order.

## Incremental input, snapshots and copies

A caller-owned `Hasher` starts with `.init` for seed zero. `reset(seed)` starts another stream and
can also initialize otherwise undefined storage. Append each fragment with `update`:

```zig
const std = @import("std");
const xxhash64 = @import("wingman").xxhash64;

test "snapshot and independent continuation" {
    var state: xxhash64.Hasher = .init;
    state.reset(42);
    state.update("a");
    const prefix = state.final();
    var copy = state;
    state.update("bc");
    copy.update("d");
    try std.testing.expectEqual(xxhash64.hashSeeded(42, "a"), prefix);
    try std.testing.expectEqual(xxhash64.hashSeeded(42, "ad"), copy.final());
    try std.testing.expectEqual(@as(u64, 0x13c1d910702770e6), state.final());
}
```

XXH32 uses the same operations with `u32` seeds and results. `final` is a non-consuming snapshot:
repeated calls agree, and later updates continue the stream. Copies include all accumulators and
pending bytes, so they can continue independently. Assigning `.init` resets to seed zero;
`reset(seed)` replaces every part of the previous state.

The state copies an incomplete stripe into its own inline storage: at most 15 pending bytes for
XXH32 or 31 for XXH64. Keep each input readable and separate from the mutable state during
`update`; it may be released afterward. Serialize mutation of shared state. The API has no allocator
or cleanup and no recoverable error path; it requires valid initialized state and readable input.
Use `.init`, `reset` or a valid copy to establish the field invariants.

## Numeric results and bytes

The number returned by `hash` or `final` has no serialized byte order. xxHash's canonical byte
representation puts the most significant byte first:

```zig
const std = @import("std");
const xxhash64 = @import("wingman").xxhash64;

test "canonical hash bytes" {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, xxhash64.hash("abc"), .big);
    try std.testing.expectEqual([8]u8{ 0x44, 0xbc, 0x2c, 0xf5, 0xad, 0x77, 0x09, 0x99 }, bytes);
}
```

Use a four-byte array and `writeInt(u32, ..., .big)` for canonical XXH32. An enclosing format may
choose another byte order or store only part of the result. Those rules belong to that format;
these hash libraries return the complete numeric value.

## How the calculation works

A stripe is a group of four words. Four independent accumulators mix the stripe's words using
wrapping addition, multiplication by fixed odd constants and bit rotation. Independent lanes
permit work on several words before one result depends on all of them. Input words are always
decoded as little-endian, which fixes the result across machines.

After full stripes, the lanes converge. XXH64 applies an additional mixing round to each lane's
contribution. Remaining words and individual bytes are then mixed into the result, followed by
an avalanche of shifts, XOR and multiplication that spreads changes across output bits. Short
inputs start directly from the seed and skip the stripe stage.

Streaming first completes any copied partial stripe, consumes whole stripes and copies the final
remainder. Its snapshot mixes that remainder without changing the accumulators. XXH64's complete
buffer entry point keeps a direct loop over the input; its streaming helpers separately handle
partial stripes and retained state.

The final length contribution wraps modulo 2^32 or 2^64. Streaming remembers whether it has seen
a full stripe even when that counter wraps, so XXH32 streams continue correctly beyond 4 GiB.
This also defines Wingman's modular XXH64 extension beyond 2^64 accepted bytes; it keeps the
stripe stage, while upstream's C stream digest selects that stage from its wrapped length.
Synthetic-state tests check that counter boundary with independent numeric facts; they do not
claim an actual 2^64-byte execution.

## Validation scope

The tests retain independent numeric facts for empty, literal and patterned inputs with several
seeds. Standard-library comparisons cover short lengths, unaligned stripe boundaries and every
split of selected sequences. Additional joined tests check copied pending bytes, snapshots,
independent continuation, reset into undefined storage and caller-buffer retirement. Linux
protected-page tests exercise both input boundaries and read-only storage; they skip elsewhere.

Both implementations use portable word operations. The compiler chooses instructions for the
selected target.

Algorithm and canonical-byte reference:
[xxHash specification 0.2.0](https://github.com/Cyan4973/xxHash/blob/c87183a/doc/xxhash_spec.md).
Research and independent numeric-reference credits remain beside their source owners.
