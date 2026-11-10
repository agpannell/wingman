//! PNG packed-sample interpretation and conversion to RGBA.

const std = @import("std");
const builtin = @import("builtin");
const png_format = @import("format.zig");
const SourceImage = @import("Source.zig");
const png_palette_vectors = @import("testdata/palette.zig");

const RgbaConverter = @This();
const Error = png_format.Error;
const PaletteIndexPolicy = png_format.PaletteIndexPolicy;
const filter_vector_lanes = std.simd.suggestVectorLength(u8) orelse 1;

/// Admitted PNG sample depth; indexed values name palette entries.
bit_depth: u8,
/// Admitted PNG color type: 0, 2, 3, 4 or 6.
color_type: u8,
/// Stored samples per pixel, including one index for indexed images.
channel_count: usize,
/// Packed bits per pixel across all stored channels.
bits_per_pixel: usize,
/// Borrowed indexed RGB entries; empty for non-indexed interpretation.
palette: []const [3]u8,
/// Borrowed indexed alpha entries, with omitted entries opaque.
palette_alpha: []const u8,
/// Optional normalized stored-depth gray transparency code.
transparent_gray: ?u16,
/// Optional normalized stored-depth truecolor transparency codes.
transparent_rgb: ?[3]u16,
/// Numeric indexed-sample admission, independent of the borrowed source facts.
palette_index_policy: PaletteIndexPolicy = .reject,

/// Copies an admitted image's sample facts while preserving its palette borrows.
pub fn init(image: SourceImage) RgbaConverter {
    return initWithPolicy(image, .reject);
}

/// Copies admitted sample facts with an explicit out-of-range index interpretation.
pub fn initWithPolicy(image: SourceImage, policy: PaletteIndexPolicy) RgbaConverter {
    return .{
        .bit_depth = image.bit_depth,
        .color_type = image.color_type,
        .channel_count = image.channel_count,
        .bits_per_pixel = image.bits_per_pixel,
        .palette = image.palette,
        .palette_alpha = image.palette_alpha,
        .transparent_gray = image.transparent_gray,
        .transparent_rgb = image.transparent_rgb,
        .palette_index_policy = policy,
    };
}

/// Expands an admitted pass row into complete-image byte or word RGBA backing. Supply checked
/// image/pass geometry, sufficient disjoint output and the exact packed row. Destination
/// coordinates and capacity are preconditions, as for convertRgbaRow. The selected palette policy
/// applies; a rejected index may leave a partial row.
pub fn convertPassRow(
    self: RgbaConverter,
    comptime Sample: type,
    rgba: []Sample,
    image_width: usize,
    pass: png_format.Pass,
    pass_width: usize,
    image_y: usize,
    packed_row: []const u8,
) Error!void {
    if (Sample != u8 and Sample != u16) @compileError("PNG output samples must be u8 or u16");
    return (if (Sample == u8) convertRgba8Samples else convertRgba16Samples)(
        self,
        rgba,
        pass_width,
        (image_y * image_width + pass.start_x) * 4,
        pass.step_x * 4,
        packed_row,
    );
}

/// Expands one reconstructed packed row into a disjoint caller RGBA prefix. `Sample` is u8 or u16;
/// word output preserves complete 16-bit samples and scales narrower samples. Row and destination
/// borrows end with this call; palette borrows last as long as the converter. Unused output
/// capacity stays unchanged. Invalid indices may leave a partially written current row. No framing,
/// filter, checksum, color transform or allocation occurs here.
pub fn convertRow(
    self: RgbaConverter,
    comptime Sample: type,
    rgba: []Sample,
    pixel_count: usize,
    packed_row: []const u8,
) (Error || error{OutputTooSmall})!void {
    if (Sample != u8 and Sample != u16) @compileError("PNG output samples must be u8 or u16");
    const output_count = std.math.mul(usize, pixel_count, 4) catch return error.InvalidPng;
    if (rgba.len < output_count) return error.OutputTooSmall;
    try self.validatePackedLength(pixel_count, packed_row.len);
    try (if (Sample == u8) convertRgba8Samples else convertRgba16Samples)(
        self,
        rgba[0..output_count],
        pixel_count,
        0,
        4,
        packed_row,
    );
}

/// Admits a complete reconstructed row under the selected palette policy. Strict rejection checks
/// active indices, ignoring packed padding; recovery accepts every index of a nonempty admitted
/// palette. Non-indexed samples need no numeric admission. Packed length remains checked. It writes
/// nothing and allocates nothing.
pub fn validateRow(self: RgbaConverter, pixel_count: usize, packed_row: []const u8) Error!void {
    try self.validatePackedLength(pixel_count, packed_row.len);
    if (self.color_type != 3) return;
    if (self.palette.len == 0) return error.InvalidPng;
    if (self.palette_index_policy == .opaque_black) return;
    if (self.bit_depth == 8) {
        for (
            packed_row[0..pixel_count],
        ) |index| if (index >= self.palette.len) return error.InvalidPng;
        return;
    }
    var samples = PackedSampleReader.init(packed_row, 0, self.bit_depth);
    for (0..pixel_count) |_| if (samples.next() >= self.palette.len) return error.InvalidPng;
}

fn validatePackedLength(self: RgbaConverter, pixel_count: usize, length: usize) Error!void {
    const required = png_format.packedRowBytes(
        pixel_count,
        self.bits_per_pixel,
    ) catch return error.InvalidPng;
    if (length < required) return error.InvalidPng;
}

