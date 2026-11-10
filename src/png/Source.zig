//! Read-only PNG geometry, palette and metadata declarations with borrowed encoded data. Create a
//! complete-image view with open; APNG frame inspection also returns views with local dimensions.
//! Keep all fields unchanged and the encoded bytes alive and unchanged while any derived view is in
//! use. Opening checks structure and sample layout; decoding checks compressed data and pixels.

const std = @import("std");
const Limits = @import("Limits.zig");
const png_animation_vectors = @import("testdata/animation.zig");
const ImageData = @import("ImageData.zig");
const png = @import("../png.zig");
const owned = @import("image_decode.zig");
const png_raster_vectors = @import("testdata/raster.zig");
const metadata_reader = @import("metadata.zig");
const format = @import("format.zig");
const Chunk = @import("Chunk.zig");
const decoding = @import("image_decode.zig");
const regions = @import("region_decode.zig");
const rows = @import("row_reader.zig");
const decode_backing = @import("decode_workspace.zig");
const ImageRegion = @import("../common/ImageRegion.zig");
const Header = @import("Header.zig");

const Crc32 = @import("../crc.zig").Crc32IsoHdlc;

const Error = format.Error;

const Source = @This();

/// Stored image width in pixels, within the caller's limit and PNG's 31-bit bound.
width: u32,
/// Stored image height in pixels, within the caller's limit and PNG's 31-bit bound.
height: u32,
/// Complete source canvas width; an APNG frame view may have a smaller local width.
canvas_width: u32,
/// Complete source canvas height; an APNG frame view may have a smaller local height.
canvas_height: u32,
/// Stored bits per sample: 1, 2, 4, 8 or 16 as permitted by color_type. Indexed samples are palette
/// indices rather than color channels.
bit_depth: u8,
/// PNG color type: grayscale, truecolor, indexed, grayscale-alpha, or RGBA.
color_type: u8,
/// Stored samples per pixel: 1 for grayscale/indexed, 2 for gray-alpha, 3 for RGB, 4 for RGBA.
channel_count: usize,
/// Zero selects sequential rows; one selects Adam7 pass-local rows.
interlace_method: u8,
/// Borrowed PLTE entries for indexed images; suggested truecolor palettes are ignored.
palette: []const [3]u8,
/// Borrowed indexed tRNS values; missing entries are opaque.
palette_alpha: []const u8,
/// Optional stored-depth grayscale tRNS code; unused upper bits are ignored. Comparison precedes
/// any decoded sample scaling or precision reduction.
transparent_gray: ?u16,
/// Optional stored-depth truecolor tRNS codes; unused upper bits are ignored. Comparison precedes
/// any decoded sample scaling or precision reduction.
transparent_rgb: ?[3]u16,
/// Packed bits per stored pixel: channel_count times bit_depth, or bit_depth for an index.
bits_per_pixel: usize,
/// Packed bytes in one full-width row, excluding its leading filter byte.
packed_row_bytes: usize,
/// Exact inflated byte count across all nonempty passes, including filter bytes.
filtered_byte_count: usize,
/// Internal compressed-range cache; do not construct or modify it. Use chunks() for supported
/// inspection of encoded records.
image_data: ImageData,
/// Chunk count for the complete containing PNG, including IEND; unchanged in frame-local views.
record_count: usize,
/// Encoded ancillary payload bytes checked under Options. Each fdAT contributes only its four-byte
/// sequence word; its compressed frame bytes are excluded.
metadata_bytes: usize,
/// Copied ancillary presence flags; payload interpretation remains an explicit metadata query.
metadata_presence: metadata_reader.Metadata.Presence = .{},

/// Traverses every chunk in the complete borrowed PNG, including unknown ancillary chunks and IEND.
/// Frame-local sources still inspect their complete containing PNG. Each iterator rechecks framing
/// and CRCs; no pixel or optional metadata interpretation is performed. Keep encoded bytes
/// unchanged until all returned payload borrows end.
pub fn chunks(self: Source) Chunk.Iterator {
    return Chunk.Iterator.init(self.image_data.source) catch unreachable;
}

