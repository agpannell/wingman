//! Complete RIFF/WAVE and RF64 audio decoding, plus mono/stereo PCM16 writing. A frame contains one
//! sample per channel. Decoding returns interleaved f32 samples in source channel order, preserving
//! rate and an optional extensible speaker mask without resampling. Integer PCM, G.711, Microsoft
//! ADPCM and IMA/DVI WAVE blocks normalize to f32; finite binary32 samples retain their values,
//! including values outside [-1, 1]. Data chunks must be top-level and individually frame/block
//! aligned; LIST/wavl and slnt are not decoded. RIFX, Wave64 and BW64 containers are unsupported.
//! Microsoft ADPCM blocks whose adaptive delta exceeds signed 32-bit range are rejected.
//!
//! Use decodeAlloc for an independent sample owner, or decodeRequirements and decodeInto with
//! explicit sample/directory storage. ADPCM fact counts select a frame prefix while every encoded
//! block remains validated. Chunk inspection borrows source bytes. Allocating operations retain no
//! allocator; parallel variants borrow std.Io and bounded caller workers until all jobs finish.
//! Writing supports finite normalized mono/stereo PCM16 RIFF, within its 32-bit size limit.

const std = @import("std");
const builtin = @import("builtin");
const riff = @import("riff.zig");
const pcm = @import("pcm.zig");
const memory = @import("wav/storage.zig");
const container = @import("wav/container.zig");
const format = @import("wav/format.zig");
const parallel = @import("wav/parallel.zig");
const testing = std.testing;
const fixtures = @import("wav/fixtures.zig");

pub const Container = container.Container;
pub const ChunkIterator = container.ChunkIterator;
pub const ChunkIndexEntry = container.ChunkIndexEntry;
pub const Rf64Sizes = container.Rf64Sizes;
pub const parse = container.parse;
pub const ParseError = container.ParseError;
pub const Channels = format.Channels;
pub const Format = format.Format;
pub const Encoding = format.Encoding;
pub const parseFormat = format.parseFormat;
pub const frameCount = format.frameCount;
pub const FormatError = format.FormatError;
pub const Worker = parallel.Worker;
pub const ParallelOptions = parallel.ParallelOptions;

/// Malformed or unsupported WAVE, sample/size failure, or insufficient/aliased caller storage.
pub const DecodeError = ParseError || FormatError || parallel.ConversionError || error{
    DestinationTooSmall,
};

/// Allocating decode also reports allocation exhaustion. Partial ownership is released on error.
pub const DecodeAllocError = DecodeError || std.mem.Allocator.Error;

/// Cancellation ends every work borrow before return; caller output remains unpublished on error.
pub const ParallelDecodeError = DecodeError || std.Io.Cancelable;

/// Allocating parallel decode combines source/storage failures, exhaustion and cancellation.
pub const ParallelDecodeAllocError = DecodeAllocError || std.Io.Cancelable;

/// Invalid rate/layout/samples, unrepresentable PCM16 RIFF output or caller storage refusal.
pub const EncodeError = pcm.EncodeError || error{ InvalidRate, UnsupportedWave };

/// Borrowed interleaved audio. Samples remain owned by their source reservation; metadata is
/// copied. Null speaker mask means ordinary WAVE metadata; a zero mask means unspecified
/// assignments.
pub const AudioView = struct {
    sample_rate: u32,
    channels: Channels,
    samples: []const f32,
    channel_mask: ?u32 = null,
};

/// Owns naturally aligned interleaved samples independently of encoded source and scratch. The
/// complete byte owner includes alignment padding. Copies share ownership; release it exactly once
/// with the original allocator after all sample borrows retire. No allocator is retained.
pub const Audio = struct {
    sample_rate: u32,
    channels: Channels,
    samples: []f32,
    allocation: []u8,
    channel_mask: ?u32 = null,

    /// Borrows immutable samples and copied metadata until this owner is modified or released.
    pub fn view(self: Audio) AudioView {
        return .{
            .sample_rate = self.sample_rate,
            .channels = self.channels,
            .samples = self.samples,
            .channel_mask = self.channel_mask,
        };
    }

    /// Releases the complete reservation, including padding, and invalidates every sample borrow.
    pub fn deinit(self: *Audio, allocator: std.mem.Allocator) void {
        allocator.free(self.allocation);
        self.* = undefined;
    }
};

/// Complete-file geometry, not proof that encoded sample/block contents are valid. Format metadata
/// is copied except Microsoft coefficient bytes, which borrow the source until conversion retires.
pub const DecodeRequirements = struct {
    format: Format,
    frames: usize,
    samples: usize,
    sample_bytes: usize,
    directory_entries: usize,
};

/// Inspects the complete container, format and data geometry, including global ADPCM fact trimming.
/// Reserve parse(source).scratchCount() directory entries first; scratch is exclusive to each pass.
/// Unknown chunks are skipped and data may precede fmt. Samples and predictor state remain
/// unchecked.
pub fn decodeRequirements(
    source: []const u8,
    directory_index: []ChunkIndexEntry,
) DecodeError!DecodeRequirements {
    return inspectDataChunks(try parse(source), directory_index);
}

/// Decodes a complete file into independent samples. All temporary scratch and partial ownership
/// retire on failure. Zero frames allocate no sample storage. Metadata/data ordering, multiple data
/// chunks and unknown padded chunks are supported; trailing bytes and duplicate fmt are refused.
pub fn decodeAlloc(allocator: std.mem.Allocator, source: []const u8) DecodeAllocError!Audio {
    return decodeOwned(false, allocator, undefined, source, &.{}, .{});
}

test decodeAlloc {
    var bytes: [56]u8 = undefined;
    const source: AudioView = .{ .sample_rate = 48000, .channels = .stereo, .samples = &.{
        -1, 1, -0.5, 0.5, 0, 0.25,
    } };
    const encoded = try encodePcm16Into(source, &bytes);
    var audio = try decodeAlloc(testing.allocator, encoded);
    defer audio.deinit(testing.allocator);
    try testing.expectEqual(48000, audio.sample_rate);
    try testing.expectEqual(3, audio.samples.len / @as(usize, @backingInt(audio.channels)));
}

/// Decodes into a used caller sample prefix without allocating. Directory scratch comes from
/// parse(source).scratchCount(). Source, destination and used scratch must be disjoint. Capacity
/// and alias refusals precede output writes; content errors can leave partial unpublished samples.
/// The returned view survives scratch retirement and borrows only destination storage.
pub fn decodeInto(
    source: []const u8,
    destination: []f32,
    directory_index: []ChunkIndexEntry,
) DecodeError!AudioView {
    const view = try parse(source);
    try admitStorage(view, destination, directory_index, &.{});
    const requirements = try inspectDataChunks(view, directory_index);
    if (destination.len < requirements.samples) return error.DestinationTooSmall;
    const output = destination[0..requirements.samples];
    try decodeDataChunks(
        false,
        undefined,
        view,
        directory_index,
        requirements.format,
        output,
        &.{},
        .{},
    );
    return audioView(requirements.format, output);
}

test decodeInto {
    var encoded: [48]u8 = undefined;
    const source: AudioView = .{ .sample_rate = 8000, .channels = .mono, .samples = &.{ -1, 0.5 } };
    const bytes = try encodePcm16Into(source, &encoded);
    const container_view = try parse(bytes);
    // Ordinary RIFF has no RF64 directory, so this example needs no index entries.
    try testing.expectEqual(0, container_view.scratchCount());
    const required = try decodeRequirements(bytes, &.{});
    var samples: [2]f32 = undefined;
    const audio = try decodeInto(bytes, &samples, &.{});
    try testing.expectEqual(required.samples, audio.samples.len);
    try testing.expectEqualSlices(f32, source.samples, audio.samples);
}

/// Allocating complete-file decode using explicit std.Io and bounded workers, including the caller.
/// The provider may run jobs inline and controls its own scheduling allocations. Every submitted
/// job finishes before success, error or cancellation returns. Source/worker borrows do not escape.
pub fn decodeParallelAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    workers: []Worker,
    options: ParallelOptions,
) ParallelDecodeAllocError!Audio {
    if (memory.overlaps(source, std.mem.sliceAsBytes(workers))) return error.Aliasing;
    return decodeOwned(true, allocator, io, source, workers, options);
}

