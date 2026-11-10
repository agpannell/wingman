//! Owned PNG byte/word output, checked inflation and bounded transfer/replay storage.

const metadata_info = @import("metadata.zig");
const TestImage = @import("testdata/TestImage.zig");
const png_format = @import("format.zig");
const std = @import("std");
const png = @import("../png.zig");
const png_metadata_vectors = @import("testdata/metadata.zig");
const png_palette_vectors = @import("testdata/palette.zig");
const png_raster_vectors = @import("testdata/raster.zig");
const image_memory = @import("../common/allocation.zig");
const Inflater = zlib.Reader;
const Limits = @import("Limits.zig");
const deflate = @import("../deflate.zig");
const zlib = @import("../zlib.zig");
const SourceImage = @import("Source.zig");
const RgbaConverter = @import("RgbaConverter.zig");
const rgb_average = @import("testdata/raster.zig").average;
const ImageData = @import("ImageData.zig");
const filters = @import("scanline_filters.zig");
const raster = @import("raster_decoder.zig");
const regions = @import("region_decode.zig");
const decode_backing = @import("decode_workspace.zig");
const ImageRegion = @import("../common/ImageRegion.zig");

const Crc32 = @import("../crc.zig").Crc32IsoHdlc;

pub const default_maximum_source_extent = SourceImage.default_maximum_source_extent;
pub const Error = png_format.Error;
pub const IntoError = regions.Error;

const streaming_state_byte_count = @sizeOf(Inflater) + @alignOf(Inflater) - 1;

/// Pixel, structure and resource policy shared by allocating decode operations.
pub const Options = struct {
    /// Maximum complete encoded source length in bytes, including unused IDAT tails.
    maximum_encoded_bytes: usize = std.math.maxInt(usize),
    /// Largest accepted stored width or height. Zero rejects every image. PNG's 31-bit dimension
    /// bound applies independently of this caller limit.
    maximum_source_extent: u32 = default_maximum_source_extent,
    /// Independent output, scratch, structural metadata and work admission.
    limits: Limits = .{},
    /// Missing palette entries become opaque black; select `.reject` for strict ingestion.
    palette_index_policy: png_format.PaletteIndexPolicy = .opaque_black,
};

/// Owned RGBA samples with no allocator, source or scratch borrow. Sample is u8 or u16. Byte output
/// keeps high bytes of sixteen-bit source channels; native word output preserves or expands source
/// precision. Both retain the original bit-depth and color-type declarations. Copies share one
/// owner; release once with the producing allocator.
///
/// Both representations expose these fields:
///
/// | Field | Contract |
/// | --- | --- |
/// | `width`, `height` | Stored nonzero pixel dimensions, before orientation. |
/// | `texels` | Owned tight top-left RGBA `[]Sample`, four channels per pixel. |
/// | `metadata_presence` | Ancillary presence flags; payloads and transforms stay explicit. |
/// | `encoded_bit_depth`, `encoded_color_type` | Original stored PNG sample layout. |
///
/// Word results additionally expose `allocation`, the complete padded byte owner, which backs
/// `texels`. Release either result once with `image.deinit(output_allocator)`.
pub fn DecodedImage(comptime Sample: type) type {
    return switch (Sample) {
        u8 => struct {
            const Self = @This();

            /// Stored image width in pixels.
            width: u32,
            /// Stored image height in pixels.
            height: u32,
            /// Owned top-left row-major RGBA8 bytes, with length `width * height * 4`. Samples
            /// retain their encoded color values and unassociated alpha.
            texels: []u8,
            /// Original PNG sample depth; indexed images use this many bits per index.
            encoded_bit_depth: u8,
            /// Original PNG color-type byte before expansion into RGBA.
            encoded_color_type: u8,
            /// Copied ancillary presence flags; no payload query, color or orientation transform
            /// occurred.
            metadata_presence: metadata_info.Metadata.Presence,

            /// Releases `texels` through the output allocator that produced them. Invalidates this
            /// descriptor and every borrowed texel slice.
            pub fn deinit(self: *Self, output_allocator: std.mem.Allocator) void {
                output_allocator.free(self.texels);
                self.* = undefined;
            }
        },
        u16 => struct {
            const Self = @This();

            /// Stored image width in pixels.
            width: u32,
            /// Stored image height in pixels.
            height: u32,
            /// Four tightly packed unsigned 16-bit channels per texel.
            texels: []u16,
            /// Complete byte allocation, including alignment padding; texels borrow its storage.
            /// Release through `deinit` with the original output allocator.
            allocation: []u8,
            /// Original encoded bit depth before expansion; indexed layouts describe their index
            /// bits.
            encoded_bit_depth: u8,
            /// Original PNG color-type byte before expansion into RGBA.
            encoded_color_type: u8,
            /// Copied ancillary presence flags, without applying metadata transforms.
            metadata_presence: metadata_info.Metadata.Presence,

            /// Releases words through the output allocator passed to decode.rgbaAlloc(u16, ...) and
            /// invalidates borrows.
            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                allocator.free(self.allocation);
                self.* = undefined;
            }
        },
        else => @compileError("PNG output samples must be u8 or u16"),
    };
}

/// Restores one supported PNG into owned tightly packed RGBA samples without applying color or
/// orientation transforms. Alpha remains unassociated. Source framing, all filters, palette policy,
/// complete filtered length and Adler checksum must validate before publication. Shared allocation
/// authority can transfer validated byte/word storage rather than replaying rows, with its
/// documented temporary-capacity tradeoff. Every failure releases partial owners. Source bytes
/// remain immutable during the call.
pub fn rgbaAlloc(
    comptime Sample: type,
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) (std.mem.Allocator.Error || Error)!DecodedImage(Sample) {
    if (Sample == u8) return decodeByteAlloc(allocator, null, source, options);
    if (Sample == u16) return decodeWordAlloc(allocator, null, source, options);
    @compileError("PNG output samples must be u8 or u16");
}

/// Uses separate output and bounded scratch allocator parameters. Explicit scratch selects row
/// replay and disables temporary-storage transfer even when allocator handles alias. The returned
/// image is released with output_allocator; no allocator or source borrow is retained.
pub fn rgbaAllocWithScratch(
    comptime Sample: type,
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) (std.mem.Allocator.Error || Error)!DecodedImage(Sample) {
    if (Sample == u8) return decodeByteAlloc(output_allocator, scratch_allocator, source, options);
    if (Sample == u16) return decodeWordAlloc(output_allocator, scratch_allocator, source, options);
    @compileError("PNG output samples must be u8 or u16");
}

/// Policy for decoding into caller-owned storage. No field grants allocation authority.
pub const IntoOptions = struct {
    /// Publication into caller output: partial can expose provisional pixels before a later
    /// failure; transactional validates completely before replay and preserves all destination
    /// capacity on error.
    pub const Publication = enum { partial, transactional };

    /// Maximum complete encoded source length in bytes, including unused IDAT tails.
    maximum_encoded_bytes: usize = std.math.maxInt(usize),
    /// Maximum stored width or height in pixels; defaults to Source.default_maximum_source_extent.
    maximum_source_extent: u32 = SourceImage.default_maximum_source_extent,
    /// Independent selected output, work, metadata and storage policy.
    limits: Limits = .{},
    /// Missing palette indices recover as opaque black by default; `.reject` fails instead.
    palette_index_policy: png_format.PaletteIndexPolicy = .opaque_black,
    /// Validate before writing, or explicitly permit a provisional prefix.
    publication: Publication = .transactional,
};

/// Restores a complete PNG to the used tightly packed RGBA prefix without allocating. Sample is u8
/// or u16. Source and prepared backing stay live, immutable where borrowed and mutually disjoint.
/// Transactional publication is the default and preserves the entire destination on any reported
/// error. Explicit partial publication keeps the single-pass path and may expose provisional
/// pixels. Success preserves spare destination capacity. No color or orientation transform is
/// applied.
pub fn rgbaInto(
    comptime Sample: type,
    source: []const u8,
    destination: []Sample,
    storage: decode_backing.Storage(Sample),
    options: IntoOptions,
) IntoError!regions.View(Sample) {
    return admittedRgbaInto(Sample, try admit(source, options), destination, storage, options);
}

/// Decodes an admitted static image or APNG frame without reparsing framing. Source bytes and
/// palette views must remain unchanged and disjoint from destination and backing during the call.
pub fn admittedRgbaInto(
    comptime Sample: type,
    image: SourceImage,
    destination: []Sample,
    storage: decode_backing.Storage(Sample),
    policy: IntoOptions,
) IntoError!regions.View(Sample) {
    return switch (policy.publication) {
        .partial => decodePartial(Sample, image, destination, storage, policy),
        .transactional => decodeTransactional(Sample, image, destination, storage, policy),
    };
}

/// Decodes an already admitted static image or local APNG frame without allocating. The source,
/// palette and chunk ranges stay unchanged through this call. A failure can leave provisional
/// pixels; all unused output capacity is preserved. Resource limits still apply.
fn decodePartial(
    comptime Sample: type,
    image: SourceImage,
    destination: []Sample,
    storage: decode_backing.Storage(Sample),
    options: IntoOptions,
) IntoError!regions.View(Sample) {
    try regions.admitImage(
        image,
        .{
            .limits = options.limits,
            .maximum_source_extent = options.maximum_source_extent,
            .maximum_encoded_bytes = options.maximum_encoded_bytes,
        },
    );
    const rectangle: ImageRegion = .{
        .x = 0,
        .y = 0,
        .width = image.width,
        .height = image.height,
    };
    const plan = try regions.Plan(
        Sample,
    ).init(image.header(), rectangle, image.image_data.source.len, options.limits);
    const fixed_work = plan.requirements.row_fixed_work_units;
    try png_format.admitWork(options.limits, fixed_work);
    if (destination.len < plan.requirements.samples) return error.DestinationTooSmall;
    var reader = try raster.PassRowReader(
        Sample,
    ).init(
        image,
        storage,
        options.limits.maximum_work_units - fixed_work,
        options.palette_index_policy,
    );
    const output = destination[0..plan.requirements.samples];
    while (try reader.next()) |row| plan.scatter(row, output);
    return .{
        .width = image.width,
        .height = image.height,
        .source_header = image.header(),
        .texels = output,
    };
}

/// Performs the complete transaction for an admitted static or frame-local PNG source. The same
/// disjoint storage and unchanged-source requirements of transactional publication apply.
fn decodeTransactional(
    comptime Sample: type,
    image: SourceImage,
    destination: []Sample,
    storage: decode_backing.Storage(Sample),
    options: IntoOptions,
) IntoError!regions.View(Sample) {
    return regions.admittedInto(
        Sample,
        image,
        .{ .x = 0, .y = 0, .width = image.width, .height = image.height },
        destination,
        storage,
        .{
            .limits = options.limits,
            .palette_index_policy = options.palette_index_policy,
            .maximum_source_extent = options.maximum_source_extent,
            .maximum_encoded_bytes = options.maximum_encoded_bytes,
        },
    );
}

fn admit(source: []const u8, options: IntoOptions) IntoError!SourceImage {
    try png_format.admitWork(options.limits, source.len);
    return SourceImage.open(
        source,
        .{
            .maximum_encoded_bytes = options.maximum_encoded_bytes,
            .maximum_source_extent = options.maximum_source_extent,
            .maximum_records = options.limits.maximum_records,
            .maximum_metadata_bytes = options.limits.maximum_metadata_bytes,
        },
    );
}

test rgbaAlloc {
    const allocator = std.testing.allocator;
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128 };
    const bytes = try png.encode.alloc(allocator, try png.ImageInput.rgba8(&rgba, 2, 1), .{});
    defer allocator.free(bytes);
    var image = try rgbaAlloc(u8, allocator, bytes, .{});
    defer image.deinit(allocator);
    try std.testing.expectEqual(2, image.width);
    try std.testing.expectEqualSlices(u8, &rgba, image.texels);
}

fn decodeByteAlloc(
    output_allocator: std.mem.Allocator,
    scratch_allocator: ?std.mem.Allocator,
    source: []const u8,
    options: Options,
) (std.mem.Allocator.Error || Error)!DecodedImage(u8) {
    var scratch: image_memory.Scratch = .{
        .backing = scratch_allocator orelse output_allocator,
        .maximum_bytes = options.limits.maximum_scratch_bytes,
    };
    return decodeByteImage(
        output_allocator,
        scratch_allocator == null,
        source,
        options,
        &scratch,
    ) catch |err| return scratch.classifyFailure(err);
}

fn decodeByteImage(
    output_allocator: std.mem.Allocator,
    allow_transfer: bool,
    source: []const u8,
    options: Options,
    scratch: *image_memory.Scratch,
) (std.mem.Allocator.Error || Error)!DecodedImage(u8) {
    const scratch_allocator = scratch.allocator();
    const image = try admitSource(source, options);
    const image_width: usize = image.width;
    const image_height: usize = image.height;
    var fixed_input: std.Io.Reader = undefined;
    var chunked_input: ImageData.Reader = undefined;
    const compressed_reader = image.image_data.reader(&fixed_input, &chunked_input);
    // Admit PNG's header across arbitrary IDAT boundaries before reserving inflate storage.
    const zlib_header = compressed_reader.peekArray(2) catch return error.InvalidPng;
    zlib.validateHeader(zlib_header) catch return error.InvalidPng;

    const pixel_count = checkedMul(image_width, image_height) catch return error.InvalidPng;
    const rgba_byte_count = checkedMul(pixel_count, 4) catch return error.InvalidPng;
    try png_format.admitOutput(options.limits, pixel_count, rgba_byte_count);
    const transfer_admitted = allow_transfer and transferScratchBound(
        image,
        rgba_byte_count,
    ) <= options.limits.maximum_scratch_bytes;
    // The caller explicitly selects one allocation authority by omitting scratch. Stateless
    // allocators may leave their opaque context undefined, so comparing handles cannot safely
    // discover this relationship. Remap may relocate or decline.
    const can_reuse_rows = (image.color_type == 2 or image.color_type == 6) and image.bit_depth ==
        8 and image.interlace_method == 0 and transfer_admitted;
    const validated = if (can_reuse_rows) blk: {
        switch (try reuseSequentialRows(&image, scratch_allocator, rgba_byte_count)) {
            .rgba => |rgba| return .{
                .width = image.width,
                .height = image.height,
                .texels = rgba,
                .encoded_bit_depth = image.bit_depth,
                .encoded_color_type = image.color_type,
                .metadata_presence = image.metadata_presence,
            },
            .validated => break :blk true,
            .unavailable => break :blk false,
        }
    } else if (transfer_admitted) blk: {
        switch (try reuseExpandedRows(
            u8,
            &image,
            scratch_allocator,
            rgba_byte_count,
            options.palette_index_policy,
        )) {
            .output => |owner| return .{
                .width = image.width,
                .height = image.height,
                .texels = owner.samples,
                .encoded_bit_depth = image.bit_depth,
                .encoded_color_type = image.color_type,
                .metadata_presence = image.metadata_presence,
            },
            .validated => break :blk true,
            .unavailable => break :blk false,
        }
    } else false;

    // Validate length and the filtered-byte checksum before reserving output. Retire this window
    // first, even when distinct allocator handles alias one tail-reclaiming region. Reconstruction
    // then owns only storage above output.
    if (!validated) {
        try validateImageData(image.image_data, scratch_allocator, image.filtered_byte_count);
    }
    const rgba = try output_allocator.alloc(u8, rgba_byte_count);
    errdefer output_allocator.free(rgba);

    try replayImageRows(u8, image, rgba, options.palette_index_policy, scratch_allocator);
    return .{
        .width = image.width,
        .height = image.height,
        .texels = rgba,
        .encoded_bit_depth = image.bit_depth,
        .encoded_color_type = image.color_type,
        .metadata_presence = image.metadata_presence,
    };
}

fn decodeWordAlloc(
    output_allocator: std.mem.Allocator,
    scratch_allocator: ?std.mem.Allocator,
    source: []const u8,
    options: Options,
) (std.mem.Allocator.Error || Error)!DecodedImage(u16) {
    var scratch: image_memory.Scratch = .{
        .backing = scratch_allocator orelse output_allocator,
        .maximum_bytes = options.limits.maximum_scratch_bytes,
    };
    return decodeWordImage(
        output_allocator,
        scratch_allocator == null,
        source,
        options,
        &scratch,
    ) catch |err| return scratch.classifyFailure(err);
}

