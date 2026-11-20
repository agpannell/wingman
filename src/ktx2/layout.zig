//! Shared KTX2 layout admission for Container and TextureInput. Header/descriptor relationships,
//! level sizes/alignment, metadata key rules and BasisLZ directory checks must agree in both paths.
//! Directory state is internal to this owner; public BasisLz values expose admitted queries
//! instead.
const std = @import("std");
const ktx2 = @import("../ktx2.zig");
const fixtures = @import("fixtures.zig");
const KhronosDataFormatDescriptor = @import("../common/KhronosDataFormatDescriptor.zig");

pub const identifier = [_]u8{
    0xab, 0x4b, 0x54, 0x58, 0x20, 0x32, 0x30, 0xbb,
    0x0d, 0x0a, 0x1a, 0x0a,
};

/// Opens the independent descriptor profile using the enclosing container's error vocabulary.
/// Descriptor byte limits are checked by the reader/writer before calling this adapter.
pub fn openDescriptor(data: []const u8) ktx2.Error!KhronosDataFormatDescriptor {
    return KhronosDataFormatDescriptor.open(data) catch |err| switch (err) {
        error.InvalidDescriptor => error.InvalidKtx2,
        error.UnsupportedDescriptor => error.UnsupportedFormat,
    };
}

test openDescriptor {
    var data = fixtures.r8_mips[128..172].*;
    const descriptor = try openDescriptor(&data);
    try std.testing.expectEqual(8, descriptor.sample(0).?.bit_length);
    data[0] = 43;
    try std.testing.expectError(error.InvalidKtx2, openDescriptor(&data));
    data[0] = 44;
    data[4] = 1;
    try std.testing.expectError(error.UnsupportedFormat, openDescriptor(&data));
    data[4] = 0;
    data[8] = 3;
    try std.testing.expectError(error.UnsupportedFormat, openDescriptor(&data));
    data[0] = 43;
    try std.testing.expectError(error.InvalidKtx2, openDescriptor(&data));
}

/// Checks topology and the supported descriptor/container relationship before section traversal.
pub fn validateHeader(
    value: ktx2.Header,
    descriptor: KhronosDataFormatDescriptor,
    options: ktx2.Options,
) ktx2.Error!void {
    const limits = options.limits;
    if (value.width == 0 or (value.height == 0 and value.depth != 0)) return error.InvalidKtx2;
    const dimensions = [_]u32{ value.width, value.height, value.depth };
    for (dimensions) |extent| if (extent > limits.maximum_extent) return error.LimitExceeded;
    if (value.layers > limits.maximum_layers or value.levelCount() > limits.maximum_levels) {
        return error.LimitExceeded;
    }
    if (value.faces != 1 and value.faces != 6) return error.InvalidKtx2;
    if (value.faces == 6 and (value.height != value.width or value.depth != 0))
        return error.InvalidKtx2;
    const available = 32 - @clz(@max(value.width, value.height, value.depth));
    if (value.levelCount() > available) return error.InvalidKtx2;
    switch (value.type_size) {
        1, 2, 4, 8 => {},
        else => return error.InvalidKtx2,
    }
    if (value.vk_format == 0 and value.type_size != 1) return error.InvalidKtx2;
    const compressed = descriptor.color_model >= 128;
    if (compressed and (value.height == 0 or value.levels == 0 or value.type_size != 1))
        return error.InvalidKtx2;
    if (descriptor.block_extent[2] > 1 and value.depth == 0) return error.InvalidKtx2;
    if (descriptor.block_extent[3] != 1) return error.UnsupportedFormat;
    // ETC1S describes RGB and optional alpha as two separate planes, carried as paired slices.
    const paired_planes = value.supercompression == .basis_lz and descriptor.color_model == 163;
    const first_unused_plane: usize = if (paired_planes) 2 else 1;
    for (
        descriptor.bytes_plane[first_unused_plane..],
    ) |bytes| if (bytes != 0) return error.UnsupportedFormat;

    const scheme = value.supercompression;
    if (scheme == .basis_lz and (descriptor.color_model != 163 or value.vk_format != 0))
        return error.InvalidKtx2;
    if (scheme == .none and descriptor.bytes_plane[0] == 0) return error.UnsupportedFormat;
}

