//! Complete-source selected-row decoding; input stays borrowed through the session.

const std = @import("std");
const deflate = @import("../deflate.zig");
const png_raster_vectors = @import("testdata/raster.zig");
const png_palette_vectors = @import("testdata/palette.zig");
const png_format = @import("format.zig");
const SourceImage = @import("Source.zig");
const ImageRegion = @import("../common/ImageRegion.zig");
const raster = @import("raster_decoder.zig");
const regions = @import("region_decode.zig");
const backing = @import("decode_workspace.zig");
const Error = regions.Error;
const Options = regions.Options;
const Requirements = regions.Requirements;
const Storage = backing.Storage;

/// Starts rows over an admitted source; Source.rowReader owns the public operation.
pub fn fromSource(
    comptime Sample: type,
    image: SourceImage,
    rectangle: ImageRegion,
    storage: Storage(Sample),
    reconstruction: []Sample,
    options: Options,
) Error!RowReader(Sample) {
    try regions.admitImage(image, options);
    const limits = options.limits;
    const RegionPlan = regions.Plan(Sample);
    const region_plan = try RegionPlan.init(
        image.header(),
        rectangle,
        image.image_data.source.len,
        limits,
    );
    try png_format.admitWork(limits, region_plan.requirements.minimum_row_work_units);
    if (reconstruction.len < region_plan.requirements.reconstruction_samples)
        return error.ReconstructionTooSmall;
    return .{
        .requirements = region_plan.requirements,
        .region_plan = region_plan,
        .raster_reader = try raster.PassRowReader(
            Sample,
        ).init(
            image,
            storage,
            limits.maximum_work_units - region_plan.requirements.row_fixed_work_units,
            options.palette_index_policy,
        ),
        .reconstruction = reconstruction[0..region_plan.requirements.reconstruction_samples],
    };
}

/// Movable row reader over a complete source. Keep source and palettes unchanged and all backing
/// live and disjoint until the reader is retired. Capacity failures are retryable; raster/policy
/// failures persist until reset. Under `.reject`, absent indices outside the selection still fail.
/// Adam7 retains only the selected reconstruction backing reported by requirements, not a full
/// source image.
pub fn RowReader(comptime Sample: type) type {
    return struct {
        const Self = @This();

        /// One complete selected row in ascending crop-relative order.
        pub const Row = struct {
            /// Crop-relative top-left coordinate of this one-row image.
            row_index: u32,
            /// Borrows only the read call's destination; copy before reusing its backing.
            image: regions.View(Sample),
        };

        /// Copied selected/session cost admitted at construction; do not modify during use.
        requirements: Requirements,
        /// Complete crop rows delivered so far; inspect but do not modify.
        produced_rows: u32 = 0,
        /// Internal selected geometry; do not modify while reading.
        region_plan: regions.Plan(Sample),
        /// Internal source traversal and raster decoder.
        raster_reader: raster.PassRowReader(Sample),
        /// Internal borrow of the selected Adam7 reconstruction backing.
        reconstruction: []Sample,
        /// Whether interlaced reconstruction has completed.
        reconstructed: bool = false,
        /// Internal reader state; change it only through reader methods.
        phase: enum { active, done, failed, canceled } = .active,
        /// Persistent failure cause, or null until the reader fails.
        failure: ?Error = null,

        /// Admits complete PNG structure, selected output and backing before row traversal.
        /// Sequential input requires no reconstruction backing; Adam7 uses the exact crop prefix.
        pub fn init(
            source: []const u8,
            rectangle: ImageRegion,
            storage: Storage(Sample),
            reconstruction: []Sample,
            options: Options,
        ) Error!Self {
            const image = try regions.admit(source, options);
            return fromSource(Sample, image, rectangle, storage, reconstruction, options);
        }

        /// Publishes at most one complete row, preserving current destination on failure. Call
        /// through null even after the last selected row so unselected trailing rows, checksum and
        /// complete filtered length are accepted. Capacity shortage advances nothing.
        pub fn read(self: *Self, destination: []Sample) Error!?Row {
            switch (self.phase) {
                .done => return null,
                .failed => return self.failure.?,
                .canceled => return error.RowReaderCanceled,
                .active => {},
            }
            if (destination.len < self.requirements.row_samples) return error.DestinationTooSmall;
            const rectangle = self.region_plan.rectangle;
            if (self.region_plan.header.interlace_method != 0) {
                if (!self.reconstructed) {
                    while (self.raster_reader.next() catch |err| return self.fail(
                        err,
                    )) |row| self.region_plan.scatter(row, self.reconstruction);
                    self.reconstructed = true;
                }
                if (self.produced_rows == rectangle.height) {
                    self.phase = .done;
                    return null;
                }
                const first = self.produced_rows;
                const begin = @as(usize, first) * self.requirements.row_samples;
                @memcpy(
                    destination[0..self.requirements.row_samples],
                    self.reconstruction[begin..][0..self.requirements.row_samples],
                );
                self.produced_rows += 1;
                return .{
                    .row_index = first,
                    .image = regions.view(
                        Sample,
                        self.region_plan.header,
                        rectangle.width,
                        1,
                        destination[0..self.requirements.row_samples],
                    ),
                };
            }
            while (self.raster_reader.next() catch |err| return self.fail(err)) |row| {
                if (row.y < rectangle.y or row.y - rectangle.y >= rectangle.height) continue;
                const first = row.y - rectangle.y;
                const begin = @as(usize, rectangle.x) * 4;
                @memcpy(
                    destination[0..self.requirements.row_samples],
                    row.texels[begin..][0..self.requirements.row_samples],
                );
                self.produced_rows += 1;
                return .{
                    .row_index = first,
                    .image = regions.view(
                        Sample,
                        self.region_plan.header,
                        rectangle.width,
                        1,
                        destination[0..self.requirements.row_samples],
                    ),
                };
            }
            self.phase = .done;
            return null;
        }

        /// Full fixed admission plus generic charges so far; at done this is total session work.
        pub fn workUnits(self: Self) usize {
            return self.requirements.row_fixed_work_units + self.raster_reader.decoder
                .inflationWork();
        }

        /// Stops until reset without changing backing or already copied rows.
        pub fn cancel(self: *Self) void {
            self.phase = .canceled;
        }

        /// Restarts unchanged source/selection/backing/policy without clearing reserved bytes.
        pub fn reset(self: *Self) void {
            self.raster_reader.reset();
            self.produced_rows = 0;
            self.reconstructed = false;
            self.phase = .active;
            self.failure = null;
        }

        fn fail(self: *Self, failure: Error) Error {
            self.phase = .failed;
            self.failure = failure;
            return failure;
        }
    };
}

