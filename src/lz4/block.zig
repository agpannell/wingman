//! Raw LZ4 blocks rely on an enclosing record for their encoded boundary, restored extent and
//! integrity. Complete encode/decode operations retain no input or output; StreamDecoder copies
//! accepted history into its caller-owned ring. All operations accept exact unaligned slices.

/// Largest representable backward distance in the raw block wire format.
pub const maximum_distance: usize = 65535;
pub const encode = @import("block_encode.zig");
pub const decode = @import("block_decode.zig");

test {
    _ = encode;
    _ = decode;
}
