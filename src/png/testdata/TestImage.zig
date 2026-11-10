//! An owned generated PNG and its independently retained RGBA, filtered and compressed bytes.
//! Options describe deterministic test input; deinit releases all buffers through their allocator.

const owned_decode = @import("../image_decode.zig");
const std = @import("std");

const TestImage = @This();

/// Owned complete PNG, including physical IDAT boundaries and chunk CRCs.
source: []u8,
/// Owned tightly packed RGBA8 pixels, independent of their filtered encoding.
expected: []u8,
/// Owned exact filtered rows, including each leading filter selector.
filtered: []u8,
/// Owned exact zlib stream shared by every IDAT chunk in `source`.
compressed: []u8,
/// Stored nonzero image width.
width: u32,
/// Stored nonzero image height.
height: u32,

/// Scanline filter pattern used by one generated image.
pub const FilterPattern = enum { none, up, mixed, sub, average, paeth };

/// Encoding used to generate the fixture's compressed raster.
pub const Compression = enum { stored, fixed_literals, std_fast, std_default };

/// Deterministic pixel distribution; noise retains opaque alpha.
pub const PixelPattern = enum { gradient, solid, noise };

/// Image shape, filtering, compression and physical IDAT framing.
pub const Options = struct {
    width: u32,
    height: u32,
    filter_pattern: FilterPattern,
    compression: Compression = .stored,
    pixel_pattern: PixelPattern = .gradient,
    /// Maximum payload per IDAT; boundaries do not restart compression.
    idat_chunk_bytes: usize = std.math.maxInt(u31),
};

// Prepare the standard compressor at comptime, clearing its two call-local pointers before
// rebinding them in the final allocated owner. Runtime Debug construction through Compress.init
// otherwise reserves a large error-union copy.
const fast_compressor = initialCompressor(.fastest);
const default_compressor = initialCompressor(.default);

fn initialCompressor(
    comptime options: std.compress.flate.Compress.Options,
) std.compress.flate.Compress {
    var output_bytes: [16]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_bytes);
    var history: [std.compress.flate.max_window_len]u8 = undefined;
    // The fixed writer has room for the two-byte zlib header.
    var compressor = std.compress.flate.Compress.init(
        &output,
        &history,
        .zlib,
        options,
    ) catch unreachable;
    compressor.writer.buffer = &.{};
    compressor.bit_writer.output = undefined;
    return compressor;
}

const max_stored_block_length = 65_535;
const row_bytes_per_pixel = 4;

/// Generates one fixture, admitting dimensions and uncompressed lengths before allocation.
/// Compressed/framed lengths are checked as prepared bytes become available. Release a successful
/// result with `deinit(allocator)`. Temporary compression storage retires before return; failure
/// releases every unpublished buffer. The allocator may reclaim only its most recent allocation.
pub fn init(allocator: std.mem.Allocator, options: Options) !TestImage {
    const width = options.width;
    const height = options.height;
    if (width == 0 or height == 0 or width > std.math.maxInt(
        u31,
    ) or height > std.math.maxInt(u31) or options.idat_chunk_bytes == 0) return error.InvalidExtent;
    const width_usize: usize = width;
    const height_usize: usize = height;
    const row_bytes = try std.math.mul(usize, width_usize, row_bytes_per_pixel);
    const filtered_row_bytes = try std.math.add(usize, row_bytes, 1);
    const filtered_length = try std.math.mul(usize, height_usize, filtered_row_bytes);
    const pixel_count = try std.math.mul(usize, width_usize, height_usize);
    const rgba_length = try std.math.mul(usize, pixel_count, 4);
    const expected = try allocator.alloc(u8, rgba_length);
    errdefer allocator.free(expected);
    if (options.pixel_pattern == .noise) {
        var random: std.Random.DefaultPrng = .init(0x504e475f6e6f6973);
        random.random().bytes(expected);
        var alpha: usize = 3;
        while (alpha < expected.len) : (alpha += 4) expected[alpha] = 255;
    } else {
        fillExpected(expected, width_usize, height_usize, options.pixel_pattern);
    }

    const filtered = try allocator.alloc(u8, filtered_length);
    errdefer allocator.free(filtered);
    fillFiltered(filtered, expected, width_usize, height_usize, options.filter_pattern);
    const zlib = try compress(allocator, filtered, options.compression);
    errdefer allocator.free(zlib);
    const chunk_bytes = @min(options.idat_chunk_bytes, std.math.maxInt(u31));
    const chunk_count = (zlib.len - 1) / chunk_bytes + 1;
    const framing_bytes = try std.math.mul(usize, chunk_count, 12);
    const source_length = try std.math.add(
        usize,
        zlib.len,
        try std.math.add(usize, framing_bytes, 45),
    );

    const source = try allocator.alloc(u8, source_length);
    errdefer allocator.free(source);
    var offset: usize = 0;
    @memcpy(source[offset..][0..8], &[_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a });
    offset += 8;

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8] = 8;
    header[9] = 6;
    header[10] = 0;
    header[11] = 0;
    header[12] = 0;
    appendChunk(source, &offset, "IHDR", &header);
    var compressed_offset: usize = 0;
    while (compressed_offset < zlib.len) {
        const count = @min(chunk_bytes, zlib.len - compressed_offset);
        appendChunk(source, &offset, "IDAT", zlib[compressed_offset..][0..count]);
        compressed_offset += count;
    }
    appendChunk(source, &offset, "IEND", &.{});
    std.debug.assert(offset == source.len);

    return .{
        .source = source,
        .expected = expected,
        .filtered = filtered,
        .compressed = zlib,
        .width = width,
        .height = height,
    };
}

