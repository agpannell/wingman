//! PNG sample admission, static framing and native lossless encoding.

const MetadataInput = @import("metadata.zig").Metadata.Input;
const encoding_workspace = @import("encode_workspace.zig");
const owned_decode = @import("image_decode.zig");
const std = @import("std");
const SourceImage = @import("Source.zig");
const format = @import("format.zig");
const zlib = @import("../zlib.zig");
const Limits = @import("Limits.zig");
const chunks = @import("ChunkWriter.zig");
const encoding_metadata = @import("metadata_encode.zig");
const raster_encoding = @import("raster_encode.zig");
const png_encoding_vectors = @import("testdata/encoding.zig");
const ImageInput = @import("ImageInput.zig");

const EncoderWorkspace = encoding_workspace.Workspace;
const testing_encoding = png_encoding_vectors;

const FilterType = Filter.Type;
pub const Filter = @import("scanline_filters.zig").Filter;
pub const Compression = zlib.Compression;
pub const Workspace = encoding_workspace.Workspace;
const Interlace = format.Interlace;

/// Filtering, compression, traversal, metadata and resource policy for PNG writing.
pub const Options = struct {
    /// Scanline predictor; the default selects the lowest signed-byte score of all five filters.
    filter: Filter = .adaptive,
    /// Level 6 with automatic lookahead by default. A newly assigned Compression uses its own
    /// full-lookahead default unless automatic or reduced is requested.
    compression: zlib.Compression = .{ .level = 6, .lazy_lookahead = .automatic },
    /// Sequential or Adam7 traversal; no interlace remains the default.
    interlace: Interlace = .none,
    /// Typed ancillary declarations, emitted before palette and image data without transforms.
    metadata: MetadataInput = .{},
    /// Maximum compressed payload per IDAT, from one byte through PNG's 31-bit bound. Boundaries do
    /// not restart zlib. The default preserves one IDAT whenever it fits.
    data_chunk_bytes: usize = 0x7fff_ffff,
    /// Bounds pixels, encoded output, requested live scratch, records and filtering work. Every
    /// IDAT counts as a record; its twelve framing bytes count toward output. Work counts source
    /// palette checks and at most two serialization/filter passes. DEFLATE match search is
    /// controlled by the compression settings, not this work limit.
    limits: Limits = .{},
};

/// Encoding validation, resource, allocation and bounded backing-writer failures.
pub const Error = encoding_metadata.Error || raster_encoding.Error || Limits.Error || chunks
    .DataChunkWriteError;

const Layout = raster_encoding.Layout;
const scratchByteCount = raster_encoding.scratchByteCount;
const validateExtent = raster_encoding.validateExtent;

/// Capacity requirements for one image. Output is a conservative complete PNG bound; workspace
/// includes the padding required for any backing address. Neither is the actual compressed size or
/// peak allocation.
pub const Requirements = struct {
    /// Required destination capacity in bytes, including metadata and selected IDAT framing.
    output_bytes: usize,
    /// Required workspace backing bytes, including state, alignment and three full-width rows.
    workspace_bytes: usize,
    /// Extra row bytes passed to encode.Workspace.initBuffer or initCapacity.
    workspace_extra_bytes: usize,
    /// Uncompressed zlib input bytes, including every filter selector and nonempty Adam7 row.
    filtered_bytes: usize,
};

const PreparedImage = struct {
    layout: Layout,
    metadata: encoding_metadata.Prepared,
    policy: raster_encoding.Options,
    requirements: Requirements,
};

/// Computes checked output/workspace capacity without allocating or compressing. Source shape,
/// palette indices and typed metadata are validated under options. The output bound can exceed the
/// actual output policy; into admits the actual used byte and record counts.
pub fn requirements(image: ImageInput, options: Options) Error!Requirements {
    return (try prepareImage(image, options)).requirements;
}

fn prepareImage(image: ImageInput, options: Options) Error!PreparedImage {
    _ = try chunks.dataRecordCount(0, options.data_chunk_bytes, false);
    const policy: raster_encoding.Options = .{
        .filter = options.filter,
        .compression = options.compression,
        .interlace = options.interlace,
    };
    const layout = try admitImage(image, policy, options.limits);

    // Raster admission has already charged its share of the shared limits.
    var metadata_limits = options.limits;
    metadata_limits.maximum_records -= layout.minimum_records;
    metadata_limits.maximum_metadata_bytes -= layout.base_metadata_bytes;
    metadata_limits.maximum_work_units -= layout.work_units;
    const metadata = try encoding_metadata.prepare(
        options.metadata,
        @backingInt(image.color_type),
        image.bit_depth,
        metadata_limits,
    );
    return prepareWithAdmission(image, options, layout, metadata, policy);
}

fn prepareWithAdmission(
    image: ImageInput,
    options: Options,
    layout: Layout,
    metadata: encoding_metadata.Prepared,
    policy: raster_encoding.Options,
) Error!PreparedImage {
    const filtered_layout = format.packedLayout(
        image.width,
        image.height,
        layout.bits_per_pixel,
        @backingInt(options.interlace),
    ) catch return error.SizeOverflow;
    const compressed_bound = try zlib.encodeBound(filtered_layout.filtered_bytes, .{});
    const data_records = try chunks.dataRecordCount(
        compressed_bound,
        options.data_chunk_bytes,
        false,
    );
    // Signature, IHDR and IEND occupy 45 bytes; each IDAT adds 12 bytes of framing.
    var output_bound = try add(45, try add(compressed_bound, try mul(data_records, 12)));
    output_bound = try add(output_bound, try metadata.capacityBound());
    if (image.palette.len != 0) output_bound = try add(output_bound, 12 + image.palette.len * 3);
    const transparency_bytes = raster_encoding.transparencyByteCount(image.transparency);
    if (transparency_bytes != 0) output_bound = try add(output_bound, 12 + transparency_bytes);
    return .{
        .layout = layout,
        .metadata = metadata,
        .policy = policy,
        .requirements = .{
            .output_bytes = output_bound,
            .workspace_bytes = layout.scratch_bytes,
            .workspace_extra_bytes = try mul(try add(layout.row_bytes, 1), 3),
            .filtered_bytes = filtered_layout.filtered_bytes,
        },
    };
}

/// Encodes once into prepared caller capacity, returning only the complete used PNG prefix. Reserve
/// requirements capacities and keep image/metadata, workspace and output disjoint. The returned
/// slice borrows destination; no input or workspace borrow survives the call. No allocation occurs.
/// Capacity/backing refusals precede writes; later errors may leave an unpublished prefix. Success
/// preserves unused output and backing. Actual encoded size and record counts, rather than
/// conservative bounds, enforce options.limits.
pub fn into(
    image: ImageInput,
    destination: []u8,
    workspace: EncoderWorkspace,
    options: Options,
) Error![]u8 {
    const prepared = try prepareImage(image, options);
    const required = prepared.requirements;
    if (destination.len < required.output_bytes) return error.OutputTooSmall;
    if (workspace.extra.len < required.workspace_extra_bytes) return error.WorkspaceTooSmall;

    const output = destination[0..required.output_bytes];
    @memcpy(output[0..8], format.signature);
    var offset: usize = 8;
    try raster_encoding.writeHeader(output, &offset, image, options.interlace);
    offset += try prepared.metadata.writeInto(output[offset..], workspace, options.compression);
    try raster_encoding.writePaletteAndTransparency(output, &offset, image);

    var chunk_writer: chunks.DataStream = undefined;
    try chunk_writer.init(output[offset .. output.len - 12], options.data_chunk_bytes, null);
    try raster_encoding.compressRowsPrepared(
        &chunk_writer.writer,
        image,
        prepared.layout,
        prepared.policy,
        workspace,
    );
    offset += try chunk_writer.finish();
    try chunks.appendEnd(output, &offset);

    const records = try add(
        try add(prepared.layout.minimum_records - 1, prepared.metadata.record_count),
        chunk_writer.record_count,
    );
    if (records > options.limits.maximum_records) return error.MetadataLimitExceeded;
    try format.admitOutput(options.limits, prepared.layout.pixels, offset);
    return output[0..offset];
}

/// Encodes an owned PNG, borrowing one allocator for output and scratch. May reserve bounded output
/// before its exact size is known, then shrink or encode again into exact capacity. The temporary
/// reservation counts against scratch limits; actual output is admitted before return. No allocator
/// is retained. Release the returned complete PNG with the same allocator.
pub fn alloc(allocator: std.mem.Allocator, image: ImageInput, options: Options) Error![]u8 {
    var retained: [4096]u8 = undefined;
    return encodeAllocRetained(allocator, allocator, image, options, &retained, true);
}

/// Encodes source samples into an owned PNG using separate output and scratch allocators. Palette
/// and transparency precede IDAT; no color or orientation metadata is inferred. Shape and resource
/// checks precede scratch allocation; exact output size is admitted before output allocation. The
/// result borrows neither source nor scratch. Free it with output_allocator; neither allocator is
/// retained.
pub fn allocWithScratch(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    image: ImageInput,
    options: Options,
) Error![]u8 {
    var retained: [4096]u8 = undefined;
    return encodeAllocRetained(
        output_allocator,
        scratch_allocator,
        image,
        options,
        &retained,
        false,
    );
}