/// Returns a reader over this image's borrowed encoded bytes without expanding compressed records.
/// Keep those bytes unchanged while the reader or its returned records are used; the Source value
/// itself may move or go out of scope. Reading metadata neither validates pixels nor applies a
/// color or orientation transform.
pub fn metadata(self: Source) metadata_reader.Metadata.Reader {
    return .{
        .source = self.image_data.source,
        .bit_depth = self.bit_depth,
        .color_type = self.color_type,
    };
}

/// Copies admitted layout/declarations without retaining encoded data or palette pointers.
/// Structural admission remains separate from filtered bytes, zlib and sample validity.
pub fn header(self: Source) Header {
    return .{
        .width = self.width,
        .height = self.height,
        .bit_depth = self.bit_depth,
        .color_type = self.color_type,
        .channel_count = self.channel_count,
        .interlace_method = self.interlace_method,
        .bits_per_pixel = self.bits_per_pixel,
        .packed_row_bytes = self.packed_row_bytes,
        .filtered_byte_count = self.filtered_byte_count,
        .metadata_presence = self.metadata_presence,
    };
}

/// Restores this admitted static/default or frame-local source into disjoint caller samples.
/// Transactional publication is the default; partial publication must be selected explicitly.
pub fn decodeRgbaInto(
    self: Source,
    comptime Sample: type,
    destination: []Sample,
    storage: decode_backing.Storage(Sample),
    options: decoding.IntoOptions,
) decoding.IntoError!regions.View(Sample) {
    return decoding.admittedRgbaInto(Sample, self, destination, storage, options);
}

/// Reports full-source traversal, selected output/backing and fixed/minimum work without decoding
/// pixels. Source/metadata bytes remain borrowed and unchanged.
pub fn regionRequirements(
    self: Source,
    comptime Sample: type,
    rectangle: ImageRegion,
    options: regions.Options,
) regions.Error!regions.Requirements {
    return regions.admittedRequirements(Sample, self, rectangle, options);
}

/// Publishes a complete selected crop transactionally using prepared disjoint storage. Every error
/// preserves the destination; complete source work remains chargeable.
pub fn decodeRegionInto(
    self: Source,
    comptime Sample: type,
    rectangle: ImageRegion,
    destination: []Sample,
    storage: decode_backing.Storage(Sample),
    options: regions.Options,
) regions.Error!regions.View(Sample) {
    return regions.admittedInto(Sample, self, rectangle, destination, storage, options);
}

/// Starts row-by-row decoding of a selected rectangle from complete input. The row iterator borrows
/// encoded bytes and prepared storage; each returned row borrows the destination passed to that
/// read. Continue until null to validate the remaining input, even after the desired rows.
pub fn rowReader(
    self: Source,
    comptime Sample: type,
    rectangle: ImageRegion,
    storage: decode_backing.Storage(Sample),
    reconstruction: []Sample,
    options: regions.Options,
) regions.Error!rows.RowReader(Sample) {
    return rows.fromSource(Sample, self, rectangle, storage, reconstruction, options);
}

