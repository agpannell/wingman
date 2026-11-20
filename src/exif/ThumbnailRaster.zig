//! A borrowed eight-bit RGB or YCbCr Exif thumbnail on its stored pixel grid. Opening admits every
//! strip, sample declaration and color equation without allocating. Keep the complete TIFF source
//! and returned state unchanged through the last sample read. Sampling applies no orientation or
//! profile transform. RGB supports chunky/planar strips; YCbCr supports chunky 4:2:2/4:2:0 strips.
//! Other compression, sample depths and photometric layouts are unsupported.
const std = @import("std");
const Metadata = @import("Metadata.zig");
const Directory = Metadata.Directory;
const Entry = Directory.Entry;
const YcbcrConverter = @import("YcbcrConverter.zig");
const YcbcrCalibration = @import("YcbcrCalibration.zig");
const raster_fixtures = @import("fixtures.zig").raster_fixtures;
const ThumbnailRaster = @This();

/// Complete borrowed TIFF bytes, unchanged through the last pixel read.
source: []const u8,
/// Byte order for directory values and strip references.
endian: std.builtin.Endian,
/// Nonzero stored pixel width, before orientation.
width: u32,
/// Nonzero stored pixel height, before orientation.
height: u32,
/// Declared rows in a complete strip; the last strip may be shorter.
rows_per_strip: u32,
/// RGB channels occupy separate strips when true.
planar: bool,
/// FillOrder 2 reverses bits within each stored byte.
reverse_bits: bool,
/// Number of strips in each RGB plane or the YCbCr interleaved raster.
strips_per_plane: usize,
/// Prechecked borrowed strip offsets; do not modify their source.
strip_offsets: EncodedStripTable,
/// Prechecked borrowed exact strip byte counts.
strip_byte_counts: EncodedStripTable,
/// Admitted conversion and rounding state, or null for direct RGB; preserve it after `open`.
ycbcr_converter: ?YcbcrConverter = null,

/// Malformed/unsupported metadata, exhausted structural allowance, invalid extent or size overflow.
pub const Error = Metadata.Error || error{ InvalidImageExtent, SizeOverflow };

pub const YcbcrReferenceDefaults = YcbcrCalibration.YcbcrReferenceDefaults;

/// Structural allowance for one thumbnail admission, independent of metadata-chain traversal.
pub const Limits = struct {
    /// Maximum directory header plus entries plus strip offset/count pairs checked by `open`.
    records: usize = 4096,
};

/// Admission policy for one borrowed thumbnail; source storage stays with the caller.
pub const OpenOptions = struct {
    /// Independent structural allowance for this raster admission.
    limits: Limits = .{},
    /// Interpretation used only when the source omits YCbCr ReferenceBlackWhite.
    ycbcr_reference_defaults: YcbcrReferenceDefaults = .full_range,
};