// Reserve a bound from the output allocator, then turn the same allocation into the exact result.
// If shrinking is unsupported, release it and encode again into exact capacity.
fn encodeAllocProvisional(
    allocator: std.mem.Allocator,
    image: ImageInput,
    options: Options,
    prepared: PreparedImage,
) Error!?[]u8 {
    const required = prepared.requirements;
    // The caller's scratch budget also bounds large provisional output reservations.
    if (required.filtered_bytes < 8192 or prepared.metadata.record_count != 0 or required
        .workspace_bytes > options.limits.maximum_scratch_bytes or required.output_bytes > options
        .limits.maximum_scratch_bytes - required.workspace_bytes)
    {
        return null;
    }
    var owned: ?[]u8 = allocator.alloc(u8, required.output_bytes) catch return null;
    defer if (owned) |buffer| allocator.free(buffer);
    const used = emitProvisional(owned.?, image, options, prepared, allocator) catch |err| {
        if (err == error.OutOfMemory) return null;
        return err;
    };
    if (allocator.resize(owned.?, used)) {
        const result = owned.?[0..used];
        owned = null;
        return result;
    }
    allocator.free(owned.?);
    owned = null;
    owned = try allocator.alloc(u8, used);
    const repeated = try emitProvisional(owned.?, image, options, prepared, allocator);
    std.debug.assert(repeated == used);
    const result = owned.?;
    owned = null;
    return result;
}

fn emitProvisional(
    output: []u8,
    image: ImageInput,
    options: Options,
    prepared: PreparedImage,
    scratch_allocator: std.mem.Allocator,
) Error!usize {
    if (options.compression.strategy == .four_byte_runs) {
        var workspace = try encoding_workspace.FourByteRunWorkspace.initCapacity(
            scratch_allocator,
            prepared.requirements.workspace_extra_bytes,
        );
        defer workspace.deinit(scratch_allocator);
        return emitProvisionalWithStorage(output, image, options, prepared, workspace);
    }
    var workspace = try EncoderWorkspace.initCapacity(
        scratch_allocator,
        prepared.requirements.workspace_extra_bytes,
    );
    defer workspace.deinit(scratch_allocator);
    return emitProvisionalWithStorage(output, image, options, prepared, workspace);
}

fn emitProvisionalWithStorage(
    output: []u8,
    image: ImageInput,
    options: Options,
    prepared: PreparedImage,
    workspace: anytype,
) Error!usize {
    // Provisional output is selected only for metadata-free images.
    std.debug.assert(prepared.metadata.record_count == 0);
    @memcpy(output[0..8], format.signature);
    var offset: usize = 8;
    try raster_encoding.writeHeader(output, &offset, image, options.interlace);
    try raster_encoding.writePaletteAndTransparency(output, &offset, image);
    var chunk_writer: chunks.DataStream = undefined;
    try chunk_writer.init(output[offset .. output.len - 12], options.data_chunk_bytes, null);
    try raster_encoding.compressRowsWithStorage(
        &chunk_writer.writer,
        image,
        prepared.layout,
        prepared.policy,
        workspace,
    );
    offset += try chunk_writer.finish();
    try chunks.appendEnd(output, &offset);
    const records = try add(
        try add(prepared.layout.minimum_records - 1, prepared.metadata.record_count),
        chunk_writer.record_count,
    );
    if (records > options.limits.maximum_records) return error.MetadataLimitExceeded;
    try format.admitOutput(options.limits, prepared.layout.pixels, offset);
    return offset;
}

/// Encodes an exact owned PNG, counting first while retaining compressed raster bytes in caller
/// storage. If the complete raster fits, emission reuses it; otherwise compression is replayed. The
/// entire retention span counts against the scratch limit in addition to encoder workspace.
///
/// Retention is borrowed only for this call and may change on failure. Keep it disjoint from all
/// inputs and allocator results. The returned slice borrows no source or retention storage; release
/// it with output_allocator. No allocator is retained.
pub fn allocWithRetention(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    image: ImageInput,
    options: Options,
    retention: []u8,
) Error![]u8 {
    var adjusted = options;
    if (retention.len > adjusted.limits.maximum_scratch_bytes) return error.ScratchBudgetExceeded;
    adjusted.limits.maximum_scratch_bytes -= retention.len;
    return encodeAllocRetained(
        output_allocator,
        scratch_allocator,
        image,
        adjusted,
        retention,
        false,
    );
}

fn encodeAllocRetained(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    image: ImageInput,
    options: Options,
    retained: []u8,
    provisional_output: bool,
) Error![]u8 {
    _ = try chunks.dataRecordCount(0, options.data_chunk_bytes, false);
    const policy: raster_encoding.Options = .{
        .filter = options.filter,
        .compression = options.compression,
        .interlace = options.interlace,
    };
    const layout = try admitImage(image, policy, options.limits);

    // Metadata and raster admission share the same work, record and metadata budgets.
    var metadata_limits = options.limits;
    metadata_limits.maximum_records -= layout.minimum_records;
    metadata_limits.maximum_metadata_bytes -= layout.base_metadata_bytes;
    metadata_limits.maximum_work_units -= layout.work_units;
    const prepared_metadata = try encoding_metadata.prepare(
        options.metadata,
        @backingInt(image.color_type),
        image.bit_depth,
        metadata_limits,
    );
    // Prepare once: a failed speculative reservation must not repeat source validation. Only alloc
    // enables this path; its one allocator supplies both owners.
    if (provisional_output and (image.width > 32 or image.height > 32) and prepared_metadata
        .record_count == 0)
    {
        const prepared: ?PreparedImage = prepareWithAdmission(
            image,
            options,
            layout,
            prepared_metadata,
            policy,
        ) catch null;
        if (prepared) |ready| {
            if (try encodeAllocProvisional(output_allocator, image, options, ready)) |result| {
                return result;
            }
        }
    }
    const metadata_length = if (prepared_metadata.record_count == 0) 0 else try prepared_metadata
        .encodedSizeWithScratch(
        scratch_allocator,
        options.compression,
    );

    var counting: std.Io.Writer.Discarding = .init(retained);
    try raster_encoding.compressRows(&counting.writer, image, layout, policy, scratch_allocator);
    const compressed_count = counting.fullCount();
    const zlib_length = std.math.cast(usize, compressed_count) orelse return error.SizeOverflow;
    const data_records = try chunks.dataRecordCount(zlib_length, options.data_chunk_bytes, false);
    const records = try add(
        try add(layout.minimum_records - 1, prepared_metadata.record_count),
        data_records,
    );
    if (records > options.limits.maximum_records) return error.MetadataLimitExceeded;
    var length = try add(
        try add(zlib_length, 45),
        try add(metadata_length, try mul(data_records, 12)),
    );
    if (image.palette.len != 0) length = try add(length, 12 + image.palette.len * 3);
    const transparency_bytes = raster_encoding.transparencyByteCount(image.transparency);
    if (transparency_bytes != 0) length = try add(length, 12 + transparency_bytes);
    try format.admitOutput(options.limits, layout.pixels, length);
    const result = try output_allocator.alloc(u8, length);
    errdefer output_allocator.free(result);

    @memcpy(result[0..8], format.signature);
    var offset: usize = 8;
    try raster_encoding.writeHeader(result, &offset, image, options.interlace);
    if (prepared_metadata.record_count != 0) {
        offset += try prepared_metadata.writeIntoWithScratch(
            scratch_allocator,
            result[offset..],
            options.compression,
        );
    }
    try raster_encoding.writePaletteAndTransparency(result, &offset, image);

    // A zero discarded count means the complete zlib stream remains in the retention buffer.
    if (data_records > 1) {
        var chunk_writer: chunks.DataStream = undefined;
        try chunk_writer.init(result[offset..], options.data_chunk_bytes, null);
        if (counting.count == 0) {
            try chunk_writer.writer.writeAll(counting.writer.buffered());
        } else {
            try raster_encoding.compressRows(
                &chunk_writer.writer,
                image,
                layout,
                policy,
                scratch_allocator,
            );
        }
        offset += try chunk_writer.finish();
    } else if (counting.count == 0) {
        try chunks.append(result, &offset, "IDAT", counting.writer.buffered());
    } else {
        var chunk_writer: chunks = undefined;
        try chunk_writer.init(result[offset..], "IDAT", zlib_length);
        try raster_encoding.compressRows(
            &chunk_writer.writer,
            image,
            layout,
            policy,
            scratch_allocator,
        );
        offset += try chunk_writer.finish();
    }
    try chunks.appendEnd(result, &offset);
    std.debug.assert(offset == result.len);
    return result;
}

fn admitImage(image: ImageInput, policy: raster_encoding.Options, limits: Limits) Error!Layout {
    const admitted = try raster_encoding.describe(image, policy);
    try format.admitOutput(limits, admitted.pixels, 57);
    if (admitted.scratch_bytes > limits.maximum_scratch_bytes) return error.ScratchBudgetExceeded;
    if (admitted.minimum_records > limits.maximum_records or admitted.base_metadata_bytes > limits
        .maximum_metadata_bytes) return error.MetadataLimitExceeded;
    try format.admitWork(limits, admitted.work_units);
    try raster_encoding.validateIndices(image, admitted);
    return admitted;
}

fn add(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.SizeOverflow;
}

fn mul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.SizeOverflow;
}