/// Checks encoded/expanded declarations against the admitted header and descriptor, without
/// decoding.
pub fn validateLevel(
    value: ktx2.Header,
    descriptor: KhronosDataFormatDescriptor,
    index: u32,
    encoded: usize,
    expanded: u64,
) ktx2.Error!void {
    if (encoded == 0) return error.InvalidKtx2;
    switch (value.supercompression) {
        .basis_lz => {
            if (expanded != 0) return error.InvalidKtx2;
            return;
        },
        .none => if (encoded != expanded) return error.InvalidKtx2,
        .zstandard, .zlib => if (expanded == 0) return error.InvalidKtx2,
    }
    const images = @as(u64, @max(1, value.layers)) * value.faces;
    if (expanded % images != 0) return error.InvalidKtx2;
    const block_bytes = descriptor.bytes_plane[0];
    if (block_bytes == 0) return; // Variable-size/unknown decoded layout remains opaque.
    const shift: u5 = @intCast(index);
    const dimensions = [_]u32{ value.width, value.height, value.depth };
    var expected = images;
    for (dimensions, descriptor.block_extent[0..3], 0..) |dimension, extent, axis| {
        const pixels = @max(1, dimension >> shift);
        const logical_blocks = (@as(u64, pixels) - 1) / extent + 1;
        // PVRTC1 reconstruction needs a 2x2 neighborhood even for tiny mip levels.
        const stored_blocks = if (descriptor.color_model == 164 and axis < 2) @max(
            2,
            logical_blocks,
        ) else logical_blocks;
        expected = std.math.mul(u64, expected, stored_blocks) catch return error.SizeOverflow;
    }
    expected = std.math.mul(u64, expected, block_bytes) catch return error.SizeOverflow;
    if (expanded != expected) return error.InvalidKtx2;
}

pub fn levelAlignment(value: ktx2.Header, descriptor: KhronosDataFormatDescriptor) usize {
    if (value.supercompression != .none) return 1;
    const bytes: usize = descriptor.bytes_plane[0];
    // lcm(bytes, 4), including non-power-of-two RGB block sizes such as three bytes.
    if (bytes % 4 == 0) return bytes;
    return bytes * (if (bytes % 2 == 0) @as(usize, 2) else 4);
}

pub fn alignForward(position: usize, alignment: usize) ktx2.Error!usize {
    const padding = (alignment - position % alignment) % alignment;
    return std.math.add(usize, position, padding) catch error.SizeOverflow;
}

/// Enforces key syntax and strict order after the preceding admitted key; values remain opaque.
pub fn validateMetadataKey(
    entry: ktx2.Metadata.Entry,
    previous: ?[]const u8,
) error{InvalidKtx2}!void {
    if (entry.key.len == 0 or std.mem.indexOfScalar(
        u8,
        entry.key,
        0,
    ) != null or !std.unicode.utf8ValidateSlice(
        entry.key,
    ) or std.mem.startsWith(u8, entry.key, "\xef\xbb\xbf")) {
        return error.InvalidKtx2;
    }
    if (previous) |before| if (std.mem.order(
        u8,
        before,
        entry.key,
    ) != .lt) return error.InvalidKtx2;
}

/// Recognizes the header framing needed to admit BasisLZ animation flags; timing stays opaque.
pub fn isAnimationHeader(entry: ktx2.Metadata.Entry) bool {
    return std.mem.eql(u8, entry.key, "KTXanimData") and entry.value.len == 12;
}

