# zlib streams

A zlib stream wraps DEFLATE-compressed bytes with a header and an Adler-32 checksum. Use
`wingman.zlib` to encode or decode the [RFC 1950](https://www.rfc-editor.org/rfc/rfc1950)
representation, including optional preset dictionaries. For unwrapped compressed data, use
[`wingman.deflate`](deflate.md). Adler-32 detects accidental corruption; it does not authenticate
content.

Use [the package setup](../README.md#use-it-in-a-project) with Zig 0.17.0 and import
`@import("wingman").zlib`. From the package checkout, run `zig build zlib-example` or
`zig build zlib-example -- "your text"`. The [example](../examples/zlib.zig) encodes a complete
stream and verifies its checksum while decoding.

## Complete buffers

Use separate caller-owned encoding and decoding workspaces. Construct them at stable addresses with
`create(allocator)` and destroy them through the same allocator. The workspaces are shared with the
raw DEFLATE library; the [storage guide](deflate.md#complete-buffers) explains how to determine
their target-specific sizes. Codec operations allocate nothing and retain no buffer pointers or
allocator.

```zig
const zlib = @import("wingman").zlib;

const encoder = try zlib.encode.Workspace.create(allocator);
defer encoder.destroy(allocator);
defer encoder.clear();
const decoder = try zlib.decode.Workspace.create(allocator);
defer decoder.destroy(allocator);
const storage = try allocator.alloc(u8, try zlib.encode.bound(source.len, .{}));
defer allocator.free(storage);
const encoded = try zlib.encode.into(source, storage, encoder, .{});

const restored = try allocator.alloc(u8, expected_size);
defer allocator.free(restored);
const result = try zlib.decode.into(encoded, restored, .{ .workspace = decoder }, .{
    .output_size = .exact,
    .trailing_data = .reject,
});
// result.consumed == encoded.len and result.produced == expected_size.
```

The encoded prefix borrows its output reservation. Successful decoding verifies the header, declared
window, payload and Adler-32 trailer; its copied counts include the zlib framing. The default
accepts a bounded destination and leaves following input unconsumed. Select exact output and
rejected trailing data independently when the enclosing format supplies those constraints. Unused
output stays unchanged on success. An exact-output mismatch detected in the raw stream returns
`InvalidStream`; the Adler-32 trailer has not necessarily been verified when that error is returned.

Source, output and used workspaces must be disjoint; overlap returns `StorageOverlap`. Failures can
change output or scratch and return no progress counts; do not publish failed output. Byte and
algorithmic work limits are explicit options. `encode.Options` directly describes compression,
window, dictionary and limits; its output limit includes zlib framing.

A container that forbids preset dictionaries can check two header bytes with
`decode.validateDictionaryFreeHeader`. This validates the method, window declaration and header
check bits; it does not verify the payload or Adler-32 trailer.

The raw compression options select levels 0–9, with level 6 as the default and level 0 producing
stored blocks. Level and strategy affect encoding effort, output size, and the header's
informational FLEVEL hint and FCHECK bits. Adler-32 verification remains the same. See the
[DEFLATE guide](deflate.md#complete-buffers) for the level, optional search and pricing settings,
their work and output tradeoffs, and workspace storage contracts.

## Preset dictionaries

For complete encoding, pass the dictionary in `encode.Options.dictionary`. For complete decoding,
pass it in `decode.Options.dictionary` and supply an independent 32 KiB `decode.Storage.history`.
The header identifies the full dictionary by Adler-32; the codec uses only the reachable suffix as
history. An attached empty dictionary is distinct from no dictionary. The checksum is an identity
check for this format, not cryptographic proof of identity.

A streaming decoder returns `need_dictionary`; obtain `dictionaryId`, choose the matching bytes,
then call `setDictionary`. The decoder copies the required history, so dictionary backing may retire
on return. A mismatch returns `WrongDictionary`. Encoding takes the dictionary directly in
`encode.Options.dictionary`.

## Fragmented streams and Readers

`encode.StreamEncoder` and `decode.StreamDecoder` use caller-owned workspaces and report consumed
and produced counts for each fragment. Encoding supports process, flush, full-flush and finish;
decoding reports input, output, dictionary or completion boundaries. Input fragments may retire
after each call. Streaming output is provisional until `complete` confirms the checksum. After an
error, reset the owner before reuse. A decoder needs a separate 32 KiB history buffer. Encoder and
decoder state can transfer between calls with exclusive access to their stable reservations;
retire the old state after transfer.

An encoder step that fails returns no progress value. Its cumulative `counts()` can still include
input and work admitted during the failed step, along with framing bytes already copied to output.

`decode.StreamDecoder.readInto` drives an initialized decoder from `std.Io.Reader` and keeps
buffered lookahead in the reader. Transport failures remain `ReadFailed`.
`decode.consumeStoredReader` is a separate, workspace-free operation for stored blocks only. It
returns null for compressed blocks, possibly after consuming input and writing a prefix; rewind or
recreate the reader before a general decode. Errors may also change reader and output state. Neither
Reader API performs I/O scheduling itself.

`Reader` offers a pull interface when the consumer expects a `std.Io.Reader`. Construct it at its
final address, supply `Reader.history_bytes` of separate caller-owned history and call `init` with
the compressed input reader. Its `reader` field yields decompressed bytes. Keep the adapter, input
reader and history stable and disjoint through use. Drain to `EndOfStream` to verify the checksum;
reading only the expected payload length can leave the trailer unchecked. Following input remains
available in the compressed reader. Malformed streams, dictionary requests and transport failures
become `ReadFailed`; reinitialize before reuse. Use `decode.StreamDecoder` when dictionary handling
or explicit work limits are required.

For small complete streams, `encode.short_stored.into` accepts up to
`encode.short_stored.max_input_bytes` and needs input length plus 11 output bytes.
`encode.four_byte_runs.short.into` accepts up to `encode.four_byte_runs.short.max_input_bytes` and
requires `encode.four_byte_runs.short.output_capacity` bytes, including padding that may change
after the returned prefix. Both use a 32 KiB window, no dictionary or work limit, disjoint source
and output, and allocate nothing. Oversized input returns `LimitExceeded`; length, capacity and
overlap refusals leave output unchanged.

`encode.four_byte_runs.StreamEncoder` uses a smaller workspace for stored and four-byte-run
streaming. Its options default to `.mode = .runs`; choose `.mode = .stored` for uncompressed blocks.
Window, dictionary and limits remain available. Its workspace supports `create`, `clear` and
`destroy` like the full workspace. Its `inputBuffer` and `commitInput` methods also exist on
`encode.StreamEncoder`: drain the zlib header first, fill the borrowed slice, then immediately
commit its initialized prefix without another operation. The borrow ends at commit, which may
produce output and poisons the encoder on error.