/// Admits the selected uncompressed directory and all referenced strips without allocating. Limits
/// count one directory header, each entry and each strip offset/count pair. Unsupported
/// declarations, malformed references and exhausted admission publish no view; the source remains
/// unchanged.
pub fn open(directory: Directory, options: OpenOptions) Error!ThumbnailRaster {
    const defaults = options.ycbcr_reference_defaults;
    const maximum_records = options.limits.records;
    const compression = (try directory.unsignedScalar(0x0103)) orelse return error.InvalidExif;
    if (compression != 1) return error.UnsupportedExif;
    const photometric = (try directory.unsignedScalar(0x0106)) orelse return error.InvalidExif;
    if (photometric != 2 and photometric != 6) return error.UnsupportedExif;
    const bits = (try directory.find(0x0102)) orelse return error.InvalidExif;
    if (!bits.isUnsigned() or bits.value_count != 3) return error.InvalidExif;
    for (0..3) |i| if (try bits.unsigned(i) != 8) return error.UnsupportedExif;
    const samples_per_pixel = (try directory.unsignedScalar(0x0115)) orelse 3;
    if (samples_per_pixel != 3) return error.UnsupportedExif;
    if (try directory.find(0x0153)) |sample_format| {
        if (!sample_format.isUnsigned() or (sample_format.value_count != 1 and sample_format
            .value_count != 3)) return error.InvalidExif;
        for (
            0..sample_format.value_count,
        ) |i| if (try sample_format.unsigned(i) != 1) return error.UnsupportedExif;
    }
    if (try directory.find(
        0x0152,
    )) |extras| if (extras.value_count != 0) return error.UnsupportedExif;
    const width = (try directory.unsignedScalar(0x0100)) orelse return error.InvalidExif;
    const height = (try directory.unsignedScalar(0x0101)) orelse return error.InvalidExif;
    if (width == 0 or height == 0) return error.InvalidImageExtent;
    const rows = (try directory.unsignedScalar(0x0116)) orelse return error.InvalidExif;
    if (rows == 0) return error.InvalidExif;
    const configuration = (try directory.unsignedScalar(0x011c)) orelse 1;
    if (configuration != 1 and configuration != 2) return error.UnsupportedExif;
    const fill_order = (try directory.unsignedScalar(0x010a)) orelse 1;
    if (fill_order != 1 and fill_order != 2) return error.UnsupportedExif;
    const ycbcr = if (photometric == 6) try YcbcrConverter.open(directory, defaults) else null;
    if (ycbcr) |color| {
        if (configuration != 1) return error.UnsupportedExif;
        if (rows < height and rows % color.vertical_subsampling != 0) return error.InvalidExif;
    }
    const offsets = (try directory.find(0x0111)) orelse return error.InvalidExif;
    const records = std.math.add(
        usize,
        @as(usize, directory.entry_count) + 1,
        offsets.value_count,
    ) catch return error.MetadataLimitExceeded;
    if (records > maximum_records) return error.MetadataLimitExceeded;
    const strips = try directory.strips();
    // Chunky storage has one strip sequence; planar RGB repeats it for each channel.
    const per_plane = (@as(usize, height) - 1) / rows + 1;
    const count = std.math.mul(
        usize,
        per_plane,
        if (configuration == 2) @as(usize, 3) else 1,
    ) catch return error.SizeOverflow;
    if (strips.offsets.value_count != count) return error.InvalidExif;
    const strip_offsets = try EncodedStripTable.open(strips.offsets);
    const strip_byte_counts = try EncodedStripTable.open(strips.byte_counts);
    for (0..count) |i| {
        const strip_y = (i % per_plane) * rows;
        const strip_rows = @min(rows, height - strip_y);
        const expected = if (ycbcr) |color| blk: {
            const columns = (@as(usize, width) - 1) / 2 + 1;
            const unit_rows = (strip_rows - 1) / color.vertical_subsampling + 1;
            const units = std.math.mul(usize, columns, unit_rows) catch return error.SizeOverflow;
            break :blk std.math.mul(
                usize,
                units,
                @as(usize, 2) * color.vertical_subsampling + 2,
            ) catch return error.SizeOverflow;
        } else blk: {
            const pixel_count = std.math.mul(
                usize,
                width,
                strip_rows,
            ) catch return error.SizeOverflow;
            const channels: usize = if (configuration == 1) 3 else 1;
            break :blk std.math.mul(usize, pixel_count, channels) catch return error.SizeOverflow;
        };
        if (strip_byte_counts.at(
            i,
            directory.metadata.endian,
        ) != expected) return error.InvalidExif;
    }
    return .{
        .source = directory.metadata.source,
        .endian = directory.metadata.endian,
        .width = width,
        .height = height,
        .rows_per_strip = rows,
        .planar = configuration == 2,
        .reverse_bits = fill_order == 2,
        .strips_per_plane = per_plane,
        .strip_offsets = strip_offsets,
        .strip_byte_counts = strip_byte_counts,
        .ycbcr_converter = ycbcr,
    };
}

