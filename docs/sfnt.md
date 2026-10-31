# SFNT font tables and collections

SFNT is the table directory around TrueType and OpenType fonts. Each four-byte tag names an
opaque byte range, such as a character map, metrics or glyph outlines. TTC/OTC collections place
several directories in one file and can share their table storage.

Use `wingman.sfnt` to inspect these containers before handing a table to a format-specific reader.
It opens borrowed directories and collections, enumerates records, finds unique tags and computes
explicit checksums without allocating. It does not decode glyphs, shape text, render a font or
establish complete OpenType conformance.

Use [Zig 0.17.0 and the package setup](../README.md#use-it-in-a-project). Run
`zig build sfnt-example` for the complete [authored collection example](../examples/sfnt.zig).
The example checks two different directory flavors sharing one table at an absolute offset.

## Open and inspect a directory

```zig
const sfnt = @import("wingman").sfnt;

pub fn selectedTable(bytes: []const u8, tag: sfnt.Tag) sfnt.Error!?sfnt.Table {
    const directory = try sfnt.Directory.open(bytes);
    return directory.find(tag);
}
```

`Directory.open(bytes)` reads a standalone directory at byte zero. `Directory.openAt(bytes, offset)`
opens one at an absolute position in the complete source. Both check the whole record array and
every table's range before returning. Empty directories and zero-length tables at the source end
are admitted for raw inspection. No table bytes are swept or interpreted while opening.

A directory recognizes the `truetype`, `apple_truetype`, `opentype_cff` and `apple_type1` flavors.
The signature identifies a declared container technology; it does not establish that the expected
outlines exist or can be decoded. Unsupported signatures return `UnsupportedFormat`.

Tags are exact four-byte arrays with significant case and spaces; `"CFF "` differs from `"CFF2"`.
Raw inspection also preserves nonprintable tags. `directory.table(index)` returns a copied record
with a borrowed payload, or `null` out of range. Indexed enumeration preserves encoded order and
all duplicates. Maximum-size indices are refused before record arithmetic.

`directory.find(tag)` returns the unique matching table, `null` when absent or `AmbiguousTag` when
more than one record matches. Identical shared payloads do not remove that ambiguity. Opening
observes the actual record order: nondecreasing tags use lower-bound binary search, while unordered
records use a linear scan. Encoded search accelerator fields are ignored.

## Select a collection face

```zig
const sfnt = @import("wingman").sfnt;

pub fn collectionFace(bytes: []const u8, index: u32) sfnt.Error!sfnt.Directory {
    const collection = try sfnt.Collection.open(bytes);
    return collection.face(index);
}
```

`Collection.open` admits version-one or version-two framing, a nonzero face count, the complete
offset array and every member directory's extent. Version two also checks its optional DSIG
signature descriptor and byte range. `collection.signature` borrows those bytes; no cryptographic
signature is authenticated. A null descriptor must have all three fields zero.

Opening the collection does not select every member or validate its payload ranges. A structurally
present member may have an unsupported flavor or a malformed table payload. `collection.face(index)`
checks the selected directory and its tables, returning `InvalidFace` outside the recorded count.
Failure on one member leaves the collection available for selecting another.

**Table offsets remain absolute in the complete collection.** Keep the whole collection as the
source when opening a directory at a nonzero position. Passing only a suffix beginning at that
directory would change the meaning of its encoded offsets. Different face records may name the
same directory, and different tables may borrow the same bytes.

## Verify checksums explicitly

`sfnt.checksum(bytes)` adds big-endian 32-bit words with unsigned wrap. A final partial word is
virtually padded with zero bytes; the input needs neither stored padding nor pointer alignment.
The empty checksum is zero. No source bytes are changed.

`table.computedChecksum()` follows that rule with one exception: for the exact `"head"` tag, bytes
8–11 of its payload are treated as zero. `table.checksumMatches()` compares this result with the
stored directory checksum. Opening a directory does not call either method or reject a mismatch.
Even short opaque `head` bodies are range-inspectable; that does not make them valid font headers.

A complete standalone font's checksum, including its stored `head.checkSumAdjustment`, has target
`sfnt.checksum_target` (`0xb1b0afba`). This whole-file rule does not apply to TTC/OTC collections.
Checksums detect accidental corruption; they do not authenticate a font or prove table semantics.

## Borrowing, failures and work

Directories, collections, table payloads, record arrays and optional DSIG bytes borrow complete
immutable source through their last use. Copying a view keeps that borrow. Tags, checksums,
flavors, counts, offsets and versions are copied values. Construct views through their opening
operations and preserve the admitted fields; changing source, record spans, counts or ordering
flags can invalidate later access. There is no allocator, retained mutable cache or cleanup.

| Result | Meaning |
| --- | --- |
| `InvalidFont` | A required header, array, signature descriptor or selected table range is incomplete, malformed or arithmetically unrepresentable |
| `UnsupportedFormat` | The directory flavor or collection version/signature is outside the supported set |
| `InvalidFace` | The requested collection index is outside the admitted count |
| `AmbiguousTag` | Unique lookup found multiple matching records |
| `null` | A table index or selected tag is absent |

Opening and selection leave input unchanged and publish no view on failure. Arithmetic is checked
before loads and slices. Count fields and admitted source extents bound traversal: a directory
has at most 65,535 records, while a collection uses its encoded 32-bit face count. These are wire
limits, not application resource allowances. Callers bound input storage and decide whether to
inspect a large collection; aliases are visited individually rather than deduplicated.

Directory opening is linear in its table count. Indexed access is constant-time. Unique lookup
is logarithmic for an ordered directory and linear otherwise. Collection opening is linear in
face count; selecting a face scans that directory's table records. Explicit checksums scan their
supplied bytes. None of these operations allocates or copies table bodies.

## Raw inspection and format policy

The reader deliberately admits shared or overlapping payloads, unaligned table offsets, raw tags,
unsorted records, duplicates and directories without the required tables of a complete font. It
does not check canonical padding, glyphs, character maps, metrics, table-specific offsets or
cross-table agreement. Signature bytes are only opaque ranges. Consumers select the policies and
table decoders needed for their use; successful container admission alone is not a font sanitizer.

The [SFNT source](../src/sfnt.zig) keeps the small container contract and inline assertions together.
Checked binary reads and array arithmetic have their own [common support](../src/common/font_binary.zig),
without adding another root library namespace. The format references are the
[OpenType file organization](https://learn.microsoft.com/en-us/typography/opentype/spec/otff),
[font-header checksum adjustment](https://learn.microsoft.com/en-us/typography/opentype/spec/head)
and [Apple font tables](https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6.html).
Package examples and fixed controls are authored table storage, not bundled third-party fonts.
