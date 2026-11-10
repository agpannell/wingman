//! APNG controls and native frame encoding through shared PNG writers.

const MetadataInput = @import("metadata.zig").Metadata.Input;
const ImageInput = @import("ImageInput.zig");
const AnimationInput = @import("AnimationInput.zig");
const FrameControl = @import("FrameControl.zig");
const std = @import("std");
const png_encoding_vectors = @import("testdata/encoding.zig");
const format = @import("format.zig");
const zlib = @import("../zlib.zig");
const raster_encoding = @import("raster_encode.zig");
const encoding_metadata = @import("metadata_encode.zig");
const animation = @import("animation.zig");
const chunks = @import("ChunkWriter.zig");
const Limits = @import("Limits.zig");

const EncoderWorkspace = @import("encode_workspace.zig").Workspace;

const Samples = format.Samples;
const Transparency = format.Transparency;
pub const Filter = @import("scanline_filters.zig").Filter;
pub const Interlace = format.Interlace;

/// Filtering, compression, animation framing, metadata and resource policy.
pub const Options = struct {
    /// One fixed byte predictor or minimum signed-byte adaptive selection for every raster;
    /// defaults to adaptive.
    filter: Filter = .adaptive,
    /// Shared compression options for each raster and selected compressed metadata; defaults to
    /// level 6 with automatic lookahead. A newly assigned Compression defaults to full lookahead.
    compression: zlib.Compression = .{ .level = 6, .lazy_lookahead = .automatic },
    /// Traversal shared by all rasters; defaults to sequential. Each raster and Adam7 pass starts
    /// fresh filter history.
    interlace: Interlace = .none,
    /// Typed file-wide declarations emitted before PLTE and all image data.
    metadata: MetadataInput = .{},
    /// Maximum frame count independently of structural chunk count; defaults to 4096.
    maximum_frames: u32 = 4096,
    /// Maximum compressed bytes per IDAT/fdAT chunk, excluding the fdAT sequence word. Positive and
    /// at most 2^31-5; default 64 KiB. Each final partial chunk is shortened.
    data_chunk_bytes: usize = 64 * 1024,
    /// Pixels count all local frames plus an excluded poster once. Work budgets up to two raster
    /// serialization/filter passes, one palette-index scan and metadata's own work. Records include
    /// every data/control chunk and profile/TIFF record; metadata includes headers, controls, fdAT
    /// sequence words and selected raw/encoded ancillary payloads. DEFLATE match search is
    /// controlled by the compression method, not this work limit. Scratch counts the largest live
    /// requested span. Actual output bytes are admitted exactly.
    limits: Limits = .{},
};

/// Source shape, format, metadata, resource, allocation and bounded emission failures.
pub const Error = raster_encoding.Error || encoding_metadata.Error || Limits.Error || error{
    InvalidFrameCount,
    FrameLimitExceeded,
    InvalidFrameRectangle,
    InvalidDefaultFrame,
    InvalidPlayCount,
    InvalidDataChunkSize,
    SequenceOverflow,
};

const Admission = struct {
    canvas: ImageInput,
    pixels: usize = 0,
    work_units: usize = 0,
    base_records: usize,
    base_metadata: usize,
    base_bytes: usize,
    streams: usize,
    frame_data_stream_count: usize,

    /// Validates one raster against shared pixel/work budgets and its scratch limit.
    fn admitRaster(
        self: *Admission,
        image: ImageInput,
        policy: raster_encoding.Options,
        limits: Limits,
    ) Error!void {
        const layout = try raster_encoding.describe(image, policy);
        self.pixels = try add(self.pixels, layout.pixels);
        self.work_units = try add(self.work_units, layout.work_units);
        try format.admitOutput(limits, self.pixels, self.base_bytes);
        try format.admitWork(limits, self.work_units);
        if (layout.scratch_bytes > limits.maximum_scratch_bytes) return error.ScratchBudgetExceeded;
        try raster_encoding.validateIndices(image, layout);
    }
};

const Sizing = struct {
    bytes: usize = 0,
    records: usize = 0,
    frame_data_record_count: usize = 0,

    /// Compresses one raster to measure its actual framed bytes and chunk count.
    fn countRaster(
        self: *Sizing,
        image: ImageInput,
        frame_data: bool,
        policy: raster_encoding.Options,
        options: Options,
        scratch_allocator: std.mem.Allocator,
    ) Error!void {
        const layout = try raster_encoding.describe(image, policy);
        // Count the complete compressed stream without retaining it. Emission replays the same
        // immutable raster after output and chunk-record limits have been admitted.
        var buffer: [64]u8 = undefined;
        var counter: std.Io.Writer.Discarding = .init(&buffer);
        try raster_encoding.compressRows(&counter.writer, image, layout, policy, scratch_allocator);
        const compressed_bytes = std.math.cast(
            usize,
            counter.fullCount(),
        ) orelse return error.SizeOverflow;
        const count = try chunks.dataRecordCount(
            compressed_bytes,
            options.data_chunk_bytes,
            frame_data,
        );
        self.records = try add(self.records, count);
        if (frame_data) self.frame_data_record_count = try add(self.frame_data_record_count, count);
        self.bytes = try add(
            self.bytes,
            try add(compressed_bytes, try mul(count, if (frame_data) 16 else 12)),
        );
        try format.admitOutput(options.limits, 0, self.bytes);
        if (self.records > options.limits.maximum_records) return error.MetadataLimitExceeded;
    }
};

/// Conservative complete APNG output capacity and exact shared encoder backing requirements.
pub const Requirements = struct {
    /// Conservative complete output capacity, including controls, metadata and data chunks.
    output_bytes: usize,
    /// Required state/alignment and three largest full-width row slots.
    workspace_bytes: usize,
    /// Row bytes supplied to encode.Workspace.initBuffer or initCapacity.
    workspace_extra_bytes: usize,
    /// Exact filtered bytes across the optional poster and every local frame.
    filtered_bytes: usize,
};

const PreparedAnimation = struct {
    admitted: Admission,
    metadata: encoding_metadata.Prepared,
    policy: raster_encoding.Options,
    requirements: Requirements,
};

/// Reports checked capacities without allocating or compressing. Validates all source rasters,
/// controls and metadata. Capacity bounds do not replace actual output/record/metadata admission.
pub fn requirements(image: AnimationInput, options: Options) Error!Requirements {
    return (try prepareAnimation(image, options)).requirements;
}

