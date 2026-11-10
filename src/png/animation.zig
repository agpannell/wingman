//! Owned APNG frame reconstruction and retained byte/word playback.

const AnimationSource = @import("AnimationSource.zig");
const FrameControl = @import("FrameControl.zig");
const Delay = FrameControl.Delay;
const Disposal = FrameControl.Disposal;
const Blend = FrameControl.Blend;
const metadata_info = @import("metadata.zig");
const zlib = @import("../zlib.zig");
const Inflater = zlib.Reader;
const std = @import("std");
const png_animation_vectors = @import("testdata/animation.zig");
const png_palette_vectors = @import("testdata/palette.zig");
const encoding = @import("animation_encode.zig");
const format = @import("format.zig");
const SourceImage = @import("Source.zig");
const decoder = @import("image_decode.zig");
const Limits = @import("Limits.zig");
const storage_module = @import("../common/allocation.zig");

/// PNG structure/pixels, malformed animation framing and caller resource failures.
pub const Error = decoder.ImageDecodeError || error{
    /// A static PNG has no acTL animation declaration.
    NotAnimatedPng,
    /// Animation ordering, sequence, dimensions, fields or counts are inconsistent.
    InvalidApng,
    /// Declared or encountered frames exceed the selected count policy.
    FrameLimitExceeded,
};

/// Source, frame, pixel and resource policy for complete animation decoding.
pub const Options = struct {
    /// Complete encoded file size, independent of selected frames and decoded samples.
    maximum_encoded_bytes: usize = std.math.maxInt(usize),
    /// Applies to all local frames and validation of an excluded default image.
    palette_index_policy: format.PaletteIndexPolicy = .opaque_black,
    /// Largest canvas axis.
    maximum_canvas_extent: u32 = SourceImage.default_maximum_source_extent,
    /// Largest selected frame count.
    maximum_frames: u32 = 4096,
    /// Output counts all retained local frame pixels and control storage. Work counts source bytes
    /// plus each decoded stream's payload and four filtered-byte visits. An excluded default image
    /// keeps its separate canvas-pixel and logical RGBA-byte admission, but validation reserves
    /// only a bounded inflater and two packed rows.
    limits: Limits = .{},
};

/// Decodes and validates every local frame using one allocation authority for output and scratch.
/// Sample is u8 or u16. No source, scratch or allocator borrow survives success; release the
/// returned animation through deinit with allocator. An excluded poster is validated separately.
pub fn alloc(
    comptime Sample: type,
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) (std.mem.Allocator.Error || Error)!Animation(Sample) {
    return allocWithScratch(Sample, allocator, allocator, source, options);
}

/// Prepares complete local rasters transactionally with independent call-local scratch authority.
/// Encoded source stays immutable through admission and reconstruction. Every failure retires
/// partial controls, samples and scratch. Output and scratch handles may alias without merging
/// ownership.
pub fn allocWithScratch(
    comptime Sample: type,
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) (std.mem.Allocator.Error || Error)!Animation(Sample) {
    return Animation(Sample).initialize(output_allocator, scratch_allocator, source, options);
}