fn decodeWordImage(
    output_allocator: std.mem.Allocator,
    allow_transfer: bool,
    source: []const u8,
    options: Options,
    scratch: *image_memory.Scratch,
) (std.mem.Allocator.Error || Error)!DecodedImage(u16) {
    const image = try admitSource(source, options);
    var fixed: std.Io.Reader = undefined;
    var chunked: ImageData.Reader = undefined;
    const reader = image.image_data.reader(&fixed, &chunked);
    const header = reader.peekArray(2) catch return error.InvalidPng;
    zlib.validateHeader(header) catch return error.InvalidPng;
    const pixel_count = checkedMul(image.width, image.height) catch return error.InvalidPng;
    const count = checkedMul(pixel_count, 4) catch return error.InvalidPng;
    const byte_count = checkedMul(count, @sizeOf(u16)) catch return error.InvalidPng;
    try png_format.admitOutput(options.limits, pixel_count, byte_count);
    const scratch_allocator = scratch.allocator();
    const validated = if (allow_transfer and transferScratchBound(
        image,
        byte_count +| 1,
    ) <= options.limits.maximum_scratch_bytes) blk: {
        switch (try reuseExpandedRows(
            u16,
            &image,
            scratch_allocator,
            count,
            options.palette_index_policy,
        )) {
            .output => |owner| return .{
                .width = image.width,
                .height = image.height,
                .texels = owner.samples,
                .allocation = owner.allocation,
                .encoded_bit_depth = image.bit_depth,
                .encoded_color_type = image.color_type,
                .metadata_presence = image.metadata_presence,
            },
            .validated => break :blk true,
            .unavailable => break :blk false,
        }
    } else false;
    if (!validated) try validateImageData(
        image.image_data,
        scratch_allocator,
        image.filtered_byte_count,
    );
    const output = image_memory.AlignedAllocation(
        u16,
    ).init(output_allocator, count) catch |err| switch (err) {
        error.SizeOverflow => return error.InvalidPng,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer output_allocator.free(output.storage);
    try replayImageRows(
        u16,
        image,
        output.samples,
        options.palette_index_policy,
        scratch_allocator,
    );
    return .{
        .width = image.width,
        .height = image.height,
        .texels = output.samples,
        .allocation = output.storage,
        .encoded_bit_depth = image.bit_depth,
        .encoded_color_type = image.color_type,
        .metadata_presence = image.metadata_presence,
    };
}

/// Raster decoding failures plus caller-reserved destination capacity.
pub const ImageDecodeError = Error || error{OutputTooSmall};

/// Explicit scratch and work/output policy for validating or reconstructing an admitted raster. No
/// operation retains the scratch allocator.
pub const ImageDecodeOptions = struct {
    /// Allocator for a temporary window, final-address inflater and at most two packed rows.
    scratch_allocator: std.mem.Allocator,
    /// Admits pixels, output bytes (zero for validation), payload bytes and four filtered-byte
    /// visits; `decodeImageIntoTransactional` counts six for complete row validation.
    limits: Limits = .{},
    /// Applies to validation and reconstruction, including indices outside selected output.
    palette_index_policy: png_format.PaletteIndexPolicy = .opaque_black,
};

/// Checks an admitted PNG/APNG raster without reserving or writing pixel output. Complete filtered
/// length, Adler checksum, filters and the selected palette policy are checked in two passes using
/// a bounded inflater and at most two packed rows, including Adam7. Source, palettes and admitted
/// chunk bounds stay live, immutable and disjoint from scratch. Policy admits the image's pixel
/// count and zero output bytes, plus encoded payload bytes and four visits per filtered byte. All
/// temporary storage retires before returning.
pub fn validateImage(
    image: SourceImage,
    options: ImageDecodeOptions,
) (std.mem.Allocator.Error || Error)!void {
    const pixels_count = checkedMul(image.width, image.height) catch return error.InvalidPng;
    try png_format.admitOutput(options.limits, pixels_count, 0);
    const visits = checkedMul(image.filtered_byte_count, 4) catch return error.WorkBudgetExceeded;
    try png_format.admitWork(
        options.limits,
        checkedAdd(image.image_data.byte_count, visits) catch return error.WorkBudgetExceeded,
    );
    try validateImageHeader(image.image_data);
    var scratch: image_memory.Scratch = .{
        .backing = options.scratch_allocator,
        .maximum_bytes = options.limits.maximum_scratch_bytes,
    };
    validateImageContents(
        image,
        options.palette_index_policy,
        scratch.allocator(),
    ) catch |err| return scratch.classifyFailure(err);
}

/// Reconstructs an admitted PNG/APNG image view into a reserved byte or word prefix. `Sample` is u8
/// or u16; word output preserves full samples as host-native words. Source, palettes and admitted
/// chunk bounds stay live and unchanged for the call. Destination is disjoint from source and
/// scratch; its unused suffix stays unchanged. Zlib header, filtered length and Adler checks
/// precede writes. A later filter, palette or replay failure may leave a visible partial prefix; no
/// storage is retained.
pub fn decodeImageInto(
    comptime Sample: type,
    image: SourceImage,
    destination: []Sample,
    options: ImageDecodeOptions,
) (std.mem.Allocator.Error || ImageDecodeError)!void {
    return decodeReservedImage(Sample, false, image, destination, options);
}

/// Reconstructs an admitted PNG/APNG image transactionally into reserved bytes or words. Complete
/// filtered length, checksum, filter and selected palette-index admission precedes destination
/// writes. Every reported error preserves all destination, including its suffix. Source/palettes
/// stay immutable and disjoint from destination/scratch through validation and replay. Three input
/// passes use a bounded inflater and at most two packed rows; no full-raster staging is reserved.
/// Replay allocates all resources before its first write. Work counts encoded payload bytes plus
/// six visits per filtered byte. No storage is retained.
pub fn decodeImageIntoTransactional(
    comptime Sample: type,
    image: SourceImage,
    destination: []Sample,
    options: ImageDecodeOptions,
) (std.mem.Allocator.Error || ImageDecodeError)!void {
    return decodeReservedImage(Sample, true, image, destination, options);
}

fn decodeReservedImage(
    comptime Sample: type,
    comptime transactional: bool,
    image: SourceImage,
    destination: []Sample,
    options: ImageDecodeOptions,
) (std.mem.Allocator.Error || ImageDecodeError)!void {
    if (Sample != u8 and Sample != u16) @compileError("PNG output samples must be u8 or u16");
    const pixels_count = checkedMul(image.width, image.height) catch return error.InvalidPng;
    const count = checkedMul(pixels_count, 4) catch return error.InvalidPng;
    const bytes = checkedMul(count, @sizeOf(Sample)) catch return error.InvalidPng;
    try png_format.admitOutput(options.limits, pixels_count, bytes);
    if (destination.len < count) return error.OutputTooSmall;
    const visits = checkedMul(
        image.filtered_byte_count,
        if (transactional) 6 else 4,
    ) catch return error.WorkBudgetExceeded;
    try png_format.admitWork(
        options.limits,
        checkedAdd(image.image_data.byte_count, visits) catch return error.WorkBudgetExceeded,
    );
    try validateImageHeader(image.image_data);
    var scratch: image_memory.Scratch = .{
        .backing = options.scratch_allocator,
        .maximum_bytes = options.limits.maximum_scratch_bytes,
    };
    const allocator = scratch.allocator();
    (if (transactional) validateImageContents(
        image,
        options.palette_index_policy,
        allocator,
    ) else validateImageData(
        image.image_data,
        allocator,
        image.filtered_byte_count,
    )) catch |err| return scratch.classifyFailure(err);
    replayImageRows(
        Sample,
        image,
        destination[0..count],
        options.palette_index_policy,
        allocator,
    ) catch |err| switch (err) {
        error.OutOfMemory => {
            // Window, rows and final-address inflater are all reserved before the first output
            // write. Their failure therefore preserves the complete destination.
            return scratch.classifyFailure(err);
        },
        // Immutable admitted geometry/input and identical row traversal were just validated. No
        // fallible allocator or consumer callback runs after the first write.
        else => if (transactional) unreachable else return err,
    };
}

fn validateImageHeader(image_data: ImageData) Error!void {
    var fixed: std.Io.Reader = undefined;
    var chunked: ImageData.Reader = undefined;
    const input = image_data.reader(&fixed, &chunked);
    const header = input.peekArray(2) catch return error.InvalidPng;
    zlib.validateHeader(header) catch return error.InvalidPng;
}

fn validateImageContents(
    image: SourceImage,
    policy: png_format.PaletteIndexPolicy,
    allocator: std.mem.Allocator,
) (std.mem.Allocator.Error || Error)!void {
    try validateImageData(image.image_data, allocator, image.filtered_byte_count);
    // Without output, reconstruction and palette checks use the encoded sample layout; the output
    // sample type does not select a different validation path.
    try replayImageRows(u8, image, null, policy, allocator);
}

// Admission units count source bytes plus four filtered-byte visits: inflation/checksum, possible
// storage-transfer probes and bounded replay/filtering. This conservative bound does not represent
// wall time or individual CPU instructions.
fn admitSource(source: []const u8, options: Options) Error!SourceImage {
    try png_format.admitWork(options.limits, source.len);
    const image = try SourceImage.open(
        source,
        .{
            .maximum_encoded_bytes = options.maximum_encoded_bytes,
            .maximum_source_extent = options.maximum_source_extent,
            .maximum_records = options.limits.maximum_records,
            .maximum_metadata_bytes = options.limits.maximum_metadata_bytes,
        },
    );
    const visits = checkedMul(image.filtered_byte_count, 4) catch return error.WorkBudgetExceeded;
    const units = std.math.add(usize, source.len, visits) catch return error.WorkBudgetExceeded;
    try png_format.admitWork(options.limits, units);
    return image;
}

// Optional transfer can retain output, filtered rows, joined input and either inflater. If this
// conservative reservation exceeds policy, bounded replay remains available.
fn transferScratchBound(image: SourceImage, output_bytes: usize) usize {
    const filtered = image.filtered_byte_count;
    const joined = @min(image.image_data.byte_count, (filtered *| 2) +| 64);
    return output_bytes +| filtered +| joined +| streaming_state_byte_count +| @sizeOf(
        deflate.DecoderWorkspace,
    ) +| @alignOf(deflate.DecoderWorkspace) +| 1024 +| Inflater.history_bytes;
}

fn replayImageRows(
    comptime Sample: type,
    image: SourceImage,
    rgba: ?[]Sample,
    policy: png_format.PaletteIndexPolicy,
    scratch_allocator: std.mem.Allocator,
) (std.mem.Allocator.Error || Error)!void {
    const image_width: usize = image.width;
    const image_height: usize = image.height;
    const converter = RgbaConverter.initWithPolicy(image, policy);
    const direct_rgba_rows = rgba != null and Sample == u8 and image.color_type == 6 and image
        .bit_depth == 8 and image.interlace_method == 0;
    const bit_depth: usize = image.bit_depth;
    const filter_bytes_per_pixel = if (bit_depth < 8 or image.color_type == 3) 1 else image
        .channel_count * (bit_depth / 8);
    var fixed_input: std.Io.Reader = undefined;
    var chunked_input: ImageData.Reader = undefined;
    const window = try scratch_allocator.alloc(u8, Inflater.history_bytes);
    defer scratch_allocator.free(window);
    // A one-row image has no previous row in any sequential or Adam7 pass.
    const row_storage: []u8 = if (Sample == u8 and direct_rgba_rows)
        rgba.?
    else
        try scratch_allocator.alloc(
            u8,
            checkedMul(image.packed_row_bytes, @min(image_height, 2)) catch return error.InvalidPng,
        );
    defer {
        if (!direct_rgba_rows) scratch_allocator.free(row_storage);
    }
    var inflate_storage = try InflateStorage(Inflater).init(scratch_allocator);
    defer inflate_storage.deinit(scratch_allocator);
    const decompress = inflate_storage.state();
    decompress.init(image.image_data.reader(&fixed_input, &chunked_input), window);

    const pass_count = if (image.interlace_method == 0) 1 else png_format.adam7_passes.len;
    for (0..pass_count) |pass_index| {
        const pass = if (image.interlace_method == 0) png_format.sequential_pass else png_format
            .adam7_passes[pass_index];
        const pass_width = png_format.passExtent(image_width, pass.start_x, pass.step_x);
        const pass_height = png_format.passExtent(image_height, pass.start_y, pass.step_y);
        if (pass_width == 0 or pass_height == 0) continue;

        const pass_packed_row_bytes = png_format.packedRowBytes(
            pass_width,
            image.bits_per_pixel,
        ) catch return error.InvalidPng;
        // Each Adam7 pass starts a new reduced image for filtering purposes. Two rows suffice: the
        // next row may overwrite the row before its predecessor.
        for (0..pass_height) |row| {
            const current_offset = if (direct_rgba_rows) row * image.packed_row_bytes else (row %
                2) * image.packed_row_bytes;
            const current = row_storage[current_offset..][0..pass_packed_row_bytes];
            const previous: ?[]const u8 = if (row == 0) null else blk: {
                const previous_offset = if (direct_rgba_rows) (row - 1) * image
                    .packed_row_bytes else ((row - 1) % 2) * image.packed_row_bytes;
                break :blk row_storage[previous_offset..][0..pass_packed_row_bytes];
            };
            const filter = decompress.reader.takeByte() catch return error.InvalidPng;
            if (filter > 4) return error.InvalidPng;
            decompress.reader.readSliceAll(current) catch return error.InvalidPng;
            filters.reconstructRow(current, current, previous, filter_bytes_per_pixel, filter);
            if (!direct_rgba_rows and rgba != null) {
                try converter.convertPassRow(
                    Sample,
                    rgba.?,
                    image.width,
                    pass,
                    pass_width,
                    pass.start_y + row * pass.step_y,
                    current,
                );
            } else if (rgba == null) try converter.validateRow(pass_width, current);
        }
    }
    // The first pass checked the checksum over this immutable source. The replay still checks
    // stream completion after consuming all declared pass-local rows.
    try finishImageData(decompress);
}

// Joining is optional. Keep source-sized copies bounded by admitted filtered work; larger legal
// payloads, including unused tails, retain bounded streaming validation.
fn canJoinImageData(payload_bytes: usize, filtered_bytes: usize) bool {
    const twice_filtered = std.math.mul(usize, filtered_bytes, 2) catch return false;
    const limit = std.math.add(usize, twice_filtered, 64) catch return false;
    return payload_bytes <= limit;
}

// Transfer may return completed RGBA, validated replay or require fresh bounded validation.
const RowTransfer = union(enum) { rgba: []u8, validated, unavailable };

fn ExpandedTransfer(comptime Sample: type) type {
    return union(enum) {
        output: struct { allocation: []u8, samples: []Sample },
        validated,
        unavailable,
    };
}

// Other formats can borrow the filtered allocation's tail for a disjoint source while constructing
// output at its front. A declined remap retains bounded replay.
fn reuseExpandedRows(
    comptime Sample: type,
    image: *const SourceImage,
    allocator: std.mem.Allocator,
    sample_count: usize,
    policy: png_format.PaletteIndexPolicy,
) (std.mem.Allocator.Error || Error)!ExpandedTransfer(Sample) {
    const output_bytes = std.math.mul(
        usize,
        sample_count,
        @sizeOf(Sample),
    ) catch return .unavailable;
    const output_capacity = std.math.add(
        usize,
        output_bytes,
        @alignOf(Sample) - 1,
    ) catch return .unavailable;
    const data = image.image_data;
    if (data.multiple and !canJoinImageData(data.byte_count, image.filtered_byte_count)) {
        return .unavailable;
    }
    const joined_bytes = if (data.multiple) data.byte_count else 0;
    const payload_end = std.math.add(
        usize,
        image.filtered_byte_count,
        joined_bytes,
    ) catch return .unavailable;
    const stage_length = std.math.add(
        usize,
        payload_end,
        @sizeOf(deflate.DecoderWorkspace) + @alignOf(deflate.DecoderWorkspace) - 1,
    ) catch return .unavailable;

    // The required initial reservation matches bounded streaming validation. Larger
    // filtered/history/conversion storage is optional, so declining it cannot consume memory needed
    // by the caller's established bounded budget.
    var backing = try allocator.alloc(u8, Inflater.history_bytes);
    var owns_backing = true;
    defer if (owns_backing) allocator.free(backing);
    backing = allocator.remap(backing, stage_length) orelse return .unavailable;
    const source = if (data.multiple) blk: {
        const joined = backing[image.filtered_byte_count..payload_end];
        data.copyInto(joined);
        break :blk joined;
    } else data.first;
    const address = std.mem.alignForward(
        usize,
        @intFromPtr(backing.ptr) + payload_end,
        @alignOf(deflate.DecoderWorkspace),
    );
    const workspace: *deflate.DecoderWorkspace = @ptrFromInt(address);
    try inflateContiguous(source, backing[0..image.filtered_byte_count], workspace);

    // The decoder state is retired before growth or relocation. Admission has checked the complete
    // filtered length and consumed Adler before output use.
    const filtered_end = std.math.add(
        usize,
        output_capacity,
        image.filtered_byte_count,
    ) catch return .validated;
    // Indexed conversion can prepare its RGBA lookup in an optional aligned tail. It retires with
    // filtered staging and adds no allocation or retained pointer.
    const palette_bytes: usize = if (Sample == u8 and image.color_type == 3) @sizeOf(
        RgbaConverter.Palette,
    ) + @alignOf(RgbaConverter.Palette) - 1 else 0;
    const combined_length = std.math.add(
        usize,
        filtered_end,
        palette_bytes,
    ) catch return .validated;
    backing = allocator.remap(backing, combined_length) orelse return .validated;
    // The slices may overlap; the intrinsic selects an exact bounded bulk move instead of reloading
    // each backward byte through the preceding store.
    @memmove(
        backing[output_capacity..][0..image.filtered_byte_count],
        backing[0..image.filtered_byte_count],
    );
    const filtered = backing[output_capacity..filtered_end];
    const output_offset = std.mem.alignForward(
        usize,
        @intFromPtr(backing.ptr),
        @alignOf(Sample),
    ) - @intFromPtr(backing.ptr);
    const rgba: []Sample = @as(
        [*]Sample,
        @ptrCast(@alignCast(backing[output_offset..].ptr)),
    )[0..sample_count];
    const converter = RgbaConverter.initWithPolicy(image.*, policy);
    const palette: ?*const RgbaConverter.Palette = if (Sample == u8 and image.color_type ==
        3)
    blk: {
        const palette_address = std.mem.alignForward(
            usize,
            @intFromPtr(backing.ptr) + filtered_end,
            @alignOf(RgbaConverter.Palette),
        );
        const prepared: *RgbaConverter.Palette = @ptrFromInt(palette_address);
        prepared.initWithPolicy(image.*, policy);
        break :blk prepared;
    } else null;
    const bit_depth: usize = image.bit_depth;
    const bytes_per_channel = bit_depth / 8;
    const bpp = if (bit_depth < 8 or image.color_type == 3) 1 else image.channel_count *
        bytes_per_channel;
    const pass_count = if (image.interlace_method == 0) 1 else png_format.adam7_passes.len;
    var position: usize = 0;
    for (0..pass_count) |pass_index| {
        const pass = if (image.interlace_method == 0) png_format.sequential_pass else png_format
            .adam7_passes[pass_index];
        const width = png_format.passExtent(image.width, pass.start_x, pass.step_x);
        const height = png_format.passExtent(image.height, pass.start_y, pass.step_y);
        if (width == 0 or height == 0) continue;
        // The admitted full-width packed row bounds every reduced pass row.
        const row_bytes = png_format.packedRowBytes(width, image.bits_per_pixel) catch unreachable;
        const pass_bytes = height * (row_bytes + 1);
        const grouped = filters.packedPassHasGroups(
            filtered[position..][0..pass_bytes],
            row_bytes,
            height,
            bpp,
        );
        if (grouped) {
            try @call(
                .never_inline,
                filters.reconstructPackedRows,
                .{ filtered[position..][0..pass_bytes], row_bytes, height, bpp },
            );
        }
        var previous: ?[]const u8 = null;
        for (0..height) |row| {
            const current = filtered[position + 1 ..][0..row_bytes];
            if (!grouped) {
                const filter = filtered[position];
                if (filter > 4) return error.InvalidPng;
                filters.reconstructRow(current, current, previous, bpp, filter);
            }
            if (Sample == u8) {
                if (palette) |prepared| {
                    try prepared.convertPassRow(
                        image.*,
                        rgba,
                        pass,
                        width,
                        pass.start_y + row * pass.step_y,
                        current,
                    );
                } else {
                    try RgbaConverter.convertRgbaRow(
                        image.*,
                        rgba,
                        pass,
                        width,
                        pass.start_y + row * pass.step_y,
                        current,
                    );
                }
            } else {
                try converter.convertPassRow(
                    Sample,
                    rgba,
                    image.width,
                    pass,
                    width,
                    pass.start_y + row * pass.step_y,
                    current,
                );
            }
            previous = current;
            position += row_bytes + 1;
        }
    }
    std.debug.assert(position == filtered.len);
    const result = allocator.remap(backing, output_capacity) orelse return .validated;
    // Transfer the single allocation without its filtered tail to the caller.
    owns_backing = false;
    // A byte-aligned remap can relocate to a different word alignment residue. Move the completed
    // samples within their padded raw owner before publishing the new typed view.
    const final_offset = std.mem.alignForward(
        usize,
        @intFromPtr(result.ptr),
        @alignOf(Sample),
    ) - @intFromPtr(result.ptr);
    if (final_offset != output_offset) @memmove(
        result[final_offset..][0..output_bytes],
        result[output_offset..][0..output_bytes],
    );
    return .{
        .output = .{
            .allocation = result,
            .samples = @as(
                [*]Sample,
                @ptrCast(@alignCast(result[final_offset..].ptr)),
            )[0..sample_count],
        },
    };
}

fn validateImageData(
    image_data: ImageData,
    allocator: std.mem.Allocator,
    filtered_byte_count: usize,
) (std.mem.Allocator.Error || Error)!void {
    const window = try allocator.alloc(u8, Inflater.history_bytes);
    defer allocator.free(window);
    var fixed: std.Io.Reader = undefined;
    var chunked: ImageData.Reader = undefined;
    var inflate_storage = try InflateStorage(Inflater).init(allocator);
    defer inflate_storage.deinit(allocator);
    const decompress = inflate_storage.state();
    decompress.init(image_data.reader(&fixed, &chunked), window);
    var remaining = filtered_byte_count;
    while (remaining != 0) {
        const buffered = decompress.reader.peekGreedy(1) catch return error.InvalidPng;
        const count = @min(remaining, buffered.len);
        decompress.reader.toss(count);
        remaining -= count;
    }
    try finishImageData(decompress);
}

fn finishImageData(decompress: *Inflater) Error!void {
    // Reject extra filtered bytes and consume the footer. Its recorded checksum precedes any valid
    // unused bytes left in the final IDAT chunk.
    if (decompress.reader.takeByte()) |_| {
        return error.InvalidPng;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return error.InvalidPng,
    }
}

// Every non-transfer result releases its temporaries. Failed final remapping retains checksum
// admission; an unfinished bounded stream must validate before replay instead.
fn reuseSequentialRows(
    image: *const SourceImage,
    allocator: std.mem.Allocator,
    rgba_byte_count: usize,
) (std.mem.Allocator.Error || Error)!RowTransfer {
    const image_data = image.image_data;
    var backing = try allocator.alloc(u8, image.filtered_byte_count);
    var owns_backing = true;
    defer if (owns_backing) allocator.free(backing);
    if (!try inflateStoredImageData(image_data, backing)) {
        if (!image_data.multiple) {
            var storage = try InflateStorage(deflate.DecoderWorkspace).init(allocator);
            defer storage.deinit(allocator);
            try inflateContiguous(image_data.first, backing, storage.state());
        } else {
            // Inflate restarts after the stored-only probe, so its private output can retire. Grow
            // a small owner rather than preserving a full uninitialized filtered frame. A declined
            // growth restores the original filtered/streaming-state allocation order and bounded
            // budget. Page-based allocators may still grow the restored large owner even when a
            // small slot cannot become a large mapping. An unused payload tail must not cause
            // disproportionate temporary growth.
            const payload_end: ?usize = if (canJoinImageData(
                image_data.byte_count,
                image.filtered_byte_count,
            )) std.math.add(usize, backing.len, image_data.byte_count) catch null else null;
            const joined_length: ?usize = if (payload_end) |end| std.math.add(
                usize,
                end,
                @sizeOf(deflate.DecoderWorkspace) + @alignOf(deflate.DecoderWorkspace) - 1,
            ) catch null else null;
            var joined: ?[]u8 = null;
            var storage: ?InflateStorage(Inflater) = null;
            defer if (storage) |value| value.deinit(allocator);
            if (joined_length) |length| {
                allocator.free(backing);
                owns_backing = false;
                // This seed fits the original streaming-state reservation.
                const seed = try allocator.alloc(u8, @sizeOf(Inflater) + @alignOf(Inflater) - 1);
                if (allocator.remap(seed, length)) |bytes| {
                    backing = bytes;
                    owns_backing = true;
                    joined = bytes;
                } else {
                    allocator.free(seed);
                    backing = try allocator.alloc(u8, image.filtered_byte_count);
                    owns_backing = true;
                }
            }
            if (joined == null) {
                // Reserve state above the filtered owner before retrying growth. Bounded tail
                // allocators can then decline without losing stream space.
                storage = try InflateStorage(Inflater).init(allocator);
                if (joined_length) |length| joined = allocator.remap(backing, length);
            }
            if (joined) |bytes| {
                backing = bytes;
                const payload = backing[image.filtered_byte_count..payload_end.?];
                image_data.copyInto(payload);
                // The final-address workspace occupies only the optional tail. It is disjoint from
                // input/output, and its synchronous use ends before remap.
                const address = std.mem.alignForward(
                    usize,
                    @intFromPtr(backing.ptr) + payload_end.?,
                    @alignOf(deflate.DecoderWorkspace),
                );
                const workspace: *deflate.DecoderWorkspace = @ptrFromInt(address);
                try inflateContiguous(payload, backing[0..image.filtered_byte_count], workspace);
            } else {
                // Alignment belongs to the state byte owner, so an unaligned retained prefix cannot
                // strand allocator padding. Filtered bytes provide LZ history.
                const filtered = backing[0..image.filtered_byte_count];
                const decompress = storage.?.state();
                var fixed: std.Io.Reader = undefined;
                var chunked: ImageData.Reader = undefined;
                const history = try allocator.alloc(u8, Inflater.history_bytes);
                defer allocator.free(history);
                decompress.init(image_data.reader(&fixed, &chunked), history);
                var writer: std.Io.Writer = .fixed(filtered);
                const produced = decompress.reader.streamRemaining(&writer) catch |err| {
                    // A bounded Writer can refuse output before stream completion. A full
                    // destination can precede valid block/footer completion. Retire private staging
                    // and let bounded validation check the complete stream; an extra output byte or
                    // a bad Adler still fails before publication.
                    if (err == error.WriteFailed and writer.end == filtered.len)
                        return .unavailable;
                    return error.InvalidPng;
                };
                if (produced != filtered.len or writer.end != filtered.len) return error.InvalidPng;
            }
        }
    }
    const filtered = backing[0..image.filtered_byte_count];
    const fused_average = image.color_type == 2 and image.transparent_rgb == null and image.width >=
        32 and image.height >= 32 and average: {
        for (0..image.height) |row| {
            if (filtered[row * (image.packed_row_bytes + 1)] != 3) break :average false;
        }
        break :average true;
    };
    // Keep row reconstruction out of line: inlining its grouped loops slows run-heavy inputs.
    if (!fused_average and image.color_type == 6) {
        try @call(
            .never_inline,
            filters.reconstructRgba8Rows,
            .{ filtered, image.packed_row_bytes, image.height },
        );
    } else if (!fused_average) {
        try @call(
            .never_inline,
            filters.reconstructRgb8Rows,
            .{ filtered, image.packed_row_bytes, image.height },
        );
    }
    // Release any compressed tail and resize to exact returned ownership. State has retired and
    // checksum/filter admission is complete before this transfer. All-Average RGB stays filtered
    // until growth succeeds, so it can reconstruct directly into final RGBA slots. A declined remap
    // retains validated replay.
    const rgba = allocator.remap(backing, rgba_byte_count) orelse return .validated;
    owns_backing = false;
    if (fused_average) {
        @call(
            .never_inline,
            filters.reconstructAverageRgb8Rgba8,
            .{ rgba, image.packed_row_bytes, image.height },
        );
    } else if (image.color_type == 2) {
        RgbaConverter.expandRgb8InPlace(rgba, image.transparent_rgb);
    }
    return .{ .rgba = rgba };
}

// Stored-only Reader decoding keeps split payloads borrowed. A null result restarts the general
// path; partial filtered output stays private until success.
fn inflateStoredImageData(image_data: ImageData, filtered: []u8) Error!bool {
    var fixed: std.Io.Reader = undefined;
    var chunked: ImageData.Reader = undefined;
    const reader = image_data.reader(&fixed, &chunked);
    const result = (zlib.decodeStoredReader(
        reader,
        filtered,
    ) catch return error.InvalidPng) orelse return false;
    if (result.produced != filtered.len) return error.InvalidPng;
    return true;
}

fn inflateContiguous(
    source: []const u8,
    filtered: []u8,
    workspace: *deflate.DecoderWorkspace,
) Error!void {
    // Keep the token loop out of line: LLVM inlining here slows literal-heavy and noisy inputs.
    const result = @call(
        .never_inline,
        zlib.decode,
        .{
            source,
            filtered,
            @as(zlib.DecodeStorage, .{ .workspace = workspace }),
            @as(zlib.DecodeOptions, .{}),
        },
    ) catch return error.InvalidPng;
    if (result.produced != filtered.len) return error.InvalidPng;
}

// One byte span owns both the state and its internal alignment. Releasing it above live filtered
// rows reclaims all padding, including after an unaligned caller prefix. The large state is
// constructed directly at its final address.
fn InflateStorage(comptime Inflate: type) type {
    return struct {
        const Self = @This();
        bytes: []u8,

        fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Self {
            return .{ .bytes = try allocator.alloc(u8, @sizeOf(Inflate) + @alignOf(Inflate) - 1) };
        }

        fn state(self: Self) *Inflate {
            const address = std.mem.alignForward(
                usize,
                @intFromPtr(self.bytes.ptr),
                @alignOf(Inflate),
            );
            return @ptrFromInt(address);
        }

        fn deinit(self: Self, allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
        }
    };
}

fn checkedAdd(a: usize, b: usize) error{Overflow}!usize {
    return std.math.add(usize, a, b);
}

fn checkedMul(a: usize, b: usize) error{Overflow}!usize {
    return std.math.mul(usize, a, b);
}

fn readU32Big(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

const testing_samples = png_raster_vectors.samples;

test "PNG bounded RGBA8 replay completes empty blocks after exact filtered output" {
    // Frozen IDAT bytes have fixed Huffman data, two empty stored blocks and an Adler footer. zlib
    // 1.3.2 and Pillow 12.3.0 independently accept the split stream and literal pixel.
    const source = &[_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
        0x89, 0x00, 0x00, 0x00, 0x07, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9c, 0x62, 0xe4, 0xb5, 0xc9, 0x9e,
        0x88, 0x80, 0x8f, 0xad, 0x00, 0x00, 0x00, 0x07,
        0x49, 0x44, 0x41, 0x54, 0x05, 0x00, 0x00, 0x00,
        0xff, 0xff, 0x01, 0x41, 0xd5, 0x0d, 0x8a, 0x00,
        0x00, 0x00, 0x07, 0x49, 0x44, 0x41, 0x54, 0x00,
        0x00, 0xff, 0xff, 0x02, 0x62, 0x01, 0x7e, 0x7f,
        0xf7, 0x84, 0x00, 0x00, 0x00, 0x01, 0x49, 0x44,
        0x41, 0x54, 0x50, 0x43, 0x53, 0x2c, 0x1c, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
        0x42, 0x60, 0x82,
    };
    const rgb = &[_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xde, 0x00, 0x00, 0x00, 0x07, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9c, 0x62, 0x10, 0x54, 0x32, 0x06,
        0x20, 0x38, 0x97, 0xca, 0x00, 0x00, 0x00, 0x07,
        0x49, 0x44, 0x41, 0x54, 0x00, 0x00, 0x00, 0xff,
        0xff, 0x01, 0x00, 0x30, 0xd0, 0xd8, 0x79, 0x00,
        0x00, 0x00, 0x07, 0x49, 0x44, 0x41, 0x54, 0x00,
        0xff, 0xff, 0x00, 0xae, 0x00, 0x67, 0x67, 0xc6,
        0x33, 0xf5, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    // Independent zlib bytes inflate to the same filter/pixel followed by an extra byte.
    const excess = &[_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
        0x89, 0x00, 0x00, 0x00, 0x07, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x01, 0x63, 0xe4, 0xb5, 0xc9, 0x9e,
        0x14, 0x18, 0xa3, 0x80, 0x00, 0x00, 0x00, 0x07,
        0x49, 0x44, 0x41, 0x54, 0xc5, 0x0e, 0x00, 0x03,
        0xb9, 0x01, 0x57, 0xd9, 0x57, 0x95, 0x1f, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
        0x42, 0x60, 0x82,
    };
    var wrong_adler = source.*;
    wrong_adler[98] = 'Q';
    // Independent replacement chunk CRC.
    @memcpy(wrong_adler[99..103], &[_]u8{ 0x34, 0x54, 0x1c, 0x8a });

    const backing = try std.testing.allocator.alloc(u8, 128 * 1024 + 2);
    defer std.testing.allocator.free(backing);
    @memset(backing, 0xa5);
    var fixed: std.heap.FixedBufferAllocator = .init(backing[1 .. backing.len - 1]);
    @memset(try fixed.allocator().alloc(u8, 17), 0x3c);
    var tracked = std.testing.FailingAllocator.init(fixed.allocator(), .{ .resize_fail_index = 0 });
    const allocator = tracked.allocator();
    for ([_]bool{ false, true }) |explicit_scratch| {
        const options: Options = .{
            .limits = .{
                .maximum_pixels = 1,
                .maximum_output_bytes = 4,
                .maximum_metadata_bytes = 0,
                .maximum_work_units = 135,
                .maximum_scratch_bytes = 128 * 1024,
            },
        };
        for (
            [_]struct {
                bytes: []const u8,
                rgba: [4]u8,
            }{
                .{ .bytes = source, .rgba = .{ 13, 60, 107, 154 } },
                .{ .bytes = rgb, .rgba = .{ 17, 34, 51, 255 } },
            },
        ) |control| {
            for (0..2) |_| {
                var decoded = try decodeByteAlloc(
                    allocator,
                    if (explicit_scratch) allocator else null,
                    control.bytes,
                    options,
                );
                try std.testing.expectEqualSlices(u8, &control.rgba, decoded.texels);
                decoded.deinit(allocator);
                try std.testing.expectEqual(17, fixed.end_index);
            }
        }
        for ([_][]const u8{ &wrong_adler, excess }) |invalid| {
            // Framing/CRC remain valid.
            _ = try SourceImage.open(invalid, .{ .maximum_source_extent = 1 });
            try std.testing.expectError(
                error.InvalidPng,
                decodeByteAlloc(
                    allocator,
                    if (explicit_scratch) allocator else null,
                    invalid,
                    options,
                ),
            );
            try std.testing.expectEqual(17, fixed.end_index);
        }
    }
    try std.testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
    for (backing[1..18]) |byte| try std.testing.expectEqual(0x3c, byte);
    try std.testing.expectEqual(0xa5, backing[0]);
    try std.testing.expectEqual(0xa5, backing[backing.len - 1]);
}

fn expectEquivalentPngFixtures(
    sequential_encoded: []const u8,
    interlaced_encoded: []const u8,
) !void {
    const sequential_source = try std.testing.allocator.dupe(u8, sequential_encoded);
    defer std.testing.allocator.free(sequential_source);
    const interlaced_source = try std.testing.allocator.dupe(u8, interlaced_encoded);
    defer std.testing.allocator.free(interlaced_source);

    var sequential = try rgbaAlloc(u8, std.testing.allocator, sequential_source, .{});
    defer sequential.deinit(std.testing.allocator);
    var interlaced = try rgbaAlloc(u8, std.testing.allocator, interlaced_source, .{});
    defer interlaced.deinit(std.testing.allocator);
    try std.testing.expectEqual(sequential.width, interlaced.width);
    try std.testing.expectEqual(sequential.height, interlaced.height);
    try std.testing.expectEqualSlices(u8, sequential.texels, interlaced.texels);
}

fn expectDecodedPngFixture(
    encoded: []const u8,
    expected_width: usize,
    expected_height: usize,
    expected_texels: []const u8,
) !void {
    const source = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(source);

    var image = try rgbaAlloc(u8, std.testing.allocator, source, .{});
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected_width, image.width);
    try std.testing.expectEqual(expected_height, image.height);
    try std.testing.expectEqualSlices(u8, expected_texels, image.texels);
}

fn expectSuggestedPaletteIgnored(encoded: []const u8) !void {
    const source = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(source);
    const with_palette = try insertChunk(
        std.testing.allocator,
        source,
        8 + 25,
        "PLTE",
        &.{ 1, 2, 3, 4, 5, 6 },
    );
    defer std.testing.allocator.free(with_palette);

    var expected = try rgbaAlloc(u8, std.testing.allocator, source, .{});
    defer expected.deinit(std.testing.allocator);
    var actual = try rgbaAlloc(u8, std.testing.allocator, with_palette, .{});
    defer actual.deinit(std.testing.allocator);

    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
    try std.testing.expectEqualSlices(u8, expected.texels, actual.texels);
}

fn insertChunk(
    allocator: std.mem.Allocator,
    source: []const u8,
    offset: usize,
    chunk_type: []const u8,
    data: []const u8,
) ![]u8 {
    if (chunk_type.len != 4 or offset > source.len or data.len > std.math.maxInt(
        u32,
    )) return error.InvalidPng;
    const chunk_length = 12 + data.len;
    const result = try allocator.alloc(u8, source.len + chunk_length);
    errdefer allocator.free(result);
    @memcpy(result[0..offset], source[0..offset]);
    var next_offset = offset;
    writeTestChunk(result, &next_offset, chunk_type, data);
    @memcpy(result[next_offset..], source[offset..]);
    return result;
}

fn writeTestChunk(
    destination: []u8,
    offset: *usize,
    chunk_type: []const u8,
    data: []const u8,
) void {
    std.mem.writeInt(u32, destination[offset.*..][0..4], @intCast(data.len), .big);
    @memcpy(destination[offset.* + 4 ..][0..4], chunk_type);
    @memcpy(destination[offset.* + 8 ..][0..data.len], data);
    var crc = std.hash.Crc32.init();
    crc.update(destination[offset.* + 4 ..][0 .. 4 + data.len]);
    std.mem.writeInt(u32, destination[offset.* + 8 + data.len ..][0..4], crc.final(), .big);
    offset.* += 12 + data.len;
}

fn refreshTestChunkCrc(source: []u8, offset: usize) void {
    const data_length: usize = readU32Big(source, offset);
    const crc_offset = offset + 8 + data_length;
    const crc = std.hash.Crc32.hash(source[offset + 4 .. crc_offset]);
    std.mem.writeInt(u32, source[crc_offset..][0..4], crc, .big);
}

fn decodeWithFailingAllocator(allocator: std.mem.Allocator, source: []const u8) !void {
    // Failure sweeps need stable allocation points. A backing remap can depend on recycled pages;
    // moved and refused remaps have separate lifecycle checks.
    var vtable = allocator.vtable.*;
    vtable.resize = std.mem.Allocator.noResize;
    vtable.remap = std.mem.Allocator.noRemap;
    const authority: std.mem.Allocator = .{ .ptr = allocator.ptr, .vtable = &vtable };
    var image = try rgbaAlloc(u8, authority, source, .{});
    defer image.deinit(authority);
}

test "owned PNG results retain stored layout for byte and word output" {
    const cases = [_]struct {
        source: []const u8,
        depth: u8,
        color: u8,
    }{
        .{ .source = testing_samples.grayscale_1_fixture, .depth = 1, .color = 0 },
        .{ .source = testing_samples.palette_4_fixture, .depth = 4, .color = 3 },
        .{ .source = testing_samples.rgb_fixture, .depth = 8, .color = 2 },
        .{ .source = testing_samples.rgba_filters_fixture, .depth = 8, .color = 6 },
        .{ .source = testing_samples.grayscale_alpha_16_fixture, .depth = 16, .color = 4 },
        .{ .source = testing_samples.rgba_16_fixture, .depth = 16, .color = 6 },
    };
    const allocator = std.testing.allocator;
    for (cases) |case| {
        inline for (.{ u8, u16 }) |Sample| {
            for ([_]bool{ false, true }) |explicit_scratch| {
                var image = if (explicit_scratch) try rgbaAllocWithScratch(
                    Sample,
                    allocator,
                    allocator,
                    case.source,
                    .{},
                ) else try rgbaAlloc(Sample, allocator, case.source, .{});
                defer image.deinit(allocator);
                try std.testing.expectEqual(case.depth, image.encoded_bit_depth);
                try std.testing.expectEqual(case.color, image.encoded_color_type);
            }
        }
    }
}

test "decoder reconstructs every PNG filter and preserves RGBA" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgba_filters_fixture);
    defer std.testing.allocator.free(source);

    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    var image = try rgbaAllocWithScratch(
        u8,
        std.testing.allocator,
        scratch.allocator(),
        source,
        .{},
    );
    defer image.deinit(std.testing.allocator);

    const expected = [_]u8{
        11,  48,  85,  122, 159, 196, 233, 14,  51,  88,  125, 162, 199, 236, 17,  54,  91,  128,
        165, 202, 239, 20,  57,  94,  131, 168, 205, 242, 23,  60,  97,  134, 171, 208, 245, 26,
        63,  100, 137, 174, 211, 248, 29,  66,  103, 140, 177, 214, 251, 32,  69,  106, 143, 180,
        217, 254, 35,  72,  109, 146,
    };
    try std.testing.expectEqual(3, image.width);
    try std.testing.expectEqual(5, image.height);
    try std.testing.expectEqualSlices(u8, &expected, image.texels);
}