// PVRTC1 requires at least two blocks along each image axis, unlike PVRTC2.
test "PVRTC1 minimum block grid and PVRTC2 ordinary grid" {
    var descriptor: KhronosDataFormatDescriptor = .{
        .data = &.{},
        .color_model = 164,
        .color_primaries = 0,
        .transfer_function = 0,
        .flags = 0,
        .block_extent = .{ 4, 4, 1, 1 },
        .bytes_plane = .{ 8, 0, 0, 0, 0, 0, 0, 0 },
        .sample_count = 0,
    };
    var texture_header: ktx2.Header = .{ .vk_format = 0, .width = 1, .height = 1 };
    try validateLevel(texture_header, descriptor, 0, 32, 32);
    try std.testing.expectError(
        error.InvalidKtx2,
        validateLevel(texture_header, descriptor, 0, 8, 8),
    );
    texture_header.width = 9;
    texture_header.height = 5;
    try validateLevel(texture_header, descriptor, 0, 48, 48);
    texture_header.width = 1;
    texture_header.height = 1;
    texture_header.supercompression = .zstandard;
    try validateLevel(texture_header, descriptor, 0, 4, 32);
    try std.testing.expectError(
        error.InvalidKtx2,
        validateLevel(texture_header, descriptor, 0, 4, 8),
    );
    descriptor.color_model = 165;
    texture_header.supercompression = .none;
    try validateLevel(texture_header, descriptor, 0, 8, 8);
    try std.testing.expectError(
        error.InvalidKtx2,
        validateLevel(texture_header, descriptor, 0, 32, 32),
    );
}

/// Verifies that the complete required padding exists and contains only zero bytes.
pub fn zeroPadding(data: []const u8, start: usize, end: usize) error{InvalidKtx2}!void {
    if (end > data.len) return error.InvalidKtx2;
    for (data[start..end]) |byte| if (byte != 0) return error.InvalidKtx2;
}

