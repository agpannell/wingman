//! Selected PNG geometry, backing/work requirements and transactional crop decoding.

const std = @import("std");
const png_format = @import("format.zig");
const Header = @import("Header.zig");
const SourceImage = @import("Source.zig");
const Limits = @import("Limits.zig");
const ImageRegion = @import("../common/ImageRegion.zig");
const raster = @import("raster_decoder.zig");
const decode_backing = @import("decode_workspace.zig");
const row_reading = @import("row_reader.zig");
const deflate = @import("../deflate.zig");
const png_palette_vectors = @import("testdata/palette.zig");
const png_raster_vectors = @import("testdata/raster.zig");

pub const Error = raster.Error || error{RowReaderCanceled};
const Storage = decode_backing.Storage;

/// Independent complete source admission and selected output/work policy.
pub const Options = struct {
    /// Missing palette entries recover as opaque black by default, including outside the crop.
    palette_index_policy: png_format.PaletteIndexPolicy = .opaque_black,
    /// Largest stored axis, independent of selected crop pixels and backing size.
    maximum_source_extent: u32 = SourceImage.default_maximum_source_extent,
    /// Complete encoded source bytes, including ignored metadata and unused IDAT tails.
    maximum_encoded_bytes: usize = std.math.maxInt(usize),
    /// Selected output and complete work/structural limits. Caller backing is not heap scratch.
    limits: Limits = .{},
};

/// Copied selected output/backing facts and explicitly partial work estimates. Actual generic
/// inflation additionally charges accepted zlib input and restored output bytes. Its data-dependent
/// work cannot be established by structural inspection alone; no upper bound is implied by these
/// fixed/minimum fields. Region replay charges the same actual work twice.
pub const Requirements = struct {
    /// Complete source size; zero denotes an outer suspended owner charging input incrementally.
    encoded_bytes: usize,
    /// Complete source geometry and row/history backing requirements.
    raster: raster.Requirements,
    /// Selected logical pixels, independent of complete source pixels.
    pixels: usize,
    /// Exactly four selected output elements per pixel.
    samples: usize,
    /// Selected output bytes under the chosen Sample type.
    output_bytes: usize,
    /// Complete selected row capacity in Sample elements.
    row_samples: usize,
    /// Selected Adam7 reconstruction capacity; zero for sequential complete-row delivery.
    reconstruction_samples: usize,
    /// Selected Adam7 reconstruction bytes; complete-region replay needs no such backing.
    reconstruction_bytes: usize,
    /// Framing, two raster reconstructions and selected publication; null means native overflow.
    region_fixed_work_units: ?usize,
    /// Framing, one raster reconstruction, selected scatter and row delivery.
    row_fixed_work_units: usize,
    /// Fixed region work plus two exact filtered lengths; excludes compressed input work.
    minimum_region_work_units: ?usize,
    /// Fixed row work plus exact filtered length; excludes compressed input work.
    minimum_row_work_units: usize,
};

/// Plans a crop from already admitted copied geometry without rechecking chunk bytes. The source
/// byte count charges complete framing work; zero denotes a suspended owner charging input later.
/// No pixel validation or storage reservation occurs. Output, backing and partial work facts use
/// the same plan as region transactions, RowReader and Decoder.
pub fn headerRequirements(
    comptime Sample: type,
    header: Header,
    rectangle: ImageRegion,
    encoded_bytes: usize,
    limits: Limits,
) raster.Error!Requirements {
    return (try Plan(Sample).init(header, rectangle, encoded_bytes, limits)).requirements;
}

