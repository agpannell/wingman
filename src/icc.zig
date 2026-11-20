//! ICC color profiles describe how device color values relate to standard color spaces. Inspect
//! their v2/v4 headers and opaque tag storage without allocating memory or applying a transform.
//!
//! Pass the complete uncompressed profile's used byte prefix to `Profile.open`, with a tag-count
//! limit. Opening checks declared size, file signature, major version, rendering intent, tag bounds
//! and alignment. It admits shared tag bodies; selecting a duplicate tag signature is an error. V4
//! requires zero tag padding, while v2 permits an unpadded final body.
//!
//! Header fields are copied values. `Profile`, `Profile.Tag` and tag payloads borrow the original
//! bytes; keep them live and unchanged through their last use. No cleanup is needed. The
//! `Profile.open` example demonstrates inspection and tag selection.
//!
//! Each body range is checked independently. Admission does not require contiguous or disjoint
//! bodies, validate other header encodings or establish complete ICC conformance. Tag bodies remain
//! opaque: transform mathematics, required-tag completeness and agreement with an enclosing image's
//! channels are not checked. Applications select and apply color transforms. PNG profile expansion
//! and JPEG profile assembly are container work.
//!
//! References: https://www.color.org/specification/ICC.1-2001-04.pdf and
//! https://www.color.org/specification/ICC.1-2022-05.pdf

pub const Profile = @import("icc/Profile.zig");

test {
    _ = Profile;
}
