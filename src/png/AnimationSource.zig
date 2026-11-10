//! CRC-admitted APNG structure and frame-local compressed sources.

const std = @import("std");
const png_animation_vectors = @import("testdata/animation.zig");
const png_metadata_vectors = @import("testdata/metadata.zig");
const SourceImage = @import("Source.zig");
const ImageData = @import("ImageData.zig");
const format = @import("format.zig");
const Limits = @import("Limits.zig");
const FrameControl = @import("FrameControl.zig");
const animation = @import("animation.zig");
const Error = format.Error || error{
    OutputTooSmall,
    NotAnimatedPng,
    InvalidApng,
    FrameLimitExceeded,
};
const AnimationSource = @This();

/// Admitted canvas geometry, color layout, metadata presence and default IDAT stream.
default_image: SourceImage,
/// Exactly this many fcTL records and framed compressed streams occur.
frame_count: u32,
/// Zero loops indefinitely; a finite count leaves the last displayed frame in place.
play_count: u32,
/// True when the default IDAT raster is the first animation frame.
default_is_frame: bool,
/// Sum of the local rectangle pixel counts, not full-canvas copies per frame.
total_frame_pixels: usize,
/// Largest frame rectangle, useful for reserving composition backup.
maximum_frame_pixels: usize,
/// Exact filtered bytes across every frame, including Adam7 pass filters.
filtered_bytes: usize,
/// Sum of compressed frame payload bytes, excluding fdAT sequence words.
compressed_bytes: usize,

/// Checks the complete PNG and animation framing before publishing a borrowed view. Sequence words
/// start at zero and increase across fcTL/fdAT. Sequence numbers, dimensions, offsets and declared
/// counts use PNG's 31-bit bound. Split or empty frame-data fields and intervening ancillary chunks
/// remain admissible. Optional metadata is exposed without applying profiles or aspect.
pub fn open(source: []const u8, options: Options) Error!AnimationSource {
    try format.admitWork(options.limits, source.len);
    const default_image = try SourceImage.open(
        source,
        .{
            .maximum_encoded_bytes = options.maximum_encoded_bytes,
            .maximum_source_extent = options.maximum_canvas_extent,
            .maximum_records = options.limits.maximum_records,
            .maximum_metadata_bytes = options.limits.maximum_metadata_bytes,
        },
    );
    var chunk_cursor: ChunkIterator = .{ .source = source };
    var declared: ?struct { frames: u32, plays: u32 } = null;
    var count: u32 = 0;
    var expected_sequence: u64 = 0;
    var saw_idat = false;
    var active: ?FrameControl = null;
    var active_idat = false;
    var active_data = false;
    var default_is_frame = false;
    var pixels_total: usize = 0;
    var maximum_pixels: usize = 0;
    var filtered_total: usize = 0;
    var compressed_total: usize = 0;

    // Source.open has checked chunk framing and CRCs. A frame control before IDAT makes the default
    // image the first frame; otherwise IDAT is a separate poster and every animation frame obtains
    // its data from fdAT chunks.
    while (chunk_cursor.next()) |chunk| {
        if (std.mem.eql(u8, chunk.kind, "acTL")) {
            if (declared != null or saw_idat or chunk.data.len != 8) return error.InvalidApng;
            const frame_count = try readPngInteger(chunk.data, 0);
            const plays = try readPngInteger(chunk.data, 4);
            if (frame_count == 0) return error.InvalidApng;
            if (frame_count > options.maximum_frames) return error.FrameLimitExceeded;
            declared = .{ .frames = frame_count, .plays = plays };
        } else if (std.mem.eql(u8, chunk.kind, "fcTL")) {
            const declaration = declared orelse return error.InvalidApng;
            if (active != null and !active_data) return error.InvalidApng;
            if (count == declaration.frames) return error.InvalidApng;
            if (count == options.maximum_frames) return error.FrameLimitExceeded;
            const control = try parseControl(chunk.data, default_image.width, default_image.height);
            try acceptSequence(control.sequence, &expected_sequence);
            active_idat = !saw_idat;
            if (active_idat and (count != 0 or control.x != 0 or control.y != 0 or control.width !=
                default_image.width or control.height != default_image.height))
                return error.InvalidApng;
            if (active_idat) default_is_frame = true;
            active = control;
            active_data = false;
            count += 1;
            const frame_pixels = std.math.mul(
                usize,
                control.width,
                control.height,
            ) catch return error.PixelBudgetExceeded;
            pixels_total = std.math.add(
                usize,
                pixels_total,
                frame_pixels,
            ) catch return error.PixelBudgetExceeded;
            maximum_pixels = @max(maximum_pixels, frame_pixels);
            const image = try frameImage(
                default_image,
                control.width,
                control.height,
                default_image.image_data,
            );
            filtered_total = std.math.add(
                usize,
                filtered_total,
                image.filtered_byte_count,
            ) catch return error.WorkBudgetExceeded;
        } else if (std.mem.eql(u8, chunk.kind, "IDAT")) {
            saw_idat = true;
            if (active != null) {
                if (!active_idat) return error.InvalidApng;
                active_data = true;
                compressed_total = std.math.add(
                    usize,
                    compressed_total,
                    chunk.data.len,
                ) catch return error.WorkBudgetExceeded;
            }
        } else if (std.mem.eql(u8, chunk.kind, "fdAT")) {
            if (!saw_idat or active == null or active_idat or chunk.data.len < 4)
                return error.InvalidApng;
            try acceptSequence(try readPngInteger(chunk.data, 0), &expected_sequence);
            active_data = true;
            compressed_total = std.math.add(
                usize,
                compressed_total,
                chunk.data.len - 4,
            ) catch return error.WorkBudgetExceeded;
        }
    }
    const declaration = declared orelse return error.NotAnimatedPng;
    if (count != declaration.frames or active == null or !active_data) return error.InvalidApng;
    return .{
        .default_image = default_image,
        .frame_count = count,
        .play_count = declaration.plays,
        .default_is_frame = default_is_frame,
        .total_frame_pixels = pixels_total,
        .maximum_frame_pixels = maximum_pixels,
        .filtered_bytes = filtered_total,
        .compressed_bytes = compressed_total,
    };
}