fn prepareAnimation(image: AnimationInput, options: Options) Error!PreparedAnimation {
    const policy: raster_encoding.Options = .{
        .filter = options.filter,
        .compression = options.compression,
        .interlace = options.interlace,
    };
    const admitted = try admit(image, policy, options);

    // Admission reserved one data record per stream and one sequence word per fdAT stream, so these
    // minimum framing costs can be removed before preparing optional metadata.
    var metadata_limits = options.limits;
    metadata_limits.maximum_records -= admitted.base_records + admitted.streams;
    metadata_limits.maximum_metadata_bytes -= admitted.base_metadata + admitted
        .frame_data_stream_count * 4;
    metadata_limits.maximum_work_units -= admitted.work_units;
    const metadata = try encoding_metadata.prepare(
        options.metadata,
        @backingInt(image.color_type),
        image.bit_depth,
        metadata_limits,
    );
    var wire_bound: usize = 0;
    var filtered_bytes: usize = 0;
    if (image.poster != null) try addRasterBound(
        &wire_bound,
        &filtered_bytes,
        admitted.canvas,
        false,
        policy,
        options.data_chunk_bytes,
    );
    for (
        image.frames,
        0..,
    ) |frame, index| try addRasterBound(
        &wire_bound,
        &filtered_bytes,
        frameImage(image, frame),
        image.poster != null or index != 0,
        policy,
        options.data_chunk_bytes,
    );
    const layout = try raster_encoding.describe(admitted.canvas, policy);
    return .{
        .admitted = admitted,
        .metadata = metadata,
        .policy = policy,
        .requirements = .{
            .output_bytes = try add(
                try add(admitted.base_bytes, wire_bound),
                try metadata.capacityBound(),
            ),
            .workspace_bytes = layout.scratch_bytes,
            .workspace_extra_bytes = try mul(try add(layout.row_bytes, 1), 3),
            .filtered_bytes = filtered_bytes,
        },
    };
}

fn addRasterBound(
    wire_bound: *usize,
    filtered_bytes: *usize,
    image: ImageInput,
    frame_data: bool,
    policy: raster_encoding.Options,
    chunk_bytes: usize,
) Error!void {
    const layout = try raster_encoding.describe(image, policy);
    const filtered = format.packedLayout(
        image.width,
        image.height,
        layout.bits_per_pixel,
        @backingInt(policy.interlace),
    ) catch return error.SizeOverflow;
    const compressed_byte_bound = try zlib.encodeBound(filtered.filtered_bytes, .{});
    const records = try chunks.dataRecordCount(compressed_byte_bound, chunk_bytes, frame_data);
    wire_bound.* = try add(
        wire_bound.*,
        try add(compressed_byte_bound, try mul(records, if (frame_data) 16 else 12)),
    );
    filtered_bytes.* = try add(filtered_bytes.*, filtered.filtered_bytes);
}

/// Encodes complete local frames once into reserved output using one reused workspace. Source,
/// workspace and output stay disjoint; no allocation or retained borrow occurs. Capacity and
/// workspace shortages precede writes. Later errors may leave an unpublished prefix. Success
/// preserves unused output. Actual encoded bytes, sequences and metadata enforce resource limits.
pub fn into(
    image: AnimationInput,
    destination: []u8,
    workspace: EncoderWorkspace,
    options: Options,
) Error![]u8 {
    const prepared = try prepareAnimation(image, options);
    const admitted = prepared.admitted;
    const required = prepared.requirements;
    if (destination.len < required.output_bytes) return error.OutputTooSmall;
    if (workspace.extra.len < required.workspace_extra_bytes) return error.WorkspaceTooSmall;
    const output = destination[0..required.output_bytes];
    @memcpy(output[0..8], format.signature);
    var offset: usize = 8;
    try raster_encoding.writeHeader(output, &offset, admitted.canvas, options.interlace);
    const metadata_start = offset;
    offset += try prepared.metadata.writeInto(output[offset..], workspace, options.compression);
    const metadata_payload = chunks.payloadByteCount(output[metadata_start..offset]);
    try raster_encoding.writePaletteAndTransparency(output, &offset, admitted.canvas);
    var actl: [8]u8 = undefined;
    std.mem.writeInt(u32, actl[0..4], @intCast(image.frames.len), .big);
    std.mem.writeInt(u32, actl[4..8], image.play_count, .big);
    try chunks.append(output, &offset, "acTL", &actl);
    var sequence: u64 = 0;
    var records: usize = 0;
    var frame_data_record_count: usize = 0;
    const raster_output = output[0 .. output.len - 12];
    if (image.poster != null) {
        const result = try writeRaster(
            raster_output,
            &offset,
            admitted.canvas,
            null,
            prepared.policy,
            options,
            .{ .prepared = workspace },
        );
        records = result.records;
    }
    for (image.frames, 0..) |frame, index| {
        try writeControl(output, &offset, frame, try chunks.nextSequence(&sequence));
        const result = try writeRaster(
            raster_output,
            &offset,
            frameImage(image, frame),
            if (image.poster != null or index != 0) &sequence else null,
            prepared.policy,
            options,
            .{ .prepared = workspace },
        );
        records = try add(records, result.records);
        frame_data_record_count = try add(frame_data_record_count, result.frame_data_record_count);
    }
    try chunks.appendEnd(output, &offset);
    records = try add(try add(admitted.base_records, records), prepared.metadata.record_count);
    const structural_metadata = try add(
        admitted.base_metadata,
        try mul(frame_data_record_count, 4),
    );
    if (records > options.limits.maximum_records or structural_metadata > options.limits
        .maximum_metadata_bytes) return error.MetadataLimitExceeded;
    const metadata_left = options.limits.maximum_metadata_bytes - structural_metadata;
    if (prepared.metadata.source_bytes > metadata_left or metadata_payload > metadata_left)
        return error.MetadataLimitExceeded;
    try format.admitOutput(options.limits, admitted.pixels, offset);
    return output[0..offset];
}

/// Returns an exact-size owned APNG using one authority for output and call-local scratch. The
/// caller frees returned bytes with allocator; no source or allocator is retained.
pub fn alloc(allocator: std.mem.Allocator, image: AnimationInput, options: Options) Error![]u8 {
    return allocWithScratch(allocator, allocator, image, options);
}

