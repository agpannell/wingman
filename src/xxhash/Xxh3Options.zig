//! Configuration shared by XXH3-64 and XXH3-128. A seed and a custom secret select distinct modes.
//! Custom secrets change the hash mapping; they do not provide authentication.

/// Selects the default seed zero, another seed or a borrowed custom secret.
mode: Mode = .{ .seed = 0 },

/// The two supported XXH3 modes; a seed and a custom secret cannot be combined.
pub const Mode = union(enum) {
    /// Any 64-bit seed. Streaming state owns any secret bytes derived from it.
    seed: u64,
    /// At least `minimum_secret_length` immutable bytes. A complete hash borrows them only for its
    /// call; a stream borrows them until every copy is reset successfully or no longer used.
    secret: []const u8,
};

/// Minimum custom secret length in bytes. The full supplied slice is available to the algorithm.
pub const minimum_secret_length: usize = 136;

/// Option admission shared by complete hashing and streaming reset.
pub const Error = error{
    /// The custom secret contains fewer than `minimum_secret_length` bytes.
    InvalidSecret,
};
