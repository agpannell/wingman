# PNG and APNG

PNG stores lossless raster images with checksummed chunks, filtering and zlib-compressed samples.
APNG adds timed frames and composition rules. `wingman.png` inspects and writes both formats,
recovers typed RGBA samples, and prepares animations for caller-controlled playback. It also offers
crops, rows and fragmented input when a complete owned image is not the right storage model.

Run `zig build png-example` to encode and recover two RGBA pixels. The [static
example](../examples/png.zig) uses the complete-buffer APIs. Run `zig build png-animation-example`
for an [APNG example](../examples/png_animation.zig) that constructs, decodes and plays two frames.
PNG data and metadata are described by the [PNG Third
Edition](https://www.w3.org/TR/2025/REC-png-3-20250624/).

## Inspect and decode

`Source.open` validates chunk framing, CRCs, ordering and supported geometry. It borrows encoded
bytes; keep them immutable while using the source or its metadata views. `Source.header` copies
layout facts. Opening checks structure but does not establish that image data can be reconstructed;
perform a decode to validate the compressed stream and samples. `Source.open` and `decode.rgbaAlloc`
default to a maximum width or height of 4,096 pixels; set `maximum_source_extent` in their
respective options to admit a larger supported image.

This helper returns a copied first pixel and releases the decoded image before returning:

```zig
const std = @import("std");
const png = @import("wingman").png;

fn firstPixel(allocator: std.mem.Allocator, encoded: []const u8) ![4]u8 {
    var image = try png.decode.rgbaAlloc(u8, allocator, encoded, .{});
    defer image.deinit(allocator);
    return image.texels[0..4].*;
}
```

`decode.rgbaAlloc` accepts `u8` or `u16` output and returns owned top-left row-major RGBA samples.
Release the result through `deinit` with the output allocator. Byte output takes the high byte of
16-bit samples; word output preserves 16-bit precision and scales narrower samples over 0–65535.
Both output types retain `encoded_bit_depth` and `encoded_color_type`, so callers can inspect the
original layout even after conversion to RGBA. `metadata_presence` records which metadata
declarations were observed; query `Source.metadata()` for their values. Alpha remains unassociated.
Color, gamma and orientation metadata are reported without transforming samples. Missing palette
entries decode as opaque black by default; select `.reject` through the `palette_index_policy` for
strict ingestion.

`decode.rgbaAllocWithScratch` separates output and scratch allocators and uses bounded row replay.
The single-allocator call can transfer validated temporary storage to the result; this can avoid a
second traversal at the cost of different temporary capacity. No allocator is retained. A failure
releases partial owned results.

## Prepared output, regions and fragments

`decode.Workspace(Sample).byteCount` and `initBuffer` bind caller backing without allocation;
`initCapacity` allocates one reservation and `deinit` frees it through the same allocator. Use the
prepared storage with `decode.rgbaInto` or `Source.decodeRgbaInto`; `decode.IntoOptions` selects the
publication policy. Output is transactional by default: a reported error leaves the entire
destination unchanged. Explicit `.partial` publication allows provisional output before a later
failure. In either case, keep borrowed input and prepared storage stable and mutually disjoint
throughout the call.

A `wingman.ImageRegion` selects a nonempty rectangle on the source's top-left pixel grid.
`decode.regionRequirements` and `decode.regionInto` compute and write a crop with caller storage; complete
source validation covers pixels outside the selected rectangle. `Source.rowReader()` constructs a
`decode.RowReader` that reads selected rows into caller storage. Its row views borrow that storage and must
be consumed before reuse. Keep calling `read` until it returns null, including after the last wanted
row, to validate trailing rows, complete stream length and checksum.

For fragmented input, `decode.StreamDecoder(Sample)` accepts its nested `Input` and reports input progress and
events. Provide the reservations described by its static `plan(header, options)`. The raster storage holds
history, two `packed_rows` for predictor history and one full-width RGBA `conversion_row`.
`StreamDecoder(Sample).Storage.output_row` holds the selected row returned to the caller; reserve
`output_row_samples` or `output_row_bytes` from `StreamDecoder(Sample).Requirements`. Indexed palettes and Adam7
reconstruction have separate backing requirements.

Consumed fragments may retire. Mark the fragment reaching the physical end as final; after a row
pause, resubmit its unconsumed suffix and drain empty input until completion. The decoder latches
the final flag. Sequential rows are provisional until complete validation; Adam7 rows follow
validated physical EOF. A row's `metadata_presence_complete` describes observed chunk flags,
independently of pixel validity or parsed metadata values. Fragmented input decodes the
static/default image, not incremental APNG frame data. Reset after failure or cancellation before
reuse.

`maximum_source_extent` bounds input-image axes. APNG inspection and decoding call that bound
`maximum_canvas_extent`; both default to 4,096 pixels. A fragmented decoder's
`maximum_selected_extent` bounds the selected rectangle separately from
`policy.maximum_source_extent`. Other output, scratch and work limits still apply.

`Limits` separately bounds output pixels and bytes, simultaneously live scratch, work, records and
metadata. Source dimensions and encoded input have additional admission options. An admitted
`Source` retains its structural counts, so stricter record and metadata limits apply to subsequent
prepared operations. Geometry-only `Header` planning cannot recheck those counts. Work units
describe codec operations, not elapsed time. Raise limits explicitly for larger supported data.

## Metadata and APNG

`Source.metadata()` constructs a reader over borrowed encoded bytes. Call `reader.read(.{})` to
check and obtain color, density, animation, Exif and ICC declarations. Use `reader.texts(.{})` and
the returned iterator's `next()` to read text records. Compressed text and profiles expand into
explicit caller storage. Metadata does not select a color transform, orientation policy or
application text handling; those decisions belong to the caller. The separate [`exif`](exif.md) and
[`icc`](icc.md) guides describe their storage inspection APIs.

`AnimationSource.open` inspects APNG controls and frame-local data. `decode.animation.alloc` prepares
all frames with explicit allocator authority; release the animation with its allocator. Construct
`Animation(Sample).Player` with a stable borrowed animation and its own reserved canvas. `next` composes the
next frame without allocating and returns a borrowed canvas plus the exact encoded delay. Player
follows the declared play count; the caller schedules frames using their delays. Frame disposal,
blending and excluded poster handling follow the admitted animation data. Playback supplies no
clock, display or color management.

## Inspect and write chunks

`Source.chunks()` visits the complete containing PNG, including unknown chunks and `IEND`. A
frame-local source visits the same containing file. Each `Chunk` copies its four-byte name and
borrows its payload from the unchanged input. For chunk inspection without image-layout admission,
start with `Chunk.Iterator.init(encoded)` instead. Iteration checks bounds, chunk names, lengths and
CRCs; it does not interpret payloads or establish PNG ordering and pixel validity.

The following helpers use the imports above. `privateData` returns a payload borrowed from
`encoded`; keep those bytes alive and unchanged while using it. `writePrivateChunk` returns a prefix
of the supplied destination and requires disjoint payload and destination storage.

```zig
fn privateData(encoded: []const u8) !?[]const u8 {
    const source = try png.Source.open(encoded, .{});
    var chunks = source.chunks();
    while (try chunks.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.name, "vpAg")) return chunk.data;
    }
    return null;
}

fn writePrivateChunk(destination: []u8, payload: []const u8) ![]u8 {
    const custom: png.Chunk = .{ .name = "vpAg".*, .data = payload };
    return custom.writeInto(destination);
}
```

`Chunk.byteCount()` includes framing and CRC bytes. `writeInto` writes one chunk with a generated
CRC into disjoint caller storage and preserves unused capacity. Iteration tolerates the reserved
chunk-type bit for forward-compatible reading; writing requires that bit to be clear. It does not
emit a PNG signature or arrange a complete image. `isAncillary` and `isPrivate` describe chunk-type
property bits. `isSafeToCopy` identifies ancillary chunks whose type permits copying after critical
data changes; it returns false for every critical chunk. Custom metadata normally uses a name with a
lowercase first letter, a lowercase second letter for a private type, and an uppercase third letter.

`Chunk.Validator` checks ordering, image layout and structural limits across a sequence. Call
`start`, optionally `validateChunkHeader`, then `complete` after accepting each chunk's CRC.
`finish` returns copied header facts after IEND. Its options limit dimensions, chunk count and
ancillary bytes; callers check byte bounds, CRCs and complete encoded size.

A private chunk carries an application-defined extension. When rewriting a PNG, retain
critical-chunk ordering. Preserve an unknown unsafe-to-copy chunk only when critical chunks remain
unchanged, and keep unknown safe-to-copy chunks on their original side of `IDAT`. Typed image and
metadata encoding remain available for writing recognized fields.

## Encode

`ImageInput` describes a static image; `AnimationInput` holds the canvas and its
`AnimationInput.Frame` descriptions. `Metadata.Input` holds ancillary records, with
`Metadata.Input.Text` and `Metadata.Input.IccProfile` describing its text and profile inputs.
Their borrowed bytes stay live and unchanged throughout encoding. `Metadata.Input.Text.compress`
requests compression of its uncompressed text bytes.

`ImageInput` describes the caller's borrowed samples, strides, palette and transparency. `rgba8` and
`rgba16` construct tightly packed inputs. `encode.alloc` returns owned PNG bytes; free them through
the supplied allocator. `encode.allocWithScratch` separates output and scratch authority.
`encode.requirements` and `encode.Workspace` support bounded `encode.into` with caller-owned output
and workspace; reserve the reported capacity before writing. The encoder workspace contains
substantial compression state, even for small images; query the requirements rather than placing it
on the stack.

Options choose filtering, compression effort, sequential or Adam7 traversal, typed metadata, data
chunk size and resource limits. Static and animation defaults use adaptive filtering and level 6
compression with automatic lookahead. Automatic selects reduced lookahead for ordinary level 6, and
full lookahead for other levels or strategies. Assigning a new compression value uses that type’s
full-lookahead default unless specified otherwise. Choose level 9 for more compression effort.
`encode.alloc` returns exact-size owned bytes. For eligible inputs it may first reserve a
conservative output bound within the scratch budget, compress once and shrink. If the allocator
cannot shrink, it replays into an exact-size allocation. Other inputs and `encode.allocWithScratch`
count first, retaining up to 4 KiB of compressed raster data; larger raster streams require
recompression.

`encode.allocWithRetention` counts first using caller-provided retention instead of the internal 4
KiB buffer. It reuses the compressed raster when it fits, otherwise replays compression. The entire
span counts against the scratch limit alongside encoder workspace. Keep retention disjoint from
inputs and allocator results; its bytes may change on failure. The returned PNG borrows no retention
or source storage and must be freed through the output allocator.

`encode.into` compresses once into caller-provided capacity. Lower compression levels can reduce
encoding work at the cost of different output size. The PNG encoder's work limit budgets an estimate
for filtering, serialization, palette checks and metadata; it does not bound the DEFLATE encoder's
match search. Compression settings control that search effort. PNG and APNG animation writers
preserve input sample meaning; callers choose color and metadata policy. `encode.animation.alloc` and
`encode.animation.into` write animation frames with explicit controls.

## Reading the implementation

The [PNG index](../src/png.zig) presents `decode` and `encode` operations alongside the source,
input, result, animation and metadata concepts. Operation-specific options and storage live under
those namespaces; stream events belong to `decode.StreamDecoder(Sample)`, rows to
`decode.RowReader(Sample)`, and playback state to `Animation(Sample).Player`.

[Source](../src/png/Source.zig) admits structure and exposes borrowed image data.
[Chunk](../src/png/Chunk.zig) owns record iteration and ordering validation;
[Header](../src/png/Header.zig) owns copied geometry. [AnimationSource](../src/png/AnimationSource.zig)
adds APNG structure and frame-local source views. [Metadata](../src/png/metadata.zig) groups checked
values, readers and input schemas; its compression and emission live in the
[metadata encoder](../src/png/metadata_encode.zig).

[Image decoding](../src/png/image_decode.zig) coordinates owned and caller-provided output.
[Region decoding](../src/png/region_decode.zig), the [row reader](../src/png/row_reader.zig) and the
[fragmented-input decoder](../src/png/stream_decoder.zig) share selected geometry and the
[raster decoder](../src/png/raster_decoder.zig). [Scanline filters](../src/png/scanline_filters.zig)
implement predictors and their inverse; [RgbaConverter](../src/png/RgbaConverter.zig) interprets
samples, transparency and palettes. The general pull reader belongs to [zlib](../src/zlib/Reader.zig),
while PNG's [ImageData](../src/png/ImageData.zig) replays admitted IDAT/fdAT payloads.

[Image encoding](../src/png/image_encode.zig) and [animation encoding](../src/png/animation_encode.zig)
coordinate their respective inputs. The [raster encoder](../src/png/raster_encode.zig) serializes
samples and compresses filtered rows; [ChunkWriter](../src/png/ChunkWriter.zig) owns bounded wire
framing. [Animation](../src/png/animation.zig) owns decoded frames and its nested playback worker;
the application controls scheduling and display.