/// Expands packed RGB8 at the start of rgba into the complete RGBA8 slice in place. The slice
/// contains four bytes per pixel; its first three bytes per pixel are initialized. Transparency
/// uses the admitted full sample values. No allocation or padding is needed.
pub fn expandRgb8InPlace(rgba: []u8, transparent_rgb: ?[3]u16) void {
    std.debug.assert(rgba.len % 4 == 0);
    const batch = 16;
    const rgb_lanes = batch * 3;
    const rgba_lanes = batch * 4;
    const rgb_mask = comptime blk: {
        var mask: [rgba_lanes]i32 = undefined;
        for (0..batch) |index| {
            for (0..3) |channel| mask[index * 4 + channel] = @intCast(index * 3 + channel);
            mask[index * 4 + 3] = ~@as(i32, @intCast(index));
        }
        break :blk mask;
    };
    var pixel = rgba.len / 4;
    while ((std.simd.suggestVectorLength(u8) orelse 1) >= 32 and pixel >= batch) {
        pixel -= batch;
        // Complete the overlapping input load before any destination store. Packing proceeds
        // backward, so earlier unread RGB samples stay below this batch.
        const source: @Vector(rgb_lanes, u8) = rgba[pixel * 3 ..][0..rgb_lanes].*;
        var alpha: @Vector(batch, u8) = @splat(255);
        if (transparent_rgb) |transparent| {
            const red_mask = comptime mask: {
                var value: [batch]i32 = undefined;
                for (0..batch) |index| value[index] = @intCast(index * 3);
                break :mask value;
            };
            const green_mask = comptime mask: {
                var value: [batch]i32 = undefined;
                for (0..batch) |index| value[index] = @intCast(index * 3 + 1);
                break :mask value;
            };
            const blue_mask = comptime mask: {
                var value: [batch]i32 = undefined;
                for (0..batch) |index| value[index] = @intCast(index * 3 + 2);
                break :mask value;
            };
            const red: @Vector(batch, u16) = @shuffle(u8, source, undefined, red_mask);
            const green: @Vector(batch, u16) = @shuffle(u8, source, undefined, green_mask);
            const blue: @Vector(batch, u16) = @shuffle(u8, source, undefined, blue_mask);
            // Compare at the format's full tRNS precision, including values above 255.
            const matched = (red == @as(
                @Vector(batch, u16),
                @splat(transparent[0]),
            )) & (green == @as(
                @Vector(batch, u16),
                @splat(transparent[1]),
            )) & (blue == @as(@Vector(batch, u16), @splat(transparent[2])));
            alpha = @select(u8, matched, @as(@Vector(batch, u8), @splat(0)), alpha);
        }
        const expanded = @shuffle(u8, source, alpha, rgb_mask);
        rgba[pixel * 4 ..][0..rgba_lanes].* = expanded;
    }
    while (pixel != 0) {
        pixel -= 1;
        // Load all three samples before writing. Backward expansion preserves every unread packed
        // sample, including the first pixel where input and output overlap.
        const rgb = rgba[pixel * 3 ..][0..3].*;
        rgba[pixel * 4 ..][0..4].* = .{
            rgb[0],
            rgb[1],
            rgb[2],
            if (transparent_rgb) |transparent| if (rgb[0] == transparent[0] and rgb[1] ==
                transparent[1] and rgb[2] == transparent[2]) 0 else 255 else 255,
        };
    }
}

/// Caller-owned lookup of admitted indexed RGB/alpha entries as exact RGBA8 words. Initialize
/// directly in retained or decoder-provided storage; this 1 KiB owner allocates nothing and retains
/// no source pointers. Use it for multiple rows of the image whose palette initialized it, under
/// the selected palette policy.
pub const Palette = struct {
    /// Initialized exact RGBA8 lookup entries; later entries are unavailable.
    entries: [256][4]u8,
    /// Initialized lookup length; recovery includes all 256 byte indices.
    count: usize,

    /// Combines the admitted indexed image's RGB and optional alpha entries once. Construct
    /// directly at `self`; entries beyond the admitted count stay undefined.
    pub fn init(self: *Palette, image: SourceImage) void {
        self.initWithPolicy(image, .reject);
    }

    /// Prepares admitted entries and optionally fills absent byte indices with opaque black.
    /// `count` names initialized lookup entries; source palette length remains unchanged.
    pub fn initWithPolicy(self: *Palette, image: SourceImage, policy: PaletteIndexPolicy) void {
        std.debug.assert(image.color_type == 3);
        self.count = image.palette.len;
        for (image.palette, 0..) |rgb, index| {
            self.entries[index] = .{
                rgb[0],
                rgb[1],
                rgb[2],
                if (index < image.palette_alpha.len) image.palette_alpha[index] else 255,
            };
        }
        if (policy == .opaque_black) {
            @memset(self.entries[self.count..], .{ 0, 0, 0, 255 });
            self.count = self.entries.len;
        }
    }

    /// Expands an admitted indexed row through this image's prepared RGBA8 entries. Supply matching
    /// admitted image/pass geometry, exact reconstructed packed rows, disjoint full-image output
    /// and valid destination coordinates. Invalid palette values can leave a prefix of the selected
    /// row written; publication stays fallible.
    pub fn convertPassRow(
        self: *const Palette,
        image: SourceImage,
        rgba: []u8,
        pass: png_format.Pass,
        pass_width: usize,
        image_y: usize,
        packed_row: []const u8,
    ) Error!void {
        const destination_step = pass.step_x * 4;
        var destination = (image_y * @as(usize, image.width) + pass.start_x) * 4;
        if (image.bit_depth == 8) {
            if (self.count == 256) {
                for (packed_row[0..pass_width]) |index| {
                    rgba[destination..][0..4].* = self.entries[index];
                    destination += destination_step;
                }
            } else {
                var pixel: usize = 0;
                while (filter_vector_lanes >= 32 and pass_width - pixel >= 8) : (pixel += 8) {
                    // Admit every index before loading any entry from this batch.
                    const indices: @Vector(8, u8) = packed_row[pixel..][0..8].*;
                    if (@reduce(.Max, indices) >= self.count) return error.InvalidPng;
                    inline for (0..8) |i| {
                        rgba[destination..][0..4].* = self.entries[indices[i]];
                        destination += destination_step;
                    }
                }
                for (packed_row[pixel..pass_width]) |index| {
                    if (index >= self.count) return error.InvalidPng;
                    rgba[destination..][0..4].* = self.entries[index];
                    destination += destination_step;
                }
            }
            return;
        }
        switch (image.bit_depth) {
            inline 1, 2, 4 => |depth| try convertPackedPaletteRgbaRow(
                depth,
                self,
                rgba,
                destination,
                destination_step,
                pass_width,
                packed_row,
            ),
            else => unreachable,
        }
    }
};

/// Expands a reconstructed pass row into the complete image's RGBA8 storage. Keep `image` admitted
/// and its borrowed source live; provide a disjoint row of packed samples without a filter byte,
/// with the admitted pass width and valid destination coordinates. Adam7 callers use the pass
/// geometry and reset row history between passes. Invalid palette indices report `InvalidPng` and
/// may leave a partially written row; the decoder publishes output only after every row succeeds.
pub fn convertRgbaRow(
    image: SourceImage,
    rgba: []u8,
    pass: png_format.Pass,
    pass_width: usize,
    image_y: usize,
    packed_row: []const u8,
) Error!void {
    return RgbaConverter.init(
        image,
    ).convertPassRow(u8, rgba, image.width, pass, pass_width, image_y, packed_row);
}

