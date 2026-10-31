//! Image directories and shared compressed tables stored in KTX2 supercompression global data.
//!
//! BasisLZ stores one RGB slice and an optional alpha slice per image, plus compressed tables
//! shared by the texture. Directory records follow mip, layer, face and depth order, independently
//! of the reversed mip storage. This owner checks directory framing and level-relative ranges. The
//! codec validates table contents, compressed slices and temporal dependencies.
//!
//! Reference: KTX 2.0 BasisLZ Global Data appendix.

const std = @import("std");
const types = @import("format.zig");
const dfd = @import("dfd.zig");

/// One image's borrowed encoded slices. The container checks their ranges, not their contents. Keep
/// the original file alive and unchanged through their final use.
pub const ImageSlice = struct {
    data: []const u8,
    /// Separate ETC1S alpha slice, empty for an opaque image.
    alpha: []const u8 = &.{},
    /// BasisLZ image flags: bit 1 marks a frame referring to the previous animation layer. Other
    /// values are reserved; codec state validates the actual reference.
    flags: u32 = 0,
};

/// Borrowed compressed ETC1S tables shared by all images in a BasisLZ texture. Counts describe
/// decoded entries; byte spans still contain compressed data and need codec validation.
pub const BasisLzGlobalData = struct {
    endpoint_count: u16,
    selector_count: u16,
    endpoints: []const u8,
    selectors: []const u8,
    tables: []const u8,
};

const Kind = enum { none, etc1s };

/// Internal reader/writer admission after header and descriptor topology checks.
pub const Directory = struct {
    header: types.Header,
    kind: Kind,
    records: []const u8,
    has_alpha: bool,
    has_animation: bool,

    pub fn open(
        header: types.Header,
        descriptor: dfd.DataFormatDescriptor,
        data: []const u8,
        has_animation: bool,
        maximum_images: u64,
    ) types.Error!Directory {
        const kind = directoryKind(header);
        const result: Directory = .{
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
            const count = try imageCount(header, @intCast(mip));
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

    pub fn validateLevel(self: Directory, mip: u32, data: []const u8) types.Error!void {
        if (self.kind == .none) return;
        const start = self.firstImage(mip);
        const count: usize = @intCast(try imageCount(self.header, mip));
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

    fn firstImage(self: Directory, mip: u32) usize {
        var first: usize = 0;
        for (0..mip) |level| {
            first += @intCast(imageCount(self.header, @intCast(level)) catch unreachable);
        }
        return first;
    }

    fn imageRecord(self: Directory, index: usize) []const u8 {
        const size = recordSize(self.kind);
        return self.records[index * size ..][0..size];
    }
};

/// Reads an already admitted directory; coordinates have been range checked by the caller.
pub fn imageSlice(
    header: types.Header,
    descriptor: dfd.DataFormatDescriptor,
    data: []const u8,
    level: []const u8,
    mip: u32,
    layer: u32,
    face: u32,
    depth: u32,
) ?ImageSlice {
    const kind = directoryKind(header);
    if (kind == .none) return null;
    const offset: usize = 20;
    const directory: Directory = .{
        .header = header,
        .kind = kind,
        .records = data[offset..],
        .has_alpha = descriptor.sample_count == 2,
        .has_animation = false,
    };
    const image = (@as(usize, layer) * header.faces + face) * levelDepth(header, mip) + depth;
    const record = directory.imageRecord(directory.firstImage(mip) + image);
    const color_offset: usize = 4;
    const start = read(u32, record, color_offset);
    const size = read(u32, record, color_offset + 4);
    var result: ImageSlice = .{ .data = level[start..][0..size] };
    if (kind == .etc1s) {
        result.flags = read(u32, record, 0);
        const alpha_offset = read(u32, record, 12);
        const alpha_size = read(u32, record, 16);
        result.alpha = level[alpha_offset..][0..alpha_size];
    }
    return result;
}

/// Reads shared tables from already admitted BasisLZ/ETC1S data.
pub fn codebooks(header: types.Header, data: []const u8) BasisLzGlobalData {
    var count: usize = 0;
    for (0..header.levelCount()) |mip| {
        count += @intCast(imageCount(header, @intCast(mip)) catch unreachable);
    }
    const position = 20 + count * 20;
    const endpoint_end = position + read(u32, data, 4);
    const selector_end = endpoint_end + read(u32, data, 8);
    const table_end = selector_end + read(u32, data, 12);
    return .{
        .endpoint_count = read(u16, data, 0),
        .selector_count = read(u16, data, 2),
        .endpoints = data[position..endpoint_end],
        .selectors = data[endpoint_end..selector_end],
        .tables = data[selector_end..table_end],
    };
}

pub fn levelDepth(header: types.Header, mip: u32) u32 {
    return @max(1, header.depth >> @as(u5, @intCast(mip)));
}

fn directoryKind(header: types.Header) Kind {
    return if (header.supercompression == .basis_lz) .etc1s else .none;
}

fn recordSize(kind: Kind) usize {
    return if (kind == .etc1s) 20 else 0;
}

fn imageCount(header: types.Header, mip: u32) types.Error!u64 {
    const planes = @as(u64, @max(1, header.layers)) * header.faces;
    return std.math.mul(u64, planes, levelDepth(header, mip)) catch error.SizeOverflow;
}

fn validateSlice(data: []const u8, offset: u32, size: u32) types.Error!void {
    if (size == 0 or offset > data.len or size > data.len - offset) {
        return error.InvalidKtx2;
    }
}

fn read(comptime T: type, data: []const u8, offset: usize) T {
    return std.mem.readInt(T, data[offset..][0..@divExact(@bitSizeOf(T), 8)], .little);
}
