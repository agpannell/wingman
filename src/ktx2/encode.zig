//! KTX2 serialization of declared formats, metadata and pre-encoded whole mip levels.

const std = @import("std");
const ktx2 = @import("../ktx2.zig");

const memory = @import("../common/byte_ranges.zig");

const Source = @import("container.zig").Source;
const dfd = @import("dfd.zig");
const fixture = @import("fixtures.zig");
const global = @import("global_data.zig");
const types = @import("format.zig");
const validate = @import("validation.zig");
const testing = std.testing;

/// Complete container input. Mips are supplied from largest to smallest; writing stores them in
/// reverse order. All input arrays, descriptors and payloads remain immutable through the call.
/// Bytes already have their declared encoded representation; no compression/conversion occurs.
pub const EncodeTexture = struct {
    header: types.Header,
    descriptor: []const u8,
    levels: []const types.Level,
    /// Unique UTF-8 keys in increasing order, without terminators; values remain opaque.
    metadata: []const types.KeyValue = &.{},
    /// Shared tables and image directory for BasisLZ. Directory framing, slice ranges and image
    /// flags are validated; compressed contents/profile meanings are not.
    global_data: []const u8 = &.{},
};

/// Container admission, wire size, capacity or overlapping input/output storage failure.
pub const EncodeError = types.Error || error{ DestinationTooSmall, OverlappingStorage };

/// Validates every input record and returns the exact serialized byte count without allocating.
pub fn encodedSize(image: *const EncodeTexture, options: types.Options) EncodeError!usize {
    return (try preflight(image, options)).size;
}

/// Allocates and serializes a complete file. Free the returned byte slice with the same allocator.
/// Preflight precedes allocation; any failure releases the output request.
pub fn encode(
    allocator: std.mem.Allocator,
    image: *const EncodeTexture,
    options: types.Options,
) (EncodeError || std.mem.Allocator.Error)![]u8 {
    const layout = try preflight(image, options);
    const output = try allocator.alloc(u8, layout.size);
    errdefer allocator.free(output);
    return try encodeInto(image, output, options);
}

/// Writes and returns the used destination prefix. All validation, capacity and overlap checks
/// precede writes. Input descriptor/record storage and payloads must not overlap the used prefix.
/// Spare output and all output on failure remain unchanged. No allocation occurs.
pub fn encodeInto(
    image: *const EncodeTexture,
    output: []u8,
    options: types.Options,
) EncodeError![]u8 {
    const layout = try preflight(image, options);
    if (layout.size > output.len) return error.DestinationTooSmall;
    const result = output[0..layout.size];
    try rejectOverlap(image, result);
    @memset(result, 0);
    @memcpy(result[0..12], &validate.identifier);
    const header = image.header;
    const fields = [_]u32{
        header.vk_format,
        header.type_size,
        header.width,
        header.height,
        header.depth,
        header.layers,
        header.faces,
        header.levels,
        @backingInt(header.supercompression),
    };
    for (fields, 0..) |value, index| put(u32, result, 12 + index * 4, value);
    const descriptor_offset = 80 + image.levels.len * 24;
    put(u32, result, 48, @intCast(descriptor_offset));
    put(u32, result, 52, @intCast(image.descriptor.len));
    var position = descriptor_offset;
    append(result, &position, image.descriptor);
    if (layout.metadata_size != 0) {
        put(u32, result, 56, @intCast(position));
        put(u32, result, 60, @intCast(layout.metadata_size));
        for (image.metadata) |entry| {
            const size = entry.key.len + 1 + entry.value.len;
            put(u32, result, position, @intCast(size));
            position += 4;
            append(result, &position, entry.key);
            position += 1; // NUL and all padding were cleared with the destination.
            append(result, &position, entry.value);
            position += (4 - size % 4) % 4;
        }
    }
    if (image.global_data.len != 0) {
        position = layout.global_offset;
        put(u64, result, 64, position);
        put(u64, result, 72, image.global_data.len);
        append(result, &position, image.global_data);
    }
    var index = image.levels.len;
    while (index != 0) {
        index -= 1;
        const item = image.levels[index];
        position = validate.alignForward(position, layout.alignment) catch unreachable;
        const record = result[80 + index * 24 ..][0..24];
        put(u64, record, 0, position);
        put(u64, record, 8, item.data.len);
        put(u64, record, 16, item.uncompressed_size);
        append(result, &position, item.data);
    }
    std.debug.assert(position == result.len);
    return result;
}