/// Releases all four buffers through the allocator supplied to `init`.
pub fn deinit(self: *TestImage, allocator: std.mem.Allocator) void {
    allocator.free(self.source);
    allocator.free(self.compressed);
    allocator.free(self.filtered);
    allocator.free(self.expected);
    self.* = undefined;
}

test "fixture rejects invalid dimensions before allocating" {
    try std.testing.expectError(
        error.InvalidExtent,
        init(std.testing.allocator, .{ .width = 0, .height = 1, .filter_pattern = .none }),
    );
    try std.testing.expectError(
        error.InvalidExtent,
        init(std.testing.allocator, .{ .width = 1, .height = 0, .filter_pattern = .none }),
    );
    try std.testing.expectError(
        error.InvalidExtent,
        init(
            std.testing.allocator,
            .{
                .width = std.math.maxInt(u32),
                .height = std.math.maxInt(u32),
                .filter_pattern = .none,
            },
        ),
    );
}

fn fillExpected(expected: []u8, width: usize, height: usize, pixel_pattern: PixelPattern) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * 4;
            expected[offset..][0..4].* = if (pixel_pattern == .solid) .{ 48, 96, 144, 255 } else .{
                @intCast((x *% 17 +% y *% 31 +% 11) & 0xff),
                @intCast((x *% 29 +% y *% 7 +% 48) & 0xff),
                @intCast((x *% 43 +% y *% 19 +% 85) & 0xff),
                @intCast((x *% 61 +% y *% 13 +% 122) & 0xff),
            };
        }
    }
}

fn fillFiltered(
    filtered: []u8,
    expected: []const u8,
    width: usize,
    height: usize,
    mode: FilterPattern,
) void {
    const row_bytes = width * row_bytes_per_pixel;
    const filtered_row_bytes = row_bytes + 1;
    for (0..height) |row| {
        const filter = filterForRow(mode, row);
        const filtered_offset = row * filtered_row_bytes;
        filtered[filtered_offset] = filter;
        for (0..row_bytes) |column| {
            const source_offset = row * row_bytes + column;
            const current = expected[source_offset];
            const left = if (column >= row_bytes_per_pixel) expected[
                source_offset -
                    row_bytes_per_pixel
            ] else 0;
            const up = if (row != 0) expected[source_offset - row_bytes] else 0;
            const upper_left = if (row != 0 and column >= row_bytes_per_pixel)
                expected[source_offset - row_bytes - row_bytes_per_pixel]
            else
                0;
            const predictor: u8 = switch (filter) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @intCast((@as(u16, left) + up) / 2),
                4 => paethPredictor(left, up, upper_left),
                else => unreachable,
            };
            filtered[filtered_offset + 1 + column] = current -% predictor;
        }
    }
}

fn filterForRow(mode: FilterPattern, row: usize) u8 {
    return switch (mode) {
        .none => 0,
        .up => if (row == 0) 0 else 2,
        .mixed => @intCast(row % 5),
        .sub => 1,
        .average => 3,
        .paeth => 4,
    };
}

fn paethPredictor(left: u8, up: u8, upper_left: u8) u8 {
    const left_wide: i32 = left;
    const up_wide: i32 = up;
    const upper_left_wide: i32 = upper_left;
    const p = left_wide + up_wide - upper_left_wide;
    const distance_left = @abs(p - left_wide);
    const distance_up = @abs(p - up_wide);
    const distance_upper_left = @abs(p - upper_left_wide);
    return if (distance_left <= distance_up and distance_left <= distance_upper_left)
        left
    else if (distance_up <= distance_upper_left) up else upper_left;
}

