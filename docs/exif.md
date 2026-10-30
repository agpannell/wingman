# Exif attributes and thumbnails

Exif stores image attributes such as orientation and camera settings in directories built on the
TIFF format. It can also point to an embedded thumbnail. `wingman.exif` inspects this metadata and
its referenced storage without allocating or decoding the main image. It also samples the
supported uncompressed RGB and YCbCr thumbnail layouts as RGB8 pixels.

Pass a complete **classic TIFF payload** to `View.open`. For a JPEG Exif segment, the caller first
removes the enclosing JPEG marker/length and the six-byte `Exif\0\0` signature. This library does
not locate image-container metadata, edit tags or decode JPEG thumbnails. Both TIFF byte orders
are supported; no alignment or input padding is required.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project). The complete
[Exif example](../examples/exif.zig) constructs a small TIFF payload, reads its stored orientation,
checks thumbnail strip storage and samples two RGB pixels.

## Inspect borrowed metadata

Every view, directory, entry, thumbnail and strip borrows the complete TIFF source. Keep its
storage live and unchanged through the last derived use, including raster sampling. Copying a
view copies descriptors and policy, without copying source bytes. Copied scalar values and
returned `[3]u8` pixels are independent. No allocator, retained scheduler or cleanup is needed.

| Operation | Result and admission |
| --- | --- |
| `View.open` | Validate the header and bounded main directory chain |
| `View.primary`, `directoryAt`, `Directory.child` | Select a checked directory; child traversal is explicit |
| `Directory.entry`, `find` | Select an indexed record or a unique tag, including unsorted records |
| `Entry.data` | Validate and borrow the selected field's encoded bytes |
| `Entry.unsigned`, `unsignedScalar` | Read BYTE, SHORT or LONG unsigned values in source byte order |
| `View.orientation` | Read an optional orientation from 1 through 8, rejecting duplicates |
| `View.thumbnail`, `Directory.strips` | Inspect IFD1 thumbnail declarations and checked byte ranges |
| `ThumbnailRaster.open`, `rgb` | Admit supported uncompressed storage and sample its stored grid |

An image file directory (**IFD**) is a bounded set of tag/type/count/value records. The main chain
starts at IFD0; its next directory is IFD1, used by `thumbnail`. `Directory.child(tag)` follows one
selected unsigned offset, such as an Exif or GPS directory pointer. It does not recursively walk
that child's pointers. Applications bound repeated selections and decide which tags to interpret.

```zig
const std = @import("std");
const exif = @import("wingman").exif;

test "read stored orientation and its raw record" {
    const bytes = [_]u8{
        0x49, 0x49, 42, 0, 8, 0, 0, 0,
        1, 0, 0x12, 0x01, 3, 0, 1, 0,
        0, 0, 6, 0, 0, 0, 0, 0, 0, 0,
    };
    const view = try exif.View.open(&bytes, .{});
    try std.testing.expectEqual(exif.Orientation.right_top, (try view.orientation()).?);
    const entry = (try (try view.primary()).find(0x0112)).?;
    try std.testing.expectEqual(6, try entry.unsignedScalar());
    try std.testing.expectEqualSlices(u8, &.{ 6, 0 }, try entry.data());
    try std.testing.expectEqual(null, try view.thumbnail());
}
```

Opening proves the main chain's directory storage, bounds and absence of cycles within admitted
work. It does not establish that every selected tag or referenced field payload is valid.
`find` rejects duplicate occurrences of the requested tag. Unknown tags remain raw entries;
unknown field types stay opaque until a reader requests their bytes. `data` supports classic TIFF
types 1 through 12, returning their encoded representation rather than converting signed values,
floats, strings or rationals into another type.

```zig
const std = @import("std");
const exif = @import("wingman").exif;

test "structural admission leaves unknown field types opaque" {
    const bytes = [_]u8{
        0x49, 0x49, 42, 0, 8, 0, 0, 0,
        1, 0, 0x12, 0x01, 129, 0, 1, 0,
        0, 0, 6, 0, 0, 0, 0, 0, 0, 0,
    };
    const view = try exif.View.open(&bytes, .{});
    const entry = (try view.primary()).entry(0).?;
    try std.testing.expectEqual(129, entry.field_type);
    try std.testing.expectError(error.UnsupportedExif, entry.data());
    try std.testing.expectError(error.InvalidExif, view.orientation());
}
```

