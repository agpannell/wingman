//! Uncompressed thumbnail admission, RGB/YCbCr sampling and precision-preserving calibration.
const std = @import("std");
const tiff = @import("tiff.zig");
const Error = tiff.Error;
const View = tiff.View;
const Directory = tiff.Directory;
const Entry = tiff.Entry;
const raster_fixtures = @import("fixtures.zig").raster_fixtures;

/// Malformed or unsupported Exif raster, exceeded records, invalid extent or size overflow.
pub const ThumbnailRasterError = Error || error{ InvalidImageExtent, SizeOverflow };

/// Interpretation of absent YCbCr ReferenceBlackWhite values; no profile transform is applied.
pub const YcbcrDefaults = enum {
    /// Full-range TIFF/JFIF codes [0,255,128,255,128,255], used by common image readers.
    full_range,
    /// Codes [0,255,0,128,0,128] printed in CIPA DC-008-2012 section 4.6.5.2.
    exif_2012,
};

/// Directory header, entries and strip references, independent of the view's traversal allowance.
pub const ThumbnailRasterLimits = struct { records: usize = 4096 };

/// Admission for one borrowed uncompressed Exif thumbnail raster.
pub const ThumbnailRasterOptions = struct {
    /// Independent structural allowance for this raster admission.
    limits: ThumbnailRasterLimits = .{},
    /// Explicit interpretation when the source omits ReferenceBlackWhite.
    ycbcr_defaults: YcbcrDefaults = .full_range,
};