test decodeParallelAlloc {
    if (builtin.single_threaded) return error.SkipZigTest;
    const allocator = testing.allocator;
    var provider = std.Io.Threaded.init(allocator, .{ .async_limit = .limited(3) });
    defer provider.deinit();
    var bytes: [56]u8 = undefined;
    const source: AudioView = .{ .sample_rate = 48000, .channels = .stereo, .samples = &.{
        -1, 1, -0.5, 0.5, 0, 0.25,
    } };
    const encoded = try encodePcm16Into(source, &bytes);
    var workers: [4]Worker = undefined;
    var audio = try decodeParallelAlloc(allocator, provider.io(), encoded, &workers, .{});
    defer audio.deinit(allocator);
    try testing.expectEqual(6, audio.samples.len);
}

/// Parallel decode into caller samples without library allocation. Worker, sample and used index
/// reservations must be pairwise disjoint and disjoint from source. All submitted work retires on
/// every exit, including Canceled. Failed output remains unpublished, even if some jobs completed.
pub fn decodeParallelInto(
    io: std.Io,
    source: []const u8,
    destination: []f32,
    directory_index: []ChunkIndexEntry,
    workers: []Worker,
    options: ParallelOptions,
) ParallelDecodeError!AudioView {
    const view = try parse(source);
    try admitStorage(view, destination, directory_index, workers);
    const requirements = try inspectDataChunks(view, directory_index);
    if (destination.len < requirements.samples) return error.DestinationTooSmall;
    const output = destination[0..requirements.samples];
    try decodeDataChunks(
        true,
        io,
        view,
        directory_index,
        requirements.format,
        output,
        workers,
        options,
    );
    return audioView(requirements.format, output);
}

fn audioView(info: Format, samples: []const f32) AudioView {
    return .{
        .sample_rate = info.sample_rate,
        .channels = info.channels,
        .samples = samples,
        .channel_mask = info.channel_mask,
    };
}

fn admitStorage(
    view: Container,
    destination: []f32,
    directory_index: []ChunkIndexEntry,
    workers: []Worker,
) DecodeError!void {
    const entries = view.scratchCount();
    if (directory_index.len < entries) return error.InsufficientScratch;
    const index_bytes = std.mem.sliceAsBytes(directory_index[0..entries]);
    const samples = std.mem.sliceAsBytes(destination);
    const work = std.mem.sliceAsBytes(workers);
    if (memory.overlaps(
        view.source,
        samples,
    ) or memory.overlaps(
        view.source,
        index_bytes,
    ) or memory.overlaps(
        view.source,
        work,
    ) or memory.overlaps(
        samples,
        index_bytes,
    ) or memory.overlaps(
        samples,
        work,
    ) or memory.overlaps(index_bytes, work)) return error.Aliasing;
}

fn decodeOwned(
    comptime scheduled: bool,
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    workers: []Worker,
    options: ParallelOptions,
) (if (scheduled) ParallelDecodeAllocError else DecodeAllocError)!Audio {
    const view = try parse(source);
    const requirements = blk: {
        const index = try allocator.alloc(ChunkIndexEntry, view.scratchCount());
        defer allocator.free(index);
        break :blk try inspectDataChunks(view, index);
    };
    const owner = try memory.allocateSamples(allocator, requirements.samples);
    errdefer allocator.free(owner.storage);
    // Retire inspection scratch before samples exist, then reacquire conversion scratch above them.
    // This order lets a tail-reclaiming allocator free both the index and all sample padding.
    const index = try allocator.alloc(ChunkIndexEntry, view.scratchCount());
    defer allocator.free(index);
    try decodeDataChunks(
        scheduled,
        io,
        view,
        index,
        requirements.format,
        owner.samples,
        workers,
        options,
    );
    return .{
        .sample_rate = requirements.format.sample_rate,
        .channels = requirements.format.channels,
        .samples = owner.samples,
        .allocation = owner.storage,
        .channel_mask = requirements.format.channel_mask,
    };
}

fn inspectDataChunks(
    view: Container,
    directory_index: []ChunkIndexEntry,
) DecodeError!DecodeRequirements {
    var chunks = try view.iterator(directory_index);
    var format_bytes: ?[]const u8 = null;
    var fact_frames: ?u32 = null;
    var saw_data = false;
    while (try chunks.next()) |chunk| {
        if (std.mem.eql(u8, chunk.id, "fmt ")) {
            if (format_bytes != null) return error.UnsupportedWave;
            format_bytes = chunk.data;
        } else if (std.mem.eql(u8, chunk.id, "data")) {
            saw_data = true;
        } else if (std.mem.eql(u8, chunk.id, "fact")) {
            if (fact_frames != null or chunk.data.len < 4) return error.InvalidWave;
            fact_frames = std.mem.readInt(u32, chunk.data[0..4], .little);
        }
    }
    const info = try parseFormat(format_bytes orelse return error.InvalidWave);
    if (!saw_data) return error.InvalidWave;
    const complete = try countDataSamples(view, directory_index, info);
    const count: usize = blk: {
        if (info.encoding != .ima_adpcm and info.encoding != .ms_adpcm) break :blk complete;
        const fact = fact_frames orelse break :blk complete;
        const frames: u64 = if (fact == std.math.maxInt(
            u32,
        ) and view.rf64_sizes != null) view.rf64_sizes.?.sample_count else fact;
        const channels: usize = @backingInt(info.channels);
        if (frames > complete / channels) return error.InvalidWave;
        break :blk @as(usize, @intCast(frames)) * channels;
    };
    const bytes = std.math.mul(usize, count, @sizeOf(f32)) catch return error.SizeOverflow;
    return .{
        .format = info,
        .frames = count / @as(usize, @backingInt(info.channels)),
        .samples = count,
        .sample_bytes = bytes,
        .directory_entries = view.scratchCount(),
    };
}

fn countDataSamples(
    view: Container,
    directory_index: []ChunkIndexEntry,
    info: Format,
) DecodeError!usize {
    var chunks = try view.iterator(directory_index);
    var count: usize = 0;
    while (try chunks.next()) |chunk| {
        if (std.mem.eql(u8, chunk.id, "data")) {
            const frames = try frameCount(info, chunk.data.len);
            const samples = std.math.mul(
                usize,
                frames,
                @backingInt(info.channels),
            ) catch return error.SizeOverflow;
            count = std.math.add(usize, count, samples) catch return error.SizeOverflow;
        }
    }
    return count;
}

fn decodeDataChunks(
    comptime scheduled: bool,
    io: std.Io,
    view: Container,
    directory_index: []ChunkIndexEntry,
    info: Format,
    samples: []f32,
    workers: []Worker,
    options: ParallelOptions,
) (if (scheduled) ParallelDecodeError else DecodeError)!void {
    var chunks = try view.iterator(directory_index);
    var offset: usize = 0;
    while (try chunks.next()) |chunk| {
        if (std.mem.eql(u8, chunk.id, "data")) {
            if (chunk.data.len == 0) continue;
            const frames = try frameCount(info, chunk.data.len);
            const count = std.math.mul(
                usize,
                frames,
                @backingInt(info.channels),
            ) catch return error.SizeOverflow;
            const complete_end = std.math.add(usize, offset, count) catch return error.SizeOverflow;
            const end = @min(complete_end, samples.len);
            // Keep complete conversion independent from container-directory register state. Even an
            // empty retained prefix must validate every omitted ADPCM block.
            if (scheduled) {
                try @call(
                    .never_inline,
                    parallel.convertParallel,
                    .{ io, info, chunk.data, samples[offset..end], workers, options },
                );
            } else {
                try @call(
                    .never_inline,
                    parallel.convert,
                    .{ info, chunk.data, samples[offset..end] },
                );
            }
            offset = end;
        }
    }
    if (offset != samples.len) return error.InvalidWave;
}

