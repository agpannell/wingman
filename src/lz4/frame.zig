//! Standard LZ4 frames package compressed blocks with descriptors, optional XXH32 checksums and
//! boundaries. Use encode.into/decode.into for complete buffers, or their StreamEncoder and
//! StreamDecoder types for fragments. Complete decoding stops at one frame by default; concatenate
//! verifies the supplied sequence. Stream iteration reports each verified frame separately.
//!
//! Encoding workspaces own block buffers and copied history. Streaming decoding needs a fixed 128
//! KiB history/dictionary workspace, regardless of advertised block size. Calls allocate nothing
//! after explicit workspace construction. Checksums detect corruption; decoded bytes remain private
//! until the required block/content checks and declared content size have succeeded.

const std = @import("std");

pub const encode = @import("frame_encode.zig");
pub const decode = @import("frame_decode.zig");

/// Maximum uncompressed frame-block sizes. Streaming recovery requires only its history workspace,
/// regardless of the advertised block size.
pub const BlockSize = enum(u3) {
    k64 = 4,
    k256 = 5,
    m1 = 6,
    m4 = 7,

    /// Maximum encoded or decoded data bytes in a frame block.
    pub fn bytes(self: BlockSize) usize {
        const descriptor_id: std.math.Log2Int(usize) = @backingInt(self);
        const size_exponent = descriptor_id * 2 + 8;
        return @as(usize, 1) << size_exponent;
    }
};

/// External dictionary and optional application identifier. Dictionaries have no embedded
/// validation; supply identical bytes at encoding and decoding. Only the final 65,535 bytes can be
/// referenced.
pub const Dictionary = struct {
    /// Borrowed bytes supplied to a complete call or copied by a streaming reset.
    bytes: []const u8,
    /// Application-selected identity serialized in the descriptor; null omits it.
    id: ?u32 = null,
};

/// A validated frame descriptor. A present zero content size or dictionary ID remains distinct from
/// an absent field.
pub const Descriptor = struct {
    /// Maximum stored or decoded bytes in an ordinary frame block.
    block_size: BlockSize,
    /// True when every block starts from the initial dictionary rather than earlier blocks.
    independent: bool,
    /// A checksum follows each encoded block.
    block_checksum: bool,
    /// A checksum of all decoded content follows the final block.
    content_checksum: bool,
    /// Declared decoded byte count; null means the frame omits it.
    content_size: ?u64,
    /// Application-selected dictionary ID; null means the frame omits it.
    dictionary_id: ?u32,
};

test {
    _ = encode;
    _ = decode;
}