fn fixedLiteralByteCount(literal_count: usize, wide_count: usize) error{Overflow}!usize {
    std.debug.assert(wide_count <= literal_count);
    // Each literal contributes one byte; nine-bit codes add one bit each. The final partial group
    // and ten block/end bits take two bytes, or three with seven extras.
    const literal_bytes = try std.math.add(usize, literal_count, wide_count / 8);
    return std.math.add(usize, literal_bytes, if (wide_count % 8 == 7) 9 else 8);
}

test "fixed literal sizing admits representable bytes beyond intermediate bit counts" {
    // All literals below 144 need eight bits; larger literals add one bit each. A 500 MiB byte
    // stream remains representable on a 32-bit host in both extremes.
    try std.testing.expectEqual(524288008, try fixedLiteralByteCount(524288000, 0));
    try std.testing.expectEqual(589824008, try fixedLiteralByteCount(524288000, 524288000));
    const maximum = std.math.maxInt(usize);
    try std.testing.expectEqual(maximum, try fixedLiteralByteCount(maximum - 8, 0));
    try std.testing.expectError(error.Overflow, fixedLiteralByteCount(maximum - 7, 0));
    const counts = [_]usize{ 0, 1, 2, 6, 7, 8, 9, 15, 16, 143, 144, 255, 256 };
    for (counts) |count| for (0..count + 1) |wide| {
        const expected = (count * 8 + wide + 10 + 7) / 8 + 6;
        try std.testing.expectEqual(expected, try fixedLiteralByteCount(count, wide));
    };
    const boundaries = [_]usize{
        0,
        1,
        7,
        8,
        9,
        maximum / 8,
        maximum / 2,
        maximum - 8,
        maximum - 7,
        maximum,
    };
    for (boundaries) |count| for ([_]usize{ 0, count / 2, count }) |wide| {
        const expected = (@as(u128, count) * 8 + wide + 10 + 7) / 8 + 6;
        if (expected > maximum) {
            try std.testing.expectError(error.Overflow, fixedLiteralByteCount(count, wide));
        } else {
            try std.testing.expectEqual(
                @as(usize, @intCast(expected)),
                try fixedLiteralByteCount(count, wide),
            );
        }
    };
}

fn compress(allocator: std.mem.Allocator, filtered: []const u8, mode: Compression) ![]u8 {
    if (mode == .stored) {
        const blocks = (filtered.len - 1) / max_stored_block_length + 1;
        const length = try std.math.add(
            usize,
            filtered.len,
            try std.math.add(usize, try std.math.mul(usize, blocks, 5), 6),
        );
        const result = try allocator.alloc(u8, length);
        encodeStoredZlib(result, filtered);
        return result;
    }
    if (mode == .fixed_literals) {
        // RFC 1951's fixed alphabet assigns eight bits below 144 and nine above it. Three block
        // bits and the seven-bit end code complete one final block.
        var wide_count: usize = 0;
        for (filtered) |byte| wide_count += @intFromBool(byte >= 144);
        const length = try fixedLiteralByteCount(filtered.len, wide_count);
        const result = try allocator.alloc(u8, length);
        result[0..2].* = .{ 0x78, 0x01 };
        var writer = BitWriter{ .destination = result[2 .. result.len - 4] };
        writer.put(3, 3); // Final fixed-Huffman block.
        for (filtered) |byte| {
            const code: u16 = if (byte < 144) @as(
                u16,
                byte,
            ) + 0x30 else @as(u16, byte) - 144 + 0x190;
            const width: u5 = if (byte < 144) 8 else 9;
            writer.put(@bitReverse(code) >> @as(u4, @intCast(16 - width)), width);
        }
        writer.put(0, 7); // Symbol 256.
        if (writer.count != 0) {
            writer.destination[writer.offset] = @truncate(writer.bits);
            writer.offset += 1;
        }
        std.debug.assert(writer.offset == writer.destination.len);
        std.mem.writeInt(u32, result[result.len - 4 ..][0..4], adler32(filtered), .big);
        return result;
    }

    var counting_bytes: [64]u8 = undefined;
    var counting: std.Io.Writer.Discarding = .init(&counting_bytes);
    try writeCompressed(allocator, filtered, mode, &counting.writer);
    const length = std.math.cast(usize, counting.fullCount()) orelse return error.Overflow;
    const result = try allocator.alloc(u8, length);
    errdefer allocator.free(result);

    var output: BufferedWriter = undefined;
    output.init(result);
    try writeCompressed(allocator, filtered, mode, &output.writer);
    try output.writer.flush();
    // Both passes consume the same private filtered bytes with identical state.
    std.debug.assert(output.destination.end == result.len);
    return result;
}

