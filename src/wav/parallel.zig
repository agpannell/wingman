//! Bounded WAVE conversion through independent codecs, with optional caller-owned std.Io work. Each
//! participant owns disjoint complete frames or ADPCM blocks. Job-local failures are read after
//! joining; all source, destination and coefficient pointers retire before return.

const std = @import("std");
const pcm = @import("../pcm.zig");
const g711 = @import("../g711.zig");
const adpcm = @import("../adpcm.zig");
const Format = @import("format.zig").Format;

pub const ConversionError = error{ InvalidWave, InvalidSamples, SizeOverflow };

/// Parallel conversion also propagates cancellation after every borrowed participant has finished.
pub const ParallelError = ConversionError || std.Io.Cancelable;

/// Admission thresholds in encoded bytes. Small chunks or insufficient workers use serial decode.
/// Zero thresholds permit the smallest whole-frame/block partitions.
pub const ParallelOptions = struct {
    minimum_bytes: usize = 256 * 1024,
    minimum_job_bytes: usize = 64 * 1024,
};

/// Address-stable reservation for one conversion participant, including the calling thread.
/// Contents are managed by parallel decoding; no initialization is required. Source, destination
/// and coefficient borrows end before return, including cancellation. No allocator is retained.
pub const Worker = struct {
    format: Format,
    source: []const u8,
    destination: []f32,
    failure: ?ConversionError,

    fn run(self: *Worker) void {
        self.failure = null;
        convert(self.format, self.source, self.destination) catch |err| {
            self.failure = err;
        };
    }

    fn retire(self: *Worker) void {
        self.source = &.{};
        self.destination = &.{};
        self.format.adpcm_coefficients = &.{};
    }
};

// The owning complete-file layer has admitted format, frame geometry, exact output and aliasing.
pub fn convert(format: Format, source: []const u8, destination: []f32) ConversionError!void {
    switch (format.encoding) {
        .g711_alaw, .g711_mulaw => {
            _ = g711.decodeInto(
                source,
                destination,
                if (format.encoding == .g711_alaw) .alaw else .mulaw,
            ) catch unreachable;
        },
        .ima_adpcm, .ms_adpcm => {
            const block_format: adpcm.Format = .{
                .encoding = if (format.encoding == .ima_adpcm) .ima_wave else .microsoft_wave,
                .channels = @backingInt(format.channels),
                .block_bytes = format.block_align,
                .frames_per_block = format.samples_per_block,
                .coefficients = format.adpcm_coefficients,
            };
            _ = adpcm.decodePrefixInto(
                source,
                destination,
                destination.len / block_format.channels,
                block_format,
            ) catch |err| switch (err) {
                error.SizeOverflow => return error.SizeOverflow,
                error.InvalidData, error.InvalidFormat => return error.InvalidWave,
                error.DestinationTooSmall, error.Aliasing => unreachable,
            };
        },
        else => {
            const sample_format: pcm.Format = .{ .encoding = switch (format.encoding) {
                .pcm_u8 => .unsigned8,
                .pcm_s16 => .signed16,
                .pcm_s24 => .signed24,
                .pcm_s32 => .signed32,
                .ieee_f32 => .float32,
                else => unreachable,
            }, .valid_bits = @intCast(format.valid_bits_per_sample) };
            _ = pcm.decodeInto(source, destination, sample_format) catch |err| switch (err) {
                error.InvalidSamples => return error.InvalidSamples,
                error.InvalidFormat, error.InvalidData => return error.InvalidWave,
                error.DestinationTooSmall, error.Aliasing => unreachable,
            };
        },
    }
}

pub fn convertParallel(
    io: std.Io,
    format: Format,
    source: []const u8,
    destination: []f32,
    workers: []Worker,
    options: ParallelOptions,
) ParallelError!void {
    if (workers.len < 2 or source.len < options.minimum_bytes) return convert(
        format,
        source,
        destination,
    );
    const units = source.len / format.block_align;
    const minimum_units = @max(
        1,
        options.minimum_job_bytes / format.block_align + @intFromBool(
            options.minimum_job_bytes % format.block_align != 0,
        ),
    );
    const participants = @min(workers.len, units / minimum_units);
    if (participants < 2) return convert(format, source, destination);
    const samples_per_unit = std.math.mul(
        usize,
        format.samples_per_block,
        @backingInt(format.channels),
    ) catch return error.SizeOverflow;
    const units_per_job = units / participants;
    const remainder = units % participants;
    var group: std.Io.Group = .init;
    defer {
        group.cancel(io);
        for (workers[0..participants]) |*worker| worker.retire();
    }
    for (workers[0..participants], 0..) |*worker, index| {
        const begin = index * units_per_job + @min(index, remainder);
        const end = begin + units_per_job + @intFromBool(index < remainder);
        const sample_begin = @min(begin * samples_per_unit, destination.len);
        const sample_end = @min(end * samples_per_unit, destination.len);
        worker.* = .{
            .format = format,
            .source = source[begin * format.block_align .. end * format.block_align],
            .destination = destination[sample_begin..sample_end],
            .failure = null,
        };
        if (index != 0) group.async(io, Worker.run, .{worker});
    }
    workers[0].run();
    try group.await(io);
    // Input order chooses the reported content failure, regardless of completion order.
    for (workers[0..participants]) |worker| if (worker.failure) |failure| return failure;
}