test alloc {
    const allocator = std.testing.allocator;
    const frames = [_]AnimationInput.Frame{
        .{
            .width = 1,
            .height = 1,
            .samples = .{ .packed_bytes = .{ .bytes = &.{ 255, 0, 0, 255 } } },
            .delay = .{ .numerator = 1, .denominator = 10 },
        },
        .{
            .width = 1,
            .height = 1,
            .samples = .{ .packed_bytes = .{ .bytes = &.{ 0, 0, 255, 255 } } },
            .delay = .{ .numerator = 1, .denominator = 10 },
        },
    };
    const encoded = try alloc(
        allocator,
        .{
            .width = 1,
            .height = 1,
            .color_type = .rgba,
            .bit_depth = 8,
            .frames = &frames,
            .play_count = 1,
        },
        .{},
    );
    defer allocator.free(encoded);

    var decoded = try animation.alloc(u8, allocator, encoded, .{});
    defer decoded.deinit(allocator);
    var player = try animation.Animation(u8).Player.initCapacity(allocator, &decoded, .{});
    defer player.deinit(allocator);
    const first = player.next().?;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, first.pixels);
    try std.testing.expectEqual(10, first.delay.effectiveDenominator());
    // The next call reuses the canvas; inspect or copy each frame before advancing.
    const second = player.next().?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, second.pixels);
    try std.testing.expectEqual(null, player.next());
}

/// Encodes complete native frame rasters and exact controls into one owned APNG. All source
/// admission precedes compression; exact chunk/output admission follows counting. No
/// source/allocator is retained, and failed output remains unpublished and fully released.
pub fn allocWithScratch(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    image: AnimationInput,
    options: Options,
) Error![]u8 {
    const policy: raster_encoding.Options = .{
        .filter = options.filter,
        .compression = options.compression,
        .interlace = options.interlace,
    };
    const admitted = try admit(image, policy, options);
    var metadata_limits = options.limits;
    metadata_limits.maximum_records -= admitted.base_records + admitted.streams;
    metadata_limits.maximum_metadata_bytes -= admitted.base_metadata + admitted
        .frame_data_stream_count * 4;
    metadata_limits.maximum_work_units -= admitted.work_units;
    var prepared_metadata = try encoding_metadata.prepare(
        options.metadata,
        @backingInt(image.color_type),
        image.bit_depth,
        metadata_limits,
    );

    var sizing: Sizing = .{};
    if (image.poster != null) try sizing.countRaster(
        admitted.canvas,
        false,
        policy,
        options,
        scratch_allocator,
    );
    for (image.frames, 0..) |frame, index| {
        try sizing.countRaster(
            frameImage(image, frame),
            image.poster != null or index != 0,
            policy,
            options,
            scratch_allocator,
        );
    }
    const sequences = try add(image.frames.len, sizing.frame_data_record_count);
    if (sequences > 0x80000000) return error.SequenceOverflow;
    const data_records = try add(admitted.base_records, sizing.records);
    const records = try add(data_records, prepared_metadata.record_count);
    const structural_metadata = try add(
        admitted.base_metadata,
        try mul(sizing.frame_data_record_count, 4),
    );
    if (records > options.limits.maximum_records or structural_metadata > options.limits
        .maximum_metadata_bytes or prepared_metadata.source_bytes > options.limits
        .maximum_metadata_bytes - structural_metadata) return error.MetadataLimitExceeded;
    prepared_metadata.maximum_payload_bytes = options.limits.maximum_metadata_bytes -
        structural_metadata;
    const metadata_bytes = try prepared_metadata.encodedSizeWithScratch(
        scratch_allocator,
        options.compression,
    );
    const length = try add(try add(admitted.base_bytes, sizing.bytes), metadata_bytes);
    try format.admitOutput(options.limits, admitted.pixels, length);
    const result = try output_allocator.alloc(u8, length);
    errdefer output_allocator.free(result);

    @memcpy(result[0..8], &[_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a });
    var offset: usize = 8;
    try raster_encoding.writeHeader(result, &offset, admitted.canvas, options.interlace);
    offset += try prepared_metadata.writeIntoWithScratch(
        scratch_allocator,
        result[offset..],
        options.compression,
    );
    try raster_encoding.writePaletteAndTransparency(result, &offset, admitted.canvas);
    var actl: [8]u8 = undefined;
    std.mem.writeInt(u32, actl[0..4], @intCast(image.frames.len), .big);
    std.mem.writeInt(u32, actl[4..8], image.play_count, .big);
    try chunks.append(result, &offset, "acTL", &actl);
    var sequence: u64 = 0;
    if (image.poster != null) _ = try writeRaster(
        result,
        &offset,
        admitted.canvas,
        null,
        policy,
        options,
        .{ .allocator = scratch_allocator },
    );
    for (image.frames, 0..) |frame, index| {
        try writeControl(result, &offset, frame, try chunks.nextSequence(&sequence));
        _ = try writeRaster(
            result,
            &offset,
            frameImage(image, frame),
            if (image.poster != null or index != 0) &sequence else null,
            policy,
            options,
            .{ .allocator = scratch_allocator },
        );
    }
    try chunks.appendEnd(result, &offset);
    std.debug.assert(sequence == sequences and offset == result.len);
    return result;
}

