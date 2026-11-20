//! Inspect Exif attributes and thumbnail storage in classic TIFF payloads without allocation.
//!
//! Pass TIFF bytes to `Metadata.open`, excluding any enclosing image header or JPEG Exif signature.
//! Both TIFF byte orders are supported. Opening checks the bounded main image-file-directory (IFD)
//! chain; selecting fields or child directories applies their own bounds and type checks. Unknown
//! tags remain available as raw records, and unknown field types stay opaque until read.
//!
//! Use `Metadata.orientation` for the optional stored orientation, `Metadata.thumbnail` for IFD1
//! storage, and `Metadata.Directory.strips` for recorded uncompressed byte ranges. These operations
//! inspect stored declarations. `ThumbnailRaster` reads the supported uncompressed RGB/YCbCr
//! strips; applications decode encoded JPEG thumbnails and apply orientation or profile transforms
//! explicitly.
//!
//! Views, directories, entries and selected payloads borrow unchanged TIFF bytes through their last
//! use. Copied scalar values are independent. No allocator or cleanup is needed. Directory, entry
//! and total-record limits bound each traversal; applications bound repeated child selection.
//!
//! References: CIPA DC-008 sections 4.5.8 and 4.6, classic TIFF directory/value framing, and
//! Brent's cycle checkpoints. This reader does not interpret every Exif tag or support other TIFF
//! raster compression and sample layouts. https://www.cipa.jp/std/documents/e/DC-008-2012_E.pdf
//! https://maths-people.anu.edu.au/~brent/pd/rpb051i.pdf

pub const Metadata = @import("exif/Metadata.zig");
pub const ThumbnailRaster = @import("exif/ThumbnailRaster.zig");

test {
    _ = Metadata;
    _ = ThumbnailRaster;
}