/// Replays frames in source order without allocating or concatenating compressed data.
pub fn frames(self: AnimationSource) Iterator {
    return .{
        .chunks = .{ .source = self.default_image.image_data.source },
        .default_image = self.default_image,
    };
}

fn frameImage(
    self: SourceImage,
    width: u32,
    height: u32,
    data: ImageData,
) format.Error!SourceImage {
    if (width == 0 or height == 0 or width > self.width or height > self.height)
        return error.InvalidPng;
    const layout = try format.packedLayout(
        width,
        height,
        self.bits_per_pixel,
        self.interlace_method,
    );
    var frame = self;
    frame.width = width;
    frame.height = height;
    frame.packed_row_bytes = layout.row_bytes;
    frame.filtered_byte_count = layout.filtered_bytes;
    frame.image_data = data;
    return frame;
}

/// Small replay cursor over an immutable admitted animation; no inflater or pixels are retained.
pub const Iterator = struct {
    /// Checked source cursor; mutate it only through `next`.
    chunks: ChunkIterator,
    /// Borrowed admitted color layout and complete canvas geometry.
    default_image: SourceImage,
    /// Next published frame ordinal.
    index: u32 = 0,
    /// FrameControl whose stream is being collected by this replay.
    control: ?FrameControl = null,
    /// Borrowed payload spans of the pending control.
    data: ?ImageData = null,

    /// Borrows the next frame, or null after the declared frames. AnimationSource admission has
    /// proved control/geometry/range invariants; no new syntax or pixel promise is made.
    pub fn next(self: *Iterator) ?Frame {
        while (self.chunks.next()) |chunk| {
            if (std.mem.eql(u8, chunk.kind, "fcTL")) {
                const previous = self.take();
                // Save the next checked control before returning the completed frame, so the next
                // call continues after this chunk without rescanning it.
                self.control = parseControl(
                    chunk.data,
                    self.default_image.width,
                    self.default_image.height,
                ) catch unreachable;
                if (previous) |frame| return frame;
            } else if (std.mem.eql(u8, chunk.kind, "IDAT") or std.mem.eql(u8, chunk.kind, "fdAT")) {
                if (self.control == null) continue; // Default image outside the animation.
                const prefix: usize = if (std.mem.eql(u8, chunk.kind, "fdAT")) 4 else 0;
                const body = chunk.data[prefix..];
                if (self.data) |*data| {
                    data.after_last = chunk.after;
                    data.multiple = true;
                    // Complete sum was checked by AnimationSource.open.
                    data.byte_count += body.len;
                } else self.data = .{
                    .kind = if (prefix == 0) .idat else .fdat,
                    .source = self.chunks.source,
                    .first = body,
                    .first_offset = chunk.offset,
                    .after_last = chunk.after,
                    .multiple = false,
                    .byte_count = body.len,
                };
            }
        }
        return self.take();
    }

    fn take(self: *Iterator) ?Frame {
        const control = self.control orelse return null;
        const data = self.data orelse return null;
        const index = self.index;
        self.index += 1;
        self.control = null;
        self.data = null;
        return .{
            .index = index,
            .control = control,
            .image = frameImage(
                self.default_image,
                control.width,
                control.height,
                data,
            ) catch unreachable,
        };
    }
};