test "decoder scatters Adam7 RGB passes into row-major RGBA" {
    try expectEquivalentPngFixtures(
        testing_samples.rgb_adam7_sequential_fixture,
        testing_samples.rgb_adam7_fixture,
    );
}

test "decoder scatters Adam7 indexed passes into row-major RGBA" {
    try expectEquivalentPngFixtures(
        testing_samples.indexed_adam7_sequential_fixture,
        testing_samples.indexed_adam7_fixture,
    );
}

test "decoder scatters Adam7 16-bit RGBA passes into row-major RGBA" {
    try expectEquivalentPngFixtures(
        testing_samples.rgba_16_adam7_sequential_fixture,
        testing_samples.rgba_16_adam7_fixture,
    );
}

test "decoder handles empty Adam7 reduced images" {
    try expectEquivalentPngFixtures(
        testing_samples.tiny_sequential_fixture,
        testing_samples.tiny_adam7_fixture,
    );
}

test "decoder expands RGB to opaque RGBA" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgb_fixture);
    defer std.testing.allocator.free(source);

    var image = try rgbaAlloc(u8, std.testing.allocator, source, .{});
    defer image.deinit(std.testing.allocator);

    const expected = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 20, 40, 60, 255 };
    try std.testing.expectEqual(2, image.width);
    try std.testing.expectEqual(2, image.height);
    try std.testing.expectEqualSlices(u8, &expected, image.texels);
}

test "decoder accepts suggested palettes on truecolor images" {
    try expectSuggestedPaletteIgnored(testing_samples.rgb_fixture);
    try expectSuggestedPaletteIgnored(testing_samples.rgba_filters_fixture);
}

test "decoder requires truecolor transparency after a suggested palette" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgb_fixture);
    defer std.testing.allocator.free(source);
    // The eight-byte signature and 25-byte IHDR chunk precede optional chunks.
    const after_header = 8 + 25;
    const palette_bytes = &[_]u8{ 1, 2, 3, 4, 5, 6 };
    const transparency_bytes = &[_]u8{ 0, 0, 0, 0, 0, 0 };

    const with_palette = try insertChunk(
        std.testing.allocator,
        source,
        after_header,
        "PLTE",
        palette_bytes,
    );
    defer std.testing.allocator.free(with_palette);
    const valid = try insertChunk(
        std.testing.allocator,
        with_palette,
        after_header + 12 + palette_bytes.len,
        "tRNS",
        transparency_bytes,
    );
    defer std.testing.allocator.free(valid);
    var image = try rgbaAlloc(u8, std.testing.allocator, valid, .{});
    defer image.deinit(std.testing.allocator);

    const with_transparency = try insertChunk(
        std.testing.allocator,
        source,
        after_header,
        "tRNS",
        transparency_bytes,
    );
    defer std.testing.allocator.free(with_transparency);
    const invalid = try insertChunk(
        std.testing.allocator,
        with_transparency,
        after_header + 12 + transparency_bytes.len,
        "PLTE",
        palette_bytes,
    );
    defer std.testing.allocator.free(invalid);
    if (rgbaAlloc(u8, std.testing.allocator, invalid, .{})) |decoded| {
        var unexpected = decoded;
        unexpected.deinit(std.testing.allocator);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.InvalidPng, err);
    }
}

test "decoder expands grayscale to opaque RGBA" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.grayscale_fixture);
    defer std.testing.allocator.free(source);

    var image = try rgbaAlloc(u8, std.testing.allocator, source, .{});
    defer image.deinit(std.testing.allocator);

    const expected = [_]u8{ 0, 0, 0, 255, 85, 85, 85, 255, 170, 170, 170, 255, 255, 255, 255, 255 };
    try std.testing.expectEqual(2, image.width);
    try std.testing.expectEqual(2, image.height);
    try std.testing.expectEqualSlices(u8, &expected, image.texels);
}

test "decoder expands one-bit grayscale samples" {
    try expectDecodedPngFixture(
        testing_samples.grayscale_1_fixture,
        9,
        2,
        &.{
            0,   0,   0,   255, 255, 255, 255, 0,   0,   0,   0,   255, 255, 255, 255, 0,   255,
            255, 255, 0,   0,   0,   0,   255, 255, 255, 255, 0,   0,   0,   0,   255, 255, 255,
            255, 0,   255, 255, 255, 0,   255, 255, 255, 0,   255, 255, 255, 0,   0,   0,   0,
            255, 0,   0,   0,   255, 255, 255, 255, 0,   0,   0,   0,   255, 0,   0,   0,   255,
            0,   0,   0,   255,
        },
    );
}

test "decoder expands two-bit grayscale samples" {
    try expectDecodedPngFixture(
        testing_samples.grayscale_2_fixture,
        5,
        2,
        &.{
            0,   0,   0,   255, 85,  85,  85,  255, 170, 170, 170, 0,  255, 255, 255, 255, 170, 170,
            170, 0,   255, 255, 255, 255, 170, 170, 170, 0,   85,  85, 85,  255, 0,   0,   0,   255,
            255, 255, 255, 255,
        },
    );
}

test "decoder expands four-bit grayscale Adam7 samples" {
    try expectDecodedPngFixture(
        testing_samples.grayscale_4_adam7_fixture,
        5,
        3,
        &.{
            0,   0,   0,   255, 17,  17,  17,  255, 34,  34,  34,  255, 51,  51,  51,  255, 68,
            68,  68,  255, 85,  85,  85,  255, 102, 102, 102, 255, 119, 119, 119, 255, 136, 136,
            136, 255, 153, 153, 153, 255, 170, 170, 170, 255, 187, 187, 187, 255, 204, 204, 204,
            255, 221, 221, 221, 255, 255, 255, 255, 0,
        },
    );
}

test "decoder preserves grayscale alpha in RGBA" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.grayscale_alpha_fixture);
    defer std.testing.allocator.free(source);

    var image = try rgbaAlloc(u8, std.testing.allocator, source, .{});
    defer image.deinit(std.testing.allocator);

    const expected = [_]u8{ 0, 0, 0, 0, 85, 85, 85, 64, 170, 170, 170, 128, 255, 255, 255, 255 };
    try std.testing.expectEqual(2, image.width);
    try std.testing.expectEqual(2, image.height);
    try std.testing.expectEqualSlices(u8, &expected, image.texels);
}

test "decoder reduces 16-bit color types into RGBA8" {
    const rgba_source = try std.testing.allocator.dupe(u8, testing_samples.rgba_16_fixture);
    defer std.testing.allocator.free(rgba_source);

    var rgba_image = try rgbaAlloc(u8, std.testing.allocator, rgba_source, .{});
    defer rgba_image.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x12, 0x56, 0x9a, 0xde, 0xff, 0x01, 0x03, 0x05 },
        rgba_image.texels,
    );

    const grayscale_source = try std.testing.allocator.dupe(
        u8,
        testing_samples.grayscale_16_fixture,
    );
    defer std.testing.allocator.free(grayscale_source);
    const grayscale_transparency = try insertChunk(
        std.testing.allocator,
        grayscale_source,
        8 + 25,
        "tRNS",
        &.{ 0x12, 0x34 },
    );
    defer std.testing.allocator.free(grayscale_transparency);

    var grayscale_image = try rgbaAlloc(u8, std.testing.allocator, grayscale_transparency, .{});
    defer grayscale_image.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x12, 0x12, 0x12, 0, 0x56, 0x56, 0x56, 255 },
        grayscale_image.texels,
    );

    const rgb_source = try std.testing.allocator.dupe(u8, testing_samples.rgb_16_fixture);
    defer std.testing.allocator.free(rgb_source);
    const rgb_transparency = try insertChunk(
        std.testing.allocator,
        rgb_source,
        8 + 25,
        "tRNS",
        &.{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc },
    );
    defer std.testing.allocator.free(rgb_transparency);

    var rgb_image = try rgbaAlloc(u8, std.testing.allocator, rgb_transparency, .{});
    defer rgb_image.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x12, 0x56, 0x9a, 0, 0xff, 0x01, 0x03, 255 },
        rgb_image.texels,
    );

    const grayscale_alpha_source = try std.testing.allocator.dupe(
        u8,
        testing_samples.grayscale_alpha_16_fixture,
    );
    defer std.testing.allocator.free(grayscale_alpha_source);

    var grayscale_alpha_image = try rgbaAlloc(
        u8,
        std.testing.allocator,
        grayscale_alpha_source,
        .{},
    );
    defer grayscale_alpha_image.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x12, 0x12, 0x12, 0x34, 0x56, 0x56, 0x56, 0x78 },
        grayscale_alpha_image.texels,
    );
}

test "decoder expands one-bit indexed color" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.palette_1_fixture);
    defer std.testing.allocator.free(source);

    var image = try rgbaAlloc(u8, std.testing.allocator, source, .{});
    defer image.deinit(std.testing.allocator);

    const expected = [_]u8{
        0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255,
    };
    try std.testing.expectEqual(4, image.width);
    try std.testing.expectEqual(2, image.height);
    try std.testing.expectEqualSlices(u8, &expected, image.texels);
}

test "decoder expands two-bit indexed color" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.palette_2_fixture);
    defer std.testing.allocator.free(source);

    var image = try rgbaAlloc(u8, std.testing.allocator, source, .{});
    defer image.deinit(std.testing.allocator);

    const expected = [_]u8{
        191, 85, 170, 255, 0, 224, 0, 255, 0, 0,   0, 255, 191, 85, 170, 255, 0, 0, 0, 255,
        191, 85, 170, 255, 0, 0,   0, 255, 0, 224, 0, 255,
    };
    try std.testing.expectEqual(4, image.width);
    try std.testing.expectEqual(2, image.height);
    try std.testing.expectEqualSlices(u8, &expected, image.texels);
}

test "decoder expands four-bit indexed color" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.palette_4_fixture);
    defer std.testing.allocator.free(source);

    var image = try rgbaAlloc(u8, std.testing.allocator, source, .{});
    defer image.deinit(std.testing.allocator);

    const expected = [_]u8{
        255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255, 255, 255, 255, 255,
    };
    try std.testing.expectEqual(5, image.width);
    try std.testing.expectEqual(1, image.height);
    try std.testing.expectEqualSlices(u8, &expected, image.texels);
}

