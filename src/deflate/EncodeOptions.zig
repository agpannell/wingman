//! Compression, history and cumulative allowances shared by raw DEFLATE and its wrappers.
//! Dictionary bytes are borrowed only during reset or a complete operation. Raw streams carry no
//! dictionary identity; framing formats may identify the full dictionary while matching copies only
//! its reachable suffix. Output allowances include enclosing framing where used.

const Compression = @import("Compression.zig");
const EncodeLimits = @import("EncodeLimits.zig");

/// Optional preset dictionary, borrowed during reset or a complete operation. History copies only
/// its reachable suffix; an enclosing format may identify the entire dictionary.
dictionary: ?[]const u8 = null,
/// Compression level, lazy-lookahead effort and optional match strategy.
compression: Compression = .{},
/// Maximum match distance, in 256..32768 and a power of two.
window_bytes: usize = 32768,
/// Cumulative bounds; exhaustion requires reset.
limits: EncodeLimits = .{},
