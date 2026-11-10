//! Shared PNG sample serialization, filtering and sequential/Adam7 compression.

const png_format = @import("format.zig");
const builtin = @import("builtin");
const std = @import("std");
const zlib = @import("../zlib.zig");
const encoding_workspace = @import("encode_workspace.zig");
const scanline_filters = @import("scanline_filters.zig");
const Filter = scanline_filters.Filter;
const FilterType = Filter.Type;
const chooseFilter = scanline_filters.chooseFilter;
const filterRow = scanline_filters.filterRow;
const filterUp = scanline_filters.filterUp;
const Interlace = png_format.Interlace;
const chunks = @import("ChunkWriter.zig");
const ImageInput = @import("ImageInput.zig");

const EncodingStorage = encoding_workspace.Workspace;

const Transparency = png_format.Transparency;

/// Encoded tRNS payload bytes; zero omits its chunk.
pub fn transparencyByteCount(self: Transparency) usize {
    return switch (self) {
        .none => 0,
        .grayscale => 2,
        .truecolor => 6,
        .palette => |values| values.len,
    };
}

/// Checked raster geometry and conservative work for up to two filtering passes. This contains no
/// source pointer; callers keep the source unchanged while using its admitted layout.
pub const Layout = struct {
    /// Complete serialized source row bytes, including a partial packed final byte.
    row_bytes: usize,
    /// Source row stride in bytes or words according to Samples.
    source_row_stride: usize,
    /// Stored bits in one pixel.
    bits_per_pixel: usize,
    /// Byte-predictor distance, at least one for packed samples.
    filter_bytes_per_pixel: usize,
    /// Raster pixels, excluding any canvas outside this rectangle.
    pixels: usize,
    /// Static framing records: IHDR, one IDAT, IEND and selected PLTE/tRNS.
    minimum_records: usize,
    /// IHDR and selected PLTE/tRNS payload bytes, excluding raster data.
    base_metadata_bytes: usize,
    /// Two serialization/filter passes plus one complete indexed-source validation.
    work_units: usize,
    /// Largest live requested compression span, including internal alignment.
    scratch_bytes: usize,
};

/// One raster's explicit filtering, compression and traversal policy; no authority is retained.
pub const Options = struct {
    /// Predictor or adaptive minimum signed-byte score, with lowest selector winning ties.
    filter: Filter = .{ .fixed = .sub },
    /// Zlib compression level and strategy. The default level 3 uses greedy matching.
    compression: zlib.Compression = .{ .level = 3 },
    /// Each Adam7 pass begins with empty previous-row filter history.
    interlace: Interlace = .none,
};

/// Checked shape, row storage, palette, compression, allocation and bounded output failures.
pub const Error = EncodingStorage.Error || encoding_workspace.WriteError || chunks.Error || std.mem
    .Allocator.Error || error{
    InvalidImageExtent,
    SizeOverflow,
    InvalidTexelCount,
    InvalidSampleDepth,
    InvalidRowStride,
    InvalidPalette,
    InvalidPaletteIndex,
    InvalidTransparency,
};

/// Checks PNG's nonzero 31-bit axes without reading source samples.
pub fn validateExtent(width: u32, height: u32) Error!void {
    if (width == 0 or height == 0 or width > 0x7fffffff or height > 0x7fffffff)
        return error.InvalidImageExtent;
}

