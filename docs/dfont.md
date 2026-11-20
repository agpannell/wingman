# Macintosh DFONT resources

A DFONT file is a Macintosh data-fork resource container that can hold one or more SFNT font
resources. `wingman.dfont` inspects the resource map and borrows one font's exact bytes; use
[`wingman.sfnt`](sfnt.md) to inspect that font's table directory. The reader needs no allocator and
does not decode glyphs or validate a complete font.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project). Run
`zig build dfont-example` for an [authored container](../examples/dfont.zig) with an SFNT table.

```zig
const wingman = @import("wingman");
const Container = wingman.dfont.Container;

pub fn fontDirectory(bytes: []const u8, index: u32) Container.FaceError!wingman.sfnt.Directory {
    const container = try Container.open(bytes);
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

`faceCount()` counts `sfnt` references in resource-list order, including compressed resources that
cannot be selected for decoding. `faceBytes(index)` returns the exact borrowed font payload; its internal SFNT offsets are relative
to that payload. An out-of-range index returns `InvalidFace`; compressed resources can be counted
but selection returns `UnsupportedFormat`. A container without SFNT resources also returns
`UnsupportedFormat`. Malformed framing or ranges return `InvalidFont`.

In the example, the selected SFNT resource begins at byte 20 of the container. Its table offset
is 28 relative to that resource, so the table starts at byte 48 of the container. Pass the selected
payload to `sfnt.Directory.open`; passing the whole DFONT would use the wrong offset base. This
differs from an SFNT collection, whose table offsets refer to the complete collection.

`Container.hasHeader(bytes)` checks only the fixed framing and the two disjoint ranges. A successful
result is a preliminary check, not proof that the resource map is valid or that the file contains a font.
A header's leading word is a data offset and may equal a font signature, so this function does not
choose between file formats. Preflight, opening and selection leave the input unchanged.

`Container.OpenError` names malformed framing and unsupported content failures.
`Container.FaceError` adds invalid face selection. The descriptor's `source`, `resource_data` and
`font_references` fields retain the complete source, length-prefixed resource region and admitted
SFNT reference records, respectively; preserve these fields after opening.

Opening performs work linear in resource types and SFNT references; face selection is constant-time
apart from the selected payload's length/range checks. The caller owns source storage and any
application-level limits. Other resource payloads, NFNT/POST fonts, compressed-resource decoding,
AppleDouble, MacBinary and filesystem resource-fork discovery are outside this reader.

The [Container implementation and inline tests](../src/dfont/Container.zig) share checked
[font binary support](../src/common/font_binary.zig) and
[byte-range overlap checks](../src/common/byte_ranges.zig). Resource admission is independent of
the SFNT reader; the examples compose their public facades. The format
layout is described in Apple's [Resource Manager documentation](https://developer.apple.com/library/archive/documentation/mac/MoreToolbox/MoreToolbox-99.html).