fn writeCompressed(
    allocator: std.mem.Allocator,
    filtered: []const u8,
    mode: Compression,
    output: *std.Io.Writer,
) !void {
    const Compressor = std.compress.flate.Compress;
    const alignment = @alignOf(Compressor);
    const workspace_length = @sizeOf(
        Compressor,
    ) + alignment - 1 + std.compress.flate.max_window_len;
    // Leading alignment stays inside the byte allocation; freeing the span can restore an unaligned
    // caller prefix without leaving allocator-owned padding.
    const workspace = try allocator.alloc(u8, workspace_length);
    defer allocator.free(workspace);
    const address = std.mem.alignForward(usize, @intFromPtr(workspace.ptr), alignment);
    const compressor: *Compressor = @ptrFromInt(address);
    const history_offset = address - @intFromPtr(workspace.ptr) + @sizeOf(Compressor);
    compressor.* = if (mode == .std_fast) fast_compressor else default_compressor;
    compressor.writer.buffer = workspace[history_offset..][0..std.compress.flate.max_window_len];
    compressor.bit_writer.output = output;
    try output.writeAll(std.compress.flate.Container.zlib.header());
    try compressor.writer.writeAll(filtered);
    try compressor.finish();
}

// The bit writer needs eight-byte lookahead even when fewer bytes remain in the exact destination.
// Keep that lookahead in this small synchronous owner's buffer.
const BufferedWriter = struct {
    writer: std.Io.Writer,
    destination: std.Io.Writer,
    buffer: [64]u8,

    fn init(self: *BufferedWriter, destination: []u8) void {
        self.destination = .fixed(destination);
        self.writer = .{ .buffer = &self.buffer, .vtable = &.{ .drain = drain } };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *BufferedWriter = @fieldParentPtr("writer", writer);
        try self.destination.writeAll(writer.buffered());
        writer.end = 0;
        return self.destination.writeSplat(data, splat);
    }
};

const BitWriter = struct {
    destination: []u8,
    offset: usize = 0,
    bits: u32 = 0,
    count: u5 = 0,

    fn put(self: *BitWriter, bits: u16, width: u5) void {
        self.bits |= @as(u32, bits) << self.count;
        self.count += width;
        while (self.count >= 8) {
            self.destination[self.offset] = @truncate(self.bits);
            self.offset += 1;
            self.bits >>= 8;
            self.count -= 8;
        }
    }
};

fn encodeStoredZlib(destination: []u8, filtered: []const u8) void {
    destination[0] = 0x78;
    destination[1] = 0x01;
    var destination_offset: usize = 2;
    var source_offset: usize = 0;
    while (source_offset < filtered.len) {
        const remaining = filtered.len - source_offset;
        const block_length = @min(remaining, max_stored_block_length);
        const final_block: u8 = if (block_length == remaining) 1 else 0;
        destination[destination_offset] = final_block;
        destination_offset += 1;
        std.mem.writeInt(
            u16,
            destination[destination_offset..][0..2],
            @intCast(block_length),
            .little,
        );
        destination_offset += 2;
        std.mem.writeInt(
            u16,
            destination[destination_offset..][0..2],
            ~@as(u16, @intCast(block_length)),
            .little,
        );
        destination_offset += 2;
        @memcpy(
            destination[destination_offset..][0..block_length],
            filtered[source_offset..][0..block_length],
        );
        destination_offset += block_length;
        source_offset += block_length;
    }
    std.mem.writeInt(u32, destination[destination_offset..][0..4], adler32(filtered), .big);
    destination_offset += 4;
    std.debug.assert(destination_offset == destination.len);
}

fn adler32(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |byte| {
        a = (a + byte) % 65_521;
        b = (b + a) % 65_521;
    }
    return (b << 16) | a;
}

fn appendChunk(destination: []u8, offset: *usize, chunk_type: []const u8, data: []const u8) void {
    std.mem.writeInt(u32, destination[offset.*..][0..4], @intCast(data.len), .big);
    offset.* += 4;
    @memcpy(destination[offset.*..][0..4], chunk_type);
    const chunk_data_start = offset.* + 4;
    @memcpy(destination[chunk_data_start..][0..data.len], data);
    var crc = std.hash.Crc32.init();
    crc.update(destination[offset.*..][0 .. 4 + data.len]);
    offset.* = chunk_data_start + data.len;
    std.mem.writeInt(u32, destination[offset.*..][0..4], crc.final(), .big);
    offset.* += 4;
}