/// Returns complete PCM16 RIFF output bytes after validating rate, mono/stereo frame geometry and
/// every finite sample in [-1, 1]. Size arithmetic is checked before any writer mutation.
pub fn encodePcm16Requirements(source: AudioView) EncodeError!usize {
    const channels: u32 = @backingInt(source.channels);
    if (source.sample_rate == 0) return error.InvalidRate;
    if (channels == 0) return error.InvalidSamples;
    if (channels > 2) return error.UnsupportedWave;
    if (source.samples.len % channels != 0) return error.InvalidSamples;
    if (source.samples.len > (std.math.maxInt(u32) - 36) / 2) return error.SizeOverflow;
    _ = std.math.mul(u32, source.sample_rate, channels * 2) catch return error.InvalidRate;
    try pcm.validatePcm16(source.samples);
    return std.math.add(usize, 44, source.samples.len * 2) catch error.SizeOverflow;
}

/// Writes complete normalized mono/stereo PCM16 RIFF. Invalid input leaves the writer untouched;
/// writer failure may leave a prefix. Samples must be disjoint from writer storage. Rounding uses
/// nearest integer without dithering; endpoints map to -32768/32767. Extensible speaker-mask
/// metadata is not encoded. The caller owns flushing.
pub fn writePcm16(
    source: AudioView,
    writer: *std.Io.Writer,
) (EncodeError || std.Io.Writer.Error)!void {
    const bytes = try encodePcm16Requirements(source);
    try writePcm16Admitted(source, bytes, writer);
}

test writePcm16 {
    const source: AudioView = .{ .sample_rate = 8000, .channels = .mono, .samples = &.{ -1, 0.5 } };
    var bytes: [48]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writePcm16(source, &writer);
    try testing.expectEqual(48, writer.buffered().len);
    try testing.expectEqualSlices(u8, &.{ 0, 128, 0, 64 }, writer.buffered()[44..]);
}

/// Writes a complete file into a used caller byte prefix. Admission failures preserve the entire
/// destination, including unused capacity. Input samples and output must be disjoint.
pub fn encodePcm16Into(source: AudioView, destination: []u8) EncodeError![]u8 {
    const bytes = try encodePcm16Requirements(source);
    if (destination.len < bytes) return error.DestinationTooSmall;
    const output = destination[0..bytes];
    if (memory.overlaps(std.mem.sliceAsBytes(source.samples), output)) return error.Aliasing;
    var writer = std.Io.Writer.fixed(output);
    writePcm16Admitted(source, bytes, &writer) catch unreachable;
    return output;
}

test encodePcm16Into {
    var bytes: [48]u8 = undefined;
    const audio: AudioView = .{ .sample_rate = 8000, .channels = .mono, .samples = &.{ -1, 1 } };
    const encoded = try encodePcm16Into(audio, &bytes);
    var decoded = try decodeAlloc(testing.allocator, encoded);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualSlices(f32, &.{ -1, 32767.0 / 32768.0 }, decoded.samples);
}

fn writePcm16Admitted(
    source: AudioView,
    bytes: usize,
    writer: *std.Io.Writer,
) riff.WriteError!void {
    const channels: u32 = @backingInt(source.channels);
    try riff.writeHeader("WAVE".*, bytes - 12, writer);
    try riff.writeChunkHeader("fmt ".*, 16, writer);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u16, @intCast(channels), .little);
    try writer.writeInt(u32, source.sample_rate, .little);
    try writer.writeInt(u32, source.sample_rate * channels * 2, .little);
    try writer.writeInt(u16, @intCast(channels * 2), .little);
    try writer.writeInt(u16, 16, .little);
    try riff.writeChunkHeader("data".*, source.samples.len * 2, writer);
    pcm.writePcm16(source.samples, writer) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        else => unreachable,
    };
}

test {
    _ = container;
    _ = format;
    _ = parallel;
}

fn testParallelDecode(allocator: std.mem.Allocator, source: []const u8) !Audio {
    var provider: TestIo = .{};
    var workers: [4]Worker = undefined;
    defer std.debug.assert(provider.count == 0);
    return decodeParallelAlloc(
        allocator,
        provider.io(),
        source,
        &workers,
        .{ .minimum_bytes = 0, .minimum_job_bytes = 1 },
    );
}

const TestIo = struct {
    const Pending = struct {
        context: [@sizeOf(*Worker)]u8 align(@alignOf(*Worker)),
        start: *const fn (*const anyopaque) void,
    };
    pending: [7]Pending = undefined,
    count: usize = 0,
    submitted: usize = 0,
    joined: usize = 0,
    canceled: bool = false,

    const vtable: std.Io.VTable = blk: {
        var table = std.Io.failing.vtable.*;
        table.groupAsync = groupAsync;
        table.groupAwait = groupAwait;
        table.groupCancel = groupCancel;
        break :blk table;
    };

    fn groupAsync(
        pointer: ?*anyopaque,
        group: *std.Io.Group,
        context: []const u8,
        alignment: std.mem.Alignment,
        start: *const fn (*const anyopaque) void,
    ) void {
        const self: *TestIo = @ptrCast(@alignCast(pointer.?));
        std.debug.assert(context.len == @sizeOf(*Worker));
        std.debug.assert(alignment == std.mem.Alignment.of(*Worker));
        std.debug.assert(self.count < self.pending.len);
        const task = &self.pending[self.count];
        @memcpy(&task.context, context);
        task.start = start;
        self.count += 1;
        self.submitted += 1;
        group.token.store(self, .release);
    }

    fn drain(self: *TestIo, group: *std.Io.Group) void {
        while (self.count != 0) {
            self.count -= 1;
            const task = &self.pending[self.count];
            task.start(&task.context);
        }
        group.token.store(null, .release);
        self.joined += 1;
    }

    fn groupAwait(
        pointer: ?*anyopaque,
        group: *std.Io.Group,
        _: *anyopaque,
    ) std.Io.Cancelable!void {
        const self: *TestIo = @ptrCast(@alignCast(pointer.?));
        self.drain(group);
        if (self.canceled) return error.Canceled;
    }

    fn groupCancel(pointer: ?*anyopaque, group: *std.Io.Group, _: *anyopaque) void {
        const self: *TestIo = @ptrCast(@alignCast(pointer.?));
        self.drain(group);
    }

    fn io(self: *TestIo) std.Io {
        return .{ .userdata = self, .vtable = &vtable };
    }
};

test "invalid PCM preserves output and writer exhaustion is returned" {
    var bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writer.writeByte(0x55);
    try std.testing.expectError(
        error.InvalidRate,
        writePcm16(.{ .sample_rate = 0, .channels = .mono, .samples = &.{} }, &writer),
    );
    try std.testing.expectError(
        error.InvalidRate,
        writePcm16(
            .{ .sample_rate = std.math.maxInt(u32), .channels = .stereo, .samples = &.{} },
            &writer,
        ),
    );
    try std.testing.expectError(
        error.UnsupportedWave,
        writePcm16(
            .{ .sample_rate = 48000, .channels = @fromBackingInt(@intCast(6)), .samples = &.{} },
            &writer,
        ),
    );
    try std.testing.expectError(
        error.InvalidSamples,
        writePcm16(.{ .sample_rate = 48000, .channels = .stereo, .samples = &.{0} }, &writer),
    );
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -1.01, 1.01 }) |value| {
        try std.testing.expectError(
            error.InvalidSamples,
            writePcm16(.{ .sample_rate = 48000, .channels = .mono, .samples = &.{value} }, &writer),
        );
    }
    try std.testing.expectEqualSlices(u8, &.{0x55}, writer.buffered());
    var short = std.Io.Writer.fixed(bytes[0..43]);
    try std.testing.expectError(
        error.WriteFailed,
        writePcm16(.{ .sample_rate = 48000, .channels = .mono, .samples = &.{0} }, &short),
    );
}

test "stereo RIFF bytes carry exact sizes rates order and signed PCM endpoints" {
    var bytes: [56]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writePcm16(.{ .sample_rate = 48000, .channels = .stereo, .samples = &.{
        -1, 1, -0.5, 0.5, 0, 0.25,
    } }, &writer);
    try std.testing.expectEqualSlices(u8, fixtures.stereo, writer.buffered());
}