fn convertRgba8Samples(
    converter: RgbaConverter,
    rgba: []u8,
    pass_width: usize,
    first_destination: usize,
    destination_step: usize,
    packed_row: []const u8,
) Error!void {
    var destination = first_destination;
    if (converter.color_type == 3) {
        if (converter.bit_depth == 8) {
            // Byte indices need no bit-reader state or per-sample unpacking.
            for (packed_row[0..pass_width]) |index| {
                const palette_index: usize = index;
                if (palette_index >= converter.palette.len) {
                    if (converter.palette_index_policy == .reject or converter.palette.len == 0)
                        return error.InvalidPng;
                    rgba[destination..][0..4].* = .{ 0, 0, 0, 255 };
                    destination += destination_step;
                    continue;
                }
                const rgb = converter.palette[palette_index];
                rgba[destination..][0..4].* = .{
                    rgb[0],
                    rgb[1],
                    rgb[2],
                    if (palette_index < converter.palette_alpha.len) converter
                        .palette_alpha[palette_index] else 255,
                };
                destination += destination_step;
            }
            return;
        }
        var packed_samples = PackedSampleReader.init(packed_row, 0, converter.bit_depth);
        for (0..pass_width) |_| {
            const palette_index: usize = @intCast(packed_samples.next());
            if (palette_index >= converter.palette.len) {
                if (converter.palette_index_policy == .reject or converter.palette.len == 0)
                    return error.InvalidPng;
                rgba[destination..][0..4].* = .{ 0, 0, 0, 255 };
                destination += destination_step;
                continue;
            }
            @memcpy(rgba[destination..][0..3], converter.palette[palette_index][0..]);
            rgba[destination + 3] = if (palette_index < converter.palette_alpha.len) converter
                .palette_alpha[palette_index] else 255;
            destination += destination_step;
        }
        return;
    }

    if (converter.color_type == 6) {
        if (converter.bit_depth == 8 and destination_step == 4) {
            @memcpy(rgba[destination..][0 .. pass_width * 4], packed_row[0 .. pass_width * 4]);
            return;
        }
        var pixel: usize = 0;
        if (converter.bit_depth == 16 and destination_step == 4) {
            // Filter history retains all sample bytes; RGBA8 keeps each high byte. Full batches
            // read exactly four pixels, followed by an exact scalar tail.
            const high_bytes: @Vector(
                16,
                i32,
            ) = .{ 0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30 };
            while (pass_width - pixel >= 4) : (pixel += 4) {
                const samples: @Vector(32, u8) = packed_row[pixel * 8 ..][0..32].*;
                const stripped = @shuffle(u8, samples, undefined, high_bytes);
                rgba[destination..][0..16].* = stripped;
                destination += 16;
            }
        }
        const stride: usize = if (converter.bit_depth == 16) 8 else 4;
        while (pixel < pass_width) : (pixel += 1) {
            if (converter.bit_depth == 16) {
                const samples = packed_row[pixel * stride ..][0..8].*;
                rgba[destination..][0..4].* = .{ samples[0], samples[2], samples[4], samples[6] };
            } else {
                rgba[destination..][0..4].* = packed_row[pixel * stride ..][0..4].*;
            }
            destination += destination_step;
        }
        return;
    }

    if (destination_step == 4) {
        switch (converter.color_type) {
            0 => {
                switch (converter.bit_depth) {
                    inline 1, 2, 4, 8, 16 => |depth| convertGrayRgbaRow(
                        depth,
                        rgba,
                        destination,
                        pass_width,
                        packed_row,
                        converter.transparent_gray,
                    ),
                    else => unreachable,
                }
                return;
            },
            4 => {
                switch (converter.bit_depth) {
                    inline 8, 16 => |depth| convertGrayAlphaRgbaRow(
                        depth,
                        rgba,
                        destination,
                        pass_width,
                        packed_row,
                    ),
                    else => unreachable,
                }
                return;
            },
            2 => if (converter.bit_depth == 16) {
                convertRgb16RgbaRow(
                    rgba,
                    destination,
                    pass_width,
                    packed_row,
                    converter.transparent_rgb,
                );
                return;
            },
            else => {},
        }
    }

    const bytes_per_sample: usize = @as(usize, converter.bit_depth) / 8;
    const source_stride = converter.channel_count * bytes_per_sample;
    var source_offset: usize = 0;
    var packed_samples: PackedSampleReader = undefined;
    if (converter.color_type == 0 and converter.bit_depth < 8) {
        packed_samples = PackedSampleReader.init(packed_row, 0, converter.bit_depth);
    }
    for (0..pass_width) |_| {
        switch (converter.color_type) {
            2 => {
                const red = readSample(packed_row, source_offset, converter.bit_depth);
                const green = readSample(
                    packed_row,
                    source_offset + bytes_per_sample,
                    converter.bit_depth,
                );
                const blue = readSample(
                    packed_row,
                    source_offset + 2 * bytes_per_sample,
                    converter.bit_depth,
                );
                rgba[destination] = sampleToRgba8(red, converter.bit_depth);
                rgba[destination + 1] = sampleToRgba8(green, converter.bit_depth);
                rgba[destination + 2] = sampleToRgba8(blue, converter.bit_depth);
                rgba[destination + 3] = if (converter.transparent_rgb) |transparent| blk: {
                    break :blk if (red == transparent[0] and green == transparent[1] and blue ==
                        transparent[2]) 0 else 255;
                } else 255;
            },
            4 => {
                const gray = readSample(packed_row, source_offset, converter.bit_depth);
                const alpha = readSample(
                    packed_row,
                    source_offset + bytes_per_sample,
                    converter.bit_depth,
                );
                @memset(rgba[destination..][0..3], sampleToRgba8(gray, converter.bit_depth));
                rgba[destination + 3] = sampleToRgba8(alpha, converter.bit_depth);
            },
            0 => {
                const gray = if (converter.bit_depth < 8) packed_samples.next() else readSample(
                    packed_row,
                    source_offset,
                    converter.bit_depth,
                );
                @memset(rgba[destination..][0..3], sampleToRgba8(gray, converter.bit_depth));
                rgba[destination + 3] = if (converter.transparent_gray) |transparent| if (gray ==
                    transparent) 0 else 255 else 255;
            },
            else => unreachable,
        }
        source_offset += source_stride;
        destination += destination_step;
    }
}

/// Checks every active palette index in one admitted reconstructed pass row. Packed padding bits
/// are ignored. Non-indexed rows require no value admission here. Geometry, packed length and
/// format must come from an admitted `Source`; no framing, filter or checksum validation occurs.
/// Source bytes and palettes remain borrowed.
pub fn validatePaletteRow(
    image: SourceImage,
    pass_width: usize,
    packed_row: []const u8,
) Error!void {
    return RgbaConverter.init(image).validateRow(pass_width, packed_row);
}

/// Expands an admitted reconstructed pass row into the complete image's RGBA16 storage. Output
/// contains host-native unsigned words with unassociated alpha. Original 16-bit samples remain
/// exact; narrower samples scale by `sample * 65535 / ((1 << depth) - 1)`. Palette bytes multiply
/// by 257. Full-precision tRNS comparisons precede that scaling. Source row and destination are
/// disjoint, with the same admitted geometry and lifetime preconditions as `convertRgbaRow`. An
/// invalid index can leave a partially written row.
pub fn convertRgba16Row(
    image: SourceImage,
    rgba: []u16,
    pass: png_format.Pass,
    pass_width: usize,
    image_y: usize,
    packed_row: []const u8,
) Error!void {
    return RgbaConverter.init(
        image,
    ).convertPassRow(u16, rgba, image.width, pass, pass_width, image_y, packed_row);
}