test open {
    const bytes = [_]u8{
        0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x0e, 0x00, 0x00, 0x00, 0x0a, 0x00,
        0x00, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x01, 0x01, 0x04, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
        0x02, 0x01, 0x03, 0x00, 0x03, 0x00, 0x00, 0x00,
        0x8c, 0x00, 0x00, 0x00, 0x03, 0x01, 0x03, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x06, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x00, 0x11, 0x01, 0x04, 0x00,
        0x02, 0x00, 0x00, 0x00, 0x92, 0x00, 0x00, 0x00,
        0x15, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x16, 0x01, 0x04, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
        0x17, 0x01, 0x04, 0x00, 0x02, 0x00, 0x00, 0x00,
        0x9a, 0x00, 0x00, 0x00, 0x1c, 0x01, 0x03, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x08, 0x00,
        0x08, 0x00, 0xa2, 0x00, 0x00, 0x00, 0xb4, 0x00,
        0x00, 0x00, 0x12, 0x00, 0x00, 0x00, 0x09, 0x00,
        0x00, 0x00, 0x01, 0x14, 0xfa, 0x1e, 0xc8, 0x28,
        0x32, 0x3c, 0x46, 0x50, 0x5a, 0x64, 0x6e, 0x78,
        0x82, 0x8c, 0x96, 0xa0, 0xaa, 0xb4, 0xbe, 0xc8,
        0xd2, 0xdc, 0xe6, 0xf0, 0xff,
    };
    const view = try Metadata.open(&bytes, .{});
    const thumbnail = (try view.thumbnail()).?;
    const raster = try ThumbnailRaster.open(thumbnail.directory, .{});
    try std.testing.expectEqual(3, raster.width);
    try std.testing.expectEqual(3, raster.height);
    try std.testing.expectEqual([3]u8{ 1, 20, 250 }, raster.rgb(0, 0));
}

fn strip(self: ThumbnailRaster, index: usize) []const u8 {
    // Admission checked every table value and strip range. Pixel/chroma coordinates select one of
    // those strips while the complete source stays unchanged.
    const offset = self.strip_offsets.at(index, self.endian);
    const count = self.strip_byte_counts.at(index, self.endian);
    return self.source[offset..][0..count];
}

/// Returns one RGB8 pixel on the stored grid. YCbCr conversion clips final components to 0–255 and
/// rounds to the nearest code; an exact mathematical half may select either adjacent code.
/// Coordinates must satisfy x < width and y < height. Source storage must remain unchanged; no
/// allocation occurs. The returned array copies red, green and blue codes, in that order.
pub fn rgb(self: ThumbnailRaster, x: usize, y: usize) [3]u8 {
    std.debug.assert(x < self.width and y < self.height);
    if (self.ycbcr_converter) |color| {
        const columns = (@as(usize, self.width) - 1) / 2 + 1;
        const unit_size = @as(usize, 2) * color.vertical_subsampling + 2;
        const strip_bytes = self.strip(y / self.rows_per_strip);
        const unit = (y % self.rows_per_strip / color.vertical_subsampling * columns + x / 2) *
            unit_size;
        const luminance = self.decodeSampleByte(
            strip_bytes[unit + (y % color.vertical_subsampling) * 2 + x % 2],
        );
        const horizontal = ChromaInterpolation.forPixel(x, 2, columns, color.cosited);
        const vertical = ChromaInterpolation.forPixel(
            y,
            color.vertical_subsampling,
            (@as(usize, self.height) - 1) / color.vertical_subsampling + 1,
            color.cosited,
        );
        const top_left = self.chroma(horizontal.first, vertical.first, color);
        const top_right = self.chroma(horizontal.second, vertical.first, color);
        const bottom_left = self.chroma(horizontal.first, vertical.second, color);
        const bottom_right = self.chroma(horizontal.second, vertical.second, color);
        var chrominance: [2]f64 = undefined;
        for (&chrominance, 0..) |*value, channel| {
            const top = top_left[channel] * (1 - horizontal.weight) + top_right[channel] *
                horizontal.weight;
            const bottom = bottom_left[channel] * (1 - horizontal.weight) + bottom_right[channel] *
                horizontal.weight;
            value.* = top * (1 - vertical.weight) + bottom * vertical.weight;
        }
        return color.convert(luminance, chrominance, self.endian);
    }
    const index = y / self.rows_per_strip;
    const offset = (y % self.rows_per_strip) * self.width + x;
    const components: [3]u8 = if (!self.planar) self.strip(
        index,
    )[offset * 3 ..][0..3].* else .{
        self.strip(index)[offset],
        self.strip(index + self.strips_per_plane)[offset],
        self.strip(index + 2 * self.strips_per_plane)[offset],
    };
    return .{
        self.decodeSampleByte(components[0]),
        self.decodeSampleByte(components[1]),
        self.decodeSampleByte(components[2]),
    };
}