/// Checks source shape and policy without scanning palette indices or allocating. Call
/// validateIndices after admitting work, then keep source and policy unchanged through compression.
pub fn describe(image: ImageInput, options: Options) Error!Layout {
    try validateExtent(image.width, image.height);
    try options.compression.validate();
    const allowed_depth = switch (image.color_type) {
        .grayscale,
        => image.bit_depth == 1 or image.bit_depth == 2 or image.bit_depth == 4 or image
            .bit_depth == 8 or image.bit_depth == 16,
        .indexed,
        => image.bit_depth == 1 or image.bit_depth == 2 or image.bit_depth == 4 or image
            .bit_depth == 8,
        .truecolor, .grayscale_alpha, .rgba => image.bit_depth == 8 or image.bit_depth == 16,
    };
    if (!allowed_depth or (image.samples == .words and image.bit_depth != 16))
        return error.InvalidSampleDepth;
    const bits_per_pixel = image.color_type.channels() * image.bit_depth;
    const row_bytes = try png_format.packedRowBytes(image.width, bits_per_pixel);
    const row_units = if (image.samples == .words) row_bytes / 2 else row_bytes;
    const input_count, const specified_stride = switch (image.samples) {
        .packed_bytes => |rows| .{ rows.bytes.len, rows.stride },
        .words => |rows| .{ rows.values.len, rows.stride },
    };
    const stride = if (specified_stride == 0) row_units else specified_stride;
    if (stride < row_units) return error.InvalidRowStride;
    if (input_count < try add(
        try mul(image.height - 1, stride),
        row_units,
    )) return error.InvalidTexelCount;

    if (image.palette.len > 256) return error.InvalidPalette;
    switch (image.color_type) {
        .indexed => if (image.palette.len == 0 or image.palette.len > (@as(
            usize,
            1,
        ) << @intCast(image.bit_depth))) return error.InvalidPalette,
        .grayscale, .grayscale_alpha => if (image.palette.len != 0) return error.InvalidPalette,
        .truecolor, .rgba => {},
    }
    const maximum: u16 = if (image.bit_depth == 16) 65535 else (@as(
        u16,
        1,
    ) << @intCast(image.bit_depth)) - 1;
    switch (image.transparency) {
        .none => {},
        .grayscale,
        => |value| if (image.color_type != .grayscale or value > maximum)
            return error.InvalidTransparency,
        .truecolor => |values| {
            if (image.color_type != .truecolor) return error.InvalidTransparency;
            for (values) |value| if (value > maximum) return error.InvalidTransparency;
        },
        .palette,
        => |values| if (image.color_type != .indexed or values.len > image.palette.len)
            return error.InvalidTransparency,
    }

    const pixel_count = try mul(image.width, image.height);
    const scratch_bytes = try scratchByteCount(try add(row_bytes, 1));
    const records: usize = 3 + @as(
        usize,
        @intFromBool(image.palette.len != 0),
    ) + @as(usize, @intFromBool(transparencyByteCount(image.transparency) != 0));
    var metadata_bytes: usize = 13 + image.palette.len * 3;
    metadata_bytes += transparencyByteCount(image.transparency);
    // Adaptive scoring visits five candidates, then emits the chosen sixth filter pass.
    const filter_trials: usize = if (options.filter == .adaptive) 6 else 1;
    var scan_bytes: usize = 0;
    const passes: []const png_format.Pass = if (options.interlace == .adam7) &png_format
        .adam7_passes else &.{
        png_format.sequential_pass,
    };
    for (passes) |pass| {
        const width = png_format.passExtent(image.width, pass.start_x, pass.step_x);
        const height = png_format.passExtent(image.height, pass.start_y, pass.step_y);
        if (width == 0 or height == 0) continue;
        scan_bytes = try add(
            scan_bytes,
            try mul(height, try png_format.packedRowBytes(width, bits_per_pixel)),
        );
    }
    const filter_work = try mul(try mul(scan_bytes, filter_trials + 1), 2);
    const work = try add(filter_work, if (image.color_type == .indexed) pixel_count else 0);
    const layout: Layout = .{
        .row_bytes = row_bytes,
        .source_row_stride = stride,
        .bits_per_pixel = bits_per_pixel,
        .filter_bytes_per_pixel = @max(1, (bits_per_pixel + 7) / 8),
        .pixels = pixel_count,
        .minimum_records = records,
        .base_metadata_bytes = metadata_bytes,
        .work_units = work,
        .scratch_bytes = scratch_bytes,
    };
    return layout;
}

/// Scans indexed source pixels after admitting the work reported by describe. The layout must come
/// from the same image and policy; keep both unchanged through compression.
pub fn validateIndices(image: ImageInput, admitted: Layout) Error!void {
    if (image.color_type == .indexed) {
        const rows = image.samples.packed_bytes.bytes;
        for (0..image.height) |y| {
            const row = rows[y * admitted.source_row_stride ..][0..admitted.row_bytes];
            for (
                0..image.width,
            ) |x| if (packedSample(
                row,
                x,
                image.bit_depth,
            ) >= image.palette.len) return error.InvalidPaletteIndex;
        }
    }
}