fn convertRgba16Samples(
    converter: RgbaConverter,
    rgba: []u16,
    pass_width: usize,
    first_destination: usize,
    destination_step: usize,
    packed_row: []const u8,
) Error!void {
    var destination = first_destination;
    const bytes_per_sample: usize = @as(usize, converter.bit_depth) / 8;
    var packed_samples: PackedSampleReader = undefined;
    if (converter.color_type == 3 or converter.bit_depth < 8) packed_samples = PackedSampleReader
        .init(
        packed_row,
        0,
        converter.bit_depth,
    );
    for (0..pass_width) |pixel| {
        const offset = pixel * converter.channel_count * bytes_per_sample;
        var value: [4]u16 = undefined;
        switch (converter.color_type) {
            0 => {
                const gray = if (converter.bit_depth < 8) packed_samples.next() else readSample(
                    packed_row,
                    offset,
                    converter.bit_depth,
                );
                const wide = sampleToRgba16(gray, converter.bit_depth);
                value = .{
                    wide,
                    wide,
                    wide,
                    if (converter.transparent_gray) |key| if (gray == key) 0 else 65535 else 65535,
                };
            },
            2 => {
                const red = readSample(packed_row, offset, converter.bit_depth);
                const green = readSample(
                    packed_row,
                    offset + bytes_per_sample,
                    converter.bit_depth,
                );
                const blue = readSample(
                    packed_row,
                    offset + bytes_per_sample * 2,
                    converter.bit_depth,
                );
                value = .{
                    sampleToRgba16(red, converter.bit_depth),
                    sampleToRgba16(green, converter.bit_depth),
                    sampleToRgba16(blue, converter.bit_depth),
                    if (converter.transparent_rgb) |key| if (red == key[0] and green == key[1] and
                        blue == key[2]) 0 else 65535 else 65535,
                };
            },
            3 => {
                const index = packed_samples.next();
                if (index >= converter.palette.len) {
                    if (converter.palette_index_policy == .reject or converter.palette.len == 0)
                        return error.InvalidPng;
                    rgba[destination..][0..4].* = .{ 0, 0, 0, 65535 };
                    destination += destination_step;
                    continue;
                }
                const rgb = converter.palette[index];
                value = .{
                    @as(u16, rgb[0]) * 257,
                    @as(u16, rgb[1]) * 257,
                    @as(u16, rgb[2]) * 257,
                    if (index < converter.palette_alpha.len) @as(
                        u16,
                        converter.palette_alpha[index],
                    ) * 257 else 65535,
                };
            },
            4 => {
                const gray = sampleToRgba16(
                    readSample(packed_row, offset, converter.bit_depth),
                    converter.bit_depth,
                );
                const alpha = readSample(
                    packed_row,
                    offset + bytes_per_sample,
                    converter.bit_depth,
                );
                value = .{ gray, gray, gray, sampleToRgba16(alpha, converter.bit_depth) };
            },
            6 => {
                inline for (0..4) |channel| {
                    const sample = readSample(
                        packed_row,
                        offset + channel * bytes_per_sample,
                        converter.bit_depth,
                    );
                    value[channel] = sampleToRgba16(sample, converter.bit_depth);
                }
            },
            else => unreachable,
        }
        rgba[destination..][0..4].* = value;
        destination += destination_step;
    }
}

fn sampleToRgba16(sample: u16, depth: u8) u16 {
    return switch (depth) {
        1 => sample * 65535,
        2 => sample * 21845,
        4 => sample * 4369,
        8 => sample * 257,
        16 => sample,
        else => unreachable,
    };
}

const PackedSampleReader = struct {
    bytes: []const u8,
    byte_offset: usize,
    bit_depth: u8,
    samples_per_byte: usize,
    sample_index: usize,
    packed_byte: u8,
    mask: u8,

    fn init(bytes: []const u8, row_offset: usize, bit_depth: u8) PackedSampleReader {
        const samples_per_byte = 8 / @as(usize, bit_depth);
        return .{
            .bytes = bytes,
            .byte_offset = row_offset,
            .bit_depth = bit_depth,
            .samples_per_byte = samples_per_byte,
            .sample_index = samples_per_byte,
            .packed_byte = undefined,
            .mask = switch (bit_depth) {
                1 => 0x01,
                2 => 0x03,
                4 => 0x0f,
                8 => 0xff,
                else => unreachable,
            },
        };
    }

    fn next(self: *PackedSampleReader) u16 {
        if (self.sample_index == self.samples_per_byte) {
            self.packed_byte = self.bytes[self.byte_offset];
            self.sample_index = 0;
        }
        const shift: u3 = @intCast(
            (self.samples_per_byte - 1 - self.sample_index) * @as(usize, self.bit_depth),
        );
        const sample: u16 = @intCast((self.packed_byte >> shift) & self.mask);
        self.sample_index += 1;
        if (self.sample_index == self.samples_per_byte) self.byte_offset += 1;
        return sample;
    }
};

// Expand exactly sixteen packed samples. Every shuffle lane selects an admitted source byte;
// callers handle incomplete batches without reading row padding.
fn unpackByteSamples(comptime bit_depth: u8, input: []const u8) @Vector(16, u8) {
    const samples_per_byte = 8 / bit_depth;
    const byte_count = 16 / samples_per_byte;
    const bytes: @Vector(byte_count, u8) = input[0..byte_count].*;
    const indices: @Vector(16, i32) = comptime blk: {
        var mask: [16]i32 = undefined;
        for (&mask, 0..) |*lane, index| lane.* = @intCast(index / samples_per_byte);
        break :blk mask;
    };
    const shifts: @Vector(16, u3) = comptime blk: {
        var values: [16]u3 = undefined;
        for (&values, 0..) |*lane, index| {
            lane.* = @intCast(8 - bit_depth - index % samples_per_byte * bit_depth);
        }
        break :blk values;
    };
    const repeated = @shuffle(u8, bytes, undefined, indices);
    return (repeated >> shifts) & @as(@Vector(16, u8), @splat((1 << bit_depth) - 1));
}

fn convertGrayRgbaRow(
    comptime bit_depth: u8,
    rgba: []u8,
    destination_start: usize,
    width: usize,
    packed_row: []const u8,
    transparent: ?u16,
) void {
    const rgba_indices: @Vector(64, i32) = comptime blk: {
        var mask: [64]i32 = undefined;
        for (&mask, 0..) |*lane, index| {
            const pixel: i32 = @intCast(index / 4);
            lane.* = if (index % 4 == 3) ~pixel else pixel;
        }
        break :blk mask;
    };
    var pixel: usize = 0;
    var destination = destination_start;
    while (width - pixel >= 16) : (pixel += 16) {
        const raw: @Vector(16, u16) = if (bit_depth == 16) blk: {
            const samples: @Vector(32, u8) = packed_row[pixel * 2 ..][0..32].*;
            const high_indices: @Vector(16, i32) = comptime mask: {
                var indices: [16]i32 = undefined;
                for (&indices, 0..) |*lane, index| lane.* = @intCast(index * 2);
                break :mask indices;
            };
            const high: @Vector(16, u16) = @shuffle(u8, samples, undefined, high_indices);
            const low_indices = high_indices + @as(@Vector(16, i32), @splat(1));
            const low: @Vector(16, u16) = @shuffle(u8, samples, undefined, low_indices);
            break :blk (high << @splat(8)) | low;
        } else unpackByteSamples(
            bit_depth,
            packed_row[png_format.packedSamplePosition(pixel, bit_depth).byte_index..],
        );
        const scaled = if (bit_depth == 16) raw >> @splat(
            8,
        ) else raw * @as(@Vector(16, u16), @splat(255 / ((1 << bit_depth) - 1)));
        const gray: @Vector(16, u8) = @intCast(scaled);
        const alpha: @Vector(
            16,
            u8,
        ) = if (transparent) |key| @select(
            u8,
            raw == @as(@Vector(16, u16), @splat(key)),
            @as(@Vector(16, u8), @splat(0)),
            @as(@Vector(16, u8), @splat(255)),
        ) else @splat(255);
        rgba[destination..][0..64].* = @shuffle(u8, gray, alpha, rgba_indices);
        destination += 64;
    }
    while (pixel < width) : (pixel += 1) {
        const sample: u16 = if (bit_depth < 8) blk: {
            const position = png_format.packedSamplePosition(pixel, bit_depth);
            break :blk (packed_row[position.byte_index] >> position.shift) & ((1 << bit_depth) - 1);
        } else if (bit_depth == 8) packed_row[pixel] else std.mem.readInt(
            u16,
            packed_row[pixel * 2 ..][0..2],
            .big,
        );
        const gray = sampleToRgba8(sample, bit_depth);
        const alpha: u8 = if (transparent) |key| if (sample == key) 0 else 255 else 255;
        rgba[destination..][0..4].* = .{ gray, gray, gray, alpha };
        destination += 4;
    }
}