/// Copied selected geometry shared by regions, complete-source rows and suspended input. It owns no
/// encoded data, palette, allocator or backing.
pub fn Plan(comptime Sample: type) type {
    return struct {
        const Self = @This();

        /// Admitted copied complete source geometry/declarations.
        header: Header,
        /// Checked top-left selection in the original sample grid.
        rectangle: ImageRegion,
        /// Selected sizes, row backing and fixed/minimum work facts.
        requirements: Requirements,

        /// Plans admitted unchanged source geometry without visiting pixels or allocating. Encoded
        /// bytes count complete framing work; suspended owners may charge them later.
        pub fn init(
            header: Header,
            rectangle: ImageRegion,
            encoded_bytes: usize,
            limits: Limits,
        ) raster.Error!Self {
            try rectangle.validate(header.width, header.height);
            const raster_cost = try raster.requirements(Sample, header);
            const pixels_count = std.math.mul(
                usize,
                rectangle.width,
                rectangle.height,
            ) catch return error.PixelBudgetExceeded;
            const samples = std.math.mul(
                usize,
                pixels_count,
                4,
            ) catch return error.OutputBudgetExceeded;
            const output_bytes = std.math.mul(
                usize,
                samples,
                @sizeOf(Sample),
            ) catch return error.OutputBudgetExceeded;
            try png_format.admitOutput(limits, pixels_count, output_bytes);
            const interlaced = header.interlace_method != 0;
            const raster_work = raster_cost.reconstruction_work_units;
            const two_rasters = std.math.mul(usize, raster_work, 2) catch null;
            const region_fixed = if (two_rasters) |twice| blk: {
                const framed = std.math.add(usize, encoded_bytes, twice) catch break :blk null;
                break :blk std.math.add(usize, framed, samples) catch null;
            } else null;
            const row_copies = std.math.mul(
                usize,
                samples,
                if (interlaced) 2 else 1,
            ) catch return error.WorkBudgetExceeded;
            const row_fixed = std.math.add(
                usize,
                encoded_bytes,
                raster_work,
            ) catch return error.WorkBudgetExceeded;
            const row_work = std.math.add(
                usize,
                row_fixed,
                row_copies,
            ) catch return error.WorkBudgetExceeded;
            const twice_filtered = std.math.mul(usize, header.filtered_byte_count, 2) catch null;
            return .{
                .header = header,
                .rectangle = rectangle,
                .requirements = .{
                    .encoded_bytes = encoded_bytes,
                    .raster = raster_cost,
                    .pixels = pixels_count,
                    .samples = samples,
                    .output_bytes = output_bytes,
                    .row_samples = @as(usize, rectangle.width) * 4,
                    .reconstruction_samples = if (interlaced) samples else 0,
                    .reconstruction_bytes = if (interlaced) output_bytes else 0,
                    .region_fixed_work_units = region_fixed,
                    .row_fixed_work_units = row_work,
                    .minimum_region_work_units = if (region_fixed != null and twice_filtered !=
                        null) std.math.add(
                        usize,
                        region_fixed.?,
                        twice_filtered.?,
                    ) catch null else null,
                    .minimum_row_work_units = std.math.add(
                        usize,
                        row_work,
                        header.filtered_byte_count,
                    ) catch return error.WorkBudgetExceeded,
                },
            };
        }

        /// Copies the selected part of a complete pass-local converted row into a tight crop. All
        /// samples have already been validated. The destination is an admitted full crop, disjoint
        /// from conversion backing; no unselected output capacity is touched.
        pub fn scatter(self: Self, row: raster.Decoder(Sample).Row, destination: []Sample) void {
            const rectangle = self.rectangle;
            if (row.y < rectangle.y or row.y - rectangle.y >= rectangle.height) return;
            const y = @as(usize, row.y - rectangle.y);
            const first_column = if (rectangle.x <= row.first_x) 0 else @min(
                row.width,
                (@as(usize, rectangle.x - row.first_x) + row.step_x - 1) / row.step_x,
            );
            const limit = rectangle.x + rectangle.width;
            const after_column = if (limit <= row.first_x) 0 else @min(
                row.width,
                (@as(usize, limit - row.first_x) + row.step_x - 1) / row.step_x,
            );
            for (first_column..after_column) |column| {
                const x = @as(usize, row.first_x) + column * row.step_x;
                const selected_x = x - rectangle.x;
                const offset = (y * rectangle.width + selected_x) * 4;
                @memcpy(destination[offset..][0..4], row.texels[column * 4 ..][0..4]);
            }
        }
    };
}

