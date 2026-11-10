//! PNG sample layout, pass geometry and shared resource-policy admission.

const std = @import("std");
const Limits = @import("Limits.zig");

/// Default source-axis policy shared by structural inspection and decoding, in pixels. This is a
/// configurable resource default, separate from PNG's 31-bit dimension bound.
pub const default_maximum_source_extent: u32 = 4_096;

/// PNG signature bytes, independently of chunk CRC and pixel validity.
pub const signature = &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

/// Malformed or unsupported PNG data; allocation failure remains separate.
pub const Error = Limits.Error || error{
    /// Malformed structure, dimensions, checksums, compressed data, or pixel values.
    InvalidPng,
    /// A header feature or critical chunk lies outside the supported profile.
    UnsupportedPng,
    /// Explicit structural record policy is exhausted before another chunk is visited.
    MetadataLimitExceeded,
};

// Shared policy checks for PNG operations. Limits remains the caller's resource declaration.
pub fn admitOutput(limits: Limits, pixels: usize, bytes: usize) Limits.Error!void {
    if (pixels > limits.maximum_pixels) return error.PixelBudgetExceeded;
    if (bytes > limits.maximum_output_bytes) return error.OutputBudgetExceeded;
}

pub fn admitWork(limits: Limits, units: usize) Limits.Error!void {
    if (units > limits.maximum_work_units) return error.WorkBudgetExceeded;
}

/// Coordinates of one reduced image whose rows share filter history.
pub const Pass = struct {
    /// First destination pixel column.
    start_x: usize,
    /// First destination pixel row.
    start_y: usize,
    /// Distance between destination columns. Nonzero; use the admitted sequential or Adam7 pass
    /// definitions.
    step_x: usize,
    /// Distance between destination rows. Nonzero; filter history belongs to this pass alone.
    step_y: usize,
};

/// Adam7 scan order; each pass starts with no preceding filter row.
pub const adam7_passes = [_]Pass{
    .{ .start_x = 0, .start_y = 0, .step_x = 8, .step_y = 8 },
    .{ .start_x = 4, .start_y = 0, .step_x = 8, .step_y = 8 },
    .{ .start_x = 0, .start_y = 4, .step_x = 4, .step_y = 8 },
    .{ .start_x = 2, .start_y = 0, .step_x = 4, .step_y = 4 },
    .{ .start_x = 0, .start_y = 2, .step_x = 2, .step_y = 4 },
    .{ .start_x = 1, .start_y = 0, .step_x = 2, .step_y = 2 },
    .{ .start_x = 0, .start_y = 1, .step_x = 1, .step_y = 2 },
};

/// Full-resolution sequential scan order.
pub const sequential_pass = Pass{ .start_x = 0, .start_y = 0, .step_x = 1, .step_y = 1 };

/// Computes the byte-aligned size of a packed row, excluding its filter byte. Zero width or zero
/// bits contributes no bytes. Only an unrepresentable final byte count overflows; callers
/// separately admit PNG dimensions and supported sample layouts.
pub fn packedRowBytes(width: usize, bits_per_pixel: usize) error{SizeOverflow}!usize {
    const whole = std.math.mul(usize, width, bits_per_pixel / 8) catch return error.SizeOverflow;
    const remaining_bits = bits_per_pixel % 8;
    if (remaining_bits == 0) return whole;

    // Split before multiplying: the tail has at most 49 bits, and its rounded byte count plus the
    // complete eight-pixel groups never exceeds width.
    const partial = (width / 8) * remaining_bits + ((width % 8) * remaining_bits + 7) / 8;
    return std.math.add(usize, whole, partial) catch error.SizeOverflow;
}

/// Locates a high-bit-first sample of depth 1, 2, 4 or 8 without an intermediate bit offset. Every
/// usize sample index has a representable byte index at these depths.
pub fn packedSamplePosition(index: usize, depth: u8) struct { byte_index: usize, shift: u3 } {
    return switch (depth) {
        inline 1, 2, 4, 8 => |bits| .{
            .byte_index = index / (8 / bits),
            .shift = @intCast((8 / bits - 1 - index % (8 / bits)) * bits),
        },
        else => unreachable,
    };
}