fn convertGrayAlphaRgbaRow(
    comptime bit_depth: u8,
    rgba: []u8,
    destination_start: usize,
    width: usize,
    packed_row: []const u8,
) void {
    const stride = bit_depth / 4;
    const indices: @Vector(32, i32) = comptime blk: {
        var mask: [32]i32 = undefined;
        for (&mask, 0..) |*lane, index| {
            const channel_offset = if (index % 4 == 3) bit_depth / 8 else @as(usize, 0);
            lane.* = @intCast(index / 4 * stride + channel_offset);
        }
        break :blk mask;
    };
    var pixel: usize = 0;
    var destination = destination_start;
    while (width - pixel >= 8) : (pixel += 8) {
        const samples: @Vector(8 * stride, u8) = packed_row[pixel * stride ..][0 .. 8 * stride].*;
        rgba[destination..][0..32].* = @shuffle(u8, samples, undefined, indices);
        destination += 32;
    }
    while (pixel < width) : (pixel += 1) {
        const samples = packed_row[pixel * stride ..][0..stride];
        rgba[destination..][0..4].* = .{
            samples[0],
            samples[0],
            samples[0],
            samples[bit_depth / 8],
        };
        destination += 4;
    }
}

fn convertRgb16RgbaRow(
    rgba: []u8,
    destination_start: usize,
    width: usize,
    packed_row: []const u8,
    transparent: ?[3]u16,
) void {
    const indices: @Vector(
        16,
        i32,
    ) = .{ 0, 2, 4, -1, 6, 8, 10, -1, 12, 14, 16, -1, 18, 20, 22, -1 };
    var pixel: usize = 0;
    var destination = destination_start;
    while (width - pixel >= 4) : (pixel += 4) {
        const samples: @Vector(24, u8) = packed_row[pixel * 6 ..][0..24].*;
        var output = @shuffle(u8, samples, @as(@Vector(24, u8), @splat(255)), indices);
        if (transparent) |key| {
            inline for (0..4) |i| {
                const red = @as(u16, samples[i * 6]) << 8 | samples[i * 6 + 1];
                const green = @as(u16, samples[i * 6 + 2]) << 8 | samples[i * 6 + 3];
                const blue = @as(u16, samples[i * 6 + 4]) << 8 | samples[i * 6 + 5];
                output[i * 4 + 3] = if (red == key[0] and green == key[1] and blue == key[2])
                    0
                else
                    255;
            }
        }
        rgba[destination..][0..16].* = output;
        destination += 16;
    }
    while (pixel < width) : (pixel += 1) {
        const samples = packed_row[pixel * 6 ..][0..6];
        const red = std.mem.readInt(u16, samples[0..2], .big);
        const green = std.mem.readInt(u16, samples[2..4], .big);
        const blue = std.mem.readInt(u16, samples[4..6], .big);
        const alpha: u8 = if (transparent) |key| if (red == key[0] and green == key[1] and blue ==
            key[2]) 0 else 255 else 255;
        rgba[destination..][0..4].* = .{ samples[0], samples[2], samples[4], alpha };
        destination += 4;
    }
}

fn convertPackedPaletteRgbaRow(
    comptime bit_depth: u8,
    palette: *const Palette,
    rgba: []u8,
    destination_start: usize,
    destination_step: usize,
    width: usize,
    packed_row: []const u8,
) Error!void {
    const per_byte = 8 / bit_depth;
    var pixel: usize = 0;
    var destination = destination_start;
    if (bit_depth <= 2 and destination_step == 4 and palette.count == 1 << bit_depth) {
        // Native word loads and stores preserve the palette bytes on either endian. This batch
        // writes only sixteen complete pixels within the admitted row.
        const a: @Vector(
            16,
            u32,
        ) = @splat(@as(*align(1) const u32, @ptrCast(&palette.entries[0])).*);
        const b: @Vector(
            16,
            u32,
        ) = @splat(@as(*align(1) const u32, @ptrCast(&palette.entries[1])).*);
        while (width - pixel >= 16) : (pixel += 16) {
            const indices = unpackByteSamples(
                bit_depth,
                packed_row[png_format.packedSamplePosition(pixel, bit_depth).byte_index..],
            );
            const low_bit_set = (indices & @as(
                @Vector(16, u8),
                @splat(1),
            )) != @as(@Vector(16, u8), @splat(0));
            const first = @select(u32, low_bit_set, b, a);
            const words = if (bit_depth == 1) first else blk: {
                const c: @Vector(
                    16,
                    u32,
                ) = @splat(@as(*align(1) const u32, @ptrCast(&palette.entries[2])).*);
                const d: @Vector(
                    16,
                    u32,
                ) = @splat(@as(*align(1) const u32, @ptrCast(&palette.entries[3])).*);
                const second = @select(u32, low_bit_set, d, c);
                break :blk @select(u32, indices >= @as(@Vector(16, u8), @splat(2)), second, first);
            };
            @as(*align(1) @Vector(16, u32), @ptrCast(rgba[destination..][0..64])).* = words;
            destination += 64;
        }
    }
    while (width - pixel >= per_byte) : (pixel += per_byte) {
        const byte = packed_row[pixel / per_byte];
        inline for (0..per_byte) |i| {
            const index = (byte >> (8 - bit_depth - i * bit_depth)) & ((1 << bit_depth) - 1);
            if (index >= palette.count) return error.InvalidPng;
            rgba[destination..][0..4].* = palette.entries[index];
            destination += destination_step;
        }
    }
    while (pixel < width) : (pixel += 1) {
        const shift: u3 = @intCast(8 - bit_depth - pixel % per_byte * bit_depth);
        const index = (packed_row[pixel / per_byte] >> shift) & ((1 << bit_depth) - 1);
        if (index >= palette.count) return error.InvalidPng;
        rgba[destination..][0..4].* = palette.entries[index];
        destination += destination_step;
    }
}

