//! Focused byte-processing libraries with explicit caller ownership.
//!
//! Adler-32 and IEEE CRC-32 compute checksums without allocating or retaining input. Each library
//! provides hash for a complete buffer, Hasher for fragments, and combine for independently
//! processed sequences. Each owns its format, API documentation and executable examples.
//!
//! XXH32 and XXH64 provide seeded hashes for lookup keys and content checksums. Their Hasher states
//! copy pending bytes and provide non-consuming snapshots; no input or allocator is retained.

pub const adler32 = @import("adler32.zig");
pub const crc32 = @import("crc32.zig");
pub const xxhash32 = @import("xxhash32.zig");
pub const xxhash64 = @import("xxhash64.zig");

test {
    _ = adler32;
    _ = crc32;
    _ = xxhash32;
    _ = xxhash64;
}