fn chroma(self: ThumbnailRaster, x: usize, y: usize, color: YcbcrConverter) [2]f64 {
    const pixel_y = y * color.vertical_subsampling;
    const columns = (@as(usize, self.width) - 1) / 2 + 1;
    const unit_size = @as(usize, 2) * color.vertical_subsampling + 2;
    const bytes = self.strip(pixel_y / self.rows_per_strip);
    const offset = (pixel_y % self.rows_per_strip / color.vertical_subsampling * columns + x) *
        unit_size + @as(
        usize,
        2,
    ) * color.vertical_subsampling;
    return .{
        @floatFromInt(self.decodeSampleByte(bytes[offset])),
        @floatFromInt(self.decodeSampleByte(bytes[offset + 1])),
    };
}

fn decodeSampleByte(self: ThumbnailRaster, value: u8) u8 {
    return if (self.reverse_bits) @bitReverse(value) else value;
}

// Borrowed unsigned strip offsets or byte counts; admitted once, then indexed during sampling.
const EncodedStripTable = struct {
    /// Borrowed array payload admitted by the directory's complete strip selection.
    bytes: []const u8,
    /// Unsigned element width from the stored TIFF type.
    format: enum { byte, short, long },

    fn open(entry: Entry) Entry.Error!EncodedStripTable {
        return .{ .bytes = try entry.data(), .format = switch (entry.field_type) {
            1 => .byte,
            3 => .short,
            4 => .long,
            else => return error.UnsupportedExif,
        } };
    }

    fn at(self: EncodedStripTable, index: usize, endian: std.builtin.Endian) u32 {
        return switch (self.format) {
            .byte => self.bytes[index],
            .short => std.mem.readInt(u16, self.bytes[index * 2 ..][0..2], endian),
            .long => std.mem.readInt(u32, self.bytes[index * 4 ..][0..4], endian),
        };
    }
};

// Pixel coordinates select two neighboring chroma samples and their interpolation weight.
const ChromaInterpolation = struct {
    /// Lower chroma sample index after clamping at the image edge.
    first: usize,
    /// Upper neighbor; equal to `first` at a clamped edge.
    second: usize,
    /// Fraction contributed by `second`; interpolation uses exact quarter-step weights.
    weight: f64,

    fn forPixel(pixel: usize, factor: u8, samples: usize, cosited: bool) ChromaInterpolation {
        const value = @as(f64, @floatFromInt(pixel));
        const spacing: f64 = @floatFromInt(factor);
        const coordinate = if (cosited) value / spacing else (value + 0.5) / spacing - 0.5;
        const clamped = std.math.clamp(coordinate, 0, @as(f64, @floatFromInt(samples - 1)));
        const first: usize = @intFromFloat(@floor(clamped));
        return .{
            .first = first,
            .second = @min(first + 1, samples - 1),
            .weight = clamped - @as(f64, @floatFromInt(first)),
        };
    }
};

test "Exif native thumbnail rasters retain independent RGB and YCbCr samples" {
    for (raster_fixtures) |control| {
        const view = try Metadata.open(control.wire, .{});
        const directory = if (try view.thumbnail()) |thumbnail| thumbnail.directory else try view
            .primary();
        const raster = try ThumbnailRaster.open(
            directory,
            .{ .ycbcr_reference_defaults = if (control.exif_default) .exif_2012 else .full_range },
        );
        try std.testing.expectEqual(control.rgb.len, @as(usize, raster.width) * raster.height * 3);
        for (0..raster.height) |y| for (0..raster.width) |x| {
            const expected = control.rgb[(y * raster.width + x) * 3 ..][0..3];
            const actual = raster.rgb(x, y);
            for (expected, actual) |want, got| {
                const difference: u16 = if (want > got) want - got else got - want;
                try std.testing.expect(difference <= control.maximum_difference);
            }
        };
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            ThumbnailRaster.open(directory, .{ .limits = .{ .records = 0 } }),
        );
    }
}

