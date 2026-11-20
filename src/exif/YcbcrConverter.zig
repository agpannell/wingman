//! Converts admitted TIFF YCbCr samples to RGB8 with reliable final rounding. ReferenceBlackWhite
//! first expands the stored codes; the inverse color matrix then combines them. Narrow rational
//! spans can create large terms that cancel. Opening bounds binary64 error and certifies ordinary
//! calibration once against its exact output grid. Other calibration checks each pixel's rounding
//! interval and asks the retained rational calibration to resolve uncertainty.
const std = @import("std");
const Metadata = @import("Metadata.zig");
const Directory = Metadata.Directory;
const Entry = Directory.Entry;
const Rational = Entry.UnsignedRational;
const YcbcrCalibration = @import("YcbcrCalibration.zig");
const YcbcrConverter = @This();

/// One or two luminance rows per stored chroma row.
vertical_subsampling: u8,
/// Chroma samples coincide with the first luminance sample when true; otherwise centered.
cosited: bool,
/// False when admission certifies every pixel against the exact component grids.
requires_rounding_check: bool = undefined,
/// Binary64 projection of red, green and blue luminance coefficients.
coefficients: [3]f64,
/// Binary64 black/span expansion parameters for Y, Cb and Cr.
references: [3]ReferenceRange,
/// Borrowed exact fractions retained for certification and uncertain rounding.
calibration: YcbcrCalibration,
/// Upper bounds on absolute red, green and blue evaluation error, in output code units.
rgb_error_bounds: [3]f64 = undefined,

/// Admits chroma geometry, color parameters and a safe rounding strategy for one directory.
pub fn open(
    directory: Directory,
    defaults: YcbcrCalibration.YcbcrReferenceDefaults,
) Entry.Error!YcbcrConverter {
    var result: YcbcrConverter = .{
        .vertical_subsampling = 2,
        .cosited = false,
        .coefficients = .{ 0.299, 0.587, 0.114 },
        .calibration = .{ .reference_defaults = defaults },
        .references = switch (defaults) {
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
        },
    };
    if (try directory.find(0x0212)) |sampling| {
        if (!sampling.isUnsigned() or sampling.value_count != 2) return error.InvalidExif;
        const horizontal = try sampling.unsigned(0);
        const vertical = try sampling.unsigned(1);
        if (horizontal != 2 or (vertical != 1 and vertical != 2)) return error.UnsupportedExif;
        result.vertical_subsampling = @intCast(vertical);
    }
    const positioning = (try directory.unsignedScalar(0x0213)) orelse 1;
    if (positioning != 1 and positioning != 2) return error.UnsupportedExif;
    result.cosited = positioning == 2;
    if (try directory.find(0x0211)) |coefficients| {
        if (coefficients.value_count != 3) return error.InvalidExif;
        for (&result.coefficients, 0..) |*value, i| {
            value.* = (try coefficients.unsignedRational(i)).toFloat();
        }
        result.calibration.coefficients = (try coefficients.data())[0..24];
    }
    const c = result.coefficients;
    // TIFF's inverse matrix divides only by green. Unsigned rationals already exclude negative
    // weights; zero red/blue weights keep the matrix invertible.
    if (c[1] <= 0 or @abs(c[0] + c[1] + c[2] - 1) > 0.00001) return error.InvalidExif;
    if (try directory.find(0x0214)) |references| {
        if (references.value_count != 6) return error.InvalidExif;
        for (&result.references, 0..) |*reference, i| {
            reference.* = try ReferenceRange.init(
                try references.unsignedRational(i * 2),
                try references.unsignedRational(i * 2 + 1),
            );
        }
        result.calibration.references = (try references.data())[0..48];
    }
    result.rgb_error_bounds = result.errorBounds(directory.metadata.endian);
    result.requires_rounding_check = result.calibration.requiresRoundingCheck(
        directory.metadata.endian,
        result.rgb_error_bounds,
    );
    return result;
}

