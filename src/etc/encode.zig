//! Caller-owned ETC1 RGB and unsigned EAC block encoding. Admission precedes all output writes;
//! fitting uses bounded stack storage and compares complete 4×4 tiles without color conversion.

const std = @import("std");
const memory = @import("../common/byte_ranges.zig");
const format = @import("format.zig");
const fitting = @import("fit.zig");
const scalar = @import("scalar.zig");

/// Per-call search and admission. All sixteen samples participate, including any stored padding.
pub const EncodeOptions = struct {
    /// Wider searches retain earlier candidates; complete-tile squared component error cannot rise.
    effort: format.Effort = .fast,
    /// Maximum `colorWorkUnits(effort)` or `scalarWorkUnits(effort)` for this block. Units are
    /// conservative admission policy rather than elapsed time. Refusal precedes any output write.
    maximum_work_units: u64 = 1024 * 1024,
};

/// Insufficient output, overlapping used storage or a refused fitting reservation.
pub const EncodeError = error{ DestinationTooSmall, OverlappingStorage, WorkBudgetExceeded };

/// Fits sixteen row-major RGBA8 samples into an eight-byte ETC1 RGB block. Alpha is ignored; the
/// reconstructed block is opaque. Both individual and differential color modes participate. Writes
/// only the used output prefix; every error preserves the entire destination. Source and used
/// output must be disjoint. No allocation, transfer conversion or perceptual metric occurs.
pub fn encodeBlock(
    texels: *const [16][4]u8,
    destination: []u8,
    options: EncodeOptions,
) EncodeError!void {
    const output = try admit(
        std.mem.asBytes(texels),
        destination,
        options,
        fitting.colorWorkUnits(options.effort),
    );
    fitting.encode(texels, options.effort, output);
}

test encodeBlock {
    const texels: [16][4]u8 = @splat(.{ 0, 0, 0, 17 });
    var encoded: [8]u8 = undefined;
    try encodeBlock(&texels, &encoded, .{});
    var rgba: [64]u8 = undefined;
    try @import("color.zig").decodeBlock(&encoded, &rgba);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, rgba[0..4]);
}

/// Fits sixteen row-major alpha bytes into one eight-byte EAC alpha8 block. ETC2 RGBA stores this
/// block before its color block. Constants reconstruct exactly. The encoder always emits a nonzero
/// multiplier, as required by the format; the decoder also handles stored zero multipliers.
/// Allocates nothing; storage, spare capacity and failure guarantees match `encodeBlock`.
pub fn encodeAlphaBlock(
    samples: *const [16]u8,
    destination: []u8,
    options: EncodeOptions,
) EncodeError!void {
    const output = try admit(samples, destination, options, scalar.scalarWorkUnits(options.effort));
    scalar.encode(samples, 8, options.effort, output);
}

test encodeAlphaBlock {
    const samples: [16]u8 = @splat(103);
    var encoded: [8]u8 = undefined;
    try encodeAlphaBlock(&samples, &encoded, .{});
    var alpha: [16]u8 = undefined;
    try scalar.decodeAlphaBlock(&encoded, &alpha);
    try std.testing.expectEqualSlices(u8, &samples, &alpha);
}

/// Fits sixteen normalized unsigned bytes into an eight-byte EAC R11 block. Each input maps to
/// nearest `value * 2047 / 255`; error is measured against all eleven reconstructed bits. Constant
/// bytes reconstruct that nearest value exactly. This is not the alpha8 representation. RG11 stores
/// two R11 blocks in component order. Allocates nothing; storage and failure guarantees match
/// `encodeBlock`. No transfer conversion, signed mapping or channel selection is inferred.
pub fn encodeR11Block(
    samples: *const [16]u8,
    destination: []u8,
    options: EncodeOptions,
) EncodeError!void {
    const output = try admit(samples, destination, options, scalar.scalarWorkUnits(options.effort));
    scalar.encode(samples, 11, options.effort, output);
}

test encodeR11Block {
    const samples: [16]u8 = @splat(103);
    var encoded: [8]u8 = undefined;
    try encodeR11Block(&samples, &encoded, .{});
    var red: [16]u16 = undefined;
    try scalar.decodeR11Block(&encoded, &red);
    try std.testing.expect(std.mem.allEqual(u16, &red, 827));
}