test "decoder expands eight-bit indexed color" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.palette_8_fixture);
    defer std.testing.allocator.free(source);

    var image = try rgbaAlloc(u8, std.testing.allocator, source, .{});
    defer image.deinit(std.testing.allocator);

    const expected = [_]u8{ 255, 0, 0, 255, 128, 128, 128, 255, 0, 0, 255, 255 };
    try std.testing.expectEqual(3, image.width);
    try std.testing.expectEqual(1, image.height);
    try std.testing.expectEqualSlices(u8, &expected, image.texels);
}

test "decoder applies indexed transparency and defaults remaining entries opaque" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.palette_2_fixture);
    defer std.testing.allocator.free(source);

    const transparency_data = [_]u8{ 0, 128 };
    const transparency_chunk = try std.testing.allocator.alloc(u8, 12 + transparency_data.len);
    defer std.testing.allocator.free(transparency_chunk);
    std.mem.writeInt(u32, transparency_chunk[0..4], transparency_data.len, .big);
    @memcpy(transparency_chunk[4..8], "tRNS");
    @memcpy(transparency_chunk[8 .. 8 + transparency_data.len], &transparency_data);
    var crc = std.hash.Crc32.init();
    crc.update(transparency_chunk[4 .. 8 + transparency_data.len]);
    std.mem.writeInt(
        u32,
        transparency_chunk[8 + transparency_data.len ..][0..4],
        crc.final(),
        .big,
    );

    // The fixture has an IHDR chunk followed by its three-entry PLTE chunk.
    const idat_offset = 8 + 25 + 12 + 9;
    const with_transparency = try std.testing.allocator.alloc(
        u8,
        source.len + transparency_chunk.len,
    );
    defer std.testing.allocator.free(with_transparency);
    @memcpy(with_transparency[0..idat_offset], source[0..idat_offset]);
    @memcpy(
        with_transparency[idat_offset .. idat_offset + transparency_chunk.len],
        transparency_chunk,
    );
    @memcpy(with_transparency[idat_offset + transparency_chunk.len ..], source[idat_offset..]);

    var image = try rgbaAlloc(u8, std.testing.allocator, with_transparency, .{});
    defer image.deinit(std.testing.allocator);

    const expected = [_]u8{
        191, 85,  170, 128, 0, 224, 0, 255, 0, 0,   0, 0, 191, 85, 170, 128, 0, 0, 0, 0, 191, 85,
        170, 128, 0,   0,   0, 0,   0, 224, 0, 255,
    };
    try std.testing.expectEqual(4, image.width);
    try std.testing.expectEqual(2, image.height);
    try std.testing.expectEqualSlices(u8, &expected, image.texels);
}

test "decoder accepts an empty indexed transparency table" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.palette_2_fixture);
    defer std.testing.allocator.free(source);

    const with_empty_transparency = try insertChunk(
        std.testing.allocator,
        source,
        8 + 25 + 12 + 9,
        "tRNS",
        &.{},
    );
    defer std.testing.allocator.free(with_empty_transparency);

    var image = try rgbaAlloc(u8, std.testing.allocator, with_empty_transparency, .{});
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(
        u8,
        &.{
            191, 85, 170, 255, 0, 224, 0, 255, 0, 0,   0, 255, 191, 85, 170, 255, 0, 0, 0, 255,
            191, 85, 170, 255, 0, 0,   0, 255, 0, 224, 0, 255,
        },
        image.texels,
    );
}

test "decoder applies grayscale and truecolor transparency" {
    const grayscale_source = try std.testing.allocator.dupe(u8, testing_samples.grayscale_fixture);
    defer std.testing.allocator.free(grayscale_source);
    const grayscale_transparency = try insertChunk(
        std.testing.allocator,
        grayscale_source,
        8 + 25,
        "tRNS",
        &.{ 0, 0x55 },
    );
    defer std.testing.allocator.free(grayscale_transparency);

    var grayscale_image = try rgbaAlloc(u8, std.testing.allocator, grayscale_transparency, .{});
    defer grayscale_image.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 0, 255, 85, 85, 85, 0, 170, 170, 170, 255, 255, 255, 255, 255 },
        grayscale_image.texels,
    );

    const rgb_source = try std.testing.allocator.dupe(u8, testing_samples.rgb_fixture);
    defer std.testing.allocator.free(rgb_source);
    const rgb_transparency = try insertChunk(
        std.testing.allocator,
        rgb_source,
        8 + 25,
        "tRNS",
        &.{ 0, 0, 0, 0xff, 0, 0 },
    );
    defer std.testing.allocator.free(rgb_transparency);

    var rgb_image = try rgbaAlloc(u8, std.testing.allocator, rgb_transparency, .{});
    defer rgb_image.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 255, 255, 20, 40, 60, 255 },
        rgb_image.texels,
    );
}

// Independent stored-block PNG rows and exact transparency expansion facts. Each stream has a None
// filter, one row of three pixels, and an RFC 1950 Adler checksum. The keys differ only in unused
// upper bits; their stored-depth code is one.

const transparency_fixtures = struct {
    /// Grayscale depths, encoded keys, filtered streams and complete expected RGBA rows.
    pub const grayscale = [_]struct {
        depth: u8,
        keys: [3]u16,
        stream: []const u8,
        rgba8: [12]u8,
        rgba16: [12]u16,
    }{
        .{
            .depth = 1,
            .keys = .{ 0x0001, 0x0003, 0xffff },
            // Packed samples 0, 1, 0; Adler sums s1=65, s2=66.
            .stream = &.{ 0x78, 0x01, 0x01, 0x02, 0x00, 0xfd, 0xff, 0, 0x40, 0, 0x42, 0, 0x41 },
            .rgba8 = .{ 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 0, 255 },
            .rgba16 = .{ 0, 0, 0, 65535, 65535, 65535, 65535, 0, 0, 0, 0, 65535 },
        },
        .{
            .depth = 2,
            .keys = .{ 0x0001, 0x0005, 0xfffd },
            // Packed samples 0, 1, 2; Adler sums s1=25, s2=26.
            .stream = &.{ 0x78, 0x01, 0x01, 0x02, 0x00, 0xfd, 0xff, 0, 0x18, 0, 0x1a, 0, 0x19 },
            .rgba8 = .{ 0, 0, 0, 255, 85, 85, 85, 0, 170, 170, 170, 255 },
            .rgba16 = .{ 0, 0, 0, 65535, 21845, 21845, 21845, 0, 43690, 43690, 43690, 65535 },
        },
        .{
            .depth = 4,
            .keys = .{ 0x0001, 0x0011, 0xfff1 },
            // Packed samples 0, 1, 2; Adler sums s1=34, s2=37.
            .stream = &.{
                0x78, 0x01, 0x01, 0x03, 0x00, 0xfc, 0xff, 0, 0x01, 0x20, 0, 0x25, 0, 0x22,
            },
            .rgba8 = .{ 0, 0, 0, 255, 17, 17, 17, 0, 34, 34, 34, 255 },
            .rgba16 = .{ 0, 0, 0, 65535, 4369, 4369, 4369, 0, 8738, 8738, 8738, 65535 },
        },
        .{
            .depth = 8,
            .keys = .{ 0x0001, 0x0101, 0xff01 },
            // Samples 0, 1, 2; Adler sums s1=4, s2=8.
            .stream = &.{ 0x78, 0x01, 0x01, 0x04, 0x00, 0xfb, 0xff, 0, 0, 1, 2, 0, 0x08, 0, 0x04 },
            .rgba8 = .{ 0, 0, 0, 255, 1, 1, 1, 0, 2, 2, 2, 255 },
            .rgba16 = .{ 0, 0, 0, 65535, 257, 257, 257, 0, 514, 514, 514, 65535 },
        },
    };

    /// Truecolor transparency keys with each channel's unused bits varied independently.
    pub const rgb_keys = [_][3]u16{
        .{ 0x0001, 0x0002, 0x0003 },
        .{ 0x0101, 0x0002, 0x0003 },
        .{ 0x0001, 0x0102, 0x0003 },
        .{ 0x0001, 0x0002, 0x0103 },
        .{ 0xff01, 0xaa02, 0x5503 },
    };

    /// Pixels (1,2,3), (1,2,4), (2,2,3); Adler sums s1=21, s2=101.
    pub const rgb_stream = [_]u8{
        0x78, 0x01, 0x01, 0x0a, 0x00, 0xf5, 0xff, 0, 1, 2, 3, 1, 2, 4, 2, 2, 3, 0, 0x65, 0, 0x15,
    };

    /// Only the first pixel matches all three significant transparency codes.
    pub const rgb_rgba8 = [_]u8{ 1, 2, 3, 0, 1, 2, 4, 255, 2, 2, 3, 255 };

    /// The same native-word row, with exact byte-to-word expansion.
    pub const rgb_rgba16 = [_]u16{ 257, 514, 771, 0, 257, 514, 1028, 65535, 514, 514, 771, 65535 };
};

test "decoder ignores unused grayscale transparency bits" {
    const facts = transparency_fixtures;
    for (facts.grayscale) |case| {
        const header = [_]u8{ 0, 0, 0, 3, 0, 0, 0, 1, case.depth, 0, 0, 0, 0 };
        for (case.keys) |key| {
            var bytes: [128]u8 = undefined;
            @memcpy(bytes[0..8], &[_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a });
            var offset: usize = 8;
            writeTestChunk(&bytes, &offset, "IHDR", &header);
            var transparency: [2]u8 = undefined;
            std.mem.writeInt(u16, &transparency, key, .big);
            writeTestChunk(&bytes, &offset, "tRNS", &transparency);
            writeTestChunk(&bytes, &offset, "IDAT", case.stream);
            writeTestChunk(&bytes, &offset, "IEND", &.{});
            const source = bytes[0..offset];

            const admitted = try SourceImage.open(source, .{ .maximum_source_extent = 3 });
            try std.testing.expectEqual(1, admitted.transparent_gray.?);
            var narrow = try rgbaAlloc(u8, std.testing.allocator, source, .{});
            defer narrow.deinit(std.testing.allocator);
            try std.testing.expectEqualSlices(u8, &case.rgba8, narrow.texels);
            var wide = try rgbaAlloc(u16, std.testing.allocator, source, .{});
            defer wide.deinit(std.testing.allocator);
            try std.testing.expectEqualSlices(u16, &case.rgba16, wide.texels);
            var reserved_bytes: [14]u8 = @splat(0xa5);
            var reserved_words: [14]u16 = @splat(0xa55a);
            try decodeImageIntoTransactional(
                u8,
                admitted,
                &reserved_bytes,
                .{ .scratch_allocator = std.testing.allocator },
            );
            try decodeImageIntoTransactional(
                u16,
                admitted,
                &reserved_words,
                .{ .scratch_allocator = std.testing.allocator },
            );
            try std.testing.expectEqualSlices(u8, &case.rgba8, reserved_bytes[0..12]);
            try std.testing.expectEqualSlices(u16, &case.rgba16, reserved_words[0..12]);
            try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, reserved_bytes[12..]);
            try std.testing.expectEqualSlices(u16, &.{ 0xa55a, 0xa55a }, reserved_words[12..]);
        }
    }
}

test "decoder ignores unused truecolor transparency bits" {
    const facts = transparency_fixtures;
    const header = [_]u8{ 0, 0, 0, 3, 0, 0, 0, 1, 8, 2, 0, 0, 0 };
    for (facts.rgb_keys) |key| {
        var bytes: [128]u8 = undefined;
        @memcpy(bytes[0..8], &[_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a });
        var offset: usize = 8;
        writeTestChunk(&bytes, &offset, "IHDR", &header);
        var transparency: [6]u8 = undefined;
        for (
            key,
            0..,
        ) |sample, channel| std.mem.writeInt(u16, transparency[channel * 2 ..][0..2], sample, .big);
        writeTestChunk(&bytes, &offset, "tRNS", &transparency);
        writeTestChunk(&bytes, &offset, "IDAT", &facts.rgb_stream);
        writeTestChunk(&bytes, &offset, "IEND", &.{});
        const source = bytes[0..offset];

        const admitted = try SourceImage.open(source, .{ .maximum_source_extent = 3 });
        try std.testing.expectEqual([3]u16{ 1, 2, 3 }, admitted.transparent_rgb.?);
        var narrow = try rgbaAlloc(u8, std.testing.allocator, source, .{});
        defer narrow.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, &facts.rgb_rgba8, narrow.texels);
        var wide = try rgbaAlloc(u16, std.testing.allocator, source, .{});
        defer wide.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u16, &facts.rgb_rgba16, wide.texels);
        var reserved_bytes: [14]u8 = @splat(0xa5);
        var reserved_words: [14]u16 = @splat(0xa55a);
        try decodeImageIntoTransactional(
            u8,
            admitted,
            &reserved_bytes,
            .{ .scratch_allocator = std.testing.allocator },
        );
        try decodeImageIntoTransactional(
            u16,
            admitted,
            &reserved_words,
            .{ .scratch_allocator = std.testing.allocator },
        );
        try std.testing.expectEqualSlices(u8, &facts.rgb_rgba8, reserved_bytes[0..12]);
        try std.testing.expectEqualSlices(u16, &facts.rgb_rgba16, reserved_words[0..12]);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, reserved_bytes[12..]);
        try std.testing.expectEqualSlices(u16, &.{ 0xa55a, 0xa55a }, reserved_words[12..]);
    }
}

test "decoder distinguishes malformed and unsupported PNG input" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgb_fixture);
    defer std.testing.allocator.free(source);

    const invalid_crc = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(invalid_crc);
    invalid_crc[29] ^= 1;
    try std.testing.expectError(
        error.InvalidPng,
        rgbaAlloc(u8, std.testing.allocator, invalid_crc, .{}),
    );

    const unsupported = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(unsupported);
    unsupported[25] = 5;
    var crc = std.hash.Crc32.init();
    crc.update(unsupported[12..29]);
    std.mem.writeInt(u32, unsupported[29..33], crc.final(), .big);
    try std.testing.expectError(
        error.UnsupportedPng,
        rgbaAlloc(u8, std.testing.allocator, unsupported, .{}),
    );

    const unsupported_interlace = try std.testing.allocator.dupe(u8, source);
    defer std.testing.allocator.free(unsupported_interlace);
    unsupported_interlace[28] = 2;
    var interlace_crc = std.hash.Crc32.init();
    interlace_crc.update(unsupported_interlace[12..29]);
    std.mem.writeInt(u32, unsupported_interlace[29..33], interlace_crc.final(), .big);
    try std.testing.expectError(
        error.UnsupportedPng,
        rgbaAlloc(u8, std.testing.allocator, unsupported_interlace, .{}),
    );
}

test "decoder rejects non-letter chunk type names" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgb_fixture);
    defer std.testing.allocator.free(source);

    // The fixture's 25-byte IHDR chunk follows the 8-byte PNG signature.
    const chunk_offset = 8 + 25;
    const with_invalid_name = try std.testing.allocator.alloc(u8, source.len + 12);
    defer std.testing.allocator.free(with_invalid_name);
    @memcpy(with_invalid_name[0..chunk_offset], source[0..chunk_offset]);
    std.mem.writeInt(u32, with_invalid_name[chunk_offset..][0..4], 0, .big);
    @memcpy(with_invalid_name[chunk_offset + 4 ..][0..4], "fOo!");
    var crc = std.hash.Crc32.init();
    crc.update(with_invalid_name[chunk_offset + 4 ..][0..4]);
    std.mem.writeInt(u32, with_invalid_name[chunk_offset + 8 ..][0..4], crc.final(), .big);
    @memcpy(with_invalid_name[chunk_offset + 12 ..], source[chunk_offset..]);

    try std.testing.expectError(
        error.InvalidPng,
        rgbaAlloc(u8, std.testing.allocator, with_invalid_name, .{}),
    );
}

test "decoder ignores unknown ancillary chunks when the reserved bit is set" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgb_fixture);
    defer std.testing.allocator.free(source);

    var expected = try rgbaAlloc(u8, std.testing.allocator, source, .{});
    defer expected.deinit(std.testing.allocator);

    for ([_][]const u8{ "vpAg", "vpag" }) |chunk_type| {
        const with_chunk = try insertChunk(
            std.testing.allocator,
            source,
            8 + 25,
            chunk_type,
            &.{ 0x01, 0x02 },
        );
        defer std.testing.allocator.free(with_chunk);

        var actual = try rgbaAlloc(u8, std.testing.allocator, with_chunk, .{});
        defer actual.deinit(std.testing.allocator);
        try std.testing.expectEqual(expected.width, actual.width);
        try std.testing.expectEqual(expected.height, actual.height);
        try std.testing.expectEqualSlices(u8, expected.texels, actual.texels);
    }
}

test "decoder requires IHDR to be the first chunk" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgb_fixture);
    defer std.testing.allocator.free(source);

    const with_leading_text = try insertChunk(
        std.testing.allocator,
        source,
        8,
        "tEXt",
        "before IHDR",
    );
    defer std.testing.allocator.free(with_leading_text);
    try std.testing.expectError(
        error.InvalidPng,
        rgbaAlloc(u8, std.testing.allocator, with_leading_text, .{}),
    );
}

test "decoder rejects malformed and incompatible transparency chunks" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.grayscale_fixture);
    defer std.testing.allocator.free(source);

    const malformed = try insertChunk(std.testing.allocator, source, 8 + 25, "tRNS", &.{0});
    defer std.testing.allocator.free(malformed);
    try std.testing.expectError(
        error.InvalidPng,
        rgbaAlloc(u8, std.testing.allocator, malformed, .{}),
    );

    const oversized_gray = try insertChunk(
        std.testing.allocator,
        source,
        8 + 25,
        "tRNS",
        &.{ 0x00, 0x01, 0x00 },
    );
    defer std.testing.allocator.free(oversized_gray);
    try std.testing.expectError(
        error.InvalidPng,
        rgbaAlloc(u8, std.testing.allocator, oversized_gray, .{}),
    );

    const alpha_source = try std.testing.allocator.dupe(
        u8,
        testing_samples.grayscale_alpha_fixture,
    );
    defer std.testing.allocator.free(alpha_source);
    const with_alpha = try insertChunk(
        std.testing.allocator,
        alpha_source,
        8 + 25,
        "tRNS",
        &.{ 0, 0 },
    );
    defer std.testing.allocator.free(with_alpha);

    try std.testing.expectError(
        error.InvalidPng,
        rgbaAlloc(u8, std.testing.allocator, with_alpha, .{}),
    );

    const rgb_source = try std.testing.allocator.dupe(u8, testing_samples.rgb_fixture);
    defer std.testing.allocator.free(rgb_source);
    const incomplete_rgb = try insertChunk(
        std.testing.allocator,
        rgb_source,
        8 + 25,
        "tRNS",
        &.{ 0x00, 0x01, 0x00, 0x02, 0x00 },
    );
    defer std.testing.allocator.free(incomplete_rgb);
    try std.testing.expectError(
        error.InvalidPng,
        rgbaAlloc(u8, std.testing.allocator, incomplete_rgb, .{}),
    );
}

test "decoder ignores unused bytes after the IDAT zlib stream" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgb_fixture);
    defer std.testing.allocator.free(source);

    const idat_offset = 8 + 25;
    const idat_data_start = idat_offset + 8;
    const idat_data_end = idat_data_start + readU32Big(source, idat_offset);
    const with_trailing = try std.testing.allocator.alloc(u8, source.len + 1);
    defer std.testing.allocator.free(with_trailing);
    @memcpy(with_trailing[0..idat_data_end], source[0..idat_data_end]);
    std.mem.writeInt(
        u32,
        with_trailing[idat_offset..][0..4],
        readU32Big(source, idat_offset) + 1,
        .big,
    );
    with_trailing[idat_data_end] = 0xa5;
    @memcpy(with_trailing[idat_data_end + 1 ..], source[idat_data_end..]);
    var crc = std.hash.Crc32.init();
    crc.update(with_trailing[idat_offset + 4 .. idat_data_end + 1]);
    std.mem.writeInt(u32, with_trailing[idat_data_end + 1 ..][0..4], crc.final(), .big);

    var image = try rgbaAlloc(u8, std.testing.allocator, with_trailing, .{});
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(2, image.width);
    try std.testing.expectEqual(2, image.height);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 20, 40, 60, 255 },
        image.texels,
    );
}

test "decoder reads one zlib_bytes stream across empty and one-byte IDAT chunks" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgb_fixture);
    defer std.testing.allocator.free(source);

    const idat_offset = 8 + 25;
    const data_start = idat_offset + 8;
    const data_end = data_start + readU32Big(source, idat_offset);
    const after_idat = data_end + 4;
    const zlib_bytes = source[data_start..data_end];
    try std.testing.expect(zlib_bytes.len > 1);

    // Replace one IDAT with an empty chunk, a chunk per compressed byte, and a final empty chunk.
    // This crosses the zlib header, blocks, and checksum.
    const split = try std.testing.allocator.alloc(u8, source.len + (zlib_bytes.len + 1) * 12);
    defer std.testing.allocator.free(split);
    @memcpy(split[0..idat_offset], source[0..idat_offset]);
    var offset: usize = idat_offset;
    writeTestChunk(split, &offset, "IDAT", &.{});
    for (zlib_bytes) |*byte| writeTestChunk(split, &offset, "IDAT", byte[0..1]);
    writeTestChunk(split, &offset, "IDAT", &.{});
    @memcpy(split[offset..], source[after_idat..]);

    var image = try rgbaAlloc(u8, std.testing.allocator, split, .{});
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(2, image.width);
    try std.testing.expectEqual(2, image.height);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 20, 40, 60, 255 },
        image.texels,
    );
}

test "multiple IDAT chunks need scratch only for decoded rows and zlib" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgb_fixture);
    defer std.testing.allocator.free(source);

    const buffers = struct {
        var unused: [Inflater.history_bytes * 2]u8 = @splat(0xa5);
        var scratch: [Inflater.history_bytes + streaming_state_byte_count + 128]u8 = undefined;
    };
    const idat_offset = 8 + 25;
    const data_start = idat_offset + 8;
    const data_end = data_start + readU32Big(source, idat_offset);
    const after_idat = data_end + 4;
    const split = try std.testing.allocator.alloc(u8, source.len + 12 + buffers.unused.len);
    defer std.testing.allocator.free(split);
    @memcpy(split[0..idat_offset], source[0..idat_offset]);
    var offset: usize = idat_offset;
    writeTestChunk(split, &offset, "IDAT", source[data_start..data_end]);
    writeTestChunk(split, &offset, "IDAT", &buffers.unused);
    @memcpy(split[offset..], source[after_idat..]);

    var scratch = std.heap.FixedBufferAllocator.init(&buffers.scratch);
    var image = try rgbaAllocWithScratch(
        u8,
        std.testing.allocator,
        scratch.allocator(),
        split,
        .{},
    );
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(2, image.width);
    try std.testing.expectEqual(2, image.height);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 20, 40, 60, 255 },
        image.texels,
    );
}