/// Bounded structural policy, without pixel allocation or entropy validity claims.
pub const Options = struct {
    /// Maximum complete source bytes, including excluded poster data and ancillary records. The
    /// default permits any source length representable by usize.
    maximum_encoded_bytes: usize = std.math.maxInt(usize),
    /// Largest canvas axis; frame rectangles must lie within that admitted canvas.
    maximum_canvas_extent: u32 = SourceImage.default_maximum_source_extent,
    /// Maximum animation frames, independently of total PNG chunk count; defaults to 4096.
    maximum_frames: u32 = 4096,
    /// Source-byte traversal and chunk/metadata limits; pixel/output caps apply on decoding.
    limits: Limits = .{},
};

/// Checked frame control and a borrowed stream for its independently compressed local raster.
pub const Frame = struct {
    /// Zero-based frame ordinal.
    index: u32,
    /// Copied rectangle, delay, disposal and blend facts.
    control: FrameControl,
    /// Shared PNG layout with frame-local geometry and a borrowed IDAT/fdAT stream. Keep the
    /// complete encoded PNG bytes alive and unchanged while this image is used.
    image: SourceImage,
};

const Chunk = struct { offset: usize, after: usize, kind: []const u8, data: []const u8 };

const ChunkIterator = struct {
    source: []const u8,
    offset: usize = 8,

    fn next(self: *ChunkIterator) ?Chunk {
        if (self.offset == self.source.len) return null;
        // The complete immutable source has already passed Source framing/CRC admission.
        const offset = self.offset;
        const data_start = offset + 8;
        const data_end = data_start + std.mem.readInt(u32, self.source[offset..][0..4], .big);
        self.offset = data_end + 4;
        return .{
            .offset = offset,
            .after = self.offset,
            .kind = self.source[offset + 4 ..][0..4],
            .data = self.source[data_start..data_end],
        };
    }
};

fn readPngInteger(source: []const u8, offset: usize) Error!u32 {
    const value = std.mem.readInt(u32, source[offset..][0..4], .big);
    if (value > 0x7fff_ffff) return error.InvalidApng;
    return value;
}

fn acceptSequence(value: u32, expected: *u64) Error!void {
    if (value != expected.*) return error.InvalidApng;
    expected.* += 1; // u64 represents the successor of PNG's largest sequence word.
}

fn parseControl(source: []const u8, width: u32, height: u32) Error!FrameControl {
    if (source.len != 26) return error.InvalidApng;
    const control: FrameControl = .{
        .sequence = try readPngInteger(source, 0),
        .width = try readPngInteger(source, 4),
        .height = try readPngInteger(source, 8),
        .x = try readPngInteger(source, 12),
        .y = try readPngInteger(source, 16),
        .delay = .{
            .numerator = std.mem.readInt(u16, source[20..22], .big),
            .denominator = std.mem.readInt(u16, source[22..24], .big),
        },
        .dispose = switch (source[24]) {
            0 => .none,
            1 => .background,
            2 => .previous,
            else => return error.InvalidApng,
        },
        .blend = switch (source[25]) {
            0 => .source,
            1 => .over,
            else => return error.InvalidApng,
        },
    };
    if (control.width == 0 or control.height == 0 or control.x > width or control.y > height or
        control.width > width - control.x or control.height > height - control.y)
        return error.InvalidApng;
    return control;
}

