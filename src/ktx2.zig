//! Inspect and write KTX2 texture containers. A container packages whole mip levels, array layers,
//! cube faces and volume slices with format declarations and key/value metadata. Mip levels are
//! successively smaller versions of a texture. They are supplied largest first; the file stores
//! smaller levels first for progressive loading.
//!
//! `Source.open` checks complete framing, section and level ranges, zero padding, topology, basic
//! descriptor records and sorted unique UTF-8 metadata keys. Its views borrow immutable input and
//! need no cleanup. BasisLZ global tables, image directories, slice ranges and animation flags are
//! checked structurally; compressed contents and actual frame references need a codec.
//!
//! Core supercompression schemes 0–3 are supported as declarations: none, BasisLZ, Zstandard and
//! zlib. There is no implicit decompression, pixel conversion or GPU upload. A leading Khronos
//! basic descriptor version 2 describes blocks and samples; additional vendor records remain
//! opaque. This library checks descriptor framing and declared sizes, rather than model-specific
//! sample meanings or the complete descriptor-to-Vulkan format mapping. Reserved schemes and
//! general multiplane layouts are unsupported; BasisLZ's paired ETC1S color/alpha planes are
//! admitted.
//!
//! `encodeInto` writes supplied encoded levels after complete preflight. `encode` allocates its
//! result with the explicit allocator. Metadata values and opaque descriptor blocks are preserved.
//! Executable examples accompany the defining operations.
//!
//! Reference: https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html

const types = @import("ktx2/format.zig");
const dfd = @import("ktx2/dfd.zig");
const container = @import("ktx2/container.zig");
const encoding = @import("ktx2/encode.zig");
const global = @import("ktx2/global_data.zig");

pub const Error = types.Error;
pub const Supercompression = types.Supercompression;
pub const Header = types.Header;
pub const Limits = types.Limits;
pub const Options = types.Options;
pub const Level = types.Level;
pub const KeyValue = types.KeyValue;
pub const Sample = dfd.Sample;
pub const DescriptorBlock = dfd.DescriptorBlock;
pub const DescriptorIterator = dfd.DescriptorIterator;
pub const DataFormatDescriptor = dfd.DataFormatDescriptor;
pub const BasicDescriptor = dfd.BasicDescriptor;
pub const Source = container.Source;
pub const ImageSlice = global.ImageSlice;
pub const BasisLzGlobalData = global.BasisLzGlobalData;
pub const KeyValueIterator = container.KeyValueIterator;
pub const EncodeTexture = encoding.EncodeTexture;
pub const EncodeError = encoding.EncodeError;
pub const encodedSize = encoding.encodedSize;
pub const encode = encoding.encode;
pub const encodeInto = encoding.encodeInto;

test {
    _ = types;
    _ = dfd;
    _ = container;
    _ = encoding;
    _ = global;
    _ = @import("common/byte_ranges.zig");
    _ = @import("ktx2/validation.zig");
}
