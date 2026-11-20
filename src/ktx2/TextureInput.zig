//! Supplied KTX2 texture data for serialization. Provide complete descriptor bytes, encoded whole
//! mips from largest to smallest, sorted metadata entries and optional BasisLZ global data. Writing
//! stores smaller mips first and performs no compression, pixel conversion or GPU work.
//!
//! All records and payloads are borrowed and remain immutable through a call. Methods keep pointer
//! receivers so overlap checks inspect the caller's actual root record. Sizing admits without
//! allocating; writing admits before output publication. Returned bytes are independent of inputs.
const std = @import("std");
const ktx2 = @import("../ktx2.zig");
const memory = @import("../common/byte_ranges.zig");
const KhronosDataFormatDescriptor = @import("../common/KhronosDataFormatDescriptor.zig");
const fixtures = @import("fixtures.zig");
const layout = @import("layout.zig");
const TextureInput = @This();
const testing = std.testing;

/// Format/topology declarations; levels = 0 supplies one mip and requests generated mips.
header: ktx2.Header,
/// Complete immutable Khronos descriptor, including its total-size field and any opaque blocks.
descriptor: []const u8,
/// Borrowed whole-mip records in largest-to-smallest order, exactly header.levelCount() entries.
levels: []const ktx2.Level,
/// Borrowed unique UTF-8 keys in increasing order and opaque binary values; no stored framing.
metadata: []const ktx2.Metadata.Entry = &.{},
/// Raw BasisLZ image directory and shared compressed tables, empty for other schemes. Framing,
/// image ranges and flags are checked; compressed contents remain the codec's responsibility.
supercompression_data: []const u8 = &.{},

/// Invalid/unsupported declarations, a caller limit or unrepresentable size arithmetic.
pub const SizeError = ktx2.Error;
/// Admission failures, insufficient destination capacity or protected input/output overlap.
pub const EncodeIntoError = SizeError || error{ DestinationTooSmall, OverlappingStorage };
/// Admission failures, allocator exhaustion or an allocation overlapping protected input storage.
pub const EncodeError = SizeError || std.mem.Allocator.Error || error{OverlappingStorage};

/// Validates all supplied records and returns the exact serialized byte count without allocating.
pub fn encodedSize(self: *const TextureInput, options: ktx2.Options) SizeError!usize {
    return (try preflight(self, options)).size;
}

/// Allocates a complete file with the explicit allocator; free the returned slice with that same
/// allocator. Preflight precedes allocation. Every failure after allocation releases the request.
pub fn encode(
    self: *const TextureInput,
    allocator: std.mem.Allocator,
    options: ktx2.Options,
) EncodeError![]u8 {
    const validated = try preflight(self, options);
    const output = try allocator.alloc(u8, validated.size);
    errdefer allocator.free(output);
    try writeValidated(self, output, validated);
    return output;
}

/// Writes the used destination prefix after admission, capacity and overlap checks. Protected input
/// records and payloads must be disjoint from that prefix; they may occupy spare output capacity.
/// Spare bytes and the entire destination on refusal remain unchanged. No allocation occurs.
pub fn encodeInto(
    self: *const TextureInput,
    output: []u8,
    options: ktx2.Options,
) EncodeIntoError![]u8 {
    const validated = try preflight(self, options);
    if (validated.size > output.len) return error.DestinationTooSmall;
    const result = output[0..validated.size];
    try writeValidated(self, result, validated);
    return result;
}

fn writeValidated(
    input: *const TextureInput,
    result: []u8,
    validated: Layout,
) error{OverlappingStorage}!void {
    try rejectOverlap(input, result);
    // The header contains optional fields. Level records and payloads are written in full below, so
    // only the header and the actual padding need clearing.
    @memset(result[0..80], 0);
    @memcpy(result[0..12], &layout.identifier);
    const header = input.header;
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
    for (fields, 0..) |value, index|
        put(u32, result, 12 + index * 4, value);
    const descriptor_offset = 80 + input.levels.len * 24;
    put(u32, result, 48, @intCast(descriptor_offset));
    put(u32, result, 52, @intCast(input.descriptor.len));
    var position = descriptor_offset;
    append(result, &position, input.descriptor);
    if (validated.metadata_size != 0) {
        put(u32, result, 56, @intCast(position));
        put(u32, result, 60, @intCast(validated.metadata_size));
        for (input.metadata) |entry| {
            const size = entry.key.len + 1 + entry.value.len;
            put(u32, result, position, @intCast(size));
            position += 4;
            append(result, &position, entry.key);
            result[position] = 0;
            position += 1;
            append(result, &position, entry.value);
            const padding = (4 - size % 4) % 4;
            if (padding != 0) @memset(result[position..][0..padding], 0);
            position += padding;
        }
    }
    if (input.supercompression_data.len != 0) {
        if (position != validated.global_offset) @memset(
            result[position..validated.global_offset],
            0,
        );
        position = validated.global_offset;
        put(u64, result, 64, position);
        put(u64, result, 72, input.supercompression_data.len);
        append(result, &position, input.supercompression_data);
    }
    var index = input.levels.len;
    while (index != 0) {
        index -= 1;
        const item = input.levels[index];
        const aligned = layout.alignForward(position, validated.alignment) catch unreachable;
        if (position != aligned) @memset(result[position..aligned], 0);
        position = aligned;
        const record = result[80 + index * 24 ..][0..24];
        put(u64, record, 0, position);
        put(u64, record, 8, item.data.len);
        put(u64, record, 16, item.uncompressed_size);
        append(result, &position, item.data);
    }
    std.debug.assert(position == result.len);
}