test "mono zero-frame WAV has a complete empty data chunk" {
    var bytes: [44]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try writePcm16(.{ .sample_rate = 8000, .channels = .mono, .samples = &.{} }, &writer);
    try std.testing.expectEqualSlices(u8, fixtures.empty_mono, writer.buffered());
}

test "decoder reads interleaved PCM16 into owned normalized samples" {
    var audio = try decodeAlloc(std.testing.allocator, fixtures.stereo);
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqual(48000, audio.sample_rate);
    try std.testing.expectEqual(Channels.stereo, audio.channels);
    try std.testing.expectEqualSlices(f32, &.{
        -1, 0.999969482421875, -0.5, 0.5, 0, 0.25,
    }, audio.samples);
}

test "decoder concatenates multiple frame-aligned data chunks" {
    var audio = try decodeAlloc(std.testing.allocator, fixtures.stereo_split_data);
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(f32, &.{
        -1, 0.999969482421875, -0.5, 0.5, 0, 0.25,
    }, audio.samples);
}

test "decoder accepts RF64 64-bit chunk sizes" {
    var audio = try decodeAlloc(std.testing.allocator, fixtures.rf64_stereo_with_table);
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqual(48000, audio.sample_rate);
    try std.testing.expectEqual(Channels.stereo, audio.channels);
    try std.testing.expectEqualSlices(f32, &.{
        -1, 0.999969482421875, -0.5, 0.5, 0, 0.25,
    }, audio.samples);
}

test "decoder consumes the RF64 data size once across multiple data chunks" {
    var audio = try decodeAlloc(std.testing.allocator, fixtures.rf64_split_data);
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0.9921875 }, audio.samples);

    var repeated_sentinel = fixtures.rf64_split_data.*;
    const second_data = std.mem.lastIndexOf(u8, &repeated_sentinel, "data") orelse unreachable;
    std.mem.writeInt(
        u32,
        repeated_sentinel[second_data + 4 ..][0..4],
        std.math.maxInt(u32),
        .little,
    );
    try std.testing.expectError(
        error.InvalidWave,
        decodeAlloc(std.testing.allocator, &repeated_sentinel),
    );
}

test "decoder resolves repeated RF64 table IDs using each entry once" {
    var audio = try decodeAlloc(std.testing.allocator, fixtures.rf64_repeated_unknown_chunks);
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqual(8000, audio.sample_rate);
    try std.testing.expectEqual(Channels.mono, audio.channels);
    try std.testing.expectEqualSlices(f32, &.{0}, audio.samples);
}

test "RF64 decoding reuses bounded storage after temporary table usage" {
    const backing = try std.testing.allocator.alignedAlloc(u8, .of(f32), 64);
    defer std.testing.allocator.free(backing);

    for ([_]bool{ false, true }) |use_executor| {
        var fixed = std.heap.FixedBufferAllocator.init(backing);
        const allocator = fixed.allocator();
        const retained = try allocator.alloc(u32, 1);
        defer allocator.free(retained);
        retained[0] = 0x12345678;
        const retained_end = fixed.end_index;

        for (0..32) |iteration| {
            {
                var audio = if (use_executor) try testParallelDecode(
                    allocator,
                    fixtures.rf64_repeated_unknown_chunks,
                ) else try decodeAlloc(allocator, fixtures.rf64_repeated_unknown_chunks);
                defer audio.deinit(allocator);
                try std.testing.expectEqual(8000, audio.sample_rate);
                try std.testing.expectEqual(Channels.mono, audio.channels);
                try std.testing.expectEqualSlices(f32, &.{0}, audio.samples);
                try std.testing.expectEqual(retained_end + @sizeOf(f32), fixed.end_index);
            }
            try std.testing.expectEqual(retained_end, fixed.end_index);
            try std.testing.expectEqual(0x12345678, retained[0]);
            if (iteration == 0) {
                // The fixture has three RF64 table entries and one output sample. Leave room for
                // one decode, so leaked scratch prevents reuse.
                fixed.buffer = backing[0 .. retained_end + @sizeOf(
                    f32,
                ) + 3 * @sizeOf(ChunkIndexEntry)];
            }
        }
    }
}

test "decoder rejects incorrect explicit RF64 outer lengths" {
    var invalid_rf64 = fixtures.rf64_stereo_with_table.*;
    for ([_]usize{ invalid_rf64.len - 9, invalid_rf64.len - 7 }) |incorrect| {
        std.mem.writeInt(u32, invalid_rf64[4..8], @intCast(incorrect), .little);
        try std.testing.expectError(
            error.InvalidWave,
            decodeAlloc(std.testing.allocator, &invalid_rf64),
        );
    }
}

test "decoder accepts an empty PCM data chunk" {
    var audio = try decodeAlloc(std.testing.allocator, fixtures.empty_mono);
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqual(8000, audio.sample_rate);
    try std.testing.expectEqual(Channels.mono, audio.channels);
    try std.testing.expectEqual(@as(usize, 0), audio.samples.len);
}

test "decoder skips padded metadata and accepts chunk reordering" {
    var audio = try decodeAlloc(std.testing.allocator, fixtures.padded_mono_u8);
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqual(8000, audio.sample_rate);
    try std.testing.expectEqual(Channels.mono, audio.channels);
    try std.testing.expectEqualSlices(f32, &.{ -1, 0, 0.9921875 }, audio.samples);
}

test "decoder accepts G.711 mu-law and A-law WAV tags" {
    var mulaw = try decodeAlloc(std.testing.allocator, fixtures.mulaw_mono);
    defer mulaw.deinit(std.testing.allocator);
    try std.testing.expectEqual(8000, mulaw.sample_rate);
    try std.testing.expectEqual(Channels.mono, mulaw.channels);
    try std.testing.expectEqualSlices(f32, &.{
        0, 0, -0.9803466796875, 0.9803466796875,
    }, mulaw.samples);

    var alaw = try decodeAlloc(std.testing.allocator, fixtures.alaw_mono);
    defer alaw.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(f32, &.{
        0.000244140625, -0.000244140625, -0.16796875, 0.16796875,
    }, alaw.samples);

    var invalid_bits = fixtures.mulaw_mono.*;
    std.mem.writeInt(u16, invalid_bits[34..36], 16, .little);
    try std.testing.expectError(
        error.UnsupportedWave,
        decodeAlloc(std.testing.allocator, &invalid_bits),
    );
}

test "decoder accepts extensible G.711 subformat GUIDs" {
    var mulaw = try decodeAlloc(std.testing.allocator, fixtures.extensible_mulaw_mono);
    defer mulaw.deinit(std.testing.allocator);
    try std.testing.expectEqual(Channels.mono, mulaw.channels);
    try std.testing.expectEqualSlices(f32, &.{
        0, 0, -0.9803466796875, 0.9803466796875,
    }, mulaw.samples);

    var alaw = try decodeAlloc(std.testing.allocator, fixtures.extensible_alaw_mono);
    defer alaw.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(f32, &.{
        0.000244140625, -0.000244140625, -0.16796875, 0.16796875,
    }, alaw.samples);

    var invalid_bits = fixtures.extensible_mulaw_mono.*;
    std.mem.writeInt(u16, invalid_bits[34..36], 16, .little);
    try std.testing.expectError(
        error.UnsupportedWave,
        decodeAlloc(std.testing.allocator, &invalid_bits),
    );
}

test "decoder follows G.711 A-law segment boundaries" {
    var audio = try decodeAlloc(std.testing.allocator, fixtures.alaw_segment_boundaries);
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(f32, &.{
        -0.000244140625, 0.000244140625, -0.008056640625, 0.008056640625, -0.01611328125,
        0.01611328125,   -0.0322265625,  0.0322265625,    -0.064453125,   0.064453125,
        -0.12890625,     0.12890625,     -0.2578125,      0.2578125,      -0.515625,
        0.515625,
    }, audio.samples);
}

