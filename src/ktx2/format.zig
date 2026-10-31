//! KTX2 topology, supercompression identifiers and bounded container policy.

/// Container framing, descriptor/metadata syntax, unsupported identifiers or caller limits.
pub const Error = error{ InvalidKtx2, UnsupportedFormat, LimitExceeded, SizeOverflow };

/// Compression applied independently to each mip level, or a codec-specific slice layout.
pub const Supercompression = enum(u32) { none = 0, basis_lz = 1, zstandard = 2, zlib = 3 };

/// Copied declarations in the KTX2 header. Zero height/depth means that axis is absent. Zero layers
/// means a non-array texture, distinct from an array with one element. Mip zero is the largest.
pub const Header = struct {
    /// Vulkan VkFormat numeric identifier, or zero for a format described only by the DFD.
    vk_format: u32,
    /// Component/packed-word size in bytes. Block-compressed and undefined formats use one.
    type_size: u32 = 1,
    width: u32,
    height: u32 = 0,
    depth: u32 = 0,
    layers: u32 = 0,
    /// One for ordinary textures, six for cubes in +X, -X, +Y, -Y, +Z, -Z order.
    faces: u32 = 1,
    /// Zero stores one level and asks the consumer to generate mips; disallowed for block formats.
    levels: u32 = 1,
    supercompression: Supercompression = .none,

    /// Number of encoded levels, including the one stored when the declaration is zero.
    pub fn levelCount(self: Header) u32 {
        return @max(1, self.levels);
    }
};

/// Independent bounds checked before traversing records or accepting expanded byte declarations.
pub const Limits = struct {
    maximum_encoded_bytes: usize = 256 * 1024 * 1024,
    maximum_extent: u32 = 16384,
    maximum_layers: u32 = 65536,
    maximum_levels: u32 = 32,
    /// Total image records across mips in BasisLZ image directories.
    maximum_image_slices: u64 = 1024 * 1024,
    maximum_descriptor_bytes: usize = 1024 * 1024,
    maximum_metadata_bytes: usize = 1024 * 1024,
    maximum_metadata_entries: usize = 65536,
    /// Sum of expanded sizes declared by levels. Variable-size codec schemes declare zero.
    maximum_uncompressed_bytes: u64 = 1024 * 1024 * 1024,
};

/// Shared admission for borrowed reading and serialization; no decompression is performed.
pub const Options = struct { limits: Limits = .{} };

/// One whole mip's encoded data, ordered internally by layer, face, depth, row and block/texel.
/// Uncompressed bytes are little-endian even on a big-endian host; no sample conversion occurs.
pub const Level = struct {
    data: []const u8,
    /// Equal to data.len for no compression; zero for BasisLZ.
    uncompressed_size: u64,
};

/// UTF-8 key without its stored NUL terminator and an opaque binary value. Keys are unique and
/// sorted by Unicode scalar value; valid UTF-8 byte order has the same ordering.
pub const KeyValue = struct { key: []const u8, value: []const u8 };