test encodeInto {
    const source = try Source.open(&fixture.r8_mips, .{});
    const levels = [_]types.Level{ source.level(0).?, source.level(1).? };
    const image: EncodeTexture = .{
        .header = source.header,
        .descriptor = source.descriptor.data,
        .levels = &levels,
    };
    var output: [256]u8 = @splat(0xa5);
    const file = try encodeInto(&image, &output, .{});
    try testing.expectEqualSlices(u8, &fixture.r8_mips, file);
    try testing.expectEqual(@as(u8, 0xa5), output[file.len]);
}

test "KTX2 writing preserves binary metadata and refuses unsorted or overlapping input" {
    const source = try Source.open(&fixture.r8_mips, .{});
    var levels = [_]types.Level{ source.level(0).?, source.level(1).? };
    var entries = [_]types.KeyValue{ .{ .key = "a", .value = &.{
        0, 255, 0,
    } }, .{ .key = "é", .value = "" } };
    const image: EncodeTexture = .{
        .header = source.header,
        .descriptor = source.descriptor.data,
        .levels = &levels,
        .metadata = &entries,
    };
    const owned = try encode(testing.allocator, &image, .{});
    defer testing.allocator.free(owned);
    const decoded = try Source.open(owned, .{});
    var metadata = decoded.keyValues();
    try testing.expectEqualSlices(u8, entries[0].value, metadata.next().?.value);
    try testing.expectEqualStrings("é", metadata.next().?.key);
    try testing.expectEqual(null, metadata.next());

    var output: [512]u8 = @splat(0xa5);
    const before = output;
    try testing.expectError(error.DestinationTooSmall, encodeInto(&image, output[0..1], .{}));
    entries[1].key = "a";
    try testing.expectError(error.InvalidKtx2, encodeInto(&image, &output, .{}));
    entries[1].key = "\xff";
    try testing.expectError(error.InvalidKtx2, encodeInto(&image, &output, .{}));
    entries[1].key = "é";
    levels[0].data = output[0..2];
    try testing.expectError(error.OverlappingStorage, encodeInto(&image, &output, .{}));
    try testing.expectEqualSlices(u8, &before, &output);
}

test "KTX2 writing supports dimensional declarations and explicit generation of missing mips" {
    const source = try Source.open(&fixture.r8_mips, .{});
    const payload: [8]u8 = @splat(7);
    const headers = [_]types.Header{
        .{ .vk_format = 9, .width = 2, .levels = 0 },
        .{ .vk_format = 9, .width = 2, .layers = 4 },
        .{ .vk_format = 9, .width = 2, .height = 2, .depth = 2 },
    };
    for (headers, [_]usize{ 2, 8, 8 }) |header, size| {
        const levels = [_]types.Level{.{ .data = payload[0..size], .uncompressed_size = size }};
        const image: EncodeTexture = .{
            .header = header,
            .descriptor = source.descriptor.data,
            .levels = &levels,
        };
        const output = try encode(testing.allocator, &image, .{});
        defer testing.allocator.free(output);
        const decoded = try Source.open(output, .{});
        try testing.expectEqual(header, decoded.header);
        try testing.expectEqualSlices(u8, payload[0..size], decoded.level(0).?.data);
    }
}