test "decoder accepts extensible 24-bit PCM and float sources" {
    var pcm24 = try decodeAlloc(std.testing.allocator, fixtures.extensible_pcm24);
    defer pcm24.deinit(std.testing.allocator);
    try std.testing.expectEqual(48000, pcm24.sample_rate);
    try std.testing.expectEqualSlices(f32, &.{ -1, 0, 0.9999998807907104 }, pcm24.samples);

    var extensible_float = try decodeAlloc(std.testing.allocator, fixtures.extensible_float32);
    defer extensible_float.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(f32, &.{0.5}, extensible_float.samples);
}

test "decoder rejects a truncated extensible format extension" {
    var truncated = fixtures.extensible_pcm24.*;
    std.mem.writeInt(u16, truncated[36..38], 23, .little);
    try std.testing.expectError(error.InvalidWave, decodeAlloc(std.testing.allocator, &truncated));
}

test "decoder accepts extensible multichannel and reduced-precision PCM" {
    var multichannel = try decodeAlloc(std.testing.allocator, fixtures.extensible_pcm6);
    defer multichannel.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(Channels, @fromBackingInt(@intCast(6))), multichannel.channels);
    try std.testing.expectEqualSlices(f32, &.{
        -1, -0.5, 0, 0.5, 0.999969482421875, -0.000030517578125,
    }, multichannel.samples);

    var reduced = try decodeAlloc(std.testing.allocator, fixtures.extensible_pcm20);
    defer reduced.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(f32, &.{ -1, 0.9999980926513672 }, reduced.samples);

    var reduced_u8 = try decodeAlloc(std.testing.allocator, fixtures.extensible_pcm4_u8);
    defer reduced_u8.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(f32, &.{ -1, 0, 0.875 }, reduced_u8.samples);
}

test "decoder preserves finite IEEE float values without clamping" {
    var audio = try decodeAlloc(std.testing.allocator, fixtures.float32);
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqual(44100, audio.sample_rate);
    try std.testing.expectEqualSlices(f32, &.{ -0.5, 0.25, 2 }, audio.samples);
}

test "decoder reads mono IMA ADPCM blocks" {
    var audio = try decodeAlloc(std.testing.allocator, fixtures.ima_adpcm_mono);
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqual(8000, audio.sample_rate);
    try std.testing.expectEqual(Channels.mono, audio.channels);
    try std.testing.expectEqualSlices(f32, &.{
        0,                 0.000030517578125, 0.00006103515625, 0.00018310546875, 0.000274658203125,
        0.000274658203125, 0.00048828125,     0,                0.00103759765625,
    }, audio.samples);

    var invalid = fixtures.ima_adpcm_mono.*;
    invalid[50] = 89;
    try std.testing.expectError(error.InvalidWave, decodeAlloc(std.testing.allocator, &invalid));
}

test "decoder reads IMA seed-only blocks in both channel layouts" {
    const cases = .{ .{ fixtures.ima_header_mono, Channels.mono, &[_]f32{
        -1, 0.999969482421875,
    } }, .{ fixtures.ima_header_stereo, Channels.stereo, &[_]f32{
        -1, 0.999969482421875, 0.5, -0.5,
    } } };
    inline for (cases) |case| {
        const info = try parseFormat(case[0][20..40]);
        try std.testing.expectEqual(1, info.samples_per_block);
        try std.testing.expectEqual(2, try frameCount(info, case[0].len - 48));
        var serial = try decodeAlloc(std.testing.allocator, case[0]);
        defer serial.deinit(std.testing.allocator);
        try std.testing.expectEqual(case[1], serial.channels);
        try std.testing.expectEqual(8000, serial.sample_rate);
        try std.testing.expectEqualSlices(f32, case[2], serial.samples);
        var dispatched = try testParallelDecode(std.testing.allocator, case[0]);
        defer dispatched.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, case[2], dispatched.samples);

        var invalid = case[0][20..40].*;
        for ([_]u16{ 0, 2 }) |frames| {
            std.mem.writeInt(u16, invalid[18..20], frames, .little);
            try std.testing.expectError(error.InvalidWave, parseFormat(&invalid));
        }
    }
}

test "decoder rejects incomplete IMA mono data words before allocating output" {
    var no_storage: [0]u8 = .{};
    var allocator = std.heap.FixedBufferAllocator.init(&no_storage);
    for ([_]usize{ 1, 2, 3, 5, 6, 7 }) |encoded_bytes| {
        var source: [64]u8 = undefined;
        @memcpy(source[0..48], fixtures.ima_partial_word[0..48]);
        const block_bytes = 4 + encoded_bytes;
        const frames = 1 + encoded_bytes * 2;
        const length = 48 + block_bytes + (block_bytes & 1);
        std.mem.writeInt(u32, source[4..8], @intCast(length - 8), .little);
        std.mem.writeInt(u32, source[28..32], @intCast(8000 * block_bytes / frames), .little);
        std.mem.writeInt(u16, source[32..34], @intCast(block_bytes), .little);
        std.mem.writeInt(u16, source[38..40], @intCast(frames), .little);
        std.mem.writeInt(u32, source[44..48], @intCast(block_bytes), .little);
        @memset(source[48..length], 0);
        try std.testing.expectError(
            error.InvalidWave,
            decodeAlloc(allocator.allocator(), source[0..length]),
        );
        try std.testing.expectError(
            error.InvalidWave,
            testParallelDecode(allocator.allocator(), source[0..length]),
        );
    }
    try std.testing.expectError(
        error.OutOfMemory,
        decodeAlloc(allocator.allocator(), fixtures.ima_header_mono),
    );
}

test "decoder validates IMA seed-only headers beyond the fact prefix" {
    var source = fixtures.ima_header_stereo_fact.*;
    const expected = [_]f32{ -1, 0.999969482421875, 0.5, -0.5 };
    for (0..3) |frames| {
        std.mem.writeInt(u32, source[48..52], @intCast(frames), .little);
        var serial = try decodeAlloc(std.testing.allocator, &source);
        defer serial.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, expected[0 .. frames * 2], serial.samples);
        var dispatched = try testParallelDecode(std.testing.allocator, &source);
        defer dispatched.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, expected[0 .. frames * 2], dispatched.samples);

        // The second block is padding when fact retains zero or one frame.
        source[70] = 89;
        try std.testing.expectError(error.InvalidWave, decodeAlloc(std.testing.allocator, &source));
        try std.testing.expectError(
            error.InvalidWave,
            testParallelDecode(std.testing.allocator, &source),
        );
        source[70] = 88;
    }
}

test "decoder reads interleaved stereo IMA ADPCM channel groups" {
    var audio = try decodeAlloc(std.testing.allocator, fixtures.ima_adpcm_stereo);
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqual(Channels.stereo, audio.channels);
    try std.testing.expectEqualSlices(f32, &.{
        0,                 0.030517578125,    0.000030517578125, 0.030548095703125,
        0.00006103515625,  0.03057861328125,  0.00018310546875,  0.03070068359375,
        0.000274658203125, 0.030792236328125, 0.000274658203125, 0.030792236328125,
        0.00048828125,     0.031005859375,    0,                 0.030517578125,
        0.00103759765625,  0.03155517578125,
    }, audio.samples);
}

test "decoder reads Microsoft ADPCM seed samples in time order" {
    var mono = try decodeAlloc(std.testing.allocator, fixtures.ms_adpcm_mono);
    defer mono.deinit(std.testing.allocator);
    try std.testing.expectEqual(Channels.mono, mono.channels);
    try std.testing.expectEqualSlices(f32, &.{
        0.06103515625,    0.030517578125, 0.030517578125, 0.05792236328125, 0.0333251953125,
        -0.1434326171875,
    }, mono.samples);

    var stereo = try decodeAlloc(std.testing.allocator, fixtures.ms_adpcm_stereo);
    defer stereo.deinit(std.testing.allocator);
    try std.testing.expectEqual(Channels.stereo, stereo.channels);
    try std.testing.expectEqualSlices(f32, &.{
        0.06103515625,   -0.06103515625,   0.030517578125,   -0.030517578125, 0.030517578125,
        -0.030517578125, 0.03753662109375, -0.0445556640625,
    }, stereo.samples);
}

