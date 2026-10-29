# RIFF containers

RIFF groups bytes into named chunks. WAVE audio and WebP images use this envelope, with their own
rules for the contents. `wingman.riff` reads and writes the envelope so an application can inspect
metadata, skip unknown chunks or pass a bounded payload to its decoder.

Reading allocates nothing. A container, chunk or list borrows unchanged input; copied headers and
form/list types do not. Writing accepts `*std.Io.Writer`, so the same functions work with fixed
buffers, files or a caller's writer backend. The library retains no writer, allocator or scheduler.

## Inspect a container

`parse` checks the outer RIFF header and its declared extent. The returned `source` contains that
prefix, including its twelve-byte header. Trailing bytes are outside it. Iteration checks one child
at a time; successful outer parsing does not establish that every child or payload is valid.

```zig
const std = @import("std");
const riff = @import("wingman").riff;

test "inspect a bounded RIFF form" {
    const bytes = "RIFF\x0e\x00\x00\x00DEMOnote\x01\x00\x00\x00x\x00tail";
    const form = try riff.parse(bytes);
    try std.testing.expectEqualStrings("DEMO", &form.form_type);
    try std.testing.expectEqual(22, form.source.len);
    var chunks = form.iterator();
    const chunk = (try chunks.next()).?;
    try std.testing.expectEqualStrings("note", chunk.id);
    try std.testing.expectEqualStrings("x", chunk.data);
    try std.testing.expectEqual(0, chunk.padding.?);
    try std.testing.expectEqual(null, try chunks.next());
}
```

Chunks keep their borrowed ID and payload after the iterator advances. Copying an iterator makes
an independent cursor over the same source. Keep that source live and unchanged through every view's
last use. Obtain containers through `parse`; manually constructed public values must preserve the
same source extents and field invariants.

## Sizes, identifiers and padding

A four-character code, or **FourCC**, is four exact bytes. Case and spaces are significant. Framing
preserves arbitrary IDs; it does not validate a format's registry or required chunk order.

| Part | Encoded extent | What its size field counts |
| --- | --- | --- |
| Chunk header | Four ID bytes and a little-endian `u32` size | Payload bytes only |
| Chunk body | Payload followed by one pad byte when its length is odd | Padding is excluded |
| RIFF or LIST payload | Four-byte form/list type, then encoded child chunks | Type, child headers, payloads and child padding |

`chunkSize(n)` returns `8 + n + (n & 1)`, checking the 32-bit size field and the selected
address space. `writeHeader(type, body_bytes, writer)` adds the four-byte form type itself;
`body_bytes` is the sum of the encoded child extents.

The writer emits zero padding. Reading exposes the actual byte as `Chunk.padding`, without rejecting
a nonzero value. A form that requires zero padding must enforce it. This distinction also applies to
outer trailing bytes, duplicate chunks, ID validity and payload contents: geometry admission is
useful independently of complete-file conformance.

## Write with caller storage

Reserve the encoded extent before using a fixed writer. `writeChunk` writes a complete chunk;
`writeChunkHeader` is available when the caller will emit the exact payload and padding itself.

```zig
const std = @import("std");
const riff = @import("wingman").riff;

test "write a RIFF form into fixed storage" {
    const body_size = try riff.chunkSize(1);
    var bytes: [12 + 10]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try riff.writeHeader("DEMO".*, body_size, &writer);
    try riff.writeChunk("note".*, "x", &writer);
    try std.testing.expectEqualStrings(
        "RIFF\x0e\x00\x00\x00DEMOnote\x01\x00\x00\x00x\x00",
        writer.buffered(),
    );
}
```

Payload and writer backing storage must be disjoint. Size refusals occur before writing; a backend
failure can leave a prefix already buffered or sent. The caller owns flushing, allocation and any
transaction needed before publishing output. A file writer supplies its `interface`; its chosen
`std.Io` implementation supplies file operations.

## Nested lists and resolved sizes

`Chunk.list` accepts `RIFF` or `LIST` with at least four payload bytes. It copies the type.
The returned child region borrows the parent. Traversal stays explicit, letting the caller choose
which lists to inspect and how much nesting or total work to admit.

```zig
const std = @import("std");
const riff = @import("wingman").riff;

test "select one nested list" {
    var outer: riff.ChunkIterator = .{
        .source = "LIST\x0e\x00\x00\x00INFOnote\x01\x00\x00\x00x\x00",
    };
    const list = try (try outer.next()).?.list();
    try std.testing.expectEqualStrings("INFO", &list.list_type);
    var children = list.iterator();
    try std.testing.expectEqualStrings("x", (try children.next()).?.data);
    try std.testing.expectEqual(null, try children.next());
}
```

`ChunkIterator.nextResolved(u64)` substitutes a caller-resolved payload length for the current
header's `u32` field. It checks the same payload/padding geometry and address-space limits.
An RF64 adapter can use this primitive after applying its directory rules; it does not make
`parse` an RF64 parser. On failure the cursor is unchanged, allowing a corrected resolved size to
be retried. At the exact end either iterator method returns `null`; an offset beyond the region
or a truncated chunk returns an error.

## API and scope

| Operation or type | Contract |
| --- | --- |
| `FourCc`, `ChunkHeader`, `readHeader` | Copied four-byte ID and unsigned size; header reading alone does not admit a payload |
| `Container`, `parse`, `Container.iterator` | Declared RIFF prefix and independent child traversal |
| `Chunk`, `List`, `Chunk.list`, `List.iterator` | Borrowed payloads and explicitly selected nested children |
| `ChunkIterator.next`, `nextResolved` | Bounded progress; failure preserves the cursor |
| `chunkSize` | Checked complete chunk extent, including padding |
| `writeHeader`, `writeChunkHeader`, `writeChunk` | Checked framing through `std.Io.Writer` |

`ParseError` distinguishes invalid/truncated framing from an extent that overflows the address
space. `WriteError` combines `SizeOverflow` with the writer's `WriteFailed`. No operation implicitly
recurses, decodes media, validates every format rule or retains hidden allocation state. RIFX and
RF64 outer headers are rejected. A complete immutable input span is required; fragmented input
recovery is outside this API.

Run `zig build riff-example` to write and inspect nested `DEMO`/`INFO` chunks. An optional text
argument changes the `note` payload: `zig build riff-example -- hello`. The example allocates its
own storage; the framing calls do not. Generate the declaration reference with `zig build docs`.
Tests cover fixed independent bytes, malformed extents, cursor behavior, exact IDs and padding,
copied/borrowed lifetimes, writer capacity and size limits. No throughput claim is made.

The format geometry follows Microsoft's
[RIFF layout](https://learn.microsoft.com/en-us/windows/win32/xaudio2/resource-interchange-file-format--riff-)
and [RIFF services](https://learn.microsoft.com/en-us/windows/win32/multimedia/resource-interchange-file-format-services)
descriptions. These describe the envelope; each payload format supplies its own rules.