test "APNG structure iterates split empty data and preserves exact control facts" {
    const source = try std.testing.allocator.dupe(u8, png_animation_vectors.rgba8);
    defer std.testing.allocator.free(source);
    const admitted = try AnimationSource.open(source, .{});
    try std.testing.expectEqual(8, admitted.frame_count);
    try std.testing.expectEqual(2, admitted.play_count);
    try std.testing.expect(admitted.default_is_frame);
    try std.testing.expectEqual(12, admitted.total_frame_pixels);
    try std.testing.expectEqual(4, admitted.maximum_frame_pixels);
    var iterator = admitted.frames();
    var controls: [8]FrameControl = undefined;
    var ordinal: u32 = 0;
    var payload_total: usize = 0;
    while (iterator.next()) |frame| : (ordinal += 1) {
        try std.testing.expectEqual(ordinal, frame.index);
        try std.testing.expectEqual(
            @as(ImageData.Kind, if (ordinal == 0) .idat else .fdat),
            frame.image.image_data.kind,
        );
        controls[ordinal] = frame.control;
        // Chunk inspection on a local frame still visits the complete containing PNG.
        var records = frame.image.chunks();
        var record_count: usize = 0;
        while (try records.next()) |_| record_count += 1;
        try std.testing.expectEqual(admitted.default_image.record_count, record_count);
        const data = frame.image.image_data;
        try std.testing.expect(data.multiple);
        payload_total += data.byte_count;
        const joined = try std.testing.allocator.alloc(u8, data.byte_count);
        defer std.testing.allocator.free(joined);
        data.copyInto(joined);
        var fixed: std.Io.Reader = undefined;
        var chunked: ImageData.Reader = undefined;
        const input = data.reader(&fixed, &chunked);
        const read = try std.testing.allocator.alloc(u8, data.byte_count);
        defer std.testing.allocator.free(read);
        try input.readSliceAll(read);
        try std.testing.expectEqualSlices(u8, joined, read);
        try std.testing.expectError(error.EndOfStream, input.takeByte());
    }
    try std.testing.expectEqual(8, ordinal);
    try std.testing.expect(iterator.next() == null);
    try std.testing.expectEqual(admitted.compressed_bytes, payload_total);
    try std.testing.expectEqual(
        FrameControl{
            .sequence = 0,
            .width = 2,
            .height = 2,
            .x = 0,
            .y = 0,
            .delay = .{ .numerator = 0, .denominator = 0 },
            .dispose = .previous,
            .blend = .source,
        },
        controls[0],
    );
    try std.testing.expectEqual(100, controls[0].delay.effectiveDenominator());
    try std.testing.expectEqual(100, controls[1].delay.effectiveDenominator());
    try std.testing.expectEqual(30, controls[2].delay.effectiveDenominator());
    try std.testing.expectEqual(65535, controls[4].delay.numerator);
    try std.testing.expectEqual(65535, controls[4].delay.effectiveDenominator());
}

test "APNG structure rejects duplicate misplaced and missing frame records" {
    const original = try std.testing.allocator.dupe(u8, png_animation_vectors.rgba8);
    defer std.testing.allocator.free(original);
    const actl = testChunk(original, "acTL", 0);
    const actl_end = actl + 20;
    const duplicate = try std.testing.allocator.alloc(u8, original.len + 20);
    defer std.testing.allocator.free(duplicate);
    @memcpy(duplicate[0..actl_end], original[0..actl_end]);
    @memcpy(duplicate[actl_end..][0..20], original[actl..actl_end]);
    @memcpy(duplicate[actl_end + 20 ..], original[actl_end..]);
    try std.testing.expectError(error.InvalidApng, AnimationSource.open(duplicate, .{}));

    const source = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(source);
    // Rename the early declaration, then turn a later private chunk into acTL.
    @memcpy(source[actl + 4 ..][0..4], "vpAg");
    testRefreshCrc(source, actl);
    const last_control = testChunk(source, "fcTL", 7);
    @memcpy(source[last_control + 4 ..][0..4], "acTL");
    testRefreshCrc(source, last_control);
    try std.testing.expectError(error.InvalidApng, AnimationSource.open(source, .{}));

    @memcpy(source, original);
    // Remove all data of a local frame from animation semantics while preserving PNG CRCs.
    for (4..8) |ordinal| {
        const offset = testChunk(original, "fdAT", ordinal);
        @memcpy(source[offset + 4 ..][0..4], "vpAg");
        testRefreshCrc(source, offset);
    }
    try std.testing.expectError(error.InvalidApng, AnimationSource.open(source, .{}));

    // A genuine static PNG differs from malformed animation records.
    const static = try std.testing.allocator.dupe(u8, png_metadata_vectors.color_png);
    defer std.testing.allocator.free(static);
    try std.testing.expectError(error.NotAnimatedPng, AnimationSource.open(static, .{}));
}

