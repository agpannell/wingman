# Raw DEFLATE

DEFLATE compresses byte streams using backward references and Huffman codes. `wingman.deflate`
encodes and decodes raw [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951) streams, including
stored, fixed-Huffman and dynamic-Huffman blocks. It supports complete buffers and resumable input,
preset dictionaries, work limits and caller-owned storage.

A raw DEFLATE stream has no checksum, decoded-size field or dictionary identifier. Formats such as
zlib and gzip provide their own wrapper and integrity checks; this library accepts the raw stream,
not those wrappers. Use [`wingman.zlib`](zlib.md) for zlib framing or [`wingman.gzip`](gzip.md)
for gzip members. The enclosing format or application must select the matching dictionary, bound
resources and verify integrity before using untrusted output.

Run `zig build deflate-example`, or pass text after `--`. The [example](../examples/deflate.zig)
encodes and recovers a complete raw stream.

## Complete buffers

Create separate encoding and decoding workspaces at stable addresses with the allocator that will
later destroy them. Codec calls allocate nothing and retain neither buffer nor allocator. An encoder
workspace contains substantial search storage; avoid placing a large temporary on the stack.
On x86-64 with Zig 0.17.0, the encoder workspace is about 6 MiB and the decoder workspace is
about 20 KiB. Exact sizes depend on the target; use `@sizeOf` for the workspace type.

```zig
const deflate = @import("wingman").deflate;

const encoder = try deflate.EncoderWorkspace.create(allocator);
defer encoder.destroy(allocator);
defer encoder.clear();
const decoder = try deflate.DecoderWorkspace.create(allocator);
defer decoder.destroy(allocator);
const storage = try allocator.alloc(u8, try deflate.encodeBound(source.len));
defer allocator.free(storage);
const encoded = try deflate.encode(source, storage, encoder, .{});

const restored = try allocator.alloc(u8, expected_size);
defer allocator.free(restored);
const result = try deflate.decode(encoded, restored, .{ .workspace = decoder }, .{
    .output_size = .exact,
    .trailing_data = .reject,
});
// result.consumed == encoded.len and result.produced == expected_size.
```

Encoding returns a prefix borrowed from output; retain the full reservation for cleanup. Its
`.offline` default spends more work looking for a smaller result. Select `.stored`, `.huffman`,
`.greedy` or `.lazy` to change effort; all produce ordinary DEFLATE. The options also bound input,
output and algorithmic work. Work units are not elapsed time or instruction counts.

Decoding defaults to bounded output and allows following input. On success, copied `consumed` and
`produced` counts identify the raw stream and initialized output; unused output stays unchanged.
Use `.output_size = .exact` to require the full destination and `.trailing_data = .reject` to
require all supplied input. Decode limits bound accepted input, restored output and their combined
work units. A dictionary-free decode needs only a decoder workspace. A selected preset dictionary
also needs an independent 32 KiB history reservation in `DecodeStorage`.

Source, output and workspace must be disjoint. Overlap is refused before mutation; other failures
can modify output or workspace and publish no progress. Do not publish partial output from a failed
call. A complete-call workspace can be reused after success or failure. `EncoderWorkspace.clear`
clears retained input and scratch when the caller no longer needs them.

## Fragmented streams

`Encoder.reset` exclusively borrows an `EncoderWorkspace` and copies any supplied dictionary.
`step` accepts input and output fragments with `.process`, `.flush`, `.full_flush` or `.finish`.
Progress reports consumed and produced bytes plus `need_input`, `need_output`, `flushed` or
`complete`. Repeat a pending action with its unconsumed input suffix; while draining a latched
flush or finish, pass empty input and the same action. A flush retains history; a full flush clears
it for subsequent input. Both the owner and workspace must remain stable until streaming ends.

`Decoder.reset` borrows a decoder workspace and a separate 32 KiB history buffer. Each `step`
returns copied progress and `need_input`, `need_output` or `complete`. Set `Input.final` only when
that fragment reaches the actual end of the raw stream; retain the flag with any unconsumed suffix.
Consumed fragments may retire immediately because history is retained in caller storage. Stream
limits are cumulative. An error requires reset before reusing a streaming owner; previously returned
output can be incomplete and must not be treated as a validated complete stream.