test encodeInto {
    const source = try ktx2.Container.open(&fixtures.r8_mips, .{});
    const levels = [_]ktx2.Level{ source.level(0).?, source.level(1).? };
    const input: TextureInput = .{
        .header = source.header,
        .descriptor = source.descriptor.data,
        .levels = &levels,
    };
    var output: [256]u8 = @splat(0xa5);
    const file = try input.encodeInto(&output, .{});
    try testing.expectEqualSlices(u8, &fixtures.r8_mips, file);
    try testing.expectEqual(@as(u8, 0xa5), output[file.len]);
}

test "KTX2 allocating writer rejects and releases overlapping output" {
    const OverlappingAllocator = struct {
        buffer: []u8,
        allocated: bool = false,
        freed: bool = false,
        allocated_len: usize = 0,

        fn alloc(context: *anyopaque, length: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.allocated or length > self.buffer.len) return null;
            self.allocated = true;
            self.allocated_len = length;
            return self.buffer.ptr;
        }

        fn free(context: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.freed = true;
        }
    };
    const source = try ktx2.Container.open(&fixtures.r8_mips, .{});
    var buffer: [256]u8 = @splat(0xa5);
    @memcpy(buffer[0..2], source.level(0).?.data);
    const before = buffer;
    const levels = [_]ktx2.Level{
        .{ .data = buffer[0..2], .uncompressed_size = 2 },
        source.level(1).?,
    };
    const input: TextureInput = .{
        .header = source.header,
        .descriptor = source.descriptor.data,
        .levels = &levels,
    };
    var backing: OverlappingAllocator = .{ .buffer = &buffer };
    const allocator: std.mem.Allocator = .{
        .ptr = &backing,
        .vtable = &.{
            .alloc = OverlappingAllocator.alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = OverlappingAllocator.free,
        },
    };
    try testing.expectError(error.OverlappingStorage, input.encode(allocator, .{}));
    try testing.expect(backing.allocated and backing.freed);
    // Allocator.free may poison the returned allocation; bytes beyond it remain untouched.
    try testing.expectEqualSlices(
        u8,
        before[backing.allocated_len..],
        buffer[backing.allocated_len..],
    );
}

test "KTX2 writing initializes every byte and preserves spare output" {
    const files = [_][]const u8{
        &fixtures.r8_mips,
        &fixtures.etc1s,
        &fixtures.astc_levels_none,
        &fixtures.astc_levels_zstandard,
        &fixtures.astc_levels_zlib,
    };
    for (files) |expected| {
        const source = try ktx2.Container.open(expected, .{});
        var levels: [32]ktx2.Level = undefined;
        for (levels[0..source.header.levelCount()], 0..) |*level, index| {
            level.* = source.level(@intCast(index)).?;
        }
        var entries: [16]ktx2.Metadata.Entry = undefined;
        var count: usize = 0;
        var iterator = source.metadata.iterator();
        while (iterator.next()) |entry| {
            entries[count] = entry;
            count += 1;
        }
        const input: TextureInput = .{
            .header = source.header,
            .descriptor = source.descriptor.data,
            .levels = levels[0..source.header.levelCount()],
            .metadata = entries[0..count],
            .supercompression_data = source.supercompression_data,
        };
        for ([_]u8{ 0xa5, 0x5a }) |poison| {
            var output: [512]u8 = @splat(poison);
            const written = try input.encodeInto(&output, .{});
            try testing.expectEqualSlices(u8, expected, written);
            try testing.expect(std.mem.allEqual(u8, output[written.len..], poison));
        }
    }
}