test "packed sample positions retain byte-fit indices beyond bit-offset arithmetic" {
    const maximum = std.math.maxInt(usize);
    inline for (.{ 1, 2, 4, 8 }) |depth| {
        const per_byte = 8 / depth;
        for (0..8) |tail| {
            const index = maximum - tail;
            const position = packedSamplePosition(index, depth);
            try std.testing.expectEqual(index / per_byte, position.byte_index);
            try std.testing.expectEqual((tail % per_byte) * depth, position.shift);
        }
    }
}

/// Computes row and filtered stream byte counts for admitted sample geometry. The interlace method
/// must be 0 (sequential) or 1 (Adam7); unrepresentable sizes return InvalidPng.
pub fn packedLayout(
    width: u32,
    height: u32,
    bits_per_pixel: usize,
    interlace_method: u8,
) Error!struct { row_bytes: usize, filtered_bytes: usize } {
    const packed_row_bytes = packedRowBytes(width, bits_per_pixel) catch return error.InvalidPng;
    const filtered_row_bytes = std.math.add(
        usize,
        packed_row_bytes,
        1,
    ) catch return error.InvalidPng;
    const image_width: usize = width;
    const image_height: usize = height;
    const filtered_byte_count = blk: {
        if (interlace_method == 0) {
            break :blk std.math.mul(
                usize,
                image_height,
                filtered_row_bytes,
            ) catch return error.InvalidPng;
        }

        var total: usize = 0;
        for (adam7_passes) |pass| {
            const pass_width = passExtent(image_width, pass.start_x, pass.step_x);
            const pass_height = passExtent(image_height, pass.start_y, pass.step_y);
            if (pass_width == 0 or pass_height == 0) continue;
            const pass_packed_row_bytes = packedRowBytes(
                pass_width,
                bits_per_pixel,
            ) catch return error.InvalidPng;
            const pass_filtered_row_bytes = std.math.add(
                usize,
                pass_packed_row_bytes,
                1,
            ) catch return error.InvalidPng;
            const pass_byte_count = std.math.mul(
                usize,
                pass_height,
                pass_filtered_row_bytes,
            ) catch return error.InvalidPng;
            total = std.math.add(usize, total, pass_byte_count) catch return error.InvalidPng;
        }
        break :blk total;
    };
    return .{ .row_bytes = packed_row_bytes, .filtered_bytes = filtered_byte_count };
}

/// Counts samples visited by a pass along one admitted image axis. `step` is nonzero;
/// extent/start/step can use the complete usize range without overflow. An axis with
/// `extent <= start` contributes no samples. For example, extent 9, start 4, step 8 visits one
/// sample; skip an Adam7 pass if either axis count is zero.
pub fn passExtent(extent: usize, start: usize, step: usize) usize {
    if (extent <= start) return 0;
    return (extent - start - 1) / step + 1;
}

test "PNG packed row bytes match widened arithmetic at full host-size boundaries" {
    for (0..129) |width| for (0..65) |bits| {
        const expected = (width * bits + 7) / 8;
        try std.testing.expectEqual(expected, try packedRowBytes(width, bits));
    };
    const maximum = std.math.maxInt(usize);
    const widths = [_]usize{
        0,
        1,
        2,
        7,
        8,
        9,
        15,
        16,
        31,
        32,
        127,
        128,
        maximum / 8,
        maximum / 8 + 1,
        maximum / 2,
        maximum / 2 + 1,
        maximum - 7,
        maximum - 1,
        maximum,
    };
    const depths = [_]usize{
        0,
        1,
        2,
        3,
        4,
        7,
        8,
        9,
        16,
        24,
        32,
        48,
        64,
        maximum / 8,
        maximum / 8 + 1,
        maximum / 2,
        maximum,
    };
    for (widths) |width| for (depths) |bits| {
        // Independent widened multiplication/rounding fits for the supported 32/64-bit hosts.
        const expected = (@as(u128, width) * bits + 7) / 8;
        if (expected > maximum) {
            try std.testing.expectError(error.SizeOverflow, packedRowBytes(width, bits));
        } else {
            try std.testing.expectEqual(
                @as(usize, @intCast(expected)),
                try packedRowBytes(width, bits),
            );
        }
    };
}