/// Converts one luminance code and interpolated Cb/Cr pair to clipped, nearest RGB8. Chroma inputs
/// are the exact sixteenth-step values supplied by the admitted sampler.
pub fn convert(self: YcbcrConverter, y: u8, chroma: [2]f64, endian: std.builtin.Endian) [3]u8 {
    // Admitted unsigned rationals bound these coefficients and positive reference spans. Byte
    // luminance and interpolated byte chroma keep the inverse finite in f64.
    const references = self.references;
    const luminance = (@as(f64, @floatFromInt(y)) - references[0].black) * 255 / references[0].span;
    const cb = (chroma[0] - references[1].black) * 127 / references[1].span;
    const cr = (chroma[1] - references[2].black) * 127 / references[2].span;
    const red = luminance + (2 - 2 * self.coefficients[0]) * cr;
    const blue = luminance + (2 - 2 * self.coefficients[2]) * cb;
    const green = (luminance - self.coefficients[0] * red - self.coefficients[2] * blue) / self
        .coefficients[1];
    const values = [3]f64{ red, green, blue };
    if (self.requires_rounding_check) {
        @branchHint(.unlikely);
        return self.roundWithErrorBounds(y, chroma, endian, values);
    }
    return .{
        @intFromFloat(roundedCode(red)),
        @intFromFloat(roundedCode(green)),
        @intFromFloat(roundedCode(blue)),
    };
}