/// Validates complete chunk framing, CRCs, ordering and supported sample layouts. Borrows unchanged
/// input through IEND. Zlib, filters and pixel values need decoding.
pub fn open(source: []const u8, options: Options) Error!Source {
    if (source.len > options.maximum_encoded_bytes) return error.EncodedBudgetExceeded;
    if (!std.mem.startsWith(u8, source, format.signature)) return error.InvalidPng;

    var validator = Chunk.Validator.init(
        .{
            .maximum_source_extent = options.maximum_source_extent,
            .maximum_records = options.maximum_records,
            .maximum_metadata_bytes = options.maximum_metadata_bytes,
        },
    );
    var palette: []const [3]u8 = &.{};
    var palette_alpha: []const u8 = &.{};
    var first_idat: ?[]const u8 = null;
    var first_idat_offset: usize = 0;
    var after_last_idat: usize = 0;
    var multiple_idat = false;
    var idat_byte_count: usize = 0;
    var offset: usize = format.signature.len;
    while (offset < source.len) {
        const header_end = std.math.add(usize, offset, 8) catch return error.InvalidPng;
        if (header_end > source.len) return error.InvalidPng;
        const chunk_length: usize = readU32Big(source, offset);
        const data_end = std.math.add(
            usize,
            header_end,
            chunk_length,
        ) catch return error.InvalidPng;
        const chunk_end = std.math.add(usize, data_end, 4) catch return error.InvalidPng;
        if (chunk_end > source.len) return error.InvalidPng;

        const chunk_type = source[offset + 4 ..][0..4];
        const kind = try validator.start(chunk_type, chunk_length);
        const chunk_data = source[header_end..data_end];
        var crc = Crc32.init();
        crc.update(chunk_type);
        crc.update(chunk_data);
        if (crc.final() != readU32Big(source, data_end)) return error.InvalidPng;
        try validator.complete(chunk_data);
        switch (kind) {
            .idat => {
                if (first_idat == null) {
                    first_idat = chunk_data;
                    first_idat_offset = offset;
                } else {
                    multiple_idat = true;
                }
                after_last_idat = chunk_end;
                // Increasing disjoint admitted payload ranges cannot sum beyond source.len.
                idat_byte_count += chunk_data.len;
            },
            .plte => if (validator.header.?.color_type == 3) {
                palette = std.mem.bytesAsSlice([3]u8, chunk_data);
            },
            .trns => if (validator.header.?.color_type == 3) {
                palette_alpha = chunk_data;
            },
            .iend => if (chunk_end != source.len) return error.InvalidPng,
            else => {},
        }
        offset = chunk_end;
    }
    const admitted_header = try validator.finish();
    return .{
        .width = admitted_header.width,
        .height = admitted_header.height,
        .canvas_width = admitted_header.width,
        .canvas_height = admitted_header.height,
        .bit_depth = admitted_header.bit_depth,
        .color_type = admitted_header.color_type,
        .channel_count = admitted_header.channel_count,
        .interlace_method = admitted_header.interlace_method,
        .palette = palette,
        .palette_alpha = palette_alpha,
        .transparent_gray = validator.transparent_gray,
        .transparent_rgb = validator.transparent_rgb,
        .bits_per_pixel = admitted_header.bits_per_pixel,
        .packed_row_bytes = admitted_header.packed_row_bytes,
        .filtered_byte_count = admitted_header.filtered_byte_count,
        .metadata_presence = admitted_header.metadata_presence,
        .record_count = validator.record_count,
        .metadata_bytes = validator.metadata_bytes,
        .image_data = .{
            .source = source,
            .first = first_idat orelse return error.InvalidPng,
            .first_offset = first_idat_offset,
            .after_last = after_last_idat,
            .multiple = multiple_idat,
            .byte_count = idat_byte_count,
        },
    };
}
test open {
    const allocator = std.testing.allocator;
    const bytes = try png.encode.alloc(
        allocator,
        try png.ImageInput.rgba8(&.{ 255, 0, 0, 255 }, 1, 1),
        .{},
    );
    defer allocator.free(bytes);
    const image = try Source.open(bytes, .{});
    try std.testing.expectEqual(1, image.width);
    try std.testing.expectEqual(1, image.height);
    try std.testing.expectEqual(8, image.header().bit_depth);
}

/// Default accepted image width or height; a decode may supply its own limit.
pub const default_maximum_source_extent: u32 = format.default_maximum_source_extent;