/// Owns every decoded local frame, without source/scratch/allocator borrows. Preparation is
/// transactional; no partially accepted animation is returned. Copies share the two allocations and
/// must release them once. A Player borrows this owner at its final address until that player's
/// last use.
pub fn Animation(comptime Sample: type) type {
    checkSample(Sample);
    return struct {
        const Self = @This();

        /// Copied frame control and decoded frame-local RGBA samples.
        pub const Frame = struct {
            /// Encoded rectangle, delay, blend and disposal choices.
            control: FrameControl,
            /// Local tightly packed RGBA samples; byte or complete host-native word channels.
            pixels: []const Sample,
        };

        /// Composes frames into a retained caller-visible canvas.
        pub const Player = struct {
            const PlayerType = @This();

            pub const Options = PlayerOptions;

            /// Borrowed complete decoded animation at its stable owner address.
            animation: *const Animation(Sample),
            /// Complete byte owner of the canvas/backup, including alignment padding.
            allocation: []u8,
            /// Tightly packed canvas samples borrowing `allocation`.
            canvas: []Sample,
            /// Backing for the largest required previous-disposal rectangle, in RGBA samples. The
            /// first and last frames need no backup; callers must not alter it during playback.
            backup: []Sample,
            /// Next frame ordinal; advanced only through `next` or `reset`.
            next_frame: usize = 0,
            /// Current play ordinal. Unlimited playback saturates this descriptive counter at u64
            /// max.
            play_index: u64 = 0,
            /// Most recently displayed frame, pending its selected disposal.
            previous: ?usize = null,

            /// Borrows the current canvas and copies the selected display facts.
            pub const VisibleFrame = struct {
                /// Borrowed full-canvas row-major RGBA samples.
                pixels: []const Sample,
                /// Current frame ordinal.
                index: u32,
                /// Current play ordinal, starting at zero.
                play_index: u64,
                /// Exact encoded timing; this player never skips or clamps a frame.
                delay: Delay,
            };

            /// Reserves one canvas and the largest previous-disposal rectangle used within a play.
            /// `animation` was produced by alloc and stays live and unchanged. Work/output refusal
            /// and allocation failure leave the borrowed animation unchanged. The initialized
            /// canvas is fully transparent black; its backing never grows.
            pub fn initCapacity(
                allocator: std.mem.Allocator,
                animation: *const Animation(Sample),
                options: PlayerOptions,
            ) (std.mem.Allocator.Error || Error)!PlayerType {
                const canvas_pixels = try multiply(animation.width, animation.height);
                const canvas_samples = try multiply(canvas_pixels, 4);
                var previous_pixels: usize = 0;
                var maximum_pixels: usize = 0;
                for (animation.frames, 0..) |frame, index| {
                    const count = try multiply(frame.control.width, frame.control.height);
                    maximum_pixels = @max(maximum_pixels, count);
                    if (needsPreviousBackup(
                        index,
                        animation.frames.len,
                        frame.control.dispose,
                    )) previous_pixels = @max(previous_pixels, count);
                }
                const count = try add(canvas_samples, try multiply(previous_pixels, 4));
                try format.admitOutput(
                    options.limits,
                    canvas_pixels,
                    try multiply(count, @sizeOf(Sample)),
                );
                try format.admitWork(
                    options.limits,
                    try workAdd(canvas_samples, try workMultiply(maximum_pixels, 32)),
                );
                const reserved = storage_module.AlignedAllocation(
                    Sample,
                ).init(allocator, count) catch |failure| switch (failure) {
                    error.SizeOverflow => return error.OutputBudgetExceeded,
                    error.OutOfMemory => return error.OutOfMemory,
                };
                const storage = reserved.samples;
                @memset(storage[0..canvas_samples], 0);
                return .{
                    .animation = animation,
                    .allocation = reserved.storage,
                    .canvas = storage[0..canvas_samples],
                    .backup = storage[canvas_samples..],
                };
            }

            /// Advances one frame without allocation. Applies previous disposal, saves a required
            /// rectangle and composes the current frame. A new play clears the canvas. Finite
            /// completion returns null and leaves the last displayed canvas intact.
            pub fn next(self: *PlayerType) ?VisibleFrame {
                if (self.next_frame == self.animation.frames.len) {
                    if (self.animation.play_count != 0 and self.play_index + 1 >= self.animation
                        .play_count) return null;
                    self.play_index +|= 1;
                    self.next_frame = 0;
                    self.previous = null;
                    @memset(self.canvas, 0);
                }
                if (self.previous) |index| {
                    const control = self.animation.frames[index].control;
                    switch (control.dispose) {
                        .none => {},
                        .background => self.clearRectangle(control),
                        .previous => if (index == 0) self.clearRectangle(
                            control,
                        ) else self.copyRectangle(control, false),
                    }
                }

                const index = self.next_frame;
                const frame = self.animation.frames[index];
                if (needsPreviousBackup(
                    index,
                    self.animation.frames.len,
                    frame.control.dispose,
                )) self.copyRectangle(frame.control, true);
                const width: usize = frame.control.width;
                const canvas_y: usize = frame.control.y;
                for (0..frame.control.height) |y| {
                    const canvas_offset = ((canvas_y + y) * self.animation.width + frame.control
                        .x) * 4;
                    const source_offset = y * width * 4;
                    const target = self.canvas[canvas_offset..][0 .. width * 4];
                    const source = frame.pixels[source_offset..][0 .. width * 4];
                    if (frame.control.blend == .source) {
                        @memcpy(target, source);
                    } else {
                        for (0..width) |x| {
                            over(Sample, target[x * 4 ..][0..4], source[x * 4 ..][0..4]);
                        }
                    }
                }
                self.next_frame += 1;
                self.previous = index;
                return .{
                    .pixels = self.canvas,
                    .index = @intCast(index),
                    .play_index = self.play_index,
                    .delay = frame.control.delay,
                };
            }

            /// Restarts playback and clears the canvas without changing capacity or animation data.
            pub fn reset(self: *PlayerType) void {
                @memset(self.canvas, 0);
                self.next_frame = 0;
                self.play_index = 0;
                self.previous = null;
            }

            /// Releases the sole composition allocation; the borrowed animation remains owned.
            pub fn deinit(self: *PlayerType, allocator: std.mem.Allocator) void {
                allocator.free(self.allocation);
                self.* = undefined;
            }

            fn needsPreviousBackup(index: usize, frame_count: usize, dispose: Disposal) bool {
                // First-frame PREVIOUS acts as background. A last frame is held on completion, and
                // every new play clears the canvas before its first frame is composed.
                return dispose == .previous and index != 0 and index + 1 < frame_count;
            }

            fn clearRectangle(self: *PlayerType, control: FrameControl) void {
                for (0..control.height) |y| {
                    const offset = ((@as(
                        usize,
                        control.y,
                    ) + y) * self.animation.width + control.x) * 4;
                    @memset(self.canvas[offset..][0 .. @as(usize, control.width) * 4], 0);
                }
            }

            fn copyRectangle(self: *PlayerType, control: FrameControl, save: bool) void {
                const row_samples = @as(usize, control.width) * 4;
                for (0..control.height) |y| {
                    const offset = ((@as(
                        usize,
                        control.y,
                    ) + y) * self.animation.width + control.x) * 4;
                    const canvas = self.canvas[offset..][0..row_samples];
                    const saved = self.backup[y * row_samples ..][0..row_samples];
                    if (save) @memcpy(saved, canvas) else @memcpy(canvas, saved);
                }
            }
        };

        /// Complete canvas width in stored pixels.
        width: u32,
        /// Complete canvas height in stored pixels.
        height: u32,
        /// Declared plays, with zero denoting unlimited looping.
        play_count: u32,
        /// Complete byte owner of the ordered records, including alignment padding.
        frames_allocation: []u8,
        /// Complete byte owner of the frame samples, including alignment padding.
        pixels_allocation: []u8,
        /// Ordered records borrowing `frames_allocation`; their pixel slices borrow `pixels`.
        frames: []Frame,
        /// Packed samples borrowing `pixels_allocation`, containing each local rectangle in order.
        /// Keep frame descriptors and backing owners intact until deinit.
        pixels: []Sample,
        /// True when the default IDAT image is included in `frames`.
        default_is_frame: bool,
        /// Original encoded channel precision.
        encoded_bit_depth: u8,
        /// Original PNG color layout.
        encoded_color_type: u8,
        /// Copied file metadata presence, without profile/orientation/aspect application.
        metadata_presence: metadata_info.Metadata.Presence,

        /// Admits the complete structure and cumulative resources before owned storage. Every frame
        /// stream is decoded through the ordinary PNG palette/filter/Adam7 mechanism. An excluded
        /// static image is fully checked without RGBA expansion. Failure retires all partial
        /// controls, pixels and scratch without fallback.
        fn initialize(
            allocator: std.mem.Allocator,
            scratch_allocator: std.mem.Allocator,
            source: []const u8,
            options: Options,
        ) (std.mem.Allocator.Error || Error)!Self {
            var scratch: storage_module.Scratch = .{
                .backing = scratch_allocator,
                .maximum_bytes = options.limits.maximum_scratch_bytes,
            };
            return initializeFrames(
                allocator,
                source,
                options,
                &scratch,
            ) catch |err| return scratch.classifyFailure(err);
        }

        fn initializeFrames(
            allocator: std.mem.Allocator,
            source: []const u8,
            options: Options,
            scratch: *storage_module.Scratch,
        ) (std.mem.Allocator.Error || Error)!Self {
            const admitted = try AnimationSource.open(
                source,
                .{
                    .maximum_encoded_bytes = options.maximum_encoded_bytes,
                    .maximum_canvas_extent = options.maximum_canvas_extent,
                    .maximum_frames = options.maximum_frames,
                    .limits = options.limits,
                },
            );
            const samples = try multiply(admitted.total_frame_pixels, 4);
            const pixel_bytes = try multiply(samples, @sizeOf(Sample));
            const record_bytes = try multiply(admitted.frame_count, @sizeOf(Frame));
            const output_bytes = try add(pixel_bytes, record_bytes);
            try format.admitOutput(options.limits, admitted.total_frame_pixels, output_bytes);
            const default_pixels = try multiply(
                admitted.default_image.width,
                admitted.default_image.height,
            );
            const default_samples = try multiply(default_pixels, 4);
            if (!admitted.default_is_frame) try format.admitOutput(
                options.limits,
                default_pixels,
                try multiply(default_samples, @sizeOf(Sample)),
            );
            var filtered = admitted.filtered_bytes;
            var compressed = admitted.compressed_bytes;
            if (!admitted.default_is_frame) {
                filtered = try workAdd(filtered, admitted.default_image.filtered_byte_count);
                compressed = try workAdd(compressed, admitted.default_image.image_data.byte_count);
            }
            const work = try workAdd(
                source.len,
                try workAdd(compressed, try workMultiply(filtered, 4)),
            );
            try format.admitWork(options.limits, work);
            const scratch_allocator = scratch.allocator();
            if (!admitted.default_is_frame) {
                try decoder.validateImage(
                    admitted.default_image,
                    .{
                        .palette_index_policy = options.palette_index_policy,
                        .scratch_allocator = scratch_allocator,
                        .limits = options.limits,
                    },
                );
            }
            const records = storage_module.AlignedAllocation(
                Frame,
            ).init(allocator, admitted.frame_count) catch |failure| switch (failure) {
                error.SizeOverflow => return error.OutputBudgetExceeded,
                error.OutOfMemory => return error.OutOfMemory,
            };
            errdefer allocator.free(records.storage);
            const pixels = storage_module.AlignedAllocation(
                Sample,
            ).init(allocator, samples) catch |failure| switch (failure) {
                error.SizeOverflow => return error.OutputBudgetExceeded,
                error.OutOfMemory => return error.OutOfMemory,
            };
            errdefer allocator.free(pixels.storage);
            const frames_storage = records.samples;
            const pixel_storage = pixels.samples;
            var iterator = admitted.frames();
            var offset: usize = 0;
            while (iterator.next()) |frame| {
                const count = try multiply(
                    try multiply(frame.control.width, frame.control.height),
                    4,
                );
                const destination = pixel_storage[offset..][0..count];
                try decoder.decodeImageInto(
                    Sample,
                    frame.image,
                    destination,
                    .{
                        .palette_index_policy = options.palette_index_policy,
                        .scratch_allocator = scratch_allocator,
                        .limits = options.limits,
                    },
                );
                frames_storage[frame.index] = .{ .control = frame.control, .pixels = destination };
                offset += count;
            }
            std.debug.assert(offset == samples);
            return .{
                .width = admitted.default_image.width,
                .height = admitted.default_image.height,
                .play_count = admitted.play_count,
                .frames_allocation = records.storage,
                .pixels_allocation = pixels.storage,
                .frames = frames_storage,
                .pixels = pixel_storage,
                .default_is_frame = admitted.default_is_frame,
                .encoded_bit_depth = admitted.default_image.bit_depth,
                .encoded_color_type = admitted.default_image.color_type,
                .metadata_presence = admitted.default_image.metadata_presence,
            };
        }

        /// Releases both owners through their initialization allocator, invalidating all frames and
        /// any Player borrow. Retire those players before this call.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.pixels_allocation);
            allocator.free(self.frames_allocation);
            self.* = undefined;
        }
    };
}