test "KTX2 allocating writer initializes the allocated bytes" {
    const PoisonedAllocator = struct {
        storage: [512]u8 align(16),
        poison: u8,
        allocated: bool = false,
        freed: bool = false,

        fn alloc(context: *anyopaque, length: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.allocated or length > self.storage.len) return null;
            self.allocated = true;
            @memset(self.storage[0..length], self.poison);
            return &self.storage;
        }

        fn free(context: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.freed = true;
        }
    };

    const files = [_][]const u8{
        &fixtures.r8_mips,
        &fixtures.etc1s,
        &fixtures.astc_levels_none,
        &fixtures.astc_levels_zstandard,
        &fixtures.astc_levels_zlib,
    };
    for (files) |expected| {
        const source = try ktx2.Container.open(expected, .{});
        var levels: [32]ktx2.Level = undefined;
        for (levels[0..source.header.levelCount()], 0..) |*level, index| {
            level.* = source.level(@intCast(index)).?;
        }
        var entries: [16]ktx2.Metadata.Entry = undefined;
        var count: usize = 0;
        var iterator = source.metadata.iterator();
        while (iterator.next()) |entry| {
            entries[count] = entry;
            count += 1;
        }
        const input: TextureInput = .{
            .header = source.header,
            .descriptor = source.descriptor.data,
            .levels = levels[0..source.header.levelCount()],
            .metadata = entries[0..count],
            .supercompression_data = source.supercompression_data,
        };
        for ([_]u8{ 0xa5, 0x5a }) |poison| {
            var backing: PoisonedAllocator = .{ .storage = @splat(poison), .poison = poison };
            const allocator: std.mem.Allocator = .{
                .ptr = &backing,
                .vtable = &.{
                    .alloc = PoisonedAllocator.alloc,
                    .resize = std.mem.Allocator.noResize,
                    .remap = std.mem.Allocator.noRemap,
                    .free = PoisonedAllocator.free,
                },
            };
            const written = try input.encode(allocator, .{});
            try testing.expect(backing.allocated);
            try testing.expectEqualSlices(u8, expected, written);
            try testing.expect(std.mem.allEqual(u8, backing.storage[written.len..], poison));
            allocator.free(written);
            try testing.expect(backing.freed);
        }
    }
}

test "KTX2 writing preserves binary metadata and refuses unsorted or overlapping input" {
    const source = try ktx2.Container.open(&fixtures.r8_mips, .{});
    var levels = [_]ktx2.Level{ source.level(0).?, source.level(1).? };
    var entries = [_]ktx2.Metadata.Entry{
        .{ .key = "a", .value = &.{ 0, 255, 0 } },
        .{ .key = "é", .value = "" },
    };
    const input: TextureInput = .{
        .header = source.header,
        .descriptor = source.descriptor.data,
        .levels = &levels,
        .metadata = &entries,
    };
    const owned = try input.encode(testing.allocator, .{});
    defer testing.allocator.free(owned);
    const decoded = try ktx2.Container.open(owned, .{});
    var metadata = decoded.metadata.iterator();
    try testing.expectEqualSlices(u8, entries[0].value, metadata.next().?.value);
    try testing.expectEqualStrings("é", metadata.next().?.key);
    try testing.expectEqual(null, metadata.next());

    var output: [512]u8 = @splat(0xa5);
    const before = output;
    try testing.expectError(error.DestinationTooSmall, input.encodeInto(output[0..1], .{}));
    entries[1].key = "a";
    try testing.expectError(error.InvalidKtx2, input.encodeInto(&output, .{}));
    entries[1].key = "\xff";
    try testing.expectError(error.InvalidKtx2, input.encodeInto(&output, .{}));
    entries[1].key = "é";
    levels[0].data = output[0..2];
    try testing.expectError(error.OverlappingStorage, input.encodeInto(&output, .{}));
    try testing.expectEqualSlices(u8, &before, &output);
}

test "KTX2 writing supports dimensional declarations and explicit generation of missing mips" {
    const source = try ktx2.Container.open(&fixtures.r8_mips, .{});
    const payload: [8]u8 = @splat(7);
    const headers = [_]ktx2.Header{
        .{ .vk_format = 9, .width = 2, .levels = 0 },
        .{ .vk_format = 9, .width = 2, .layers = 4 },
        .{ .vk_format = 9, .width = 2, .height = 2, .depth = 2 },
    };
    for (headers, [_]usize{ 2, 8, 8 }) |header, size| {
        const levels = [_]ktx2.Level{.{ .data = payload[0..size], .uncompressed_size = size }};
        const input: TextureInput = .{
            .header = header,
            .descriptor = source.descriptor.data,
            .levels = &levels,
        };
        const output = try input.encode(testing.allocator, .{});
        defer testing.allocator.free(output);
        const decoded = try ktx2.Container.open(output, .{});
        try testing.expectEqual(header, decoded.header);
        try testing.expectEqualSlices(u8, payload[0..size], decoded.level(0).?.data);
    }
}