test "compressed producers and IDAT boundaries preserve expected filtered bytes and pixels" {
    const allocator = std.testing.allocator;
    for (std.enums.values(Compression)) |compression| {
        for (std.enums.values(FilterPattern)) |mode| {
            var image = try init(
                allocator,
                .{
                    .width = 67,
                    .height = 19,
                    .filter_pattern = mode,
                    .compression = compression,
                    .idat_chunk_bytes = 13,
                },
            );
            defer image.deinit(allocator);
            var decoded = try owned_decode.rgbaAlloc(u8, allocator, image.source, .{});
            defer decoded.deinit(allocator);
            try std.testing.expectEqualSlices(u8, image.expected, decoded.texels);
            if (compression == .fixed_literals) try std.testing.expectEqual(
                1,
                (image.compressed[2] >> 1) & 3,
            );
        }
    }
}

fn fixtureAllocationFailure(allocator: std.mem.Allocator, compression: Compression) !void {
    var image = try init(
        allocator,
        .{
            .width = 17,
            .height = 9,
            .filter_pattern = .mixed,
            .compression = compression,
            .idat_chunk_bytes = 7,
        },
    );
    defer image.deinit(allocator);
}

test "fixture releases each partially allocated compression and framing owner" {
    for (
        std.enums.values(Compression),
    ) |compression| try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        fixtureAllocationFailure,
        .{compression},
    );
}

test "compressed fixture storage retains only live buffers in bounded caller memory" {
    const backing = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(backing);
    for ([_]Compression{ .std_fast, .std_default }) |compression| {
        for (
            [_]Options{
                .{ .width = 17, .height = 9, .filter_pattern = .mixed },
                .{ .width = 128, .height = 129, .filter_pattern = .none, .pixel_pattern = .noise },
            },
        ) |base_options| {
            var options = base_options;
            options.compression = compression;
            options.idat_chunk_bytes = 13;
            for ([_]usize{ 1, 37 }) |prefix_length| {
                for ([_]bool{ false, true }) |deny_remap| {
                    var fixed = std.heap.FixedBufferAllocator.init(backing[1..]);
                    const prefix = try fixed.allocator().alloc(u8, prefix_length);
                    @memset(prefix, 0xa5);
                    var wrapper = std.testing.FailingAllocator.init(
                        fixed.allocator(),
                        .{ .resize_fail_index = 0 },
                    );
                    const allocator = if (deny_remap) wrapper.allocator() else fixed.allocator();
                    for (0..3) |_| {
                        {
                            var image = try init(allocator, options);
                            defer image.deinit(allocator);
                            const retained = image.source.len + image.compressed.len + image
                                .filtered.len + image.expected.len;
                            try std.testing.expectEqual(prefix.len + retained, fixed.end_index);
                            var decoded = try owned_decode.rgbaAlloc(
                                u8,
                                std.testing.allocator,
                                image.source,
                                .{},
                            );
                            defer decoded.deinit(std.testing.allocator);
                            try std.testing.expectEqualSlices(u8, image.expected, decoded.texels);
                        }
                        try std.testing.expectEqual(prefix.len, fixed.end_index);
                        for (prefix) |byte| try std.testing.expectEqual(0xa5, byte);
                    }
                }
            }
        }
    }
}

test "compressed fixture storage failures restore the bounded caller prefix" {
    const backing = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(backing);
    for ([_]Compression{ .std_fast, .std_default }) |compression| {
        var reached_success = false;
        for (0..16) |fail_index| {
            var fixed = std.heap.FixedBufferAllocator.init(backing[1..]);
            const prefix = try fixed.allocator().alloc(u8, 37);
            @memset(prefix, 0x5a);
            var failing = std.testing.FailingAllocator.init(
                fixed.allocator(),
                .{ .fail_index = fail_index, .resize_fail_index = 0 },
            );
            const allocator = failing.allocator();
            if (init(
                allocator,
                .{
                    .width = 128,
                    .height = 129,
                    .filter_pattern = .none,
                    .compression = compression,
                    .pixel_pattern = .noise,
                    .idat_chunk_bytes = 13,
                },
            )) |result| {
                var image = result;
                image.deinit(allocator);
                reached_success = true;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(failing.has_induced_failure);
            }
            try std.testing.expectEqual(prefix.len, fixed.end_index);
            for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
            if (reached_success) break;
        }
        try std.testing.expect(reached_success);
    }
}