/// Appends the admitted canvas IHDR without source samples or ancillary records. No allocation
/// occurs; a bounded failure may leave destination bytes and preserves offset.
pub fn writeHeader(
    destination: []u8,
    offset: *usize,
    image: ImageInput,
    interlace: Interlace,
) Error!void {
    var header: [13]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], image.width, .big);
    std.mem.writeInt(u32, header[4..8], image.height, .big);
    header[8] = image.bit_depth;
    header[9] = @backingInt(image.color_type);
    header[12] = @backingInt(interlace);
    try chunks.append(destination, offset, "IHDR", &header);
}

/// Appends admitted PLTE/tRNS choices, omitting absent palette and empty alpha prefixes. Borrowed
/// palette/transparency must remain unchanged; failure may leave complete chunks.
pub fn writePaletteAndTransparency(
    destination: []u8,
    offset: *usize,
    image: ImageInput,
) Error!void {
    if (image.palette.len != 0) try chunks.append(
        destination,
        offset,
        "PLTE",
        std.mem.sliceAsBytes(image.palette),
    );
    switch (image.transparency) {
        .none => {},
        .grayscale => |value| {
            var bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &bytes, value, .big);
            try chunks.append(destination, offset, "tRNS", &bytes);
        },
        .truecolor => |values| {
            var bytes: [6]u8 = undefined;
            for (
                values,
                0..,
            ) |value, index| std.mem.writeInt(u16, bytes[index * 2 ..][0..2], value, .big);
            try chunks.append(destination, offset, "tRNS", &bytes);
        },
        .palette => |values| if (values.len != 0) try chunks.append(
            destination,
            offset,
            "tRNS",
            values,
        ),
    }
}

fn add(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.SizeOverflow;
}

fn mul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.SizeOverflow;
}

/// Scratch capacity for the compressor and three rows, including worst-case alignment padding.
pub fn scratchByteCount(filtered_row_bytes: usize) Error!usize {
    return EncodingStorage.byteCount(try mul(filtered_row_bytes, 3));
}

/// Emits one independent zlib raster stream using a single temporary span at its final address.
/// Source, layout and policy must be validated and immutable; admit layout.scratch_bytes first.
/// Scratch is completely released, no allocator or output Writer is retained, and failure may leave
/// output bytes. The caller owns complete-image publication and output buffering.
pub fn compressRows(
    output: *std.Io.Writer,
    image: ImageInput,
    layout: Layout,
    options: Options,
    scratch_allocator: std.mem.Allocator,
) Error!void {
    const row_capacity = try add(layout.row_bytes, 1);
    if (row_capacity <= zlib.short_stored_max_input_bytes and image.height <= zlib
        .short_stored_max_input_bytes / row_capacity)
    {
        if (try shortStoredRows(output, image, layout, options, row_capacity)) return;
    }
    if (row_capacity <= zlib.short_four_byte_run_max_input_bytes and image.height <= zlib
        .short_four_byte_run_max_input_bytes / row_capacity)
    {
        if (try shortRunRows(output, image, layout, options, row_capacity)) return;
    }
    if (options.compression.strategy == .four_byte_runs) {
        var storage = try encoding_workspace.FourByteRunWorkspace.initCapacity(
            scratch_allocator,
            try mul(row_capacity, 3),
        );
        defer storage.deinit(scratch_allocator);
        return compressRowsWithStorage(output, image, layout, options, storage);
    }
    var storage = try EncodingStorage.initCapacity(scratch_allocator, try mul(row_capacity, 3));
    defer storage.deinit(scratch_allocator);
    return compressRowsWithStorage(output, image, layout, options, storage);
}

/// Emits one independent raster using already reserved state and three row slots. No allocation
/// occurs. Source, output and backing remain disjoint through the call. Begin/finish and failures
/// retain no source or Writer borrow; the same workspace can start another image afterward.
pub fn compressRowsPrepared(
    output: *std.Io.Writer,
    image: ImageInput,
    layout: Layout,
    options: Options,
    storage: EncodingStorage,
) Error!void {
    return compressRowsWithStorage(output, image, layout, options, storage);
}