// TIFF 6.0 ReferenceBlackWhite stores unsigned rational endpoints. These independently authored
// 4:2:2 strips have Y codes 0/1 and neutral chroma. Y black=(2^32-3)/(2^32-2),
// white=(2^32-2)/(2^32-1): the positive exact span is 1/((2^32-2)*(2^32-1)), although both
// endpoints round to the same f64. Exact range expansion clips to black/white.
test "Exif distinct rational reference endpoints remain a valid color range" {
    const controls = [_][]const u8{
        &.{
            0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00,
            0x0e, 0x00, 0x00, 0x01, 0x04, 0x00, 0x01, 0x00,
            0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x01,
            0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
            0x00, 0x00, 0x02, 0x01, 0x03, 0x00, 0x03, 0x00,
            0x00, 0x00, 0xb6, 0x00, 0x00, 0x00, 0x03, 0x01,
            0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
            0x00, 0x00, 0x06, 0x01, 0x04, 0x00, 0x01, 0x00,
            0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x0a, 0x01,
            0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00,
            0x00, 0x00, 0x11, 0x01, 0x04, 0x00, 0x01, 0x00,
            0x00, 0x00, 0xf4, 0x00, 0x00, 0x00, 0x15, 0x01,
            0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x00,
            0x00, 0x00, 0x16, 0x01, 0x04, 0x00, 0x01, 0x00,
            0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x17, 0x01,
            0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00,
            0x00, 0x00, 0x1c, 0x01, 0x04, 0x00, 0x01, 0x00,
            0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x12, 0x02,
            0x04, 0x00, 0x02, 0x00, 0x00, 0x00, 0xbc, 0x00,
            0x00, 0x00, 0x13, 0x02, 0x04, 0x00, 0x01, 0x00,
            0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x14, 0x02,
            0x05, 0x00, 0x06, 0x00, 0x00, 0x00, 0xc4, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00,
            0x08, 0x00, 0x08, 0x00, 0x02, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0xfd, 0xff, 0xff, 0xff,
            0xfe, 0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x80, 0x80,
        },
        &.{
            0x4d, 0x4d, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08,
            0x00, 0x0e, 0x01, 0x00, 0x00, 0x04, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x01, 0x01,
            0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x01, 0x01, 0x02, 0x00, 0x03, 0x00, 0x00,
            0x00, 0x03, 0x00, 0x00, 0x00, 0xb6, 0x01, 0x03,
            0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x01, 0x01, 0x06, 0x00, 0x04, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x01, 0x0a,
            0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x01, 0x01, 0x11, 0x00, 0x04, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0xf4, 0x01, 0x15,
            0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x03, 0x01, 0x16, 0x00, 0x04, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x17,
            0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x04, 0x01, 0x1c, 0x00, 0x04, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x02, 0x12,
            0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00,
            0x00, 0xbc, 0x02, 0x13, 0x00, 0x04, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x02, 0x14,
            0x00, 0x05, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00,
            0x00, 0xc4, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08,
            0x00, 0x08, 0x00, 0x08, 0x00, 0x00, 0x00, 0x02,
            0x00, 0x00, 0x00, 0x01, 0xff, 0xff, 0xff, 0xfd,
            0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0xff, 0xfe,
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x80,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xff,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x80,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xff,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x80, 0x80,
        },
    };
    for (controls) |wire| {
        const selected = try (try Metadata.open(wire, .{})).primary();
        const image = try ThumbnailRaster.open(selected, .{});
        try std.testing.expectEqual([3]u8{ 0, 0, 0 }, image.rgb(0, 0));
        try std.testing.expectEqual([3]u8{ 255, 255, 255 }, image.rgb(1, 0));

        const references = try (try selected.find(0x0214)).?.data();
        const reference_offset = @intFromPtr(references.ptr) - @intFromPtr(wire.ptr);
        const invalid = try std.testing.allocator.dupe(u8, wire);
        defer std.testing.allocator.free(invalid);
        // Equal/reversed encoded endpoints also coincide in f64 and must still be refused.
        for ([_]u32{ 0xffff_fffd, 0xffff_fffc }) |numerator| {
            std.mem.writeInt(
                u32,
                invalid[reference_offset + 8 ..][0..4],
                numerator,
                selected.metadata.endian,
            );
            std.mem.writeInt(
                u32,
                invalid[reference_offset + 12 ..][0..4],
                numerator + 1,
                selected.metadata.endian,
            );
            const rejected = try (try Metadata.open(invalid, .{})).primary();
            try std.testing.expectError(error.InvalidExif, ThumbnailRaster.open(rejected, .{}));
        }
    }
}