/// Initialization policy for retained composition; ordinary advancement allocates nothing.
const PlayerOptions = struct {
    /// Canvas plus largest previous-disposal backup are admitted as owned output. Work units are
    /// four canvas-component visits plus 32 per largest frame pixel. This bounds clear, rectangle
    /// restore/save and composition visits, not elapsed time.
    limits: Limits = .{},
};

fn over(comptime Sample: type, destination: []Sample, source: []const Sample) void {
    const maximum = std.math.maxInt(Sample);
    const source_alpha: u64 = source[3];
    const destination_alpha: u64 = destination[3];

    if (source_alpha == maximum) {
        @memcpy(destination, source);
        return;
    }
    if (source_alpha == 0) {
        if (destination_alpha == 0) @memset(destination, 0);
        return;
    }
    if (destination_alpha == 0) {
        @memcpy(destination, source);
        return;
    }
    // Keep coverage scaled by the sample maximum until the final rounded divisions. This avoids
    // losing precision when composing unassociated colors with partial alpha.
    const alpha = source_alpha * maximum + destination_alpha * (maximum - source_alpha);
    for (0..3) |channel| {
        const source_color: u64 = source[channel];
        const destination_color: u64 = destination[channel];
        const color = source_color * source_alpha * maximum + destination_color *
            destination_alpha * (maximum - source_alpha);
        destination[channel] = @intCast((color + alpha / 2) / alpha);
    }
    destination[3] = @intCast((alpha + maximum / 2) / maximum);
}
fn checkSample(comptime Sample: type) void {
    if (Sample != u8 and Sample != u16) @compileError("APNG samples must be u8 or u16");
}

fn multiply(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.OutputBudgetExceeded;
}

fn add(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.OutputBudgetExceeded;
}

fn workMultiply(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.WorkBudgetExceeded;
}

fn workAdd(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.WorkBudgetExceeded;
}

test "APNG byte and word players match independent transparent disposal canvases" {
    inline for (
        .{
            .{
                u8,
                png_animation_vectors.rgba8,
                &png_animation_vectors.rgba8_frames,
                &png_animation_vectors.rgba8_canvases,
            },
            .{
                u8,
                png_animation_vectors.rgba8_adam7,
                &png_animation_vectors.rgba8_adam7_frames,
                &png_animation_vectors.rgba8_adam7_canvases,
            },
            .{
                u16,
                png_animation_vectors.rgba16,
                &png_animation_vectors.rgba16_frames,
                &png_animation_vectors.rgba16_canvases,
            },
            .{
                u16,
                png_animation_vectors.rgba16_adam7,
                &png_animation_vectors.rgba16_adam7_frames,
                &png_animation_vectors.rgba16_adam7_canvases,
            },
            .{
                u8,
                png_animation_vectors.outside8,
                &png_animation_vectors.outside8_frames,
                &png_animation_vectors.outside8_canvases,
            },
            .{
                u16,
                png_animation_vectors.outside16,
                &png_animation_vectors.outside16_frames,
                &png_animation_vectors.outside16_canvases,
            },
            .{
                u8,
                png_animation_vectors.palette_adam7,
                &png_animation_vectors.palette_adam7_frames,
                &png_animation_vectors.palette_adam7_canvases,
            },
            .{
                u16,
                png_animation_vectors.rgb16_trns,
                &png_animation_vectors.rgb16_trns_frames,
                &png_animation_vectors.rgb16_trns_canvases,
            },
        },
    ) |fixture| {
        try expectPlayback(fixture[0], fixture[1], fixture[2], fixture[3]);
    }
}

fn expectPlayback(
    comptime Sample: type,
    encoded: []const u8,
    frames: []const []const Sample,
    canvases: anytype,
) !void {
    const source = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(source);
    var animation = try allocWithScratch(
        Sample,
        std.testing.allocator,
        std.testing.allocator,
        source,
        .{},
    );
    defer animation.deinit(std.testing.allocator);
    try std.testing.expectEqual(frames.len, animation.frames.len);
    for (
        animation.frames,
        frames,
    ) |actual, expected| try std.testing.expectEqualSlices(Sample, expected, actual.pixels);
    var authority = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var player = try Animation(Sample).Player.initCapacity(authority.allocator(), &animation, .{});
    defer player.deinit(authority.allocator());
    const address = player.canvas.ptr;
    const allocation_count = authority.alloc_index;
    for (0..2) |play| {
        for (canvases, 0..) |expected, index| {
            const visible = player.next().?;
            try std.testing.expectEqualSlices(Sample, &expected, visible.pixels);
            try std.testing.expectEqual(index, visible.index);
            try std.testing.expectEqual(play, visible.play_index);
            try std.testing.expectEqual(animation.frames[index].control.delay, visible.delay);
            try std.testing.expectEqual(address, visible.pixels.ptr);
        }
    }
    try std.testing.expect(player.next() == null);
    try std.testing.expect(player.next() == null);
    try std.testing.expectEqualSlices(Sample, &canvases[canvases.len - 1], player.canvas);
    player.reset();
    for (player.canvas) |sample| try std.testing.expectEqual(0, sample);
    try std.testing.expectEqualSlices(Sample, &canvases[0], player.next().?.pixels);
    try std.testing.expectEqual(allocation_count, authority.alloc_index);
    try std.testing.expect(!authority.has_induced_failure);
}