noinline fn roundWithErrorBounds(
    self: YcbcrConverter,
    y: u8,
    chroma: [2]f64,
    endian: std.builtin.Endian,
    values: [3]f64,
) [3]u8 {
    const red, const green, const blue = values;
    const codes = [3]f64{ roundedCode(red), roundedCode(green), roundedCode(blue) };
    var uncertain = false;
    for (values, codes, self.rgb_error_bounds) |value, code, uncertainty| {
        const lower = code - 0.5;
        const upper = code + 0.5;
        if ((code != 0 and value - uncertainty <= lower) or (code != 255 and value + uncertainty >=
            upper))
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

// Bound the absolute error of the existing floating-point expression over all byte inputs. Chroma
// interpolation is exact: 4:2:2/4:2:0 positioning gives multiples of 1/16. Only rational conversion
// and the inverse color expression contribute rounding. A pixel whose uncertainty crosses a
// quantization boundary uses the encoded rationals instead of losing cancellation.
fn errorBounds(self: YcbcrConverter, endian: std.builtin.Endian) [3]f64 {
    const raw = self.calibration.readValues(endian);
    var expanded: [3]FloatErrorBound = undefined;
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
        const span_error = if (black.denominator == 1 and white.denominator == 1) 0 else 2 * (@abs(
            reference.span - exact_span,
        ) + FloatErrorBound.roundoff * exact_span);
        const black_error: FloatErrorBound = .{
            .magnitude = reference.black,
            .error_bound = if (black.denominator == 1) 0 else FloatErrorBound.roundoff * reference
                .black,
        };
        bound.* = (FloatErrorBound{
            .magnitude = 255,
        }).add(
            black_error,
        ).multiply(.{
            .magnitude = if (i == 0) 255 else 127,
        }).divide(reference.span, exact_span * 0.5, span_error);
    }
    var weights: [3]FloatErrorBound = undefined;
    for (&weights, self.coefficients, raw.coefficients) |*bound, value, encoded| {
        bound.* = .{
            .magnitude = value,
            .error_bound = if (encoded.denominator == 1) 0 else FloatErrorBound.roundoff * value,
        };
    }
    const two: FloatErrorBound = .{ .magnitude = 2 };
    // Addition also bounds subtraction, so these magnitude bounds deliberately add every term even
    // where the actual matrix subtracts it. Cancellation cannot hide rounding error.
    const red = expanded[0].add(two.add(two.multiply(weights[0])).multiply(expanded[2]));
    const blue = expanded[0].add(two.add(two.multiply(weights[2])).multiply(expanded[1]));
    const green = expanded[0].add(
        weights[0].multiply(red),
    ).add(
        weights[2].multiply(blue),
    ).divide(self.coefficients[1], self.coefficients[1] * 0.5, weights[1].error_bound);
    return .{ red.error_bound, green.error_bound, blue.error_bound };
}

// Forward absolute-error accounting for the same color expression. Positive bound operations round
// outward. Twice binary64's unit roundoff covers each operation. Admitted u32 fractions, spans
// above 2^-65 and green above 2^-33 keep conservative intermediate bounds below 2^256 and finite.
const FloatErrorBound = struct {
    /// Upper bound on the computed operand's absolute magnitude.
    magnitude: f64,
    /// Upper bound on its absolute deviation from the exact expression.
    error_bound: f64 = 0,

    const roundoff = 0x1p-52;

    fn roundUp(value: f64) f64 {
        return if (value == 0) 0 else std.math.nextAfter(f64, value, std.math.inf(f64));
    }

    // Addition and subtraction have the same absolute bounds.
    fn add(a: FloatErrorBound, b: FloatErrorBound) FloatErrorBound {
        const magnitude = roundUp(a.magnitude + b.magnitude);
        return .{
            .magnitude = magnitude,
            .error_bound = roundUp(
                roundUp(a.error_bound + b.error_bound) + roundUp(roundoff * magnitude),
            ),
        };
    }

    fn multiply(a: FloatErrorBound, b: FloatErrorBound) FloatErrorBound {
        const magnitude = roundUp(a.magnitude * b.magnitude);
        return .{
            .magnitude = magnitude,
            .error_bound = roundUp(
                roundUp(
                    roundUp(
                        roundUp(a.magnitude * b.error_bound) + roundUp(b.magnitude * a.error_bound),
                    ) + roundUp(a.error_bound * b.error_bound),
                ) + roundUp(roundoff * magnitude),
            ),
        };
    }

    // The divisor is a known positive float; minimum bounds its exact encoded value from below.
    fn divide(a: FloatErrorBound, divisor: f64, minimum: f64, divisor_error: f64) FloatErrorBound {
        const magnitude = roundUp(a.magnitude / divisor);
        const denominator = std.math.nextAfter(f64, divisor * minimum, 0);
        return .{
            .magnitude = magnitude,
            .error_bound = roundUp(
                roundUp(
                    roundUp(
                        a.error_bound / divisor,
                    ) + roundUp(
                        roundUp(roundUp(a.magnitude + a.error_bound) * divisor_error) / denominator,
                    ),
                ) + roundUp(roundoff * magnitude),
            ),
        };
    }
};

// Preserve a positive encoded span even when its two endpoints project to the same binary64 value.
const ReferenceRange = struct {
    /// Binary64 projection of the exact black reference code.
    black: f64,
    /// Strictly positive white-minus-black span, retaining a sub-ULP encoded difference.
    span: f64,

    fn init(black: Rational, white: Rational) error{InvalidExif}!ReferenceRange {
        const maximum_black_numerator = @as(u64, black.denominator) * 255;
        const maximum_white_numerator = @as(u64, white.denominator) * 255;
        if (black.numerator > maximum_black_numerator or white.numerator > maximum_white_numerator)
            return error.InvalidExif;
        // Compare the encoded fractions before rounding. Products of their u32 components fit u64.
        const scaled_black = @as(u64, black.numerator) * white.denominator;
        const scaled_white = @as(u64, white.numerator) * black.denominator;
        if (scaled_white <= scaled_black) return error.InvalidExif;
        const black_value = black.toFloat();
        var span = white.toFloat() - black_value;
        if (span == 0) {
            const numerator: f64 = @floatFromInt(scaled_white - scaled_black);
            const denominator: f64 = @floatFromInt(@as(u64, black.denominator) * white.denominator);
            span = numerator / denominator;
        }
        return .{ .black = black_value, .span = span };
    }
};

fn roundedCode(value: f64) f64 {
    return @floor(std.math.clamp(value, 0, 255) + 0.5);
}