test "indexed PNG palettes preserve reusable bounded scratch and borrowed source bytes" {
    const allocator = std.testing.allocator;
    const prefix_bytes = 64;
    const backing = try allocator.alloc(
        u8,
        prefix_bytes + Inflater.history_bytes + streaming_state_byte_count + 4096,
    );
    defer allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    const scratch = fixed.allocator();
    const prefix = try scratch.alloc(u8, prefix_bytes);
    @memset(prefix, 0x5a);

    for (
        [_][]const u8{
            testing_samples.palette_1_fixture,     testing_samples.palette_2_fixture,
            testing_samples.palette_4_fixture,     testing_samples.palette_8_fixture,
            testing_samples.indexed_adam7_fixture,
        },
    ) |encoded| {
        const source = try allocator.dupe(u8, encoded);
        defer allocator.free(source);
        const after_palette = 8 + 25 + 12 + readU32Big(source, 8 + 25);
        const transparent = try insertChunk(allocator, source, after_palette, "tRNS", &.{ 0, 128 });
        defer allocator.free(transparent);
        for ([_][]const u8{ source, transparent }) |input_bytes| {
            const source_hash = std.hash.Wyhash.hash(0, input_bytes);
            for (0..32) |_| {
                var image = try decodeByteAlloc(allocator, scratch, input_bytes, .{});
                defer image.deinit(allocator);
                try std.testing.expectEqual(prefix_bytes, fixed.end_index);
                for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
                try std.testing.expectEqual(source_hash, std.hash.Wyhash.hash(0, input_bytes));
            }
        }
    }
}

test "indexed PNG palette framing is rejected before workspace allocation" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, testing_samples.palette_8_fixture);
    defer allocator.free(source);
    const palette_offset = 8 + 25;
    const after_palette = palette_offset + 12 + readU32Big(source, palette_offset);
    const corrupt = try allocator.dupe(u8, source);
    defer allocator.free(corrupt);
    corrupt[palette_offset + 8] ^= 1;
    const duplicate = try insertChunk(allocator, source, after_palette, "PLTE", &.{ 1, 2, 3 });
    defer allocator.free(duplicate);
    const alpha_overrun = try insertChunk(
        allocator,
        source,
        after_palette,
        "tRNS",
        &.{ 0, 1, 2, 3 },
    );
    defer allocator.free(alpha_overrun);
    const missing_palette = try allocator.alloc(u8, palette_offset + source.len - after_palette);
    defer allocator.free(missing_palette);
    @memcpy(missing_palette[0..palette_offset], source[0..palette_offset]);
    @memcpy(missing_palette[palette_offset..], source[after_palette..]);

    for ([_][]const u8{ corrupt, duplicate, alpha_overrun, missing_palette }) |rejected| {
        try std.testing.expectError(
            error.InvalidPng,
            rgbaAlloc(u8, std.testing.failing_allocator, rejected, .{}),
        );
    }
}

test "indexed PNG allocation failures reclaim bounded scratch and preserve its prefix" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, testing_samples.palette_8_fixture);
    defer allocator.free(source);
    const backing = try allocator.alloc(
        u8,
        64 + Inflater.history_bytes + streaming_state_byte_count + 4096,
    );
    defer allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    const scratch = fixed.allocator();
    const prefix = try scratch.alloc(u8, 64);
    @memset(prefix, 0x5a);

    // Fail validation's window, replay's window, and rows after output construction.
    for (0..3) |fail_index| {
        var failing = std.testing.FailingAllocator.init(scratch, .{ .fail_index = fail_index });
        try std.testing.expectError(
            error.OutOfMemory,
            rgbaAllocWithScratch(u8, allocator, failing.allocator(), source, .{}),
        );
        try std.testing.expectEqual(prefix.len, fixed.end_index);
        for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
    }
    try std.testing.expectError(
        error.OutOfMemory,
        rgbaAllocWithScratch(u8, std.testing.failing_allocator, scratch, source, .{}),
    );
    try std.testing.expectEqual(prefix.len, fixed.end_index);
    for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
}

test "direct inflate storage reclaims scratch with an unaligned retained prefix" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 1, std.math.maxInt(u31) }) |chunk_bytes| {
        var fixture = try TestImage.init(
            allocator,
            .{
                .width = 17,
                .height = 17,
                .filter_pattern = .mixed,
                .compression = .std_default,
                .idat_chunk_bytes = chunk_bytes,
            },
        );
        defer fixture.deinit(allocator);
        const state_bytes: usize = if (chunk_bytes == 1) @sizeOf(
            Inflater,
        ) + @alignOf(
            Inflater,
        ) - 1 else @sizeOf(deflate.DecoderWorkspace) + @alignOf(deflate.DecoderWorkspace) - 1;
        const backing = try allocator.alloc(u8, fixture.filtered.len + state_bytes + 7);
        defer allocator.free(backing);
        var scratch: std.heap.FixedBufferAllocator = .init(backing);
        @memset(try scratch.allocator().alloc(u8, 7), 0x5a);
        for (0..128) |_| {
            var image = try rgbaAlloc(u8, scratch.allocator(), fixture.source, .{});
            try std.testing.expectEqualSlices(u8, fixture.expected, image.texels);
            image.deinit(scratch.allocator());
            try std.testing.expectEqual(7, scratch.end_index);
            try std.testing.expectEqualSlices(u8, &(@as([7]u8, @splat(0x5a))), backing[0..7]);
        }
        // Supplying scratch explicitly selects bounded replay, even for the same handle. This
        // region fits filtered rows/tables but deliberately lacks a window.
        try std.testing.expectError(
            error.OutOfMemory,
            rgbaAllocWithScratch(u8, scratch.allocator(), scratch.allocator(), fixture.source, .{}),
        );
        try std.testing.expectEqual(7, scratch.end_index);
    }
}

test "allocation failures release PNG output and scratch storage" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgba_filters_fixture);
    defer std.testing.allocator.free(source);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeWithFailingAllocator,
        .{source},
    );

    const indexed_source = try std.testing.allocator.dupe(u8, testing_samples.palette_8_fixture);
    defer std.testing.allocator.free(indexed_source);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeWithFailingAllocator,
        .{indexed_source},
    );
}

test "shared PNG storage reclaims temporary rows while output remains owned" {
    for (
        [_][]const u8{
            testing_samples.rgb_fixture,               testing_samples.grayscale_fixture,
            testing_samples.grayscale_1_fixture,       testing_samples.grayscale_2_fixture,
            testing_samples.grayscale_4_adam7_fixture, testing_samples.grayscale_alpha_fixture,
            testing_samples.rgba_16_fixture,           testing_samples.grayscale_16_fixture,
            testing_samples.rgb_16_fixture,            testing_samples.grayscale_alpha_16_fixture,
            testing_samples.rgba_16_adam7_fixture,     testing_samples.palette_1_fixture,
            testing_samples.palette_2_fixture,         testing_samples.palette_4_fixture,
            testing_samples.palette_8_fixture,         testing_samples.rgba_filters_fixture,
            testing_samples.rgb_adam7_fixture,         testing_samples.indexed_adam7_fixture,
            testing_samples.tiny_sequential_fixture,   testing_samples.tiny_adam7_fixture,
        },
    ) |encoded| {
        const source = try std.testing.allocator.dupe(u8, encoded);
        defer std.testing.allocator.free(source);
        var reference = try rgbaAlloc(u8, std.testing.allocator, source, .{});
        defer reference.deinit(std.testing.allocator);
        try expectSharedPngLifetimes(source, reference.texels);
    }
}

test "shared RGBA PNG reconstruction preserves overlapping vector and scalar rows" {
    for ([_]u32{ 1, 3, 17, 63 }) |width| {
        for (std.enums.values(TestImage.FilterPattern)) |mode| {
            var fixture = try TestImage.init(
                std.testing.allocator,
                .{ .width = width, .height = 11, .filter_pattern = mode },
            );
            defer fixture.deinit(std.testing.allocator);
            try expectSharedPngLifetimes(fixture.source, fixture.expected);
        }
    }
    // Cross multiple stored blocks and inflater-window rebases during validation and replay, with
    // independently generated expected pixels.
    var large = try TestImage.init(
        std.testing.allocator,
        .{ .width = 129, .height = 257, .filter_pattern = .mixed },
    );
    defer large.deinit(std.testing.allocator);
    try expectSharedPngLifetimes(large.source, large.expected);
}

fn expectSharedPngLifetimes(source: []const u8, expected: []const u8) !void {
    const prefix_bytes = 64;
    const backing = try std.testing.allocator.alloc(
        u8,
        prefix_bytes + Inflater.history_bytes + streaming_state_byte_count + expected.len * 3 +
            4096,
    );
    defer std.testing.allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    const prefix = try fixed.allocator().alloc(u8, prefix_bytes);
    @memset(prefix, 0x5a);
    const source_hash = std.hash.Wyhash.hash(0, source);

    // Explicit scratch handles may alias output storage. Shared selection and denied remap must
    // also preserve the ordinary decode contract.
    for (0..3) |allocator_mode| {
        var wrapper = std.testing.FailingAllocator.init(
            fixed.allocator(),
            .{ .resize_fail_index = 0 },
        );
        const output = if (allocator_mode == 1) wrapper.allocator() else fixed.allocator();
        const scratch = if (allocator_mode == 0) fixed.allocator() else wrapper.allocator();
        for (0..32) |_| {
            {
                var image = try decodeByteAlloc(
                    output,
                    if (allocator_mode == 0) null else scratch,
                    source,
                    .{},
                );
                defer image.deinit(output);
                try std.testing.expectEqualSlices(u8, expected, image.texels);
                try std.testing.expectEqual(prefix_bytes + expected.len, fixed.end_index);
            }
            try std.testing.expectEqual(prefix_bytes, fixed.end_index);
            for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
            try std.testing.expectEqual(source_hash, std.hash.Wyhash.hash(0, source));
        }
    }
}

test "shared PNG failures unwind above retained caller storage" {
    const backing = try std.testing.allocator.alloc(
        u8,
        64 + Inflater.history_bytes + streaming_state_byte_count + 8192,
    );
    defer std.testing.allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    const prefix = try fixed.allocator().alloc(u8, 64);
    @memset(prefix, 0x5a);
    for (
        [_][]const u8{ testing_samples.palette_8_fixture, testing_samples.rgba_filters_fixture },
    ) |encoded| {
        const source = try std.testing.allocator.dupe(u8, encoded);
        defer std.testing.allocator.free(source);
        for (0..3) |allocator_mode| {
            var completed = false;
            for (0..16) |fail_index| {
                var failing = std.testing.FailingAllocator.init(
                    fixed.allocator(),
                    .{ .fail_index = fail_index, .resize_fail_index = 0 },
                );
                const output = if (allocator_mode == 1) fixed.allocator() else failing.allocator();
                const scratch = if (allocator_mode == 2) fixed.allocator() else failing.allocator();
                if (decodeByteAlloc(
                    output,
                    if (allocator_mode == 0) null else scratch,
                    source,
                    .{},
                )) |decoded| {
                    var image = decoded;
                    image.deinit(output);
                    completed = true;
                } else |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                    try std.testing.expect(failing.has_induced_failure);
                }
                try std.testing.expectEqual(prefix.len, fixed.end_index);
                for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
                if (completed) break;
            }
            try std.testing.expect(completed);
        }
    }

    var fixture = try TestImage.init(
        std.testing.allocator,
        .{ .width = 17, .height = 11, .filter_pattern = .none },
    );
    defer fixture.deinit(std.testing.allocator);
    const idat_offset = 8 + 25;
    const data_start = idat_offset + 8;
    const data_end = data_start + readU32Big(fixture.source, idat_offset);
    // This small fixture has one stored block after its two-byte zlib header.
    fixture.source[data_start + 7] = 5;
    std.mem.writeInt(
        u32,
        fixture.source[data_end - 4 ..][0..4],
        std.hash.Adler32.hash(fixture.source[data_start + 7 .. data_end - 4]),
        .big,
    );
    refreshTestChunkCrc(fixture.source, idat_offset);
    for (0..3) |allocator_mode| {
        var wrapper = std.testing.FailingAllocator.init(
            fixed.allocator(),
            .{ .resize_fail_index = 0 },
        );
        try std.testing.expectError(
            error.InvalidPng,
            decodeByteAlloc(
                if (allocator_mode == 1) wrapper.allocator() else fixed.allocator(),
                if (allocator_mode == 0) null else wrapper.allocator(),
                fixture.source,
                .{},
            ),
        );
        try std.testing.expectEqual(prefix.len, fixed.end_index);
        for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
    }
}

test "RGBA PNG output follows a relocating allocator remap" {
    var fixture = try TestImage.init(
        std.testing.allocator,
        .{ .width = 17, .height = 11, .filter_pattern = .mixed },
    );
    defer fixture.deinit(std.testing.allocator);
    var moving = MovingPngAllocator{ .backing = std.testing.allocator };
    const allocator = moving.allocator();
    var image = try rgbaAlloc(u8, allocator, fixture.source, .{});
    defer image.deinit(allocator);
    try std.testing.expectEqual(1, moving.moves);
    try std.testing.expectEqual(moving.remapped_pointer.?, image.texels.ptr);
    try std.testing.expectEqualSlices(u8, fixture.expected, image.texels);
}

// Test-only allocator whose successful remap always moves before freeing the original allocation.
// The testing allocator checks exact cleanup lengths.
const MovingPngAllocator = struct {
    backing: std.mem.Allocator,
    moves: usize = 0,
    remapped_pointer: ?[*]u8 = null,
    calls: usize = 0,
    decline_call: ?usize = null,

    fn allocator(self: *MovingPngAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = std.mem.Allocator.noResize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *MovingPngAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *MovingPngAllocator = @ptrCast(@alignCast(ctx));
        const call = self.calls;
        self.calls += 1;
        if (self.decline_call == call) return null;
        const pointer = self.backing.rawAlloc(new_len, alignment, ra) orelse return null;
        @memcpy(pointer[0..@min(memory.len, new_len)], memory[0..@min(memory.len, new_len)]);
        self.backing.rawFree(memory, alignment, ra);
        self.moves += 1;
        self.remapped_pointer = pointer;
        return pointer;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *MovingPngAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
    }
};

test "Average RGB fusion follows moved storage, bounded replay and filter admission" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, rgb_average.source);
    defer allocator.free(source);
    const saved = try allocator.dupe(u8, source);
    defer allocator.free(saved);
    const admitted = try SourceImage.open(
        source,
        .{ .maximum_source_extent = default_maximum_source_extent },
    );
    var reference = try rgbaAllocWithScratch(u8, allocator, allocator, source, .{});
    defer reference.deinit(allocator);

    const count = admitted.image_data.first.len;
    const chunk_count = std.math.divCeil(usize, count, 13) catch unreachable;
    const split = try allocator.alloc(u8, source.len + (chunk_count + 1) * 12);
    defer allocator.free(split);
    const first = admitted.image_data.first_offset;
    @memcpy(split[0..first], source[0..first]);
    var offset = first;
    writeTestChunk(split, &offset, "IDAT", &.{});
    var position: usize = 0;
    while (position < count) {
        const end = @min(position + 13, count);
        writeTestChunk(split, &offset, "IDAT", admitted.image_data.first[position..end]);
        position = end;
    }
    writeTestChunk(split, &offset, "IDAT", &.{});
    @memcpy(split[offset..], source[admitted.image_data.after_last..]);
    for ([_][]const u8{ source, split }) |encoded| {
        for ([_]?usize{ null, 0 }) |declined| {
            var moving = MovingPngAllocator{ .backing = allocator, .decline_call = declined };
            const authority = moving.allocator();
            var result = try rgbaAlloc(u8, authority, encoded, .{});
            defer result.deinit(authority);
            try std.testing.expectEqualSlices(u8, reference.texels, result.texels);
            try std.testing.expectEqual(1, moving.calls);
            try std.testing.expectEqual(if (declined == null) @as(usize, 1) else 0, moving.moves);
            if (declined == null) try std.testing.expectEqual(
                moving.remapped_pointer.?,
                result.texels.ptr,
            );
        }
        try expectSharedPngLifetimes(encoded, reference.texels);
        try std.testing.checkAllAllocationFailures(
            allocator,
            decodeWithFailingAllocator,
            .{encoded},
        );
    }

    const prefix_bytes = 7;
    const storage = try allocator.alloc(u8, prefix_bytes + reference.texels.len);
    defer allocator.free(storage);
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    @memset(try fixed.allocator().alloc(u8, prefix_bytes), 0x5a);
    for (0..3) |_| {
        var result = try rgbaAlloc(u8, fixed.allocator(), source, .{});
        try std.testing.expectEqualSlices(u8, reference.texels, result.texels);
        try std.testing.expectEqual(prefix_bytes + reference.texels.len, fixed.end_index);
        result.deinit(fixed.allocator());
        try std.testing.expectEqual(prefix_bytes, fixed.end_index);
    }

    // Bad selectors must unwind before final growth, even after an Average prefix. Repair Adler and
    // chunk CRC to reach the filter check through valid framing.
    const filtered_start = first + 8 + 2 + 5;
    const footer_start = filtered_start + admitted.filtered_byte_count;
    const stride = admitted.packed_row_bytes + 1;
    const damaged = try allocator.dupe(u8, source);
    defer allocator.free(damaged);
    for (0..admitted.height) |row| {
        @memcpy(damaged, saved);
        damaged[filtered_start + row * stride] = 5;
        std.mem.writeInt(
            u32,
            damaged[footer_start..][0..4],
            std.hash.Adler32.hash(damaged[filtered_start..footer_start]),
            .big,
        );
        refreshTestChunkCrc(damaged, first);
        var moving = MovingPngAllocator{ .backing = allocator };
        try std.testing.expectError(
            error.InvalidPng,
            rgbaAlloc(u8, moving.allocator(), damaged, .{}),
        );
        try std.testing.expectEqual(0, moving.calls);
        try std.testing.expectError(
            error.InvalidPng,
            rgbaAlloc(u8, fixed.allocator(), damaged, .{}),
        );
        try std.testing.expectEqual(prefix_bytes, fixed.end_index);
    }
    for (storage[0..prefix_bytes]) |byte| try std.testing.expectEqual(0x5a, byte);
    try std.testing.expectEqualSlices(u8, saved, source);
}

test "compressed Average RGB retires a stored prefix and preserves shared lifetimes" {
    const allocator = std.testing.allocator;
    const fixture = rgb_average;
    const source = try allocator.dupe(u8, fixture.wide_source);
    defer allocator.free(source);
    const admitted = try SourceImage.open(
        source,
        .{ .maximum_source_extent = default_maximum_source_extent },
    );
    var reference = try rgbaAllocWithScratch(u8, allocator, allocator, source, .{});
    defer reference.deinit(allocator);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(reference.texels, &hash, .{});
    try std.testing.expectEqualSlices(u8, &fixture.wide_texels_sha256, &hash);

    // Split independently through stored data, dynamic codes, and the footer, with empty IDATs at
    // both ends. The stored probe writes one private row.
    const count = admitted.image_data.first.len;
    const chunk_count = std.math.divCeil(usize, count, 7) catch unreachable;
    const split = try allocator.alloc(u8, source.len + (chunk_count + 1) * 12);
    defer allocator.free(split);
    const first = admitted.image_data.first_offset;
    @memcpy(split[0..first], source[0..first]);
    var offset = first;
    writeTestChunk(split, &offset, "IDAT", &.{});
    var position: usize = 0;
    while (position < count) {
        const end = @min(position + 7, count);
        writeTestChunk(split, &offset, "IDAT", admitted.image_data.first[position..end]);
        position = end;
    }
    writeTestChunk(split, &offset, "IDAT", &.{});
    @memcpy(split[offset..], source[admitted.image_data.after_last..]);

    for ([_][]const u8{ source, split }) |encoded| {
        for ([_]?usize{ null, 0, 1 }) |declined| {
            var moving = MovingPngAllocator{ .backing = allocator, .decline_call = declined };
            const authority = moving.allocator();
            var result = try rgbaAlloc(u8, authority, encoded, .{});
            defer result.deinit(authority);
            try std.testing.expectEqualSlices(u8, reference.texels, result.texels);
            if (declined == null) {
                try std.testing.expectEqual(
                    if (encoded.ptr == split.ptr) @as(usize, 2) else 1,
                    moving.moves,
                );
                try std.testing.expectEqual(moving.remapped_pointer.?, result.texels.ptr);
            }
        }
        try expectSharedPngLifetimes(encoded, reference.texels);
        try std.testing.checkAllAllocationFailures(
            allocator,
            decodeWithFailingAllocator,
            .{encoded},
        );
    }
}

test "RGB storage transfer follows moved and declined split-input remaps" {
    const allocator = std.testing.allocator;
    const rgb = try allocator.dupe(u8, testing_samples.rgb_fixture);
    defer allocator.free(rgb);
    const source = try insertChunk(allocator, rgb, 33, "tRNS", &.{ 0, 0, 0, 255, 0, 0 });
    defer allocator.free(source);
    const admitted = try SourceImage.open(
        source,
        .{ .maximum_source_extent = default_maximum_source_extent },
    );
    const expected = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 255, 255, 20, 40, 60, 255 };
    // Independent chunk framing splits the original zlib at every byte, including header/footer,
    // with empty leading/trailing IDATs and unchanged transparency.
    const count = admitted.image_data.first.len;
    const split = try allocator.alloc(u8, source.len + (count + 1) * 12);
    defer allocator.free(split);
    const first = admitted.image_data.first_offset;
    @memcpy(split[0..first], source[0..first]);
    var offset = first;
    writeTestChunk(split, &offset, "IDAT", &.{});
    for (admitted.image_data.first) |byte| writeTestChunk(split, &offset, "IDAT", &.{byte});
    writeTestChunk(split, &offset, "IDAT", &.{});
    @memcpy(split[offset..], source[admitted.image_data.after_last..]);
    const split_image = try SourceImage.open(
        split,
        .{ .maximum_source_extent = default_maximum_source_extent },
    );
    try std.testing.expectEqual(count, split_image.image_data.byte_count);
    const joined = try allocator.alloc(u8, count);
    defer allocator.free(joined);
    split_image.image_data.copyInto(joined);
    try std.testing.expectEqualSlices(u8, admitted.image_data.first, joined);

    for ([_][]const u8{ source, split }) |encoded| {
        for ([_]?usize{ null, 0, 1 }) |declined| {
            var moving = MovingPngAllocator{ .backing = allocator, .decline_call = declined };
            const authority = moving.allocator();
            var image = try rgbaAlloc(u8, authority, encoded, .{});
            defer image.deinit(authority);
            try std.testing.expectEqualSlices(u8, &expected, image.texels);
            if (declined == null) {
                try std.testing.expectEqual(
                    if (encoded.ptr == split.ptr) @as(usize, 2) else 1,
                    moving.moves,
                );
                try std.testing.expectEqual(moving.remapped_pointer.?, image.texels.ptr);
            }
        }
        try expectSharedPngLifetimes(encoded, &expected);
        try std.testing.checkAllAllocationFailures(
            allocator,
            decodeWithFailingAllocator,
            .{encoded},
        );
    }
    // A moved joined owner must unwind on a bad consumed Adler, before final transfer.
    const final_payload_chunk = first + 12 + (count - 1) * 13;
    split[final_payload_chunk + 8] ^= 1;
    refreshTestChunkCrc(split, final_payload_chunk);
    var moving = MovingPngAllocator{ .backing = allocator };
    try std.testing.expectError(error.InvalidPng, rgbaAlloc(u8, moving.allocator(), split, .{}));
    try std.testing.expectEqual(1, moving.moves);
    try std.testing.expectEqual(1, moving.calls);
}