fn readSample(bytes: []const u8, offset: usize, bit_depth: u8) u16 {
    return switch (bit_depth) {
        8 => bytes[offset],
        16 => std.mem.readInt(u16, bytes[offset..][0..2], .big),
        else => unreachable,
    };
}

fn sampleToRgba8(sample: u16, bit_depth: u8) u8 {
    return switch (bit_depth) {
        1 => @intCast(sample * 255),
        2 => @intCast(sample * 85),
        4 => @intCast(sample * 17),
        8 => @intCast(sample),
        16 => @intCast(sample >> 8),
        else => unreachable,
    };
}

// These descriptors isolate reconstructed-row conversion from framing admission. Inputs and
// expected RGBA samples are authored independently of the conversion helpers.
fn conversionTestImage(width: usize, bit_depth: u8, color_type: u8) SourceImage {
    const channels: usize = switch (color_type) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => unreachable,
    };
    const bits = channels * bit_depth;
    const row_bytes = (width * bits + 7) / 8;
    return .{
        .width = @intCast(width),
        .height = 1,
        .canvas_width = @intCast(width),
        .canvas_height = 1,
        .bit_depth = bit_depth,
        .color_type = color_type,
        .channel_count = channels,
        .interlace_method = 0,
        .palette = &.{},
        .palette_alpha = &.{},
        .transparent_gray = null,
        .transparent_rgb = null,
        .bits_per_pixel = bits,
        .packed_row_bytes = row_bytes,
        .filtered_byte_count = row_bytes + 1,
        .record_count = 0,
        .metadata_bytes = 0,
        .image_data = .{
            .source = &.{},
            .first = &.{},
            .first_offset = 0,
            .after_last = 0,
            .multiple = false,
            .byte_count = 0,
        },
    };
}

fn checkSampleConversionBounds(source: []u8, destination: []u8, expected: []u8) !void {
    const allocator = std.testing.allocator;
    const original = try allocator.alloc(u8, source.len);
    defer allocator.free(original);
    const table = try allocator.create(Palette);
    defer allocator.destroy(table);
    const palette = try allocator.alloc([3]u8, 256);
    defer allocator.free(palette);
    const alpha = try allocator.alloc(u8, 253);
    defer allocator.free(alpha);
    for (palette, 0..) |*rgb, i| {
        rgb.* = .{ @truncate(i * 29 + 3), @truncate(i * 47 + 7), @truncate(i * 61 + 11) };
    }
    for (alpha, 0..) |*value, i| value.* = @truncate(i * 43);
    const formats = [_][2]u8{
        .{ 0, 1 },
        .{ 0, 2 },
        .{ 0, 4 },
        .{ 0, 8 },
        .{ 0, 16 },
        .{ 2, 8 },
        .{ 2, 16 },
        .{ 3, 1 },
        .{ 3, 2 },
        .{ 3, 4 },
        .{ 3, 8 },
        .{ 4, 8 },
        .{ 4, 16 },
        .{ 6, 8 },
        .{ 6, 16 },
    };
    const passes = [_]png_format.Pass{
        png_format.sequential_pass,
        png_format.adam7_passes[5],
        png_format.adam7_passes[3],
        png_format.adam7_passes[1],
    };
    for (formats) |format| {
        const color_type = format[0];
        const bit_depth = format[1];
        const maximum = (@as(u32, 1) << @intCast(bit_depth)) - 1;
        const gray_key: u16 = if (bit_depth == 16) 0x1234 else 1;
        const rgb_key: [3]u16 = if (bit_depth == 16) .{
            0x1234, 0x5678,
            0x9abc,
        } else .{ 17, 34, 51 };
        for ([_]bool{ false, true }) |transparency_or_partial| {
            for (passes) |pass| {
                for (1..98) |width| {
                    const image_width = pass.start_x + (width - 1) * pass.step_x + 1;
                    var image = conversionTestImage(image_width, bit_depth, color_type);
                    image.interlace_method = @intFromBool(pass.step_x != 1);
                    if (transparency_or_partial and color_type == 0) image.transparent_gray =
                        gray_key;
                    if (transparency_or_partial and color_type == 2) image.transparent_rgb =
                        rgb_key;
                    if (color_type == 3) {
                        const count = @as(usize, 1) << @intCast(bit_depth);
                        image.palette = palette[0 .. count - @intFromBool(transparency_or_partial)];
                        image.palette_alpha = alpha[0..image.palette.len -| 3];
                        table.init(image);
                    }
                    const packed_length = (width * image.bits_per_pixel + 7) / 8;
                    const rgba_length = image_width * 4;
                    for ([_]bool{ false, true }) |at_end| {
                        @memset(source, 0xd5);
                        @memset(destination, 0xd5);
                        @memset(expected, 0xd5);
                        const source_offset = if (at_end) source.len - packed_length else 1;
                        const output_offset = if (at_end) destination.len - rgba_length else 3;
                        const samples_bytes = source[source_offset..][0..packed_length];
                        @memset(samples_bytes, 0);
                        const rgba = destination[output_offset..][0..rgba_length];
                        for (0..width) |pixel| {
                            var samples: [4]u16 = @splat(0);
                            for (samples[0..image.channel_count], 0..) |*sample, channel| {
                                sample.* = @intCast((pixel * 1009 + channel * 703 + 13) & maximum);
                                if (color_type == 3) sample.* = @intCast(pixel % image.palette.len);
                                if (color_type == 0 and pixel % 4 >= 2) sample.* = gray_key ^ @as(
                                    u16,
                                    @intFromBool(pixel % 4 == 3),
                                );
                                if (color_type == 2 and pixel % 4 >= 2) {
                                    sample.* = rgb_key[channel];
                                    if (channel == 0 and pixel % 4 == 3) sample.* ^= 1;
                                }
                                const ordinal = pixel * image.channel_count + channel;
                                if (bit_depth < 8) {
                                    const shift: u3 = @intCast(
                                        8 - bit_depth - ordinal * bit_depth % 8,
                                    );
                                    samples_bytes[ordinal * bit_depth / 8] |= @as(
                                        u8,
                                        @intCast(sample.*),
                                    ) << shift;
                                } else if (bit_depth == 8) {
                                    samples_bytes[ordinal] = @intCast(sample.*);
                                } else {
                                    std.mem.writeInt(
                                        u16,
                                        samples_bytes[ordinal * 2 ..][0..2],
                                        sample.*,
                                        .big,
                                    );
                                }
                            }
                            var converted: [4]u8 = @splat(255);
                            for (samples[0..image.channel_count], 0..) |sample, channel| {
                                converted[channel] = switch (bit_depth) {
                                    1 => @intCast(sample * 255),
                                    2 => @intCast(sample * 85),
                                    4 => @intCast(sample * 17),
                                    8 => @intCast(sample),
                                    16 => @intCast(sample >> 8),
                                    else => unreachable,
                                };
                            }
                            const expected_pixel: [4]u8 = switch (color_type) {
                                0 => .{
                                    converted[0],
                                    converted[0],
                                    converted[0],
                                    if (transparency_or_partial and samples[0] == gray_key)
                                        0
                                    else
                                        255,
                                },
                                2 => .{
                                    converted[0],
                                    converted[1],
                                    converted[2],
                                    if (transparency_or_partial and samples[0] == rgb_key[0] and
                                        samples[1] == rgb_key[1] and samples[2] == rgb_key[2])
                                        0
                                    else
                                        255,
                                },
                                3 => .{
                                    palette[samples[0]][0],
                                    palette[samples[0]][1],
                                    palette[samples[0]][2],
                                    if (samples[0] < image.palette_alpha.len)
                                        alpha[samples[0]]
                                    else
                                        255,
                                },
                                4 => .{ converted[0], converted[0], converted[0], converted[1] },
                                6 => converted,
                                else => unreachable,
                            };
                            const target = output_offset + (pass.start_x + pixel * pass.step_x) * 4;
                            expected[target..][0..4].* = expected_pixel;
                        }
                        @memcpy(original, source);
                        try convertRgbaRow(image, rgba, pass, width, 0, samples_bytes);
                        try std.testing.expectEqualSlices(u8, expected, destination);
                        try std.testing.expectEqualSlices(u8, original, source);
                        if (color_type == 3) {
                            @memset(destination, 0xd5);
                            try table.convertPassRow(image, rgba, pass, width, 0, samples_bytes);
                            try std.testing.expectEqualSlices(u8, expected, destination);
                            try std.testing.expectEqualSlices(u8, original, source);
                        }
                    }
                }
            }
        }
    }
}