fn admit(
    source: []const u8,
    destination: []u8,
    options: EncodeOptions,
    work: u64,
) EncodeError!*[8]u8 {
    if (work > options.maximum_work_units) return error.WorkBudgetExceeded;
    if (destination.len < 8) return error.DestinationTooSmall;
    const output = destination[0..8];
    if (memory.overlaps(source, output)) return error.OverlappingStorage;
    return output;
}

const efforts = [_]format.Effort{ .fast, .balanced, .refined };

test "ETC1 fitting keeps exact binary splits in both orientations and ignores alpha" {
    for ([_]bool{ false, true }) |horizontal| {
        var texels: [16][4]u8 = undefined;
        for (&texels, 0..) |*texel, index| {
            const second = if (horizontal) index >= 8 else index % 4 >= 2;
            const value: u8 = if (second) 255 else 0;
            texel.* = .{ value, value, value, @intCast(index * 17) };
        }
        for (efforts) |effort| {
            var encoded: [11]u8 = @splat(0xa5);
            try encodeBlock(&texels, &encoded, .{ .effort = effort });
            var pixels: [64]u8 = undefined;
            try @import("color.zig").decodeBlock(&encoded, &pixels);
            for (texels, 0..) |texel, index| {
                try std.testing.expectEqualSlices(u8, texel[0..3], pixels[index * 4 ..][0..3]);
                try std.testing.expectEqual(255, pixels[index * 4 + 3]);
            }
            var other = texels;
            for (&other) |*texel| texel[3] = 255 - texel[3];
            var same: [8]u8 = undefined;
            try encodeBlock(&other, &same, .{ .effort = effort });
            try std.testing.expectEqualSlices(u8, &same, encoded[0..8]);
            try std.testing.expect(std.mem.allEqual(u8, encoded[8..], 0xa5));
        }
    }
}

test "EAC public writers preserve every constant at byte or eleven-bit precision" {
    for (0..256) |value| {
        const samples: [16]u8 = @splat(@intCast(value));
        for (efforts) |effort| {
            var encoded: [11]u8 = @splat(0xa5);
            try encodeAlphaBlock(&samples, &encoded, .{ .effort = effort });
            var alpha: [16]u8 = undefined;
            try scalar.decodeAlphaBlock(&encoded, &alpha);
            try std.testing.expectEqualSlices(u8, &samples, &alpha);
            try std.testing.expect(encoded[1] >> 4 != 0);
            if (value == 103) {
                const expected = [_]u8{ 0x67, 0x1d, 0x92, 0x49, 0x24, 0x92, 0x49, 0x24 };
                try std.testing.expectEqualSlices(u8, &expected, encoded[0..8]);
            }
            try encodeR11Block(&samples, &encoded, .{ .effort = effort });
            var red: [16]u16 = undefined;
            try scalar.decodeR11Block(&encoded, &red);
            const expected: u16 = @intCast((value * 2047 + 127) / 255);
            try std.testing.expect(std.mem.allEqual(u16, &red, expected));
            try std.testing.expect(std.mem.allEqual(u8, encoded[8..], 0xa5));
        }
    }
}

test "EAC alpha8 writers emit nonzero multipliers across narrow ranges" {
    for (0..256) |minimum| {
        for (1..9) |range| {
            var samples: [16]u8 = undefined;
            for (&samples, 0..) |*sample, pixel| {
                const offset = (pixel * 5 + pixel / 4) % (range + 1);
                sample.* = @intCast(@min(255, minimum + offset));
            }
            for (efforts) |effort| {
                var encoded: [13]u8 = @splat(0xa5);
                try encodeAlphaBlock(&samples, &encoded, .{ .effort = effort });
                try std.testing.expect(encoded[1] >> 4 != 0);
                try std.testing.expect(std.mem.allEqual(u8, encoded[8..], 0xa5));
            }
        }
    }
}