test "caller extent permits a wide raster without relaxing defaults or PNG dimensions" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(
        allocator,
        .{ .width = 4097, .height = 1, .filter_pattern = .none },
    );
    defer image.deinit(allocator);
    try std.testing.expectError(error.InvalidPng, rgbaAlloc(u8, allocator, image.source, .{}));
    try std.testing.expectError(
        error.InvalidPng,
        rgbaAlloc(u8, allocator, image.source, .{ .maximum_source_extent = 0 }),
    );
    var decoded = try rgbaAlloc(u8, allocator, image.source, .{ .maximum_source_extent = 8192 });
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(4097, decoded.width);
    try std.testing.expectEqualSlices(u8, image.expected, decoded.texels);

    std.mem.writeInt(u32, image.source[16..20], 0x80000000, .big);
    refreshTestChunkCrc(image.source, 8);
    try std.testing.expectError(
        error.InvalidPng,
        rgbaAlloc(
            u8,
            std.testing.failing_allocator,
            image.source,
            .{ .maximum_source_extent = std.math.maxInt(u32) },
        ),
    );
}

fn checkMutatedPng(source: []const u8) !void {
    var decoded = rgbaAlloc(u8, std.testing.allocator, source, .{}) catch |err| switch (err) {
        error.InvalidPng,
        error.UnsupportedPng,
        error.MetadataLimitExceeded,
        error.EncodedBudgetExceeded,
        error.PixelBudgetExceeded,
        error.OutputBudgetExceeded,
        error.ScratchBudgetExceeded,
        error.WorkBudgetExceeded,
        => return,
        error.OutOfMemory => return err,
    };
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expect(decoded.width > 0 and decoded.width <= default_maximum_source_extent);
    try std.testing.expect(decoded.height > 0 and decoded.height <= default_maximum_source_extent);
    try std.testing.expectEqual(@as(usize, decoded.width) * decoded.height * 4, decoded.texels.len);
}

test "bounded malformed PNG mutations preserve decoder bounds" {
    var generated = try TestImage.init(
        std.testing.allocator,
        .{ .width = 4, .height = 4, .filter_pattern = .mixed },
    );
    defer generated.deinit(std.testing.allocator);
    const source = generated.source;
    const mutated = try std.testing.allocator.alloc(u8, source.len);
    defer std.testing.allocator.free(mutated);
    const idat_offset = 8 + 25;
    const idat_length: usize = readU32Big(source, idat_offset);
    const idat_data_offset = idat_offset + 8;
    const filtered_offset = idat_data_offset + 2 + 5;
    const filtered_length = (4 * 4 + 1) * 4;
    const adler_offset = filtered_offset + filtered_length;
    try std.testing.expectEqual(1, source[idat_data_offset + 2]);
    try std.testing.expectEqual(
        filtered_length,
        std.mem.readInt(u16, source[idat_data_offset + 3 ..][0..2], .little),
    );
    try std.testing.expectEqual(idat_data_offset + idat_length, adler_offset + 4);

    // Raw corruption and every truncation exercise framing and declared bounds.
    for (0..source.len) |index| {
        for ([_]u8{ 0, 0xff }) |value| {
            @memcpy(mutated, source);
            mutated[index] = value;
            try checkMutatedPng(mutated);
        }
    }
    for (0..source.len + 1) |length| try checkMutatedPng(source[0..length]);

    // Repair the outer CRC so parser, inflater, and row checks see the mutation.
    for (16..29) |index| {
        for ([_]u8{ 0, 0xff }) |value| {
            @memcpy(mutated, source);
            mutated[index] = value;
            refreshTestChunkCrc(mutated, 8);
            try checkMutatedPng(mutated);
        }
    }
    for (idat_data_offset..idat_data_offset + idat_length) |index| {
        for ([_]u8{ 0, 0xff }) |value| {
            @memcpy(mutated, source);
            mutated[index] = value;
            refreshTestChunkCrc(mutated, idat_offset);
            try checkMutatedPng(mutated);
        }
    }

    // The fixture's single stored block can also reach scanline validation.
    for (filtered_offset..filtered_offset + filtered_length) |index| {
        for ([_]u8{ 0, 0xff }) |value| {
            @memcpy(mutated, source);
            mutated[index] = value;
            std.mem.writeInt(
                u32,
                mutated[adler_offset..][0..4],
                std.hash.Adler32.hash(mutated[filtered_offset..][0..filtered_length]),
                .big,
            );
            refreshTestChunkCrc(mutated, idat_offset);
            try checkMutatedPng(mutated);
        }
    }
}

test "expanded formats transfer moved storage and preserve bounded replay budgets" {
    const allocator = std.testing.allocator;
    const encoded_cases = [_][]const u8{
        testing_samples.grayscale_fixture,          testing_samples.grayscale_1_fixture,
        testing_samples.grayscale_2_fixture,        testing_samples.grayscale_4_adam7_fixture,
        testing_samples.grayscale_alpha_fixture,    testing_samples.grayscale_16_fixture,
        testing_samples.grayscale_alpha_16_fixture, testing_samples.rgb_16_fixture,
        testing_samples.rgba_16_fixture,            testing_samples.rgba_16_adam7_fixture,
        testing_samples.palette_1_fixture,          testing_samples.palette_2_fixture,
        testing_samples.palette_4_fixture,          testing_samples.palette_8_fixture,
        testing_samples.indexed_adam7_fixture,      testing_samples.rgb_adam7_fixture,
        testing_samples.tiny_adam7_fixture,
    };
    for (encoded_cases) |encoded| {
        const source = try allocator.dupe(u8, encoded);
        defer allocator.free(source);
        const saved = try allocator.dupe(u8, source);
        defer allocator.free(saved);
        var expected = try rgbaAllocWithScratch(u8, allocator, allocator, source, .{});
        defer expected.deinit(allocator);
        for ([_]?usize{ null, 0, 1, 2 }) |declined| {
            var moving = MovingPngAllocator{ .backing = allocator, .decline_call = declined };
            const authority = moving.allocator();
            var result = try rgbaAlloc(u8, authority, source, .{});
            defer result.deinit(authority);
            try std.testing.expectEqualSlices(u8, expected.texels, result.texels);
            if (declined == null) {
                try std.testing.expectEqual(3, moving.moves);
                try std.testing.expectEqual(moving.remapped_pointer.?, result.texels.ptr);
            }
        }
        const image = try SourceImage.open(
            source,
            .{ .maximum_source_extent = default_maximum_source_extent },
        );
        const prefix = 7;
        const capacity = prefix + expected.texels.len + Inflater.history_bytes + image
            .packed_row_bytes * 2;
        const storage = try allocator.alloc(u8, capacity);
        defer allocator.free(storage);
        var fixed = std.heap.FixedBufferAllocator.init(storage);
        @memset(try fixed.allocator().alloc(u8, prefix), 0x5a);
        for (0..3) |_| {
            var result = try rgbaAlloc(u8, fixed.allocator(), source, .{});
            try std.testing.expectEqualSlices(u8, expected.texels, result.texels);
            try std.testing.expectEqual(prefix + result.texels.len, fixed.end_index);
            result.deinit(fixed.allocator());
            try std.testing.expectEqual(prefix, fixed.end_index);
        }
        try std.testing.expectEqualSlices(u8, saved, source);
        try std.testing.expectEqualSlices(u8, &(@as([prefix]u8, @splat(0x5a))), storage[0..prefix]);
        try std.testing.checkAllAllocationFailures(
            allocator,
            decodeWithFailingAllocator,
            .{source},
        );
    }
}

test "split image joining bounds unused tails without rejecting valid pixels" {
    const allocator = std.testing.allocator;
    for (
        [_][]const u8{ testing_samples.rgb_fixture, testing_samples.palette_8_fixture },
    ) |encoded| {
        const source = try allocator.dupe(u8, encoded);
        defer allocator.free(source);
        var expected = try rgbaAllocWithScratch(u8, allocator, allocator, source, .{});
        defer expected.deinit(allocator);
        const admitted = try SourceImage.open(
            source,
            .{ .maximum_source_extent = default_maximum_source_extent },
        );
        const tail_length = 32768;
        const split = try allocator.alloc(u8, source.len + tail_length + 24);
        defer allocator.free(split);
        const first = admitted.image_data.first_offset;
        @memcpy(split[0..first], source[0..first]);
        var offset = first;
        writeTestChunk(split, &offset, "IDAT", admitted.image_data.first);
        writeTestChunk(split, &offset, "IDAT", &.{});
        const tail = try allocator.alloc(u8, tail_length);
        defer allocator.free(tail);
        @memset(tail, 0xa5);
        writeTestChunk(split, &offset, "IDAT", tail);
        @memcpy(split[offset..], source[admitted.image_data.after_last..]);
        const image = try SourceImage.open(
            split,
            .{ .maximum_source_extent = default_maximum_source_extent },
        );
        try std.testing.expect(image.image_data.multiple);
        try std.testing.expect(
            !canJoinImageData(image.image_data.byte_count, image.filtered_byte_count),
        );
        var moving = MovingPngAllocator{ .backing = allocator };
        var result = try rgbaAlloc(u8, moving.allocator(), split, .{});
        defer result.deinit(moving.allocator());
        try std.testing.expectEqualSlices(u8, expected.texels, result.texels);
        try std.testing.expectEqual(if (image.color_type == 2) @as(usize, 1) else 0, moving.moves);
        try expectSharedPngLifetimes(split, expected.texels);
        try std.testing.checkAllAllocationFailures(allocator, decodeWithFailingAllocator, .{split});
    }
}

fn rejectIndexedPixelsWithFailingAllocator(allocator: std.mem.Allocator, source: []const u8) !void {
    var image = rgbaAlloc(u8, allocator, source, .{ .palette_index_policy = .reject }) catch |err| {
        if (err == error.InvalidPng) return;
        return err;
    };
    defer image.deinit(allocator);
    return error.ExpectedInvalidPalette;
}

test "prepared indexed expansion rejects missing entries and retires bounded staging" {
    const allocator = std.testing.allocator;
    for (
        [_][]const u8{
            testing_samples.palette_1_fixture, testing_samples.palette_2_fixture,
            testing_samples.palette_4_fixture, testing_samples.palette_8_fixture,
        },
    ) |encoded| {
        const source = try allocator.dupe(u8, encoded);
        defer allocator.free(source);
        const palette_offset = 8 + 25;
        const palette_bytes = readU32Big(source, palette_offset);
        const after_palette = palette_offset + 12 + palette_bytes;
        const shortened = try allocator.alloc(u8, source.len - (palette_bytes - 3));
        defer allocator.free(shortened);
        @memcpy(shortened[0..palette_offset], source[0..palette_offset]);
        var offset: usize = palette_offset;
        writeTestChunk(shortened, &offset, "PLTE", source[palette_offset + 8 ..][0..3]);
        @memcpy(shortened[offset..], source[after_palette..]);
        const image = try SourceImage.open(
            shortened,
            .{ .maximum_source_extent = default_maximum_source_extent },
        );
        try std.testing.expectEqual(1, image.palette.len);
        const source_hash = std.hash.Wyhash.hash(0, shortened);
        const prefix = 7;
        const capacity = prefix + @as(
            usize,
            image.width,
        ) * image.height * 4 + Inflater.history_bytes + streaming_state_byte_count + image
            .packed_row_bytes * 2;
        const storage = try allocator.alloc(u8, capacity);
        defer allocator.free(storage);
        var fixed = std.heap.FixedBufferAllocator.init(storage);
        @memset(try fixed.allocator().alloc(u8, prefix), 0x5a);
        for ([_]bool{ false, true }) |explicit_scratch| {
            for (0..3) |_| {
                try std.testing.expectError(
                    error.InvalidPng,
                    decodeByteAlloc(
                        fixed.allocator(),
                        if (explicit_scratch) fixed.allocator() else null,
                        shortened,
                        .{ .palette_index_policy = .reject },
                    ),
                );
                try std.testing.expectEqual(prefix, fixed.end_index);
                try std.testing.expectEqualSlices(
                    u8,
                    &(@as([prefix]u8, @splat(0x5a))),
                    storage[0..prefix],
                );
            }
        }
        try std.testing.expectEqual(source_hash, std.hash.Wyhash.hash(0, shortened));
        try std.testing.checkAllAllocationFailures(
            allocator,
            rejectIndexedPixelsWithFailingAllocator,
            .{shortened},
        );
    }
}

const testing_zlib = struct {
    /// A None filter followed by one exact RGBA8 pixel.
    pub const filtered = [_]u8{ 0, 1, 2, 3, 4 };

    /// Untagged 1x1 RGBA8 PNG image header: dimensions, sample depth, color type, compression,
    /// filter method, and sequential scan order.
    pub const image_header = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0 };

    /// Expected decoded pixel, independently specified from the stored-block bytes.
    pub const texels = [_]u8{ 1, 2, 3, 4 };

    /// RFC 1950 wrapper, one final RFC 1951 stored block, and big-endian Adler-32.
    pub const stream = [_]u8{
        0x78, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff, 0x00,
        0x01, 0x02, 0x03, 0x04, 0x00, 0x19, 0x00, 0x0b,
    };

    /// The same literal row in a nonfinal stored block followed by a fixed empty block. Python zlib
    /// 1.3.2 independently admits its output, checksum and unused suffix.
    pub const mixed_stream = [_]u8{
        0x78, 0x01, 0x00, 0x05, 0x00, 0xfa, 0xff, 0x00,
        0x01, 0x02, 0x03, 0x04, 0x03, 0x00, 0x00, 0x19,
        0x00, 0x0b,
    };

    /// Valid header pairs for all eight window exponents, followed by the other compression-level
    /// hints at the largest window. No stream uses a dictionary.
    pub const valid_headers = [_][2]u8{
        .{ 0x08, 0x1d },
        .{ 0x18, 0x19 },
        .{ 0x28, 0x15 },
        .{ 0x38, 0x11 },
        .{ 0x48, 0x0d },
        .{ 0x58, 0x09 },
        .{ 0x68, 0x05 },
        .{ 0x78, 0x01 },
        .{ 0x78, 0x5e },
        .{ 0x78, 0x9c },
        .{ 0x78, 0xda },
    };

    /// Invalid FCHECK, prohibited preset dictionary, unknown method, and excessive window exponent.
    /// The last three have valid FCHECK to isolate their own failure.
    pub const invalid_headers = [_][2]u8{
        .{ 0x78, 0x00 },
        .{ 0x78, 0x20 },
        .{ 0x79, 0x18 },
        .{ 0x88, 0x1c },
    };
};

test "Average RGB fusion and bounded replay match independently retained full samples" {
    const allocator = std.testing.allocator;
    inline for (
        .{
            .{ rgb_average.source, 32, &rgb_average.texels_sha256 },
            .{ rgb_average.wide_source, 129, &rgb_average.wide_texels_sha256 },
        },
    ) |fixture| {
        const source = try allocator.dupe(u8, fixture[0]);
        defer allocator.free(source);
        for ([_]bool{ false, true }) |bounded| {
            var image = try decodeByteAlloc(
                allocator,
                if (bounded) allocator else null,
                source,
                .{},
            );
            defer image.deinit(allocator);
            try std.testing.expectEqual(fixture[1], image.width);
            try std.testing.expectEqual(fixture[1], image.height);
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(image.texels, &hash, .{});
            try std.testing.expectEqualSlices(u8, fixture[2], &hash);
        }
    }
}

test "PNG zlib wrapper accepts window and level hints across IDAT boundaries" {
    for (testing_zlib.valid_headers) |header| {
        var stream = testing_zlib.stream;
        stream[0..2].* = header;
        for ([_]bool{ false, true }) |split| {
            const source = try wrapZlib(std.testing.allocator, &stream, split);
            defer std.testing.allocator.free(source);
            try expectPixel(source);
        }
    }
}

test "stored PNG chunks need only filtered backing and release it after failure" {
    const allocator = std.testing.allocator;
    const prefix_bytes = 3;
    const storage = try allocator.alloc(u8, prefix_bytes + testing_zlib.filtered.len);
    defer allocator.free(storage);
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    const bounded = fixed.allocator();
    const prefix = try bounded.alloc(u8, prefix_bytes);
    @memset(prefix, 0xa5);
    for ([_]bool{ false, true }) |split| {
        const source = try wrapZlib(allocator, &testing_zlib.stream, split);
        defer allocator.free(source);
        for (0..16) |_| {
            var image = try rgbaAlloc(u8, bounded, source, .{});
            try std.testing.expectEqualSlices(u8, &testing_zlib.texels, image.texels);
            try std.testing.expectEqual(prefix_bytes + testing_zlib.texels.len, fixed.end_index);
            image.deinit(bounded);
            try std.testing.expectEqual(prefix_bytes, fixed.end_index);
            for (prefix) |byte| try std.testing.expectEqual(0xa5, byte);
        }
        // Explicit scratch retains the selected bounded validation/replay contract.
        try std.testing.expectError(
            error.OutOfMemory,
            rgbaAllocWithScratch(u8, bounded, bounded, source, .{}),
        );
        try std.testing.expectEqual(prefix_bytes, fixed.end_index);

        var damaged = testing_zlib.stream;
        damaged[damaged.len - 1] ^= 1;
        const invalid = try wrapZlib(allocator, &damaged, split);
        defer allocator.free(invalid);
        try std.testing.expectError(error.InvalidPng, rgbaAlloc(u8, bounded, invalid, .{}));
        try std.testing.expectEqual(prefix_bytes, fixed.end_index);
        for (prefix) |byte| try std.testing.expectEqual(0xa5, byte);

        // The stored probe fills the row, then declines the final fixed block. General inflation
        // must restart from the original borrowed IDAT input.
        const mixed = try wrapZlib(allocator, &testing_zlib.mixed_stream, split);
        defer allocator.free(mixed);
        try expectPixel(mixed);
    }
}

test "PNG zlib wrapper rejects invalid header flags despite matching chunk CRCs" {
    for (testing_zlib.invalid_headers) |header| {
        var stream = testing_zlib.stream;
        stream[0..2].* = header;
        for ([_]bool{ false, true }) |split| {
            const source = try wrapZlib(std.testing.allocator, &stream, split);
            defer std.testing.allocator.free(source);
            try expectInvalid(std.testing.allocator, null, source, .{});
        }
    }
}

test "PNG zlib header validation precedes image workspace allocation" {
    for (testing_zlib.invalid_headers) |header| {
        var stream = testing_zlib.stream;
        stream[0..2].* = header;
        for ([_]bool{ false, true }) |split| {
            const source = try wrapZlib(std.testing.allocator, &stream, split);
            defer std.testing.allocator.free(source);
            try expectInvalid(std.testing.failing_allocator, null, source, .{});
        }
    }
}

test "PNG zlib checksum rejects changed footer and filtered bytes" {
    const filtered_offset = testing_zlib.stream.len - 4 - testing_zlib.filtered.len;
    for (filtered_offset..testing_zlib.stream.len) |index| {
        var stream = testing_zlib.stream;
        // Both the five-byte filtered row and every checksum byte are covered. The changed filter
        // is Sub, still a valid filter for the single pixel.
        stream[index] ^= 1;
        for ([_]bool{ false, true }) |split| {
            const source = try wrapZlib(std.testing.allocator, &stream, split);
            defer std.testing.allocator.free(source);
            try expectInvalid(std.testing.allocator, null, source, .{});
        }
    }
    var stream = testing_zlib.stream;
    stream[stream.len - 1] ^= 1;
    const source = try wrapZlib(std.testing.allocator, &stream, true);
    defer std.testing.allocator.free(source);
    try expectInvalid(std.testing.failing_allocator, std.testing.allocator, source, .{});
}

test "PNG zlib checksum ignores unused IDAT bytes following the stream" {
    const stream = testing_zlib.stream ++ [_]u8{ 0, 0, 0, 0 };
    for ([_]bool{ false, true }) |split| {
        const source = try wrapZlib(std.testing.allocator, &stream, split);
        defer std.testing.allocator.free(source);
        try expectPixel(source);
    }
}

fn expectPixel(source: []const u8) !void {
    try validateImage(
        try SourceImage.open(source, .{ .maximum_source_extent = default_maximum_source_extent }),
        .{ .scratch_allocator = std.testing.allocator, .limits = .{ .maximum_output_bytes = 0 } },
    );
    var image = try rgbaAlloc(u8, std.testing.allocator, source, .{});
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, image.width);
    try std.testing.expectEqual(1, image.height);
    try std.testing.expectEqualSlices(u8, &testing_zlib.texels, image.texels);
}

fn expectInvalid(
    output_allocator: std.mem.Allocator,
    scratch_allocator: ?std.mem.Allocator,
    source: []const u8,
    options: Options,
) !void {
    const admitted = try SourceImage.open(
        source,
        .{ .maximum_source_extent = options.maximum_source_extent },
    );
    // These independent wrapper controls are 1x1; both used output and spare capacity stay private
    // when header, filtered bytes or the consumed footer are rejected.
    try std.testing.expectEqual(1, admitted.width);
    try std.testing.expectEqual(1, admitted.height);
    try std.testing.expectError(
        error.InvalidPng,
        validateImage(
            admitted,
            .{
                .scratch_allocator = scratch_allocator orelse output_allocator,
                .limits = options.limits,
            },
        ),
    );
    inline for (.{ u8, u16 }) |Sample| {
        const sentinel: Sample = if (Sample == u8) 0xa5 else 0xa55a;
        var output: [8]Sample = @splat(sentinel);
        try std.testing.expectError(
            error.InvalidPng,
            decodeImageIntoTransactional(
                Sample,
                admitted,
                &output,
                .{
                    .scratch_allocator = scratch_allocator orelse output_allocator,
                    .limits = options.limits,
                },
            ),
        );
        for (output) |value| try std.testing.expectEqual(sentinel, value);
    }
    var image = decodeByteAlloc(output_allocator, scratch_allocator, source, options) catch |err| {
        try std.testing.expectEqual(error.InvalidPng, err);
        return;
    };
    defer image.deinit(output_allocator);
    return error.AcceptedInvalidZlib;
}