fn admit(image: AnimationInput, policy: raster_encoding.Options, options: Options) Error!Admission {
    try raster_encoding.validateExtent(image.width, image.height);
    if (image.frames.len == 0 or image.frames.len > 0x7fffffff) return error.InvalidFrameCount;
    if (image.frames.len > options.maximum_frames) return error.FrameLimitExceeded;
    if (image.play_count > 0x7fffffff) return error.InvalidPlayCount;
    if (options.data_chunk_bytes == 0 or options.data_chunk_bytes > 0x7ffffffb)
        return error.InvalidDataChunkSize;
    if (image.poster == null) {
        const first = image.frames[0];
        if (first.width != image.width or first.height != image.height or first.x != 0 or first.y !=
            0) return error.InvalidDefaultFrame;
    }
    const canvas: ImageInput = .{
        .width = image.width,
        .height = image.height,
        .color_type = image.color_type,
        .bit_depth = image.bit_depth,
        .palette = image.palette,
        .transparency = image.transparency,
        .samples = image.poster orelse image.frames[0].samples,
    };
    const canvas_layout = try raster_encoding.describe(canvas, policy);

    // IDAT supplies exactly one raster: the poster when present, otherwise frame zero. Every
    // remaining frame uses fdAT, whose chunks each add a sequence word.
    const streams = try add(image.frames.len, @intFromBool(image.poster != null));
    const frame_data_stream_count = image.frames.len - @intFromBool(image.poster == null);

    // The signature, IHDR, acTL and IEND occupy 65 bytes including chunk framing. Each fcTL adds 38
    // bytes including its length, type and CRC.
    var admitted: Admission = .{
        .canvas = canvas,
        .base_records = try add(canvas_layout.minimum_records, image.frames.len),
        .base_metadata = try add(
            try add(canvas_layout.base_metadata_bytes, 8),
            try mul(image.frames.len, 26),
        ),
        .base_bytes = try add(65, try mul(image.frames.len, 38)),
        .streams = streams,
        .frame_data_stream_count = frame_data_stream_count,
    };
    if (image.palette.len != 0) admitted.base_bytes = try add(
        admitted.base_bytes,
        12 + image.palette.len * 3,
    );
    const transparency_bytes = raster_encoding.transparencyByteCount(image.transparency);
    if (transparency_bytes != 0) admitted.base_bytes = try add(
        admitted.base_bytes,
        12 + transparency_bytes,
    );
    if (try add(
        admitted.base_records,
        streams,
    ) > options.limits.maximum_records or try add(
        admitted.base_metadata,
        try mul(frame_data_stream_count, 4),
    ) > options.limits.maximum_metadata_bytes) return error.MetadataLimitExceeded;
    if (image.poster != null) try admitted.admitRaster(canvas, policy, options.limits);
    for (image.frames) |frame| {
        // Check each origin before subtracting it, so an out-of-canvas origin cannot underflow.
        if (frame.width == 0 or frame.height == 0 or frame.x > image.width or frame.y > image
            .height or frame.width > image.width - frame.x or frame.height > image.height - frame.y)
            return error.InvalidFrameRectangle;
        try admitted.admitRaster(frameImage(image, frame), policy, options.limits);
    }
    return admitted;
}

fn frameImage(image: AnimationInput, frame: AnimationInput.Frame) ImageInput {
    return .{
        .width = frame.width,
        .height = frame.height,
        .color_type = image.color_type,
        .bit_depth = image.bit_depth,
        .samples = frame.samples,
        .palette = image.palette,
        .transparency = image.transparency,
    };
}

fn writeControl(
    destination: []u8,
    offset: *usize,
    frame: AnimationInput.Frame,
    sequence: u32,
) Error!void {
    var control: [26]u8 = undefined;
    // fcTL contains five big-endian words, two delay fields and the disposal/blend bytes.
    const words = [_]u32{ sequence, frame.width, frame.height, frame.x, frame.y };
    for (words, 0..) |value, index| std.mem.writeInt(u32, control[index * 4 ..][0..4], value, .big);
    std.mem.writeInt(u16, control[20..22], frame.delay.numerator, .big);
    std.mem.writeInt(u16, control[22..24], frame.delay.denominator, .big);
    control[24] = @backingInt(frame.dispose);
    control[25] = @backingInt(frame.blend);
    try chunks.append(destination, offset, "fcTL", &control);
}

const RasterStorage = union(enum) { allocator: std.mem.Allocator, prepared: EncoderWorkspace };
const RasterResult = struct { records: usize, frame_data_record_count: usize };

fn writeRaster(
    destination: []u8,
    offset: *usize,
    image: ImageInput,
    sequence: ?*u64,
    policy: raster_encoding.Options,
    options: Options,
    storage: RasterStorage,
) Error!RasterResult {
    const layout = try raster_encoding.describe(image, policy);
    var chunk_writer: chunks.DataStream = undefined;
    try chunk_writer.init(destination[offset.*..], options.data_chunk_bytes, sequence);
    switch (storage) {
        .allocator => |allocator| try raster_encoding.compressRows(
            &chunk_writer.writer,
            image,
            layout,
            policy,
            allocator,
        ),
        .prepared => |workspace| try raster_encoding.compressRowsPrepared(
            &chunk_writer.writer,
            image,
            layout,
            policy,
            workspace,
        ),
    }
    offset.* += try chunk_writer.finish();
    return .{
        .records = chunk_writer.record_count,
        .frame_data_record_count = if (sequence != null) chunk_writer.record_count else 0,
    };
}

fn add(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.SizeOverflow;
}

fn mul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.SizeOverflow;
}