test "ETC and EAC wider searches retain complete tile error for mixed and narrow ranges" {
    for (0..32) |case| {
        var texels: [16][4]u8 = undefined;
        var samples: [16]u8 = undefined;
        for (&texels, &samples, 0..) |*texel, *sample, pixel| {
            for (texel, 0..) |*component, channel| {
                component.* = @truncate(case * 97 + pixel * 31 + channel * (pixel + case * 7));
            }
            sample.* = if (case < 16) @intCast(case * 13 + pixel % 5) else texel[3];
        }
        var previous: [3]u64 = @splat(std.math.maxInt(u64));
        for (efforts) |effort| {
            var encoded: [8]u8 = undefined;
            var pixels: [64]u8 = undefined;
            try encodeBlock(&texels, &encoded, .{ .effort = effort });
            try @import("color.zig").decodeBlock(&encoded, &pixels);
            var errors: [3]u64 = @splat(0);
            for (texels, 0..) |texel, pixel| {
                for (texel[0..3], pixels[pixel * 4 ..][0..3]) |a, b| errors[0] += squared(a, b);
            }
            var alpha: [16]u8 = undefined;
            try encodeAlphaBlock(&samples, &encoded, .{ .effort = effort });
            try std.testing.expect(encoded[1] >> 4 != 0);
            try scalar.decodeAlphaBlock(&encoded, &alpha);
            for (samples, alpha) |a, b| errors[1] += squared(a, b);
            var red: [16]u16 = undefined;
            try encodeR11Block(&samples, &encoded, .{ .effort = effort });
            try scalar.decodeR11Block(&encoded, &red);
            for (samples, red) |a, b| errors[2] += squared((@as(u32, a) * 2047 + 127) / 255, b);
            for (errors, previous) |current, old| try std.testing.expect(current <= old);
            previous = errors;
        }
    }
}

fn squared(a: u32, b: u32) u64 {
    const difference = @as(i64, a) - b;
    return @intCast(difference * difference);
}

test "ETC and EAC writers admit exact work before preserving refused and spare storage" {
    const bounds = [_][2]u64{ .{ 9216, 1280 }, .{ 25600, 4352 }, .{ 91136, 20736 } };
    for (efforts, bounds) |effort, work| {
        try std.testing.expectEqual(work[0], fitting.colorWorkUnits(effort));
        try std.testing.expectEqual(work[1], scalar.scalarWorkUnits(effort));
        var backing: [80]u8 = @splat(0xa5);
        const texels = std.mem.bytesAsValue([16][4]u8, backing[0..64]);
        const samples = backing[0..16];
        var output: [11]u8 = @splat(0x7b);
        inline for ([_]bool{ false, true }) |r11| {
            const encode = if (r11) encodeR11Block else encodeAlphaBlock;
            try std.testing.expectError(
                error.WorkBudgetExceeded,
                encode(samples, &output, .{ .effort = effort, .maximum_work_units = work[1] - 1 }),
            );
            try std.testing.expectError(
                error.DestinationTooSmall,
                encode(samples, output[0..7], .{}),
            );
            try std.testing.expectError(error.OverlappingStorage, encode(samples, &backing, .{}));
            try std.testing.expect(std.mem.allEqual(u8, &backing, 0xa5));
            try std.testing.expect(std.mem.allEqual(u8, &output, 0x7b));
            try encode(samples, &output, .{ .effort = effort, .maximum_work_units = work[1] });
            try std.testing.expect(std.mem.allEqual(u8, output[8..], 0x7b));
            @memset(&output, 0x7b);
        }
        try std.testing.expectError(
            error.WorkBudgetExceeded,
            encodeBlock(texels, &output, .{ .effort = effort, .maximum_work_units = work[0] - 1 }),
        );
        try std.testing.expectError(
            error.DestinationTooSmall,
            encodeBlock(texels, output[0..7], .{}),
        );
        try std.testing.expectError(error.OverlappingStorage, encodeBlock(texels, &backing, .{}));
        try std.testing.expect(std.mem.allEqual(u8, &backing, 0xa5));
        try std.testing.expect(std.mem.allEqual(u8, &output, 0x7b));
        try encodeBlock(texels, &output, .{ .effort = effort, .maximum_work_units = work[0] });
        try std.testing.expect(std.mem.allEqual(u8, output[8..], 0x7b));

        // Input may occupy spare destination capacity; only the written prefix must be disjoint.
        const spare_texels = std.mem.bytesAsValue([16][4]u8, backing[8..72]);
        try encodeBlock(spare_texels, &backing, .{});
        try std.testing.expect(std.mem.allEqual(u8, backing[8..], 0xa5));
    }
}