test "KTX2 BasisLZ validates codebooks, paired slices and animation references before writing" {
    var descriptor_storage: [60]u8 = undefined;
    const descriptor = try globalTestDescriptor(&descriptor_storage, 163, true);
    // Two image records, followed by three deliberately opaque one-byte table payloads.
    var shared: [63]u8 = @splat(0);
    put(u16, &shared, 0, 1);
    put(u16, &shared, 2, 1);
    for ([_]usize{ 4, 8, 12 }) |field| put(u32, &shared, field, 1);
    put(u32, &shared, 28, 1);
    put(u32, &shared, 32, 1);
    put(u32, &shared, 36, 1);
    put(u32, &shared, 40, 2);
    put(u32, &shared, 44, 2);
    put(u32, &shared, 48, 1);
    put(u32, &shared, 52, 3);
    put(u32, &shared, 56, 1);
    shared[60..63].* = .{ 0xe1, 0x51, 0x7a };
    const animation = [_]u8{ 1, 0, 0, 0, 30, 0, 0, 0, 0, 0, 0, 0 };
    const entries = [_]types.KeyValue{.{ .key = "KTXanimData", .value = &animation }};
    const levels = [_]types.Level{.{ .data = &.{ 10, 20, 30, 40 }, .uncompressed_size = 0 }};
    var image: EncodeTexture = .{
        .header = .{
            .vk_format = 0,
            .width = 4,
            .height = 4,
            .layers = 2,
            .supercompression = .basis_lz,
        },
        .descriptor = descriptor,
        .levels = &levels,
        .metadata = &entries,
        .global_data = &shared,
    };
    var output: [512]u8 = @splat(0xa5);
    const wire = try encodeInto(&image, &output, .{});
    const source = try Source.open(wire, .{});
    const tables = source.basisLz().?;
    try testing.expectEqual(1, tables.endpoint_count);
    try testing.expectEqual(1, tables.selector_count);
    try testing.expectEqualSlices(u8, &.{0xe1}, tables.endpoints);
    try testing.expectEqualSlices(u8, &.{0x51}, tables.selectors);
    try testing.expectEqualSlices(u8, &.{0x7a}, tables.tables);
    const first = source.imageSlice(0, 0, 0, 0).?;
    const second = source.imageSlice(0, 1, 0, 0).?;
    try testing.expectEqualSlices(u8, &.{10}, first.data);
    try testing.expectEqualSlices(u8, &.{20}, first.alpha);
    try testing.expectEqual(0, first.flags);
    try testing.expectEqualSlices(u8, &.{30}, second.data);
    try testing.expectEqualSlices(u8, &.{40}, second.alpha);
    try testing.expectEqual(2, second.flags);
    try testing.expectEqual(null, source.imageSlice(0, 2, 0, 0));
    try testing.expectEqual(null, source.imageSlice(1, 0, 0, 0));
    try testing.expectEqual(null, source.imageSlice(0, 0, 1, 0));
    try testing.expectEqual(null, source.imageSlice(0, 0, 0, 1));

    const before = output;
    const shared_offset = std.mem.readInt(u64, wire[64..72], .little);
    // Reader and writer use the same admission, with independent on-wire mutations as controls.
    for ([_]usize{ 4, 8, 12, 16, 20, 28, 36, 40, 48, 56 }) |field| {
        var changed = before;
        const position: usize = @intCast(shared_offset + field);
        @memset(changed[position..][0..4], 0xff);
        try testing.expectError(error.InvalidKtx2, Source.open(changed[0..wire.len], .{}));
    }
    for ([_]usize{ 0, 2 }) |field| {
        var changed = before;
        const position: usize = @intCast(shared_offset + field);
        @memset(changed[position..][0..2], 0);
        try testing.expectError(error.InvalidKtx2, Source.open(changed[0..wire.len], .{}));
    }
    image.metadata = &.{};
    try testing.expectError(error.InvalidKtx2, encodeInto(&image, &output, .{}));
    image.metadata = &entries;
    image.global_data = shared[0 .. shared.len - 1];
    try testing.expectError(error.InvalidKtx2, encodeInto(&image, &output, .{}));
    image.global_data = &shared;
    // A KTX2 animation must start with an I-frame, even if a caller has other prior-frame state.
    put(u32, &shared, 20, 2);
    try testing.expectError(error.InvalidKtx2, encodeInto(&image, &output, .{}));
    var changed_first_frame = before;
    put(u32, &changed_first_frame, @intCast(shared_offset + 20), 2);
    try testing.expectError(error.InvalidKtx2, Source.open(changed_first_frame[0..wire.len], .{}));
    put(u32, &shared, 20, 1); // Only bit 1 is a defined BasisLZ image flag.
    try testing.expectError(error.InvalidKtx2, encodeInto(&image, &output, .{}));
    put(u32, &shared, 20, 0);
    put(u32, &shared, 56, 0); // Paired DFD requires an alpha slice for every image.
    try testing.expectError(error.InvalidKtx2, encodeInto(&image, &output, .{}));
    try testing.expectEqualSlices(u8, &before, &output);
}