pub fn compressRowsWithStorage(
    output: *std.Io.Writer,
    image: ImageInput,
    layout: Layout,
    options: Options,
    storage: anytype,
) Error!void {
    const row_capacity = try add(layout.row_bytes, 1);
    if (storage.extra.len < try mul(row_capacity, 3)) return error.WorkspaceTooSmall;
    const current_storage = storage.extra[0..row_capacity];
    const previous_storage = storage.extra[row_capacity..][0..row_capacity];
    const filtered = storage.extra[2 * row_capacity ..][0..row_capacity];
    try encoding_workspace.beginStream(storage, options.compression);
    // Sequential packed rows can borrow their source directly. The two serialization/history slots
    // are therefore available to batch three filtered rows before entering the zlib stream.
    if (options.interlace == .none) switch (image.samples) {
        .packed_bytes => |source| {
            if (row_capacity <= 256 and options.filter == .fixed and options.filter.fixed == .up) {
                try compressShortUpRows(
                    storage,
                    output,
                    source.bytes,
                    image.height,
                    layout,
                    row_capacity,
                );
                try encoding_workspace.finishStream(storage, output);
                return;
            }
            if (options.filter == .fixed and options.filter.fixed == .up) {
                try compressUpRows(
                    storage,
                    output,
                    source.bytes,
                    image.height,
                    layout,
                    row_capacity,
                );
                try encoding_workspace.finishStream(storage, output);
                return;
            }
            var y: usize = 0;
            while (y < image.height) {
                const direct = encoding_workspace.inputBuffer(storage);
                const direct_rows = if (direct) |buffer| @min(3, buffer.len / row_capacity) else 0;
                const count = @min(
                    if (direct_rows != 0) direct_rows else 3,
                    @as(usize, image.height) - y,
                );
                const destinations = if (direct_rows != 0) direct.? else storage.extra;
                for (0..count) |i| {
                    const row = y + i;
                    const current = source.bytes[row * layout.source_row_stride ..][0..layout
                        .row_bytes];
                    const previous: ?[]const u8 = if (row == 0) null else source.bytes[(row - 1) *
                        layout.source_row_stride ..][0..layout.row_bytes];
                    const destination = destinations[i * row_capacity ..][0..row_capacity];
                    const selected = switch (options.filter) {
                        .fixed => |kind| kind,
                        .adaptive => chooseFilter(current, previous, layout.filter_bytes_per_pixel),
                    };
                    filterRow(
                        destination,
                        current,
                        previous,
                        layout.filter_bytes_per_pixel,
                        selected,
                    );
                }
                if (direct_rows != 0) {
                    try encoding_workspace.commitInput(storage, output, count * row_capacity);
                } else {
                    try encoding_workspace.writeStream(
                        storage,
                        output,
                        storage.extra[0 .. count * row_capacity],
                    );
                }
                y += count;
            }
            try encoding_workspace.finishStream(storage, output);
            return;
        },
        else => {},
    };
    const passes: []const png_format.Pass = if (options.interlace == .adam7) &png_format
        .adam7_passes else &.{
        png_format.sequential_pass,
    };
    for (passes) |pass| {
        const width = png_format.passExtent(image.width, pass.start_x, pass.step_x);
        const height = png_format.passExtent(image.height, pass.start_y, pass.step_y);
        if (width == 0 or height == 0) continue;
        const row_bytes = try png_format.packedRowBytes(width, layout.bits_per_pixel);
        var previous: ?[]const u8 = null;
        for (0..height) |pass_y| {
            const y = pass.start_y + pass_y * pass.step_y;
            const current = serializeRow(
                image,
                layout,
                pass,
                width,
                y,
                current_storage[0..row_bytes],
            );
            const selected = switch (options.filter) {
                .fixed => |kind| kind,
                .adaptive => chooseFilter(current, previous, layout.filter_bytes_per_pixel),
            };
            filterRow(
                filtered[0 .. row_bytes + 1],
                current,
                previous,
                layout.filter_bytes_per_pixel,
                selected,
            );
            try encoding_workspace.writeStream(storage, output, filtered[0 .. row_bytes + 1]);
            if (current.ptr == current_storage.ptr) {
                @memcpy(previous_storage[0..row_bytes], current);
                previous = previous_storage[0..row_bytes];
            } else previous = current;
        }
    }
    try encoding_workspace.finishStream(storage, output);
}