test "PNG pass extent preserves independent sample walks and full host-size boundaries" {
    // Enumerate visited coordinates independently of the division/rounding expression.
    for (0..33) |extent| for (0..17) |start| for (1..17) |step| {
        var expected: usize = 0;
        var coordinate = start;
        while (coordinate < extent) : (coordinate += step) expected += 1;
        try std.testing.expectEqual(expected, passExtent(extent, start, step));
    };
    const maximum = std.math.maxInt(usize);
    try std.testing.expectEqual(0, passExtent(0, 0, maximum));
    try std.testing.expectEqual(0, passExtent(maximum, maximum, 1));
    try std.testing.expectEqual(maximum, passExtent(maximum, 0, 1));
    try std.testing.expectEqual(maximum / 2 + 1, passExtent(maximum, 0, 2));
    try std.testing.expectEqual(1, passExtent(maximum, 0, maximum));
    try std.testing.expectEqual(1, passExtent(maximum, maximum - 1, maximum));
    try std.testing.expectEqual(1, passExtent(1, 0, maximum));
}

/// Encoded PNG color layout; channels stay in stored order without conversion.
pub const ColorType = enum(u8) {
    /// One grayscale channel, depth 1/2/4/8/16.
    grayscale = 0,
    /// Red, green, blue channels, depth 8/16.
    truecolor = 2,
    /// One palette index, depth 1/2/4/8.
    indexed = 3,
    /// Grayscale and unassociated alpha channels, depth 8/16.
    grayscale_alpha = 4,
    /// Red, green, blue and unassociated alpha channels, depth 8/16.
    rgba = 6,

    /// Number of stored channels; a palette index is one channel.
    pub fn channels(self: ColorType) usize {
        return switch (self) {
            .grayscale, .indexed => 1,
            .truecolor => 3,
            .grayscale_alpha => 2,
            .rgba => 4,
        };
    }
};

/// Caller-owned immutable row storage; the final row need not retain trailing padding.
pub const Samples = union(enum) {
    /// Packed PNG samples: high bits first below eight, big endian at sixteen.
    packed_bytes: struct {
        /// At least `(height - 1) * effective_stride + row_bytes` bytes; trailing bytes are
        /// ignored.
        bytes: []const u8,
        /// Bytes between row starts. Zero selects row_bytes as the effective stride; padding is
        /// ignored.
        stride: usize = 0,
    },
    /// Host-native u16 channels; available only with bit_depth sixteen.
    words: struct {
        /// At least `(height - 1) * effective_stride + width * channels` words; trailing words are
        /// ignored.
        values: []const u16,
        /// Words between row starts. Zero selects width * channels as the effective stride; padding
        /// is ignored.
        stride: usize = 0,
    },
};

/// Explicit tRNS choice; alpha-bearing layouts instead preserve their supplied alpha.
pub const Transparency = union(enum) {
    /// Omit tRNS.
    none,
    /// Complete stored grayscale code; unused upper bits must be zero.
    grayscale: u16,
    /// Complete stored red/green/blue codes; unused upper bits must be zero.
    truecolor: [3]u16,
    /// Indexed alpha values for a palette prefix; remaining entries are opaque. An empty prefix
    /// omits tRNS rather than writing an empty table.
    palette: []const u8,
};

/// Encoded traversal; both use one zlib stream with independent per-pass filter history.
pub const Interlace = enum(u8) { none = 0, adam7 = 1 };

/// Interpretation of indices outside an admitted, nonempty indexed palette. PNG Third Edition 13.1
/// specifies opaque-black recovery. Select strict rejection when ingestion must reject every absent
/// entry. Neither policy repairs framing, missing palettes, filters or checksums. Encoders continue
/// rejecting invalid indices. Specification:
/// https://www.w3.org/TR/2025/REC-png-3-20250624/#13Error-handling
pub const PaletteIndexPolicy = enum {
    /// Report InvalidPng before loading an absent palette entry.
    reject,
    /// Emit zero RGB and maximum alpha, independent of the encoded palette's tRNS values.
    opaque_black,
};