/// Tight RGBA crop borrowing the caller's destination, with copied source facts. Its texels stay
/// valid until that destination is reused or released; no cleanup is required.
pub fn View(comptime Sample: type) type {
    return struct {
        /// Selected logical width in source-grid pixels.
        width: u32,
        /// Selected logical height, or one for a delivered row.
        height: u32,
        /// Copied source dimensions, sample precision and metadata presence, before cropping.
        source_header: Header,
        /// Exactly width*height*4 byte or native-word samples in caller storage.
        texels: []Sample,
    };
}

/// Reports source traversal, selected output, required backing and fixed/minimum work. Structural
/// admission checks all chunk CRCs; pixel/inflation validity remains separate.
pub fn requirements(
    comptime Sample: type,
    source: []const u8,
    rectangle: ImageRegion,
    options: Options,
) Error!Requirements {
    return (try admit(source, options)).regionRequirements(Sample, rectangle, options);
}

/// Computes requirements for an admitted source, retaining its source/capacity admission checks.
pub fn admittedRequirements(
    comptime Sample: type,
    image: SourceImage,
    rectangle: ImageRegion,
    policy: Options,
) Error!Requirements {
    try admitImage(image, policy);
    const Selection = Plan(Sample);
    return (try Selection.init(
        image.header(),
        rectangle,
        image.image_data.source.len,
        policy.limits,
    )).requirements;
}

/// Publishes a complete selected byte/word crop transactionally, with no heap allocation. Source,
/// storage and destination stay disjoint/live and source immutable through both passes. All
/// reported errors preserve destination including unused capacity. Private backing may change.
pub fn into(
    comptime Sample: type,
    source: []const u8,
    rectangle: ImageRegion,
    destination: []Sample,
    storage: Storage(Sample),
    options: Options,
) Error!View(Sample) {
    const image = try admit(source, options);
    return image.decodeRegionInto(Sample, rectangle, destination, storage, options);
}

/// Performs the crop transaction for an admitted static/default or APNG frame-local source. The
/// palette and payload ranges stay admitted and unchanged. Complete source bytes still charge
/// framing work; source extent/byte caps and selected output/work limits apply independently.
pub fn admittedInto(
    comptime Sample: type,
    image: SourceImage,
    rectangle: ImageRegion,
    destination: []Sample,
    storage: Storage(Sample),
    options: Options,
) Error!View(Sample) {
    try admitImage(image, options);
    const limits = options.limits;
    const Selection = Plan(Sample);
    const plan = try Selection.init(image.header(), rectangle, image.image_data.source.len, limits);
    const fixed = plan.requirements.region_fixed_work_units orelse return error.WorkBudgetExceeded;
    try png_format.admitWork(limits, fixed);
    if (destination.len < plan.requirements.samples) return error.DestinationTooSmall;
    // Reserve both identical inflation passes before validation can publish any output.
    const inflate_budget = (limits.maximum_work_units - fixed) / 2;
    var reader = try raster.PassRowReader(
        Sample,
    ).init(image, storage, inflate_budget, options.palette_index_policy);
    while (try reader.next()) |_| {}
    reader.reset();
    while (reader.next() catch unreachable) |row| plan.scatter(
        row,
        destination[0..plan.requirements.samples],
    );
    return view(
        Sample,
        plan.header,
        rectangle.width,
        rectangle.height,
        destination[0..plan.requirements.samples],
    );
}

/// Rechecks complete-source bounds and structural usage against a new operation policy.
pub fn admitImage(image: SourceImage, options: Options) Error!void {
    if (image.image_data.source.len > options.maximum_encoded_bytes)
        return error.EncodedBudgetExceeded;
    if (image.canvas_width > options.maximum_source_extent or image.canvas_height > options
        .maximum_source_extent) return error.InvalidPng;
    if (image.record_count > options.limits.maximum_records or image.metadata_bytes > options.limits
        .maximum_metadata_bytes) return error.MetadataLimitExceeded;
}

pub fn admit(source: []const u8, options: Options) Error!SourceImage {
    if (source.len > options.maximum_encoded_bytes) return error.EncodedBudgetExceeded;
    try png_format.admitWork(options.limits, source.len);
    return SourceImage.open(
        source,
        .{
            .maximum_source_extent = options.maximum_source_extent,
            .maximum_records = options.limits.maximum_records,
            .maximum_metadata_bytes = options.limits.maximum_metadata_bytes,
        },
    );
}

