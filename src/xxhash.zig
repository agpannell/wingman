//! Noncryptographic xxHash algorithms for checksums and lookup keys. Choose the variant required by
//! the enclosing format or application: classic XXH32 and XXH64 are distinct from XXH3-64 and
//! XXH3-128. Upstream also calls XXH3-128 XXH128. A custom secret does not make any of these hashes
//! an authentication mechanism.
//!
//! Results are numeric values. XXH3-128 returns `u128` with upstream's high 64 bits above its low
//! 64 bits; its low half must not be assumed to equal XXH3-64. The upstream canonical encoding is
//! the result in big-endian byte order; enclosing formats may specify another order. For example,
//! LZ4 and Zstandard store their checksum fields in little-endian order.
//!
//! Use `Xxh32.hash`, `Xxh64.hash`, `Xxh3_64.hash` or `Xxh3_128.hash` for complete input. Each state
//! can also be initialized with a seed, updated with fragments and finalized without being
//! consumed. States allocate nothing; copies continue independently and updates retain no input.
//!
//! The XXH3 types also accept `Xxh3Options` for a custom secret. Complete calls borrow it only
//! during the call. A streaming state borrows it until successful reinitialization or the last use
//! of every copy; keep it alive, immutable and disjoint from each mutable state. See
//! `Xxh3_64.initWithOptions` for a module-context example and the family guide for more modes.
//!
//! ```zig
//! const std = @import("std");
//! const xxhash = @import("wingman").xxhash;
//!
//! test "stream a seeded XXH3-64 digest" {
//!     var state: xxhash.Xxh3_64 = undefined;
//!     state.init(1);
//!     state.update("a");
//!     state.update("bc");
//!     try std.testing.expectEqual(xxhash.Xxh3_64.hashSeeded(1, "abc"), state.final());
//! }
//! ```

pub const Xxh32 = @import("xxhash/Xxh32.zig");
pub const Xxh64 = @import("xxhash/Xxh64.zig");
pub const Xxh3_64 = @import("xxhash/Xxh3_64.zig");
pub const Xxh3_128 = @import("xxhash/Xxh3_128.zig");
pub const Xxh3Options = @import("xxhash/xxh3.zig").Xxh3Options;

test {
    _ = Xxh32;
    _ = Xxh64;
    _ = Xxh3_64;
    _ = Xxh3_128;
    _ = @import("xxhash/xxh3.zig");
    _ = @import("xxhash/xxh3_stream.zig");
    _ = @import("xxhash/xxh3_small.zig");
    _ = @import("xxhash/xxh3_long.zig");
    _ = @import("common/byte_ranges.zig");
}