test "KTX2 BasisLZ volume directory follows the shrinking depth of each mip" {
    var descriptor_storage: [60]u8 = undefined;
    const descriptor = try globalTestDescriptor(&descriptor_storage, 163, false);
    var shared: [83]u8 = @splat(0);
    put(u16, &shared, 0, 1);
    put(u16, &shared, 2, 1);
    for ([_]usize{ 4, 8, 12 }) |field| put(u32, &shared, field, 1);
    for (0..3) |index| {
        put(u32, &shared, 24 + index * 20, if (index == 1) 1 else 0);
        put(u32, &shared, 28 + index * 20, 1);
    }
    const base = [_]u8{ 3, 4 };
    const smaller = [_]u8{5};
    const levels = [_]types.Level{
        .{ .data = &base, .uncompressed_size = 0 },
        .{ .data = &smaller, .uncompressed_size = 0 },
    };
    const image: EncodeTexture = .{
        .header = .{
            .vk_format = 0,
            .width = 2,
            .height = 2,
            .depth = 2,
            .levels = 2,
            .supercompression = .basis_lz,
        },
        .descriptor = descriptor,
        .levels = &levels,
        .global_data = &shared,
    };
    const wire = try encode(testing.allocator, &image, .{});
    defer testing.allocator.free(wire);
    const source = try Source.open(wire, .{});
    try testing.expectEqualSlices(u8, &.{3}, source.imageSlice(0, 0, 0, 0).?.data);
    try testing.expectEqualSlices(u8, &.{4}, source.imageSlice(0, 0, 0, 1).?.data);
    try testing.expectEqualSlices(u8, &.{5}, source.imageSlice(1, 0, 0, 0).?.data);
    try testing.expectEqual(null, source.imageSlice(1, 0, 0, 1));
    try testing.expectEqual(0, source.imageSlice(0, 0, 0, 0).?.alpha.len);
    put(u32, &shared, 32, 1); // A one-sample DFD must have no alpha offset or length.
    var output: [512]u8 = @splat(0xa5);
    const before = output;
    try testing.expectError(error.InvalidKtx2, encodeInto(&image, &output, .{}));
    try testing.expectEqualSlices(u8, &before, &output);
}

test "KTX2 global directory counts reject overflow before walking image records" {
    var descriptor_storage: [60]u8 = undefined;
    const descriptor = try globalTestDescriptor(&descriptor_storage, 163, false);
    const levels: [32]types.Level = @splat(.{ .data = &.{1}, .uncompressed_size = 0 });
    const shared: [20]u8 = @splat(0);
    const image: EncodeTexture = .{
        .header = .{
            .vk_format = 0,
            .width = 0xffffffff,
            .height = 0xffffffff,
            .depth = 0xffffffff,
            .layers = 0xffffffff,
            .levels = 32,
            .supercompression = .basis_lz,
        },
        .descriptor = descriptor,
        .levels = &levels,
        .global_data = &shared,
    };
    const options: types.Options = .{
        .limits = .{
            .maximum_extent = 0xffffffff,
            .maximum_layers = 0xffffffff,
            .maximum_image_slices = 0xffffffffffffffff,
        },
    };
    var output: [512]u8 = @splat(0xa5);
    const before = output;
    try testing.expectError(error.SizeOverflow, encodeInto(&image, &output, options));
    try testing.expectEqualSlices(u8, &before, &output);
}

fn globalTestDescriptor(storage: []u8, model: u8, alpha: bool) ![]const u8 {
    const samples = [_]dfd.Sample{
        .{ .bit_offset = 0, .bit_length = 64, .channel_type = 0, .lower = 0, .upper = 0xffffffff },
        .{
            .bit_offset = 64,
            .bit_length = 64,
            .channel_type = 15,
            .lower = 0,
            .upper = 0xffffffff,
        },
    };
    var planes: [8]u8 = @splat(0);
    planes[0] = 8;
    if (alpha) planes[1] = 8;
    const count: usize = if (alpha) 2 else 1;
    const descriptor: dfd.BasicDescriptor = .{ .color_model = model, .block_extent = .{
        4, 4, 1, 1,
    }, .bytes_plane = planes, .samples = samples[0..count] };
    return try descriptor.encodeInto(storage);
}

const Layout = struct { size: usize, metadata_size: usize, global_offset: usize, alignment: usize };

