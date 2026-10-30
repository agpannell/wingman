# LZ4

LZ4 compresses byte sequences by replacing repeated data with backward references. Use it when
fast recovery and an interoperable representation matter more than the smallest possible encoding.
Wingman supports raw blocks and standard version-1 frames, dictionaries, fragmented decoding,
frame streaming and bounded high-compression (HC) encoding. Legacy LZ4 frames are unsupported.

A raw block needs an enclosing record for its encoded boundary, decoded size or capacity,
dictionary agreement and integrity policy. A frame carries block boundaries, options and optional
XXH32 checksums. Those checksums detect accidental corruption; they do not authenticate data.

Use [the package setup](../README.md#use-it-in-a-project) with Zig 0.17.0 and import
`@import("wingman").lz4`. Run `zig build lz4-example` or
`zig build lz4-example -- "your text"`. The [example](../examples/lz4.zig) recovers the same input
from greedy raw encoding, HC raw encoding and a checksummed standard frame.

## Operations and storage

| Operation | Entry points | Storage and default extent |
| --- | --- | --- |
| Complete raw block | `encodeBlock`, `decodeBlock` | Encoder workspace; decoding needs only source/output. Exact decoded size by default. |
| HC raw block | `encodeBlockHc` | Separate HC workspace; same wire format and decoder. |
| Fragmented raw recovery | `Decoder.reset`, `step` | Caller-owned 64 KiB history ring. |
| Complete frame | `encodeFrame`, `decodeFrame` | Encoder workspace/buffers; decoding needs only source/output. Bounded decoded size by default. |
| Fragmented frame | `FrameEncoder`, `FrameDecoder` | Explicit workspaces borrowed until the owner retires. |

The [public entry](../src/lz4.zig) groups raw, HC and frame APIs. The shallow `src/lz4/` group
contains `block.zig` for sequences, history and block recovery; `hc.zig` for bounded search and
parsing; and `frame.zig` for descriptors, checksums and frame state machines. Inline tests stay
with those implementations.

Codec calls allocate nothing. Workspace `create(allocator)` methods allocate directly at their
final address; `destroy(allocator)` releases the complete reservation with that same allocator.
No allocator is retained. Typed storage is possible where the workspace contract permits it.
Large or self-referencing streaming owners must be initialized at their final address and remain
stable while in use. Input/output bytes require no extra alignment or padding.

## Complete raw blocks

Reserve the full `try blockEncodeBound(source.len)` capacity, even when actual output will be
small. Encoding returns a borrowed used prefix; retain the original full allocation for cleanup:

```zig
const lz4 = @import("wingman").lz4;

const workspace = try lz4.EncoderWorkspace.create(allocator);
defer workspace.destroy(allocator);
const capacity = try lz4.blockEncodeBound(source.len);
const storage = try allocator.alloc(u8, capacity);
defer allocator.free(storage);
const encoded = try lz4.encodeBlock(source, storage, workspace, .{});

const restored = try allocator.alloc(u8, expected_size);
defer allocator.free(restored);
const result = try lz4.decodeBlock(encoded, restored, .{});
// result.produced == expected_size; result.consumed == encoded.len.
```

Default raw decoding requires exactly the supplied output length. Use
`.{ .output_size = .bounded }` to admit spare capacity and return the used length. The complete
encoded slice is always parsed: bounded output does not permit ignoring trailing encoded bytes.
The unused output suffix stays unchanged on success. `OutputSizeMismatch` identifies an incorrect
exact extent; `OutputTooSmall` identifies insufficient capacity. Malformed lengths, offsets and
termination have separate errors.

Source/output must be disjoint. Complete calls retain neither span; recovered output can outlive
source and workspace. Failure may change a private output prefix. Publish only after complete
validation and any enclosing integrity check, including when a resource limit caused failure.

## Dictionaries and raw fragments

Greedy and HC encoding accept an immutable dictionary slice. Decoding accepts `HistoryView`, two
chronological spans named `older` and `newer`. This represents a dictionary followed by earlier
decoded blocks without concatenating them. Only the last 65,535 bytes are reachable. Reachable
history must be disjoint from destination and, for encoding, mutable scratch. Complete-call
borrows end on return. Raw blocks do not identify their dictionary: the caller must agree on it.

```zig
const encoded = try lz4.encodeBlock(source, storage, workspace, .{
    .dictionary = dictionary,
});
const result = try lz4.decodeBlock(encoded, restored, .{
    .dictionary = .{ .newer = dictionary },
});
```

For resumable recovery, initialize a `Decoder` with a separate history ring:

```zig
const history = try allocator.create([65536]u8);
defer allocator.destroy(history);
var decoder: lz4.Decoder = undefined;
try decoder.reset(history, .{ .limits = .{ .output_bytes = maximum_decoded_bytes } });
```

Each `step(.{ .bytes = input, .final = at_block_end }, output)` returns `consumed`, `produced`
and a status. Advance by those counts. `need_input` asks for more encoded bytes; `need_output`
asks for output capacity. Resubmit any unconsumed input suffix. True `final` means those bytes
reach the actual encoded block end; preserve that flag when resubmitting its suffix. It does not
mean the end of an arbitrary network fragment.

Accepted input and produced output fragments can retire on return; the ring retains history.
`complete` validates the raw block, and repeated completion returns zero counts. A `step` error
poisons the owner: reset before reuse. Keep state, history and fragments disjoint as documented.
Only the ring is borrowed across calls. Reset or `setDictionary` copies dictionary bytes.

After completion, `nextBlock(true)` starts another block with retained history;
`nextBlock(false)` starts independently. `appendHistory` adds uncompressed bytes between blocks
for a container that owns their framing and accounting. Per-block counts and limits restart with
`nextBlock`.

## Standard frames

`FrameEncodeOptions` defaults to independent 64 KiB blocks with a content checksum. Select
`.k64`, `.k256`, `.m1` or `.m4` for maximum block sizes of 64 KiB, 256 KiB, 1 MiB or 4 MiB.
Block checksums, linked blocks, an exact content size, dictionaries and HC are explicit selections.
Present zero content size is distinct from an omitted size.

```zig
const options: lz4.FrameEncodeOptions = .{
    .block_checksum = true,
    .content_size = source.len,
};
const workspace = try lz4.FrameEncoderWorkspace.create(allocator, options.block_size);
defer workspace.destroy(allocator);
const capacity = try lz4.frameEncodeBound(source.len, options);
const storage = try allocator.alloc(u8, capacity);
defer allocator.free(storage);
const encoded = try lz4.encodeFrame(source, storage, .{ .workspace = workspace }, options);
const result = try lz4.decodeFrame(encoded, restored, .{ .trailing_data = .reject });
// Use restored[0..result.produced].
```

Frame decoding is bounded by default; `.output_size = .exact` requires the destination length
exactly. Default `.frames = .single` stops at the first ordinary or skippable frame, leaving
following bytes unconsumed. `.trailing_data = .reject` rejects that remainder. `.concatenate`
validates the complete supplied sequence. Complete-buffer `.iterate` also stops after one frame;
advance by `consumed` yourself.

All sixteen standard skippable tags are supported. `encodeSkippableFrame` writes a complete
payload/header; `skippableFrameHeader` supplies just its eight-byte header. Skippable payload
produces no decoded bytes, but charges encoded-byte and frame limits. Returned frame counts
include skippables, with a separate `skippable_frames` count.

Block checksums cover encoded block bytes; content checksums cover restored content. Complete
frame decoding verifies each block checksum before recovery. Streaming may emit private bytes
before its checksums and content size can be verified. Treat output as unverified until successful
completion. Each frame resets history and checksum state; independent blocks restart from the
initial dictionary.

## Streaming frames and dictionary IDs

`FrameDecoder.reset(workspace, options)` borrows a `FrameDecoderWorkspace`, with a fixed 128 KiB
history/dictionary reservation regardless of advertised block size. Its `step` uses the raw
decoder's finality/progress rules. Under `.iterate`, `frame_end` reports a verified frame and waits
for `nextFrame()`; `.concatenate` continues to explicit EOF. Copied `frame_info` and cumulative
`counts()` remain available.

Dictionary IDs are application identifiers, not hashes or proof of dictionary contents. IDs
include zero. Supply `FrameDictionary` at reset, or resolve `need_dictionary` by inspecting
`frame_info` and calling `setDictionary(id, bytes)`. A wrong ID can be retried. Matching dictionary
bytes are copied and can retire. Frames without IDs may use an out-of-band dictionary agreement.

`FrameEncoder.reset(storage, options)` borrows its workspace and copies any dictionary.
`step(input, output, action)` accepts fragments and copies pending input into the workspace.
Use `.process` to keep a frame open, `.flush` to emit a short block, or `.finish` to also emit the
footer. Resubmit unconsumed input with the same action. Finish latches after all supplied input is
accepted; then drain with empty input. `flushed` permits further input; only finish returns
`complete`. Step errors require reset.

`frameEncodeBound` bounds complete encoding with the selected block size. Explicit streaming
flushes may add short blocks, so reserve or emit output incrementally for that route. Callers own
file/network I/O and flushing; the codecs retain no I/O provider.

## HC search and limits

HC produces ordinary blocks using a separate `HcEncoderWorkspace`. `HcEncodeOptions` selects
`.balanced` or `.offline` search, `.size` or `.throughput` decoder-cost pricing, a dictionary and
`limits.work_units`. These profiles are not upstream numeric compression levels. `HcStats`
reports work, probes and sequences. `clear()` explicitly erases HC workspace; other destruction
methods do not promise automatic erasure.

For HC frames, supply `hc_workspace` in `FrameEncodeStorage` and select
`.compression = .{ .hc = .{} }`. Dictionaries belong in `FrameEncodeOptions`, not nested HC
options. HC effort accumulates across the frame, including repeated dictionary priming; byte
admission stays independent. Missing selected HC storage is an options error. Unused HC storage
may be supplied with fast policy without being borrowed.

Raw/frame decode limits bound accepted input, decoded output and byte work. Frames also bound
frame count and advertised block size. Frame encoding bounds accepted input and produced wire
bytes. Byte work counts input plus output once, excluding copied initial dictionaries; it is not
a wall-clock or complete CPU-instruction budget. HC separately counts insertions, probes,
comparisons and parser edges. Defaults are permissive: choose finite limits before decoding
untrusted input or allocating from an untrusted size. Exhaustion is not successful partial output.

## Mechanisms and validation

A raw sequence stores literals and a match: a backward distance and copy length. Matches can
read newly produced output, growing short patterns. Recovery uses guarded bulk paths and exact
tails without reading outside supplied spans. Encoding preserves LZ4's final-literal and
last-match restrictions. Greedy encoding uses a compact hash table. HC uses hash chains, exact
serialized-byte prices, a 2 KiB parsing horizon and a long-match shortcut. One path per position
and bounded search avoid a global-optimality claim. Throughput pricing is a heuristic, not a
decoder-latency guarantee.

Inline tests cover frozen independent blocks, exact/bounded output, overlapping distances,
dictionaries, retired fragments and ring wrap, malformed input, aliases, limits, poisoning,
checksums, frame policies, all block sizes, flush/finish, storage retry and allocation cleanup.
The separate consumer checks complete public calls. These finite checks do not exhaust all
histories or fragment schedules. Portable/emulated execution does not establish native speed.

Format references: [LZ4 block specification 1.10.0](https://github.com/lz4/lz4/blob/ebb370ca83af193212df4dcbadcc5d87bc0de2f0/doc/lz4_Block_format.md)
and [frame specification 1.6.4](https://github.com/lz4/lz4/blob/ebb370ca83af193212df4dcbadcc5d87bc0de2f0/doc/lz4_Frame_format.md).
Algorithm and frozen-vector credits remain beside their owners. The implementation is covered
by the package's [MIT license](../LICENSE).