fn wrapZlib(allocator: std.mem.Allocator, stream: []const u8, split: bool) ![]u8 {
    // The untagged 1x1 RGBA8 header is independent of the production encoder.
    const chunk_count = if (split) stream.len + 2 else 1;
    const source = try allocator.alloc(u8, 8 + 25 + stream.len + chunk_count * 12 + 12);
    errdefer allocator.free(source);
    @memcpy(source[0..8], &[_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a });
    var offset: usize = 8;
    writeChunk(source, &offset, "IHDR", &testing_zlib.image_header);
    if (split) {
        writeChunk(source, &offset, "IDAT", &.{});
        for (stream) |byte| writeChunk(source, &offset, "IDAT", &.{byte});
        writeChunk(source, &offset, "IDAT", &.{});
    } else {
        writeChunk(source, &offset, "IDAT", stream);
    }
    writeChunk(source, &offset, "IEND", &.{});
    try std.testing.expectEqual(source.len, offset);
    return source;
}

fn writeChunk(source: []u8, offset: *usize, kind: *const [4]u8, data: []const u8) void {
    const start = offset.*;
    std.mem.writeInt(u32, source[start..][0..4], @intCast(data.len), .big);
    @memcpy(source[start + 4 ..][0..4], kind);
    @memcpy(source[start + 8 ..][0..data.len], data);
    const crc_offset = start + 8 + data.len;
    const crc = std.hash.Crc32.hash(source[start + 4 .. crc_offset]);
    std.mem.writeInt(u32, source[crc_offset..][0..4], crc, .big);
    offset.* = crc_offset + 4;
}

test "RGBA16 PNG output preserves frozen low bytes for every 16-bit color layout" {
    // These literal words are the independent filtered fixture's original samples; Python 3 zlib
    // expansion and libpng 1.6.59 confirm them independently (2026-10-08). Native reference uses
    // expand, gray_to_rgb, add_alpha only when absent, and interlace handling; it selects no
    // gamma/ICC conversion or alpha association. After read_image, serialize big-endian channel
    // pairs as little-endian RGBA16 words. Decoded SHA-256: RGBA16:
    // 450f6fd577d6d57ae58a1a4dd2c8f5fde9a0645e64309c23b4cb864544414b70 gray16:
    // 3d463d7fc24cade131ac8f8549204fc6a0e71bea3ad1eb23f682b5672445ca0c RGB16:
    // 93085831119a544a5ee1b8e0d8b176646e4bdf81f5dd7bb4b28b703b9ed670c7 gray/A:
    // 143e572aeb116e1f1ce4fc41846ff7648778a02d3d7d2815291381ea9cacee95

    for (testing_samples.cases16) |case| {
        var image = blk: {
            const source = try std.testing.allocator.dupe(u8, case.source);
            defer std.testing.allocator.free(source);
            break :blk try rgbaAlloc(u16, std.testing.allocator, source, .{});
        };
        defer image.deinit(std.testing.allocator);
        try std.testing.expectEqual(16, image.encoded_bit_depth);
        try std.testing.expectEqual(2, image.width);
        try std.testing.expectEqual(1, image.height);
        try std.testing.expectEqualSlices(u16, case.expected, image.texels);
    }
}

test "RGBA16 PNG transparency compares original complete samples" {
    // libpng 1.6.59 independently confirms zero alpha for the original complete key. Little-endian
    // RGBA16 hashes after inserting tRNS at offset 33: gray16:
    // 187f440fca804a69156c831741cdbdb8857305e8ea977c2b5687ca87fb7da9e0 RGB16:
    // 32e8bff41039f0f625f334201a79d5d9468c0ecbc33ee29cb46eceed5a81287b
    inline for (
        .{ testing_samples.grayscale_16_fixture, testing_samples.rgb_16_fixture },
    ) |encoded| {
        const source = try std.testing.allocator.dupe(u8, encoded);
        defer std.testing.allocator.free(source);
        const color = (try SourceImage.open(source, .{ .maximum_source_extent = 2 })).color_type;
        for ([_]u8{ 0x34, 0x35 }) |low_byte| {
            const key = [_]u8{ 0x12, low_byte, 0x56, 0x78, 0x9a, 0xbc };
            const tagged = try insertChunk(
                std.testing.allocator,
                source,
                33,
                "tRNS",
                key[0..if (color == 0) @as(usize, 2) else 6],
            );
            defer std.testing.allocator.free(tagged);
            var image = try rgbaAlloc(u16, std.testing.allocator, tagged, .{});
            defer image.deinit(std.testing.allocator);
            try std.testing.expectEqual(0x1234, image.texels[0]);
            try std.testing.expectEqual(
                if (low_byte == 0x34) @as(u16, 0) else 65535,
                image.texels[3],
            );
            try std.testing.expectEqual(65535, image.texels[7]);
        }
    }
}

test "RGBA16 PNG Adam7 and narrower layout expansion retain qualified sample meaning" {
    // Sequential and Adam7 libpng 1.6.59 RGBA16 outputs share SHA-256
    // 675ec120b8a6cf5088150e0ece3d979f25a56d4dc6a9abd66f9ca940bb747cf8.
    for (
        [_][]const u8{
            testing_samples.rgba_16_adam7_sequential_fixture, testing_samples.rgba_16_adam7_fixture,
        },
    ) |encoded| {
        const source = try std.testing.allocator.dupe(u8, encoded);
        defer std.testing.allocator.free(source);
        var image = try rgbaAlloc(u16, std.testing.allocator, source, .{});
        defer image.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u16, &testing_samples.adam7_rgba16, image.texels);
    }
    const palette = try std.testing.allocator.dupe(u8, testing_samples.palette_8_fixture);
    defer std.testing.allocator.free(palette);
    var palette_image = try rgbaAlloc(u16, std.testing.allocator, palette, .{});
    defer palette_image.deinit(std.testing.allocator);
    // Independent libpng result, byte-to-word expansion; decoded SHA-256
    // 84502ee6aa59de0641171cf1bb9c64318b23696e4ff9a741508c908c6224067a.
    try std.testing.expectEqualSlices(u16, &testing_samples.palette_rgba16, palette_image.texels);
    const gray = try std.testing.allocator.dupe(u8, testing_samples.grayscale_2_fixture);
    defer std.testing.allocator.free(gray);
    var gray_image = try rgbaAlloc(u16, std.testing.allocator, gray, .{});
    defer gray_image.deinit(std.testing.allocator);
    // Independent libpng expanded 2-bit grayscale and tRNS; decoded SHA-256
    // fbd49c5fa3be21b1db3787071467581cac27894a0e0387dc94f9c5b4f816c4e2.
    try std.testing.expectEqualSlices(u16, &testing_samples.gray_2_trns_rgba16, gray_image.texels);
    // Supplement independent narrow-layout RGBA8 controls with exact cross-representation checks.
    // They cover pass scattering, filters and palette alpha rather than lossy reduction.
    for (
        [_][]const u8{
            testing_samples.grayscale_2_fixture,     testing_samples.grayscale_4_adam7_fixture,
            testing_samples.grayscale_alpha_fixture, testing_samples.rgba_filters_fixture,
            testing_samples.palette_1_fixture,       testing_samples.palette_2_fixture,
            testing_samples.palette_4_fixture,       testing_samples.palette_8_fixture,
            testing_samples.rgb_adam7_fixture,       testing_samples.indexed_adam7_fixture,
        },
    ) |encoded| {
        const source = try std.testing.allocator.dupe(u8, encoded);
        defer std.testing.allocator.free(source);
        var narrow = try rgbaAlloc(u8, std.testing.allocator, source, .{});
        defer narrow.deinit(std.testing.allocator);
        var wide = try rgbaAlloc(u16, std.testing.allocator, source, .{});
        defer wide.deinit(std.testing.allocator);
        for (
            narrow.texels,
            wide.texels,
        ) |byte, word| try std.testing.expectEqual(@as(u16, byte) * 257, word);
    }
}

fn decodeWideWithFailingAllocator(allocator: std.mem.Allocator, source: []const u8) !void {
    var image = try rgbaAllocWithScratch(u16, allocator, allocator, source, .{});
    defer image.deinit(allocator);
}

test "RGBA16 PNG validates checksum before output and releases every partial allocation" {
    for (
        [_][]const u8{
            testing_samples.rgba_16_fixture,   testing_samples.rgba_16_adam7_fixture,
            testing_samples.palette_4_fixture,
        },
    ) |encoded| {
        const source = try std.testing.allocator.dupe(u8, encoded);
        defer std.testing.allocator.free(source);
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            decodeWideWithFailingAllocator,
            .{source},
        );
    }
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgba_16_fixture);
    defer std.testing.allocator.free(source);
    source[33 + 8 + readU32Big(source, 33) - 1] ^= 1;
    refreshTestChunkCrc(source, 33);
    var output = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.InvalidPng,
        rgbaAllocWithScratch(u16, output.allocator(), std.testing.allocator, source, .{}),
    );
    try std.testing.expect(!output.has_induced_failure);
}

const metadata_fixtures = png_metadata_vectors;

test "PNG resource policy rejects before output and admits exact word replay reservations" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgba_16_fixture);
    defer std.testing.allocator.free(source);
    const denied = std.testing.failing_allocator;
    const tagged = try std.testing.allocator.dupe(u8, metadata_fixtures.color_png);
    defer std.testing.allocator.free(tagged);
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        rgbaAlloc(u8, denied, tagged, .{ .limits = .{ .maximum_metadata_bytes = 0 } }),
    );
    try std.testing.expectError(
        error.PixelBudgetExceeded,
        rgbaAlloc(u16, denied, source, .{ .limits = .{ .maximum_pixels = 1 } }),
    );
    try std.testing.expectError(
        error.OutputBudgetExceeded,
        rgbaAlloc(u16, denied, source, .{ .limits = .{ .maximum_output_bytes = 15 } }),
    );
    try std.testing.expectError(
        error.WorkBudgetExceeded,
        rgbaAlloc(u16, denied, source, .{ .limits = .{ .maximum_work_units = source.len - 1 } }),
    );
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        rgbaAlloc(u16, denied, source, .{ .limits = .{ .maximum_records = 2 } }),
    );
    try std.testing.expectError(
        error.ScratchBudgetExceeded,
        rgbaAlloc(u16, denied, source, .{ .limits = .{ .maximum_scratch_bytes = 0 } }),
    );
    const scratch_bytes = Inflater.history_bytes + streaming_state_byte_count + 16;
    var image = try rgbaAlloc(
        u16,
        std.testing.allocator,
        source,
        .{
            .limits = .{
                .maximum_pixels = 2,
                .maximum_output_bytes = 16,
                .maximum_scratch_bytes = scratch_bytes,
            },
        },
    );
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u16,
        &.{ 0x1234, 0x5678, 0x9abc, 0xdef0, 0xffff, 0x0102, 0x0304, 0x0506 },
        image.texels,
    );
    try std.testing.expectError(
        error.ScratchBudgetExceeded,
        rgbaAlloc(
            u16,
            std.testing.allocator,
            source,
            .{ .limits = .{ .maximum_scratch_bytes = scratch_bytes - 1 } },
        ),
    );
}

test "reserved PNG byte and word prefixes retain exact samples and unused capacity" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgba_16_fixture);
    defer std.testing.allocator.free(source);
    const image = try SourceImage.open(
        source,
        .{ .maximum_source_extent = default_maximum_source_extent },
    );
    var words: [12]u16 = @splat(0xa55a);
    try decodeImageInto(u16, image, &words, .{ .scratch_allocator = std.testing.allocator });
    try std.testing.expectEqualSlices(u16, testing_samples.cases16[0].expected, words[0..8]);
    try std.testing.expectEqualSlices(u16, &.{ 0xa55a, 0xa55a, 0xa55a, 0xa55a }, words[8..]);
    var bytes: [12]u8 = @splat(0xa5);
    try decodeImageInto(u8, image, &bytes, .{ .scratch_allocator = std.testing.allocator });
    try std.testing.expectEqualSlices(u8, &testing_samples.rgba16_standard, bytes[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, bytes[8..]);
    try std.testing.expectError(
        error.OutputTooSmall,
        decodeImageInto(
            u16,
            image,
            words[0..7],
            .{ .scratch_allocator = std.testing.failing_allocator },
        ),
    );
    try std.testing.expectError(
        error.OutputBudgetExceeded,
        decodeImageInto(
            u16,
            image,
            &words,
            .{
                .scratch_allocator = std.testing.failing_allocator,
                .limits = .{ .maximum_output_bytes = 15 },
            },
        ),
    );
    const work = image.image_data.byte_count + image.filtered_byte_count * 4;
    try std.testing.expectError(
        error.WorkBudgetExceeded,
        decodeImageInto(
            u16,
            image,
            &words,
            .{
                .scratch_allocator = std.testing.failing_allocator,
                .limits = .{ .maximum_work_units = work - 1 },
            },
        ),
    );
    try decodeImageInto(
        u16,
        image,
        &words,
        .{
            .scratch_allocator = std.testing.allocator,
            .limits = .{
                .maximum_pixels = 2,
                .maximum_output_bytes = 16,
                .maximum_work_units = work,
            },
        },
    );
}

test "reserved PNG checksum refusal precedes writes and every scratch failure retires" {
    const source = try std.testing.allocator.dupe(u8, testing_samples.rgba_16_fixture);
    defer std.testing.allocator.free(source);
    const image = try SourceImage.open(
        source,
        .{ .maximum_source_extent = default_maximum_source_extent },
    );
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, admitted: SourceImage) !void {
            var destination: [8]u16 = undefined;
            try decodeImageInto(u16, admitted, &destination, .{ .scratch_allocator = allocator });
            try std.testing.expectEqualSlices(
                u16,
                testing_samples.cases16[0].expected,
                &destination,
            );
        }
    }.run, .{image});
    var destination: [12]u16 = @splat(0xa55a);
    try std.testing.expectError(
        error.ScratchBudgetExceeded,
        decodeImageInto(
            u16,
            image,
            &destination,
            .{
                .scratch_allocator = std.testing.allocator,
                .limits = .{ .maximum_scratch_bytes = 0 },
            },
        ),
    );
    source[33 + 8 + readU32Big(source, 33) - 1] ^= 1;
    refreshTestChunkCrc(source, 33);
    const malformed = try SourceImage.open(
        source,
        .{ .maximum_source_extent = default_maximum_source_extent },
    );
    try std.testing.expectError(
        error.InvalidPng,
        decodeImageInto(
            u16,
            malformed,
            &destination,
            .{ .scratch_allocator = std.testing.allocator },
        ),
    );
    for (destination) |sample| try std.testing.expectEqual(0xa55a, sample);
}

test "transactional PNG reservation and validation preserve retained packed and wide layouts" {
    for (
        [_][]const u8{
            testing_samples.rgb_fixture,
            testing_samples.grayscale_fixture,
            testing_samples.grayscale_1_fixture,
            testing_samples.grayscale_2_fixture,
            testing_samples.grayscale_4_adam7_fixture,
            testing_samples.grayscale_alpha_fixture,
            testing_samples.rgba_16_fixture,
            testing_samples.grayscale_16_fixture,
            testing_samples.rgb_16_fixture,
            testing_samples.grayscale_alpha_16_fixture,
            testing_samples.rgba_16_adam7_sequential_fixture,
            testing_samples.rgba_16_adam7_fixture,
            testing_samples.palette_1_fixture,
            testing_samples.palette_2_fixture,
            testing_samples.palette_4_fixture,
            testing_samples.palette_8_fixture,
            testing_samples.rgba_filters_fixture,
            testing_samples.rgb_adam7_sequential_fixture,
            testing_samples.rgb_adam7_fixture,
            testing_samples.indexed_adam7_sequential_fixture,
            testing_samples.indexed_adam7_fixture,
            testing_samples.tiny_sequential_fixture,
            testing_samples.tiny_adam7_fixture,
        },
    ) |encoded| {
        const source = try std.testing.allocator.dupe(u8, encoded);
        defer std.testing.allocator.free(source);
        const image = try SourceImage.open(
            source,
            .{ .maximum_source_extent = default_maximum_source_extent },
        );
        try validateImage(
            image,
            .{
                .scratch_allocator = std.testing.allocator,
                .limits = .{ .maximum_output_bytes = 0 },
            },
        );
        inline for (.{ u8, u16 }) |Sample| {
            var expected = if (Sample == u8) try rgbaAlloc(
                u8,
                std.testing.allocator,
                source,
                .{},
            ) else try rgbaAlloc(u16, std.testing.allocator, source, .{});
            defer expected.deinit(std.testing.allocator);
            const destination = try std.testing.allocator.alloc(Sample, expected.texels.len + 4);
            defer std.testing.allocator.free(destination);
            const sentinel: Sample = if (Sample == u8) 0xa5 else 0xa55a;
            @memset(destination, sentinel);
            try decodeImageIntoTransactional(
                Sample,
                image,
                destination,
                .{ .scratch_allocator = std.testing.allocator },
            );
            try std.testing.expectEqualSlices(
                Sample,
                expected.texels,
                destination[0..expected.texels.len],
            );
            for (
                destination[expected.texels.len..],
            ) |value| try std.testing.expectEqual(sentinel, value);
        }
    }
}

test "transactional PNG rows and validation retain filters through compressed one-byte chunks" {
    for (
        [_]TestImage.FilterPattern{ .none, .up, .mixed, .sub, .average, .paeth },
    ) |filter| for (
        [_]TestImage.Compression{ .stored, .fixed_literals, .std_fast, .std_default },
    ) |compression| for ([_]usize{ 1, 65536 }) |chunk_bytes| {
        var generated = try TestImage.init(
            std.testing.allocator,
            .{
                .width = 31,
                .height = 13,
                .filter_pattern = filter,
                .compression = compression,
                .idat_chunk_bytes = chunk_bytes,
            },
        );
        defer generated.deinit(std.testing.allocator);
        const image = try SourceImage.open(
            generated.source,
            .{ .maximum_source_extent = default_maximum_source_extent },
        );
        try validateImage(
            image,
            .{
                .scratch_allocator = std.testing.allocator,
                .limits = .{ .maximum_output_bytes = 0 },
            },
        );
        inline for (.{ u8, u16 }) |Sample| {
            const count = generated.expected.len;
            const output = try std.testing.allocator.alloc(Sample, count + 4);
            defer std.testing.allocator.free(output);
            const sentinel: Sample = if (Sample == u8) 0xa5 else 0xa55a;
            @memset(output, sentinel);
            try decodeImageIntoTransactional(
                Sample,
                image,
                output,
                .{ .scratch_allocator = std.testing.allocator },
            );
            for (
                generated.expected,
                output[0..count],
            ) |byte, value| try std.testing.expectEqual(
                if (Sample == u8) byte else @as(u16, byte) * 257,
                value,
            );
            for (output[count..]) |value| try std.testing.expectEqual(sentinel, value);
        }
    };
}

test "transactional PNG validates late filters and palette indices before publication" {
    const allocator = std.testing.allocator;
    var generated = try TestImage.init(
        allocator,
        .{ .width = 4, .height = 4, .filter_pattern = .none },
    );
    defer generated.deinit(allocator);
    const offset = 33;
    const filtered_offset = offset + 8 + 2 + 5;
    generated.source[filtered_offset + 17 * 3] = 5;
    std.mem.writeInt(
        u32,
        generated.source[filtered_offset + 68 ..][0..4],
        std.hash.Adler32.hash(generated.source[filtered_offset..][0..68]),
        .big,
    );
    refreshTestChunkCrc(generated.source, offset);
    const invalid_filter = try SourceImage.open(
        generated.source,
        .{ .maximum_source_extent = default_maximum_source_extent },
    );

    const original = try allocator.dupe(u8, testing_samples.palette_4_fixture);
    defer allocator.free(original);
    // PLTE now admits two entries; the original active row uses 0,1,2,3,4. Correct chunk
    // framing/checksum leaves the third sample as the first invalid index.
    const palette_offset = 33;
    const original_end = palette_offset + 12 + readU32Big(original, palette_offset);
    const invalid_source = try allocator.alloc(u8, original.len - 9);
    defer allocator.free(invalid_source);
    @memcpy(invalid_source[0..palette_offset], original[0..palette_offset]);
    var next: usize = palette_offset;
    writeTestChunk(invalid_source, &next, "PLTE", original[palette_offset + 8 ..][0..6]);
    @memcpy(invalid_source[next..], original[original_end..]);
    const invalid_palette = try SourceImage.open(
        invalid_source,
        .{ .maximum_source_extent = default_maximum_source_extent },
    );
    for ([_]SourceImage{ invalid_filter, invalid_palette }) |image| {
        try std.testing.expectError(
            error.InvalidPng,
            validateImage(
                image,
                .{
                    .scratch_allocator = allocator,
                    .palette_index_policy = .reject,
                    .limits = .{ .maximum_output_bytes = 0 },
                },
            ),
        );
    }
    inline for (.{ u8, u16 }) |Sample| {
        const sentinel: Sample = if (Sample == u8) 0xa5 else 0xa55a;
        var output: [68]Sample = @splat(sentinel);
        for ([_]SourceImage{ invalid_filter, invalid_palette }) |image| {
            try std.testing.expectError(
                error.InvalidPng,
                decodeImageIntoTransactional(
                    Sample,
                    image,
                    &output,
                    .{ .scratch_allocator = allocator, .palette_index_policy = .reject },
                ),
            );
            for (output) |value| try std.testing.expectEqual(sentinel, value);
        }
    }
}