test "APNG source-over literal endpoints and neighbors retain byte and full-word samples" {
    // Independent exact fractions for PNG's unassociated OVER equations, rounded half-up. Include
    // invisible colors, lowest nonzero alpha and neighbors below full opacity; a word alpha of 255
    // remains partial rather than becoming byte-style opacity.
    // https://www.w3.org/TR/2025/REC-png-3-20250624/#13Alpha-channel-processing
    const byte_controls = [_]struct {
        source: [4]u8,
        destination: [4]u8,
        expected: [4]u8,
    }{
        .{
            .source = .{ 1, 2, 3, 0 },
            .destination = .{ 33, 77, 155, 0 },
            .expected = .{ 0, 0, 0, 0 },
        },
        .{
            .source = .{ 1, 2, 3, 0 },
            .destination = .{ 33, 77, 155, 1 },
            .expected = .{ 33, 77, 155, 1 },
        },
        .{
            .source = .{ 17, 63, 240, 255 },
            .destination = .{ 9, 8, 7, 0 },
            .expected = .{ 17, 63, 240, 255 },
        },
        .{
            .source = .{ 17, 63, 240, 255 },
            .destination = .{ 9, 8, 7, 255 },
            .expected = .{ 17, 63, 240, 255 },
        },
        .{
            .source = .{ 1, 2, 3, 1 },
            .destination = .{ 250, 200, 150, 255 },
            .expected = .{ 249, 199, 149, 255 },
        },
        .{
            .source = .{ 0, 0, 0, 254 },
            .destination = .{ 255, 255, 255, 255 },
            .expected = .{ 1, 1, 1, 255 },
        },
        .{
            .source = .{ 255, 1, 127, 1 },
            .destination = .{ 0, 254, 2, 1 },
            .expected = .{ 128, 127, 65, 2 },
        },
    };
    for (byte_controls) |control| {
        var destination = control.destination;
        over(u8, &destination, &control.source);
        try std.testing.expectEqual(control.expected, destination);
    }
    const word_controls = [_]struct {
        source: [4]u16,
        destination: [4]u16,
        expected: [4]u16,
    }{
        .{
            .source = .{ 1, 2, 3, 0 },
            .destination = .{ 65535, 32768, 1, 0 },
            .expected = .{ 0, 0, 0, 0 },
        },
        .{
            .source = .{ 1, 2, 3, 0 },
            .destination = .{ 65535, 32768, 1, 1 },
            .expected = .{ 65535, 32768, 1, 1 },
        },
        .{
            .source = .{ 1, 257, 65534, 65535 },
            .destination = .{ 65535, 32768, 1, 0 },
            .expected = .{ 1, 257, 65534, 65535 },
        },
        .{
            .source = .{ 1, 257, 65534, 65535 },
            .destination = .{ 65535, 32768, 1, 65535 },
            .expected = .{ 1, 257, 65534, 65535 },
        },
        .{
            .source = .{ 0, 0, 0, 65534 },
            .destination = .{ 65535, 65535, 65535, 65535 },
            .expected = .{ 1, 1, 1, 65535 },
        },
        .{
            .source = .{ 65535, 0, 1, 255 },
            .destination = .{ 0, 65535, 65534, 65535 },
            .expected = .{ 255, 65280, 65279, 65535 },
        },
        .{
            .source = .{ 65535, 1, 32767, 1 },
            .destination = .{ 0, 65534, 2, 1 },
            .expected = .{ 32768, 32767, 16385, 2 },
        },
    };
    for (word_controls) |control| {
        var destination = control.destination;
        over(u16, &destination, &control.source);
        try std.testing.expectEqual(control.expected, destination);
    }
}

test "APNG transparent destination preserves every nonzero byte and word alpha" {
    // Unassociated source-over over zero destination alpha is exactly the source. Invisible
    // destination colors contribute nothing; zero source alpha stays covered by the literal
    // transparent-black control above.
    inline for (.{ u8, u16 }) |Sample| {
        const maximum = std.math.maxInt(Sample);
        for (1..@as(usize, maximum) + 1) |alpha| {
            const source = [_]Sample{
                @intCast(alpha),
                @intCast(maximum - alpha),
                maximum,
                @intCast(alpha),
            };
            var destination = [_]Sample{ maximum, 1, 3, 0 };
            over(Sample, &destination, &source);
            try std.testing.expectEqual(source, destination);
        }
    }
}

test "APNG excluded static image retains ordinary PNG default selection" {
    const source = try std.testing.allocator.dupe(u8, png_animation_vectors.outside8);
    defer std.testing.allocator.free(source);
    const admitted = try AnimationSource.open(source, .{});
    try std.testing.expect(!admitted.default_is_frame);
    try std.testing.expectEqual(7, admitted.frame_count);
    var static_image = try decoder.rgbaAlloc(u8, std.testing.allocator, source, .{});
    defer static_image.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(255))), static_image.texels);
    var animation = try allocWithScratch(
        u8,
        std.testing.allocator,
        std.testing.allocator,
        source,
        .{},
    );
    defer animation.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 128 }, animation.frames[0].pixels);
    try std.testing.expect(animation.metadata_presence.animation);
}

test "APNG Pillow producer matches independently composed opaque canvases" {
    const source = try std.testing.allocator.dupe(u8, png_animation_vectors.pillow_writer);
    defer std.testing.allocator.free(source);
    var animation = try allocWithScratch(
        u8,
        std.testing.allocator,
        std.testing.allocator,
        source,
        .{},
    );
    defer animation.deinit(std.testing.allocator);
    try std.testing.expectEqual(3, animation.frames.len);
    try std.testing.expectEqual(
        Delay{ .numerator = 1, .denominator = 10 },
        animation.frames[0].control.delay,
    );
    try std.testing.expectEqual(
        Delay{ .numerator = 1, .denominator = 5 },
        animation.frames[1].control.delay,
    );
    try std.testing.expectEqual(
        Delay{ .numerator = 3, .denominator = 10 },
        animation.frames[2].control.delay,
    );
    try std.testing.expectEqual(Disposal.previous, animation.frames[1].control.dispose);
    try std.testing.expectEqual(Disposal.background, animation.frames[2].control.dispose);
    try std.testing.expectEqual(Blend.over, animation.frames[1].control.blend);
    var player = try Animation(u8).Player.initCapacity(std.testing.allocator, &animation, .{});
    defer player.deinit(std.testing.allocator);
    for (
        png_animation_vectors.pillow_writer_canvases,
    ) |expected| try std.testing.expectEqualSlices(u8, &expected, player.next().?.pixels);
}