// Up prediction is independent for each byte. Produce bounded pieces directly into the raw input
// reservation, including partial rows at slab boundaries. Source, prior-row and destination bytes
// for an 8 KiB batch fit near a 32 KiB L1 working set before the Adler traversal.
noinline fn compressUpRows(
    storage: anytype,
    output: *std.Io.Writer,
    source: []const u8,
    height: usize,
    layout: Layout,
    row_capacity: usize,
) Error!void {
    try encoding_workspace.writeStream(storage, output, &.{});
    var row: usize = 0;
    var offset: usize = 0;
    while (row < height) {
        const available = encoding_workspace.inputBuffer(storage) orelse {
            // A depleted input limit must use ordinary admission so it poisons the native owner and
            // reports the same refusal as copied input.
            storage.extra[0] = if (offset == 0) @backingInt(FilterType.up) else blk: {
                const current = source[row * layout.source_row_stride + offset - 1];
                const prior = if (row == 0) 0 else source[
                    (row - 1) * layout.source_row_stride +
                        offset - 1
                ];
                break :blk current -% prior;
            };
            try encoding_workspace.writeStream(storage, output, storage.extra[0..1]);
            offset += 1;
            if (offset == row_capacity) {
                row += 1;
                offset = 0;
            }
            continue;
        };
        const capacity = @min(available.len, 8192);
        var filled: usize = 0;
        while (filled < capacity and row < height) {
            const length = @min(capacity - filled, row_capacity - offset);
            const destination = available[filled..][0..length];
            const prefix: usize = @intFromBool(offset == 0);
            if (prefix != 0) destination[0] = @backingInt(FilterType.up);
            const x = offset -| 1;
            const bytes = length - prefix;
            const current = source[row * layout.source_row_stride + x ..][0..bytes];
            const previous: ?[]const u8 = if (row == 0) null else source[(row - 1) * layout
                .source_row_stride + x ..][0..bytes];
            filterUp(destination[prefix..], current, previous);
            filled += length;
            offset += length;
            if (offset == row_capacity) {
                row += 1;
                offset = 0;
            }
        }
        try encoding_workspace.commitInput(storage, output, filled);
    }
}

// Small complete raster streams fit a single stored block. Filter exactly the same admitted packed
// rows, then use the generic zlib short-stream writer without initializing streaming state.
noinline fn shortStoredRows(
    output: *std.Io.Writer,
    image: ImageInput,
    layout: Layout,
    options: Options,
    row_capacity: usize,
) align(64) Error!bool {
    if (options.interlace != .none or options.compression.strategy != .four_byte_runs or
        row_capacity > zlib.short_stored_max_input_bytes or image.height > zlib
        .short_stored_max_input_bytes / row_capacity) return false;
    const source = switch (image.samples) {
        .packed_bytes => |value| value.bytes,
        .words => return false,
    };
    var filtered: [zlib.short_stored_max_input_bytes]u8 = undefined;
    filterShortRows(&filtered, source, image.height, layout, options.filter, row_capacity);
    var encoded: [zlib.short_stored_output_capacity]u8 = undefined;
    const wire = try zlib.encodeShortStored(filtered[0 .. image.height * row_capacity], &encoded);
    try output.writeAll(wire);
    return true;
}

noinline fn shortRunRows(
    output: *std.Io.Writer,
    image: ImageInput,
    layout: Layout,
    options: Options,
    row_capacity: usize,
) Error!bool {
    if (options.interlace != .none or options.compression.strategy != .four_byte_runs or options
        .compression.level == 0) return false;
    const source = switch (image.samples) {
        .packed_bytes => |value| value.bytes,
        .words => return false,
    };
    var filtered: [zlib.short_four_byte_run_max_input_bytes]u8 = undefined;
    filterShortRows(&filtered, source, image.height, layout, options.filter, row_capacity);
    var encoded: [zlib.short_four_byte_run_output_capacity]u8 = undefined;
    const wire = try zlib.encodeShortFourByteRuns(
        filtered[0 .. image.height * row_capacity],
        &encoded,
    );
    try output.writeAll(wire);
    return true;
}

