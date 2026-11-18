# BLAKE3

BLAKE3 produces a cryptographic digest of a byte sequence. Use it for content identifiers or
integrity checks against a trusted digest. Its keyed mode authenticates bytes with a shared secret;
its derivation mode separates keys for different application purposes. Extended output supplies more
than the default 32 bytes, including directly selected output ranges.

The unkeyed digest does not authenticate who supplied the bytes. Key derivation expects key material
with sufficient entropy; it is not a password-stretching function. Frame structured fields in the
caller: updates append bytes without recording boundaries, so `"ab"` then `"c"` hashes the same
message as `"a"` then `"bc"`.

Use [the package setup](../README.md#use-it-in-a-project) with Zig 0.17.0 and import
`@import("wingman").blake3`. Run `zig build blake3-example` or
`zig build blake3-example -- "your text"`. The [example](../examples/blake3.zig) checks complete
and incremental hashing and verifies a selected extended-output range.

## Complete input and streams

`Hasher` selects kernels from the compile-time CPU target. Initialize its caller-owned storage with
`reset` for a stream or `hash` for a complete unkeyed buffer:

```zig
const std = @import("std");
const blake3 = @import("wingman").blake3;

test "digest and continued stream" {
    var state: blake3.Hasher = undefined;
    const digest = try state.hash("abc");
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(
        "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85",
        &hex,
    );
    state.reset();
    try state.update("a");
    const prefix = state.final();
    try state.update("bc");
    try std.testing.expectEqual(digest, state.final());
    try std.testing.expect(!std.mem.eql(u8, &prefix, &digest));
}
```

`final` returns a copied `[32]u8` digest and leaves the stream usable. Repeated snapshots agree;
later updates append to the accepted bytes. `hash` replaces any previous stream or keyed mode, but
that newly hashed stream can also be extended. Digest bytes are already in BLAKE3's output order;
hex is a display encoding, not an integer byte-order conversion.

The state includes tree and batch scratch. Construct it directly in its final reservation and reuse
it through a pointer. Use `@sizeOf(blake3.Hasher)` and `@alignOf(blake3.Hasher)` to reserve storage
for the selected target. Heap storage is optional: callers may use their allocator's
`create`/`destroy`, an arena, or sufficient aligned stack storage. The library allocates nothing and
retains no allocator. There is no `deinit`.

Input requires no extra alignment or padding. Keep input, state and output separate and readable or
writable as appropriate until each call returns. Updates copy all retained data; input can then be
released or changed, and copied output outlives both input and state. Serialize mutation of a shared
state. `ScalarHasher` has the same methods with an explicitly scalar kernel.

A copy of an initialized state can continue independently. It includes the tree, batch scratch
and any retained key-derived values. Use copying when a common prefix needs different suffixes;
clear each sensitive state copy separately.

## Keyed hashing and derivation

Choose the initialization for the operation; `update`, `final` and `finalizeSeek` then work in that
mode:

| Initialization | Meaning |
| --- | --- |
| `reset()` | Unkeyed digest |
| `resetKeyed(key)` | Keyed hashing with exactly `[32]u8` of caller-supplied secret key |
| `try resetDerive(context)` | Derive from material appended afterward, with a stable application/purpose context |

`resetKeyed` copies the key. `resetDerive` consumes the context synchronously and retains only its
derived words. Choose a fixed, globally unique context string for each application purpose; it is
public context, not the secret material. Neither mode generates entropy or manages secrets.

```zig
const std = @import("std");
const blake3 = @import("wingman").blake3;

test "derive a key and clear retained state" {
    var state: blake3.Hasher = undefined;
    const derived_key = blk: {
        defer state.clear();
        // Independent empty-material vector; applications choose their own unique context.
        try state.resetDerive("BLAKE3 2019-12-27 16:29:52 test vectors context");
        try state.update("");
        break :blk state.final();
    };
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&state), 0));
    const hex = std.fmt.bytesToHex(derived_key, .lower);
    try std.testing.expectEqualStrings(
        "2cc39783c223154fea8dfb7c1b1660f2ac2dcbd1c1de8277b0b0dd39b7e50d7d",
        &hex,
    );
}
```

`clear` uses volatile stores to erase the entire state reservation, including retained key-derived
scratch. Initialize with a reset method before reusing cleared storage. Reset, `hash`, or destroying
a reservation does not erase all old scratch. Caller keys, input material and copied outputs have
independent lifetimes; clear those separately when needed. This erasure contract covers the
reservation, not all temporary machine registers or copies made elsewhere.

## Extended output and limits

`try state.finalizeSeek(offset, output)` writes `output.len` bytes starting at the `u64` byte offset
in the current stream's extended output. Offset zero starts with the ordinary digest. Reading one
range does not advance a cursor or change the state:

```zig
const std = @import("std");
const blake3 = @import("wingman").blake3;

test "select a range of extended output" {
    var state: blake3.Hasher = undefined;
    _ = try state.hash("abc");
    var extended: [96]u8 = undefined;
    try state.finalizeSeek(0, &extended);
    var selected: [40]u8 = undefined;
    try state.finalizeSeek(31, &selected);
    try std.testing.expectEqualSlices(u8, extended[31..71], &selected);
}
```

The accepted input length and output range use checked `u64` arithmetic. `update` rejects a total
above `maxInt(u64)` with `SizeOverflow` before changing the accepted stream. `finalizeSeek` rejects
an overflowing exclusive end before writing any output; empty output is allowed. `resetDerive` and
`hash` intentionally begin a replacement stream. No file I/O or output allocation is implicit.

## Explicit parallel updates

`updateParallel(io, input, workspaces, options)` appends to the same stream using a supplied
`std.Io` provider and caller-owned `[]blake3.ParallelWorkspace` scratch. Ordinary `update` never
schedules jobs.

Each participant uses one workspace, including the calling thread. A wave submits at most
`workspaces.len - 1` jobs; the caller handles one partition. The provider may execute inline. Fewer
than two workspaces, small updates, or insufficient aligned subtree geometry use ordinary hashing.
Defaults admit updates of at least 256 KiB and aim for at least 64 KiB per participant.
`ParallelOptions` exposes both thresholds.

```zig
const std = @import("std");
const builtin = @import("builtin");
const blake3 = @import("wingman").blake3;

test "append a parallel update" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var provider = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .limited(3) });
    defer provider.deinit();
    var bytes: [256 * 1024]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i % 251);
    var workspaces: [4]blake3.ParallelWorkspace = undefined;
    defer for (&workspaces) |*workspace| workspace.clear();
    var state: blake3.Hasher = undefined;
    defer state.clear();
    state.reset();
    try state.updateParallel(provider.io(), &bytes, &workspaces, .{});
    var expected: blake3.Digest = undefined;
    std.crypto.hash.Blake3.hash(&bytes, &expected, .{});
    try std.testing.expectEqual(expected, state.final());
}
```

Keep workspaces, state and input disjoint and stable until return. All accepted jobs finish before
success, error or cancellation returns. Participating workspaces' input pointers are then empty;
unused workspaces are untouched. The provider owns scheduling resources and allocation policy. The
hashing operation itself allocates nothing. Overflow refuses before mutation or scheduling.
`Canceled` can leave a partial update: reset before reuse. Parallel scratch can retain key-derived
words; `ParallelWorkspace.clear` erases its entire reservation.

## Compression and implementation

The [library entry](../src/blake3.zig) presents the public API. Within `src/blake3/`, `hasher.zig`
owns streaming and tree admission. `parallel.zig` owns subtree jobs, and `ParallelWorkspace.zig`
owns their caller-reserved scratch. `ChunkState.zig` retains pending chunk blocks,
`CompressionInput.zig` holds deferred compression inputs, and `compression.zig` owns target kernels.
The official vectors live in `fixtures.zig`; tests stay with the implementation they exercise.

Most callers need only `Hasher`. The public `compression` namespace supports applications that own
BLAKE3's chunk counters, flags and tree construction. A `Cv` is eight internal chaining words, not a
finalized digest; a `Block` holds sixteen words. `loadBlock`, `storeCv`, `compress` and `chaining`
expose block operations. `chunks`, `pairChunks`, `parents`, `batchChunks` and `batchParents` process
complete non-root chunks or ordered child values. Their API reference specifies counts, counter
ranges, alignment, scratch and overlap preconditions. Only the documented parent operations permit
input/output overlap; those permissions do not extend to the high-level state API.

BLAKE3 divides input into 1024-byte chunks, compresses 64-byte blocks, and combines chunk results as
a binary tree. Finalization preserves the last block or root children until it can apply the root
flag. Independent chunks and parents can use SIMD batches while a compact stack retains incomplete
tree levels. Short complete inputs have a direct path; partial blocks are copied only when needed.
Parallel results reduce in original input order regardless of completion order.

The selected target determines scalar or row-vector compression and batches of four, eight or
sixteen chunks. x86-64 AVX-512F plus AVX-512VL enables a dedicated sixteen-chunk kernel. There is no
runtime CPU dispatcher: a binary requires the CPU features it was built to use. Parent reduction
preserves unread children for overlap in either direction, including partial-chaining-value offsets.

Inline tests include all 35 official vector lengths in ordinary, keyed and derivation modes with 131
output bytes each; scalar/kernel comparisons; block, chunk and tree boundaries; snapshots and
continued streams; unaligned input; output seeks; overflow; erasure; parent overlap; and parallel
retirement and cancellation. Linux protected-page checks exercise input/output ends. Synthetic
near-limit states exercise range admission without hashing a 2^64-byte stream.

Algorithm reference: [BLAKE3
specification](https://github.com/BLAKE3-team/BLAKE3-specs/blob/ac784c9f22a48327782f042ec2f4d8126b3b1744/blake3.tex).
The [official test
vectors](https://github.com/BLAKE3-team/BLAKE3/blob/f55849f89cd85083c1c9daa2c5de20766f309c00/test_vectors/test_vectors.json)
carry a CC0 1.0 dedication, retained beside the embedded fixture data. The Zig implementation is
covered by the package's [MIT license](../LICENSE).