const raster_fixtures = png_raster_vectors;
const palette_fixtures = png_palette_vectors;

test "PNG row reader matches independent all-filter and Adam7 byte word crops" {
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
                    const plan = try regions.requirements(Sample, picture.source, rectangle, .{});
                    try std.testing.expectEqual(3 * picture.height, plan.raster.source_pixels);
                    try std.testing.expectEqual(width * height, plan.pixels);
                    try std.testing.expectEqual(8, plan.raster.packed_rows_bytes);
                    try std.testing.expectEqual(12, plan.raster.conversion_row_samples);
                    var packed_rows: [11]u8 = @splat(0xa5);
                    var conversion: [15]Sample = @splat(guard);
                    var reconstruction: [63]Sample = @splat(guard);
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
                    var rows = try RowReader(
                        Sample,
                    ).init(picture.source, rectangle, storage, &reconstruction, .{});
                    try std.testing.expectError(
                        error.DestinationTooSmall,
                        rows.read(band[0 .. plan.row_samples - 1]),
                    );
                    try std.testing.expectEqual(0, rows.produced_rows);
                    var next_row: usize = 0;
                    while (try rows.read(&band)) |row| {
                        try std.testing.expectEqual(next_row, row.row_index);
                        try std.testing.expectEqualSlices(
                            Sample,
                            picture.expected[((y + next_row) * 3 + x) * 4 ..][0..plan.row_samples],
                            row.image.texels,
                        );
                        for (
                            band[plan.row_samples..],
                        ) |value| try std.testing.expectEqual(guard, value);
                        next_row += 1;
                    }
                    try std.testing.expectEqual(height, next_row);
                    for (
                        reconstruction[plan.reconstruction_samples..],
                    ) |value| try std.testing.expectEqual(guard, value);
                    const actual_work = rows.workUnits();
                    var limited: Options = .{};
                    limited.limits.maximum_scratch_bytes = 0;
                    limited.limits.maximum_pixels = plan.pixels;
                    limited.limits.maximum_output_bytes = plan.output_bytes;
                    limited.limits.maximum_work_units = actual_work;
                    var exact = try RowReader(
                        Sample,
                    ).init(picture.source, rectangle, storage, &reconstruction, limited);
                    while (try exact.read(&band)) |_| {}
                    try std.testing.expectEqual(actual_work, exact.workUnits());
                    rows.cancel();
                    try std.testing.expectError(error.RowReaderCanceled, rows.read(&band));
                    rows.reset();
                    try std.testing.expectEqual(0, rows.produced_rows);
                    try std.testing.expectEqual(0, (try rows.read(&band)).?.row_index);
                };
            };
        }
    }
}

test "PNG row reader preserves destination on unselected palette failure" {
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
        var rows = try RowReader(
            Sample,
        ).init(
            fixtures.invalid_palette_png,
            rectangle,
            storage,
            &.{},
            .{ .palette_index_policy = .reject },
        );
        const first = (try rows.read(&destination)).?;
        const expected: [4]Sample = if (Sample == u8) .{
            1, 2, 3, 17,
        } else .{ 257, 514, 771, 4369 };
        try std.testing.expectEqualSlices(Sample, &expected, first.image.texels);
        @memset(&destination, guard);
        try std.testing.expectError(error.InvalidPng, rows.read(&destination));
        try std.testing.expectError(error.InvalidPng, rows.read(&destination));
        for (destination) |value| try std.testing.expectEqual(guard, value);
        rows.reset();
        try std.testing.expectEqual(0, (try rows.read(&destination)).?.row_index);
    }
}

test "PNG row palette recovery survives byte word row reset" {
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
        var reconstruction: [7]Sample = @splat(guard);
        const storage: Storage(
            Sample,
        ) = .{
            .workspace = workspace,
            .history = history,
            .packed_rows = &packed_rows,
            .conversion_row = &conversion,
        };
        for (fixtures.sources) |wire| {
            var output: [7]Sample = @splat(guard);
            var rows = try RowReader(
                Sample,
            ).init(
                wire,
                rectangle,
                storage,
                &reconstruction,
                .{ .palette_index_policy = .opaque_black },
            );
            for (0..2) |_| {
                @memset(&output, guard);
                const row = (try rows.read(output[1..])).?;
                try std.testing.expectEqualSlices(Sample, expected, row.image.texels);
                try std.testing.expectEqual(null, try rows.read(output[1..]));
                try std.testing.expectEqual(guard, output[0]);
                for (output[5..]) |value| try std.testing.expectEqual(guard, value);
                rows.reset();
            }
            for (packed_rows[36..]) |value| try std.testing.expectEqual(0xa5, value);
            for (conversion[68..]) |value| try std.testing.expectEqual(guard, value);
            for (reconstruction[4..]) |value| try std.testing.expectEqual(guard, value);
        }
    }
}
