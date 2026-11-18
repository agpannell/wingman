//! Inspect and write KTX2 texture containers. A container packages whole mip levels, array layers,
//! cube faces and volume slices with format declarations and key/value metadata. Mip levels are
//! successively smaller versions of a texture. They are supplied largest first; the file stores
//! smaller levels first for progressive loading.
//!
//! A level's texels may already use a GPU block format. Supercompression reduces that encoded data
//! further for storage: Zstandard and zlib compress each level, while BasisLZ uses shared ETC1S
//! codebooks. A codebook supplies values referenced by many blocks; recovering them needs a codec.
//!
//! Container.open admits complete framing, ranges, topology, zero padding and the supported format
//! profile without allocating. Its descriptor and Metadata views borrow immutable file bytes.
//! Container.basisLz exposes BasisLz image slices and compressed codebooks for ETC1S/BasisLZ data;
//! framing and animation flags are checked, while compressed contents still need a codec.
//!
//! TextureInput describes supplied encoded levels. Its encodedSize method admits the input;
//! encodeInto writes caller storage and encode allocates with an explicit allocator. Both writers
//! complete admission before publishing bytes. No compression, pixel conversion or GPU upload
//! occurs.
//!
//! Core supercompression declarations none, BasisLZ, Zstandard and zlib are supported. The
//! independent wingman.KhronosDataFormatDescriptor owns basic descriptor framing. KTX2 checks its
//! relationship to container declarations without interpreting every color-model rule or Vulkan
//! format mapping. Reserved schemes and general multiplane layouts are unsupported; paired ETC1S
//! color/alpha slices are admitted. Defining operations carry executable examples.
//!
//! Reference: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html
const byte_ranges = @import("common/byte_ranges.zig");
const layout = @import("ktx2/layout.zig");

pub const Container = @import("ktx2/Container.zig");
pub const TextureInput = @import("ktx2/TextureInput.zig");
pub const Metadata = @import("ktx2/Metadata.zig");
pub const BasisLz = @import("ktx2/BasisLz.zig");
pub const Header = @import("ktx2/Header.zig");

/// Container framing, descriptor/metadata syntax, unsupported identifiers or caller limits.
pub const Error = error{ InvalidKtx2, UnsupportedFormat, LimitExceeded, SizeOverflow };

/// Compression applied independently to each mip level, or a codec-specific slice layout.
pub const Supercompression = enum(u32) { none = 0, basis_lz = 1, zstandard = 2, zlib = 3 };

/// Independent bounds for complete-container admission and writing. Metadata.open applies the
/// metadata-byte and entry bounds; other limits govern the enclosing file. No decompression occurs.
pub const Limits = struct {
    /// Maximum complete file size, including framing, padding and encoded payloads.
    maximum_encoded_bytes: usize = 256 * 1024 * 1024,
    /// Maximum width, height or depth in texels before mip reduction.
    maximum_extent: u32 = 16384,
    /// Maximum declared array layers; a zero declaration denotes a non-array texture.
    maximum_layers: u32 = 65536,
    /// Maximum stored levels, including the one stored for Header.levels = 0.
    maximum_levels: u32 = 32,
    /// Maximum total image records across all mips in a BasisLZ directory.
    maximum_image_slices: u64 = 1024 * 1024,
    /// Maximum complete Khronos descriptor size, including opaque following blocks.
    maximum_descriptor_bytes: usize = 1024 * 1024,
    /// Maximum serialized metadata bytes, including lengths, key terminators and padding.
    maximum_metadata_bytes: usize = 1024 * 1024,
    /// Maximum key/value entries; keys must also be sorted and unique.
    maximum_metadata_entries: usize = 65536,
    /// Maximum sum of declared expanded level sizes. BasisLZ declares zero expanded bytes.
    maximum_uncompressed_bytes: u64 = 1024 * 1024 * 1024,
};

/// Admission policy shared by borrowed inspection and serialization.
pub const Options = struct {
    /// Independent ceilings checked before accepting records, ranges or expanded declarations.
    limits: Limits = .{},
};

/// One complete encoded mip, ordered internally by layer, face, depth, row and block/texel. Values
/// borrow their data. Uncompressed samples use little-endian bytes even on a big-endian host;
/// inspecting or writing a level performs no sample conversion.
pub const Level = struct {
    /// Whole encoded mip bytes, including every layer, face and depth plane at that resolution.
    data: []const u8,
    /// Complete expanded byte count: data.len without compression, zero for BasisLZ.
    uncompressed_size: u64,
};

test {
    _ = Container;
    _ = TextureInput;
    _ = Metadata;
    _ = BasisLz;
    _ = Header;
    _ = layout;
    _ = byte_ranges;
}