test "APNG encoding preserves every native packed profile and included or excluded default" {
    const allocator = std.testing.allocator;
    const facts = png_encoding_vectors;
    var maximum_extra: usize = 0;
    for (facts.controls) |control| maximum_extra = @max(maximum_extra, (control.stride + 1) * 3);
    var workspace = try EncoderWorkspace.initCapacity(allocator, maximum_extra);
    defer workspace.deinit(allocator);
    const filters = [_]Filter{
        .{ .fixed = .none },
        .{ .fixed = .sub },
        .{ .fixed = .up },
        .{ .fixed = .average },
        .{ .fixed = .paeth },
        .adaptive,
    };
    for (facts.controls) |control| {
        const transparency: Transparency = switch (control.color_type) {
            0 => .{ .grayscale = 0 },
            2 => .{ .truecolor = .{ 0, 17, 34 } },
            3 => .{ .palette = control.alpha },
            else => .none,
        };
        const samples: Samples = .{
            .packed_bytes = .{ .bytes = control.bytes, .stride = control.stride },
        };
        const frames = [_]AnimationInput.Frame{
            .{
                .width = control.width,
                .height = control.height,
                .samples = samples,
                .delay = .{ .numerator = 0, .denominator = 0 },
                .dispose = .previous,
                .blend = .over,
            },
            .{
                .width = control.width,
                .height = control.height,
                .samples = samples,
                .delay = .{ .numerator = 65535, .denominator = 65535 },
                .dispose = .background,
            },
        };
        for ([_]bool{ false, true }) |poster| {
            for ([_]Interlace{ .none, .adam7 }) |interlace| {
                for (filters) |filter| {
                    for (
                        [_]zlib.Compression{ .{ .level = 0 }, .{ .level = 9 } },
                        0..,
                    ) |method, index| {
                        const image: AnimationInput = .{
                            .width = control.width,
                            .height = control.height,
                            .color_type = @fromBackingInt(control.color_type),
                            .bit_depth = control.bit_depth,
                            .palette = control.palette,
                            .transparency = transparency,
                            .frames = &frames,
                            .poster = if (poster) samples else null,
                            .play_count = 0x7fffffff,
                        };
                        const options: Options = .{
                            .filter = filter,
                            .compression = method,
                            .interlace = interlace,
                            .data_chunk_bytes = if (index == 0) 1 else 17,
                        };
                        const encoded = try alloc(allocator, image, options);
                        defer allocator.free(encoded);
                        const required = try requirements(image, options);
                        const buffer = try allocator.alloc(u8, required.output_bytes + 2);
                        defer allocator.free(buffer);
                        @memset(buffer, 0xa5);
                        const prepared = try into(image, buffer[1..], workspace, options);
                        try std.testing.expectEqualSlices(u8, encoded, prepared);
                        try std.testing.expectEqual(0xa5, buffer[0]);
                        for (
                            buffer[1 + prepared.len ..],
                        ) |byte| try std.testing.expectEqual(0xa5, byte);
                        @memset(buffer, 0xa5);
                        try std.testing.expectError(
                            error.OutputTooSmall,
                            into(image, buffer[0 .. required.output_bytes - 1], workspace, options),
                        );
                        const short = try EncoderWorkspace.initBuffer(
                            workspace.allocation,
                            required.workspace_extra_bytes - 1,
                        );
                        try std.testing.expectError(
                            error.WorkspaceTooSmall,
                            into(image, buffer, short, options),
                        );
                        for (buffer) |byte| try std.testing.expectEqual(0xa5, byte);
                        var limited = options;
                        limited.limits.maximum_output_bytes = encoded.len;
                        const exact = try into(image, buffer, workspace, limited);
                        try std.testing.expectEqualSlices(u8, encoded, exact);

                        var decoded = try animation.allocWithScratch(
                            u16,
                            allocator,
                            allocator,
                            encoded,
                            .{},
                        );
                        defer decoded.deinit(allocator);
                        try std.testing.expectEqual(!poster, decoded.default_is_frame);
                        try std.testing.expectEqual(0x7fffffff, decoded.play_count);
                        try std.testing.expectEqual(2, decoded.frames.len);
                        try std.testing.expectEqual(
                            frames[0].delay,
                            decoded.frames[0].control.delay,
                        );
                        try std.testing.expectEqual(
                            frames[1].delay,
                            decoded.frames[1].control.delay,
                        );
                        try std.testing.expectEqual(
                            FrameControl.Disposal.previous,
                            decoded.frames[0].control.dispose,
                        );
                        try std.testing.expectEqual(
                            FrameControl.Blend.over,
                            decoded.frames[0].control.blend,
                        );
                        for (
                            decoded.frames,
                        ) |frame| try std.testing.expectEqualSlices(
                            u16,
                            control.rgba16,
                            frame.pixels,
                        );
                    }
                }
            }
        }
    }
}

