//! Focused byte-processing libraries with explicit caller ownership.
//!
//! Adler-32 and IEEE CRC-32 compute checksums without allocating or retaining input. Each library
//! provides hash for a complete buffer, Hasher for fragments, and combine for independently
//! processed sequences. Each owns its format, API documentation and executable examples.

pub const adler32 = @import("adler32.zig");
pub const crc32 = @import("crc32.zig");

test {
    _ = adler32;
    _ = crc32;
}
