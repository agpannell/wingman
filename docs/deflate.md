# Raw DEFLATE

DEFLATE compresses byte streams using backward references and Huffman codes. `wingman.deflate`
encodes and decodes raw [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951) streams, including
stored, fixed-Huffman and dynamic-Huffman blocks. It supports complete buffers and resumable input,
preset dictionaries, work limits and caller-owned storage.

A raw DEFLATE stream has no checksum, decoded-size field or dictionary identifier. Formats such as
zlib and gzip provide their own wrapper and integrity checks; this library accepts the raw stream,
not those wrappers. Use [`wingman.zlib`](zlib.md) for zlib framing or [`wingman.gzip`](gzip.md) for
gzip members. The enclosing format or application must select the matching dictionary, bound
resources and verify integrity before using untrusted output.

Use [the package setup](../README.md#use-it-in-a-project) with Zig 0.17.0 and import
`@import("wingman").deflate`. From the package checkout, run `zig build deflate-example` or
`zig build deflate-example -- "your text"`. The [example](../examples/deflate.zig) encodes and
recovers both complete and fragmented raw streams.

## Complete buffers

Create separate encoding and decoding workspaces at stable addresses with the allocator that will
later destroy them. Codec calls allocate nothing and retain neither buffer nor allocator. An encoder
workspace contains substantial search storage; avoid placing a large temporary on the stack.
Workspace sizes depend on the target and compiler; use `@sizeOf(deflate.encode.Workspace)` and
`@sizeOf(deflate.decode.Workspace)` for the selected build. Streaming decoding also needs a separate
32 KiB history buffer.

```zig
const deflate = @import("wingman").deflate;

const encoder = try deflate.encode.Workspace.create(allocator);
defer encoder.destroy(allocator);
defer encoder.clear();
const decoder = try deflate.decode.Workspace.create(allocator);
defer decoder.destroy(allocator);
const storage = try allocator.alloc(u8, try deflate.encode.bound(source.len));
defer allocator.free(storage);
const encoded = try deflate.encode.into(source, storage, encoder, .{});

const restored = try allocator.alloc(u8, expected_size);
defer allocator.free(restored);
const result = try deflate.decode.into(encoded, restored, .{ .workspace = decoder }, .{
    .output_size = .exact,
    .trailing_data = .reject,
});
// result.consumed == encoded.len and result.produced == expected_size.
```

Encoding returns a prefix borrowed from output; retain the full reservation for cleanup. Set
`encode.Options.compression.level` from 0 through 9 to choose the effort spent on compression. Level
0 stores bytes without compression; levels 1–3 use greedy matching, 4–6 use lazy matching and 7–9
use offline parsing. The default is level 6. Higher levels generally spend more effort to seek
smaller output, but neither time nor size is guaranteed to improve for every input. Level numbers
are not equivalent to another encoder's settings.

Use `.{ .compression = .{ .level = 9 } }` when more encoding work is appropriate, or set
`compression.strategy = .huffman_only` to skip match search. Level 0 always stores bytes, even with
the Huffman-only strategy. The `four_byte_runs` strategy searches only for patterns repeated at
distance four, then selects among prebuilt dynamic codebooks and stored blocks. It can reduce work
for four-byte residual data, but other input can expand substantially compared with general
matching. Levels 1–9 select the same run policy; level 0 still stores. The strategy operates on
bytes and does not choose PNG filtering. The streaming `encode.four_byte_runs.StreamEncoder` uses
the smaller `encode.four_byte_runs.Workspace`. Its `encode.four_byte_runs.Options` defaults to
`.mode = .runs`; select `.mode = .stored` for uncompressed blocks. Both modes accept window,
dictionary and limits, with no ordinary match-search controls. The workspace has the same `create`,
`clear` and `destroy` lifecycle as `encode.Workspace`.

Each encoding operation can limit input, output and algorithmic work. Work units are not elapsed
time or instruction counts; some bounded pricing scans and dictionary or wrapper metadata work are
not charged. Bound input and metadata separately when those costs matter.

The default compression settings perform full lazy lookahead and full offline pricing with standard
refinement. For ordinary matching at levels 4–6, `lazy_lookahead = .reduced` spends less search
effort on the position after a candidate match. `lazy_lookahead = .automatic` selects reduced
lookahead for ordinary level 6 and full lookahead for other valid combinations. At levels 7–9,
`offline_pricing = .reduced` prices the first retained match supporting each length; that match need
not be the nearest. `offline_pricing = .maximum_lengths` prices only each retained match's longest
length. Both can exclude choices considered by full pricing. `offline_refinement = .early` can stop
after the second pass when the dynamic cost improved by at most 1%; that threshold does not bound
the final change in compressed size. Standard refinement continues until costs stop improving or the
pass limit is reached.

These choices can change encoded bytes, work used and whether a finite work allowance is exhausted;
they do not guarantee faster encoding or smaller output for every input. Explicit reduced lookahead
is valid only for ordinary matching at levels 4–6; automatic is valid for any otherwise valid
combination. Nondefault offline pricing or refinement requires ordinary matching at levels 7–9.
Other combinations return `InvalidOptions`. The input and output limits remain independent of these
settings.

Decoding defaults to bounded output and allows following input. On success, copied `consumed` and
`produced` counts identify the raw stream and initialized output; unused output stays unchanged. Use
`.output_size = .exact` to require the full destination and `.trailing_data = .reject` to require
all supplied input. Decode limits bound accepted input, restored output and their combined work
units. A dictionary-free decode needs only a decoder workspace. A selected preset dictionary also
needs an independent 32 KiB history reservation in `decode.Storage`.

Exact decoding reserves the whole requested destination against output and work limits, even if the
stream ends short. After work admission, a valid raw end before the destination is filled returns
`OutputSizeMismatch`; that result does not validate trailing input or an enclosing checksum. A
rejected trailing suffix is checked after the exact extent. Direct decoding can report
`InvalidStream` for truncated input, while dictionary decoding can report `Truncated`.

Source, output and workspace must be disjoint. Overlap is refused before mutation; other failures
can modify output or workspace and publish no progress. Do not publish partial output from a failed
call. A complete-call workspace can be reused after success or failure. `encode.Workspace.clear`
clears retained input and scratch when the caller no longer needs them.

## Fragmented streams

`encode.StreamEncoder.reset` exclusively borrows an `encode.Workspace` and copies any supplied
dictionary. `step` accepts input and output fragments with `.process`, `.flush`, `.full_flush` or
`.finish`. Progress reports consumed and produced bytes plus `need_input`, `need_output`, `flushed`
or `complete`. Repeat a pending action with its unconsumed input suffix; while draining a latched
flush or finish, pass empty input and the same action. A flush retains history; a full flush clears
it for subsequent input. Keep the workspace stable until streaming ends. The small worker can
transfer between calls with its exclusive workspace borrow; retire the old copy after transfer.

`decode.StreamDecoder.reset` borrows a decoder workspace and a separate 32 KiB history buffer. Each
`step` returns copied progress and `need_input`, `need_output` or `complete`. Set
`decode.StreamDecoder.Input.final` only when that fragment reaches the actual end of the raw stream;
retain the flag with any unconsumed suffix. Consumed fragments may retire immediately because
history is retained in caller storage. Stream limits are cumulative. An error requires reset before
reusing a streaming owner; previously returned output can be incomplete and must not be treated as a
validated complete stream.

For a complete input of at most `encode.four_byte_runs.short.max_input_bytes`,
`encode.four_byte_runs.short.into` writes directly to caller output without a workspace. Reserve
`encode.four_byte_runs.short.output_capacity` bytes, including temporary padding; bytes beyond the
returned prefix may change. It uses no dictionary or work limit. Source and output must be disjoint.
Oversized input returns `LimitExceeded`; length, capacity and overlap refusals leave output
unchanged.

A streaming encoder's `inputBuffer` lends workspace for an immediate fill and `commitInput` call. Do
not call another encoder operation while holding the slice. The commit consumes its initialized
prefix with process semantics and may produce output; drain that output before continuing. A null
borrow means input cannot currently be accepted. Commit failures require reset.