/// Internal reader/writer admission after header and descriptor topology checks. The global section
/// holds a fixed header, one image record per mip/layer/face/depth coordinate, then three
/// compressed shared tables. Topology determines record count; table lengths determine the rest.
/// Level validation checks slice ranges and flags without interpreting compressed payloads.
pub const BasisLzDirectory = struct {
    const Kind = enum { none, etc1s };

    /// Copied admitted topology used to locate each mip's image records.
    header: ktx2.Header,
    /// Whether this representation has an ETC1S directory or no global directory.
    kind: Kind,
    /// Borrowed image records; the shared compressed tables are outside this span.
    records: []const u8,
    /// Whether the descriptor requires an alpha slice alongside every color slice.
    has_alpha: bool,
    /// Whether a structurally recognized KTXanimData header permits animation flags.
    has_animation: bool,

    pub fn open(
        header: ktx2.Header,
        descriptor: KhronosDataFormatDescriptor,
        data: []const u8,
        has_animation: bool,
        maximum_images: u64,
    ) ktx2.Error!BasisLzDirectory {
        const kind = directoryKind(header);
        const result: BasisLzDirectory = .{
            .header = header,
            .kind = kind,
            .records = &.{},
            .has_alpha = descriptor.sample_count == 2,
            .has_animation = has_animation,
        };
        if (kind == .none) {
            if (data.len != 0) return error.InvalidKtx2;
            return result;
        }

        // Check the complete record count before converting to usize or traversing any records.
        var image_count: u64 = 0;
        for (0..header.levelCount()) |mip| {
            const count = try basisLzImageCount(header, @intCast(mip));
            image_count = std.math.add(u64, image_count, count) catch return error.SizeOverflow;
            if (image_count > maximum_images) return error.LimitExceeded;
        }
        const record_bytes = std.math.mul(u64, image_count, recordSize(kind)) catch {
            return error.SizeOverflow;
        };
        const offset: usize = 20;
        if (data.len < offset or record_bytes > data.len - offset) return error.InvalidKtx2;
        const end = offset + @as(usize, @intCast(record_bytes));
        var admitted = result;
        admitted.records = data[offset..end];
        if (descriptor.sample_count != 1 and descriptor.sample_count != 2) return error.InvalidKtx2;
        if (read(u16, data, 0) == 0 or read(u16, data, 2) == 0) return error.InvalidKtx2;
        var position = end;
        for ([_]usize{ 4, 8, 12 }) |field| {
            const size = read(u32, data, field);
            if (size == 0 or size > data.len - position) return error.InvalidKtx2;
            position += size;
        }
        // ETC1S has no extended data, and the global-data section has no trailing bytes.
        if (read(u32, data, 16) != 0 or position != data.len) return error.InvalidKtx2;
        return admitted;
    }

    /// Checks every image's color/alpha ranges and animation flags for one admitted mip.
    pub fn validateLevel(self: BasisLzDirectory, mip: u32, data: []const u8) ktx2.Error!void {
        if (self.kind == .none) return;
        const start = firstBasisLzImageIndex(self.header, mip);
        const count: usize = @intCast(try basisLzImageCount(self.header, mip));
        const depth = levelDepth(self.header, mip);
        for (0..count) |index| {
            const record = self.imageRecord(start + index);
            const offset: usize = 4;
            try validateSlice(data, read(u32, record, offset), read(u32, record, offset + 4));
            const flags = read(u32, record, 0);
            if (flags & ~@as(u32, 2) != 0) return error.InvalidKtx2;
            if (flags & 2 != 0) {
                const layer = index / (@as(usize, self.header.faces) * depth);
                // The KTX2 ETC1S bitstream appendix requires an I-frame at animation layer zero.
                // Actual prior-frame contents are a separate codec-state admission.
                if (!self.has_animation or self.header.layers == 0 or layer == 0)
                    return error.InvalidKtx2;
            }
            const alpha_offset = read(u32, record, 12);
            const alpha_size = read(u32, record, 16);
            if (self.has_alpha) {
                try validateSlice(data, alpha_offset, alpha_size);
            } else if (alpha_offset != 0 or alpha_size != 0) return error.InvalidKtx2;
        }
    }

    fn imageRecord(self: BasisLzDirectory, index: usize) []const u8 {
        const size = recordSize(self.kind);
        return self.records[index * size ..][0..size];
    }

    fn directoryKind(header: ktx2.Header) Kind {
        return if (header.supercompression == .basis_lz) .etc1s else .none;
    }

    fn recordSize(kind: Kind) usize {
        return if (kind == .etc1s) 20 else 0;
    }

    fn validateSlice(data: []const u8, offset: u32, size: u32) ktx2.Error!void {
        if (size == 0 or offset > data.len or size > data.len - offset) {
            return error.InvalidKtx2;
        }
    }

    fn read(comptime T: type, data: []const u8, offset: usize) T {
        return std.mem.readInt(T, data[offset..][0..@divExact(@bitSizeOf(T), 8)], .little);
    }
};

/// Absolute first image record for a mip in an already admitted BasisLZ directory.
pub fn firstBasisLzImageIndex(header: ktx2.Header, mip: u32) usize {
    var first: usize = 0;
    for (0..mip) |level| {
        first += @intCast(basisLzImageCount(header, @intCast(level)) catch unreachable);
    }
    return first;
}

/// Number of depth planes at an admitted mip; an absent depth axis contributes one plane.
pub fn levelDepth(header: ktx2.Header, mip: u32) u32 {
    return @max(1, header.depth >> @as(u5, @intCast(mip)));
}

/// Counts every layer, face and depth plane at one admitted mip using checked wide arithmetic.
pub fn basisLzImageCount(header: ktx2.Header, mip: u32) ktx2.Error!u64 {
    const planes = @as(u64, @max(1, header.layers)) * header.faces;
    return std.math.mul(u64, planes, levelDepth(header, mip)) catch error.SizeOverflow;
}