inline fn filterShortRows(
    filtered: []u8,
    source: []const u8,
    height: usize,
    layout: Layout,
    filter: Filter,
    row_capacity: usize,
) void {
    if (layout.row_bytes >= up_vector_threshold and filter == .fixed and filter.fixed == .up) {
        filterShortUpBatch(filtered, source, layout, row_capacity, 0, height);
        return;
    }
    var previous: ?[]const u8 = null;
    for (0..height) |y| {
        const current = source[y * layout.source_row_stride ..][0..layout.row_bytes];
        const selected = switch (filter) {
            .fixed => |kind| kind,
            .adaptive => chooseFilter(current, previous, layout.filter_bytes_per_pixel),
        };
        filterRow(
            filtered[y * row_capacity ..][0..row_capacity],
            current,
            previous,
            layout.filter_bytes_per_pixel,
            selected,
        );
        previous = current;
    }
}

const up_vector_threshold = 16;

noinline fn compressShortUpRows(
    storage: anytype,
    output: *std.Io.Writer,
    source: []const u8,
    height: usize,
    layout: Layout,
    row_capacity: usize,
) Error!void {
    if (height > 2048 / row_capacity and height <= 4160 / row_capacity) {
        if (encoding_workspace.wideRowBatchBuffer(storage)) |batch| {
            filterShortUpBatch(batch, source, layout, row_capacity, 0, height);
            try encoding_workspace.writeWideRowBatch(storage, output, height * row_capacity);
            return;
        }
    }
    const batch = encoding_workspace.rowBatchBuffer(storage);
    const rows_per_batch = batch.len / row_capacity;
    var y: usize = 0;
    while (y < height) {
        const count = @min(rows_per_batch, height - y);
        filterShortUpBatch(batch, source, layout, row_capacity, y, count);
        try encoding_workspace.writeRowBatch(storage, output, count * row_capacity);
        y += count;
    }
}

inline fn filterShortUpBatch(
    batch: []u8,
    source: []const u8,
    layout: Layout,
    row_capacity: usize,
    first_row: usize,
    count: usize,
) void {
    for (0..count) |i| {
        const row = first_row + i;
        const current = source[row * layout.source_row_stride ..][0..layout.row_bytes];
        const previous: ?[]const u8 = if (row == 0) null else source[(row - 1) * layout
            .source_row_stride ..][0..layout.row_bytes];
        const destination = batch[i * row_capacity ..][0..row_capacity];
        destination[0] = @backingInt(FilterType.up);
        filterUp(destination[1..], current, previous);
    }
}

fn serializeRow(
    image: ImageInput,
    layout: Layout,
    pass: png_format.Pass,
    width: usize,
    y: usize,
    destination: []u8,
) []const u8 {
    switch (image.samples) {
        .packed_bytes => |rows| {
            const source = rows.bytes[y * layout.source_row_stride ..][0..layout.row_bytes];
            if (pass.start_x == 0 and pass.step_x == 1) return source;
            if (image.bit_depth < 8) {
                @memset(destination, 0);
                for (0..width) |pass_x| {
                    const value = packedSample(
                        source,
                        pass.start_x + pass_x * pass.step_x,
                        image.bit_depth,
                    );
                    const position = png_format.packedSamplePosition(pass_x, image.bit_depth);
                    destination[position.byte_index] |= value << position.shift;
                }
            } else {
                const pixel_bytes = layout.bits_per_pixel / 8;
                for (0..width) |pass_x| {
                    const x = pass.start_x + pass_x * pass.step_x;
                    @memcpy(
                        destination[pass_x * pixel_bytes ..][0..pixel_bytes],
                        source[x * pixel_bytes ..][0..pixel_bytes],
                    );
                }
            }
        },
        .words => |rows| {
            const channels = image.color_type.channels();
            const source = rows.values[y * layout.source_row_stride ..][0 .. @as(
                usize,
                image.width,
            ) * channels];
            for (0..width) |pass_x| {
                const x = pass.start_x + pass_x * pass.step_x;
                for (0..channels) |channel| {
                    std.mem.writeInt(
                        u16,
                        destination[(pass_x * channels + channel) * 2 ..][0..2],
                        source[x * channels + channel],
                        .big,
                    );
                }
            }
        },
    }
    return destination;
}

fn packedSample(row: []const u8, x: usize, depth: u8) u8 {
    const position = png_format.packedSamplePosition(x, depth);
    const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
    return (row[position.byte_index] >> position.shift) & mask;
}

