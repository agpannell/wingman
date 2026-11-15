# LZ4

LZ4 compresses byte sequences by replacing repeated data with backward references. Use it when fast
recovery and an interoperable representation matter more than the smallest possible encoding.
Wingman supports raw blocks and standard version-1 frames, dictionaries, fragmented decoding, frame
streaming and bounded high-compression (HC) encoding. Legacy LZ4 frames are unsupported.

A raw block needs an enclosing record for its encoded boundary, decoded size or capacity, dictionary
agreement and integrity policy. A frame carries block boundaries, options and optional XXH32
checksums. Those checksums detect accidental corruption; they do not authenticate data.

Use [the package setup](../README.md#use-it-in-a-project) with Zig 0.17.0 and import
`@import("wingman").lz4`. From the package checkout, run `zig build lz4-example` or
`zig build lz4-example -- "your text"`. The [example](../examples/lz4.zig) recovers the same input
from greedy raw encoding, HC raw encoding and a checksummed standard frame.

## Operations and storage

| Operation | Entry points | Storage and default extent |
| --- | --- | --- |
| Complete raw block | `block.encode.into`, `block.decode.into` | Encoder workspace; decoding needs only source/output. Exact decoded size by default. |
| HC raw block | `block.encode.hc.into` | Separate HC workspace; same wire format and decoder. |
| Fragmented raw recovery | `block.decode.StreamDecoder.reset`, `step` | Caller-owned 64 KiB history ring. |
| Complete frame | `frame.encode.into`, `frame.decode.into` | Encoder workspace/buffers; decoding needs only source/output. Bounded decoded size by default. |
| Fragmented frame | `frame.encode.StreamEncoder`, `frame.decode.StreamDecoder` | Explicit workspaces borrowed until the owner retires. |

The [public entry](../src/lz4.zig) presents [block](../src/lz4/block.zig) and
[frame](../src/lz4/frame.zig) chapters. Each has `encode` and `decode` operations; HC belongs to
`block.encode.hc`. Concrete stream workers and workspace reservations have named type files. Private
greedy, block-recovery and framing owners keep their algorithms and invariants together. Inline
tests stay with the behavior they qualify.

Codec calls allocate nothing. Workspace `create(allocator)` methods allocate directly at their final
address; `destroy(allocator)` releases the complete reservation with that same allocator. No
allocator is retained. Typed storage is possible where the workspace contract permits it. The frame
encoder retains views into its own staging fields: initialize it at its final address and keep it
stable while in use. Decoder state can transfer between calls with exclusive access to its stable
reservations; retire the old copy after transfer. Input/output bytes require no extra alignment or
padding.

## Complete raw blocks

Reserve the full `try block.encode.bound(source.len)` capacity, even when actual output will be
small. Encoding returns a borrowed used prefix; retain the original full allocation for cleanup:

```zig
const lz4 = @import("wingman").lz4;

const workspace = try lz4.block.encode.Workspace.create(allocator);
defer workspace.destroy(allocator);
const capacity = try lz4.block.encode.bound(source.len);
const storage = try allocator.alloc(u8, capacity);
defer allocator.free(storage);
const encoded = try lz4.block.encode.into(source, storage, workspace, .{});

const restored = try allocator.alloc(u8, expected_size);
defer allocator.free(restored);
const result = try lz4.block.decode.into(encoded, restored, .{});
// result.produced == expected_size; result.consumed == encoded.len.
```

Default raw decoding requires exactly the supplied output length. Use `.{ .output_size = .bounded }`
to admit spare capacity and return the used length. The complete encoded slice is always parsed:
bounded output does not permit ignoring trailing encoded bytes. The unused output suffix stays
unchanged on success. `OutputSizeMismatch` identifies an incorrect exact extent; `OutputTooSmall`
identifies insufficient capacity. Malformed lengths, offsets and termination have separate errors.

Source/output must be disjoint. Complete calls retain neither span; recovered output can outlive
source and workspace. Failure may change a private output prefix. Publish only after complete
validation and any enclosing integrity check, including when a resource limit caused failure.

## Dictionaries and raw fragments

Greedy and HC encoding accept an immutable dictionary slice. Decoding accepts
`block.decode.History`, two chronological spans named `older` and `newer`. This represents a
dictionary followed by earlier decoded blocks without concatenating them. Only the last 65,535 bytes
are reachable. Reachable history must be disjoint from destination and, for encoding, mutable
scratch. Complete-call borrows end on return. Raw blocks do not identify their dictionary: the
caller must agree on it.

```zig
const encoded = try lz4.block.encode.into(source, storage, workspace, .{
    .dictionary = dictionary,
});
const result = try lz4.block.decode.into(encoded, restored, .{
    .history = .{ .newer = dictionary },
});
```

For resumable recovery, initialize a `block.decode.StreamDecoder` with a separate history ring:

```zig
const history = try allocator.create([65536]u8);
defer allocator.destroy(history);
var decoder: lz4.block.decode.StreamDecoder = undefined;
try decoder.reset(history, .{ .limits = .{ .output_bytes = maximum_decoded_bytes } });
```

Each `step(.{ .bytes = input, .final = at_block_end }, output)` returns `consumed`, `produced` and a
status. Advance by those counts. `need_input` asks for more encoded bytes; `need_output` asks for
output capacity. Resubmit any unconsumed input suffix. True `final` means those bytes reach the
actual encoded block end; preserve that flag when resubmitting its suffix. It does not mean the end
of an arbitrary network fragment.

Accepted input and produced output fragments can retire on return; the ring retains history.
`complete` validates the raw block, and repeated completion returns zero counts. A `step` error
poisons the owner: reset before reuse. Keep state, history and fragments disjoint as documented.
Only the ring is borrowed across calls. Reset or `setDictionary` copies dictionary bytes.

After completion, `nextBlock(.{ .retain_history = true })` starts another block with retained
history; `nextBlock(.{ .retain_history = false })` starts independently. `appendHistory` adds
uncompressed bytes between blocks for a container that owns their framing and accounting. Per-block
counts restart with `nextBlock`. Its default null `limits` reuses the configured ceilings for the
next block; an explicit `limits` value replaces them at that boundary. `counts()` returns copied
input, output and byte-work totals, including admitted partial work when a later error prevents
completion.

## Standard frames

`frame.encode.Options` defaults to independent 64 KiB blocks with a content checksum. Select `.k64`,
`.k256`, `.m1` or `.m4` for maximum block sizes of 64 KiB, 256 KiB, 1 MiB or 4 MiB. Block checksums,
linked blocks, an exact content size, dictionaries and HC are explicit selections. Present zero
content size is distinct from an omitted size.

```zig
const options: lz4.frame.encode.Options = .{
    .block_checksum = true,
    .content_size = source.len,
};
const workspace = try lz4.frame.encode.Workspace.create(allocator, options.block_size);
defer workspace.destroy(allocator);
const capacity = try lz4.frame.encode.bound(source.len, options);
const storage = try allocator.alloc(u8, capacity);
defer allocator.free(storage);
const encoded = try lz4.frame.encode.into(source, storage, .{ .workspace = workspace }, options);
const result = try lz4.frame.decode.into(encoded, restored, .{ .trailing_data = .reject });
// Use restored[0..result.produced].
```

Frame decoding is bounded by default; `.output_size = .exact` requires the destination length
exactly. Default `.frames = .single` stops at the first ordinary or skippable frame, leaving
following bytes unconsumed. `.trailing_data = .reject` rejects that remainder. `.concatenate`
validates the complete supplied sequence. Advance by `consumed` to select the next complete frame
yourself; explicit `.iterate` boundary events belong to the streaming decoder.

All sixteen standard skippable tags are supported. `frame.encode.skippable.into` writes a complete
payload/header; `frame.encode.skippable.header` supplies just its eight-byte header. Skippable
payload produces no decoded bytes, but charges encoded-byte and frame limits. Returned frame counts
include skippables, with a separate `skippable_frames` count.

Block checksums cover encoded block bytes; content checksums cover restored content. Complete frame
decoding verifies each block checksum before recovery. Streaming may emit private bytes before its
checksums and content size can be verified. Treat output as unverified until successful completion.
Each frame resets history and checksum state; independent blocks restart from the initial
dictionary.

## Streaming frames and dictionary IDs

`frame.decode.StreamDecoder.reset(workspace, options)` borrows a `frame.decode.Workspace`, with a
fixed 128 KiB history/dictionary reservation regardless of advertised block size. Its `step` uses
the raw decoder's finality/progress rules. Under `.iterate`, `frame_end` reports a verified frame
and waits for `nextFrame()`; `.concatenate` continues to explicit EOF. Copied `descriptor` and
cumulative `counts()` remain available.

Dictionary IDs are application identifiers, not hashes or proof of dictionary contents. IDs include
zero. Supply `frame.Dictionary` at reset, or resolve `need_dictionary` by inspecting `descriptor`
and calling `setDictionary(id, bytes)`. A wrong ID can be retried. Matching dictionary bytes are
copied and can retire. Frames without IDs may use an out-of-band dictionary agreement.

`frame.encode.StreamEncoder.reset(storage, options)` borrows its workspace and copies any
dictionary. `step(input, output, action)` accepts fragments and copies pending input into the
workspace. Use `.process` to keep a frame open, `.flush` to emit a short block, or `.finish` to also
emit the footer. Resubmit unconsumed input with the same action. Finish latches after all supplied
input is accepted; then drain with empty input. `flushed` permits further input; only finish returns
`complete`. Step errors require reset.

`frame.encode.bound` bounds complete encoding with the selected block size. Explicit streaming
flushes may add short blocks, so reserve or emit output incrementally for that route. Callers own
file/network I/O and flushing; the codecs retain no I/O provider.

## HC search and limits

HC produces ordinary blocks using a separate `block.encode.hc.Workspace`. Its `Options` combine
borrowed dictionary bytes with a `Policy`: `.balanced` or `.offline` search, `.size` or
`.throughput` decoder-cost pricing and `limits.work_units`. These profiles are not upstream numeric
compression levels. The workspace's `stats` reports work, probes and sequences. `clear()` explicitly
erases HC workspace; other destruction methods do not promise automatic erasure.

For HC frames, supply `hc_workspace` in `frame.encode.Storage` and select
`.compression = .{ .hc = .{} }`. The HC payload is a dictionary-free `block.encode.hc.Policy`; frame
dictionary bytes and their ID belong to `frame.encode.Options.dictionary`. HC effort accumulates
across the frame, including repeated dictionary priming; byte admission stays independent. Missing
selected HC storage is an options error. Unused HC storage may be supplied with fast policy without
being borrowed. `StreamEncoder.counts()` reports frame byte/work totals and completed-block HC
effort. On refusal, the failing block's partial HC effort remains available in the selected HC
workspace's `stats`.

Raw/frame decode limits bound accepted input, decoded output and byte work. Frames also bound frame
count and advertised block size. Frame encoding bounds accepted input and produced wire bytes. Byte
work counts input plus output once, excluding copied initial dictionaries; it is not a wall-clock or
complete CPU-instruction budget. HC separately charges one unit per insertion, eligible chain probe,
additional comparison and parser edge. A probe includes its initial four-byte prefix check; each
later endpoint-word, extension-word or scalar comparison counts even when it finds a mismatch. The
HC frame allowance covers all its blocks, including search that ultimately stores a block verbatim.
Defaults are permissive: choose finite limits before decoding untrusted input or allocating from an
untrusted size. Exhaustion is not successful partial output.

## Mechanisms and validation

A raw sequence stores literals and a match: a backward distance and copy length. Matches can read
newly produced output, growing short patterns. Recovery uses guarded bulk paths and exact tails
without reading outside supplied spans. Encoding preserves LZ4's final-literal and last-match
restrictions. Greedy encoding uses a compact hash table. HC uses hash chains, exact serialized-byte
prices, a 2 KiB parsing horizon and a long-match shortcut. One path per position and bounded search
avoid a global-optimality claim. Throughput pricing is a heuristic, not a decoder-latency guarantee.

Inline tests cover frozen independent blocks, exact/bounded output, overlapping distances,
dictionaries, retired fragments and ring wrap, malformed input, aliases, limits, poisoning,
checksums, frame policies, all block sizes, flush/finish, storage retry and allocation cleanup. The
separate consumer checks complete public calls through the packaged API.

Format references:
[LZ4 block specification 1.10.0](https://github.com/lz4/lz4/blob/ebb370ca83af193212df4dcbadcc5d87bc0de2f0/doc/lz4_Block_format.md)
and
[frame specification 1.6.4](https://github.com/lz4/lz4/blob/ebb370ca83af193212df4dcbadcc5d87bc0de2f0/doc/lz4_Frame_format.md).
Algorithm and frozen-vector credits remain beside their owners. The implementation is covered by the
package's [MIT license](../LICENSE).
