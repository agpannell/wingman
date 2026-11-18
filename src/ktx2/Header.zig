//! Copied KTX2 format and topology declarations. Container.open admits these values with the file's
//! descriptor and levels; TextureInput supplies them for writing. Mip zero is the largest level.
//! Zero height/depth omits that axis; zero layers denotes a non-array texture rather than one
//! layer.
const ktx2 = @import("../ktx2.zig");
const Header = @This();

/// Vulkan VkFormat numeric identifier, or zero when the descriptor alone identifies the format.
vk_format: u32,
/// Component or packed-word size in bytes. Block-compressed and undefined formats use one.
type_size: u32 = 1,
/// Nonzero width of the largest mip in texels.
width: u32,
/// Height of the largest mip in texels, or zero for a one-dimensional texture.
height: u32 = 0,
/// Depth of the largest mip in texels, or zero for a non-volume texture.
depth: u32 = 0,
/// Declared array layers; zero means a non-array texture, distinct from a one-element array.
layers: u32 = 0,
/// One for ordinary textures, six for cube faces in +X, -X, +Y, -Y, +Z, -Z order.
faces: u32 = 1,
/// Zero stores one level and requests generated mips; block-compressed formats require a count.
levels: u32 = 1,
/// Representation of stored levels; this library admits framing without running a codec.
supercompression: ktx2.Supercompression = .none,

/// Number of encoded levels, including the one stored when the declaration is zero.
pub fn levelCount(self: Header) u32 {
    return @max(1, self.levels);
}