test "Microsoft ADPCM signed prediction matches independent PCM through both decode paths" {
    const cases = .{ .{
        fixtures.ms_prediction_mono, fixtures.ms_prediction_mono_samples, Channels.mono,
    }, .{
        fixtures.ms_prediction_stereo, fixtures.ms_prediction_stereo_samples, Channels.stereo,
    } };
    inline for (cases) |case| {
        for ([_]bool{ false, true }) |scheduled| {
            var audio = if (scheduled) try testParallelDecode(
                std.testing.allocator,
                case[0],
            ) else try decodeAlloc(std.testing.allocator, case[0]);
            defer audio.deinit(std.testing.allocator);
            try std.testing.expectEqual(8000, audio.sample_rate);
            try std.testing.expectEqual(case[2], audio.channels);
            try expectPcm16Reference(case[1], audio.samples);
        }
    }
}

test "Microsoft ADPCM signed prediction preserves fact prefixes under reversed execution" {
    const cases = .{ .{
        fixtures.ms_prediction_mono, fixtures.ms_prediction_mono_samples,
    }, .{
        fixtures.ms_prediction_stereo, fixtures.ms_prediction_stereo_samples,
    } };
    inline for (cases) |case| {
        const channels = std.mem.readInt(u16, case[0][22..24], .little);
        const frames = case[1].len / 2 / channels;
        for ([_]usize{ 0, 1, 2, 3, 17, 18, 19, frames - 1, frames }) |retained_frames| {
            var source = case[0].*;
            std.mem.writeInt(u32, source[78..82], @intCast(retained_frames), .little);
            for ([_]bool{ false, true }) |scheduled| {
                var audio = if (scheduled) try testParallelDecode(
                    std.testing.allocator,
                    &source,
                ) else try decodeAlloc(std.testing.allocator, &source);
                defer audio.deinit(std.testing.allocator);
                try expectPcm16Reference(
                    case[1][0 .. retained_frames * channels * 2],
                    audio.samples,
                );
            }
        }
    }
}

test "decoder honors ADPCM fact frames without publishing block padding" {
    const cases = .{ .{ fixtures.ima_mono, Channels.mono, &[_]f32{
        0, 0.000030517578125, 0.00006103515625,
    } }, .{ fixtures.extended_fact, Channels.mono, &[_]f32{
        0, 0.000030517578125, 0.00006103515625,
    } }, .{ fixtures.ima_stereo, Channels.stereo, &[_]f32{
        0,                0.030517578125,   0.000030517578125, 0.030548095703125, 0.00006103515625,
        0.03057861328125, 0.00018310546875, 0.03070068359375,  0.000274658203125, 0.030792236328125,
    } }, .{ fixtures.ms_mono, Channels.mono, &[_]f32{
        0.06103515625, 0.030517578125, 0.030517578125, 0.05792236328125, 0.0333251953125,
    } }, .{ fixtures.ms_stereo, Channels.stereo, &[_]f32{
        0.06103515625,   -0.06103515625, 0.030517578125, -0.030517578125, 0.030517578125,
        -0.030517578125,
    } } };
    inline for (cases) |case| {
        var audio = try decodeAlloc(std.testing.allocator, case[0]);
        defer audio.deinit(std.testing.allocator);
        try std.testing.expectEqual(case[1], audio.channels);
        try std.testing.expectEqualSlices(f32, case[2], audio.samples);
        var scheduled = try testParallelDecode(std.testing.allocator, case[0]);
        defer scheduled.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, case[2], scheduled.samples);
    }
}

test "decoder resolves RF64 ADPCM fact sentinels and retains explicit counts" {
    var audio = try decodeAlloc(std.testing.allocator, fixtures.rf64_ima_mono);
    defer audio.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(f32, &.{
        0, 0.000030517578125, 0.00006103515625,
    }, audio.samples);

    var explicit = fixtures.rf64_ima_mono.*;
    std.mem.writeInt(u32, explicit[84..88], 2, .little);
    var shorter = try decodeAlloc(std.testing.allocator, &explicit);
    defer shorter.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0.000030517578125 }, shorter.samples);
}

test "RF64 explicit outer sizes reach requirements and all complete decode operations" {
    const source = fixtures.rf64_explicit_lengths;
    const requirements = try decodeRequirements(source, &.{});
    try testing.expectEqual(1, requirements.frames);
    try testing.expectEqual(1, requirements.samples);
    try testing.expectEqual(4, requirements.sample_bytes);
    const expected = [_]f32{127.0 / 128.0};
    var samples: [2]f32 = @splat(-9);
    const decoded = try decodeInto(source, &samples, &.{});
    try testing.expectEqualSlices(f32, &expected, decoded.samples);
    try testing.expectEqual(-9, samples[1]);
    var owned = try decodeAlloc(testing.allocator, source);
    defer owned.deinit(testing.allocator);
    try testing.expectEqualSlices(f32, &expected, owned.samples);
    var workers: [2]Worker = undefined;
    const scheduled = try decodeParallelInto(std.Io.failing, source, &samples, &.{}, &workers, .{});
    try testing.expectEqualSlices(f32, &expected, scheduled.samples);
    var scheduled_owner = try decodeParallelAlloc(
        testing.allocator,
        std.Io.failing,
        source,
        &workers,
        .{},
    );
    defer scheduled_owner.deinit(testing.allocator);
    try testing.expectEqualSlices(f32, &expected, scheduled_owner.samples);
}

test "ADPCM fact counts span blocks and data chunks under reordered execution" {
    const expected = [_]f32{
        0,                 0.000030517578125, 0.00006103515625, 0.00018310546875, 0.000274658203125,
        0.000274658203125, 0.00048828125,     0,                0.00103759765625, 0,
        0.000030517578125, 0.00006103515625,
    };
    for ([_][]const u8{ fixtures.ima_two_blocks, fixtures.ima_split_data }) |source| {
        var audio = try decodeAlloc(std.testing.allocator, source);
        defer audio.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &expected, audio.samples);
        var scheduled = try testParallelDecode(std.testing.allocator, source);
        defer scheduled.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(f32, &expected, scheduled.samples);
    }
}

test "ADPCM fact counts can end inside seed samples or publish no frames" {
    const cases = [_]struct {
        source: []const u8,
        count_offset: usize,
        expected: []const f32,
    }{ .{ .source = fixtures.ima_mono, .count_offset = 48, .expected = &.{
        0, 0.000030517578125,
    } }, .{ .source = fixtures.ms_stereo, .count_offset = 78, .expected = &.{
        0.06103515625, -0.06103515625, 0.030517578125, -0.030517578125,
    } } };
    for (cases) |case| {
        const bytes = try std.testing.allocator.dupe(u8, case.source);
        defer std.testing.allocator.free(bytes);
        for ([_]u32{ 0, 1, 2 }) |frames| {
            std.mem.writeInt(u32, bytes[case.count_offset..][0..4], frames, .little);
            var audio = try decodeAlloc(std.testing.allocator, bytes);
            defer audio.deinit(std.testing.allocator);
            const sample_count = frames * @backingInt(audio.channels);
            try std.testing.expectEqualSlices(f32, case.expected[0..sample_count], audio.samples);
            var scheduled = try testParallelDecode(std.testing.allocator, bytes);
            defer scheduled.deinit(std.testing.allocator);
            try std.testing.expectEqualSlices(f32, audio.samples, scheduled.samples);
        }
    }
}

test "invalid ADPCM fact metadata is rejected before output allocation" {
    var oversized = fixtures.ima_mono.*;
    std.mem.writeInt(u32, oversized[48..52], 10, .little);
    for ([_][]const u8{ &oversized, fixtures.short_fact, fixtures.duplicate_fact }) |source| {
        try std.testing.expectError(
            error.InvalidWave,
            decodeAlloc(std.testing.failing_allocator, source),
        );
    }
    var rf64_oversized = fixtures.rf64_ima_mono.*;
    std.mem.writeInt(u64, rf64_oversized[36..44], 0x1_0000_0000, .little);
    try std.testing.expectError(
        error.InvalidWave,
        decodeAlloc(std.testing.failing_allocator, &rf64_oversized),
    );
}