test "retained PNG allocation preserves exact output and scratch limits" {
    const allocator = std.testing.allocator;
    const width = 96;
    const height = 96;
    const pixels = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(pixels);
    for (pixels, 0..) |*byte, i| byte.* = @truncate(i *% 47 +% i / 71);
    const image = try ImageInput.rgba8(pixels, width, height);
    var options: Options = .{
        .filter = .{ .fixed = .up },
        .compression = .{ .level = 6, .strategy = .four_byte_runs },
    };
    const baseline = try alloc(allocator, image, options);
    defer allocator.free(baseline);
    const compressed: usize = std.mem.readInt(u32, baseline[33..][0..4], .big);
    const capacities = [_]usize{ 0, 1, 4096, compressed - 1, compressed, compressed + 1 };
    const required = try requirements(image, options);
    for (capacities) |capacity| {
        const buffer = try allocator.alloc(u8, capacity + 2);
        defer allocator.free(buffer);
        @memset(buffer, 0xa5);
        options.limits.maximum_scratch_bytes = required.workspace_bytes + capacity;
        const result = try allocWithRetention(
            allocator,
            allocator,
            image,
            options,
            buffer[1..][0..capacity],
        );
        defer allocator.free(result);
        try std.testing.expectEqualSlices(u8, baseline, result);
        try std.testing.expectEqual(@as(u8, 0xa5), buffer[0]);
        try std.testing.expectEqual(@as(u8, 0xa5), buffer[capacity + 1]);
        options.limits.maximum_scratch_bytes -= 1;
        try std.testing.expectError(
            error.ScratchBudgetExceeded,
            allocWithRetention(allocator, allocator, image, options, buffer[1..][0..capacity]),
        );
    }
}

test "retained PNG allocation shares fixed storage without replay" {
    const allocator = std.testing.allocator;
    const width = 128;
    const height = 128;
    const pixels = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(pixels);
    var generator: std.Random.DefaultPrng = .init(0x6ef28);
    generator.random().bytes(pixels);
    const image = try ImageInput.rgba8(pixels, width, height);
    const options: Options = .{
        .filter = .{ .fixed = .up },
        .compression = .{ .strategy = .four_byte_runs },
    };
    const expected = try alloc(allocator, image, options);
    defer allocator.free(expected);
    const compressed: usize = std.mem.readInt(u32, expected[33..][0..4], .big);
    try std.testing.expect(compressed > 4096);
    const required = try requirements(image, options);
    const compact_bytes = try encoding_workspace.FourByteRunWorkspace.byteCount(
        required.workspace_extra_bytes,
    );
    const extra = @max(compact_bytes, expected.len);
    const backing = try allocator.alloc(u8, compressed + extra);
    defer allocator.free(backing);
    for ([_]usize{ compressed - 1, compressed }) |capacity| {
        var fixed: std.heap.FixedBufferAllocator = .init(backing[0 .. capacity + extra]);
        const retention = try fixed.allocator().alloc(u8, capacity);
        if (capacity < compressed) {
            try std.testing.expectError(
                error.OutOfMemory,
                allocWithRetention(fixed.allocator(), fixed.allocator(), image, options, retention),
            );
            try std.testing.expectEqual(capacity, fixed.end_index);
        } else {
            const actual = try allocWithRetention(
                fixed.allocator(),
                fixed.allocator(),
                image,
                options,
                retention,
            );
            try std.testing.expectEqualSlices(u8, expected, actual);
            fixed.allocator().free(actual);
            try std.testing.expectEqual(capacity, fixed.end_index);
        }
        fixed.allocator().free(retention);
        try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
    }
}

fn retainedAllocationFailure(allocator: std.mem.Allocator) !void {
    const image = try ImageInput.rgba8(&.{ 1, 2, 3, 4, 5, 6, 7, 8 }, 2, 1);
    var retained: [2048]u8 = undefined;
    const result = try allocWithRetention(allocator, allocator, image, .{}, &retained);
    allocator.free(result);
}

test "retained PNG allocation handles metadata, chunks, limits and failures" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(u8, 33 * 19 * 4);
    defer allocator.free(pixels);
    for (pixels, 0..) |*byte, i| byte.* = @truncate(i *% 53 +% i / 17);
    const image = try ImageInput.rgba8(pixels, 33, 19);
    var options: Options = .{
        .filter = .adaptive,
        .interlace = .adam7,
        .compression = .{ .strategy = .four_byte_runs },
        .data_chunk_bytes = 17,
        .metadata = .{
            .icc_profile = .{ .name = "profile", .bytes = testing_encoding.srgb_icc },
            .texts = &.{
                .{ .keyword = "Description", .data = "compressed metadata", .compress = true },
            },
        },
    };
    const expected = try alloc(allocator, image, options);
    defer allocator.free(expected);
    const buffer = try allocator.alloc(u8, 32768);
    defer allocator.free(buffer);
    for ([_]usize{ 0, 32, 4096, buffer.len }) |capacity| {
        const result = try allocWithRetention(
            allocator,
            allocator,
            image,
            options,
            buffer[0..capacity],
        );
        defer allocator.free(result);
        try std.testing.expectEqualSlices(u8, expected, result);
    }
    options.limits.maximum_output_bytes = expected.len - 1;
    try std.testing.expectError(
        error.OutputBudgetExceeded,
        allocWithRetention(allocator, allocator, image, options, buffer),
    );
    try std.testing.checkAllAllocationFailures(allocator, retainedAllocationFailure, .{});
}

fn controlImage(control: testing_encoding.Control) ImageInput {
    const transparency: format.Transparency = switch (control.color_type) {
        0 => .{ .grayscale = 0 },
        2 => .{ .truecolor = .{ 0, 17, 34 } },
        3 => .{ .palette = control.alpha },
        else => .none,
    };
    return .{
        .width = control.width,
        .height = control.height,
        .color_type = @fromBackingInt(control.color_type),
        .bit_depth = control.bit_depth,
        .samples = .{ .packed_bytes = .{ .bytes = control.bytes, .stride = control.stride } },
        .palette = control.palette,
        .transparency = transparency,
    };
}

test "sequential packed row batches preserve Up history and skip stride padding" {
    const allocator = std.testing.allocator;
    inline for (
        .{ 12, 15, 16, 17, 31, 32, 33, 254, 255, 256, 4094, 4095, 4096, 8190, 8191, 8192 },
    ) |row_bytes| {
        const height = if (row_bytes >= 4094) 7 else 19;
        const stride = row_bytes + 4;
        var pixels: [stride * (height - 1) + row_bytes]u8 = @splat(0xa5);
        for (0..height) |y| for (0..row_bytes) |x| {
            pixels[y * stride + x] = @truncate(y * 17 + x);
        };
        const image: ImageInput = .{
            .width = row_bytes,
            .height = height,
            .color_type = .grayscale,
            .bit_depth = 8,
            .samples = .{ .packed_bytes = .{ .bytes = &pixels, .stride = stride } },
        };
        const encoded = try alloc(
            allocator,
            image,
            .{ .filter = .{ .fixed = .up }, .compression = .{ .level = 0 } },
        );
        defer allocator.free(encoded);
        const compressed_len = std.mem.readInt(u32, encoded[33..][0..4], .big);
        try std.testing.expectEqualStrings("IDAT", encoded[37..41]);
        const workspace = try zlib.DecoderWorkspace.create(allocator);
        defer workspace.destroy(allocator);
        var history: [32768]u8 = undefined;
        var filtered: [height * (row_bytes + 1)]u8 = undefined;
        const result = try zlib.decode(
            encoded[41..][0..compressed_len],
            &filtered,
            .{ .workspace = workspace, .history = &history },
            .{},
        );
        try std.testing.expectEqual(@as(usize, filtered.len), result.produced);
        for (0..height) |y| {
            const row = filtered[y * (row_bytes + 1) ..][0 .. row_bytes + 1];
            try std.testing.expectEqual(@as(u8, 2), row[0]);
            for (0..row_bytes) |x| {
                const expected: u8 = if (y == 0) @truncate(x) else 17;
                try std.testing.expectEqual(expected, row[x + 1]);
            }
        }
    }
}

test "PNG encoding preserves every packed profile across filters and odd Adam7 edges" {
    const allocator = std.testing.allocator;
    const filters = [_]Filter{
        .{ .fixed = .none },
        .{ .fixed = .sub },
        .{ .fixed = .up },
        .{ .fixed = .average },
        .{ .fixed = .paeth },
        .adaptive,
    };
    for (testing_encoding.controls) |control| {
        for (filters) |filter| {
            for ([_]Interlace{ .none, .adam7 }) |interlace| {
                const encoded = try allocWithScratch(
                    allocator,
                    allocator,
                    controlImage(control),
                    .{ .filter = filter, .interlace = interlace, .compression = .{ .level = 3 } },
                );
                defer allocator.free(encoded);
                const source = try SourceImage.open(encoded, .{ .maximum_source_extent = 16 });
                try std.testing.expectEqual(control.color_type, source.color_type);
                try std.testing.expectEqual(control.bit_depth, source.bit_depth);
                try std.testing.expectEqual(@backingInt(interlace), source.interlace_method);
                var decoded = try owned_decode.rgbaAlloc(u16, allocator, encoded, .{});
                defer decoded.deinit(allocator);
                try std.testing.expectEqualSlices(u16, control.rgba16, decoded.texels);
            }
        }
    }
}

