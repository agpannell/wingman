# zlib streams

A zlib stream wraps DEFLATE-compressed bytes with a header and an Adler-32 checksum. Use
`wingman.zlib` to encode or decode the [RFC 1950](https://www.rfc-editor.org/rfc/rfc1950)
representation, including optional preset dictionaries. For unwrapped compressed data, use
[`wingman.deflate`](deflate.md). Adler-32 detects accidental corruption; it does not authenticate
content.

Run `zig build zlib-example` or pass text after `--`. The [example](../examples/zlib.zig) encodes a
complete stream and verifies its checksum while decoding.

## Complete buffers

Use separate caller-owned encoding and decoding workspaces. Construct them at stable addresses
with `create(allocator)` and destroy them through the same allocator. The workspaces are shared with
the raw DEFLATE library; the [storage guide](deflate.md#complete-buffers) gives their approximate
sizes. Codec operations allocate nothing and retain no buffer pointers or allocator.

```zig
const zlib = @import("wingman").zlib;

const encoder = try zlib.EncoderWorkspace.create(allocator);
defer encoder.destroy(allocator);
defer encoder.clear();
const decoder = try zlib.DecoderWorkspace.create(allocator);
defer decoder.destroy(allocator);
const storage = try allocator.alloc(u8, try zlib.encodeBound(source.len, .{}));
defer allocator.free(storage);
const encoded = try zlib.encode(source, storage, encoder, .{});

const restored = try allocator.alloc(u8, expected_size);
defer allocator.free(restored);
const result = try zlib.decode(encoded, restored, .{ .workspace = decoder }, .{
    .output_size = .exact,
    .trailing_data = .reject,
});
// result.consumed == encoded.len and result.produced == expected_size.
```

The encoded prefix borrows its output reservation. Successful decoding verifies the header,
declared window, payload and Adler-32 trailer; its copied counts include the zlib framing. The
default accepts a bounded destination and leaves following input unconsumed. Select exact output and
rejected trailing data independently when the enclosing format supplies those constraints. Unused
output stays unchanged on success.

Source, output and used workspaces must be disjoint; overlap returns `StorageOverlap`. Failures
can change output or scratch and return no progress counts; do not publish failed output.
Byte and algorithmic work limits are explicit options; the encoder's raw effort and limits live in
`EncodeOptions.deflate` and count zlib framing in its output limit.

## Preset dictionaries

For complete encoding, pass the dictionary in `EncodeOptions.dictionary`. For complete decoding,
pass it in `DecodeOptions.dictionary` and supply an independent 32 KiB `DecodeStorage.history`.
The header identifies the full dictionary by Adler-32; the codec uses only the reachable suffix as
history. An attached empty dictionary is distinct from no dictionary. The checksum is an identity
check for this format, not cryptographic proof of identity.

A streaming decoder returns `need_dictionary`; obtain `dictionaryId`, choose the matching bytes,
then call `setDictionary`. The decoder copies the required history, so dictionary backing may retire
on return. A mismatch returns `WrongDictionary`. Use the wrapper's dictionary field when encoding;
a dictionary set in the nested raw DEFLATE options is invalid.

## Fragmented streams and Readers

`Encoder` and `Decoder` use caller-owned workspaces and report consumed and produced counts for
each fragment. Encoding supports process, flush, full-flush and finish; decoding reports input,
output, dictionary or completion boundaries. Input fragments may retire after each call. Streaming
output is provisional until `complete` confirms the checksum. After an error, reset the owner
before reuse. A decoder needs a separate 32 KiB history buffer; its small state may be transferred
between calls only when exclusive access to the same reservations transfers with it.

`decodeReader` drives an initialized decoder from `std.Io.Reader` and keeps buffered lookahead in
the reader. Transport failures remain `ReadFailed`. `decodeStoredReader` is a separate,
workspace-free operation for stored blocks only. It returns null for compressed blocks, possibly
after consuming input and writing a prefix; rewind or recreate the reader before a general decode.
Errors may also change reader and output state. Neither Reader API performs I/O scheduling itself.