test "prepared APNG bounds exact-slab poster IDAT and fdAT rasters" {
    const allocator = std.testing.allocator;
    // 255 rows of 256 grayscale bytes plus one filter byte total 65535 bytes.
    const source = try allocator.alloc(u8, 256 * 255);
    defer allocator.free(source);
    for (source, 0..) |*byte, i| byte.* = @truncate(i *% 71 +% i / 251);
    const samples: Samples = .{ .packed_bytes = .{ .bytes = source } };
    const frames = [_]AnimationInput.Frame{
        .{
            .width = 256,
            .height = 255,
            .samples = samples,
            .delay = .{ .numerator = 1, .denominator = 10 },
        },
        .{
            .width = 256,
            .height = 255,
            .samples = samples,
            .delay = .{ .numerator = 1, .denominator = 10 },
        },
    };
    for ([_]bool{ false, true }) |poster| {
        const image: AnimationInput = .{
            .width = 256,
            .height = 255,
            .color_type = .grayscale,
            .bit_depth = 8,
            .frames = &frames,
            .poster = if (poster) samples else null,
        };
        const options: Options = .{
            .filter = .{ .fixed = .none },
            .compression = .{ .level = 0 },
            .data_chunk_bytes = 65535,
        };
        const required = try requirements(image, options);
        var workspace = try EncoderWorkspace.initCapacity(
            allocator,
            required.workspace_extra_bytes,
        );
        defer workspace.deinit(allocator);
        const buffer = try allocator.alloc(u8, required.output_bytes + 2);
        defer allocator.free(buffer);
        @memset(buffer, 0xa5);
        const encoded = try into(image, buffer[1..][0..required.output_bytes], workspace, options);
        try std.testing.expect(encoded.len <= required.output_bytes);
        try std.testing.expectEqual(@as(u8, 0xa5), buffer[0]);
        for (buffer[1 + encoded.len ..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        const owned = try alloc(allocator, image, options);
        defer allocator.free(owned);
        try std.testing.expectEqualSlices(u8, owned, encoded);
        var decoded = try animation.alloc(u8, allocator, encoded, .{});
        defer decoded.deinit(allocator);
        try std.testing.expectEqual(!poster, decoded.default_is_frame);
        try std.testing.expectEqual(@as(usize, 2), decoded.frames.len);
        for (decoded.frames) |frame| for (source, 0..) |value, i| {
            try std.testing.expectEqualSlices(
                u8,
                &.{ value, value, value, 255 },
                frame.pixels[i * 4 ..][0..4],
            );
        };
        var limited = options;
        limited.limits.maximum_output_bytes = encoded.len - 1;
        try std.testing.expectError(
            error.OutputBudgetExceeded,
            into(image, buffer[1..][0..required.output_bytes], workspace, limited),
        );
    }
}

test "APNG encoding preserves native-word rectangles and exact rational playback" {
    const allocator = std.testing.allocator;
    const frames = [_]AnimationInput.Frame{
        .{
            .width = 2,
            .height = 1,
            .samples = .{
                .words = .{ .values = &.{ 65535, 0, 0, 65535, 0x1234, 0x5678, 0x9abc, 0 } },
            },
            .delay = .{ .numerator = 1, .denominator = 0 },
        },
        .{
            .width = 1,
            .height = 1,
            .x = 1,
            .samples = .{ .words = .{ .values = &.{ 0x1357, 0x2468, 0xabcd, 0x8000 } } },
            .delay = .{ .numerator = 2, .denominator = 17 },
            .blend = .over,
            .dispose = .previous,
        },
        .{
            .width = 1,
            .height = 1,
            .samples = .{ .words = .{ .values = &.{ 0, 65535, 0, 65535 } } },
            .delay = .{ .numerator = 3, .denominator = 19 },
            .dispose = .background,
        },
    };
    for ([_]Interlace{ .none, .adam7 }) |interlace| {
        const encoded = try allocWithScratch(
            allocator,
            allocator,
            .{
                .width = 2,
                .height = 1,
                .color_type = .rgba,
                .bit_depth = 16,
                .frames = &frames,
                .play_count = 1,
            },
            .{
                .filter = .adaptive,
                .compression = .{ .strategy = .huffman_only },
                .interlace = interlace,
                .data_chunk_bytes = 7,
                .metadata = .{
                    .cicp = .{ .primaries = 9, .transfer = 16, .matrix = 0, .full_range = false },
                    .physical = .{ .x = 3, .y = 7, .metres = false },
                    .significant_bits = &.{ 15, 14, 13, 12 },
                },
            },
        );
        defer allocator.free(encoded);
        var decoded = try animation.allocWithScratch(u16, allocator, allocator, encoded, .{});
        defer decoded.deinit(allocator);
        for (decoded.frames, &frames) |actual, source| {
            try std.testing.expectEqual(source.width, actual.control.width);
            try std.testing.expectEqual(source.height, actual.control.height);
            try std.testing.expectEqual(source.x, actual.control.x);
            try std.testing.expectEqual(source.y, actual.control.y);
            try std.testing.expectEqual(source.delay, actual.control.delay);
            try std.testing.expectEqual(source.dispose, actual.control.dispose);
            try std.testing.expectEqual(source.blend, actual.control.blend);
            try std.testing.expectEqualSlices(u16, source.samples.words.values, actual.pixels);
        }
        var player = try animation.Animation(u16).Player.initCapacity(allocator, &decoded, .{});
        defer player.deinit(allocator);
        try std.testing.expectEqualSlices(
            u16,
            frames[0].samples.words.values,
            player.next().?.pixels,
        );
        // Over an alpha-zero destination produces the complete source colors and alpha.
        try std.testing.expectEqualSlices(
            u16,
            &.{ 65535, 0, 0, 65535, 0x1357, 0x2468, 0xabcd, 0x8000 },
            player.next().?.pixels,
        );
        // Previous restores the alpha-zero hidden colors, then Source replaces pixel zero.
        try std.testing.expectEqualSlices(
            u16,
            &.{ 0, 65535, 0, 65535, 0x1234, 0x5678, 0x9abc, 0 },
            player.next().?.pixels,
        );
        try std.testing.expect(player.next() == null);
    }
}

test "APNG encoding admits geometry frame policy and cumulative resources before allocation" {
    const sample: Samples = .{ .packed_bytes = .{ .bytes = &.{ 1, 2, 3, 4 } } };
    var frames = [_]AnimationInput.Frame{
        .{
            .width = 1,
            .height = 1,
            .samples = sample,
            .delay = .{ .numerator = 0, .denominator = 0 },
        },
    };
    var image: AnimationInput = .{
        .width = 1,
        .height = 1,
        .color_type = .rgba,
        .bit_depth = 8,
        .frames = &frames,
    };
    const output_allocator = std.testing.failing_allocator;
    const scratch_allocator = std.testing.failing_allocator;
    var options: Options = .{ .compression = .{ .level = 3 }, .filter = .{ .fixed = .sub } };
    image.width = 0;
    try std.testing.expectError(
        error.InvalidImageExtent,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.width = 1;
    image.frames = &.{};
    try std.testing.expectError(
        error.InvalidFrameCount,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.frames = &frames;
    options.maximum_frames = 0;
    try std.testing.expectError(
        error.FrameLimitExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.maximum_frames = 4096;
    image.play_count = 0x80000000;
    try std.testing.expectError(
        error.InvalidPlayCount,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.play_count = 0;
    options.data_chunk_bytes = 0;
    try std.testing.expectError(
        error.InvalidDataChunkSize,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.data_chunk_bytes = 0x7ffffffc;
    try std.testing.expectError(
        error.InvalidDataChunkSize,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.data_chunk_bytes = 1;
    frames[0].x = 1;
    try std.testing.expectError(
        error.InvalidDefaultFrame,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.poster = sample;
    try std.testing.expectError(
        error.InvalidFrameRectangle,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    frames[0].x = 0;
    options.limits.maximum_pixels = 1;
    try std.testing.expectError(
        error.PixelBudgetExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.limits = .{ .maximum_work_units = 31 };
    try std.testing.expectError(
        error.WorkBudgetExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.limits = .{ .maximum_scratch_bytes = try raster_encoding.scratchByteCount(5) - 1 };
    try std.testing.expectError(
        error.ScratchBudgetExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.limits = .{ .maximum_records = 5 };
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.limits = .{ .maximum_metadata_bytes = 50 };
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.limits = .{};
    options.metadata.gamma = 0;
    try std.testing.expectError(
        error.InvalidPngMetadata,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.color_type = .indexed;
    image.palette = &.{.{ 1, 2, 3 }};
    try std.testing.expectError(
        error.InvalidPaletteIndex,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
}

test "APNG encoding preserves exact chunk metadata work and output budgets" {
    const allocator = std.testing.allocator;
    const sample: Samples = .{ .packed_bytes = .{ .bytes = &.{ 1, 2, 3, 4 } } };
    const image: AnimationInput = .{
        .width = 1,
        .height = 1,
        .color_type = .rgba,
        .bit_depth = 8,
        .poster = sample,
        .frames = &.{
            .{
                .width = 1,
                .height = 1,
                .samples = sample,
                .delay = .{ .numerator = 1, .denominator = 3 },
            },
        },
    };
    const output_allocator = allocator;
    const scratch_allocator = allocator;
    var options: Options = .{
        .compression = .{ .level = 0 },
        .filter = .{ .fixed = .none },
        .data_chunk_bytes = 3,
    };
    const expected = try allocWithScratch(output_allocator, scratch_allocator, image, options);
    defer allocator.free(expected);
    // A five-byte filtered raster is zlib header + final stored block + Adler: 2+5+5+4 = 16 bytes,
    // split into six chunks for each raster. IHDR/IEND/acTL/fcTL plus twelve data chunks use
    // sixteen records, including six four-byte fdAT words.
    try std.testing.expectEqual(303, expected.len);
    options.limits = .{
        .maximum_pixels = 2,
        .maximum_output_bytes = expected.len,
        .maximum_scratch_bytes = try raster_encoding.scratchByteCount(5),
        .maximum_work_units = 32,
        .maximum_records = 16,
        .maximum_metadata_bytes = 71,
    };
    const exact = try allocWithScratch(output_allocator, scratch_allocator, image, options);
    defer allocator.free(exact);
    try std.testing.expectEqualSlices(u8, expected, exact);
    options.limits.maximum_records -= 1;
    try expectEncodeError(
        error.MetadataLimitExceeded,
        output_allocator,
        scratch_allocator,
        image,
        options,
    );
    options.limits.maximum_records += 1;
    options.limits.maximum_metadata_bytes -= 1;
    try expectEncodeError(
        error.MetadataLimitExceeded,
        output_allocator,
        scratch_allocator,
        image,
        options,
    );
    options.limits.maximum_metadata_bytes += 1;
    options.limits.maximum_output_bytes -= 1;
    try expectEncodeError(
        error.OutputBudgetExceeded,
        output_allocator,
        scratch_allocator,
        image,
        options,
    );
}

fn expectEncodeError(
    expected: Error,
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    image: AnimationInput,
    options: Options,
) !void {
    // Unexpected admission still returns caller-owned output; release it before failing.
    if (allocWithScratch(output_allocator, scratch_allocator, image, options)) |output| {
        output_allocator.free(output);
        return error.TestExpectedError;
    } else |actual| {
        try std.testing.expectEqual(expected, actual);
    }
}

test "APNG encoding retires metadata and raster scratch through distinct aliased fixed handles" {
    const allocator = std.testing.allocator;
    const width = 33;
    const height = 19;
    const words = try allocator.alloc(u16, width * height * 4);
    defer allocator.free(words);
    for (words, 0..) |*value, index| value.* = @truncate(index * 17837 + index / 7);
    const source_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(words));
    const samples: Samples = .{ .words = .{ .values = words } };
    const image: AnimationInput = .{
        .width = width,
        .height = height,
        .color_type = .rgba,
        .bit_depth = 16,
        .poster = samples,
        .frames = &.{
            .{
                .width = width,
                .height = height,
                .samples = samples,
                .delay = .{ .numerator = 1, .denominator = 0 },
            },
            .{
                .width = 3,
                .height = 2,
                .x = 5,
                .y = 7,
                .samples = .{ .words = .{ .values = words, .stride = width * 4 } },
                .delay = .{ .numerator = 65535, .denominator = 7 },
                .dispose = .previous,
                .blend = .over,
            },
        },
    };
    const facts = png_encoding_vectors;
    var output_allocator = allocator;
    var scratch_allocator = allocator;
    const options: Options = .{
        .filter = .adaptive,
        .compression = .{ .level = 9 },
        .interlace = .adam7,
        .data_chunk_bytes = 7,
        .metadata = .{
            .icc_profile = .{ .name = "sRGB profile", .bytes = facts.srgb_icc },
            .exif_payload = facts.exif_little,
            .texts = &.{
                .{
                    .keyword = "Description",
                    .compress = true,
                    .data = &@as(
                        [100 * "圧縮 metadata ".len]u8,
                        @bitCast(@as([100]["圧縮 metadata ".len]u8, @splat("圧縮 metadata ".*))),
                    ),
                },
            },
        },
    };
    const expected = try allocWithScratch(output_allocator, scratch_allocator, image, options);
    defer allocator.free(expected);
    const scratch_bytes = try raster_encoding.scratchByteCount(width * 8 + 1);
    const backing = try allocator.alloc(u8, expected.len + scratch_bytes + 16);
    defer allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing[1..]);
    const prefix = try fixed.allocator().alloc(u8, 7);
    @memset(prefix, 0x5a);
    const Alias = struct {
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const owner: *std.heap.FixedBufferAllocator = @ptrCast(@alignCast(ctx));
            return owner.allocator().rawAlloc(len, alignment, ra);
        }
        fn resize(
            ctx: *anyopaque,
            bytes: []u8,
            alignment: std.mem.Alignment,
            len: usize,
            ra: usize,
        ) bool {
            const owner: *std.heap.FixedBufferAllocator = @ptrCast(@alignCast(ctx));
            return owner.allocator().rawResize(bytes, alignment, len, ra);
        }
        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
            return null;
        }
        fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const owner: *std.heap.FixedBufferAllocator = @ptrCast(@alignCast(ctx));
            owner.allocator().rawFree(bytes, alignment, ra);
        }
    };
    const aliased: std.mem.Allocator = .{
        .ptr = &fixed,
        .vtable = &.{
            .alloc = Alias.alloc,
            .resize = Alias.resize,
            .remap = Alias.remap,
            .free = Alias.free,
        },
    };
    for (0..3) |mode| {
        output_allocator = if (mode == 2) aliased else fixed.allocator();
        scratch_allocator = if (mode == 1) aliased else fixed.allocator();
        for (0..8) |_| {
            const encoded = try allocWithScratch(
                output_allocator,
                scratch_allocator,
                image,
                options,
            );
            try std.testing.expectEqual(prefix.len + encoded.len, fixed.end_index);
            try std.testing.expectEqualSlices(u8, expected, encoded);
            output_allocator.free(encoded);
            try std.testing.expectEqual(prefix.len, fixed.end_index);
        }
    }
    for (0..3) |mode| {
        var complete = false;
        for (0..32) |fail_index| {
            var failing = std.testing.FailingAllocator.init(
                fixed.allocator(),
                .{ .fail_index = fail_index, .resize_fail_index = 0 },
            );
            output_allocator = if (mode == 1) fixed.allocator() else failing.allocator();
            scratch_allocator = if (mode == 2) fixed.allocator() else failing.allocator();
            if (allocWithScratch(output_allocator, scratch_allocator, image, options)) |encoded| {
                output_allocator.free(encoded);
                complete = true;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(failing.has_induced_failure);
            }
            try std.testing.expectEqual(prefix.len, fixed.end_index);
            if (complete) break;
        }
        try std.testing.expect(complete);
    }
    fixed.buffer = backing[1..][0 .. prefix.len + expected.len + scratch_bytes - 1];
    output_allocator = fixed.allocator();
    scratch_allocator = fixed.allocator();
    try std.testing.expectError(
        error.OutOfMemory,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    try std.testing.expectEqual(prefix.len, fixed.end_index);
    for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
    try std.testing.expectEqual(source_hash, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(words)));
}

test "APNG prepared metadata counts actual sequence words and both raw and encoded declarations" {
    const allocator = std.testing.allocator;
    const zeros = [_]u8{ 0, 0, 0, 0 };
    const image: AnimationInput = .{
        .width = 1,
        .height = 1,
        .color_type = .rgba,
        .bit_depth = 8,
        .frames = &.{
            .{
                .width = 1,
                .height = 1,
                .samples = .{ .packed_bytes = .{ .bytes = &zeros } },
                .delay = .{ .numerator = 1, .denominator = 10 },
            },
            .{
                .width = 1,
                .height = 1,
                .samples = .{ .packed_bytes = .{ .bytes = &zeros } },
                .delay = .{ .numerator = 2, .denominator = 10 },
            },
        },
    };
    const repeated: [128]u8 = @splat('x');
    const cases = .{
        .{ .method = zlib.Compression{ .level = 0 }, .text = "x" },
        .{ .method = zlib.Compression{ .level = 3 }, .text = &repeated },
    };
    inline for (cases) |case| {
        var options: Options = .{
            .filter = .{ .fixed = .none },
            .compression = case.method,
            .data_chunk_bytes = 1,
            .metadata = .{
                .texts = &.{
                    .{ .keyword = "K", .encoding = .latin1, .data = case.text, .compress = true },
                },
            },
        };
        const encoded = try alloc(allocator, image, options);
        defer allocator.free(encoded);
        var offset: usize = 8;
        var frame_data_record_count: usize = 0;
        var text_bytes: usize = 0;
        while (offset < encoded.len) {
            const length = std.mem.readInt(u32, encoded[offset..][0..4], .big);
            const kind = encoded[offset + 4 ..][0..4];
            if (std.mem.eql(u8, kind, "fdAT")) frame_data_record_count += 1;
            if (std.mem.eql(u8, kind, "zTXt")) text_bytes += length;
            offset += 12 + @as(usize, length);
        }
        // IHDR 13, acTL 8 and two fcTL payloads of 26 precede sequence-word accounting.
        const structural_bytes = 73 + frame_data_record_count * 4;
        options.limits.maximum_metadata_bytes = structural_bytes + @max(
            3 + case.text.len,
            text_bytes,
        );
        options.limits.maximum_output_bytes = encoded.len;
        const required = try requirements(image, options);
        const buffer = try allocator.alloc(u8, required.output_bytes);
        defer allocator.free(buffer);
        var workspace = try EncoderWorkspace.initCapacity(
            allocator,
            required.workspace_extra_bytes,
        );
        defer workspace.deinit(allocator);
        try std.testing.expectEqualSlices(u8, encoded, try into(image, buffer, workspace, options));
        options.limits.maximum_metadata_bytes -= 1;
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            into(image, buffer, workspace, options),
        );
    }
}

test "default APNG compression composes with level and strategy mutation" {
    const allocator = std.testing.allocator;
    const pixel = [_]u16{ 0x1234, 0x4567, 0x89ab, 0xffff };
    const frames = [_]AnimationInput.Frame{
        .{
            .width = 1,
            .height = 1,
            .samples = .{ .words = .{ .values = &pixel } },
            .delay = .{ .numerator = 1, .denominator = 10 },
        },
    };
    const image: AnimationInput = .{
        .width = 1,
        .height = 1,
        .color_type = .rgba,
        .bit_depth = 16,
        .frames = &frames,
        .play_count = 1,
    };
    var options: Options = .{};
    options.data_chunk_bytes = 7;
    for (0..10) |level| {
        options.compression.level = @intCast(level);
        for ([_]zlib.Compression.Strategy{ .default, .huffman_only, .four_byte_runs }) |strategy| {
            options.compression.strategy = strategy;
            _ = try requirements(image, options);
            const encoded = try alloc(allocator, image, options);
            defer allocator.free(encoded);
            var decoded = try animation.alloc(u16, allocator, encoded, .{});
            defer decoded.deinit(allocator);
            var player = try animation.Animation(u16).Player.initCapacity(allocator, &decoded, .{});
            defer player.deinit(allocator);
            try std.testing.expectEqualSlices(u16, &pixel, player.next().?.pixels);
            try std.testing.expectEqual(null, player.next());
        }
    }
}

test "invalid compression is refused before APNG allocation and prepared writes" {
    const allocator = std.testing.allocator;
    const frames = [_]AnimationInput.Frame{
        .{
            .width = 1,
            .height = 1,
            .samples = .{ .packed_bytes = .{ .bytes = &.{ 1, 2, 3, 255 } } },
            .delay = .{ .numerator = 1, .denominator = 10 },
        },
    };
    const image: AnimationInput = .{
        .width = 1,
        .height = 1,
        .color_type = .rgba,
        .bit_depth = 8,
        .frames = &frames,
    };
    const required = try requirements(image, .{});
    const output = try allocator.alloc(u8, required.output_bytes);
    defer allocator.free(output);
    const backing = try allocator.alloc(u8, required.workspace_bytes);
    defer allocator.free(backing);
    const workspace = try EncoderWorkspace.initBuffer(backing, required.workspace_extra_bytes);
    for ([_]u8{ 10, 255 }) |level| {
        const options: Options = .{ .compression = .{ .level = level } };
        try std.testing.expectError(error.InvalidOptions, requirements(image, options));
        try std.testing.expectError(
            error.InvalidOptions,
            allocWithScratch(
                std.testing.failing_allocator,
                std.testing.failing_allocator,
                image,
                options,
            ),
        );
        @memset(output, 0xa5);
        @memset(backing, 0x5a);
        try std.testing.expectError(error.InvalidOptions, into(image, output, workspace, options));
        try std.testing.expect(std.mem.allEqual(u8, output, 0xa5));
        try std.testing.expect(std.mem.allEqual(u8, backing, 0x5a));
    }
}