test "APNG one frame accepts the integer play boundary and leaves final disposal pending" {
    const original = try std.testing.allocator.dupe(u8, png_animation_vectors.rgba8);
    defer std.testing.allocator.free(original);
    const after_default = testChunk(original, "fcTL", 1);
    const source = try std.testing.allocator.alloc(u8, after_default + 12);
    defer std.testing.allocator.free(source);
    @memcpy(source[0..after_default], original[0..after_default]);
    @memcpy(source[after_default..], original[original.len - 12 ..]);
    const actl = testChunk(source, "acTL", 0);
    std.mem.writeInt(u32, source[actl + 8 ..][0..4], 1, .big);
    std.mem.writeInt(u32, source[actl + 12 ..][0..4], 0x7fff_ffff, .big);
    testRefreshCrc(source, actl);
    const admitted = try AnimationSource.open(source, .{ .maximum_frames = 1 });
    try std.testing.expectEqual(0x7fff_ffff, admitted.play_count);
    std.mem.writeInt(u32, source[actl + 12 ..][0..4], 1, .big);
    testRefreshCrc(source, actl);
    var animation = try allocWithScratch(
        u8,
        std.testing.allocator,
        std.testing.allocator,
        source,
        .{ .maximum_frames = 1 },
    );
    defer animation.deinit(std.testing.allocator);
    var player = try Animation(u8).Player.initCapacity(std.testing.allocator, &animation, .{});
    defer player.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, player.backup.len);
    try std.testing.expectEqualSlices(
        u8,
        &png_animation_vectors.rgba8_canvases[0],
        player.next().?.pixels,
    );
    try std.testing.expect(player.next() == null);
    try std.testing.expectEqualSlices(u8, &png_animation_vectors.rgba8_canvases[0], player.canvas);
}

test "APNG count metadata work output and scratch policies admit exact boundaries" {
    const source = try std.testing.allocator.dupe(u8, png_animation_vectors.rgba8);
    defer std.testing.allocator.free(source);
    const admitted = try AnimationSource.open(source, .{});
    try std.testing.expectError(
        error.FrameLimitExceeded,
        AnimationSource.open(source, .{ .maximum_frames = 7 }),
    );
    try std.testing.expectError(
        error.WorkBudgetExceeded,
        AnimationSource.open(source, .{ .limits = .{ .maximum_work_units = source.len - 1 } }),
    );
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        AnimationSource.open(source, .{ .limits = .{ .maximum_records = 2 } }),
    );
    // acTL + gAMA + eight controls + 28 fdAT sequence words + seven private records.
    const metadata_bytes = 8 + 4 + 8 * 26 + 28 * 4 + 7 * 5;
    _ = try AnimationSource.open(
        source,
        .{
            .maximum_frames = 8,
            .limits = .{
                .maximum_work_units = source.len,
                .maximum_metadata_bytes = metadata_bytes,
            },
        },
    );
    try std.testing.expectError(
        error.MetadataLimitExceeded,
        AnimationSource.open(
            source,
            .{ .limits = .{ .maximum_metadata_bytes = metadata_bytes - 1 } },
        ),
    );
    const work = source.len + admitted.compressed_bytes + admitted.filtered_bytes * 4;
    const output_bytes = 12 * 4 + 8 * @sizeOf(Animation(u8).Frame);
    const denied = std.testing.failing_allocator;
    for (
        [_]struct {
            limits: Limits,
            expected: anyerror,
        }{
            .{ .limits = .{ .maximum_pixels = 11 }, .expected = error.PixelBudgetExceeded },
            .{
                .limits = .{ .maximum_output_bytes = output_bytes - 1 },
                .expected = error.OutputBudgetExceeded,
            },
            .{
                .limits = .{ .maximum_work_units = work - 1 },
                .expected = error.WorkBudgetExceeded,
            },
            .{ .limits = .{ .maximum_scratch_bytes = 0 }, .expected = error.ScratchBudgetExceeded },
        },
    ) |case| {
        try std.testing.expectError(
            case.expected,
            allocWithScratch(
                u8,
                if (case.expected == error.ScratchBudgetExceeded) std.testing.allocator else denied,
                std.testing.allocator,
                source,
                .{ .limits = case.limits },
            ),
        );
    }
    var animation = try allocWithScratch(
        u8,
        std.testing.allocator,
        std.testing.allocator,
        source,
        .{
            .limits = .{
                .maximum_pixels = 12,
                .maximum_output_bytes = output_bytes,
                .maximum_work_units = work,
            },
        },
    );
    defer animation.deinit(std.testing.allocator);
    const player_work = 16 + 4 * 32;
    try std.testing.expectError(
        error.WorkBudgetExceeded,
        Animation(
            u8,
        ).Player.initCapacity(
            denied,
            &animation,
            .{ .limits = .{ .maximum_work_units = player_work - 1 } },
        ),
    );
    try std.testing.expectError(
        error.OutputBudgetExceeded,
        Animation(
            u8,
        ).Player.initCapacity(denied, &animation, .{ .limits = .{ .maximum_output_bytes = 19 } }),
    );
    var player = try Animation(
        u8,
    ).Player.initCapacity(
        std.testing.allocator,
        &animation,
        .{
            .limits = .{
                .maximum_pixels = 4,
                .maximum_output_bytes = 20,
                .maximum_work_units = player_work,
            },
        },
    );
    defer player.deinit(std.testing.allocator);
    try std.testing.expectEqual(4, player.backup.len);
}

test "APNG partial initialization and reserved playback release every allocation" {
    inline for (
        .{ .{ u8, png_animation_vectors.rgba8 }, .{ u16, png_animation_vectors.outside16 } },
    ) |fixture| {
        const source = try std.testing.allocator.dupe(u8, fixture[1]);
        defer std.testing.allocator.free(source);
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            testInitialize(fixture[0]),
            .{source},
        );
    }
}