test "PNG encoding serializes padded native words without reducing channel precision" {
    const allocator = std.testing.allocator;
    for (testing_encoding.controls) |control| {
        if (control.bit_depth != 16) continue;
        var image = controlImage(control);
        const row_words = @as(usize, control.width) * image.color_type.channels();
        const stride = row_words + 2;
        const words = try allocator.alloc(u16, stride * (control.height - 1) + row_words);
        defer allocator.free(words);
        @memset(words, 0x5aa5);
        for (0..control.height) |y| for (0..row_words) |x| {
            words[y * stride + x] = std.mem.readInt(
                u16,
                control.bytes[y * control.stride + x * 2 ..][0..2],
                .big,
            );
        };
        image.samples = .{ .words = .{ .values = words, .stride = stride } };
        for ([_]Interlace{ .none, .adam7 }) |interlace| {
            for (
                [_]zlib.Compression{
                    .{ .level = 0 },
                    .{ .strategy = .huffman_only },
                    .{ .level = 3 },
                    .{ .level = 9 },
                },
            ) |method| {
                const encoded = try allocWithScratch(
                    allocator,
                    allocator,
                    image,
                    .{ .filter = .adaptive, .interlace = interlace, .compression = method },
                );
                defer allocator.free(encoded);
                var decoded = try owned_decode.rgbaAlloc(u16, allocator, encoded, .{});
                defer decoded.deinit(allocator);
                try std.testing.expectEqualSlices(u16, control.rgba16, decoded.texels);
            }
        }
    }
    const bytes = try allocWithScratch(
        allocator,
        allocator,
        try ImageInput.rgba16(&.{ 0x0123, 0xabcd, 0xffff, 0x8080 }, 1, 1),
        .{ .filter = .adaptive, .compression = .{ .level = 6 }, .interlace = .adam7 },
    );
    defer allocator.free(bytes);
    var decoded = try owned_decode.rgbaAlloc(u16, allocator, bytes, .{});
    defer decoded.deinit(allocator);
    try std.testing.expectEqualSlices(u16, &.{ 0x0123, 0xabcd, 0xffff, 0x8080 }, decoded.texels);
}

test "PNG segmented IDAT preserves complete zlib and independent byte word profile pixels" {
    const allocator = std.testing.allocator;
    for (testing_encoding.controls) |control| {
        for ([_]Interlace{ .none, .adam7 }) |interlace| {
            const baseline = try allocWithScratch(
                allocator,
                allocator,
                controlImage(control),
                .{
                    .interlace = interlace,
                    .compression = .{ .level = 3 },
                    .filter = .{ .fixed = .sub },
                },
            );
            defer allocator.free(baseline);
            const original = try SourceImage.open(baseline, .{ .maximum_source_extent = 16 });
            var original_parts = original.image_data.payloads();
            const zlib_bytes = original_parts.next().?;
            try std.testing.expectEqual(null, original_parts.next());
            for ([_]usize{ 1, 2, 13, 64, 0x7fff_ffff }) |limit| {
                const encoded = try allocWithScratch(
                    allocator,
                    allocator,
                    controlImage(control),
                    .{
                        .interlace = interlace,
                        .data_chunk_bytes = limit,
                        .compression = .{ .level = 3 },
                        .filter = .{ .fixed = .sub },
                    },
                );
                defer allocator.free(encoded);
                const image = try SourceImage.open(encoded, .{ .maximum_source_extent = 16 });
                var parts = image.image_data.payloads();
                var offset: usize = 0;
                var records: usize = 0;
                while (parts.next()) |part| {
                    try std.testing.expect(part.len != 0 and part.len <= limit);
                    try std.testing.expectEqualSlices(u8, zlib_bytes[offset..][0..part.len], part);
                    offset += part.len;
                    records += 1;
                }
                try std.testing.expectEqual(zlib_bytes.len, offset);
                try std.testing.expectEqual((zlib_bytes.len + limit - 1) / limit, records);
                if (limit == 0x7fff_ffff) try std.testing.expectEqualSlices(u8, baseline, encoded);
                var decoded = try owned_decode.rgbaAlloc(u16, allocator, encoded, .{});
                defer decoded.deinit(allocator);
                try std.testing.expectEqualSlices(u16, control.rgba16, decoded.texels);
            }
        }
    }
}

test "PNG segmented IDAT admits exact framing records output and invalid-limit refusals" {
    const image: ImageInput = .{
        .width = 1,
        .height = 1,
        .color_type = .rgba,
        .bit_depth = 8,
        .samples = .{ .packed_bytes = .{ .bytes = &.{ 1, 2, 3, 4 } } },
    };
    var output_allocator = std.testing.failing_allocator;
    var scratch_allocator = std.testing.failing_allocator;
    var options: Options = .{ .compression = .{ .level = 3 }, .filter = .{ .fixed = .sub } };
    for ([_]usize{ 0, 0x8000_0000 }) |limit| {
        options.data_chunk_bytes = limit;
        try std.testing.expectError(
            error.InvalidDataChunkSize,
            allocWithScratch(output_allocator, scratch_allocator, image, options),
        );
    }
    output_allocator = std.testing.allocator;
    scratch_allocator = std.testing.allocator;
    options.compression = .{ .level = 0 };
    options.filter = .{ .fixed = .none };
    options.data_chunk_bytes = 1;
    // Five filtered bytes use one final stored block: zlib header (2), block header (5), samples
    // (5) and Adler-32 (4). Sixteen one-byte IDATs plus the PNG signature, IHDR and IEND occupy 45
    // + 16 * 13 = 253 bytes.
    const expected_zlib = &[_]u8{
        0x78, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff, 0x00,
        0x01, 0x02, 0x03, 0x04, 0x00, 0x19, 0x00, 0x0b,
    };
    options.limits = .{
        .maximum_records = 18,
        .maximum_output_bytes = 253,
        .maximum_metadata_bytes = 13,
    };
    const encoded = try allocWithScratch(output_allocator, scratch_allocator, image, options);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(253, encoded.len);
    const source = try SourceImage.open(encoded, .{ .maximum_source_extent = 1 });
    var parts = source.image_data.payloads();
    var records: usize = 0;
    while (parts.next()) |part| {
        try std.testing.expectEqual(1, part.len);
        try std.testing.expectEqual(expected_zlib[records], part[0]);
        records += 1;
    }
    try std.testing.expectEqual(16, records);
    output_allocator = std.testing.failing_allocator;
    options.limits.maximum_records = 17;
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.limits.maximum_records = 18;
    options.limits.maximum_output_bytes = 252;
    try std.testing.expectError(
        error.OutputBudgetExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
}

test "PNG segmented IDAT preserves native words Adam7 and compressed metadata" {
    const allocator = std.testing.allocator;
    const words = [_]u16{
        0x0123, 0xabcd, 0xffff, 0x8080, 0x0000, 0x4444, 0xeeee, 0x0000,
        0xfedc, 0x7654, 0x3210, 0xffff, 0x1111, 0x2222, 0x3333, 0x4444,
    };
    for (
        [_]zlib.Compression{ .{ .level = 0 }, .{ .strategy = .huffman_only }, .{ .level = 9 } },
    ) |method| {
        const encoded = try allocWithScratch(
            allocator,
            allocator,
            try ImageInput.rgba16(&words, 2, 2),
            .{
                .filter = .adaptive,
                .compression = method,
                .interlace = .adam7,
                .data_chunk_bytes = 13,
                .metadata = .{
                    .gamma = 45455,
                    .texts = &.{
                        .{
                            .keyword = "Test",
                            .data = "metadata across data chunks",
                            .compress = true,
                        },
                    },
                },
            },
        );
        defer allocator.free(encoded);
        const source = try SourceImage.open(encoded, .{ .maximum_source_extent = 2 });
        var parts = source.image_data.payloads();
        var count: usize = 0;
        while (parts.next()) |part| {
            try std.testing.expect(part.len > 0 and part.len <= 13);
            count += 1;
        }
        try std.testing.expect(count > 1);
        var decoded = try owned_decode.rgbaAlloc(u16, allocator, encoded, .{});
        defer decoded.deinit(allocator);
        try std.testing.expectEqualSlices(u16, &words, decoded.texels);
    }
}

test "PNG owned encoding retains or replays at the compressed stream boundary" {
    const allocator = std.testing.allocator;
    var samples: [4085]u8 = undefined;
    var generator: std.Random.DefaultPrng = .init(0xb62f);
    generator.random().bytes(&samples);
    for (4095..4098) |stream_bytes| {
        const width = stream_bytes - 12; // one filter byte and eleven zlib stored-stream bytes
        const image: ImageInput = .{
            .width = @intCast(width),
            .height = 1,
            .color_type = .grayscale,
            .bit_depth = 8,
            .samples = .{ .packed_bytes = .{ .bytes = samples[0..width] } },
        };
        var scratch = std.testing.FailingAllocator.init(allocator, .{});
        const encoded = try allocWithScratch(
            allocator,
            scratch.allocator(),
            image,
            .{ .filter = .{ .fixed = .none }, .compression = .{ .level = 0 } },
        );
        defer allocator.free(encoded);
        const source = try SourceImage.open(encoded, .{});
        try std.testing.expectEqual(stream_bytes, source.image_data.byte_count);
        try std.testing.expectEqual(
            @as(usize, if (stream_bytes <= 4096) 1 else 2),
            scratch.allocations,
        );
        try std.testing.expectEqual(scratch.allocations, scratch.deallocations);
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
        const retry = allocWithScratch(
            allocator,
            failing.allocator(),
            image,
            .{ .filter = .{ .fixed = .none }, .compression = .{ .level = 0 } },
        );
        if (stream_bytes <= 4096) {
            const retained = try retry;
            defer allocator.free(retained);
            try std.testing.expectEqualSlices(u8, encoded, retained);
        } else {
            try std.testing.expectError(error.OutOfMemory, retry);
        }
        try std.testing.expectEqual(failing.allocations, failing.deallocations);
        var decoded = try owned_decode.rgbaAlloc(u8, allocator, encoded, .{});
        defer decoded.deinit(allocator);
        for (samples[0..width], 0..) |sample, x| {
            try std.testing.expectEqualSlices(
                u8,
                &.{ sample, sample, sample, 255 },
                decoded.texels[x * 4 ..][0..4],
            );
        }
    }
}

test "PNG segmented IDAT replay failures restore aliased caller storage and source" {
    const allocator = std.testing.allocator;
    const texels = try makeEncodingFixture(allocator, 65, 19, true);
    defer allocator.free(texels);
    const original = try allocator.dupe(u8, texels);
    defer allocator.free(original);
    const expected = try allocWithScratch(
        allocator,
        allocator,
        try ImageInput.rgba8(texels, 65, 19),
        .{ .data_chunk_bytes = 13, .compression = .{ .level = 3 }, .filter = .{ .fixed = .sub } },
    );
    defer allocator.free(expected);
    // The random source exceeds the counter's 4 KiB buffer, exercising replay scratch after output
    // reservation. One misaligned bounded region supplies both authorities.
    const source = try SourceImage.open(expected, .{});
    try std.testing.expect(source.image_data.byte_count > 4096);
    const scratch_bytes = try scratchByteCount(65 * 4 + 1);
    const backing = try allocator.alloc(u8, 1 + 7 + expected.len + scratch_bytes);
    defer allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing[1..]);
    const prefix = try fixed.allocator().alloc(u8, 7);
    @memset(prefix, 0x5a);

    for (0..3) |allocator_mode| {
        var completed = false;
        for (0..16) |fail_index| {
            var failing = std.testing.FailingAllocator.init(
                fixed.allocator(),
                .{ .fail_index = fail_index, .resize_fail_index = 0 },
            );
            const output = if (allocator_mode == 1) fixed.allocator() else failing.allocator();
            const scratch = if (allocator_mode == 2) fixed.allocator() else failing.allocator();
            if (allocWithScratch(
                output,
                scratch,
                try ImageInput.rgba8(texels, 65, 19),
                .{
                    .data_chunk_bytes = 13,
                    .compression = .{ .level = 3 },
                    .filter = .{ .fixed = .sub },
                },
            )) |encoded| {
                try std.testing.expectEqualSlices(u8, expected, encoded);
                try std.testing.expectEqual(prefix.len + encoded.len, fixed.end_index);
                output.free(encoded);
                completed = true;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(failing.has_induced_failure);
            }
            try std.testing.expectEqual(prefix.len, fixed.end_index);
            for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
            try std.testing.expectEqualSlices(u8, original, texels);
            if (completed) break;
        }
        try std.testing.expect(completed);
    }
    var decoded = try owned_decode.rgbaAlloc(u8, allocator, expected, .{});
    defer decoded.deinit(allocator);
    try std.testing.expectEqualSlices(u8, original, decoded.texels);
}