fn preflight(image: *const EncodeTexture, options: types.Options) EncodeError!Layout {
    const limits = options.limits;
    if (image.levels.len != image.header.levelCount()) return error.InvalidKtx2;
    if (image.levels.len > limits.maximum_levels or image.levels.len > 32)
        return error.LimitExceeded;
    if (image.descriptor.len > limits.maximum_descriptor_bytes) return error.LimitExceeded;
    if (image.metadata.len > limits.maximum_metadata_entries) return error.LimitExceeded;
    if (image.global_data.len > limits.maximum_encoded_bytes) return error.LimitExceeded;
    const descriptor = try dfd.DataFormatDescriptor.open(image.descriptor);
    try validate.header(image.header, descriptor, options);
    const needs_global = image.header.supercompression == .basis_lz;
    if (needs_global != (image.global_data.len != 0)) return error.InvalidKtx2;
    var metadata_size: usize = 0;
    var previous: ?[]const u8 = null;
    var has_animation = false;
    for (image.metadata) |entry| {
        var size = try add(entry.key.len, 1);
        size = try add(size, entry.value.len);
        if (size > std.math.maxInt(u32)) return error.SizeOverflow;
        const padding = (4 - size % 4) % 4;
        metadata_size = try add(metadata_size, 4);
        metadata_size = try add(metadata_size, try add(size, padding));
        if (metadata_size > limits.maximum_metadata_bytes) return error.LimitExceeded;
        try validate.key(entry, previous);
        const is_animation = std.mem.eql(u8, entry.key, "KTXanimData");
        if (is_animation and entry.value.len == 12) has_animation = true;
        previous = entry.key;
    }
    const directory = try global.Directory.open(
        image.header,
        descriptor,
        image.global_data,
        has_animation,
        options.limits.maximum_image_slices,
    );
    var position = try add(80 + image.levels.len * 24, image.descriptor.len);
    position = try add(position, metadata_size);
    if (position > std.math.maxInt(u32)) return error.SizeOverflow;
    var global_offset: usize = 0;
    if (needs_global) {
        global_offset = try validate.alignForward(position, 8);
        position = try add(global_offset, image.global_data.len);
    }
    if (position > limits.maximum_encoded_bytes) return error.LimitExceeded;
    const alignment = validate.levelAlignment(image.header, descriptor);
    var expanded: u64 = 0;
    var index = image.levels.len;
    while (index != 0) {
        index -= 1;
        const item = image.levels[index];
        try validate.level(
            image.header,
            descriptor,
            @intCast(index),
            item.data.len,
            item.uncompressed_size,
        );
        try directory.validateLevel(@intCast(index), item.data);
        expanded = std.math.add(
            u64,
            expanded,
            item.uncompressed_size,
        ) catch return error.SizeOverflow;
        if (expanded > limits.maximum_uncompressed_bytes) return error.LimitExceeded;
        position = try validate.alignForward(position, alignment);
        position = try add(position, item.data.len);
        if (position > limits.maximum_encoded_bytes) return error.LimitExceeded;
    }
    return .{
        .size = position,
        .metadata_size = metadata_size,
        .global_offset = global_offset,
        .alignment = alignment,
    };
}

fn rejectOverlap(image: *const EncodeTexture, output: []const u8) EncodeError!void {
    const spans = [_][]const u8{
        std.mem.asBytes(image),
        image.descriptor,
        std.mem.sliceAsBytes(image.levels),
        std.mem.sliceAsBytes(image.metadata),
        image.global_data,
    };
    for (spans) |data| if (memory.overlaps(data, output)) return error.OverlappingStorage;
    for (
        image.levels,
    ) |item| if (memory.overlaps(item.data, output)) return error.OverlappingStorage;
    for (image.metadata) |entry| {
        if (memory.overlaps(
            entry.key,
            output,
        ) or memory.overlaps(entry.value, output)) return error.OverlappingStorage;
    }
}

fn add(first: usize, second: usize) types.Error!usize {
    return std.math.add(usize, first, second) catch error.SizeOverflow;
}

fn append(output: []u8, position: *usize, data: []const u8) void {
    @memcpy(output[position.*..][0..data.len], data);
    position.* += data.len;
}

fn put(comptime T: type, output: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, output[offset..][0..@divExact(@bitSizeOf(T), 8)], value, .little);
}