test "sample format packed length admits byte-fit geometry beyond intermediate bit arithmetic" {
    const converter: RgbaConverter = .{
        .bit_depth = 4,
        .color_type = 0,
        .channel_count = 1,
        .bits_per_pixel = 4,
        .palette = &.{},
        .palette_alpha = &.{},
        .transparent_gray = null,
        .transparent_rgb = null,
    };
    // Validate counts directly without reserving half a GiB of fixture or output storage.
    try converter.validatePackedLength(0x3fff_ffff, 536870912);
    try std.testing.expectError(
        error.InvalidPng,
        converter.validatePackedLength(0x3fff_ffff, 536870911),
    );
    var wide = converter;
    wide.bit_depth = 16;
    wide.bits_per_pixel = 16;
    try std.testing.expectError(
        error.InvalidPng,
        wide.validatePackedLength(std.math.maxInt(usize), std.math.maxInt(usize)),
    );
}

test "sample format row prefixes preserve independent packed palette bytes words and failures" {
    const palette = [_][3]u8{.{ 1, 2, 3 }};
    const alpha = [_]u8{17};
    const converter: RgbaConverter = .{
        .bit_depth = 1,
        .color_type = 3,
        .channel_count = 1,
        .bits_per_pixel = 1,
        .palette = &palette,
        .palette_alpha = &alpha,
        .transparent_gray = null,
        .transparent_rgb = null,
    };
    var bytes: [9]u8 = @splat(0xa5);
    var words: [9]u16 = @splat(0xa5a5);
    // Active high bit is zero; nonzero packed padding is outside pixel meaning.
    try converter.convertRow(u8, &bytes, 1, &.{0x7f});
    try converter.convertRow(u16, &words, 1, &.{0x7f});
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 17 }, bytes[0..4]);
    try std.testing.expectEqualSlices(u16, &.{ 257, 514, 771, 4369 }, words[0..4]);
    for (bytes[4..]) |value| try std.testing.expectEqual(0xa5, value);
    for (words[4..]) |value| try std.testing.expectEqual(0xa5a5, value);
    @memset(&bytes, 0xa5);
    try std.testing.expectError(
        error.OutputTooSmall,
        converter.convertRow(u8, bytes[0..3], 1, &.{0}),
    );
    try std.testing.expectError(error.InvalidPng, converter.convertRow(u8, &bytes, 1, &.{}));
    for (bytes) |value| try std.testing.expectEqual(0xa5, value);
    try std.testing.expectError(error.InvalidPng, converter.validateRow(1, &.{0x80}));
    try std.testing.expectError(error.InvalidPng, converter.convertRow(u8, &bytes, 2, &.{0x40}));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 17 }, bytes[0..4]);
    for (bytes[4..]) |value| try std.testing.expectEqual(0xa5, value);
    try converter.convertRow(u8, &.{}, 0, &.{});
    try converter.convertRow(u16, &.{}, 0, &.{});
}

test "palette recovery preserves valid transparency and expands absent entries to opaque black" {
    const fixtures = png_palette_vectors;
    const allocator = std.testing.allocator;
    const prepared = try allocator.create(Palette);
    defer allocator.destroy(prepared);
    const rows = [_][]const u8{ &.{0x5f}, &.{0x33}, &.{ 0x0f, 0x0f }, &.{ 0, 255, 0, 255 } };
    const expected8 = [_]u8{ 13, 29, 47, 17, 0, 0, 0, 255, 13, 29, 47, 17, 0, 0, 0, 255 };
    const expected16 = [_]u16{
        3341, 7453, 12079, 4369, 0, 0, 0, 65535, 3341, 7453, 12079, 4369, 0, 0, 0, 65535,
    };
    for (rows, 0..) |packed_row, index| {
        const image = try SourceImage.open(
            fixtures.sources[index * 2],
            .{ .maximum_source_extent = 17 },
        );
        const strict = RgbaConverter.init(image);
        const recovery = RgbaConverter.initWithPolicy(image, .opaque_black);
        try std.testing.expectError(error.InvalidPng, strict.validateRow(4, packed_row));
        try recovery.validateRow(4, packed_row);
        var bytes: [19]u8 = @splat(0xa5);
        var words: [19]u16 = @splat(0xa5a5);
        try recovery.convertRow(u8, bytes[1..], 4, packed_row);
        try recovery.convertRow(u16, words[1..], 4, packed_row);
        try std.testing.expectEqualSlices(u8, &expected8, bytes[1..17]);
        try std.testing.expectEqualSlices(u16, &expected16, words[1..17]);
        try std.testing.expectEqual(0xa5, bytes[0]);
        try std.testing.expectEqual(0xa5a5, words[0]);
        for (bytes[17..]) |value| try std.testing.expectEqual(0xa5, value);
        for (words[17..]) |value| try std.testing.expectEqual(0xa5a5, value);
        prepared.initWithPolicy(image, .opaque_black);
        try std.testing.expectEqual(256, prepared.count);
        @memset(&bytes, 0xa5);
        try prepared.convertPassRow(
            image,
            bytes[1..],
            png_format.sequential_pass,
            4,
            0,
            packed_row,
        );
        try std.testing.expectEqualSlices(u8, &expected8, bytes[1..17]);
        try std.testing.expectEqual(0xa5, bytes[0]);
        for (bytes[17..]) |value| try std.testing.expectEqual(0xa5, value);
        prepared.init(image);
        try std.testing.expectEqual(1, prepared.count);
        try std.testing.expectError(
            error.InvalidPng,
            prepared.convertPassRow(
                image,
                bytes[1..],
                png_format.sequential_pass,
                4,
                0,
                packed_row,
            ),
        );
        var missing = recovery;
        missing.palette = &.{};
        try std.testing.expectError(error.InvalidPng, missing.validateRow(4, packed_row));
        try std.testing.expectError(
            error.InvalidPng,
            missing.convertRow(u8, &bytes, 4, packed_row),
        );
        try std.testing.expectError(error.InvalidPng, recovery.validateRow(9, &.{}));
    }
}