test "PNG encoding refuses unsupported descriptors and exhausted policy before allocation" {
    const output_allocator = std.testing.failing_allocator;
    const scratch_allocator = std.testing.failing_allocator;
    var options: Options = .{ .compression = .{ .level = 3 }, .filter = .{ .fixed = .sub } };
    var image: ImageInput = .{
        .width = 1,
        .height = 1,
        .color_type = .rgba,
        .bit_depth = 8,
        .samples = .{ .packed_bytes = .{ .bytes = &.{ 0, 1, 2, 3 } } },
    };
    image.bit_depth = 4;
    try std.testing.expectError(
        error.InvalidSampleDepth,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.bit_depth = 8;
    image.samples = .{ .words = .{ .values = &.{ 0, 1, 2, 3 } } };
    try std.testing.expectError(
        error.InvalidSampleDepth,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.samples = .{ .packed_bytes = .{ .bytes = &.{ 0, 1, 2, 3 }, .stride = 3 } };
    try std.testing.expectError(
        error.InvalidRowStride,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.samples = .{ .packed_bytes = .{ .bytes = &.{ 0, 1, 2 } } };
    try std.testing.expectError(
        error.InvalidTexelCount,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.samples = .{ .packed_bytes = .{ .bytes = &.{ 0, 1, 2, 3 } } };
    image.transparency = .{ .truecolor = .{ 0, 1, 2 } };
    try std.testing.expectError(
        error.InvalidTransparency,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.transparency = .none;
    options.compression = .{ .level = 3 };
    options.limits.maximum_pixels = 0;
    try std.testing.expectError(
        error.PixelBudgetExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.limits = .{ .maximum_output_bytes = 56 };
    try std.testing.expectError(
        error.OutputBudgetExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.limits = .{ .maximum_scratch_bytes = try scratchByteCount(5) - 1 };
    try std.testing.expectError(
        error.ScratchBudgetExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.limits = .{ .maximum_work_units = 15 };
    try std.testing.expectError(
        error.WorkBudgetExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.limits = .{ .maximum_records = 2 };
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.limits = .{ .maximum_metadata_bytes = 12 };
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    options.limits = .{};
    image.color_type = .indexed;
    try std.testing.expectError(
        error.InvalidPalette,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.palette = &.{.{ 0, 0, 0 }};
    image.samples = .{ .packed_bytes = .{ .bytes = &.{1} } };
    try std.testing.expectError(
        error.InvalidPaletteIndex,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.bit_depth = 1;
    image.palette = &.{ .{ 0, 0, 0 }, .{ 1, 2, 3 }, .{ 4, 5, 6 } };
    try std.testing.expectError(
        error.InvalidPalette,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.color_type = .grayscale;
    try std.testing.expectError(
        error.InvalidPalette,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
    image.palette = &.{};
    image.transparency = .{ .grayscale = 2 };
    try std.testing.expectError(
        error.InvalidTransparency,
        allocWithScratch(output_allocator, scratch_allocator, image, options),
    );
}

test "PNG encoding omits an empty palette alpha table under exact metadata budgets" {
    const allocator = std.testing.allocator;
    const encoded = try allocWithScratch(
        allocator,
        allocator,
        .{
            .width = 1,
            .height = 1,
            .color_type = .indexed,
            .bit_depth = 1,
            .samples = .{ .packed_bytes = .{ .bytes = &.{0} } },
            .palette = &.{.{ 11, 23, 45 }},
            .transparency = .{ .palette = &.{} },
        },
        .{
            .limits = .{
                .maximum_records = 4,
                .maximum_metadata_bytes = 16,
                .maximum_work_units = 5,
            },
            .compression = .{ .level = 3 },
            .filter = .{ .fixed = .sub },
        },
    );
    defer allocator.free(encoded);
    _ = try SourceImage.open(encoded, .{ .maximum_source_extent = 1, .maximum_records = 4 });
    var decoded = try owned_decode.rgbaAlloc(u16, allocator, encoded, .{});
    defer decoded.deinit(allocator);
    try std.testing.expectEqualSlices(u16, &.{ 0x0b0b, 0x1717, 0x2d2d, 0xffff }, decoded.texels);
}

test "RGBA encoding preserves samples across rows and compression history" {
    const allocator = std.testing.allocator;
    const width = 257;
    const height = 67;
    const texels = try allocator.alloc(u8, width * height * 4);
    defer allocator.free(texels);
    for (texels, 0..) |*value, index| value.* = @truncate(index * 131 + index / 7);
    const encoded = try allocWithScratch(
        allocator,
        allocator,
        try ImageInput.rgba8(texels, width, height),
        .{ .compression = .{ .level = 3 }, .filter = .{ .fixed = .sub } },
    );
    defer allocator.free(encoded);
    var decoded = try owned_decode.rgbaAlloc(u8, allocator, encoded, .{});
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(width, decoded.width);
    try std.testing.expectEqual(height, decoded.height);
    try std.testing.expectEqualSlices(u8, texels, decoded.texels);
}

fn encodeAllocationFailure(allocator: std.mem.Allocator) !void {
    const encoded = try allocWithScratch(
        allocator,
        allocator,
        try ImageInput.rgba8(&.{ 1, 2, 3, 0, 4, 5, 6, 255 }, 2, 1),
        .{ .compression = .{ .level = 3 }, .filter = .{ .fixed = .sub } },
    );
    defer allocator.free(encoded);
}

test "RGBA encoding releases scratch and partial output on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, encodeAllocationFailure, .{});
}

test "RGBA encoding reclaims bounded scratch when the compressed stream grows" {
    const allocator = std.testing.allocator;
    const texels = try makeEncodingFixture(allocator, 128, 128, true);
    defer allocator.free(texels);
    const backing = try allocator.alloc(
        u8,
        try scratchByteCount(128 * 4 + 1) + texels.len * 2 + 4096,
    );
    defer allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    const prefix = try fixed.allocator().alloc(u8, 64);
    @memset(prefix, 0x5a);

    for ([_]bool{ false, true }) |deny_remap| {
        var wrapper = std.testing.FailingAllocator.init(
            fixed.allocator(),
            .{ .resize_fail_index = if (deny_remap) 0 else std.math.maxInt(usize) },
        );
        for (0..8) |_| {
            const encoded = try allocWithScratch(
                allocator,
                wrapper.allocator(),
                try ImageInput.rgba8(texels, 128, 128),
                .{ .compression = .{ .level = 3 }, .filter = .{ .fixed = .sub } },
            );
            defer allocator.free(encoded);
            try std.testing.expect(encoded.len > 4096);
            try std.testing.expectEqual(prefix.len, fixed.end_index);
            for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
        }
    }
}

test "RGBA encoding shares bounded storage without retaining scratch or alignment gaps" {
    const allocator = std.testing.allocator;
    for (
        [_]struct {
            width: u32,
            height: u32,
            random: bool,
        }{
            .{ .width = 1, .height = 1, .random = false },
            .{ .width = 8, .height = 7, .random = false },
            .{ .width = 128, .height = 128, .random = true },
            .{ .width = 129, .height = 257, .random = false },
        },
    ) |fixture| {
        const texels = try makeEncodingFixture(
            allocator,
            fixture.width,
            fixture.height,
            fixture.random,
        );
        defer allocator.free(texels);
        const source_hash = std.hash.Wyhash.hash(0, texels);
        const expected = try allocWithScratch(
            allocator,
            allocator,
            try ImageInput.rgba8(texels, fixture.width, fixture.height),
            .{ .compression = .{ .level = 3 }, .filter = .{ .fixed = .sub } },
        );
        defer allocator.free(expected);
        const scratch_bytes = try scratchByteCount(@as(usize, fixture.width) * 4 + 1);
        const backing = try allocator.alloc(u8, 1 + 64 + expected.len + scratch_bytes);
        defer allocator.free(backing);

        for ([_]usize{ 1, 7, 64 }) |prefix_bytes| {
            // Shift the backing address too: scratch must contain its own compressor alignment
            // padding rather than leave it above output.
            var fixed = std.heap.FixedBufferAllocator.init(
                backing[1..][0 .. prefix_bytes + expected.len + scratch_bytes],
            );
            const prefix = try fixed.allocator().alloc(u8, prefix_bytes);
            @memset(prefix, 0x5a);
            for (0..3) |allocator_mode| {
                var wrapper = std.testing.FailingAllocator.init(
                    fixed.allocator(),
                    .{ .resize_fail_index = 0 },
                );
                const output = if (allocator_mode == 1) wrapper.allocator() else fixed.allocator();
                const scratch = if (allocator_mode == 0) fixed.allocator() else wrapper.allocator();
                for (0..8) |_| {
                    {
                        const encoded = try allocWithScratch(
                            output,
                            scratch,
                            try ImageInput.rgba8(texels, fixture.width, fixture.height),
                            .{ .compression = .{ .level = 3 }, .filter = .{ .fixed = .sub } },
                        );
                        defer output.free(encoded);
                        try std.testing.expectEqualSlices(u8, expected, encoded);
                        try std.testing.expectEqual(prefix.len + encoded.len, fixed.end_index);
                    }
                    try std.testing.expectEqual(prefix.len, fixed.end_index);
                    for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
                    try std.testing.expectEqual(source_hash, std.hash.Wyhash.hash(0, texels));
                }
            }
        }
        var decoded = try owned_decode.rgbaAlloc(u8, allocator, expected, .{});
        defer decoded.deinit(allocator);
        try std.testing.expectEqualSlices(u8, texels, decoded.texels);
    }
}

test "RGBA encoding failures restore shared caller storage" {
    const allocator = std.testing.allocator;
    const texels = try makeEncodingFixture(allocator, 128, 128, true);
    defer allocator.free(texels);
    const backing = try allocator.alloc(
        u8,
        try scratchByteCount(128 * 4 + 1) + texels.len * 2 + 4096,
    );
    defer allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing[1..]);
    const prefix = try fixed.allocator().alloc(u8, 7);
    @memset(prefix, 0x5a);

    for (0..3) |allocator_mode| {
        var completed = false;
        for (0..16) |fail_index| {
            var failing = std.testing.FailingAllocator.init(
                fixed.allocator(),
                .{ .fail_index = fail_index, .resize_fail_index = 0 },
            );
            const output = if (allocator_mode == 1) fixed.allocator() else failing.allocator();
            const scratch = if (allocator_mode == 2) fixed.allocator() else failing.allocator();
            if (allocWithScratch(
                output,
                scratch,
                try ImageInput.rgba8(texels, 128, 128),
                .{ .compression = .{ .level = 3 }, .filter = .{ .fixed = .sub } },
            )) |encoded| {
                output.free(encoded);
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

    const expected = try allocWithScratch(
        allocator,
        allocator,
        try ImageInput.rgba8(texels, 128, 128),
        .{ .compression = .{ .level = 3 }, .filter = .{ .fixed = .sub } },
    );
    defer allocator.free(expected);
    const scratch_bytes = try scratchByteCount(128 * 4 + 1);
    fixed.buffer = backing[1..][0 .. prefix.len + expected.len + scratch_bytes - 1];
    // Counting fits and exact output fits, but replay has one byte too little workspace. Its failed
    // reservation must release the unpublished output.
    try std.testing.expectError(
        error.OutOfMemory,
        allocWithScratch(
            fixed.allocator(),
            fixed.allocator(),
            try ImageInput.rgba8(texels, 128, 128),
            .{ .compression = .{ .level = 3 }, .filter = .{ .fixed = .sub } },
        ),
    );
    try std.testing.expectEqual(prefix.len, fixed.end_index);
    for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
}

test "PNG extended encoding retires every metadata and Adam7 workspace in shared storage" {
    const allocator = std.testing.allocator;
    const width = 33;
    const height = 19;
    const words = try allocator.alloc(u16, width * height * 4);
    defer allocator.free(words);
    var generator: std.Random.DefaultPrng = .init(0x436283);
    generator.random().bytes(std.mem.sliceAsBytes(words));
    const source_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(words));
    const description: MetadataInput = .{
        .icc_profile = .{ .name = "sRGB profile", .bytes = testing_encoding.srgb_icc },
        .exif_payload = testing_encoding.exif_little,
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
    };
    var output_allocator = allocator;
    var scratch_allocator = allocator;
    const options: Options = .{
        .metadata = description,
        .filter = .adaptive,
        .interlace = .adam7,
        .compression = .{ .level = 9 },
    };
    const expected = try allocWithScratch(
        output_allocator,
        scratch_allocator,
        try ImageInput.rgba16(words, width, height),
        options,
    );
    defer allocator.free(expected);
    const source = try SourceImage.open(expected, .{});
    try std.testing.expect(source.image_data.byte_count > 4096);
    const scratch_bytes = try scratchByteCount(width * 8 + 1);
    const backing = try allocator.alloc(u8, 1 + 7 + expected.len + scratch_bytes);
    defer allocator.free(backing);
    var fixed = std.heap.FixedBufferAllocator.init(backing[1..]);
    const prefix = try fixed.allocator().alloc(u8, 7);
    @memset(prefix, 0x5a);

    for (0..3) |mode| {
        var completed = false;
        for (0..24) |fail_index| {
            var failing = std.testing.FailingAllocator.init(
                fixed.allocator(),
                .{ .fail_index = fail_index, .resize_fail_index = 0 },
            );
            output_allocator = if (mode == 1) fixed.allocator() else failing.allocator();
            scratch_allocator = if (mode == 2) fixed.allocator() else failing.allocator();
            if (allocWithScratch(
                output_allocator,
                scratch_allocator,
                try ImageInput.rgba16(words, width, height),
                options,
            )) |encoded| {
                try std.testing.expectEqualSlices(u8, expected, encoded);
                try std.testing.expectEqual(prefix.len + expected.len, fixed.end_index);
                output_allocator.free(encoded);
                completed = true;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(failing.has_induced_failure);
            }
            try std.testing.expectEqual(prefix.len, fixed.end_index);
            try std.testing.expectEqual(
                source_hash,
                std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(words)),
            );
            for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
            if (completed) break;
        }
        try std.testing.expect(completed);
    }
    output_allocator = fixed.allocator();
    scratch_allocator = fixed.allocator();
    for (0..8) |_| {
        const encoded = try allocWithScratch(
            output_allocator,
            scratch_allocator,
            try ImageInput.rgba16(words, width, height),
            options,
        );
        try std.testing.expectEqualSlices(u8, expected, encoded);
        try std.testing.expectEqual(prefix.len + expected.len, fixed.end_index);
        fixed.allocator().free(encoded);
        try std.testing.expectEqual(prefix.len, fixed.end_index);
    }
    // Every count and the output fit, but replay's row span is one byte short.
    fixed.buffer = backing[1 .. backing.len - 1];
    try std.testing.expectError(
        error.OutOfMemory,
        allocWithScratch(
            output_allocator,
            scratch_allocator,
            try ImageInput.rgba16(words, width, height),
            options,
        ),
    );
    try std.testing.expectEqual(prefix.len, fixed.end_index);
}

fn makeEncodingFixture(allocator: std.mem.Allocator, width: u32, height: u32, random: bool) ![]u8 {
    const texels = try allocator.alloc(u8, @as(usize, width) * height * 4);
    if (random) {
        var generator: std.Random.DefaultPrng = .init(0x5a1752);
        generator.random().bytes(texels);
    } else {
        @memset(texels, 0x45);
    }
    return texels;
}

test "PNG prepared encoding preserves every layout filter Adam7 and exact output policy" {
    const allocator = std.testing.allocator;
    var maximum_extra: usize = 0;
    for (
        testing_encoding.controls,
    ) |control| maximum_extra = @max(maximum_extra, (control.stride + 1) * 3);
    const workspace_bytes = try EncoderWorkspace.byteCount(maximum_extra);
    const backing = try allocator.alloc(u8, workspace_bytes + 2);
    defer allocator.free(backing);
    @memset(backing, 0x3c);
    const workspace = try EncoderWorkspace.initBuffer(backing[1 .. backing.len - 1], maximum_extra);
    var output: [4096]u8 = undefined;
    const filters = [_]Filter{
        .{ .fixed = .none },
        .{ .fixed = .sub },
        .{ .fixed = .up },
        .{ .fixed = .average },
        .{ .fixed = .paeth },
        .adaptive,
    };
    for (testing_encoding.controls) |control| {
        for (filters) |filter| {
            for ([_]Interlace{ .none, .adam7 }) |interlace| {
                const image = controlImage(control);
                const options: Options = .{
                    .filter = filter,
                    .interlace = interlace,
                    .data_chunk_bytes = 7,
                };
                const required = try requirements(image, options);
                try std.testing.expect(required.output_bytes < output.len - 2);
                @memset(&output, 0xa5);
                const encoded = try into(image, output[1..], workspace, options);
                const exact = try alloc(allocator, image, options);
                defer allocator.free(exact);
                try std.testing.expectEqualSlices(u8, exact, encoded);
                var decoded = try owned_decode.rgbaAlloc(u16, allocator, encoded, .{});
                defer decoded.deinit(allocator);
                try std.testing.expectEqualSlices(u16, control.rgba16, decoded.texels);
                try std.testing.expectEqual(0xa5, output[0]);
                for (output[1 + encoded.len ..]) |byte| try std.testing.expectEqual(0xa5, byte);
                try std.testing.expectEqual(0x3c, backing[0]);
                try std.testing.expectEqual(0x3c, backing[backing.len - 1]);
                @memset(&output, 0xa5);
                try std.testing.expectError(
                    error.OutputTooSmall,
                    into(image, output[0 .. required.output_bytes - 1], workspace, options),
                );
                const short = try EncoderWorkspace.initBuffer(
                    backing[1..],
                    required.workspace_extra_bytes - 1,
                );
                try std.testing.expectError(
                    error.WorkspaceTooSmall,
                    into(image, &output, short, options),
                );
                for (output) |byte| try std.testing.expectEqual(0xa5, byte);
                var exact_policy = options;
                exact_policy.limits.maximum_output_bytes = exact.len;
                // The output bound is larger than the actual output policy. Only used bytes count.
                const limited = try into(image, &output, workspace, exact_policy);
                try std.testing.expectEqualSlices(u8, exact, limited);
            }
        }
    }
}

test into {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128 };
    const image: ImageInput = .{
        .width = 2,
        .height = 1,
        .color_type = .rgba,
        .bit_depth = 8,
        .samples = .{ .packed_bytes = .{ .bytes = &pixels } },
    };
    const required = try requirements(image, .{});
    var workspace = try EncoderWorkspace.initCapacity(allocator, required.workspace_extra_bytes);
    defer workspace.deinit(allocator);
    const output = try allocator.alloc(u8, required.output_bytes);
    defer allocator.free(output);
    const encoded = try into(image, output, workspace, .{});
    const source = try SourceImage.open(encoded, .{});
    try std.testing.expectEqual(2, source.width);
    try std.testing.expectEqual(1, source.height);
}

test "default PNG compression permits level and strategy mutation" {
    const allocator = std.testing.allocator;
    const pixels = [_]u16{ 0x1234, 0x4567, 0x89ab, 0xffff };
    const image = try ImageInput.rgba16(&pixels, 1, 1);
    var options: Options = .{};
    for (0..10) |level| {
        options.compression.level = @intCast(level);
        for ([_]zlib.Compression.Strategy{ .default, .huffman_only, .four_byte_runs }) |strategy| {
            options.compression.strategy = strategy;
            _ = try requirements(image, options);
            const encoded = try alloc(allocator, image, options);
            defer allocator.free(encoded);
            var decoded = try owned_decode.rgbaAlloc(u16, allocator, encoded, .{});
            defer decoded.deinit(allocator);
            try std.testing.expectEqualSlices(u16, &pixels, decoded.texels);
        }
    }
}

test "invalid compression is refused before PNG allocation and prepared writes" {
    const allocator = std.testing.allocator;
    const image = try ImageInput.rgba8(&.{ 1, 2, 3, 255 }, 1, 1);
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

test "provisional PNG output preserves shared fixed allocator reclamation" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(u8, 96 * 96 * 4);
    defer allocator.free(pixels);
    var random: std.Random.DefaultPrng = .init(0xe253);
    random.random().bytes(pixels);
    const image = try ImageInput.rgba8(pixels, 96, 96);
    const options: Options = .{
        .filter = .{ .fixed = .up },
        .compression = .{ .strategy = .four_byte_runs },
        .data_chunk_bytes = 1024,
    };
    var stack: [4096]u8 = undefined;
    const expected = try encodeAllocRetained(allocator, allocator, image, options, &stack, false);
    defer allocator.free(expected);
    var no_resize: std.testing.FailingAllocator = .init(allocator, .{ .resize_fail_index = 0 });
    const repeated = try alloc(no_resize.allocator(), image, options);
    try std.testing.expectEqualSlices(u8, expected, repeated);
    no_resize.allocator().free(repeated);
    try std.testing.expectEqual(no_resize.allocated_bytes, no_resize.freed_bytes);
    try std.testing.expectEqual(@as(usize, 4), no_resize.allocations);
    const requirement = try requirements(image, options);
    const capacities = [_]usize{
        requirement.workspace_bytes + expected.len + 128,
        requirement.workspace_bytes + requirement.output_bytes + 128,
    };
    for (capacities) |capacity| {
        const backing = try allocator.alloc(u8, capacity);
        defer allocator.free(backing);
        var fixed: std.heap.FixedBufferAllocator = .init(backing);
        const actual = try alloc(fixed.allocator(), image, options);
        try std.testing.expectEqualSlices(u8, expected, actual);
        fixed.allocator().free(actual);
        try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
    }
}

fn provisionalAllocationFailure(
    allocator: std.mem.Allocator,
    image: ImageInput,
    options: Options,
) !void {
    const output = try alloc(allocator, image, options);
    allocator.free(output);
}

test "provisional PNG output releases persistent allocation failures" {
    var pixels: [96 * 96 * 4]u8 = undefined;
    var random: std.Random.DefaultPrng = .init(0x661c);
    random.random().bytes(&pixels);
    const image = try ImageInput.rgba8(&pixels, 96, 96);
    const options: Options = .{
        .compression = .{ .strategy = .four_byte_runs },
        .filter = .{ .fixed = .up },
        .data_chunk_bytes = 1024,
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        provisionalAllocationFailure,
        .{ image, options },
    );
}

test "short run PNG retains scratch admission without scratch allocation" {
    const allocator = std.testing.allocator;
    var pixels: [22 * 22 * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% i / 7);
    for ([_]u32{ 8, 16, 22 }) |side| {
        const image = try ImageInput.rgba8(pixels[0 .. side * side * 4], side, side);
        var options: Options = .{
            .filter = .{ .fixed = .up },
            .compression = .{ .level = 6, .strategy = .four_byte_runs },
        };
        const admitted = try scratchByteCount(side * 4 + 1);
        options.limits.maximum_scratch_bytes = admitted - 1;
        try std.testing.expectError(
            error.ScratchBudgetExceeded,
            allocWithScratch(allocator, std.testing.failing_allocator, image, options),
        );
        options.limits.maximum_scratch_bytes = admitted;
        const result = try allocWithScratch(
            allocator,
            std.testing.failing_allocator,
            image,
            options,
        );
        defer allocator.free(result);
        try std.testing.expect(result.len > 0);
    }
}

test "PNG streamed bound covers split Up rows and final blocks after exact slabs" {
    const allocator = std.testing.allocator;
    const geometries = [_][2]u32{ .{ 256, 255 }, .{ 256, 510 }, .{ 65534, 1 }, .{ 65535, 1 } };
    for (geometries) |geometry| {
        const width: usize = geometry[0];
        const height: usize = geometry[1];
        const source = try allocator.alloc(u8, width * height);
        defer allocator.free(source);
        var random: std.Random.DefaultPrng = .init(7);
        random.random().bytes(source);
        const image: ImageInput = .{
            .width = geometry[0],
            .height = geometry[1],
            .color_type = .grayscale,
            .bit_depth = 8,
            .samples = .{ .packed_bytes = .{ .bytes = source, .stride = width } },
        };
        for ([_]FilterType{ .none, .up }) |filter| {
            for ([_]u4{ 0, 6 }) |level| {
                const options: Options = .{
                    .filter = .{ .fixed = filter },
                    .compression = .{ .level = level, .strategy = .four_byte_runs },
                    .data_chunk_bytes = 17,
                };
                const required = try requirements(image, options);
                const owned = try alloc(allocator, image, options);
                defer allocator.free(owned);
                try std.testing.expect(owned.len <= required.output_bytes);
                var workspace = try EncoderWorkspace.initCapacity(
                    allocator,
                    required.workspace_extra_bytes,
                );
                defer workspace.deinit(allocator);
                const guarded = try allocator.alloc(u8, required.output_bytes + 2);
                defer allocator.free(guarded);
                @memset(guarded, 0xa5);
                const encoded_into = try into(
                    image,
                    guarded[1..][0..required.output_bytes],
                    workspace,
                    options,
                );
                try std.testing.expectEqualSlices(u8, owned, encoded_into);
                try std.testing.expectEqual(@as(u8, 0xa5), guarded[0]);
                try std.testing.expectEqual(@as(u8, 0xa5), guarded[guarded.len - 1]);
                var decoded = try owned_decode.rgbaAlloc(
                    u8,
                    allocator,
                    owned,
                    .{ .maximum_source_extent = 65535 },
                );
                defer decoded.deinit(allocator);
                for (source, 0..) |value, i| {
                    try std.testing.expectEqualSlices(
                        u8,
                        &.{ value, value, value, 255 },
                        decoded.texels[i * 4 ..][0..4],
                    );
                }
                var limited = options;
                limited.limits.maximum_output_bytes = owned.len - 1;
                try std.testing.expectError(
                    error.OutputBudgetExceeded,
                    alloc(allocator, image, limited),
                );
            }
        }
    }
}

test "PNG owned encoding accepts a context-free allocator" {
    const Stateless = struct {
        const allocator: std.mem.Allocator = .{
            .ptr = undefined,
            .vtable = &.{ .alloc = @This().alloc, .resize = resize, .remap = remap, .free = free },
        };
        fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn resize(
            _: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            len: usize,
            ra: usize,
        ) bool {
            return std.testing.allocator.rawResize(memory, alignment, len, ra);
        }
        fn remap(
            _: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            len: usize,
            ra: usize,
        ) ?[*]u8 {
            return std.testing.allocator.rawRemap(memory, alignment, len, ra);
        }
        fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(memory, alignment, ra);
        }
    };
    const pixels = [_]u8{ 1, 2, 3, 255 };
    const image = try ImageInput.rgba8(&pixels, 1, 1);
    const wire = try alloc(
        Stateless.allocator,
        image,
        .{
            .filter = .{ .fixed = .up },
            .compression = .{ .level = 6, .strategy = .four_byte_runs },
            .data_chunk_bytes = 65536,
        },
    );
    defer Stateless.allocator.free(wire);
    var decoded = try owned_decode.rgbaAlloc(u8, std.testing.allocator, wire, .{});
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &pixels, decoded.texels);
    const large_pixels = try std.testing.allocator.alloc(u8, 96 * 96 * 4);
    defer std.testing.allocator.free(large_pixels);
    var random: std.Random.DefaultPrng = .init(0x5923);
    random.random().bytes(large_pixels);
    const large_image = try ImageInput.rgba8(large_pixels, 96, 96);
    const large_wire = try alloc(
        Stateless.allocator,
        large_image,
        .{ .filter = .{ .fixed = .up }, .compression = .{ .strategy = .four_byte_runs } },
    );
    defer Stateless.allocator.free(large_wire);
    var large_decoded = try owned_decode.rgbaAlloc(u8, std.testing.allocator, large_wire, .{});
    defer large_decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, large_pixels, large_decoded.texels);
}

test "separate PNG allocators count and admit output before its allocation" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(u8, 96 * 96 * 4);
    defer allocator.free(pixels);
    var random: std.Random.DefaultPrng = .init(0x17c5);
    random.random().bytes(pixels);
    const image = try ImageInput.rgba8(pixels, 96, 96);
    const options: Options = .{
        .filter = .{ .fixed = .up },
        .compression = .{ .strategy = .four_byte_runs },
    };
    const required = try requirements(image, options);
    const expected = try alloc(allocator, image, options);
    defer allocator.free(expected);
    for (0..5) |mode| {
        var output = std.testing.FailingAllocator.init(
            allocator,
            .{ .fail_index = if (mode == 3) 0 else std.math.maxInt(usize), .resize_fail_index = 0 },
        );
        var scratch = std.testing.FailingAllocator.init(
            allocator,
            .{ .fail_index = if (mode == 4) 0 else std.math.maxInt(usize) },
        );
        var selected = options;
        if (mode == 1) selected.limits.maximum_output_bytes = 57;
        if (mode == 2) selected.limits.maximum_scratch_bytes = required.workspace_bytes - 1;
        const result = allocWithScratch(output.allocator(), scratch.allocator(), image, selected);
        if (mode == 0) {
            const actual = try result;
            try std.testing.expectEqualSlices(u8, expected, actual);
            try std.testing.expectEqual(@as(usize, 1), output.allocations);
            try std.testing.expectEqual(actual.len, output.allocated_bytes);
            try std.testing.expectEqual(@as(usize, 0), output.resize_index);
            output.allocator().free(actual);
        } else {
            const expected_error: Error = switch (mode) {
                1 => error.OutputBudgetExceeded,
                2 => error.ScratchBudgetExceeded,
                else => error.OutOfMemory,
            };
            try std.testing.expectError(expected_error, result);
            try std.testing.expectEqual(@as(usize, 0), output.allocations);
        }
        try std.testing.expectEqual(output.allocated_bytes, output.freed_bytes);
        try std.testing.expectEqual(scratch.allocated_bytes, scratch.freed_bytes);
    }
}

test "provisional PNG allocation uses admitted larger bounds" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.alloc(u8, 321 * 867 * 4);
    defer allocator.free(pixels);
    const options: Options = .{
        .filter = .{ .fixed = .up },
        .compression = .{ .strategy = .four_byte_runs },
        .data_chunk_bytes = 65536,
    };
    // The third raster has exactly seventeen 65,535-byte filtered slabs.
    const geometries = [_][2]u32{ .{ 511, 512 }, .{ 512, 512 }, .{ 321, 867 } };
    for (geometries) |geometry| for ([_]bool{ false, true }) |random_pixels| {
        const width = geometry[0];
        const height = geometry[1];
        const source_bytes = @as(usize, width) * height * 4;
        if (random_pixels) {
            var random: std.Random.DefaultPrng = .init(0xc23a);
            random.random().bytes(pixels);
        } else @memset(pixels, 0);
        const image = try ImageInput.rgba8(pixels[0..source_bytes], width, height);
        const required = try requirements(image, options);
        try std.testing.expectEqual(width != 511, required.output_bytes > 1024 * 1024);
        const expected = try allocWithScratch(allocator, allocator, image, options);
        defer allocator.free(expected);
        var no_resize: std.testing.FailingAllocator = .init(allocator, .{ .resize_fail_index = 0 });
        const repeated = try alloc(no_resize.allocator(), image, options);
        try std.testing.expectEqualSlices(u8, expected, repeated);
        no_resize.allocator().free(repeated);
        try std.testing.expectEqual(no_resize.allocated_bytes, no_resize.freed_bytes);
        try std.testing.expectEqual(4, no_resize.allocations);
        for ([_]usize{ 0, 1 }) |shortfall| {
            var limited = options;
            limited.limits.maximum_scratch_bytes = required.output_bytes + required
                .workspace_bytes - shortfall;
            limited.limits.maximum_output_bytes = expected.len;
            const actual = try alloc(allocator, image, limited);
            defer allocator.free(actual);
            try std.testing.expectEqualSlices(u8, expected, actual);
        }
        var limited = options;
        limited.limits.maximum_output_bytes = expected.len - 1;
        try std.testing.expectError(error.OutputBudgetExceeded, alloc(allocator, image, limited));
        if (random_pixels) {
            limited = options;
            limited.limits.maximum_records = 3;
            try std.testing.expectError(
                error.MetadataLimitExceeded,
                alloc(allocator, image, limited),
            );
        }
        for ([_]usize{ expected.len, required.output_bytes }) |reservation| {
            const backing = try allocator.alloc(u8, required.workspace_bytes + reservation + 128);
            defer allocator.free(backing);
            var fixed: std.heap.FixedBufferAllocator = .init(backing);
            const actual = try alloc(fixed.allocator(), image, options);
            try std.testing.expectEqualSlices(u8, expected, actual);
            fixed.allocator().free(actual);
            try std.testing.expectEqual(0, fixed.end_index);
        }
        var decoded = try owned_decode.rgbaAlloc(u8, allocator, expected, .{});
        defer decoded.deinit(allocator);
        try std.testing.expectEqualSlices(u8, pixels[0..source_bytes], decoded.texels);
        try std.testing.checkAllAllocationFailures(
            allocator,
            provisionalAllocationFailure,
            .{ image, options },
        );
    };
}
