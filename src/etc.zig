//! Compress image tiles for ETC1/EAC GPU textures, or reconstruct stored blocks for CPU image
//! inspection. Each eight-byte block describes a 4x4 tile using base values, intensity tables and
//! per-texel selectors. ETC1 stores RGB and reconstructs opaque RGBA8; EAC alpha8 stores alpha
//! bytes, while unsigned R11 retains all eleven reconstructed bits in `u16` samples.
//!
//! `decodeBlock`, `decodeAlphaBlock` and `decodeR11Block` write caller-owned tiles without
//! allocation. Every error preserves output; spare capacity is untouched. Blocks use big-endian
//! wire fields and row-major output. Clip edge tiles to the image dimensions after decoding. No
//! transfer conversion, normalization, channel assembly or GPU upload is inferred.
//!
//! `encodeBlock`, `encodeAlphaBlock` and `encodeR11Block` fit complete caller-owned tiles without
//! allocation. Three bounded efforts retain earlier candidates. RGB uses squared stored-byte error;
//! R11 maps normalized input bytes to nearest eleven-bit values and measures error at that
//! precision. Per-call work admission occurs before publication. These encoders introduce
//! additional loss. Alpha8 encoders emit nonzero multipliers; alpha8 decoding also handles stored
//! zero multipliers.
//!
//! An ETC2 RGBA block stores an alpha8 block followed by a color block. Its ETC1-compatible color
//! modes can use `decodeBlock`; ETC2 T/H/planar color modes and signed EAC are unsupported here.
//! EAC RG11 stores a red R11 block followed by a green R11 block; decode each separately.
//!
//! https://registry.khronos.org/OpenGL/specs/es/3.0/es_spec_3.0.pdf (appendix C)

const format = @import("etc/format.zig");
const color = @import("etc/color.zig");
const scalar = @import("etc/scalar.zig");
const encoding = @import("etc/encode.zig");
const fitting = @import("etc/fit.zig");

pub const DecodeError = format.DecodeError;
pub const Effort = format.Effort;
pub const EncodeOptions = encoding.EncodeOptions;
pub const EncodeError = encoding.EncodeError;
pub const decodeBlock = color.decodeBlock;
pub const decodeAlphaBlock = scalar.decodeAlphaBlock;
pub const decodeR11Block = scalar.decodeR11Block;
pub const encodeBlock = encoding.encodeBlock;
pub const encodeAlphaBlock = encoding.encodeAlphaBlock;
pub const encodeR11Block = encoding.encodeR11Block;
pub const colorWorkUnits = fitting.colorWorkUnits;
pub const scalarWorkUnits = scalar.scalarWorkUnits;

test {
    _ = format;
    _ = color;
    _ = scalar;
    _ = encoding;
    _ = fitting;
}