test "APNG sequence count order and rectangle errors precede allocation" {
    const original = try std.testing.allocator.dupe(u8, png_animation_vectors.rgba8);
    defer std.testing.allocator.free(original);
    const source = try std.testing.allocator.dupe(u8, original);
    defer std.testing.allocator.free(source);
    const words = [_]struct {
        kind: *const [4]u8,
        ordinal: usize,
        field: usize,
        value: u32,
    }{
        .{ .kind = "acTL", .ordinal = 0, .field = 0, .value = 0 },
        .{ .kind = "acTL", .ordinal = 0, .field = 0, .value = 7 },
        .{ .kind = "acTL", .ordinal = 0, .field = 0, .value = 9 },
        .{ .kind = "acTL", .ordinal = 0, .field = 4, .value = 0x8000_0000 },
        .{ .kind = "fcTL", .ordinal = 0, .field = 0, .value = 1 },
        .{ .kind = "fcTL", .ordinal = 0, .field = 4, .value = 1 },
        .{ .kind = "fcTL", .ordinal = 1, .field = 4, .value = 0 },
        .{ .kind = "fcTL", .ordinal = 1, .field = 8, .value = 0x8000_0000 },
        .{ .kind = "fcTL", .ordinal = 1, .field = 12, .value = 2 },
        .{ .kind = "fcTL", .ordinal = 1, .field = 16, .value = 2 },
        .{ .kind = "fdAT", .ordinal = 0, .field = 0, .value = 0 },
        .{ .kind = "fdAT", .ordinal = 0, .field = 0, .value = 0x8000_0000 },
    };
    for (words) |mutation| {
        @memcpy(source, original);
        const offset = testChunk(source, mutation.kind, mutation.ordinal);
        std.mem.writeInt(u32, source[offset + 8 + mutation.field ..][0..4], mutation.value, .big);
        testRefreshCrc(source, offset);
        try std.testing.expectError(
            error.InvalidApng,
            animation.allocWithScratch(
                u8,
                std.testing.failing_allocator,
                std.testing.failing_allocator,
                source,
                .{},
            ),
        );
    }
    for ([_]usize{ 24, 25 }) |field| {
        @memcpy(source, original);
        const offset = testChunk(source, "fcTL", 0);
        source[offset + 8 + field] = 3;
        testRefreshCrc(source, offset);
        try std.testing.expectError(error.InvalidApng, AnimationSource.open(source, .{}));
    }
    @memcpy(source, original);
    const offset = testChunk(source, "acTL", 0);
    @memcpy(source[offset + 4 ..][0..4], "vpAg");
    testRefreshCrc(source, offset);
    try std.testing.expectError(error.InvalidApng, AnimationSource.open(source, .{}));
    try std.testing.expectError(
        error.InvalidPng,
        AnimationSource.open(original[0 .. original.len - 1], .{}),
    );
    @memcpy(source, original);
    source[original.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidPng, AnimationSource.open(source, .{}));
}

fn testChunk(source: []const u8, kind: *const [4]u8, ordinal: usize) usize {
    var offset: usize = 8;
    var count: usize = 0;
    while (offset < source.len) {
        if (std.mem.eql(u8, source[offset + 4 ..][0..4], kind)) {
            if (count == ordinal) return offset;
            count += 1;
        }
        offset += 12 + std.mem.readInt(u32, source[offset..][0..4], .big);
    }
    unreachable; // These helpers address fixed complete fixture chunks.
}

fn testRefreshCrc(source: []u8, offset: usize) void {
    const end = offset + 8 + std.mem.readInt(u32, source[offset..][0..4], .big);
    std.mem.writeInt(
        u32,
        source[end..][0..4],
        std.hash.Crc32.hash(source[offset + 4 .. end]),
        .big,
    );
}
