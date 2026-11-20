//! Exact rational YCbCr calibration borrowed from admitted TIFF fields. Ordinary pixels use
//! binary64. This value retains the encoded fractions so admission can certify that rounding is
//! safe, and uncertain pixels can use exact arithmetic. No intermediate color is clipped; only the
//! final RGB8 result is quantized.
const std = @import("std");
const Metadata = @import("Metadata.zig");
const Rational = Metadata.Directory.Entry.UnsignedRational;
const YcbcrCalibration = @This();

/// Encoded three-coefficient field, or null for TIFF's standard coefficients.
coefficients: ?*const [24]u8 = null,
/// Encoded six ReferenceBlackWhite endpoints, or null for `reference_defaults`.
references: ?*const [48]u8 = null,
/// Interpretation used only when the source omits ReferenceBlackWhite.
reference_defaults: YcbcrReferenceDefaults,

/// Fallback ReferenceBlackWhite interpretation when the TIFF field is absent.
pub const YcbcrReferenceDefaults = enum {
    /// Full-range TIFF/JFIF codes [0,255,128,255,128,255], used by common image readers.
    full_range,
    /// Codes [0,255,0,128,0,128] printed in CIPA DC-008-2012 section 4.6.5.2.
    exif_2012,
};

/// Exact coefficients and endpoints decoded for certification or an uncertain pixel.
const Values = struct {
    /// Exact red, green and blue luminance coefficients.
    coefficients: [3]Rational,
    /// Exact black/white pairs for Y, Cb and Cr, in that order.
    references: [6]Rational,
};