test "KTX2 BasisLZ validates codebooks, paired slices and animation references before writing" {
    var descriptor_storage: [60]u8 = undefined;
    const descriptor = try writeBasisLzDescriptor(&descriptor_storage, 163, true);
    // Two image records, followed by three deliberately opaque one-byte table payloads.
    var shared: [63]u8 = @splat(0);
    put(u16, &shared, 0, 1);
    put(u16, &shared, 2, 1);
    for ([_]usize{ 4, 8, 12 }) |field|
        put(u32, &shared, field, 1);
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
    const entries = [_]ktx2.Metadata.Entry{.{ .key = "KTXanimData", .value = &animation }};
    const levels = [_]ktx2.Level{.{ .data = &.{ 10, 20, 30, 40 }, .uncompressed_size = 0 }};
    var input: TextureInput = .{
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
        .supercompression_data = &shared,
    };
    var output: [512]u8 = @splat(0xa5);
    const wire = try input.encodeInto(&output, .{});
    const source = try ktx2.Container.open(wire, .{});
    const basis = source.basisLz().?;
    const tables = basis.codebooks();
    try testing.expectEqual(1, tables.endpoint_count);
    try testing.expectEqual(1, tables.selector_count);
    try testing.expectEqualSlices(u8, &.{0xe1}, tables.endpoints);
    try testing.expectEqualSlices(u8, &.{0x51}, tables.selectors);
    try testing.expectEqualSlices(u8, &.{0x7a}, tables.tables);
    const first = basis.image(0, 0, 0, 0).?;
    const second = basis.image(0, 1, 0, 0).?;
    try testing.expectEqualSlices(u8, &.{10}, first.color);
    try testing.expectEqualSlices(u8, &.{20}, first.alpha);
    try testing.expectEqual(0, first.flags);
    try testing.expectEqualSlices(u8, &.{30}, second.color);
    try testing.expectEqualSlices(u8, &.{40}, second.alpha);
    try testing.expectEqual(2, second.flags);
    try testing.expectEqual(null, basis.image(0, 2, 0, 0));
    try testing.expectEqual(null, basis.image(1, 0, 0, 0));
    try testing.expectEqual(null, basis.image(0, 0, 1, 0));
    try testing.expectEqual(null, basis.image(0, 0, 0, 1));

    const before = output;
    const shared_offset = std.mem.readInt(u64, wire[64..72], .little);
    // Reader and writer use the same admission, with independent on-wire mutations as controls.
    for ([_]usize{ 4, 8, 12, 16, 20, 28, 36, 40, 48, 56 }) |field| {
        var changed = before;
        const position: usize = @intCast(shared_offset + field);
        @memset(changed[position..][0..4], 0xff);
        try testing.expectError(error.InvalidKtx2, ktx2.Container.open(changed[0..wire.len], .{}));
    }
    for ([_]usize{ 0, 2 }) |field| {
        var changed = before;
        const position: usize = @intCast(shared_offset + field);
        @memset(changed[position..][0..2], 0);
        try testing.expectError(error.InvalidKtx2, ktx2.Container.open(changed[0..wire.len], .{}));
    }
    input.metadata = &.{};
    try testing.expectError(error.InvalidKtx2, input.encodeInto(&output, .{}));
    input.metadata = &entries;
    input.supercompression_data = shared[0 .. shared.len - 1];
    try testing.expectError(error.InvalidKtx2, input.encodeInto(&output, .{}));
    input.supercompression_data = &shared;
    // A KTX2 animation must start with an I-frame, even if a caller has other prior-frame state.
    put(u32, &shared, 20, 2);
    try testing.expectError(error.InvalidKtx2, input.encodeInto(&output, .{}));
    var changed_first_frame = before;
    put(u32, &changed_first_frame, @intCast(shared_offset + 20), 2);
    try testing.expectError(
        error.InvalidKtx2,
        ktx2.Container.open(changed_first_frame[0..wire.len], .{}),
    );
    put(u32, &shared, 20, 1); // Only bit 1 is a defined BasisLZ image flag.
    try testing.expectError(error.InvalidKtx2, input.encodeInto(&output, .{}));
    put(u32, &shared, 20, 0);
    put(u32, &shared, 56, 0); // Paired DFD requires an alpha slice for every image.
    try testing.expectError(error.InvalidKtx2, input.encodeInto(&output, .{}));
    try testing.expectEqualSlices(u8, &before, &output);
}

