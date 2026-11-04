# xxHash

xxHash is a family of fast noncryptographic hashes for lookup keys, cache identifiers and compatible
format checksums. `wingman.xxhash` provides classic XXH32 and XXH64, plus XXH3 with 64-bit and
128-bit results. Select the algorithm and seed required by the format or application: the variants
are distinct, and truncating XXH64 does not produce XXH32. XXH128 is another name for XXH3-128.

These hashes do not authenticate data or prove that two inputs are identical. A custom secret
changes the mapping; it does not make the algorithm cryptographic. Compare original keys when
collisions matter.

Run `zig build xxhash-example`, or pass text after `--`. The [example](../examples/xxhash.zig)
prints all four widths and checks seeded and custom-secret streams against complete-input calls.

## Complete input and seeded streams

| Type | Result | Seed | Classic stripe |
| --- | --- | --- | --- |
| `xxhash.Xxh32` | `u32` | `u32` | 16 bytes |
| `xxhash.Xxh64` | `u64` | `u64` | 32 bytes |
| `xxhash.Xxh3_64` | `u64` | `u64` | — |
| `xxhash.Xxh3_128` | `u128` | `u64` | — |

Each type has `hash(bytes)` for seed zero and `hashSeeded(seed, bytes)` for a selected seed. The
seed comes first. Empty and unaligned input needs no padding. Operations allocate nothing, retain
no input and perform no I/O.

```zig
const std = @import("std");
const xxhash = @import("wingman").xxhash;

test "hash complete input" {
    try std.testing.expectEqual(@as(u32, 0x32d153ff), xxhash.Xxh32.hash("abc"));
    try std.testing.expectEqual(@as(u64, 0x44bc2cf5ad770999), xxhash.Xxh64.hash("abc"));
    try std.testing.expectEqual(@as(u64, 0x78af5f94892f3950), xxhash.Xxh3_64.hash("abc"));
    try std.testing.expectEqual(
        @as(u128, 0x6b05ab6733a618578af5f94892f3950),
        xxhash.Xxh3_128.hash("abc"),
    );
}
```

For fragments, initialize a caller-owned state and append with `update`. The classic states use
value-returning `init(seed)`; XXH3 states use `state.init(seed)` in their final storage.
`final` returns a snapshot without resetting; repeated calls agree and later updates continue the
stream. Copies have independent state. The classic `reset(seed)` and XXH3 `init(seed)` start a
new stream and can initialize undefined storage. Input can retire after `update` returns, but must
be readable and disjoint from the mutable state during that call. Serialize shared-state mutation.

```zig
const std = @import("std");
const xxhash = @import("wingman").xxhash;

test "snapshot and continue" {
    var state = xxhash.Xxh64.init(42);
    state.update("a");
    const prefix = state.final();
    var copy = state;
    state.update("bc");
    copy.update("d");
    try std.testing.expectEqual(xxhash.Xxh64.hashSeeded(42, "a"), prefix);
    try std.testing.expectEqual(xxhash.Xxh64.hashSeeded(42, "ad"), copy.final());
    try std.testing.expectEqual(@as(u64, 0x13c1d910702770e6), state.final());
}
```

## XXH3 custom secrets

The two XXH3 types also accept `Xxh3Options` with either `.mode = .{ .seed = seed }` or
`.mode = .{ .secret = secret }`. The default is seed zero. Secret and seed cannot be combined in
this interface. Secrets must contain at least 136 bytes; all supplied bytes are available to the
algorithm, including bytes beyond 192.

`hashWithOptions(options, bytes)` borrows its inputs only for the call and returns `InvalidSecret`
for a shorter secret. For streaming, use `initWithOptions` on the actual destination state. It
checks secret length before checking overlap with the complete state; `InvalidSecret` and
`StorageOverlap` leave the state unchanged. A successful secret-mode initialization borrows the
secret: keep the full slice alive, immutable and disjoint from every mutable state copy until that
copy is successfully reinitialized or no longer used. Failed initialization retains any existing
borrow. Seeded states own their internal derived bytes and can be moved or copied.

```zig
const std = @import("std");
const xxhash = @import("wingman").xxhash;

test "stream with a borrowed secret" {
    const secret: [137]u8 = @splat(0xa5);
    const options: xxhash.Xxh3Options = .{ .mode = .{ .secret = &secret } };
    var state: xxhash.Xxh3_128 = undefined;
    try state.initWithOptions(options);
    state.update("abc");
    const digest = state.final();
    const complete = try xxhash.Xxh3_128.hashWithOptions(options, "abc");
    try std.testing.expectEqual(complete, digest);
    // Keep secret alive and unchanged until the last use of state and its copies.
}
```

The supplied secret and input may overlap for a complete `hashWithOptions` call. For streaming,
keep update input disjoint from the mutable state. Neither operation retains an allocator.
Experimental upstream secret generation and combined secret-and-seed interfaces are outside this
API.

## Numeric results and length

Results are integers, independent of host byte order. The upstream canonical representation uses
big-endian bytes: use `std.mem.writeInt` with the result type and `.big`. An enclosing format may
choose another order or a portion of the result. LZ4 stores XXH32 fields in little-endian order;
Zstandard's content checksum stores the low 32 bits of seed-zero XXH64 in little-endian order.
XXH3-128's `u128` places upstream's high 64 bits above its low 64 bits; its low half is not a
substitute for XXH3-64.

Classic XXH32 and XXH64 lengths wrap modulo 2³² and 2⁶⁴ respectively, while streaming remembers
that it processed a full stripe. XXH3 uses the reference's wrapped 64-bit length and its matching
short/long finalization behavior. Synthetic-state tests exercise wrap boundaries; they do not claim
an actual 2⁶⁴-byte execution.

## Validation and implementation

Classic tests include independent vectors, standard-library comparisons, fragmented streams,
unaligned boundaries, snapshots, copies and Linux protected-page checks. XXH3 tests include upstream
vectors, short and long inputs, seeded and secret modes, fragment boundaries, state copies and
failed initialization admission. Input and secret backing must follow the ownership rules above.
These tests cover selected cases rather than every possible input or update history.

The implementation uses compile-time target features and portable fallback operations; it does not
perform runtime CPU dispatch. Algorithm and test-vector references are credited at their source
owners. xxHash was designed by Yann Collet and the xxHash contributors. The stable format and API
reference is [xxHash v0.8.4](https://github.com/Cyan4973/xxHash/tree/c87183a77d67f7d37e3d2d1b7eaac5e7c695e4f0).