test "KTX2 writer refuses every known input span before changing any destination byte" {
    const source = try ktx2.Source.open(&fixture.r8_mips, .{});
    const Span = enum { root, descriptor, levels, metadata, payload, key, value };
    for (std.enums.values(Span)) |span| {
        var arena: [1024]u8 align(16) = @splat(0xa5);
        var levels = [_]ktx2.Level{ source.level(0).?, source.level(1).? };
        var entries = [_]ktx2.KeyValue{.{ .key = "a", .value = "b" }};
        var outer: ktx2.EncodeTexture = .{
            .header = source.header,
            .descriptor = source.descriptor.data,
            .levels = &levels,
            .metadata = &entries,
        };
        var texture = &outer;
        switch (span) {
            .root => {
                texture = @ptrCast(&arena);
                texture.* = outer;
            },
            .descriptor => {
                @memcpy(arena[0..outer.descriptor.len], outer.descriptor);
                outer.descriptor = arena[0..outer.descriptor.len];
            },
            .levels => {
                const records: *[2]ktx2.Level = @ptrCast(&arena);
                records.* = levels;
                outer.levels = records;
            },
            .metadata => {
                const records: *[1]ktx2.KeyValue = @ptrCast(&arena);
                records.* = entries;
                outer.metadata = records;
            },
            .payload => levels[0].data = arena[0..2],
            .key => {
                arena[0] = 'a';
                entries[0].key = arena[0..1];
            },
            .value => entries[0].value = arena[0..1],
        }
        const before = arena;
        try testing.expectError(error.OverlappingStorage, ktx2.encodeInto(texture, &arena, .{}));
        try testing.expectEqualSlices(u8, &before, &arena);
    }

    const basis = try ktx2.Source.open(&fixture.etc1s, .{});
    const levels = [_]ktx2.Level{basis.level(0).?};
    var arena: [1024]u8 = @splat(0xa5);
    @memcpy(arena[0..basis.global_data.len], basis.global_data);
    const texture: ktx2.EncodeTexture = .{
        .header = basis.header,
        .descriptor = basis.descriptor.data,
        .levels = &levels,
        .global_data = arena[0..basis.global_data.len],
    };
    const before = arena;
    try testing.expectError(error.OverlappingStorage, ktx2.encodeInto(&texture, &arena, .{}));
    try testing.expectEqualSlices(u8, &before, &arena);
}

test "KTX2 writer permits inputs in spare output capacity and preserves them" {
    const source = try ktx2.Source.open(&fixture.r8_mips, .{});
    var arena: [2048]u8 align(16) = @splat(0xa5);
    const levels: *[2]ktx2.Level = @ptrCast(@alignCast(arena[512..].ptr));
    const entries: *[1]ktx2.KeyValue = @ptrCast(@alignCast(arena[768..].ptr));
    const texture: *ktx2.EncodeTexture = @ptrCast(@alignCast(arena[1024..].ptr));
    @memcpy(arena[640..684], source.descriptor.data);
    arena[832..837].* = .{ 23, 42, 17, 'a', 255 };
    levels.* = .{
        .{ .data = arena[832..834], .uncompressed_size = 2 },
        .{ .data = arena[834..835], .uncompressed_size = 1 },
    };
    entries.* = .{.{ .key = arena[835..836], .value = arena[836..837] }};
    texture.* = .{
        .header = source.header,
        .descriptor = arena[640..684],
        .levels = levels,
        .metadata = entries,
    };
    const before = arena;
    const wire = try ktx2.encodeInto(texture, &arena, .{});
    try testing.expect(wire.len < 512);
    try testing.expectEqualSlices(u8, before[wire.len..], arena[wire.len..]);
    const result = try ktx2.Source.open(wire, .{});
    try testing.expectEqualSlices(u8, &.{ 23, 42 }, result.level(0).?.data);
    var metadata = result.keyValues();
    try testing.expectEqualStrings("a", metadata.next().?.key);
    try testing.expectEqual(null, metadata.next());
}