test "Exif rational color terms retain exact cancellation" {
    // TIFF 6.0 pp87/91: with m=255000002, these references expand Y=1 to 255*m and Cr=0 to
    // -127*(m-2)*m. The red multiplier 2/254000000 cancels Y exactly. Blue and green exceed 255, so
    // the stored pixel is cyan, not white.
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var wire: [284]u8 = @splat(0);
        @memcpy(wire[0..2], if (endian == .little) "II" else "MM");
        std.mem.writeInt(u16, wire[2..4], 42, endian);
        std.mem.writeInt(u32, wire[4..8], 8, endian);
        std.mem.writeInt(u16, wire[8..10], 15, endian);
        const fields = [_]struct {
            tag: u16,
            kind: u16,
            count: u32 = 1,
            value: u32,
        }{
            .{ .tag = 0x0100, .kind = 4, .value = 2 },
            .{ .tag = 0x0101, .kind = 4, .value = 1 },
            .{ .tag = 0x0102, .kind = 3, .count = 3, .value = 194 },
            .{ .tag = 0x0103, .kind = 4, .value = 1 },
            .{ .tag = 0x0106, .kind = 4, .value = 6 },
            .{ .tag = 0x010a, .kind = 4, .value = 1 },
            .{ .tag = 0x0111, .kind = 4, .value = 280 },
            .{ .tag = 0x0115, .kind = 4, .value = 3 },
            .{ .tag = 0x0116, .kind = 4, .value = 1 },
            .{ .tag = 0x0117, .kind = 4, .value = 4 },
            .{ .tag = 0x011c, .kind = 4, .value = 1 },
            .{ .tag = 0x0211, .kind = 5, .count = 3, .value = 208 },
            .{ .tag = 0x0212, .kind = 4, .count = 2, .value = 200 },
            .{ .tag = 0x0213, .kind = 4, .value = 2 },
            .{ .tag = 0x0214, .kind = 5, .count = 6, .value = 232 },
        };
        for (fields, 0..) |field, index| {
            const entry = wire[10 + index * 12 ..][0..12];
            std.mem.writeInt(u16, entry[0..2], field.tag, endian);
            std.mem.writeInt(u16, entry[2..4], field.kind, endian);
            std.mem.writeInt(u32, entry[4..8], field.count, endian);
            std.mem.writeInt(u32, entry[8..12], field.value, endian);
        }
        for (0..3) |index|
            std.mem.writeInt(u16, wire[194 + index * 2 ..][0..2], 8, endian);
        const calibration = [_]u32{
            2,           1,           253_999_999, 254_000_000, 1,   254_000_000, 0,   1,
            255_000_000, 255_000_001, 255_000_001, 255_000_002, 128, 1,           255, 1,
            255_000_000, 255_000_001, 255_000_001, 255_000_002,
        };
        for (calibration, 0..) |value, index|
            std.mem.writeInt(u32, wire[200 + index * 4 ..][0..4], value, endian);
        wire[280..284].* = .{ 1, 1, 128, 0 };
        const selected = try (try Metadata.open(&wire, .{})).primary();
        const image = try ThumbnailRaster.open(selected, .{});
        try std.testing.expectEqual([3]u8{ 0, 255, 255 }, image.rgb(0, 0));
        try std.testing.expectEqual([3]u8{ 0, 255, 255 }, image.rgb(1, 0));

        // All three spans now have unit cross-product differences and maximum-width denominators.
        // These endpoint codes clip to white/black, while exercising the full wide-intermediate
        // bounds through the same public sampler on both 32-bit and 64-bit targets.
        const extreme_weights = [_]u32{ 0xfffffffe, 0xffffffff, 1, 0xffffffff, 0, 1 };
        for (extreme_weights, 0..) |value, index|
            std.mem.writeInt(u32, wire[208 + index * 4 ..][0..4], value, endian);
        for (0..3) |channel| {
            const reference: [4]u32 = .{ 0xfffffffd, 0xfffffffe, 0xfffffffe, 0xffffffff };
            for (reference, 0..) |value, index|
                std.mem.writeInt(u32, wire[232 + channel * 16 + index * 4 ..][0..4], value, endian);
        }
        for ([_]u8{ 0, 1 }) |code| {
            @memset(wire[280..284], code);
            const extreme = try ThumbnailRaster.open(
                try (try Metadata.open(&wire, .{})).primary(),
                .{},
            );
            const expected: [3]u8 = @splat(if (code == 0) 0 else 255);
            try std.testing.expectEqual(expected, extreme.rgb(0, 0));
            try std.testing.expectEqual(expected, extreme.rgb(1, 0));
        }
    }
}