pub fn view(
    comptime Sample: type,
    header: Header,
    width: u32,
    height: u32,
    texels: []Sample,
) View(Sample) {
    return .{ .width = width, .height = height, .source_header = header, .texels = texels };
}

const raster_fixtures = png_raster_vectors;

test "PNG crops match independent all-filter and Adam7 byte word samples" {
    const fixtures = raster_fixtures;
    const allocator = std.testing.allocator;
    const workspace = try deflate.DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.alloc(u8, raster.history_bytes + 3);
    defer allocator.free(history);
    inline for (.{ u8, u16 }) |Sample| {
        const guard: Sample = if (Sample == u8) 0xa5 else 0xa5a5;
        const pictures = [_]struct {
            source: []const u8,
            height: u32,
            expected: []const Sample,
        }{
            .{
                .source = fixtures.sequential_png,
                .height = 5,
                .expected = if (Sample == u8) &fixtures.sequential_rgba8 else &fixtures
                    .sequential_rgba16,
            },
            .{
                .source = fixtures.adam7_png,
                .height = 3,
                .expected = if (Sample == u8) &fixtures.adam7_rgba8 else &fixtures.adam7_rgba16,
            },
        };
        for (pictures) |picture| {
            for (0..picture.height) |y| for (0..3) |x| {
                for (1..picture.height - y + 1) |height| for (1..3 - x + 1) |width| {
                    const rectangle: ImageRegion = .{
                        .x = @intCast(x),
                        .y = @intCast(y),
                        .width = @intCast(width),
                        .height = @intCast(height),
                    };
                    const plan = try requirements(Sample, picture.source, rectangle, .{});
                    try std.testing.expectEqual(3 * picture.height, plan.raster.source_pixels);
                    try std.testing.expectEqual(width * height, plan.pixels);
                    try std.testing.expectEqual(8, plan.raster.packed_rows_bytes);
                    try std.testing.expectEqual(12, plan.raster.conversion_row_samples);
                    var packed_rows: [11]u8 = @splat(0xa5);
                    var conversion: [15]Sample = @splat(guard);
                    var reconstruction: [63]Sample = @splat(guard);
                    var destination: [63]Sample = @splat(guard);
                    var band: [15]Sample = @splat(guard);
                    @memset(history, 0xa5);
                    const storage: Storage(
                        Sample,
                    ) = .{
                        .workspace = workspace,
                        .history = history,
                        .packed_rows = &packed_rows,
                        .conversion_row = &conversion,
                    };
                    const image = try into(
                        Sample,
                        picture.source,
                        rectangle,
                        &destination,
                        storage,
                        .{},
                    );
                    try std.testing.expectEqual(width, image.width);
                    try std.testing.expectEqual(height, image.height);
                    try std.testing.expectEqual(plan.samples, image.texels.len);
                    for (0..height) |row| {
                        const expected_offset = ((y + row) * 3 + x) * 4;
                        try std.testing.expectEqualSlices(
                            Sample,
                            picture.expected[expected_offset..][0 .. width * 4],
                            image.texels[row * width * 4 ..][0 .. width * 4],
                        );
                    }
                    for (
                        destination[plan.samples..],
                    ) |value| try std.testing.expectEqual(guard, value);
                    for (
                        packed_rows[plan.raster.packed_rows_bytes..],
                    ) |value| try std.testing.expectEqual(0xa5, value);
                    for (
                        conversion[plan.raster.conversion_row_samples..],
                    ) |value| try std.testing.expectEqual(guard, value);
                    for (
                        history[raster.history_bytes..],
                    ) |value| try std.testing.expectEqual(0xa5, value);
                    var rows = try row_reading.RowReader(
                        Sample,
                    ).init(picture.source, rectangle, storage, &reconstruction, .{});
                    while (try rows.read(&band)) |_| {}
                    const actual_work = rows.workUnits();
                    const inflate_work = actual_work - plan.row_fixed_work_units;
                    var limited: Options = .{};
                    limited.limits.maximum_scratch_bytes = 0;
                    limited.limits.maximum_pixels = plan.pixels;
                    limited.limits.maximum_output_bytes = plan.output_bytes;
                    limited.limits.maximum_work_units = plan.region_fixed_work_units.? +
                        inflate_work * 2;
                    _ = try into(Sample, picture.source, rectangle, &destination, storage, limited);
                    limited.limits.maximum_work_units -= 1;
                    @memset(&destination, guard);
                    try std.testing.expectError(
                        error.WorkBudgetExceeded,
                        into(Sample, picture.source, rectangle, &destination, storage, limited),
                    );
                    for (destination) |value| try std.testing.expectEqual(guard, value);
                };
            };
        }
    }
}

