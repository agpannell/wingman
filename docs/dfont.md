# Macintosh DFONT resources

A DFONT file is a Macintosh data-fork resource container that can hold one or more SFNT font
resources. `wingman.dfont` inspects the resource map and borrows one font's exact bytes; use
[`wingman.sfnt`](sfnt.md) to inspect that font's table directory. The reader needs no allocator and
does not decode glyphs or validate a complete font.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project). Run
`zig build dfont-example` for an [authored container](../examples/dfont.zig) with an SFNT table.

```zig
const wingman = @import("wingman");

pub fn fontDirectory(bytes: []const u8, index: u32) !wingman.sfnt.Directory {
    const container = try wingman.dfont.Container.open(bytes);
    const font_bytes = try container.faceBytes(index);
    return wingman.sfnt.Directory.open(font_bytes);
}
```

Keep the complete source immutable and alive until the container, selected font bytes, and any
SFNT tables borrowed from them are no longer used. A selected slice borrows the source rather than
the container descriptor, so it can outlive that descriptor. Copies of the descriptor retain the
same source borrow. Construct it through `open` and preserve its admitted fields.

## Admission and selection

`Container.open` checks the resource header, disjoint data and map ranges, type and reference
lists, names and payload extents. For uncompressed `sfnt` resources it also checks that the font
directory fits. It accepts a copied or zero map header. It does not interpret table contents, so a
malformed table in one resource does not prevent selecting another. Open the selected bytes with
`sfnt.Directory.open` to check that resource's table ranges.

`faceCount()` counts `sfnt` references in resource-list order, including compressed resources.
`faceBytes(index)` returns the exact borrowed font payload; its internal SFNT offsets are relative
to that payload. An out-of-range index returns `InvalidFace`; compressed resources can be counted
but selection returns `UnsupportedFormat`. A container without SFNT resources also returns
`UnsupportedFormat`. Malformed framing or ranges return `InvalidFont`.

`hasHeader(bytes)` checks only the fixed framing and the two disjoint ranges. A successful result
is a preliminary check, not proof that the resource map is valid or that the file contains a font.
A header's leading word is a data offset and may equal a font signature, so this function does not
choose between file formats. Both APIs leave the input unchanged.

Opening performs work linear in resource types and SFNT references; face selection is constant-time
apart from the selected payload's length/range checks. The caller owns source storage and any
application-level limits. Other resource payloads, NFNT/POST fonts, compressed-resource decoding,
AppleDouble, MacBinary and filesystem resource-fork discovery are outside this reader.

The [implementation and inline tests](../src/dfont.zig) compose checked
[font binary support](../src/common/font_binary.zig) with the independent SFNT reader. The format
layout is described in Apple's [Resource Manager documentation](https://developer.apple.com/library/archive/documentation/mac/MoreToolbox/MoreToolbox-99.html).