test "word samples scale every supported input value across the complete range" {
    for ([_]u8{ 1, 2, 4, 8, 16 }) |depth| {
        const maximum = (@as(u32, 1) << @intCast(depth)) - 1;
        for (0..maximum + 1) |value| {
            const expected: u16 = @intCast(@as(u32, @intCast(value)) * 65535 / maximum);
            try std.testing.expectEqual(expected, sampleToRgba16(@intCast(value), depth));
        }
    }
}

test "sample conversion preserves full transparency, scatter, tails and byte bounds" {
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 4096);
    defer allocator.free(source);
    const destination = try allocator.alloc(u8, source.len);
    defer allocator.free(destination);
    const expected = try allocator.alloc(u8, source.len);
    defer allocator.free(expected);
    try checkSampleConversionBounds(source, destination, expected);
}

test "packed and byte palette batches reject missing entries at every sample position" {
    const allocator = std.testing.allocator;
    const table = try allocator.create(Palette);
    defer allocator.destroy(table);
    const palette = try allocator.alloc([3]u8, 173);
    defer allocator.free(palette);
    @memset(palette, .{ 17, 34, 51 });
    const backing = try allocator.alloc(u8, 256);
    defer allocator.free(backing);
    for ([_]u8{ 1, 2, 4, 8 }) |depth| {
        const count: usize = if (depth == 8) 173 else (@as(usize, 1) << @intCast(depth)) - 1;
        var image = conversionTestImage(33, depth, 3);
        image.palette = palette[0..count];
        table.init(image);
        for (0..33) |bad_pixel| {
            var samples_bytes: [33]u8 = @splat(0);
            const shift: u3 = @intCast(8 - depth - bad_pixel * depth % 8);
            samples_bytes[bad_pixel * depth / 8] = @as(u8, @intCast(count)) << shift;
            const original = samples_bytes;
            try std.testing.expectError(
                error.InvalidPng,
                validatePaletteRow(image, 33, &samples_bytes),
            );
            for ([_]bool{ false, true }) |prepared| {
                @memset(backing, 0xd5);
                const rgba = backing[31..][0 .. 33 * 4];
                const row = samples_bytes[0..image.packed_row_bytes];
                const result = if (prepared) table.convertPassRow(
                    image,
                    rgba,
                    png_format.sequential_pass,
                    33,
                    0,
                    row,
                ) else convertRgbaRow(image, rgba, png_format.sequential_pass, 33, 0, row);
                try std.testing.expectError(error.InvalidPng, result);
                try std.testing.expectEqualSlices(u8, &original, &samples_bytes);
                for (backing[0..31]) |byte| try std.testing.expectEqual(0xd5, byte);
                for (backing[31 + rgba.len ..]) |byte| try std.testing.expectEqual(0xd5, byte);
            }
        }
    }
    // Only the first sample is active. All padding bits encode missing entries but do not
    // participate in palette validation or expansion.
    for ([_]u8{ 1, 2, 4 }) |depth| {
        var image = conversionTestImage(1, depth, 3);
        image.palette = palette[0..1];
        const row = [_]u8{@as(u8, 0xff) >> @as(u3, @intCast(depth))};
        try validatePaletteRow(image, 1, &row);
        var words: [4]u16 = undefined;
        try convertRgba16Row(image, &words, png_format.sequential_pass, 1, 0, &row);
        try std.testing.expectEqualSlices(u16, &.{ 17 * 257, 34 * 257, 51 * 257, 65535 }, &words);
    }
}

test "sample conversion stays between inaccessible pages" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const posix = std.posix;
    const page_size = std.heap.pageSize();
    const memory = try posix.mmap(
        null,
        9 * page_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer posix.munmap(memory);
    for ([_]usize{ 0, 2, 3, 5, 6, 8 }) |page| {
        try std.testing.expectEqual(
            .SUCCESS,
            posix.errno(std.os.linux.mprotect(memory.ptr + page * page_size, page_size, .{})),
        );
    }
    const source = memory[page_size .. 2 * page_size];
    const preceding = memory[4 * page_size .. 5 * page_size];
    const destination = memory[7 * page_size .. 8 * page_size];
    const expected = try std.testing.allocator.alloc(u8, page_size);
    defer std.testing.allocator.free(expected);
    var random: std.Random.DefaultPrng = .init(0x706e675f67756172);
    random.random().bytes(source);
    random.random().bytes(preceding);
    try checkSampleConversionBounds(source, destination, expected);
}

test "RGB expansion preserves partial batches, unaligned owners and full transparency" {
    const allocator = std.testing.allocator;
    const maximum_pixels = 193;
    const backing = try allocator.alloc(u8, maximum_pixels * 4 + 96);
    defer allocator.free(backing);
    const expected = try allocator.alloc(u8, backing.len);
    defer allocator.free(expected);
    const samples = [_][3]u8{ .{ 0, 0, 0 }, .{ 255, 255, 255 }, .{ 17, 34, 51 }, .{ 17, 34, 52 } };
    // Expected alpha is independent of the expansion masks and lane arithmetic.
    const controls = [_]struct {
        transparent: ?[3]u16,
        alpha: [4]u8,
    }{
        .{ .transparent = null, .alpha = .{ 255, 255, 255, 255 } },
        .{ .transparent = .{ 0, 0, 0 }, .alpha = .{ 0, 255, 255, 255 } },
        .{ .transparent = .{ 255, 255, 255 }, .alpha = .{ 255, 0, 255, 255 } },
        .{ .transparent = .{ 17, 34, 51 }, .alpha = .{ 255, 255, 0, 255 } },
        .{ .transparent = .{ 273, 34, 51 }, .alpha = .{ 255, 255, 255, 255 } },
    };
    for (0..maximum_pixels + 1) |count| {
        for ([_]usize{ 0, 1, 3, 7, 15, 31 }) |offset| {
            for (controls) |control| {
                @memset(backing, 0xd5);
                @memset(expected, 0xd5);
                const begin = 32 + offset;
                const rgba = backing[begin..][0 .. count * 4];
                for (0..count) |pixel| {
                    const sample = pixel % samples.len;
                    rgba[pixel * 3 ..][0..3].* = samples[sample];
                    expected[begin + pixel * 4 ..][0..4].* = .{
                        samples[sample][0],
                        samples[sample][1],
                        samples[sample][2],
                        control.alpha[sample],
                    };
                }
                expandRgb8InPlace(rgba, control.transparent);
                try std.testing.expectEqualSlices(u8, expected, backing);
            }
        }
    }
}
