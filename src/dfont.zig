//! Borrowed SFNT fonts from Macintosh data-fork resource containers (`.dfont` files).
//!
//! A DFONT file stores complete fonts as `sfnt` resources. Container.open admits the resource map;
//! Container.faceBytes selects a payload without copying it or changing its resource-relative table
//! offsets. Face indices follow the reference list, rather than numeric resource IDs. Keep the
//! complete source immutable and alive while using the container or any selected font bytes.
//!
//! Opening checks disjoint data/map extents and bounded type/reference lists. For SFNT resources,
//! it also checks Pascal resource names, payload bounds and uncompressed directory extents. It does
//! not interpret font tables. Admit selected bytes with a font reader separately, so an invalid
//! sibling's table contents do not hide a usable face. Compressed SFNT resources can be enumerated
//! but selecting one returns UnsupportedFormat. Other resource types do not contribute faces.
//! NFNT/POST fonts, AppleDouble, MacBinary and filesystem resource-fork discovery are outside this
//! format reader.
//!
//! All operations are allocation-free. Admission is linear in type and SFNT reference counts. The
//! leading word is a data offset and can equal a SFNT signature; Container.hasHeader provides a
//! bounded framing check, not format identification. See Container.open for an executable selection
//! example. Format:
//! https://developer.apple.com/library/archive/documentation/mac/MoreToolbox/MoreToolbox-99.html

pub const Container = @import("dfont/Container.zig");

test {
    _ = Container;
}