test "KTX2 admission precedes allocation and capacity; OOM is retryable without a leak" {
    const source = try ktx2.Source.open(&fixture.r8_mips, .{});
    const levels = [_]ktx2.Level{ source.level(0).?, source.level(1).? };
    var texture: ktx2.EncodeTexture = .{
        .header = source.header,
        .descriptor = source.descriptor.data,
        .levels = &levels,
    };
    var allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    texture.header.width = 0;
    try testing.expectError(error.InvalidKtx2, ktx2.encode(allocator.allocator(), &texture, .{}));
    var output: [256]u8 = @splat(0xa5);
    const before = output;
    try testing.expectError(error.InvalidKtx2, ktx2.encodeInto(&texture, output[0..1], .{}));
    try testing.expectEqual(0, allocator.allocations);
    try testing.expect(!allocator.has_induced_failure);

    texture.header.width = 2;
    try testing.expectError(error.OutOfMemory, ktx2.encode(allocator.allocator(), &texture, .{}));
    try testing.expect(allocator.has_induced_failure);
    try testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
    try testing.expectError(
        error.DestinationTooSmall,
        ktx2.encodeInto(&texture, output[0..1], .{}),
    );
    try testing.expectEqualSlices(u8, &before, &output);

    allocator.fail_index = std.math.maxInt(usize);
    const owned = try ktx2.encode(allocator.allocator(), &texture, .{});
    try testing.expectEqualSlices(u8, &fixture.r8_mips, owned);
    allocator.allocator().free(owned);
    try testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}

test "KTX2 serialized output survives retirement of every input record and payload" {
    const original = try ktx2.Source.open(&fixture.r8_mips, .{});
    var descriptor: [44]u8 = original.descriptor.data[0..44].*;
    var data = [_]u8{ 23, 42, 17 };
    var levels = [_]ktx2.Level{
        .{ .data = data[0..2], .uncompressed_size = 2 },
        .{ .data = data[2..3], .uncompressed_size = 1 },
    };
    var key = [_]u8{'a'};
    var value = [_]u8{ 0, 255 };
    var entries = [_]ktx2.KeyValue{.{ .key = &key, .value = &value }};
    var texture: ktx2.EncodeTexture = .{
        .header = original.header,
        .descriptor = &descriptor,
        .levels = &levels,
        .metadata = &entries,
    };
    const output = try ktx2.encode(testing.allocator, &texture, .{});
    defer testing.allocator.free(output);
    @memset(&descriptor, 0);
    @memset(&data, 0);
    @memset(&key, 0);
    @memset(&value, 0);
    @memset(std.mem.sliceAsBytes(&levels), 0);
    @memset(std.mem.sliceAsBytes(&entries), 0);
    @memset(std.mem.asBytes(&texture), 0);

    const source = try ktx2.Source.open(output, .{});
    // A borrowed view can be copied and the original object retired; it only borrows the file.
    const copied = source;
    try testing.expectEqualSlices(u8, &.{ 23, 42 }, copied.level(0).?.data);
    try testing.expectEqualSlices(u8, &.{17}, copied.level(1).?.data);
    var first = copied.keyValues();
    var second = copied.keyValues();
    const entry = first.next().?;
    try testing.expectEqualStrings("a", entry.key);
    try testing.expectEqualSlices(u8, &.{ 0, 255 }, entry.value);
    try testing.expectEqualStrings("a", second.next().?.key);
    try testing.expectEqual(null, first.next());
}

test "KTX2 RGB byte alignment uses lcm rather than a power-of-two rounding mask" {
    const samples = [_]ktx2.Sample{
        .{ .bit_offset = 0, .bit_length = 8, .channel_type = 0, .lower = 0, .upper = 255 },
        .{ .bit_offset = 8, .bit_length = 8, .channel_type = 1, .lower = 0, .upper = 255 },
        .{ .bit_offset = 16, .bit_length = 8, .channel_type = 2, .lower = 0, .upper = 255 },
    };
    const descriptor: ktx2.BasicDescriptor = .{ .color_model = 1, .bytes_plane = .{
        3, 0, 0, 0, 0, 0, 0, 0,
    }, .samples = &samples };
    var descriptor_bytes: [76]u8 = undefined;
    const levels = [_]ktx2.Level{ .{ .data = &.{
        1, 2, 3, 4, 5, 6, 7, 8, 9,
    }, .uncompressed_size = 9 }, .{ .data = &.{ 10, 11, 12 }, .uncompressed_size = 3 } };
    const texture: ktx2.EncodeTexture = .{
        .header = .{ .vk_format = 23, .width = 3, .levels = 2 },
        .descriptor = try descriptor.encodeInto(&descriptor_bytes),
        .levels = &levels,
    };
    var output: [256]u8 = @splat(0xa5);
    const wire = try ktx2.encodeInto(&texture, &output, .{});
    try testing.expectEqual(225, wire.len);
    try testing.expectEqual(216, std.mem.readInt(u64, output[80..88], .little));
    try testing.expectEqual(204, std.mem.readInt(u64, output[104..112], .little));
    try testing.expectEqualSlices(u8, &@as([9]u8, @splat(0)), output[207..216]);
    const source = try ktx2.Source.open(wire, .{});
    try testing.expectEqualSlices(u8, levels[0].data, source.level(0).?.data);
    output[211] = 1;
    try testing.expectError(error.InvalidKtx2, ktx2.Source.open(wire, .{}));
}

