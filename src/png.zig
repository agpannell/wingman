//! PNG stores lossless images as filtered, zlib-compressed samples in checksummed chunks. APNG adds
//! animation frames, delays and composition rules. This library reads and writes both formats and
//! decodes pixels as RGBA8 or RGBA16 without applying color or orientation transforms.
//!
//! Source.open admits the complete PNG structure without allocating and borrows its encoded bytes.
//! Source.metadata returns a Metadata.Reader for selected declarations and text. Source.chunks
//! exposes raw records, including unknown chunks. Keep input unchanged while using borrowed views.
//!
//! decode.rgbaAlloc returns a DecodedImage; release it through deinit with its output allocator.
//! decode.Workspace prepares backing for caller-owned output. decode.rgbaInto preserves output on
//! failure by default; IntoOptions.Publication makes partial publication explicit. Region and
//! RowReader operations support selected rectangles. decode.StreamDecoder accepts fragmented input;
//! its sequential rows remain provisional until successful completion.
//!
//! AnimationSource inspects borrowed APNG controls. decode.animation.alloc owns every local frame.
//! Animation(Sample).Player borrows that animation and composes a retained canvas without
//! allocating during playback. The caller schedules next using each returned FrameControl.Delay.
//!
//! ImageInput describes packed bytes or native words, palettes and transparency. encode.alloc
//! returns owned PNG bytes; encode.into uses caller-owned output and workspace. encode.animation
//! accepts an AnimationInput. Both encoders accept Metadata.Input, filters and Adam7 interlacing;
//! scratch and retention variants control temporary storage and compression replay.
//!
//! Limits bound charged resources, rather than elapsed time. Chunk.Iterator and Chunk.writeInto
//! support raw record inspection and writing independently of pixel decoding. The PNG guide
//! describes these workflows and the ordering rules for editing. Format:
//! https://www.w3.org/TR/2025/REC-png-3-20250624/

const std = @import("std");
const image_decoding = @import("png/image_decode.zig");
const region_decoding = @import("png/region_decode.zig");
const row_reading = @import("png/row_reader.zig");
const stream_decoding = @import("png/stream_decoder.zig");
const raster_decoding = @import("png/raster_decoder.zig");
const decode_backing = @import("png/decode_workspace.zig");
const animation_decoding = @import("png/animation.zig");
const image_encoding = @import("png/image_encode.zig");
const animation_encoding = @import("png/animation_encode.zig");
const raster_encoding = @import("png/raster_encode.zig");
const encode_backing = @import("png/encode_workspace.zig");
const metadata_encoding = @import("png/metadata_encode.zig");
const metadata = @import("png/metadata.zig");
const filters = @import("png/scanline_filters.zig");
const RgbaConverter = @import("png/RgbaConverter.zig");
const ChunkWriter = @import("png/ChunkWriter.zig");
const format = @import("png/format.zig");
const zlib = @import("zlib.zig");
const allocation = @import("common/allocation.zig");
const TestImage = @import("png/testdata/TestImage.zig");

pub const Source = @import("png/Source.zig");
pub const Header = @import("png/Header.zig");
pub const Chunk = @import("png/Chunk.zig");
pub const Limits = @import("png/Limits.zig");
pub const ImageInput = @import("png/ImageInput.zig");
pub const AnimationInput = @import("png/AnimationInput.zig");
pub const AnimationSource = @import("png/AnimationSource.zig");
pub const FrameControl = @import("png/FrameControl.zig");
pub const DecodedImage = image_decoding.DecodedImage;
pub const Animation = animation_decoding.Animation;
pub const Metadata = metadata.Metadata;
pub const ColorType = format.ColorType;
pub const Samples = format.Samples;
pub const Transparency = format.Transparency;
pub const Interlace = format.Interlace;

/// Recover complete images, selected regions, complete-source rows or fragmented-input rows.
/// Backing, publication and borrowed-output contracts are specific to each operation.
pub const decode = struct {
    pub const Options = image_decoding.Options;
    pub const IntoOptions = image_decoding.IntoOptions;
    pub const Storage = decode_backing.Storage;
    pub const Workspace = decode_backing.Workspace;
    pub const Requirements = raster_decoding.Requirements;
    pub const RegionOptions = region_decoding.Options;
    pub const RegionRequirements = region_decoding.Requirements;
    pub const View = region_decoding.View;
    pub const RowReader = row_reading.RowReader;
    pub const StreamDecoder = stream_decoding.StreamDecoder;
    pub const PaletteIndexPolicy = format.PaletteIndexPolicy;
    pub const Error = image_decoding.Error || image_decoding.IntoError || stream_decoding.Error ||
        animation_decoding.Error || std.mem.Allocator.Error;

    pub const rgbaAlloc = image_decoding.rgbaAlloc;
    pub const rgbaAllocWithScratch = image_decoding.rgbaAllocWithScratch;
    pub const rgbaInto = image_decoding.rgbaInto;
    pub const requirements = raster_decoding.requirements;
    pub const regionInto = region_decoding.into;
    pub const regionRequirements = region_decoding.requirements;

    /// Transactionally reconstruct every local APNG frame into an owned Animation.
    pub const animation = struct {
        pub const Options = animation_decoding.Options;
        pub const Error = animation_decoding.Error || std.mem.Allocator.Error;
        pub const alloc = animation_decoding.alloc;
        pub const allocWithScratch = animation_decoding.allocWithScratch;
    };
};

/// Write PNG samples and typed metadata. The default operations encode one ImageInput; animation
/// operations encode the canvas and frame controls in AnimationInput.
pub const encode = struct {
    pub const Options = image_encoding.Options;
    pub const Requirements = image_encoding.Requirements;
    pub const Workspace = encode_backing.Workspace;
    pub const Error = image_encoding.Error || animation_encoding.Error;
    pub const Compression = zlib.Compression;
    pub const Filter = filters.Filter;
    pub const alloc = image_encoding.alloc;
    pub const allocWithScratch = image_encoding.allocWithScratch;
    pub const allocWithRetention = image_encoding.allocWithRetention;
    pub const into = image_encoding.into;
    pub const requirements = image_encoding.requirements;

    pub const animation = struct {
        pub const Options = animation_encoding.Options;
        pub const Requirements = animation_encoding.Requirements;
        pub const Error = animation_encoding.Error;
        pub const alloc = animation_encoding.alloc;
        pub const allocWithScratch = animation_encoding.allocWithScratch;
        pub const into = animation_encoding.into;
        pub const requirements = animation_encoding.requirements;
    };
};

/// Structure, metadata, raster, encoding, backing, allocation and resource failures.
pub const Error = decode.Error || encode.Error || Metadata.Error;

test {
    _ = Source;
    _ = Header;
    _ = Chunk;
    _ = ImageInput;
    _ = AnimationInput;
    _ = AnimationSource;
    _ = FrameControl;
    _ = format;
    _ = metadata;
    _ = Limits;
    _ = image_decoding;
    _ = region_decoding;
    _ = row_reading;
    _ = RgbaConverter;
    _ = filters;
    _ = raster_decoding;
    _ = stream_decoding;
    _ = image_encoding;
    _ = raster_encoding;
    _ = metadata_encoding;
    _ = animation_decoding;
    _ = animation_encoding;
    _ = encode_backing.Workspace;
    _ = decode_backing.Workspace(u8);
    _ = decode_backing.Workspace(u16);
    _ = allocation;
    _ = ChunkWriter;
    _ = TestImage;
}