test "ADPCM padding still validates block headers after all output is complete" {
    var invalid = fixtures.ima_two_blocks.*;
    std.mem.writeInt(u32, invalid[48..52], 0, .little);
    invalid[70] = 89;
    try std.testing.expectError(error.InvalidWave, decodeAlloc(std.testing.allocator, &invalid));
    try std.testing.expectError(
        error.InvalidWave,
        testParallelDecode(std.testing.allocator, &invalid),
    );
}

test "decoder rejects malformed Microsoft ADPCM format and predictor data" {
    var invalid_coefficients = fixtures.ms_adpcm_mono.*;
    invalid_coefficients[40] = 0;
    invalid_coefficients[41] = 0;
    try std.testing.expectError(
        error.InvalidWave,
        decodeAlloc(std.testing.allocator, &invalid_coefficients),
    );

    var invalid_predictor = fixtures.ms_adpcm_mono.*;
    invalid_predictor[78] = 7;
    try std.testing.expectError(
        error.InvalidWave,
        decodeAlloc(std.testing.allocator, &invalid_predictor),
    );
}

test "decoder rejects a Microsoft ADPCM delta that exceeds its supported range" {
    // Extend a valid mono block so repeated high-magnitude codes grow the adaptive delta past the
    // decoder's integer range before the block ends.
    var source: [104]u8 = undefined;
    @memcpy(source[0..87], fixtures.ms_adpcm_mono[0..87]);
    @memset(source[85..103], 0x88);
    source[103] = 0;
    std.mem.writeInt(u32, source[4..8], 96, .little);
    std.mem.writeInt(u16, source[32..34], 25, .little);
    std.mem.writeInt(u16, source[38..40], 38, .little);
    std.mem.writeInt(u32, source[74..78], 25, .little);
    std.mem.writeInt(u16, source[79..81], 65_535, .little);

    try std.testing.expectError(error.InvalidWave, decodeAlloc(std.testing.allocator, &source));
    try std.testing.expectError(
        error.InvalidWave,
        testParallelDecode(std.testing.allocator, &source),
    );
}

test "decoder rejects malformed, unsupported, and nonfinite WAV data" {
    try std.testing.expectError(
        error.InvalidWave,
        decodeAlloc(std.testing.allocator, fixtures.stereo[0 .. fixtures.stereo.len - 1]),
    );
    try std.testing.expectError(
        error.InvalidWave,
        decodeAlloc(std.testing.allocator, fixtures.stereo_split_unaligned),
    );

    var unsupported = fixtures.stereo.*;
    unsupported[20] = 2;
    try std.testing.expectError(
        error.UnsupportedWave,
        decodeAlloc(std.testing.allocator, &unsupported),
    );

    var ambiguous_multichannel = fixtures.stereo.*;
    ambiguous_multichannel[22] = 3;
    ambiguous_multichannel[32] = 6;
    try std.testing.expectError(
        error.UnsupportedWave,
        decodeAlloc(std.testing.allocator, &ambiguous_multichannel),
    );

    var invalid_rf64 = fixtures.rf64_stereo_with_table.*;
    invalid_rf64[20] = 0;
    try std.testing.expectError(
        error.InvalidWave,
        decodeAlloc(std.testing.allocator, &invalid_rf64),
    );

    var nonfinite = fixtures.float32.*;
    nonfinite[44] = 0;
    nonfinite[45] = 0;
    nonfinite[46] = 0xc0;
    nonfinite[47] = 0x7f;
    try std.testing.expectError(
        error.InvalidSamples,
        decodeAlloc(std.testing.allocator, &nonfinite),
    );
}

test "decoder releases output and RF64 scratch on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeWithFailingAllocator,
        .{},
    );
}

test "WAV decoder handles bounded truncation and byte mutations" {
    const backing = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(backing);
    const corpus = [_][]const u8{
        fixtures.stereo,          fixtures.empty_mono,         fixtures.rf64_stereo_with_table,
        fixtures.extensible_pcm6, fixtures.extensible_float32, fixtures.mulaw_mono,
        fixtures.alaw_mono,       fixtures.ima_adpcm_mono,     fixtures.ima_adpcm_stereo,
        fixtures.ms_adpcm_mono,   fixtures.ms_adpcm_stereo,    fixtures.ima_mono,
        fixtures.ima_header_mono, fixtures.ima_header_stereo,  fixtures.ima_header_stereo_fact,
        fixtures.extended_fact,   fixtures.ima_stereo,         fixtures.ms_mono,
        fixtures.ms_stereo,       fixtures.rf64_ima_mono,      fixtures.ima_two_blocks,
        fixtures.ima_split_data,
    };
    for (corpus) |source| {
        var seed = try decodeAlloc(std.testing.allocator, source);
        seed.deinit(std.testing.allocator);

        for (0..source.len + 1) |length| {
            try decodeBoundedMutation(backing, source[0..length]);
        }
        const mutated = try std.testing.allocator.dupe(u8, source);
        defer std.testing.allocator.free(mutated);
        for (source, 0..) |original, index| {
            for ([_]u8{ 1, 0x80, 0xff }) |mask| {
                mutated[index] = original ^ mask;
                try decodeBoundedMutation(backing, mutated);
            }
            mutated[index] = original;
        }
    }
}

fn expectPcm16Reference(reference: []const u8, samples: []const f32) !void {
    try std.testing.expectEqual(reference.len / 2, samples.len);
    for (samples, 0..) |sample, index| {
        const expected = std.mem.readInt(i16, reference[index * 2 ..][0..2], .little);
        try std.testing.expectEqual(@as(f32, @floatFromInt(expected)) / 32768, sample);
    }
}

fn decodeWithFailingAllocator(allocator: std.mem.Allocator) !void {
    var audio = try decodeAlloc(allocator, fixtures.stereo);
    defer audio.deinit(allocator);
    var rf64_audio = try decodeAlloc(allocator, fixtures.rf64_repeated_unknown_chunks);
    defer rf64_audio.deinit(allocator);
    var adpcm_audio = try decodeAlloc(allocator, fixtures.rf64_ima_mono);
    defer adpcm_audio.deinit(allocator);
}

fn decodeBoundedMutation(backing: []u8, source: []const u8) !void {
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    const allocator = fixed.allocator();
    // Corrupt format fields may claim large output; each attempt has its own fixed allocation
    // budget, and every accepted result must remain finite.
    if (decodeAlloc(allocator, source)) |value| {
        var audio = value;
        defer audio.deinit(allocator);
        for (audio.samples) |sample| try std.testing.expect(std.math.isFinite(sample));
    } else |_| {}
}

test "WAV owners reclaim padded samples and RF64 scratch across every allocation failure" {
    const allocator = testing.allocator;
    const backing = try allocator.alignedAlloc(u8, .@"8", 1024);
    defer allocator.free(backing);
    const table = try allocator.alloc(fixtures.Rf64Size, 41);
    defer allocator.free(table);
    @memset(table, .{ .id = "JUNK".*, .size = 1 });
    const chunks = try allocator.alloc(fixtures.Rf64Chunk, 40);
    defer allocator.free(chunks);
    @memset(chunks, .{ .id = "JUNK".*, .data = "x" });
    table[40] = .{ .id = "KEEP".*, .size = 0 };
    const indexed = try fixtures.makeRf64Metadata(allocator, table, chunks);
    defer allocator.free(indexed);
    for ([_][]const u8{
        fixtures.stereo, fixtures.rf64_repeated_unknown_chunks, indexed, fixtures.ima_two_blocks,
    }) |source| {
        for (0..8) |residue| {
            const prefix = 16 + residue;
            for ([_]bool{ false, true }) |decline_resize| {
                for ([_]bool{ false, true }) |scheduled| {
                    var fail_index: usize = 0;
                    while (true) : (fail_index += 1) {
                        try testing.expect(fail_index < 7);
                        @memset(backing, 0xa5);
                        var fixed = std.heap.FixedBufferAllocator.init(
                            backing[8 .. backing.len - 8],
                        );
                        @memset(try fixed.allocator().alloc(u8, prefix), 0x3c);
                        var failing = testing.FailingAllocator.init(
                            fixed.allocator(),
                            .{
                                .fail_index = fail_index,
                                .resize_fail_index = if (decline_resize) 0 else std.math.maxInt(
                                    usize,
                                ),
                            },
                        );
                        const result = if (scheduled) testParallelDecode(
                            failing.allocator(),
                            source,
                        ) else decodeAlloc(failing.allocator(), source);
                        var succeeded = false;
                        if (result) |value| {
                            var audio = value;
                            try testing.expect(audio.samples.len != 0);
                            try testing.expectEqual(
                                @as(usize, 0),
                                @intFromPtr(audio.samples.ptr) % @alignOf(f32),
                            );
                            audio.deinit(failing.allocator());
                            succeeded = true;
                        } else |failure| try testing.expectEqual(error.OutOfMemory, failure);
                        try testing.expectEqual(prefix, fixed.end_index);
                        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
                        try testing.expect(std.mem.allEqual(u8, fixed.buffer[0..prefix], 0x3c));
                        try testing.expect(std.mem.allEqual(u8, backing[0..8], 0xa5));
                        try testing.expect(std.mem.allEqual(u8, backing[backing.len - 8 ..], 0xa5));
                        if (succeeded) break;
                    }
                }
            }
        }
    }
    var empty = try decodeAlloc(testing.failing_allocator, fixtures.empty_mono);
    try testing.expectEqual(0, empty.samples.len);
    empty.deinit(testing.failing_allocator);
}