/// Decodes exact fractions, supplying standard coefficients and the chosen missing-tag references.
pub fn readValues(self: YcbcrCalibration, endian: std.builtin.Endian) Values {
    var result: Values = .{
        .coefficients = .{
            .{ .numerator = 299, .denominator = 1000 },
            .{ .numerator = 587, .denominator = 1000 },
            .{ .numerator = 114, .denominator = 1000 },
        },
        .references = undefined,
    };
    const references = switch (self.reference_defaults) {
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

/// Every exact output is an integer multiple of 1/D for a fixed calibration. Unless exactly on a
/// rounding half, its distance from that half is at least 1/(2D). A smaller float error makes all
/// non-ties round identically; exact ties retain the existing adjacent result. Certify ordinary
/// calibration once so it does not need a per-pixel uncertainty check.
pub fn requiresRoundingCheck(
    self: YcbcrCalibration,
    endian: std.builtin.Endian,
    errors: [3]f64,
) bool {
    const raw = self.readValues(endian);
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
    if (!includeGridDenominator(
        &output_grids[0],
        grids[0],
        1,
    ) or !includeGridDenominator(
        &output_grids[0],
        grids[2],
        red_denominator,
    ) or !includeGridDenominator(
        &output_grids[2],
        grids[0],
        1,
    ) or !includeGridDenominator(
        &output_grids[2],
        grids[1],
        blue_denominator,
    ) or !includeGridDenominator(
        &output_grids[1],
        grids[0],
        green_y,
    ) or !includeGridDenominator(
        &output_grids[1],
        grids[2],
        green_cr,
    ) or !includeGridDenominator(&output_grids[1], grids[1], green_cb)) return true;
    for (output_grids, errors) |grid, uncertainty| {
        // Half the minimum distance leaves strict headroom for the final float conversions.
        if (uncertainty >= 0.25 / @as(f64, @floatFromInt(grid))) return true;
    }
    return false;
}

fn reducedDenominator(numerator: i128, denominator: u128) u128 {
    return denominator / std.math.gcd(@abs(numerator), denominator);
}

fn includeGridDenominator(grid: *u64, component: u128, factor: u128) bool {
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

/// Resolves an uncertain pixel with exact fractions, clipping only final RGB components.
/// Fixed-width bounds below cover every admitted u32 parameter; keep this outside the float loop
/// and its register set. `preferred` selects either adjacent code only at an exact mathematical
/// half.
pub noinline fn rgbExact(
    self: YcbcrCalibration,
    y: u8,
    chroma: [2]f64,
    endian: std.builtin.Endian,
    preferred: [3]u8,
) [3]u8 {
    const raw = self.readValues(endian);
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
    // Codes are at most 4080. Expanded numerators use fewer than 84 bits, denominators 68. A common
    // denominator uses fewer than 204 bits and scaled numerators fewer than 220.
    const common = denominators[0] * @as(u256, denominators[1]) * denominators[2];
    const yy = @as(i256, numerators[0]) * @as(i256, denominators[1]) * denominators[2];
    const cb = @as(i256, numerators[1]) * @as(i256, denominators[0]) * denominators[2];
    const cr = @as(i256, numerators[2]) * @as(i256, denominators[0]) * denominators[1];
    const r = raw.coefficients[0];
    const g = raw.coefficients[1];
    const b = raw.coefficients[2];
    const red = yy * r.denominator + 2 * (@as(i256, r.denominator) - r.numerator) * cr;
    const blue = yy * b.denominator + 2 * (@as(i256, b.denominator) - b.numerator) * cb;
    // Expand the original green equation over dR^2*dB^2; do not assume the admitted weights sum to
    // exactly one. Its numerator needs fewer than 384 bits, denominator fewer than 364. Fixed
    // 512-bit arithmetic has ample headroom without allocation or intermediate clipping.
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
    // Preserve the existing adjacent lower result only at an exact mathematical half. Other values
    // receive exact nearest rounding, including cases hidden by large cancellation.
    if (twice_remainder == divisor and preferred == whole) return preferred;
    return @intCast(whole + @intFromBool(twice_remainder >= divisor));
}

// For coefficients (1/4, 1/2, 1/4), the exact matrix is R=Y+3Cr/2, B=Y+3Cb/2, G=Y-3(Cb+Cr)/4 after
// reference expansion. Sixteenth-step inputs therefore have output grids 1/32, 1/64 and 1/32. This
// independent matrix gives the certification thresholds.
test "YCbCr grid certification keeps strict quarter-step headroom" {
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var coefficients: [24]u8 = undefined;
        for ([_]u32{ 1, 4, 1, 2, 1, 4 }, 0..) |component, index|
            std.mem.writeInt(u32, coefficients[index * 4 ..][0..4], component, endian);
        const calibration: YcbcrCalibration = .{
            .coefficients = &coefficients,
            .reference_defaults = .full_range,
        };
        for ([_]f64{ 0x1p-7, 0x1p-8, 0x1p-7 }, 0..) |threshold, channel| {
            var errors: [3]f64 = @splat(0);
            errors[channel] = std.math.nextAfter(f64, threshold, 0);
            try std.testing.expect(!calibration.requiresRoundingCheck(endian, errors));
            errors[channel] = threshold;
            try std.testing.expect(calibration.requiresRoundingCheck(endian, errors));
            errors[channel] = std.math.nextAfter(f64, threshold, std.math.inf(f64));
            try std.testing.expect(calibration.requiresRoundingCheck(endian, errors));
        }
    }
}

test "exact RGB rounding distinguishes halves from neighboring fractions" {
    // 129s/(2s) is 64.5. Neighbors differ by 1/(2s), including a fraction too close for binary64 to
    // distinguish. The largest denominator exercises the proved green headroom.
    for ([_]u512{ 1, @as(u512, 1) << 250, @as(u512, 1) << 362 }) |scale| {
        const denominator = 2 * scale;
        const half: i512 = @intCast(129 * scale);
        try std.testing.expectEqual(64, roundExact(half, denominator, 64));
        try std.testing.expectEqual(65, roundExact(half, denominator, 65));
        try std.testing.expectEqual(64, roundExact(half - 1, denominator, 65));
        try std.testing.expectEqual(65, roundExact(half + 1, denominator, 64));
        try std.testing.expectEqual(0, roundExact(-1, denominator, 255));
        try std.testing.expectEqual(0, roundExact(0, denominator, 255));
        try std.testing.expectEqual(255, roundExact(@intCast(255 * denominator), denominator, 0));
        try std.testing.expectEqual(
            255,
            roundExact(@intCast(255 * denominator + 1), denominator, 0),
        );
    }
}