`entry(index)` returns null for an absent record; `find(tag)` returns null for an absent tag.
Neither result requires a sorted directory. `isUnsigned` only identifies a BYTE/SHORT/LONG type;
`unsigned` also checks the element index and storage. `unsignedScalar` additionally requires a
single value. `orientation` reports the stored enum and applies no pixel transform.

## Bound each traversal

`InspectOptions.limits` defaults to 16 main-chain directories and 4096 entries across that chain.
The additional `records` ceiling counts each directory header plus its entries and defaults to
`maxInt(usize)`. Admission checks a directory's available allowance before reading its entry body;
a resource refusal can therefore precede a malformed body. Brent's checkpoint algorithm detects
main-chain cycles without allocating a visited set or reading ahead into unadmitted directories.

Explicit `directoryAt` and child selections each apply their own header/entry ceiling from the
view's limits. They do not subtract the main-chain record count, accumulate across calls or prove
that a recursive child graph is acyclic. `Directory.child` refuses a direct self-reference.
`ThumbnailRasterOptions.limits.records` independently defaults to 4096 and bounds that raster's
directory header, entries and strip references. The view's strip-entry limit also applies.

```zig
const std = @import("std");
const exif = @import("wingman").exif;

test "record refusal precedes an unadmitted body" {
    const truncated = [_]u8{ 0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0 };
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        exif.View.open(&truncated, .{ .limits = .{ .records = 1 } }),
    );
    try std.testing.expectError(error.InvalidExif, exif.View.open(&truncated, .{}));
}
```

`InvalidExif` identifies malformed selected structures or fields. `UnsupportedExif` identifies
unsupported TIFF versions, field representations or raster layouts. `MetadataLimitExceeded`
identifies structural admission. Raster opening also reports `InvalidImageExtent` or
`SizeOverflow`. A failed inspection returns no view and never mutates source. These operations do
not certify every Exif writer/version requirement or authenticate the metadata.

## Thumbnail storage and pixels

`thumbnail()` returns null without IFD1. For compression 6 it validates and returns the encoded
JPEG slice, without checking entropy coding or decoding it. Other compression values retain the
thumbnail directory with `jpeg = null`. Use the directory explicitly to inspect strips or open a
supported uncompressed raster.

`Directory.strips()` checks every StripOffsets/StripByteCounts pair before returning a `Strips`
iterator. Each `next()` or indexed `strip()` returns a bounded source slice, and exhaustion stays
null. These byte ranges alone do not validate their encoded image content.

| Uncompressed raster | Supported interpretation |
| --- | --- |
| Eight-bit RGB | Chunky RGB or separate planar strips, with both FillOrder choices |
| Eight-bit YCbCr | Chunky 4:2:2 or 4:2:0 strips; centered or co-sited chroma positioning |
| Missing ReferenceBlackWhite | Explicit `.full_range` default or `.exif_2012` policy |
| Stored orientation/profile | Retained caller policy; no implicit transform |

`ThumbnailRaster.open` validates all strips, exact byte counts, dimensions, sample declarations
and color calibration before publishing a view. `rgb(x, y)` requires `x < width` and `y < height`;
it returns an independent RGB8 pixel without allocation or further fallible admission. The
coordinates are on the stored grid. Reading a pixel does not rotate it or apply an ICC profile.

YCbCr chroma interpolation crosses strip boundaries and handles admitted odd padded edges.
Declared rational reference spans remain distinct even when their endpoints round to the same
binary64 value. Ordinary calibration is certified once for the floating-point sampling loop;
uncertain rounding uses the encoded rational calibration with fixed wide integers, preserving
large terms that cancel. Only the final RGB components are clipped to 0–255 and rounded nearest.
At an exact mathematical half, either adjacent code is permitted.

The supported profile includes intentional tolerances such as unsorted records, unsigned field
aliases, eight-bit FillOrder 2 and padded YCbCr edges. It is not a general TIFF raster decoder.
BigTIFF, writing, other raster compression/sample layouts and automatic orientation or profile
conversion are outside this API.

The directory and sample framing follows [TIFF 6.0](https://www.itu.int/itudoc/itu-t/com16/tiff-fx/docs/tiff6.pdf).
The `.exif_2012` missing-reference policy follows
[CIPA DC-008-2012](https://www.cipa.jp/std/documents/e/DC-008-2012_E.pdf), distinct from the default
full-range interpretation. The cycle checkpoints follow
[Brent's algorithm](https://maths-people.anu.edu.au/~brent/pd/rpb051i.pdf).
