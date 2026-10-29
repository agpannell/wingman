//! Focused byte-processing libraries with explicit caller ownership.
//!
//! Adler-32 computes checksums without allocating or retaining input. Use adler32.hash for a
//! complete buffer, adler32.Hasher for fragments, and adler32.combine for independently processed
//! sequences. Each library owns its format, API documentation and executable examples.

pub const adler32 = @import("adler32.zig");

test {
    _ = adler32;
}