test "32-bit Linux packed indexing reads beyond the intermediate bit-offset bound" {
    if (@bitSizeOf(usize) != 32 or builtin.os.tag != .linux) return error.SkipZigTest;
    // Only the final page is touched; the large admitted row is a virtual reservation.
    const index: usize = 0x20000000;
    const row = try std.heap.page_allocator.alloc(u8, index + 1);
    defer std.heap.page_allocator.free(row);
    row[index] = 0x5a;
    try std.testing.expectEqual(0x5a, packedSample(row, index, 8));
}

test "short stored PNG rows match prepared streams without scratch allocation" {
    const allocator = std.testing.allocator;
    var source: [4 * 19]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index * 73 + index / 7);
    const filters = [_]Filter{
        .{ .fixed = .none },
        .{ .fixed = .sub },
        .{ .fixed = .up },
        .{ .fixed = .average },
        .{ .fixed = .paeth },
        .adaptive,
    };
    for (1..5) |height| {
        const image: ImageInput = .{
            .width = 4,
            .height = @intCast(height),
            .color_type = .rgba,
            .bit_depth = 8,
            .samples = .{
                .packed_bytes = .{ .bytes = source[0 .. (height - 1) * 19 + 16], .stride = 19 },
            },
        };
        for (filters) |filter| {
            for ([_]u4{ 0, 1, 6, 9 }) |level| {
                const options: Options = .{
                    .filter = filter,
                    .compression = .{ .level = level, .strategy = .four_byte_runs },
                };
                const layout = try describe(image, options);
                var storage = try EncodingStorage.initCapacity(
                    allocator,
                    3 * (layout.row_bytes + 1),
                );
                defer storage.deinit(allocator);
                var direct_bytes: [128]u8 = undefined;
                var streamed_bytes: [128]u8 = undefined;
                var direct: std.Io.Writer = .fixed(&direct_bytes);
                var streamed: std.Io.Writer = .fixed(&streamed_bytes);
                try compressRows(&direct, image, layout, options, std.testing.failing_allocator);
                try compressRowsPrepared(&streamed, image, layout, options, storage);
                try std.testing.expectEqualSlices(u8, streamed.buffered(), direct.buffered());
            }
        }
    }
}

test "short run PNG rows match prepared streams without scratch allocation" {
    const allocator = std.testing.allocator;
    var source: [8 * 35]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index *% 73 +% index / 7);
    const image: ImageInput = .{
        .width = 8,
        .height = 8,
        .color_type = .rgba,
        .bit_depth = 8,
        .samples = .{ .packed_bytes = .{ .bytes = source[0 .. 7 * 35 + 32], .stride = 35 } },
    };
    const filters = [_]Filter{
        .{ .fixed = .none },
        .{ .fixed = .sub },
        .{ .fixed = .up },
        .{ .fixed = .average },
        .{ .fixed = .paeth },
        .adaptive,
    };
    for (filters) |filter| {
        for ([_]u4{ 1, 6, 9 }) |level| {
            const options: Options = .{
                .filter = filter,
                .compression = .{ .level = level, .strategy = .four_byte_runs },
            };
            const layout = try describe(image, options);
            var storage = try EncodingStorage.initCapacity(allocator, 3 * (layout.row_bytes + 1));
            defer storage.deinit(allocator);
            var direct_bytes: [300]u8 = undefined;
            var streamed_bytes: [300]u8 = undefined;
            var direct: std.Io.Writer = .fixed(&direct_bytes);
            var streamed: std.Io.Writer = .fixed(&streamed_bytes);
            try compressRows(&direct, image, layout, options, std.testing.failing_allocator);
            try compressRowsPrepared(&streamed, image, layout, options, storage);
            try std.testing.expectEqualSlices(u8, streamed.buffered(), direct.buffered());
            var empty: [0]u8 = .{};
            var blocked: std.Io.Writer = .fixed(&empty);
            try std.testing.expectError(
                error.WriteFailed,
                compressRows(&blocked, image, layout, options, std.testing.failing_allocator),
            );
        }
    }
    const stored: Options = .{ .compression = .{ .level = 0, .strategy = .four_byte_runs } };
    const stored_layout = try describe(image, stored);
    var wire: [300]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&wire);
    try std.testing.expectError(
        error.OutOfMemory,
        compressRows(&writer, image, stored_layout, stored, std.testing.failing_allocator),
    );
}
