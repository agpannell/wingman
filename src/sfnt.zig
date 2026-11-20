//! Inspect SFNT font tables and TTC/OTC collections without allocating or interpreting glyphs.
//!
//! An SFNT directory names each table with a four-byte tag and an absolute byte range. Use
//! `Directory.open` for a standalone file or `Collection.open` to select a collection member.
//! Opening a directory admits every table range; its payloads remain opaque. No character map,
//! outline or metric table is required. Unknown tags, duplicate records and shared payloads remain
//! inspectable. Tag lookup reports ambiguity instead of choosing between duplicate records.
//!
//! Views borrow complete immutable source bytes and need no cleanup. Keep that backing alive and
//! unchanged through the last table borrow. Collection table offsets remain relative to the
//! complete collection, even when the selected directory starts at a nonzero offset. Opening checks
//! structure, with checksum verification available separately; it does not sanitize or authenticate
//! a font.
//!
//! Reference: https://learn.microsoft.com/en-us/typography/opentype/spec/otff

const checksums = @import("sfnt/checksums.zig");

pub const Directory = @import("sfnt/Directory.zig");
pub const Collection = @import("sfnt/Collection.zig");

pub const checksum = checksums.checksum;
pub const checksum_target = checksums.target;

test {
    _ = Directory;
    _ = Collection;
    _ = checksums;
}