test "APNG retained owners restore bounded backing after playback and exhaustion" {
    const allocator = std.testing.allocator;
    const backing = try allocator.alignedAlloc(u8, .@"8", 512 * 1024 + 16);
    defer allocator.free(backing);
    inline for (
        .{
            .{
                u8,
                png_animation_vectors.rgba8,
                &png_animation_vectors.rgba8_frames,
                &png_animation_vectors.rgba8_canvases,
            },
            .{
                u16,
                png_animation_vectors.rgba16_adam7,
                &png_animation_vectors.rgba16_adam7_frames,
                &png_animation_vectors.rgba16_adam7_canvases,
            },
            .{
                u16,
                png_animation_vectors.outside16,
                &png_animation_vectors.outside16_frames,
                &png_animation_vectors.outside16_canvases,
            },
        },
    ) |fixture| {
        const Sample = fixture[0];
        const source = try std.testing.allocator.dupe(u8, fixture[1]);
        defer allocator.free(source);
        inline for (.{ false, true }) |shared_scratch| {
            inline for (.{ false, true }) |decline_resize| {
                var failure_index: usize = 0;
                while (true) : (failure_index += 1) {
                    try std.testing.expect(failure_index < 256);
                    @memset(backing, 0xa5);
                    var fixed = std.heap.FixedBufferAllocator.init(backing[8 .. backing.len - 8]);
                    @memset(try fixed.allocator().alloc(u8, 17), 0x3c);
                    var failing = std.testing.FailingAllocator.init(
                        fixed.allocator(),
                        .{
                            .fail_index = failure_index,
                            .resize_fail_index = if (decline_resize) 0 else std.math.maxInt(usize),
                        },
                    );
                    var succeeded = false;
                    if (allocWithScratch(
                        Sample,
                        failing.allocator(),
                        if (shared_scratch) failing.allocator() else allocator,
                        source,
                        .{},
                    )) |decoded| {
                        var animation = decoded;
                        const retained = fixed.end_index;
                        try std.testing.expectEqual(fixture[2].len, animation.frames.len);
                        for (
                            animation.frames,
                            fixture[2],
                        ) |frame, expected| try std.testing.expectEqualSlices(
                            Sample,
                            expected,
                            frame.pixels,
                        );
                        if (Animation(
                            Sample,
                        ).Player.initCapacity(failing.allocator(), &animation, .{})) |prepared| {
                            var player = prepared;
                            const live = fixed.end_index;
                            const requests = failing.alloc_index;
                            const address = player.canvas.ptr;
                            for (0..2) |_| {
                                player.reset();
                                for (fixture[3], 0..) |expected, index| {
                                    const visible = player.next().?;
                                    try std.testing.expectEqual(index, visible.index);
                                    try std.testing.expectEqual(address, visible.pixels.ptr);
                                    try std.testing.expectEqualSlices(
                                        Sample,
                                        &expected,
                                        visible.pixels,
                                    );
                                }
                            }
                            try std.testing.expectEqual(live, fixed.end_index);
                            try std.testing.expectEqual(requests, failing.alloc_index);
                            player.deinit(failing.allocator());
                            succeeded = true;
                        } else |failure| try std.testing.expectEqual(error.OutOfMemory, failure);
                        try std.testing.expectEqual(retained, fixed.end_index);
                        animation.deinit(failing.allocator());
                    } else |failure| try std.testing.expectEqual(error.OutOfMemory, failure);
                    try std.testing.expectEqual(17, fixed.end_index);
                    for (fixed.buffer[0..17]) |byte| try std.testing.expectEqual(0x3c, byte);
                    for (backing[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
                    for (
                        backing[backing.len - 8 ..],
                    ) |byte| try std.testing.expectEqual(0xa5, byte);
                    if (succeeded) break;
                }
            }
        }
    }
}

test "APNG final previous disposal needs only canvas storage across plays and completion" {
    // Python zlib 1.3.2 framed these two 2x1 RGBA8 frames independently. First-frame OVER includes
    // a transparent blue pixel; every new play must start from transparent black. The final SOURCE
    // frame uses PREVIOUS disposal, which no following frame observes.
    const source = &[_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0xf4, 0x22, 0x7f,
        0x8a, 0x00, 0x00, 0x00, 0x08, 0x61, 0x63, 0x54,
        0x4c, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
        0x02, 0x1d, 0x83, 0xf2, 0x5c, 0x00, 0x00, 0x00,
        0x1a, 0x66, 0x63, 0x54, 0x4c, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x0a, 0x00, 0x01, 0x8e,
        0x2e, 0x86, 0xef, 0x00, 0x00, 0x00, 0x0d, 0x49,
        0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf,
        0xc0, 0x00, 0x46, 0x00, 0x0e, 0xfa, 0x02, 0xfe,
        0xf5, 0x1e, 0x4c, 0xa9, 0x00, 0x00, 0x00, 0x1a,
        0x66, 0x63, 0x54, 0x4c, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x0a, 0x02, 0x00, 0x50, 0x6c,
        0x3e, 0x2f, 0x00, 0x00, 0x00, 0x14, 0x66, 0x64,
        0x41, 0x54, 0x00, 0x00, 0x00, 0x02, 0x78, 0x9c,
        0x63, 0x60, 0xf8, 0xcf, 0xf0, 0xff, 0x3f, 0x10,
        0x03, 0x00, 0x13, 0xf5, 0x04, 0xfc, 0xc0, 0xb9,
        0x63, 0x4e, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    inline for (.{ .{ u8, 255 }, .{ u16, 65535 } }) |control| {
        const Sample = control[0];
        const maximum = control[1];
        var animation = try allocWithScratch(
            Sample,
            std.testing.allocator,
            std.testing.allocator,
            source,
            .{},
        );
        defer animation.deinit(std.testing.allocator);
        try std.testing.expectEqual(2, animation.frames.len);
        try std.testing.expectEqual(.previous, animation.frames[1].control.dispose);
        const canvas_bytes = 8 * @sizeOf(Sample);
        var backing: [32]u8 align(8) = @splat(0xa5);
        var fixed: std.heap.FixedBufferAllocator = .init(backing[4..][0..canvas_bytes]);
        var tracked: std.testing.FailingAllocator = .init(fixed.allocator(), .{});
        var player = try Animation(
            Sample,
        ).Player.initCapacity(
            tracked.allocator(),
            &animation,
            .{ .limits = .{ .maximum_output_bytes = canvas_bytes, .maximum_work_units = 72 } },
        );
        try std.testing.expectEqual(canvas_bytes, player.allocation.len);
        try std.testing.expectEqual(0, player.backup.len);
        try std.testing.expectEqual(1, tracked.alloc_index);
        const canvases = [2][8]Sample{
            .{ maximum, 0, 0, maximum, 0, 0, 0, 0 },
            .{ 0, maximum, 0, maximum, maximum, maximum, 0, maximum },
        };
        for (0..2) |play| {
            for (canvases, 0..) |expected, index| {
                const visible = player.next().?;
                try std.testing.expectEqual(index, visible.index);
                try std.testing.expectEqual(play, visible.play_index);
                try std.testing.expectEqualSlices(Sample, &expected, visible.pixels);
                try std.testing.expectEqual(
                    Delay{ .numerator = 1, .denominator = 10 },
                    visible.delay,
                );
            }
        }
        for (0..2) |_| {
            try std.testing.expectEqual(null, player.next());
            try std.testing.expectEqualSlices(Sample, &canvases[1], player.canvas);
        }
        player.reset();
        for (player.canvas) |value| try std.testing.expectEqual(0, value);
        try std.testing.expectEqualSlices(Sample, &canvases[0], player.next().?.pixels);
        try std.testing.expectEqual(1, tracked.alloc_index);
        player.deinit(tracked.allocator());
        try std.testing.expectEqual(0, fixed.end_index);
        try std.testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
        for (backing[0..4]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (backing[4 + canvas_bytes ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        var denied: std.testing.FailingAllocator = .init(
            std.testing.allocator,
            .{ .fail_index = 0 },
        );
        try std.testing.expectError(
            error.OutputBudgetExceeded,
            Animation(
                Sample,
            ).Player.initCapacity(
                denied.allocator(),
                &animation,
                .{ .limits = .{ .maximum_output_bytes = canvas_bytes - 1 } },
            ),
        );
        try std.testing.expect(!denied.has_induced_failure);
    }
}

test "APNG word playback restores exact padded backing and rejects one byte less" {
    const allocator = std.testing.allocator;
    const source = try std.testing.allocator.dupe(u8, png_animation_vectors.outside16);
    defer allocator.free(source);
    var animation = try allocWithScratch(u16, allocator, allocator, source, .{});
    defer animation.deinit(allocator);
    var reference = try Animation(u16).Player.initCapacity(allocator, &animation, .{});
    defer reference.deinit(allocator);
    // Independent fixture geometry: 2x2 RGBA canvas and one 1x1 interior PREVIOUS rectangle.
    try std.testing.expectEqual(16, reference.canvas.len);
    try std.testing.expectEqual(4, reference.backup.len);
    const logical = 40;
    const complete = logical + 1; // A byte owner starts at odd-address prefix seventeen.
    const backing = try allocator.alignedAlloc(u8, .@"8", 17 + complete + 16);
    defer allocator.free(backing);
    inline for (.{ false, true }) |decline_resize| {
        var index: usize = 0;
        while (true) : (index += 1) {
            try std.testing.expect(index < 3);
            @memset(backing, 0xa5);
            var fixed = std.heap.FixedBufferAllocator.init(backing[8 .. backing.len - 8]);
            @memset(try fixed.allocator().alloc(u8, 17), 0x3c);
            var failing = std.testing.FailingAllocator.init(
                fixed.allocator(),
                .{
                    .fail_index = index,
                    .resize_fail_index = if (decline_resize) 0 else std.math.maxInt(usize),
                },
            );
            var succeeded = false;
            if (Animation(
                u16,
            ).Player.initCapacity(
                failing.allocator(),
                &animation,
                .{ .limits = .{ .maximum_output_bytes = logical } },
            )) |prepared| {
                var player = prepared;
                try std.testing.expectEqual(17 + complete, fixed.end_index);
                const requests = failing.alloc_index;
                for (0..2) |_| {
                    player.reset();
                    for (
                        png_animation_vectors.outside16_canvases,
                    ) |expected| try std.testing.expectEqualSlices(
                        u16,
                        &expected,
                        player.next().?.pixels,
                    );
                }
                try std.testing.expectEqual(requests, failing.alloc_index);
                player.deinit(failing.allocator());
                succeeded = true;
            } else |failure| try std.testing.expectEqual(error.OutOfMemory, failure);
            try std.testing.expectEqual(17, fixed.end_index);
            for (fixed.buffer[0..17]) |byte| try std.testing.expectEqual(0x3c, byte);
            for (backing[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
            for (backing[backing.len - 8 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
            if (succeeded) break;
        }
        var fixed = std.heap.FixedBufferAllocator.init(backing[8 .. backing.len - 9]);
        @memset(try fixed.allocator().alloc(u8, 17), 0x3c);
        var failing = std.testing.FailingAllocator.init(
            fixed.allocator(),
            .{ .resize_fail_index = if (decline_resize) 0 else std.math.maxInt(usize) },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            Animation(
                u16,
            ).Player.initCapacity(
                failing.allocator(),
                &animation,
                .{ .limits = .{ .maximum_output_bytes = logical } },
            ),
        );
        try std.testing.expectEqual(17, fixed.end_index);
    }
}

fn testInitialize(comptime Sample: type) fn (std.mem.Allocator, []const u8) anyerror!void {
    return struct {
        fn run(allocator: std.mem.Allocator, source: []const u8) !void {
            var animation = try allocWithScratch(Sample, allocator, allocator, source, .{});
            defer animation.deinit(allocator);
            var player = try Animation(Sample).Player.initCapacity(allocator, &animation, .{});
            defer player.deinit(allocator);
            _ = player.next();
        }
    }.run;
}

test "APNG malformed later frame and excluded default cannot publish an animation" {
    const allocator = std.testing.allocator;
    const backing = try allocator.alignedAlloc(u8, .@"8", 512 * 1024 + 16);
    defer allocator.free(backing);
    for ([_][]const u8{ png_animation_vectors.rgba8, png_animation_vectors.outside8 }) |encoded| {
        const source = try std.testing.allocator.dupe(u8, encoded);
        defer std.testing.allocator.free(source);
        const offset = testChunk(
            source,
            if (std.mem.eql(u8, encoded, png_animation_vectors.rgba8)) "fdAT" else "IDAT",
            if (std.mem.eql(u8, encoded, png_animation_vectors.rgba8)) 27 else 0,
        );
        const length = std.mem.readInt(u32, source[offset..][0..4], .big);
        source[offset + 8 + length - 1] ^= 1; // Adler footer, with chunk CRC refreshed.
        testRefreshCrc(source, offset);
        // Structure is valid; entropy is a separate promise.
        _ = try AnimationSource.open(source, .{});
        try std.testing.expectError(
            error.InvalidPng,
            allocWithScratch(u8, std.testing.allocator, std.testing.allocator, source, .{}),
        );
        inline for (.{ false, true }) |shared_scratch| {
            @memset(backing, 0xa5);
            var fixed = std.heap.FixedBufferAllocator.init(backing[8 .. backing.len - 8]);
            @memset(try fixed.allocator().alloc(u8, 17), 0x3c);
            try std.testing.expectError(
                error.InvalidPng,
                allocWithScratch(
                    u8,
                    fixed.allocator(),
                    if (shared_scratch) fixed.allocator() else allocator,
                    source,
                    .{},
                ),
            );
            try std.testing.expectEqual(17, fixed.end_index);
            for (fixed.buffer[0..17]) |byte| try std.testing.expectEqual(0x3c, byte);
            for (backing[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
            for (backing[backing.len - 8 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
    }
}

test "APNG excluded posters use bounded rows and preserve resource admission" {
    const allocator = std.testing.allocator;
    inline for (.{ u8, u16 }) |Sample| {
        for ([_]encoding.Interlace{ .none, .adam7 }) |interlace| {
            for ([_]u32{ 1024, 2048 }) |height| {
                const width = 32;
                const poster = try allocator.alloc(Sample, width * height * 4);
                defer allocator.free(poster);
                @memset(poster, if (Sample == u8) 0x6c else 0x6c93);
                const expected = if (Sample == u8) [_]u8{
                    0x12, 0x34, 0x56, 0x78,
                } else [_]u16{ 0x1234, 0x5678, 0x9abc, 0xdef0 };
                const source = try encoding.allocWithScratch(
                    allocator,
                    allocator,
                    .{
                        .width = width,
                        .height = height,
                        .color_type = .rgba,
                        .bit_depth = @bitSizeOf(Sample),
                        .poster = if (Sample == u8) .{
                            .packed_bytes = .{ .bytes = poster },
                        } else .{ .words = .{ .values = poster } },
                        .frames = &.{
                            .{
                                .width = 1,
                                .height = 1,
                                .x = width - 1,
                                .y = height - 1,
                                .delay = .{ .numerator = 1, .denominator = 10 },
                                .samples = if (Sample == u8) .{
                                    .packed_bytes = .{ .bytes = &expected },
                                } else .{ .words = .{ .values = &expected } },
                            },
                        },
                    },
                    .{
                        .filter = .{ .fixed = .none },
                        .compression = .{ .level = 3 },
                        .interlace = interlace,
                    },
                );
                defer allocator.free(source);
                const admitted = try AnimationSource.open(source, .{});
                const scratch_bytes = Inflater.history_bytes + @sizeOf(
                    Inflater,
                ) + @alignOf(Inflater) - 1 + admitted.default_image.packed_row_bytes * 2;
                const work = source.len + admitted.compressed_bytes + admitted.default_image
                    .image_data.byte_count + (admitted.filtered_bytes + admitted.default_image
                    .filtered_byte_count) * 4;
                const storage = try allocator.alloc(u8, scratch_bytes + 17 + 16);
                defer allocator.free(storage);
                @memset(storage, 0xa5);
                var backing = std.heap.FixedBufferAllocator.init(
                    storage[8..][0 .. scratch_bytes + 17],
                );
                const prefix = try backing.allocator().alloc(u8, 17);
                @memset(prefix, 0x3c);
                const scratch_allocator = backing.allocator();
                const options: Options = .{
                    .limits = .{
                        .maximum_pixels = width * height,
                        .maximum_output_bytes = poster.len * @sizeOf(Sample),
                        .maximum_work_units = work,
                        .maximum_scratch_bytes = scratch_bytes,
                    },
                };
                for (0..2) |_| {
                    var decoded = try allocWithScratch(
                        Sample,
                        allocator,
                        scratch_allocator,
                        source,
                        options,
                    );
                    defer decoded.deinit(allocator);
                    try std.testing.expect(!decoded.default_is_frame);
                    try std.testing.expectEqual(1, decoded.frames.len);
                    try std.testing.expectEqualSlices(Sample, &expected, decoded.frames[0].pixels);
                    try std.testing.expectEqual(17, backing.end_index);
                }
                var limited = options;
                limited.limits.maximum_work_units -= 1;
                try std.testing.expectError(
                    error.WorkBudgetExceeded,
                    allocWithScratch(
                        Sample,
                        std.testing.failing_allocator,
                        scratch_allocator,
                        source,
                        limited,
                    ),
                );
                limited = options;
                limited.limits.maximum_pixels -= 1;
                try std.testing.expectError(
                    error.PixelBudgetExceeded,
                    allocWithScratch(
                        Sample,
                        std.testing.failing_allocator,
                        scratch_allocator,
                        source,
                        limited,
                    ),
                );
                limited = options;
                limited.limits.maximum_output_bytes -= 1;
                try std.testing.expectError(
                    error.OutputBudgetExceeded,
                    allocWithScratch(
                        Sample,
                        std.testing.failing_allocator,
                        scratch_allocator,
                        source,
                        limited,
                    ),
                );
                limited = options;
                limited.limits.maximum_scratch_bytes -= 1;
                try std.testing.expectError(
                    error.ScratchBudgetExceeded,
                    allocWithScratch(
                        Sample,
                        std.testing.failing_allocator,
                        scratch_allocator,
                        source,
                        limited,
                    ),
                );
                backing.buffer = backing.buffer[0 .. backing.buffer.len - 1];
                try std.testing.expectError(
                    error.OutOfMemory,
                    allocWithScratch(
                        Sample,
                        std.testing.failing_allocator,
                        scratch_allocator,
                        source,
                        options,
                    ),
                );
                try std.testing.expectEqual(17, backing.end_index);
                for (prefix) |byte| try std.testing.expectEqual(0x3c, byte);
                for (storage[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
                for (storage[storage.len - 8 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
            }
        }
    }
}

test "APNG endless playback clears every new play and copied output outlives source" {
    const source = try std.testing.allocator.dupe(u8, png_animation_vectors.outside16);
    const offset = testChunk(source, "acTL", 0);
    std.mem.writeInt(u32, source[offset + 12 ..][0..4], 0, .big);
    testRefreshCrc(source, offset);
    var animation = try allocWithScratch(
        u16,
        std.testing.allocator,
        std.testing.allocator,
        source,
        .{},
    );
    std.testing.allocator.free(source);
    defer animation.deinit(std.testing.allocator);
    var player = try Animation(u16).Player.initCapacity(std.testing.allocator, &animation, .{});
    defer player.deinit(std.testing.allocator);
    for (0..4) |play| {
        for (png_animation_vectors.outside16_canvases) |expected| {
            const actual = player.next().?;
            try std.testing.expectEqualSlices(u16, &expected, actual.pixels);
            try std.testing.expectEqual(play, actual.play_index);
        }
    }
    player.play_index = std.math.maxInt(u64);
    try std.testing.expectEqual(std.math.maxInt(u64), player.next().?.play_index);
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

test "PNG palette recovery covers APNG local frames excluded posters and opaque composition" {
    const fixtures = png_palette_vectors;
    const allocator = std.testing.allocator;
    const canvases8 = [_][12]u8{
        .{ 13, 29, 47, 17, 13, 29, 47, 17, 13, 29, 47, 17 },
        .{ 13, 29, 47, 17, 0, 0, 0, 255, 13, 29, 47, 17 },
        .{ 0, 0, 0, 255, 13, 29, 47, 17, 13, 29, 47, 17 },
        .{ 0, 0, 0, 0, 13, 29, 47, 17, 0, 0, 0, 255 },
    };
    const canvases16 = [_][12]u16{
        .{ 3341, 7453, 12079, 4369, 3341, 7453, 12079, 4369, 3341, 7453, 12079, 4369 },
        .{ 3341, 7453, 12079, 4369, 0, 0, 0, 65535, 3341, 7453, 12079, 4369 },
        .{ 0, 0, 0, 65535, 3341, 7453, 12079, 4369, 3341, 7453, 12079, 4369 },
        .{ 0, 0, 0, 0, 3341, 7453, 12079, 4369, 0, 0, 0, 65535 },
    };
    inline for (.{ u8, u16 }) |Sample| {
        for ([_][]const u8{ fixtures.animation, fixtures.excluded_animation }, 0..) |wire, index| {
            try std.testing.expectError(
                error.InvalidPng,
                allocWithScratch(
                    Sample,
                    allocator,
                    allocator,
                    wire,
                    .{ .palette_index_policy = .reject },
                ),
            );
            var animation = try allocWithScratch(
                Sample,
                allocator,
                allocator,
                wire,
                .{ .palette_index_policy = .opaque_black },
            );
            defer animation.deinit(allocator);
            try std.testing.expectEqual(index == 0, animation.default_is_frame);
            try std.testing.expectEqual(4, animation.frames.len);
            const valid: []const Sample = if (Sample == u8) &canvases8[0] else &canvases16[0];
            const black: []const Sample = if (Sample == u8) &.{
                0, 0, 0, 255,
            } else &.{ 0, 0, 0, 65535 };
            try std.testing.expectEqualSlices(Sample, valid, animation.frames[0].pixels);
            for (
                animation.frames[1..],
            ) |frame| try std.testing.expectEqualSlices(Sample, black, frame.pixels);
            var player = try Animation(Sample).Player.initCapacity(allocator, &animation, .{});
            defer player.deinit(allocator);
            for (0..2) |_| {
                for (0..4) |ordinal| {
                    const frame = player.next().?;
                    const expected: []const Sample = if (Sample == u8)
                        &canvases8[ordinal]
                    else
                        &canvases16[ordinal];
                    try std.testing.expectEqual(ordinal, frame.index);
                    try std.testing.expectEqualSlices(Sample, expected, frame.pixels);
                }
                try std.testing.expectEqual(null, player.next());
                player.reset();
            }
        }
        try std.testing.checkAllAllocationFailures(allocator, struct {
            fn run(backing: std.mem.Allocator) !void {
                var animation = try allocWithScratch(
                    Sample,
                    backing,
                    backing,
                    fixtures.excluded_animation,
                    .{ .palette_index_policy = .opaque_black },
                );
                defer animation.deinit(backing);
                var player = try Animation(Sample).Player.initCapacity(backing, &animation, .{});
                defer player.deinit(backing);
                while (player.next()) |_| {}
            }
        }.run, .{});
    }
}
