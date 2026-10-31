# gzip members

gzip wraps a DEFLATE stream in a member with a header, CRC-32 checksum and original-size trailer.
`wingman.gzip` encodes and verifies [RFC 1952](https://www.rfc-editor.org/rfc/rfc1952) members,
including optional metadata and concatenated members. For raw streams use [`wingman.deflate`](deflate.md);
for the distinct RFC 1950 wrapper use [`wingman.zlib`](zlib.md). CRC-32 detects accidental
corruption; it does not authenticate content.

Run `zig build gzip-example` or pass text after `--`. The [example](../examples/gzip.zig) writes
one member with a name and header checksum, inspects the header and verifies the restored bytes.

## Complete members

Create separate caller-owned encoding and decoding workspaces at stable addresses and destroy them
through the same allocator. They are the same workspace types used by raw DEFLATE; see the
[storage guide](deflate.md#complete-buffers) for approximate sizes. Codec calls allocate nothing
and retain no input, output or allocator after return.

```zig
const gzip = @import("wingman").gzip;

const encoder = try gzip.EncoderWorkspace.create(allocator);
defer encoder.destroy(allocator);
defer encoder.clear();
const decoder = try gzip.DecoderWorkspace.create(allocator);
defer decoder.destroy(allocator);
const options: gzip.EncodeOptions = .{ .name = "sample.txt", .header_crc = true };
const storage = try allocator.alloc(u8, try gzip.encodeBound(source.len, options));
defer allocator.free(storage);
const encoded = try gzip.encode(source, storage, encoder, options);
const restored = try allocator.alloc(u8, expected_size);
defer allocator.free(restored);
const result = try gzip.decode(encoded, restored, .{ .workspace = decoder }, .{
    .output_size = .exact,
    .trailing_data = .reject,
});
// result.members == 1 and result.produced == expected_size.
```

The encoded prefix borrows the output reservation. Encoding uses an explicit timestamp and
metadata; it does not read a clock. `EncodeOptions.deflate` selects compression effort, window and
per-member limits. Preset dictionaries are unsupported in gzip. Optional extra data is limited to
65,535 bytes; names and comments cannot contain NUL. The encoder copies metadata while initializing
its state. `header_crc` requests the format's optional FHCRC; the data CRC-32 and original-size
trailer are always written.

Complete decoding verifies headers, optional FHCRC, data CRC-32 and original size modulo 2³². The
default decodes one member, accepts bounded output and leaves following input unconsumed. Exact
output and trailing-data rejection are separate options. Select `.members = .concatenate` to decode
all supplied members; concatenation rejects trailing garbage. `MemberIterator` instead verifies
and returns one member at a time, advancing only after successful validation.

Source, output and used workspaces must be disjoint; overlap returns `StorageOverlap`. Failures can
change output or scratch and publish no progress counts. Do not publish failed output. Complete
calls reuse workspaces after success or failure. Input, output and work limits are caller options;
complete decoding defaults to unbounded optional header fields, so select finite `header_limits`
when handling input with an explicit resource policy.

## Headers and streaming

`parseHeader` validates and returns header facts without decoding the payload. Optional metadata
views borrow the encoded source. Names and comments are uninterpreted bytes: the caller owns any
text decoding, filename handling or path policy. `HeaderLimits` independently bounds field and
total header sizes. Header inspection alone does not validate the compressed payload or trailer.

`Encoder` accepts fragments and supports process, flush, full-flush and finish. `nextMember` starts
another member with independent history while cumulative statistics continue. The caller supplies
metadata and output; consumed fragments can retire after each step.

`Decoder` borrows an exclusive workspace and separate 32 KiB history; optional `HeaderBuffers`
capture metadata in caller storage. It can stop after one member, return each verified member for
explicit iteration, or concatenate until EOF. Supply the final-input flag only for the true end of
the input and retain it with any unconsumed suffix. Streaming output is provisional until its
member's CRC and size verify. After an error, reset the owner before reuse. Captured header views
borrow the caller's capture buffers; without capture, lengths and flags are still available.