test "KTX2 opaque supercompressed levels are framing rather than entropy validation" {
    for ([_]ktx2.Supercompression{ .zstandard, .zlib }) |scheme| {
        const original = try ktx2.Source.open(&fixture.r8_mips, .{});
        var header = original.header;
        header.supercompression = scheme;
        const levels = [_]ktx2.Level{
            .{ .data = &.{0xff}, .uncompressed_size = 2 },
            .{ .data = &.{0xfe}, .uncompressed_size = 1 },
        };
        const texture: ktx2.EncodeTexture = .{
            .header = header,
            .descriptor = original.descriptor.data,
            .levels = &levels,
        };
        var output: [256]u8 = undefined;
        const wire = try ktx2.encodeInto(&texture, &output, .{});
        const source = try ktx2.Source.open(wire, .{});
        try testing.expectEqualSlices(u8, &.{0xff}, source.level(0).?.data);
        try testing.expectEqual(null, source.imageSlice(0, 0, 0, 0));
        for ([_]u32{ 4, 5, 6, 0xffffffff }) |reserved| {
            std.mem.writeInt(u32, output[44..48], reserved, .little);
            try testing.expectError(error.UnsupportedFormat, ktx2.Source.open(wire, .{}));
        }
    }
}

test "KTX2 reader and writer enforce caller budgets before publication and allocation" {
    const source = try ktx2.Source.open(&fixture.etc1s, .{});
    const levels = [_]ktx2.Level{source.level(0).?};
    var iterator = source.keyValues();
    const entries = [_]ktx2.KeyValue{iterator.next().?};
    var texture: ktx2.EncodeTexture = .{
        .header = source.header,
        .descriptor = source.descriptor.data,
        .levels = &levels,
        .metadata = &entries,
        .global_data = source.global_data,
    };
    const refused = [_]ktx2.Options{
        .{ .limits = .{ .maximum_encoded_bytes = fixture.etc1s.len - 1 } },
        .{ .limits = .{ .maximum_extent = 3 } },
        .{ .limits = .{ .maximum_levels = 0 } },
        .{ .limits = .{ .maximum_descriptor_bytes = 43 } },
        .{ .limits = .{ .maximum_metadata_bytes = source.metadata.len - 1 } },
        .{ .limits = .{ .maximum_metadata_entries = 0 } },
        .{ .limits = .{ .maximum_image_slices = 0 } },
    };
    var output: [512]u8 = @splat(0xa5);
    const before = output;
    var allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    for (refused) |options| {
        try testing.expectError(error.LimitExceeded, ktx2.Source.open(&fixture.etc1s, options));
        try testing.expectError(error.LimitExceeded, ktx2.encodeInto(&texture, &output, options));
        try testing.expectError(
            error.LimitExceeded,
            ktx2.encode(allocator.allocator(), &texture, options),
        );
        try testing.expectEqualSlices(u8, &before, &output);
    }
    texture.header.layers = 1;
    const layer_limit: ktx2.Options = .{ .limits = .{ .maximum_layers = 0 } };
    try testing.expectError(error.LimitExceeded, ktx2.encodeInto(&texture, &output, layer_limit));
    try testing.expectEqualSlices(u8, &before, &output);

    const raw = try ktx2.Source.open(&fixture.r8_mips, .{});
    const raw_levels = [_]ktx2.Level{ raw.level(0).?, raw.level(1).? };
    const raw_texture: ktx2.EncodeTexture = .{
        .header = raw.header,
        .descriptor = raw.descriptor.data,
        .levels = &raw_levels,
    };
    const expanded_limit: ktx2.Options = .{ .limits = .{ .maximum_uncompressed_bytes = 2 } };
    try testing.expectError(
        error.LimitExceeded,
        ktx2.encodeInto(&raw_texture, &output, expanded_limit),
    );
    try testing.expectEqualSlices(u8, &before, &output);
    try testing.expect(!allocator.has_induced_failure);
    try testing.expectEqual(0, allocator.allocations);
}