test "single-row PNG validation and replay reserve one packed row" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |split| {
        const source = try wrapZlib(allocator, &testing_zlib.stream, split);
        defer allocator.free(source);
        const image = try SourceImage.open(
            source,
            .{ .maximum_source_extent = default_maximum_source_extent },
        );
        const scratch_bytes = Inflater.history_bytes + streaming_state_byte_count + 4;
        const storage = try allocator.alloc(u8, scratch_bytes + 17 + 16);
        defer allocator.free(storage);
        @memset(storage, 0xa5);
        var backing = std.heap.FixedBufferAllocator.init(storage[8..][0 .. scratch_bytes + 17]);
        const prefix = try backing.allocator().alloc(u8, 17);
        @memset(prefix, 0x3c);
        const options: ImageDecodeOptions = .{
            .scratch_allocator = backing.allocator(),
            .limits = .{
                .maximum_pixels = 1,
                .maximum_output_bytes = 8,
                .maximum_work_units = image.image_data.byte_count + image.filtered_byte_count * 6,
                .maximum_scratch_bytes = scratch_bytes,
            },
        };
        var narrow: [8]u8 = @splat(0xa5);
        var wide: [8]u16 = @splat(0xa55a);
        for (0..2) |_| {
            try validateImage(image, options);
            try decodeImageInto(u16, image, &wide, options);
            try decodeImageIntoTransactional(u16, image, &wide, options);
            try decodeImageIntoTransactional(u8, image, &narrow, options);
            try std.testing.expectEqualSlices(
                u8,
                &.{ 1, 2, 3, 4, 0xa5, 0xa5, 0xa5, 0xa5 },
                &narrow,
            );
            try std.testing.expectEqualSlices(
                u16,
                &.{ 257, 514, 771, 1028, 0xa55a, 0xa55a, 0xa55a, 0xa55a },
                &wide,
            );
            try std.testing.expectEqual(17, backing.end_index);
        }
        @memset(narrow[0..4], 0xa5);
        @memset(wide[0..4], 0xa55a);
        var limited = options;
        limited.limits.maximum_scratch_bytes -= 1;
        try std.testing.expectError(error.ScratchBudgetExceeded, validateImage(image, limited));
        try std.testing.expectError(
            error.ScratchBudgetExceeded,
            decodeImageInto(u16, image, &wide, limited),
        );
        try std.testing.expectError(
            error.ScratchBudgetExceeded,
            decodeImageIntoTransactional(u16, image, &wide, limited),
        );
        try std.testing.expectError(
            error.ScratchBudgetExceeded,
            decodeImageIntoTransactional(u8, image, &narrow, limited),
        );
        backing.buffer = backing.buffer[0 .. backing.buffer.len - 1];
        try std.testing.expectError(error.OutOfMemory, validateImage(image, options));
        try std.testing.expectEqual(17, backing.end_index);
        for (narrow) |sample| try std.testing.expectEqual(0xa5, sample);
        for (wide) |sample| try std.testing.expectEqual(0xa55a, sample);
        for (prefix) |byte| try std.testing.expectEqual(0x3c, byte);
        for (storage[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (storage[storage.len - 8 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "PNG validation without pixels admits exact budgets and retires every scratch failure" {
    const allocator = std.testing.allocator;
    for (
        [_][]const u8{
            testing_samples.rgba_16_fixture,   testing_samples.rgba_16_adam7_fixture,
            testing_samples.palette_4_fixture, testing_samples.rgba_filters_fixture,
        },
    ) |encoded| {
        const source = try allocator.dupe(u8, encoded);
        defer allocator.free(source);
        const source_hash = std.hash.Wyhash.hash(0, source);
        const image = try SourceImage.open(
            source,
            .{ .maximum_source_extent = default_maximum_source_extent },
        );
        try std.testing.checkAllAllocationFailures(allocator, struct {
            fn run(scratch_allocator: std.mem.Allocator, admitted: SourceImage) !void {
                try validateImage(
                    admitted,
                    .{
                        .scratch_allocator = scratch_allocator,
                        .limits = .{ .maximum_output_bytes = 0 },
                    },
                );
            }
        }.run, .{image});
        const scratch_bytes = Inflater.history_bytes + streaming_state_byte_count + image
            .packed_row_bytes * @min(
            image.height,
            2,
        );
        const storage = try allocator.alloc(u8, scratch_bytes + 17 + 16);
        defer allocator.free(storage);
        @memset(storage, 0xa5);
        var backing = std.heap.FixedBufferAllocator.init(storage[8..][0 .. scratch_bytes + 17]);
        const prefix = try backing.allocator().alloc(u8, 17);
        @memset(prefix, 0x3c);
        const options: ImageDecodeOptions = .{
            .scratch_allocator = backing.allocator(),
            .limits = .{
                .maximum_pixels = @as(usize, image.width) * image.height,
                .maximum_output_bytes = 0,
                .maximum_work_units = image.image_data.byte_count + image.filtered_byte_count * 4,
                .maximum_scratch_bytes = scratch_bytes,
            },
        };
        for (0..2) |_| {
            try validateImage(image, options);
            try std.testing.expectEqual(17, backing.end_index);
        }
        var limited = options;
        limited.scratch_allocator = std.testing.failing_allocator;
        limited.limits.maximum_pixels -= 1;
        try std.testing.expectError(error.PixelBudgetExceeded, validateImage(image, limited));
        limited = options;
        limited.scratch_allocator = std.testing.failing_allocator;
        limited.limits.maximum_work_units -= 1;
        try std.testing.expectError(error.WorkBudgetExceeded, validateImage(image, limited));
        limited = options;
        limited.limits.maximum_scratch_bytes -= 1;
        try std.testing.expectError(error.ScratchBudgetExceeded, validateImage(image, limited));
        backing.buffer = backing.buffer[0 .. backing.buffer.len - 1];
        try std.testing.expectError(error.OutOfMemory, validateImage(image, options));
        try std.testing.expectEqual(17, backing.end_index);
        try std.testing.expectEqual(source_hash, std.hash.Wyhash.hash(0, source));
        for (prefix) |byte| try std.testing.expectEqual(0x3c, byte);
        for (storage[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (storage[storage.len - 8 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "transactional PNG reserves exact budgets and retires every scratch failure" {
    const allocator = std.testing.allocator;
    for (
        [_][]const u8{
            testing_samples.rgba_16_fixture,   testing_samples.rgba_16_adam7_fixture,
            testing_samples.palette_4_fixture, testing_samples.rgba_filters_fixture,
        },
    ) |encoded| {
        const source = try allocator.dupe(u8, encoded);
        defer allocator.free(source);
        const image = try SourceImage.open(
            source,
            .{ .maximum_source_extent = default_maximum_source_extent },
        );
        inline for (.{ u8, u16 }) |Sample| {
            try std.testing.checkAllAllocationFailures(allocator, struct {
                fn run(scratch_allocator: std.mem.Allocator, admitted: SourceImage) !void {
                    const count = @as(usize, admitted.width) * admitted.height * 4;
                    const output = try std.testing.allocator.alloc(Sample, count + 4);
                    defer std.testing.allocator.free(output);
                    const sentinel: Sample = if (Sample == u8) 0xa5 else 0xa55a;
                    @memset(output, sentinel);
                    decodeImageIntoTransactional(
                        Sample,
                        admitted,
                        output,
                        .{ .scratch_allocator = scratch_allocator },
                    ) catch |err| {
                        for (output) |value| try std.testing.expectEqual(sentinel, value);
                        return err;
                    };
                    for (output[count..]) |value| try std.testing.expectEqual(sentinel, value);
                }
            }.run, .{image});
        }
    }
    const source = try allocator.dupe(u8, testing_samples.rgba_16_fixture);
    defer allocator.free(source);
    const image = try SourceImage.open(
        source,
        .{ .maximum_source_extent = default_maximum_source_extent },
    );
    const work = image.image_data.byte_count + image.filtered_byte_count * 6;
    const scratch_bytes = Inflater.history_bytes + streaming_state_byte_count + image
        .packed_row_bytes * @min(
        image.height,
        2,
    );
    var output: [12]u16 = @splat(0xa55a);
    const options: ImageDecodeOptions = .{
        .scratch_allocator = allocator,
        .limits = .{
            .maximum_pixels = 2,
            .maximum_output_bytes = 16,
            .maximum_work_units = work,
            .maximum_scratch_bytes = scratch_bytes,
        },
    };
    var limited = options;
    limited.limits.maximum_work_units -= 1;
    try std.testing.expectError(
        error.WorkBudgetExceeded,
        decodeImageIntoTransactional(u16, image, &output, limited),
    );
    limited = options;
    limited.limits.maximum_scratch_bytes -= 1;
    try std.testing.expectError(
        error.ScratchBudgetExceeded,
        decodeImageIntoTransactional(u16, image, &output, limited),
    );
    limited = options;
    limited.limits.maximum_output_bytes -= 1;
    try std.testing.expectError(
        error.OutputBudgetExceeded,
        decodeImageIntoTransactional(u16, image, &output, limited),
    );
    limited = options;
    limited.scratch_allocator = std.testing.failing_allocator;
    try std.testing.expectError(
        error.OutputTooSmall,
        decodeImageIntoTransactional(u16, image, output[0..7], limited),
    );
    for (output) |value| try std.testing.expectEqual(0xa55a, value);
    const backing = try allocator.alloc(u8, scratch_bytes);
    defer allocator.free(backing);
    var scratch = std.heap.FixedBufferAllocator.init(backing);
    limited = options;
    limited.scratch_allocator = scratch.allocator();
    try decodeImageIntoTransactional(u16, image, &output, limited);
    @memset(source, 0);
    @memset(backing, 0);
    try std.testing.expectEqualSlices(
        u16,
        &.{
            0x1234, 0x5678, 0x9abc, 0xdef0, 0xffff, 0x0102, 0x0304, 0x0506,
            0xa55a, 0xa55a, 0xa55a, 0xa55a,
        },
        &output,
    );
}

const raster_fixtures = png_raster_vectors;

test "PNG owned words retire padding through validation replay and allocation failure" {
    const allocator = std.testing.allocator;
    const word_source = try allocator.dupe(
        u8,
        &[_]u8{
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
            0x10, 0x06, 0x00, 0x00, 0x00, 0xa4, 0xb2, 0xa3,
            0xc9, 0x00, 0x00, 0x00, 0x1a, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9c, 0x63, 0x14, 0x32, 0x09, 0xab,
            0x98, 0xb5, 0xe7, 0xde, 0x87, 0xb7, 0xa7, 0x57,
            0x77, 0x65, 0x7a, 0xa8, 0x8b, 0x01, 0x00, 0x46,
            0x0b, 0x08, 0x15, 0xdd, 0x5a, 0x11, 0x90, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
            0x42, 0x60, 0x82,
        },
    );
    defer allocator.free(word_source);
    const facts = raster_fixtures;
    const backing = try allocator.alignedAlloc(u8, .@"2", 1024 * 1024 + 16);
    defer allocator.free(backing);
    @memset(backing, 0x6d);
    var fixed: std.heap.FixedBufferAllocator = .init(backing[8 .. backing.len - 8]);
    @memset(try fixed.allocator().alloc(u8, 17), 0x6d);
    for ([_][]const u8{ facts.sequential_png, facts.adam7_png, word_source }) |source| {
        var reference = try rgbaAlloc(u16, allocator, source, .{});
        defer reference.deinit(allocator);
        inline for (.{ false, true }) |decline_resize| {
            var index: usize = 0;
            while (true) : (index += 1) {
                try std.testing.expect(index < 32);
                var failing: std.testing.FailingAllocator = .init(
                    fixed.allocator(),
                    .{
                        .fail_index = index,
                        .resize_fail_index = if (decline_resize) 0 else std.math.maxInt(usize),
                    },
                );
                const result = rgbaAllocWithScratch(
                    u16,
                    failing.allocator(),
                    failing.allocator(),
                    source,
                    .{},
                );
                if (result) |decoded| {
                    var image = decoded;
                    try std.testing.expectEqualSlices(u16, reference.texels, image.texels);
                    try std.testing.expectEqual(
                        reference.encoded_bit_depth,
                        image.encoded_bit_depth,
                    );
                    try std.testing.expectEqual(
                        reference.encoded_color_type,
                        image.encoded_color_type,
                    );
                    try std.testing.expectEqualDeep(
                        reference.metadata_presence,
                        image.metadata_presence,
                    );
                    try std.testing.expectEqual(fixed.buffer[17..].ptr, image.allocation.ptr);
                    try std.testing.expectEqual(17 + image.allocation.len, fixed.end_index);
                    image.deinit(failing.allocator());
                } else |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                    try std.testing.expect(failing.has_induced_failure);
                }
                try std.testing.expectEqual(17, fixed.end_index);
                try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
                if (result) |_| break else |_| {}
            }
        }
    }
    for (backing[0 .. 8 + 17]) |byte| try std.testing.expectEqual(0x6d, byte);
    for (backing[backing.len - 8 ..]) |byte| try std.testing.expectEqual(0x6d, byte);
}

const palette_fixtures = png_palette_vectors;

test "PNG palette recovery reaches transferred replayed byte and word images and transactions" {
    const fixtures = palette_fixtures;
    const allocator = std.testing.allocator;
    for (fixtures.sources) |wire| {
        const source = try allocator.dupe(u8, wire);
        defer allocator.free(source);
        const image = try SourceImage.open(source, .{ .maximum_source_extent = 17 });
        try std.testing.expectEqual(1, image.palette.len);
        try std.testing.expectEqualSlices(u8, &.{17}, image.palette_alpha);
        try std.testing.expectError(
            error.InvalidPng,
            rgbaAlloc(u8, allocator, source, .{ .palette_index_policy = .reject }),
        );
        try std.testing.expectError(
            error.InvalidPng,
            rgbaAlloc(u16, allocator, source, .{ .palette_index_policy = .reject }),
        );
        for ([_]?std.mem.Allocator{ null, allocator }) |scratch| {
            var decoded = try decodeByteAlloc(
                allocator,
                scratch,
                source,
                .{ .palette_index_policy = .opaque_black },
            );
            defer decoded.deinit(allocator);
            try std.testing.expectEqualSlices(u8, &fixtures.rgba8, decoded.texels);
        }
        var decoded16 = try rgbaAllocWithScratch(
            u16,
            allocator,
            allocator,
            source,
            .{ .palette_index_policy = .opaque_black },
        );
        defer decoded16.deinit(allocator);
        try std.testing.expectEqualSlices(u16, &fixtures.rgba16, decoded16.texels);
        try std.testing.expectError(
            error.InvalidPng,
            validateImage(
                image,
                .{ .scratch_allocator = allocator, .palette_index_policy = .reject },
            ),
        );
        try validateImage(
            image,
            .{ .scratch_allocator = allocator, .palette_index_policy = .opaque_black },
        );
        inline for (.{ u8, u16 }) |Sample| {
            const guard: Sample = if (Sample == u8) 0xa5 else 0xa5a5;
            var output: [207]Sample = @splat(guard);
            try std.testing.expectError(
                error.InvalidPng,
                decodeImageIntoTransactional(
                    Sample,
                    image,
                    output[1..],
                    .{ .scratch_allocator = allocator, .palette_index_policy = .reject },
                ),
            );
            for (output) |value| try std.testing.expectEqual(guard, value);
            const expected: []const Sample = if (Sample == u8) &fixtures.rgba8 else &fixtures
                .rgba16;
            const options: ImageDecodeOptions = .{
                .scratch_allocator = allocator,
                .palette_index_policy = .opaque_black,
            };
            try decodeImageIntoTransactional(Sample, image, output[1..], options);
            try std.testing.expectEqualSlices(Sample, expected, output[1..205]);
            try std.testing.expectEqual(guard, output[0]);
            for (output[205..]) |value| try std.testing.expectEqual(guard, value);
            @memset(&output, guard);
            try decodeImageInto(Sample, image, output[1..], options);
            try std.testing.expectEqualSlices(Sample, expected, output[1..205]);
            try std.testing.expectEqual(guard, output[0]);
            for (output[205..]) |value| try std.testing.expectEqual(guard, value);
        }
        try std.testing.expectEqualSlices(u8, wire, source);
    }
    // Tail-remapping backing exercises the prepared table without retaining its scratch.
    const backing = try allocator.alloc(u8, 2 << 20);
    defer allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    const prefix = try fixed.allocator().alloc(u8, 17);
    @memset(prefix, 0xa5);
    for (fixtures.sources) |wire| {
        var transferred = try rgbaAlloc(
            u8,
            fixed.allocator(),
            wire,
            .{ .palette_index_policy = .opaque_black },
        );
        try std.testing.expectEqualSlices(u8, &fixtures.rgba8, transferred.texels);
        transferred.deinit(fixed.allocator());
        try std.testing.expectEqual(17, fixed.end_index);
    }
    for (prefix) |value| try std.testing.expectEqual(0xa5, value);
}

test "PNG palette recovery retains checksum filter structure and budget failures" {
    const fixtures = palette_fixtures;
    const allocator = std.testing.allocator;
    for (
        [_][]const u8{ fixtures.bad_filter, fixtures.bad_adler, fixtures.missing_palette },
    ) |wire| {
        try std.testing.expectError(
            error.InvalidPng,
            rgbaAlloc(u8, allocator, wire, .{ .palette_index_policy = .opaque_black }),
        );
        if (wire.ptr == fixtures.missing_palette.ptr) continue;
        const image = try SourceImage.open(wire, .{ .maximum_source_extent = 17 });
        inline for (.{ u8, u16 }) |Sample| {
            const guard: Sample = if (Sample == u8) 0xa5 else 0xa5a5;
            var output: [207]Sample = @splat(guard);
            try std.testing.expectError(
                error.InvalidPng,
                decodeImageIntoTransactional(
                    Sample,
                    image,
                    &output,
                    .{ .scratch_allocator = allocator, .palette_index_policy = .opaque_black },
                ),
            );
            for (output) |value| try std.testing.expectEqual(guard, value);
        }
    }
    const image = try SourceImage.open(fixtures.sequential_8, .{ .maximum_source_extent = 17 });
    var output: [207]u8 = @splat(0xa5);
    try std.testing.expectError(
        error.WorkBudgetExceeded,
        decodeImageIntoTransactional(
            u8,
            image,
            &output,
            .{
                .scratch_allocator = allocator,
                .palette_index_policy = .opaque_black,
                .limits = .{ .maximum_work_units = 0 },
            },
        ),
    );
    for (output) |value| try std.testing.expectEqual(0xa5, value);
}

test "PNG word transfer follows relocated byte alignment and declined remaps" {
    const fixtures = png_raster_vectors;
    const allocator = std.testing.allocator;
    const backing = try allocator.alloc(u8, 2 << 20);
    defer allocator.free(backing);
    for (0..2) |prefix| {
        for ([_]?usize{ null, 0, 1, 2 }) |declined| {
            @memset(backing, 0xa5);
            var fixed = std.heap.FixedBufferAllocator.init(backing);
            @memset(try fixed.allocator().alloc(u8, prefix), 0x3c);
            var tracked = std.testing.FailingAllocator.init(fixed.allocator(), .{});
            var moving = MovingPngAllocator{
                .backing = tracked.allocator(),
                .decline_call = declined,
            };
            var image = try rgbaAlloc(u16, moving.allocator(), fixtures.sequential_png, .{});
            try std.testing.expectEqualSlices(u16, &fixtures.sequential_rgba16, image.texels);
            try std.testing.expectEqual(0, @intFromPtr(image.texels.ptr) % @alignOf(u16));
            if (declined == null) {
                // Every remap relocates into the following byte span. The odd-sized combined
                // reservation changes alignment on the final move, requiring sample realignment.
                try std.testing.expectEqual(3, moving.moves);
                try std.testing.expect(image.allocation.len <= image.texels.len * 2 + 1);
            }
            image.deinit(moving.allocator());
            try std.testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
            for (backing[0..prefix]) |byte| try std.testing.expectEqual(0x3c, byte);
        }
    }
}

test "prepared PNG decoding preserves guards and rejects short output" {
    const fixtures = png_raster_vectors;
    const allocator = std.testing.allocator;
    const workspace = try deflate.DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var history: [raster.history_bytes]u8 = undefined;
    var packed_rows: [8]u8 = undefined;
    var conversion: [12]u16 = undefined;
    var output: [62]u16 = @splat(0xa55a);
    const storage: decode_backing.Storage(
        u16,
    ) = .{
        .workspace = workspace,
        .history = &history,
        .packed_rows = &packed_rows,
        .conversion_row = &conversion,
    };
    const result = try rgbaInto(
        u16,
        fixtures.sequential_png,
        output[1..],
        storage,
        .{ .publication = .transactional },
    );
    try std.testing.expectEqualSlices(u16, &fixtures.sequential_rgba16, result.texels);
    try std.testing.expectEqual(0xa55a, output[0]);
    try std.testing.expectEqual(0xa55a, output[61]);
    @memset(&output, 0xa55a);
    _ = try rgbaInto(
        u16,
        fixtures.sequential_png,
        output[1..],
        storage,
        .{ .publication = .partial },
    );
    try std.testing.expectEqualSlices(u16, &fixtures.sequential_rgba16, output[1..61]);
    try std.testing.expectError(
        error.DestinationTooSmall,
        rgbaInto(
            u16,
            fixtures.sequential_png,
            output[0..59],
            storage,
            .{ .publication = .transactional },
        ),
    );
    try std.testing.expectEqualSlices(u16, &fixtures.sequential_rgba16, output[1..61]);
}

test rgbaInto {
    const allocator = std.testing.allocator;
    const pixels = [_]u16{ 0x1234, 0xabcd, 0x5678, 0x8000 };
    const encoded = try png.encode.alloc(allocator, try png.ImageInput.rgba16(&pixels, 1, 1), .{});
    defer allocator.free(encoded);
    const image = try png.Source.open(encoded, .{});
    var workspace = try png.decode.Workspace(u16).initCapacity(allocator, image.header());
    defer workspace.deinit(allocator);
    var output: [4]u16 = undefined;
    const result = try rgbaInto(
        u16,
        encoded,
        &output,
        workspace.storage,
        .{ .publication = .transactional },
    );
    try std.testing.expectEqualSlices(u16, &pixels, result.texels);
}

test "PNG caller output defaults to a transaction while partial publication stays explicit" {
    const fixtures = png_raster_vectors;
    const allocator = std.testing.allocator;
    const source = try png.Source.open(fixtures.invalid_palette_png, .{});
    inline for (.{ u8, u16 }) |Sample| {
        const guard: Sample = if (Sample == u8) 0xa5 else 0xa5a5;
        const rectangle: ImageRegion = .{
            .x = 0,
            .y = 0,
            .width = source.width,
            .height = source.height,
        };
        const required = try source.header().regionRequirements(
            Sample,
            rectangle,
            .{ .encoded_bytes = fixtures.invalid_palette_png.len },
        );
        try std.testing.expectEqual(
            required.samples,
            (try source.regionRequirements(Sample, rectangle, .{})).samples,
        );
        var workspace = try png.decode.Workspace(Sample).initCapacity(allocator, source.header());
        defer workspace.deinit(allocator);
        const destination = try allocator.alloc(Sample, required.samples + 3);
        defer allocator.free(destination);
        @memset(destination, guard);
        try std.testing.expectError(
            error.InvalidPng,
            png.decode.rgbaInto(
                Sample,
                fixtures.invalid_palette_png,
                destination[1..],
                workspace.storage,
                .{ .palette_index_policy = .reject },
            ),
        );
        for (destination) |value| try std.testing.expectEqual(guard, value);
        try std.testing.expectError(
            error.InvalidPng,
            source.decodeRgbaInto(
                Sample,
                destination[1..],
                workspace.storage,
                .{ .palette_index_policy = .reject },
            ),
        );
        for (destination) |value| try std.testing.expectEqual(guard, value);

        try std.testing.expectError(
            error.InvalidPng,
            source.decodeRgbaInto(
                Sample,
                destination[1..],
                workspace.storage,
                .{ .palette_index_policy = .reject, .publication = .partial },
            ),
        );
        const expected: [4]Sample = if (Sample == u8) .{
            1, 2, 3, 17,
        } else .{ 257, 514, 771, 4369 };
        try std.testing.expectEqualSlices(Sample, &expected, destination[1..5]);
        try std.testing.expectEqual(guard, destination[0]);
        for (
            destination[required.samples + 1 ..],
        ) |value| try std.testing.expectEqual(guard, value);

        var rows = try source.rowReader(
            Sample,
            .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            workspace.storage,
            &.{},
            .{ .palette_index_policy = .reject },
        );
        var band: [7]Sample = @splat(guard);
        try std.testing.expectEqualSlices(Sample, &expected, (try rows.read(&band)).?.image.texels);
        @memset(&band, guard);
        try std.testing.expectError(error.InvalidPng, rows.read(&band));
        for (band) |value| try std.testing.expectEqual(guard, value);
    }
}