/// Allocation-free structure policy, independent of selected optional metadata semantics.
pub const Options = struct {
    /// Complete source bytes, including metadata, framing and unused final-IDAT tails.
    maximum_encoded_bytes: usize = std.math.maxInt(usize),
    /// Largest admitted axis; PNG's 31-bit format bound remains independent.
    maximum_source_extent: u32 = default_maximum_source_extent,
    /// Maximum visited chunks, independently of payload and selected pixel size.
    maximum_records: usize = 1024 * 1024,
    /// Aggregate ancillary payload bytes, including unknown chunks, before CRC traversal. fdAT
    /// contributes its sequence word; compressed frame pixels remain source storage.
    maximum_metadata_bytes: usize = 1024 * 1024,
};

fn readU32Big(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

const raster_fixtures = png_raster_vectors;

test "PNG copied header and payload iteration preserve admitted geometry empty chunks and tails" {
    const fixtures = raster_fixtures;
    const image = try Source.open(fixtures.sequential_png, .{ .maximum_source_extent = 5 });
    const source_header = image.header();
    try std.testing.expectEqual(3, source_header.width);
    try std.testing.expectEqual(5, source_header.height);
    try std.testing.expectEqual(8, source_header.bit_depth);
    try std.testing.expectEqual(0, source_header.color_type);
    try std.testing.expectEqual(3, source_header.packed_row_bytes);
    try std.testing.expectEqual(20, source_header.filtered_byte_count);
    try std.testing.expect(source_header.metadata_presence.text);
    var iterator = image.image_data.payloads();
    try std.testing.expectEqualSlices(u8, &.{0x78}, iterator.next().?);
    try std.testing.expectEqual(0, iterator.next().?.len);
    const tail = iterator.next().?;
    try std.testing.expectEqualSlices(u8, &.{ 0xe7, 0x91 }, tail[tail.len - 2 ..]);
    try std.testing.expectEqual(image.image_data.byte_count, tail.len + 1);
    try std.testing.expectEqual(null, iterator.next());
    const interlaced = try Source.open(fixtures.adam7_png, .{ .maximum_source_extent = 3 });
    try std.testing.expectEqual(15, interlaced.header().filtered_byte_count);
    const ihdr = fixtures.adam7_png[16..29];
    const copied = try Header.fromIhdr(ihdr, 3);
    try std.testing.expectEqual(15, copied.filtered_byte_count);
    try std.testing.expect(!copied.metadata_presence.text);
    try std.testing.expectError(error.InvalidPng, Header.fromIhdr(ihdr[0..12], 3));
    try std.testing.expectError(error.InvalidPng, Header.fromIhdr(ihdr, 2));
    var bad = ihdr.*;
    bad[8] = 3;
    try std.testing.expectError(error.UnsupportedPng, Header.fromIhdr(&bad, 3));
    bad = ihdr.*;
    bad[10] = 1;
    try std.testing.expectError(error.UnsupportedPng, Header.fromIhdr(&bad, 3));
    bad = ihdr.*;
    @memset(bad[0..4], 0);
    try std.testing.expectError(error.InvalidPng, Header.fromIhdr(&bad, 3));
}

test "PNG encoded source limits are independent and precede CRC and allocation" {
    const encoded = raster_fixtures.sequential_png;
    _ = try Source.open(encoded, .{ .maximum_encoded_bytes = encoded.len });
    var corrupt = encoded.*;
    corrupt[corrupt.len - 1] ^= 1;
    try std.testing.expectError(
        error.EncodedBudgetExceeded,
        Source.open(&corrupt, .{ .maximum_encoded_bytes = encoded.len - 1 }),
    );
    inline for (.{ u8, u16 }) |Sample| {
        try std.testing.expectError(
            error.EncodedBudgetExceeded,
            owned.rgbaAlloc(
                Sample,
                std.testing.failing_allocator,
                encoded,
                .{ .maximum_encoded_bytes = encoded.len - 1 },
            ),
        );
        try std.testing.expectError(
            error.EncodedBudgetExceeded,
            owned.rgbaAllocWithScratch(
                Sample,
                std.testing.failing_allocator,
                std.testing.failing_allocator,
                encoded,
                .{ .maximum_encoded_bytes = encoded.len - 1 },
            ),
        );
    }
}

test "admitted PNG operations enforce stricter structural limits before output" {
    const source_bytes = png_animation_vectors.rgba8;
    const source = try png.Source.open(source_bytes, .{});
    const rectangle: ImageRegion = .{ .x = 0, .y = 0, .width = 2, .height = 2 };
    const allocator = std.testing.allocator;
    var workspace = try png.decode.Workspace(u8).initCapacity(allocator, source.header());
    defer workspace.deinit(allocator);
    var output: [16]u8 = @splat(0xa5);
    const policies = [_]Limits{
        .{ .maximum_records = source.record_count - 1 },
        .{ .maximum_metadata_bytes = source.metadata_bytes - 1 },
    };
    try std.testing.expect(source.record_count > 0 and source.metadata_bytes > 0);
    for (policies) |limits| {
        const options: png.decode.RegionOptions = .{ .limits = limits };
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            png.decode.regionRequirements(u8, source_bytes, rectangle, options),
        );
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            source.regionRequirements(u8, rectangle, options),
        );
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            source.decodeRegionInto(u8, rectangle, &output, workspace.storage, options),
        );
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            source.rowReader(u8, rectangle, workspace.storage, &.{}, options),
        );
        for ([_]png.decode.IntoOptions.Publication{ .transactional, .partial }) |publication| {
            try std.testing.expectError(
                error.MetadataLimitExceeded,
                source.decodeRgbaInto(
                    u8,
                    &output,
                    workspace.storage,
                    .{ .limits = limits, .publication = publication },
                ),
            );
            try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0xa5))), &output);
        }
    }
    const animation = try png.AnimationSource.open(source_bytes, .{});
    var frames = animation.frames();
    const frame = frames.next().?;
    try std.testing.expectEqual(source.record_count, frame.image.record_count);
    try std.testing.expectEqual(source.metadata_bytes, frame.image.metadata_bytes);
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        frame.image.regionRequirements(u8, rectangle, .{ .limits = policies[0] }),
    );
    const small_frame = frames.next().?;
    const small_rectangle: ImageRegion = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    try std.testing.expectEqual(1, small_frame.image.width);
    try std.testing.expectEqual(1, small_frame.image.height);
    try std.testing.expectEqual(2, small_frame.image.canvas_width);
    try std.testing.expectEqual(2, small_frame.image.canvas_height);
    try std.testing.expectError(
        error.InvalidPng,
        small_frame.image.regionRequirements(u8, small_rectangle, .{ .maximum_source_extent = 1 }),
    );
    for ([_]png.decode.IntoOptions.Publication{ .transactional, .partial }) |publication| {
        try std.testing.expectError(
            error.InvalidPng,
            small_frame.image.decodeRgbaInto(
                u8,
                &output,
                workspace.storage,
                .{ .publication = publication, .maximum_source_extent = 1 },
            ),
        );
        try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0xa5))), &output);
    }

    const exact: png.decode.RegionOptions = .{
        .limits = .{
            .maximum_records = source.record_count,
            .maximum_metadata_bytes = source.metadata_bytes,
        },
    };
    _ = try source.regionRequirements(u8, rectangle, exact);
    _ = try source.decodeRegionInto(u8, rectangle, &output, workspace.storage, exact);
    try std.testing.expectError(
        error.EncodedBudgetExceeded,
        source.decodeRgbaInto(
            u8,
            &output,
            workspace.storage,
            .{ .publication = .partial, .maximum_encoded_bytes = source_bytes.len - 1 },
        ),
    );
    try std.testing.expectError(
        error.InvalidPng,
        source.decodeRgbaInto(
            u8,
            &output,
            workspace.storage,
            .{ .publication = .partial, .maximum_source_extent = 1 },
        ),
    );
}