test "PNG unselected palette failure preserves whole crop destinations" {
    const fixtures = raster_fixtures;
    const allocator = std.testing.allocator;
    const workspace = try deflate.DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.alloc(u8, raster.history_bytes);
    defer allocator.free(history);
    inline for (.{ u8, u16 }) |Sample| {
        const guard: Sample = if (Sample == u8) 0xa5 else 0xa5a5;
        var packed_rows: [8]u8 = undefined;
        var conversion: [12]Sample = undefined;
        var destination: [7]Sample = @splat(guard);
        const storage: Storage(
            Sample,
        ) = .{
            .workspace = workspace,
            .history = history,
            .packed_rows = &packed_rows,
            .conversion_row = &conversion,
        };
        const rectangle: ImageRegion = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
        try std.testing.expectError(
            error.InvalidPng,
            into(
                Sample,
                fixtures.invalid_palette_png,
                rectangle,
                &destination,
                storage,
                .{ .palette_index_policy = .reject },
            ),
        );
        for (destination) |value| try std.testing.expectEqual(guard, value);
    }
}

const palette_fixtures = png_palette_vectors;

test "PNG palette recovery applies outside crops" {
    const fixtures = palette_fixtures;
    const allocator = std.testing.allocator;
    const workspace = try deflate.DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.alloc(u8, raster.history_bytes);
    defer allocator.free(history);
    const rectangle: ImageRegion = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    inline for (.{ u8, u16 }) |Sample| {
        const guard: Sample = if (Sample == u8) 0xa5 else 0xa5a5;
        const expected: []const Sample = if (Sample == u8) &.{
            13, 29, 47, 17,
        } else &.{ 3341, 7453, 12079, 4369 };
        var packed_rows: [39]u8 = @splat(0xa5);
        var conversion: [71]Sample = @splat(guard);
        const backing: Storage(
            Sample,
        ) = .{
            .workspace = workspace,
            .history = history,
            .packed_rows = &packed_rows,
            .conversion_row = &conversion,
        };
        for (fixtures.sources) |wire| {
            var output: [7]Sample = @splat(guard);
            // The selected pixel is valid; an absent index elsewhere still fails strictly.
            try std.testing.expectError(
                error.InvalidPng,
                into(
                    Sample,
                    wire,
                    rectangle,
                    &output,
                    backing,
                    .{ .palette_index_policy = .reject },
                ),
            );
            for (output) |value| try std.testing.expectEqual(guard, value);
            const result = try into(
                Sample,
                wire,
                rectangle,
                output[1..],
                backing,
                .{ .palette_index_policy = .opaque_black },
            );
            try std.testing.expectEqualSlices(Sample, expected, result.texels);
            try std.testing.expectEqual(guard, output[0]);
            for (output[5..]) |value| try std.testing.expectEqual(guard, value);
            for (packed_rows[36..]) |value| try std.testing.expectEqual(0xa5, value);
            for (conversion[68..]) |value| try std.testing.expectEqual(guard, value);
        }
        var output: [7]Sample = @splat(guard);
        try std.testing.expectError(
            error.InvalidPng,
            into(
                Sample,
                fixtures.bad_filter,
                rectangle,
                &output,
                backing,
                .{ .palette_index_policy = .opaque_black },
            ),
        );
        for (output) |value| try std.testing.expectEqual(guard, value);
    }
}
