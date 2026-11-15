//! Stored/four-byte-run encoding policy shared by raw DEFLATE and its wrappers. Runs match repeated
//! four-byte patterns with prebuilt codebooks; stored mode copies bytes into uncompressed blocks.
//! Dictionary bytes are borrowed only during reset. An enclosing format may identify the full
//! dictionary while matching copies only its reachable suffix. Output allowances include enclosing
//! framing where used.

const EncodeLimits = @import("EncodeLimits.zig");

/// Runs are the default; stored mode omits run matching and Huffman coding.
mode: Mode = .runs,
/// Encoding window, in 256..32768 and a power of two. Runs use distance four.
window_bytes: usize = 32768,
/// Optional preset dictionary, borrowed during reset. History copies only its reachable suffix; an
/// enclosing format may identify the entire dictionary.
dictionary: ?[]const u8 = null,
/// Cumulative bounds; exhaustion requires reset.
limits: EncodeLimits = .{},

/// Block construction supported by the compact workspace.
pub const Mode = enum {
    /// Match only repetitions at backward distance four with prebuilt codebooks.
    runs,
    /// Store source bytes without compression.
    stored,
};