/// Borrowed eight-bit RGB or YCbCr Exif thumbnail raster. Opening validates every strip, sample
/// declaration and color equation before publication. Keep the complete TIFF source unchanged until
/// the last sample read. This view allocates nothing and applies no profile or orientation
/// transform. Other compression, sample depths and TIFF photometric layouts are unsupported. RGB
/// supports chunky/planar strips; YCbCr supports 4:2:2 and 4:2:0 chunky strips.
pub const ThumbnailRaster = struct {
    /// Complete borrowed TIFF bytes, unchanged through the last pixel read.
    source: []const u8,
    /// Byte order for directory values and strip references.
    endian: std.builtin.Endian,
    /// Nonzero stored pixel width, before orientation.
    width: u32,
    /// Nonzero stored pixel height, before orientation.
    height: u32,
    /// Declared rows in a complete strip; the last strip may be shorter.
    rows: u32,
    /// RGB channels occupy separate strips when true.
    planar: bool,
    /// FillOrder 2 reverses bits within each stored byte.
    reverse_bits: bool,
    /// Number of strips in each RGB plane or the YCbCr interleaved raster.
    strips_per_plane: usize,
    /// Prechecked borrowed strip offsets; do not modify their source.
    strip_offsets: StripValues,
    /// Prechecked borrowed exact strip byte counts.
    strip_counts: StripValues,
    /// Admitted YCbCr interpretation, or null for direct RGB.
    ycbcr: ?Ycbcr = null,

    /// Admits the selected uncompressed directory and all referenced strips without allocating.
    /// Limits count its directory header/entries and strip records. Unsupported declarations,
    /// malformed references and exhausted admission publish no view; the source remains unchanged.
    pub fn open(
        directory: Directory,
        options: ThumbnailRasterOptions,
    ) ThumbnailRasterError!ThumbnailRaster {
        const defaults = options.ycbcr_defaults;
        const maximum_records = options.limits.records;
        if (try scalar(directory, 0x0103, null) != 1) return error.UnsupportedExif;
        const photometric = try scalar(directory, 0x0106, null);
        if (photometric != 2 and photometric != 6) return error.UnsupportedExif;
        const bits = (try directory.find(0x0102)) orelse return error.InvalidExif;
        if (!bits.isUnsigned() or bits.count != 3) return error.InvalidExif;
        for (0..3) |i| if (try bits.unsigned(i) != 8) return error.UnsupportedExif;
        if (try scalar(directory, 0x0115, 3) != 3) return error.UnsupportedExif;
        if (try directory.find(0x0153)) |sample_format| {
            if (!sample_format.isUnsigned() or (sample_format.count != 1 and sample_format.count !=
                3)) return error.InvalidExif;
            for (
                0..sample_format.count,
            ) |i| if (try sample_format.unsigned(i) != 1) return error.UnsupportedExif;
        }
        if (try directory.find(
            0x0152,
        )) |extras| if (extras.count != 0) return error.UnsupportedExif;
        const width = try scalar(directory, 0x0100, null);
        const height = try scalar(directory, 0x0101, null);
        if (width == 0 or height == 0) return error.InvalidImageExtent;
        const rows = try scalar(directory, 0x0116, null);
        if (rows == 0) return error.InvalidExif;
        const configuration = try scalar(directory, 0x011c, 1);
        if (configuration != 1 and configuration != 2) return error.UnsupportedExif;
        const fill_order = try scalar(directory, 0x010a, 1);
        if (fill_order != 1 and fill_order != 2) return error.UnsupportedExif;
        const ycbcr = if (photometric == 6) try Ycbcr.open(directory, defaults) else null;
        if (ycbcr) |color| {
            if (configuration != 1) return error.UnsupportedExif;
            if (rows < height and rows % color.vertical != 0) return error.InvalidExif;
        }
        const offsets = (try directory.find(0x0111)) orelse return error.InvalidExif;
        const records = std.math.add(
            usize,
            @as(usize, directory.count) + 1,
            offsets.count,
        ) catch return error.MetadataLimitExceeded;
        if (records > maximum_records) return error.MetadataLimitExceeded;
        const strips = try directory.strips();
        const per_plane = (@as(usize, height) - 1) / rows + 1;
        const count = std.math.mul(
            usize,
            per_plane,
            if (configuration == 2) @as(usize, 3) else 1,
        ) catch return error.SizeOverflow;
        if (strips.offsets.count != count) return error.InvalidExif;
        const strip_offsets = try StripValues.open(strips.offsets);
        const strip_counts = try StripValues.open(strips.counts);
        for (0..count) |i| {
            const strip_y = (i % per_plane) * rows;
            const strip_rows = @min(rows, height - strip_y);
            const expected = if (ycbcr) |color| blk: {
                const columns = (@as(usize, width) - 1) / 2 + 1;
                const unit_rows = (strip_rows - 1) / color.vertical + 1;
                const units = std.math.mul(
                    usize,
                    columns,
                    unit_rows,
                ) catch return error.SizeOverflow;
                break :blk std.math.mul(
                    usize,
                    units,
                    @as(usize, 2) * color.vertical + 2,
                ) catch return error.SizeOverflow;
            } else blk: {
                const pixel_count = std.math.mul(
                    usize,
                    width,
                    strip_rows,
                ) catch return error.SizeOverflow;
                const channels: usize = if (configuration == 1) 3 else 1;
                break :blk std.math.mul(
                    usize,
                    pixel_count,
                    channels,
                ) catch return error.SizeOverflow;
            };
            if (strip_counts.at(i, directory.view.endian) != expected) return error.InvalidExif;
        }
        return .{
            .source = directory.view.source,
            .endian = directory.view.endian,
            .width = width,
            .height = height,
            .rows = rows,
            .planar = configuration == 2,
            .reverse_bits = fill_order == 2,
            .strips_per_plane = per_plane,
            .strip_offsets = strip_offsets,
            .strip_counts = strip_counts,
            .ycbcr = ycbcr,
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
        const view = try View.open(&bytes, .{});
        const thumbnail = (try view.thumbnail()).?;
        const raster = try ThumbnailRaster.open(thumbnail.directory, .{});
        try std.testing.expectEqual(3, raster.width);
        try std.testing.expectEqual(3, raster.height);
        try std.testing.expectEqual([3]u8{ 1, 20, 250 }, raster.rgb(0, 0));
    }

    fn strip(self: ThumbnailRaster, index: usize) []const u8 {
        // Admission checked every table value and strip range. Pixel/chroma coordinates select one
        // of those strips while the complete source stays unchanged.
        const offset = self.strip_offsets.at(index, self.endian);
        const count = self.strip_counts.at(index, self.endian);
        return self.source[offset..][0..count];
    }

    /// Returns one RGB8 pixel on the stored grid. YCbCr conversion clips final components to 0–255
    /// and rounds to the nearest code; an exact mathematical half may select either adjacent code.
    /// Coordinates must satisfy x < width and y < height. Source storage must remain unchanged; no
    /// allocation or fallible work occurs.
    pub fn rgb(self: ThumbnailRaster, x: usize, y: usize) [3]u8 {
        std.debug.assert(x < self.width and y < self.height);
        if (self.ycbcr) |color| {
            const columns = (@as(usize, self.width) - 1) / 2 + 1;
            const unit_size = @as(usize, 2) * color.vertical + 2;
            const strip_bytes = self.strip(y / self.rows);
            const unit = (y % self.rows / color.vertical * columns + x / 2) * unit_size;
            const luminance = self.sampleByte(strip_bytes[unit + (y % color.vertical) * 2 + x % 2]);
            const horizontal = Axis.at(x, 2, columns, color.cosited);
            const vertical = Axis.at(
                y,
                color.vertical,
                (@as(usize, self.height) - 1) / color.vertical + 1,
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
                const bottom = bottom_left[channel] * (1 - horizontal.weight) +
                    bottom_right[channel] * horizontal.weight;
                value.* = top * (1 - vertical.weight) + bottom * vertical.weight;
            }
            return color.rgb(luminance, chrominance, self.endian);
        }
        const index = y / self.rows;
        const offset = (y % self.rows) * self.width + x;
        const components: [3]u8 = if (!self.planar) self.strip(
            index,
        )[offset * 3 ..][0..3].* else .{
            self.strip(index)[offset],
            self.strip(index + self.strips_per_plane)[offset],
            self.strip(index + 2 * self.strips_per_plane)[offset],
        };
        return .{
            self.sampleByte(components[0]),
            self.sampleByte(components[1]),
            self.sampleByte(components[2]),
        };
    }

    fn chroma(self: ThumbnailRaster, x: usize, y: usize, color: Ycbcr) [2]f64 {
        const pixel_y = y * color.vertical;
        const columns = (@as(usize, self.width) - 1) / 2 + 1;
        const unit_size = @as(usize, 2) * color.vertical + 2;
        const bytes = self.strip(pixel_y / self.rows);
        const offset = (pixel_y % self.rows / color.vertical * columns + x) * unit_size + @as(
            usize,
            2,
        ) * color.vertical;
        return .{
            @floatFromInt(self.sampleByte(bytes[offset])),
            @floatFromInt(self.sampleByte(bytes[offset + 1])),
        };
    }

    fn sampleByte(self: ThumbnailRaster, value: u8) u8 {
        return if (self.reverse_bits) @bitReverse(value) else value;
    }
};

// Borrows one admitted unsigned table. Element indices are bounded by the checked strip count; this
// private view avoids repeating field-payload admission per pixel.
const StripValues = struct {
    bytes: []const u8,
    format: enum { byte, short, long },

    fn open(entry: Entry) ThumbnailRasterError!StripValues {
        return .{ .bytes = try entry.data(), .format = switch (entry.field_type) {
            1 => .byte,
            3 => .short,
            4 => .long,
            else => return error.UnsupportedExif,
        } };
    }

    fn at(self: StripValues, index: usize, endian: std.builtin.Endian) u32 {
        return switch (self.format) {
            .byte => self.bytes[index],
            .short => std.mem.readInt(u16, self.bytes[index * 2 ..][0..2], endian),
            .long => std.mem.readInt(u32, self.bytes[index * 4 ..][0..4], endian),
        };
    }
};

const Axis = struct {
    first: usize,
    second: usize,
    weight: f64,

    fn at(pixel: usize, factor: u8, samples: usize, cosited: bool) Axis {
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

// ReferenceBlackWhite expands stored codes to luminance and chroma; the inverse matrix combines
// them into RGB. Narrow rational spans can produce huge terms that cancel to a small component.
// Admission bounds float error and certifies ordinary calibration against its rational output grid.
// Other calibration checks each pixel's rounding interval and uses the encoded rationals when float
// uncertainty could change a code. Only the final RGB result is clipped.
const Ycbcr = struct {
    vertical: u8,
    cosited: bool,
    guard_rounding: bool = undefined,
    coefficients: [3]f64,
    references: [3]ColorReference,
    calibration: ColorCalibration,
    errors: [3]f64 = undefined,

    fn open(directory: Directory, defaults: YcbcrDefaults) ThumbnailRasterError!Ycbcr {
        var result: Ycbcr = .{ .vertical = 2, .cosited = false, .coefficients = .{
            0.299, 0.587, 0.114,
        }, .calibration = .{ .defaults = defaults }, .references = switch (defaults) {
            .full_range => .{
                .{ .black = 0, .span = 255 },
                .{ .black = 128, .span = 127 },
                .{ .black = 128, .span = 127 },
            },
            .exif_2012 => .{
                .{ .black = 0, .span = 255 },
                .{ .black = 0, .span = 128 },
                .{ .black = 0, .span = 128 },
            },
        } };
        if (try directory.find(0x0212)) |sampling| {
            if (!sampling.isUnsigned() or sampling.count != 2) return error.InvalidExif;
            const horizontal = try sampling.unsigned(0);
            const vertical = try sampling.unsigned(1);
            if (horizontal != 2 or (vertical != 1 and vertical != 2)) return error.UnsupportedExif;
            result.vertical = @intCast(vertical);
        }
        const positioning = try scalar(directory, 0x0213, 1);
        if (positioning != 1 and positioning != 2) return error.UnsupportedExif;
        result.cosited = positioning == 2;
        if (try directory.find(0x0211)) |coefficients| {
            if (coefficients.count != 3) return error.InvalidExif;
            for (&result.coefficients, 0..) |*value, i| {
                value.* = (try rational(coefficients, i)).value();
            }
            result.calibration.coefficients = (try coefficients.data())[0..24];
        }
        const c = result.coefficients;
        // TIFF's inverse matrix divides only by green. Unsigned rationals already exclude negative
        // weights; zero red/blue weights keep the matrix invertible.
        if (c[1] <= 0 or @abs(c[0] + c[1] + c[2] - 1) > 0.00001) return error.InvalidExif;
        if (try directory.find(0x0214)) |references| {
            if (references.count != 6) return error.InvalidExif;
            for (&result.references, 0..) |*reference, i| {
                reference.* = try ColorReference.init(
                    try rational(references, i * 2),
                    try rational(references, i * 2 + 1),
                );
            }
            result.calibration.references = (try references.data())[0..48];
        }
        result.errors = result.errorBounds(directory.view.endian);
        result.guard_rounding = result.calibration.needsGuard(directory.view.endian, result.errors);
        return result;
    }

    fn rgb(self: Ycbcr, y: u8, chroma: [2]f64, endian: std.builtin.Endian) [3]u8 {
        // Admitted unsigned rationals bound these coefficients and positive reference spans. Byte
        // luminance and interpolated byte chroma keep the inverse finite in f64.
        const references = self.references;
        const luminance = (@as(
            f64,
            @floatFromInt(y),
        ) - references[0].black) * 255 / references[0].span;
        const cb = (chroma[0] - references[1].black) * 127 / references[1].span;
        const cr = (chroma[1] - references[2].black) * 127 / references[2].span;
        const red = luminance + (2 - 2 * self.coefficients[0]) * cr;
        const blue = luminance + (2 - 2 * self.coefficients[2]) * cb;
        const green = (luminance - self.coefficients[0] * red - self.coefficients[2] * blue) / self
            .coefficients[1];
        const values = [3]f64{ red, green, blue };
        if (self.guard_rounding) {
            @branchHint(.unlikely);
            return self.roundGuarded(y, chroma, endian, values);
        }
        return .{
            @intFromFloat(rounded(red)),
            @intFromFloat(rounded(green)),
            @intFromFloat(rounded(blue)),
        };
    }

    noinline fn roundGuarded(
        self: Ycbcr,
        y: u8,
        chroma: [2]f64,
        endian: std.builtin.Endian,
        values: [3]f64,
    ) [3]u8 {
        const red, const green, const blue = values;
        const codes = [3]f64{ rounded(red), rounded(green), rounded(blue) };
        var uncertain = false;
        for (values, codes, self.errors) |value, code, uncertainty| {
            const lower = code - 0.5;
            const upper = code + 0.5;
            if ((code != 0 and value - uncertainty <= lower) or (code != 255 and value +
                uncertainty >= upper))
            {
                uncertain = true;
                break;
            }
        }
        const pixel = [3]u8{
            @intFromFloat(codes[0]),
            @intFromFloat(codes[1]),
            @intFromFloat(codes[2]),
        };
        if (uncertain) {
            @branchHint(.unlikely);
            return self.calibration.rgbExact(y, chroma, endian, pixel);
        }
        return pixel;
    }

    // Bound the absolute error of the existing floating-point expression over all byte inputs.
    // Chroma interpolation is exact: 4:2:2/4:2:0 positioning gives multiples of 1/16. Only rational
    // conversion and the inverse color expression contribute rounding. A pixel whose uncertainty
    // crosses a quantization boundary uses the encoded rationals instead of losing cancellation.
    fn errorBounds(self: Ycbcr, endian: std.builtin.Endian) [3]f64 {
        const raw = self.calibration.values(endian);
        var expanded: [3]ColorError = undefined;
        for (&expanded, self.references, 0..) |*bound, reference, i| {
            const black = raw.references[i * 2];
            const white = raw.references[i * 2 + 1];
            const difference = @as(
                u64,
                white.numerator,
            ) * black.denominator - @as(u64, black.numerator) * white.denominator;
            const exact_span = @as(
                f64,
                @floatFromInt(difference),
            ) / @as(f64, @floatFromInt(@as(u64, black.denominator) * white.denominator));
            // Integer endpoints and their subtraction are exact. Otherwise compare with an
            // independently converted exact span, accounting for both integer conversions/division.
            const span_error = if (black.denominator == 1 and white.denominator == 1) 0 else 2 *
                (@abs(
                    reference.span - exact_span,
                ) + ColorError.slack * exact_span);
            const black_error: ColorError = .{
                .magnitude = reference.black,
                .error_bound = if (black.denominator == 1) 0 else ColorError.slack * reference
                    .black,
            };
            bound.* = (ColorError{
                .magnitude = 255,
            }).add(
                black_error,
            ).multiply(
                .{ .magnitude = if (i == 0) 255 else 127 },
            ).divide(reference.span, exact_span * 0.5, span_error);
        }
        var weights: [3]ColorError = undefined;
        for (&weights, self.coefficients, raw.coefficients) |*bound, value, encoded| {
            bound.* = .{
                .magnitude = value,
                .error_bound = if (encoded.denominator == 1) 0 else ColorError.slack * value,
            };
        }
        const two: ColorError = .{ .magnitude = 2 };
        // Addition also bounds subtraction, so these magnitude bounds deliberately add every term
        // even where the actual matrix subtracts it. Cancellation cannot hide rounding error.
        const red = expanded[0].add(two.add(two.multiply(weights[0])).multiply(expanded[2]));
        const blue = expanded[0].add(two.add(two.multiply(weights[2])).multiply(expanded[1]));
        const green = expanded[0].add(
            weights[0].multiply(red),
        ).add(
            weights[2].multiply(blue),
        ).divide(self.coefficients[1], self.coefficients[1] * 0.5, weights[1].error_bound);
        return .{ red.error_bound, green.error_bound, blue.error_bound };
    }
};

// Forward absolute-error bounds for the color expression, computed once during admission.
// Magnitudes bound computed operands; errors compare them with exact operands. Slack is twice
// binary64's unit roundoff. Positive bound operations round outward explicitly. Values are normal
// and finite: u32 components, spans above 2^-65 and green above 2^-33 keep even conservative
// intermediate bounds below 2^256, far inside binary64's exponent range.
const ColorError = struct {
    magnitude: f64,
    error_bound: f64 = 0,

    const slack = 0x1p-52;

    fn up(value: f64) f64 {
        return if (value == 0) 0 else std.math.nextAfter(f64, value, std.math.inf(f64));
    }

    // Addition and subtraction have the same absolute bounds.
    fn add(a: ColorError, b: ColorError) ColorError {
        const magnitude = up(a.magnitude + b.magnitude);
        return .{
            .magnitude = magnitude,
            .error_bound = up(up(a.error_bound + b.error_bound) + up(slack * magnitude)),
        };
    }

    fn multiply(a: ColorError, b: ColorError) ColorError {
        const magnitude = up(a.magnitude * b.magnitude);
        return .{
            .magnitude = magnitude,
            .error_bound = up(
                up(
                    up(
                        up(a.magnitude * b.error_bound) + up(b.magnitude * a.error_bound),
                    ) + up(a.error_bound * b.error_bound),
                ) + up(slack * magnitude),
            ),
        };
    }

    // The divisor is a known positive float; minimum bounds its exact encoded value from below.
    fn divide(a: ColorError, divisor: f64, minimum: f64, divisor_error: f64) ColorError {
        const magnitude = up(a.magnitude / divisor);
        const denominator = std.math.nextAfter(f64, divisor * minimum, 0);
        return .{
            .magnitude = magnitude,
            .error_bound = up(
                up(
                    up(
                        a.error_bound / divisor,
                    ) + up(up(up(a.magnitude + a.error_bound) * divisor_error) / denominator),
                ) + up(slack * magnitude),
            ),
        };
    }
};

// Raw calibration borrows the already admitted fields. Keeping it alongside the float projection
// preserves the information required by cancellation without enlarging every stored rational.
const ColorCalibration = struct {
    coefficients: ?*const [24]u8 = null,
    references: ?*const [48]u8 = null,
    defaults: YcbcrDefaults,

    const Values = struct { coefficients: [3]Rational, references: [6]Rational };

    fn values(self: ColorCalibration, endian: std.builtin.Endian) Values {
        var result: Values = .{
            .coefficients = .{
                .{ .numerator = 299, .denominator = 1000 },
                .{ .numerator = 587, .denominator = 1000 },
                .{ .numerator = 114, .denominator = 1000 },
            },
            .references = undefined,
        };
        const references = switch (self.defaults) {
            .full_range => [6]u32{ 0, 255, 128, 255, 128, 255 },
            .exif_2012 => [6]u32{ 0, 255, 0, 128, 0, 128 },
        };
        for (
            &result.references,
            references,
        ) |*destination, value| destination.* = .{ .numerator = value, .denominator = 1 };
        if (self.coefficients) |bytes| read(&result.coefficients, bytes, endian);
        if (self.references) |bytes| read(&result.references, bytes, endian);
        return result;
    }

    fn read(destination: []Rational, bytes: []const u8, endian: std.builtin.Endian) void {
        for (
            destination,
            0..,
        ) |*value, i| value.* = .{
            .numerator = std.mem.readInt(u32, bytes[i * 8 ..][0..4], endian),
            .denominator = std.mem.readInt(u32, bytes[i * 8 + 4 ..][0..4], endian),
        };
    }

    // Every exact output is an integer multiple of 1/D for a fixed calibration. Unless exactly on a
    // rounding half, its distance from that half is at least 1/(2D). A smaller float error makes
    // all non-ties round identically; exact ties retain the existing adjacent result. Certify
    // ordinary calibration once so it does not need a per-pixel uncertainty check.
    fn needsGuard(self: ColorCalibration, endian: std.builtin.Endian, errors: [3]f64) bool {
        const raw = self.values(endian);
        var grids: [3]u128 = undefined;
        for (&grids, 0..) |*grid, i| {
            const black = raw.references[i * 2];
            const white = raw.references[i * 2 + 1];
            const denominator = 16 * (@as(
                u128,
                white.numerator,
            ) * black.denominator - @as(u128, black.numerator) * white.denominator);
            const variable = @as(
                u128,
                black.denominator,
            ) * @as(u128, if (i == 0) 255 else 127) * white.denominator;
            const constant = @as(
                u128,
                16,
            ) * black.numerator * @as(u128, if (i == 0) 255 else 127) * white.denominator;
            grid.* = denominator / std.math.gcd(denominator, std.math.gcd(variable, constant));
        }
        const r = raw.coefficients[0];
        const g = raw.coefficients[1];
        const b = raw.coefficients[2];
        const red_denominator = reducedDenominator(
            2 * (@as(i128, r.denominator) - r.numerator),
            r.denominator,
        );
        const blue_denominator = reducedDenominator(
            2 * (@as(i128, b.denominator) - b.numerator),
            b.denominator,
        );
        const green_y = reducedDenominator(
            (@as(
                i128,
                r.denominator,
            ) * b.denominator - @as(
                i128,
                r.numerator,
            ) * b.denominator - @as(i128, b.numerator) * r.denominator) * g.denominator,
            @as(u128, r.denominator) * b.denominator * g.numerator,
        );
        const green_cr = reducedDenominator(
            -2 * @as(i128, r.numerator) * (@as(i128, r.denominator) - r.numerator) * g.denominator,
            @as(u128, r.denominator) * r.denominator * g.numerator,
        );
        const green_cb = reducedDenominator(
            -2 * @as(i128, b.numerator) * (@as(i128, b.denominator) - b.numerator) * g.denominator,
            @as(u128, b.denominator) * b.denominator * g.numerator,
        );
        var output_grids = [3]u64{ 1, 1, 1 };
        if (!combineGrid(
            &output_grids[0],
            grids[0],
            1,
        ) or !combineGrid(
            &output_grids[0],
            grids[2],
            red_denominator,
        ) or !combineGrid(
            &output_grids[2],
            grids[0],
            1,
        ) or !combineGrid(
            &output_grids[2],
            grids[1],
            blue_denominator,
        ) or !combineGrid(
            &output_grids[1],
            grids[0],
            green_y,
        ) or !combineGrid(
            &output_grids[1],
            grids[2],
            green_cr,
        ) or !combineGrid(&output_grids[1], grids[1], green_cb)) return true;
        for (output_grids, errors) |grid, uncertainty| {
            // Half the minimum distance leaves strict headroom for the final float conversions.
            if (uncertainty >= 0.25 / @as(f64, @floatFromInt(grid))) return true;
        }
        return false;
    }

    fn reducedDenominator(numerator: i128, denominator: u128) u128 {
        return denominator / std.math.gcd(@abs(numerator), denominator);
    }

    fn combineGrid(grid: *u64, component: u128, factor: u128) bool {
        const denominator = std.math.mul(u128, component, factor) catch return false;
        if (denominator > std.math.maxInt(u64)) return false;
        const combined = @as(
            u128,
            grid.* / std.math.gcd(grid.*, @as(u64, @intCast(denominator))),
        ) * denominator;
        if (combined > std.math.maxInt(u64)) return false;
        grid.* = @intCast(combined);
        return true;
    }

    // Keep the wide-integer implementation out of the ordinary sampling loop and its register set.
    noinline fn rgbExact(
        self: ColorCalibration,
        y: u8,
        chroma: [2]f64,
        endian: std.builtin.Endian,
        preferred: [3]u8,
    ) [3]u8 {
        const raw = self.values(endian);
        const codes = [3]u16{
            @as(u16, y) * 16,
            @intFromFloat(chroma[0] * 16),
            @intFromFloat(chroma[1] * 16),
        };
        var numerators: [3]i128 = undefined;
        var denominators: [3]u128 = undefined;
        for (&numerators, &denominators, codes, 0..) |*numerator, *denominator, code, i| {
            const black = raw.references[i * 2];
            const white = raw.references[i * 2 + 1];
            numerator.* = (@as(
                i128,
                code,
            ) * black.denominator - @as(
                i128,
                16,
            ) * black.numerator) * @as(i128, if (i == 0) 255 else 127) * white.denominator;
            denominator.* = 16 * (@as(
                u128,
                white.numerator,
            ) * black.denominator - @as(u128, black.numerator) * white.denominator);
        }
        // Codes are at most 4080. Expanded numerators use fewer than 84 bits, denominators 68. A
        // common denominator uses fewer than 204 bits and scaled numerators fewer than 220.
        const common = denominators[0] * @as(u256, denominators[1]) * denominators[2];
        const yy = @as(i256, numerators[0]) * @as(i256, denominators[1]) * denominators[2];
        const cb = @as(i256, numerators[1]) * @as(i256, denominators[0]) * denominators[2];
        const cr = @as(i256, numerators[2]) * @as(i256, denominators[0]) * denominators[1];
        const r = raw.coefficients[0];
        const g = raw.coefficients[1];
        const b = raw.coefficients[2];
        const red = yy * r.denominator + 2 * (@as(i256, r.denominator) - r.numerator) * cr;
        const blue = yy * b.denominator + 2 * (@as(i256, b.denominator) - b.numerator) * cb;
        // Expand the original green equation over dR^2*dB^2; do not assume the admitted weights sum
        // to exactly one. Its numerator needs fewer than 384 bits, denominator fewer than 364.
        // Fixed 512-bit arithmetic has ample headroom without allocation or intermediate clipping.
        const red_factor = -2 * @as(
            i256,
            r.numerator,
        ) * (@as(i256, r.denominator) - r.numerator) * b.denominator * b.denominator;
        const blue_factor = -2 * @as(
            i256,
            b.numerator,
        ) * (@as(i256, b.denominator) - b.numerator) * r.denominator * r.denominator;
        const y_factor = (@as(
            i256,
            r.denominator,
        ) * b.denominator - @as(
            i256,
            r.numerator,
        ) * b.denominator - @as(i256, b.numerator) * r.denominator) * r.denominator * b.denominator;
        const green = (@as(
            i512,
            yy,
        ) * y_factor + @as(i512, cr) * red_factor + @as(i512, cb) * blue_factor) * g.denominator;
        const green_denominator = @as(
            u512,
            common,
        ) * r.denominator * r.denominator * b.denominator * b.denominator * g.numerator;
        return .{
            roundExact(red, common * r.denominator, preferred[0]),
            roundExact(green, green_denominator, preferred[1]),
            roundExact(blue, common * b.denominator, preferred[2]),
        };
    }

    fn roundExact(numerator: i512, denominator: u512, preferred: u8) u8 {
        if (numerator <= 0) return 0;
        const divisor: i512 = @intCast(denominator);
        if (numerator >= divisor * 255) return 255;
        const whole = @divTrunc(numerator, divisor);
        const twice_remainder = @rem(numerator, divisor) * 2;
        // Preserve the existing adjacent lower result only at an exact mathematical half. Other
        // values receive exact nearest rounding, including cases hidden by large cancellation.
        if (twice_remainder == divisor and preferred == whole) return preferred;
        return @intCast(whole + @intFromBool(twice_remainder >= divisor));
    }
};

const Rational = struct {
    numerator: u32,
    denominator: u32,

    fn value(self: Rational) f64 {
        return @as(f64, @floatFromInt(self.numerator)) / @as(f64, @floatFromInt(self.denominator));
    }
};

// Keep a strictly positive encoded reference span even when conversion rounds both endpoints to the
// same f64. Ordinary spans retain their previous floating-point difference.
const ColorReference = struct {
    black: f64,
    span: f64,

    fn init(black: Rational, white: Rational) ThumbnailRasterError!ColorReference {
        const maximum_black_numerator = @as(u64, black.denominator) * 255;
        const maximum_white_numerator = @as(u64, white.denominator) * 255;
        if (black.numerator > maximum_black_numerator or white.numerator > maximum_white_numerator)
            return error.InvalidExif;
        // Compare the encoded fractions before rounding. Products of their u32 components fit u64.
        const scaled_black = @as(u64, black.numerator) * white.denominator;
        const scaled_white = @as(u64, white.numerator) * black.denominator;
        if (scaled_white <= scaled_black) return error.InvalidExif;
        const black_value = black.value();
        var span = white.value() - black_value;
        if (span == 0) {
            const numerator: f64 = @floatFromInt(scaled_white - scaled_black);
            const denominator: f64 = @floatFromInt(@as(u64, black.denominator) * white.denominator);
            span = numerator / denominator;
        }
        return .{ .black = black_value, .span = span };
    }
};

fn rational(entry: Entry, index: usize) ThumbnailRasterError!Rational {
    if (entry.field_type != 5 or index >= entry.count) return error.InvalidExif;
    const bytes = (try entry.data())[index * 8 ..][0..8];
    const numerator = std.mem.readInt(u32, bytes[0..4], entry.view.endian);
    const denominator = std.mem.readInt(u32, bytes[4..8], entry.view.endian);
    if (denominator == 0) return error.InvalidExif;
    return .{ .numerator = numerator, .denominator = denominator };
}

fn rounded(value: f64) f64 {
    return @floor(std.math.clamp(value, 0, 255) + 0.5);
}

fn scalar(directory: Directory, tag: u16, default: ?u32) ThumbnailRasterError!u32 {
    const entry = (try directory.find(tag)) orelse return default orelse error.InvalidExif;
    return entry.unsignedScalar();
}

test "Exif native thumbnail rasters retain independent RGB and YCbCr samples" {
    for (raster_fixtures) |control| {
        const view = try View.open(control.wire, .{});
        const directory = if (try view.thumbnail()) |thumbnail| thumbnail.directory else try view
            .primary();
        const raster = try ThumbnailRaster.open(
            directory,
            .{ .ycbcr_defaults = if (control.exif_default) .exif_2012 else .full_range },
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
    const controls = [_][]const u8{ &.{
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
    }, &.{
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
    } };
    for (controls) |wire| {
        const selected = try (try View.open(wire, .{})).primary();
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
                selected.view.endian,
            );
            std.mem.writeInt(
                u32,
                invalid[reference_offset + 12 ..][0..4],
                numerator + 1,
                selected.view.endian,
            );
            const rejected = try (try View.open(invalid, .{})).primary();
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
        for (0..3) |index| std.mem.writeInt(u16, wire[194 + index * 2 ..][0..2], 8, endian);
        const calibration = [_]u32{
            2,           1,           253_999_999, 254_000_000, 1,   254_000_000, 0,   1,
            255_000_000, 255_000_001, 255_000_001, 255_000_002, 128, 1,           255, 1,
            255_000_000, 255_000_001, 255_000_001, 255_000_002,
        };
        for (calibration, 0..) |value, index| {
            std.mem.writeInt(u32, wire[200 + index * 4 ..][0..4], value, endian);
        }
        wire[280..284].* = .{ 1, 1, 128, 0 };
        const selected = try (try View.open(&wire, .{})).primary();
        const image = try ThumbnailRaster.open(selected, .{});
        try std.testing.expectEqual([3]u8{ 0, 255, 255 }, image.rgb(0, 0));
        try std.testing.expectEqual([3]u8{ 0, 255, 255 }, image.rgb(1, 0));

        // All three spans now have unit cross-product differences and maximum-width denominators.
        // These endpoint codes clip to white/black, while exercising the full wide-intermediate
        // bounds through the same public sampler on both 32-bit and 64-bit targets.
        const extreme_weights = [_]u32{ 0xfffffffe, 0xffffffff, 1, 0xffffffff, 0, 1 };
        for (
            extreme_weights,
            0..,
        ) |value, index| std.mem.writeInt(u32, wire[208 + index * 4 ..][0..4], value, endian);
        for (0..3) |channel| {
            const reference: [4]u32 = .{ 0xfffffffd, 0xfffffffe, 0xfffffffe, 0xffffffff };
            for (
                reference,
                0..,
            ) |value, index| std.mem.writeInt(
                u32,
                wire[232 + channel * 16 + index * 4 ..][0..4],
                value,
                endian,
            );
        }
        for ([_]u8{ 0, 1 }) |code| {
            @memset(wire[280..284], code);
            const extreme = try ThumbnailRaster.open(
                try (try View.open(&wire, .{})).primary(),
                .{},
            );
            const expected: [3]u8 = @splat(if (code == 0) 0 else 255);
            try std.testing.expectEqual(expected, extreme.rgb(0, 0));
            try std.testing.expectEqual(expected, extreme.rgb(1, 0));
        }
    }
}