test "KTX2 BasisLZ volume directory follows the shrinking depth of each mip" {
    var descriptor_storage: [60]u8 = undefined;
    const descriptor = try writeBasisLzDescriptor(&descriptor_storage, 163, false);
    var shared: [83]u8 = @splat(0);
    put(u16, &shared, 0, 1);
    put(u16, &shared, 2, 1);
    for ([_]usize{ 4, 8, 12 }) |field|
        put(u32, &shared, field, 1);
    for (0..3) |index| {
        put(u32, &shared, 24 + index * 20, if (index == 1) 1 else 0);
        put(u32, &shared, 28 + index * 20, 1);
    }
    const base = [_]u8{ 3, 4 };
    const smaller = [_]u8{5};
    const levels = [_]ktx2.Level{
        .{ .data = &base, .uncompressed_size = 0 },
        .{ .data = &smaller, .uncompressed_size = 0 },
    };
    const input: TextureInput = .{
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
        .supercompression_data = &shared,
    };
    const wire = try input.encode(testing.allocator, .{});
    defer testing.allocator.free(wire);
    const source = try ktx2.Container.open(wire, .{});
    const basis = source.basisLz().?;
    try testing.expectEqualSlices(u8, &.{3}, basis.image(0, 0, 0, 0).?.color);
    try testing.expectEqualSlices(u8, &.{4}, basis.image(0, 0, 0, 1).?.color);
    try testing.expectEqualSlices(u8, &.{5}, basis.image(1, 0, 0, 0).?.color);
    try testing.expectEqual(null, basis.image(1, 0, 0, 1));
    try testing.expectEqual(0, basis.image(0, 0, 0, 0).?.alpha.len);
    put(u32, &shared, 32, 1); // A one-sample DFD must have no alpha offset or length.
    var output: [512]u8 = @splat(0xa5);
    const before = output;
    try testing.expectError(error.InvalidKtx2, input.encodeInto(&output, .{}));
    try testing.expectEqualSlices(u8, &before, &output);
}

test "KTX2 global directory counts reject overflow before walking image records" {
    var descriptor_storage: [60]u8 = undefined;
    const descriptor = try writeBasisLzDescriptor(&descriptor_storage, 163, false);
    const levels: [32]ktx2.Level = @splat(.{ .data = &.{1}, .uncompressed_size = 0 });
    const shared: [20]u8 = @splat(0);
    const input: TextureInput = .{
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
        .supercompression_data = &shared,
    };
    const options: ktx2.Options = .{
        .limits = .{
            .maximum_extent = 0xffffffff,
            .maximum_layers = 0xffffffff,
            .maximum_image_slices = 0xffffffffffffffff,
        },
    };
    var output: [512]u8 = @splat(0xa5);
    const before = output;
    try testing.expectError(error.SizeOverflow, input.encodeInto(&output, options));
    try testing.expectEqualSlices(u8, &before, &output);
}