test "content failure and std.Io cancellation release complete owners after all jobs finish" {
    var invalid = fixtures.float32[0..fixtures.float32.len].*;
    std.mem.writeInt(u32, invalid[48..52], 0x7fc00000, .little);
    var backing: [1024]u8 align(8) = undefined;
    for (0..8) |residue| {
        const prefix = 16 + residue;
        for ([_]bool{ false, true }) |canceled| {
            @memset(&backing, 0xa5);
            var fixed = std.heap.FixedBufferAllocator.init(backing[8 .. backing.len - 8]);
            @memset(try fixed.allocator().alloc(u8, prefix), 0x3c);
            var provider: TestIo = .{ .canceled = canceled };
            var workers: [3]Worker = undefined;
            const source: []const u8 = if (canceled) fixtures.rf64_stereo_with_table else &invalid;
            const result = decodeParallelAlloc(
                fixed.allocator(),
                provider.io(),
                source,
                &workers,
                .{ .minimum_bytes = 0, .minimum_job_bytes = 1 },
            );
            if (canceled) try testing.expectError(
                error.Canceled,
                result,
            ) else try testing.expectError(error.InvalidSamples, result);
            try testing.expectEqual(prefix, fixed.end_index);
            try testing.expectEqual(0, provider.count);
            try testing.expectEqual(2, provider.submitted);
            try testing.expectEqual(1, provider.joined);
            for (workers) |worker| {
                try testing.expectEqual(0, worker.source.len);
                try testing.expectEqual(0, worker.destination.len);
                try testing.expectEqual(0, worker.format.adpcm_coefficients.len);
            }
            try testing.expect(std.mem.allEqual(u8, fixed.buffer[0..prefix], 0x3c));
            try testing.expect(std.mem.allEqual(u8, backing[0..8], 0xa5));
            try testing.expect(std.mem.allEqual(u8, backing[backing.len - 8 ..], 0xa5));
        }
    }
}

test "caller output admission preserves guards and sizing does not validate sample contents" {
    var output: [8]f32 = @splat(123);
    const needs = try decodeRequirements(fixtures.stereo, &.{});
    try testing.expectEqual(3, needs.frames);
    try testing.expectEqual(6, needs.samples);
    try testing.expectEqual(24, needs.sample_bytes);
    try testing.expectError(
        error.DestinationTooSmall,
        decodeInto(fixtures.stereo, output[0..5], &.{}),
    );
    try testing.expect(std.mem.allEqual(f32, &output, 123));
    const audio = try decodeInto(fixtures.stereo, output[1..7], &.{});
    try testing.expectEqual(6, audio.samples.len);
    try testing.expectEqual(123, output[0]);
    try testing.expectEqual(123, output[7]);
    var invalid = fixtures.float32[0..fixtures.float32.len].*;
    std.mem.writeInt(u32, invalid[44..48], 0x7f800000, .little);
    try testing.expectEqual(3, (try decodeRequirements(&invalid, &.{})).samples);
    try testing.expectError(error.InvalidSamples, decodeInto(&invalid, &output, &.{}));
    var source: [56]u8 align(8) = fixtures.stereo[0..56].*;
    const alias: []f32 = @alignCast(std.mem.bytesAsSlice(f32, source[44..56]));
    try testing.expectError(error.Aliasing, decodeInto(&source, alias, &.{}));
    try testing.expectEqualSlices(u8, fixtures.stereo, &source);
    var short_index: [2]ChunkIndexEntry = @splat(.{ .table_index = 77, .next_match = 88 });
    const view = try parse(fixtures.rf64_repeated_unknown_chunks);
    try testing.expectError(error.InsufficientScratch, view.iterator(&short_index));
    try testing.expectEqual(77, short_index[0].table_index);
    var index: [4]ChunkIndexEntry = @splat(.{ .table_index = 77, .next_match = 88 });
    _ = try view.iterator(&index);
    try testing.expectEqual(77, index[3].table_index);
}

test "parallel decoding permits inline providers empty chunks and serial thresholds" {
    var output: [6]f32 = undefined;
    var workers: [3]Worker = undefined;
    const audio = try decodeParallelInto(
        std.Io.failing,
        fixtures.stereo_empty_data,
        &output,
        &.{},
        &workers,
        .{ .minimum_bytes = 0, .minimum_job_bytes = 1 },
    );
    try testing.expectEqualSlices(
        f32,
        &.{ -1, 32767.0 / 32768.0, -0.5, 0.5, 0, 0.25 },
        audio.samples,
    );
    for (workers) |worker| try testing.expectEqual(0, worker.source.len);
    var refusing: TestIo = .{ .canceled = true };
    _ = try decodeParallelInto(refusing.io(), fixtures.stereo, &output, &.{}, &workers, .{});
    try testing.expectEqual(0, refusing.submitted);
    var empty = try decodeParallelAlloc(
        testing.failing_allocator,
        refusing.io(),
        fixtures.empty_mono,
        &workers,
        .{ .minimum_bytes = 0, .minimum_job_bytes = 0 },
    );
    empty.deinit(testing.failing_allocator);
    try testing.expectEqual(0, refusing.submitted);
}

test "std.Io threaded ADPCM conversion preserves independent samples and releases workers" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const allocator = testing.allocator;
    var provider = std.Io.Threaded.init(allocator, .{ .async_limit = .limited(3) });
    defer provider.deinit();
    var workers: [4]Worker = undefined;
    var audio = try decodeParallelAlloc(
        allocator,
        provider.io(),
        fixtures.ms_prediction_stereo,
        &workers,
        .{ .minimum_bytes = 0, .minimum_job_bytes = 1 },
    );
    defer audio.deinit(allocator);
    try expectPcm16Reference(fixtures.ms_prediction_stereo_samples, audio.samples);
    for (workers) |worker| {
        try testing.expectEqual(0, worker.source.len);
        try testing.expectEqual(0, worker.destination.len);
        try testing.expectEqual(0, worker.format.adpcm_coefficients.len);
    }
}

test "extensible speaker masks are copied without changing source sample order" {
    var source = fixtures.extensible_pcm6[0..fixtures.extensible_pcm6.len].*;
    const mask: u32 = 0x8000003f;
    std.mem.writeInt(u32, source[40..44], mask, .little);
    const info = try parseFormat(source[20..60]);
    try testing.expectEqual(mask, info.channel_mask.?);
    var audio = try decodeAlloc(testing.allocator, &source);
    defer audio.deinit(testing.allocator);
    try testing.expectEqual(mask, audio.channel_mask.?);
    try testing.expectEqual(mask, audio.view().channel_mask.?);
    std.mem.writeInt(u32, source[40..44], 0, .little);
    try testing.expectEqual(mask, audio.channel_mask.?);
    try testing.expectEqual(0, (try parseFormat(source[20..60])).channel_mask.?);
    try testing.expectEqual(null, (try parseFormat(fixtures.stereo[20..36])).channel_mask);
}