fn writeBasisLzDescriptor(storage: []u8, model: u8, alpha: bool) ![]const u8 {
    const samples = [_]KhronosDataFormatDescriptor.Sample{
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
    const descriptor: KhronosDataFormatDescriptor.BasicInput = .{
        .color_model = model,
        .block_extent = .{ 4, 4, 1, 1 },
        .bytes_plane = planes,
        .samples = samples[0..count],
    };
    return try descriptor.encodeInto(storage);
}

// Exact sizes and placement proved before either writer obtains or changes output storage.
const Layout = struct {
    /// Complete serialized byte count, including sections, level records and padding.
    size: usize,
    /// Serialized metadata bytes, including record lengths, key terminators and padding.
    metadata_size: usize,
    /// Absolute byte offset of BasisLZ global data; zero when absent.
    global_offset: usize,
    /// Byte alignment of each level's payload, including non-power-of-two block sizes.
    alignment: usize,
};

// Walk the intended file layout without writing it. Reader and writer share the admission rules;
// checked additions here also prove that serialization's offsets and destination spans will fit.
fn preflight(input: *const TextureInput, options: ktx2.Options) SizeError!Layout {
    const limits = options.limits;
    if (input.levels.len != input.header.levelCount()) return error.InvalidKtx2;
    if (input.levels.len > limits.maximum_levels or input.levels.len > 32)
        return error.LimitExceeded;
    if (input.descriptor.len > limits.maximum_descriptor_bytes) return error.LimitExceeded;
    if (input.metadata.len > limits.maximum_metadata_entries) return error.LimitExceeded;
    if (input.supercompression_data.len > limits.maximum_encoded_bytes) return error.LimitExceeded;
    const descriptor = try layout.openDescriptor(input.descriptor);
    try layout.validateHeader(input.header, descriptor, options);
    const needs_global = input.header.supercompression == .basis_lz;
    if (needs_global != (input.supercompression_data.len != 0)) return error.InvalidKtx2;
    var metadata_size: usize = 0;
    var previous: ?[]const u8 = null;
    var has_animation = false;
    for (input.metadata) |entry| {
        var size = try add(entry.key.len, 1);
        size = try add(size, entry.value.len);
        if (size > std.math.maxInt(u32)) return error.SizeOverflow;
        const padding = (4 - size % 4) % 4;
        metadata_size = try add(metadata_size, 4);
        metadata_size = try add(metadata_size, try add(size, padding));
        if (metadata_size > limits.maximum_metadata_bytes) return error.LimitExceeded;
        try layout.validateMetadataKey(entry, previous);
        if (layout.isAnimationHeader(entry)) has_animation = true;
        previous = entry.key;
    }
    const directory = try layout.BasisLzDirectory.open(
        input.header,
        descriptor,
        input.supercompression_data,
        has_animation,
        options.limits.maximum_image_slices,
    );
    var position = try add(80 + input.levels.len * 24, input.descriptor.len);
    position = try add(position, metadata_size);
    if (position > std.math.maxInt(u32)) return error.SizeOverflow;
    var global_offset: usize = 0;
    if (needs_global) {
        global_offset = try layout.alignForward(position, 8);
        position = try add(global_offset, input.supercompression_data.len);
    }
    if (position > limits.maximum_encoded_bytes) return error.LimitExceeded;
    const alignment = layout.levelAlignment(input.header, descriptor);
    var expanded: u64 = 0;
    var index = input.levels.len;
    while (index != 0) {
        index -= 1;
        const item = input.levels[index];
        try layout.validateLevel(
            input.header,
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
        position = try layout.alignForward(position, alignment);
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

fn rejectOverlap(input: *const TextureInput, output: []const u8) error{OverlappingStorage}!void {
    const spans = [_][]const u8{
        std.mem.asBytes(input),
        input.descriptor,
        std.mem.sliceAsBytes(input.levels),
        std.mem.sliceAsBytes(input.metadata),
        input.supercompression_data,
    };
    for (spans) |data| if (memory.overlaps(data, output)) return error.OverlappingStorage;
    for (
        input.levels,
    ) |item| if (memory.overlaps(item.data, output)) return error.OverlappingStorage;
    for (input.metadata) |entry| {
        if (memory.overlaps(
            entry.key,
            output,
        ) or memory.overlaps(entry.value, output)) return error.OverlappingStorage;
    }
}

fn add(first: usize, second: usize) ktx2.Error!usize {
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
    const source = try ktx2.Container.open(&fixtures.r8_mips, .{});
    const Span = enum { root, descriptor, levels, metadata, payload, key, value };
    for (std.enums.values(Span)) |span| {
        var arena: [1024]u8 align(16) = @splat(0xa5);
        var levels = [_]ktx2.Level{ source.level(0).?, source.level(1).? };
        var entries = [_]ktx2.Metadata.Entry{.{ .key = "a", .value = "b" }};
        var outer: ktx2.TextureInput = .{
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
                const records: *[1]ktx2.Metadata.Entry = @ptrCast(&arena);
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
        try testing.expectError(error.OverlappingStorage, texture.encodeInto(&arena, .{}));
        try testing.expectEqualSlices(u8, &before, &arena);
    }

    const basis = try ktx2.Container.open(&fixtures.etc1s, .{});
    const levels = [_]ktx2.Level{basis.level(0).?};
    var arena: [1024]u8 = @splat(0xa5);
    @memcpy(arena[0..basis.supercompression_data.len], basis.supercompression_data);
    const texture: ktx2.TextureInput = .{
        .header = basis.header,
        .descriptor = basis.descriptor.data,
        .levels = &levels,
        .supercompression_data = arena[0..basis.supercompression_data.len],
    };
    const before = arena;
    try testing.expectError(error.OverlappingStorage, texture.encodeInto(&arena, .{}));
    try testing.expectEqualSlices(u8, &before, &arena);
}

test "KTX2 writer permits inputs in spare output capacity and preserves them" {
    const source = try ktx2.Container.open(&fixtures.r8_mips, .{});
    var arena: [2048]u8 align(16) = @splat(0xa5);
    const levels: *[2]ktx2.Level = @ptrCast(@alignCast(arena[512..].ptr));
    const entries: *[1]ktx2.Metadata.Entry = @ptrCast(@alignCast(arena[768..].ptr));
    const texture: *ktx2.TextureInput = @ptrCast(@alignCast(arena[1024..].ptr));
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
    const wire = try texture.encodeInto(&arena, .{});
    try testing.expect(wire.len < 512);
    try testing.expectEqualSlices(u8, before[wire.len..], arena[wire.len..]);
    const result = try ktx2.Container.open(wire, .{});
    try testing.expectEqualSlices(u8, &.{ 23, 42 }, result.level(0).?.data);
    var metadata = result.metadata.iterator();
    try testing.expectEqualStrings("a", metadata.next().?.key);
    try testing.expectEqual(null, metadata.next());
}

test "KTX2 admission precedes allocation and capacity; OOM is retryable without a leak" {
    const source = try ktx2.Container.open(&fixtures.r8_mips, .{});
    const levels = [_]ktx2.Level{ source.level(0).?, source.level(1).? };
    var texture: ktx2.TextureInput = .{
        .header = source.header,
        .descriptor = source.descriptor.data,
        .levels = &levels,
    };
    var allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    texture.header.width = 0;
    try testing.expectError(error.InvalidKtx2, texture.encode(allocator.allocator(), .{}));
    var output: [256]u8 = @splat(0xa5);
    const before = output;
    try testing.expectError(error.InvalidKtx2, texture.encodeInto(output[0..1], .{}));
    try testing.expectEqual(0, allocator.allocations);
    try testing.expect(!allocator.has_induced_failure);

    texture.header.width = 2;
    try testing.expectError(error.OutOfMemory, texture.encode(allocator.allocator(), .{}));
    try testing.expect(allocator.has_induced_failure);
    try testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
    try testing.expectError(error.DestinationTooSmall, texture.encodeInto(output[0..1], .{}));
    try testing.expectEqualSlices(u8, &before, &output);

    allocator.fail_index = std.math.maxInt(usize);
    const owned = try texture.encode(allocator.allocator(), .{});
    try testing.expectEqualSlices(u8, &fixtures.r8_mips, owned);
    allocator.allocator().free(owned);
    try testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}

test "KTX2 serialized output survives retirement of every input record and payload" {
    const original = try ktx2.Container.open(&fixtures.r8_mips, .{});
    var descriptor: [44]u8 = original.descriptor.data[0..44].*;
    var data = [_]u8{ 23, 42, 17 };
    var levels = [_]ktx2.Level{
        .{ .data = data[0..2], .uncompressed_size = 2 },
        .{ .data = data[2..3], .uncompressed_size = 1 },
    };
    var key = [_]u8{'a'};
    var value = [_]u8{ 0, 255 };
    var entries = [_]ktx2.Metadata.Entry{.{ .key = &key, .value = &value }};
    var texture: ktx2.TextureInput = .{
        .header = original.header,
        .descriptor = &descriptor,
        .levels = &levels,
        .metadata = &entries,
    };
    const output = try texture.encode(testing.allocator, .{});
    defer testing.allocator.free(output);
    @memset(&descriptor, 0);
    @memset(&data, 0);
    @memset(&key, 0);
    @memset(&value, 0);
    @memset(std.mem.sliceAsBytes(&levels), 0);
    @memset(std.mem.sliceAsBytes(&entries), 0);
    @memset(std.mem.asBytes(&texture), 0);

    const source = try ktx2.Container.open(output, .{});
    // A borrowed view can be copied and the original object retired; it only borrows the file.
    const copied = source;
    try testing.expectEqualSlices(u8, &.{ 23, 42 }, copied.level(0).?.data);
    try testing.expectEqualSlices(u8, &.{17}, copied.level(1).?.data);
    var first = copied.metadata.iterator();
    var second = copied.metadata.iterator();
    const entry = first.next().?;
    try testing.expectEqualStrings("a", entry.key);
    try testing.expectEqualSlices(u8, &.{ 0, 255 }, entry.value);
    try testing.expectEqualStrings("a", second.next().?.key);
    try testing.expectEqual(null, first.next());
}

test "KTX2 RGB byte alignment uses lcm rather than a power-of-two rounding mask" {
    const samples = [_]KhronosDataFormatDescriptor.Sample{
        .{ .bit_offset = 0, .bit_length = 8, .channel_type = 0, .lower = 0, .upper = 255 },
        .{ .bit_offset = 8, .bit_length = 8, .channel_type = 1, .lower = 0, .upper = 255 },
        .{ .bit_offset = 16, .bit_length = 8, .channel_type = 2, .lower = 0, .upper = 255 },
    };
    const descriptor: KhronosDataFormatDescriptor.BasicInput = .{
        .color_model = 1,
        .bytes_plane = .{ 3, 0, 0, 0, 0, 0, 0, 0 },
        .samples = &samples,
    };
    var descriptor_bytes: [76]u8 = undefined;
    const levels = [_]ktx2.Level{
        .{ .data = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, .uncompressed_size = 9 },
        .{ .data = &.{ 10, 11, 12 }, .uncompressed_size = 3 },
    };
    const texture: ktx2.TextureInput = .{
        .header = .{ .vk_format = 23, .width = 3, .levels = 2 },
        .descriptor = try descriptor.encodeInto(&descriptor_bytes),
        .levels = &levels,
    };
    var output: [256]u8 = @splat(0xa5);
    const wire = try texture.encodeInto(&output, .{});
    try testing.expectEqual(225, wire.len);
    try testing.expectEqual(216, std.mem.readInt(u64, output[80..88], .little));
    try testing.expectEqual(204, std.mem.readInt(u64, output[104..112], .little));
    try testing.expectEqualSlices(u8, &@as([9]u8, @splat(0)), output[207..216]);
    const source = try ktx2.Container.open(wire, .{});
    try testing.expectEqualSlices(u8, levels[0].data, source.level(0).?.data);
    output[211] = 1;
    try testing.expectError(error.InvalidKtx2, ktx2.Container.open(wire, .{}));
}

test "KTX2 opaque supercompressed levels are framing rather than entropy validation" {
    for ([_]ktx2.Supercompression{ .zstandard, .zlib }) |scheme| {
        const original = try ktx2.Container.open(&fixtures.r8_mips, .{});
        var header = original.header;
        header.supercompression = scheme;
        const levels = [_]ktx2.Level{
            .{ .data = &.{0xff}, .uncompressed_size = 2 },
            .{ .data = &.{0xfe}, .uncompressed_size = 1 },
        };
        const texture: ktx2.TextureInput = .{
            .header = header,
            .descriptor = original.descriptor.data,
            .levels = &levels,
        };
        var output: [256]u8 = undefined;
        const wire = try texture.encodeInto(&output, .{});
        const source = try ktx2.Container.open(wire, .{});
        try testing.expectEqualSlices(u8, &.{0xff}, source.level(0).?.data);
        try testing.expectEqual(null, source.basisLz());
        for ([_]u32{ 4, 5, 6, 0xffffffff }) |reserved| {
            std.mem.writeInt(u32, output[44..48], reserved, .little);
            try testing.expectError(error.UnsupportedFormat, ktx2.Container.open(wire, .{}));
        }
    }
}

test "KTX2 reader and writer enforce caller budgets before publication and allocation" {
    const source = try ktx2.Container.open(&fixtures.etc1s, .{});
    const levels = [_]ktx2.Level{source.level(0).?};
    var iterator = source.metadata.iterator();
    const entries = [_]ktx2.Metadata.Entry{iterator.next().?};
    var texture: ktx2.TextureInput = .{
        .header = source.header,
        .descriptor = source.descriptor.data,
        .levels = &levels,
        .metadata = &entries,
        .supercompression_data = source.supercompression_data,
    };
    const refused = [_]ktx2.Options{
        .{ .limits = .{ .maximum_encoded_bytes = fixtures.etc1s.len - 1 } },
        .{ .limits = .{ .maximum_extent = 3 } },
        .{ .limits = .{ .maximum_levels = 0 } },
        .{ .limits = .{ .maximum_descriptor_bytes = 43 } },
        .{ .limits = .{ .maximum_metadata_bytes = source.metadata.data.len - 1 } },
        .{ .limits = .{ .maximum_metadata_entries = 0 } },
        .{ .limits = .{ .maximum_image_slices = 0 } },
    };
    var output: [512]u8 = @splat(0xa5);
    const before = output;
    var allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    for (refused) |options| {
        try testing.expectError(error.LimitExceeded, ktx2.Container.open(&fixtures.etc1s, options));
        try testing.expectError(error.LimitExceeded, texture.encodeInto(&output, options));
        try testing.expectError(
            error.LimitExceeded,
            texture.encode(allocator.allocator(), options),
        );
        try testing.expectEqualSlices(u8, &before, &output);
    }
    texture.header.layers = 1;
    const layer_limit: ktx2.Options = .{ .limits = .{ .maximum_layers = 0 } };
    try testing.expectError(error.LimitExceeded, texture.encodeInto(&output, layer_limit));
    try testing.expectEqualSlices(u8, &before, &output);

    const raw = try ktx2.Container.open(&fixtures.r8_mips, .{});
    const raw_levels = [_]ktx2.Level{ raw.level(0).?, raw.level(1).? };
    const raw_texture: ktx2.TextureInput = .{
        .header = raw.header,
        .descriptor = raw.descriptor.data,
        .levels = &raw_levels,
    };
    const expanded_limit: ktx2.Options = .{ .limits = .{ .maximum_uncompressed_bytes = 2 } };
    try testing.expectError(error.LimitExceeded, raw_texture.encodeInto(&output, expanded_limit));
    try testing.expectEqualSlices(u8, &before, &output);
    try testing.expect(!allocator.has_induced_failure);
    try testing.expectEqual(0, allocator.allocations);
}
