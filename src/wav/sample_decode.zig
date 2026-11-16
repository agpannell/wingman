//! Bounded WAVE conversion through independent codecs, with optional caller-owned std.Io work. Each
//! participant owns disjoint complete frames or ADPCM blocks. Job-local failures are read after
//! joining; all source, destination and coefficient pointers retire before return.

const std = @import("std");
const lpcm = @import("../lpcm.zig");
const g711 = @import("../g711.zig");
const adpcm = @import("../adpcm.zig");
const Format = @import("Format.zig");

/// Parallel conversion also propagates cancellation after every borrowed participant has finished.
pub const ParallelError = DecodeWorker.Error || std.Io.Cancelable;

/// Admission thresholds in encoded bytes. Small chunks or insufficient workers use serial decode.
/// Zero thresholds permit the smallest whole-frame/block partitions.
pub const ParallelOptions = struct {
    /// Minimum encoded bytes in one data chunk before attempting parallel conversion.
    minimum_bytes: usize = 256 * 1024,
    /// Minimum encoded bytes per participant, rounded up to whole frames or blocks.
    minimum_job_bytes: usize = 64 * 1024,
};

/// Address-stable reservation for one conversion participant, including the calling thread.
/// Contents are managed by parallel decoding; no initialization is required. Only the selected
/// worker prefix is initialized; unused slots may remain undefined. Source, destination and
/// coefficient borrows end before return, including cancellation. No allocator is retained.
pub const DecodeWorker = struct {
    /// Copied admitted format for a selected job; coefficient borrows are cleared on retirement.
    format: Format,
    /// Borrowed whole frames or blocks for the job; cleared before the decode call returns.
    source: []const u8,
    /// Disjoint output prefix for this job; may be empty when validating omitted ADPCM blocks.
    destination: []f32,
    /// Job-local content failure, read by the coordinator after joining all selected jobs.
    failure: ?Error,

    /// Invalid encoded content, nonfinite LPCM samples or an unrepresentable decoded extent.
    pub const Error = error{ InvalidWave, InvalidSamples, SizeOverflow };

    fn run(self: *DecodeWorker) void {
        self.failure = null;
        convert(self.format, self.source, self.destination) catch |err| {
            self.failure = err;
        };
    }

    fn retire(self: *DecodeWorker) void {
        self.source = &.{};
        self.destination = &.{};
        if (self.format.encoding == .adpcm) self.format.encoding.adpcm.coefficients = &.{};
    }
};

// The owning complete-file layer has admitted format, frame geometry, exact output and aliasing.
pub fn convert(format: Format, source: []const u8, destination: []f32) DecodeWorker.Error!void {
    switch (format.encoding) {
        .g711 => |companded| {
            _ = g711.decodeInto(source, destination, companded.law) catch unreachable;
        },
        .adpcm => |block_format| {
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
        .lpcm => |pcm| {
            _ = lpcm.decodeInto(source, destination, pcm.sample_format) catch |err| switch (err) {
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
    workers: []DecodeWorker,
    options: ParallelOptions,
) ParallelError!void {
    if (workers.len < 2 or source.len < options.minimum_bytes) return convert(
        format,
        source,
        destination,
    );
    const layout = format.blockLayout();
    const units = source.len / layout.block_bytes;
    const minimum_units = @max(
        1,
        options.minimum_job_bytes / layout.block_bytes + @intFromBool(
            options.minimum_job_bytes % layout.block_bytes != 0,
        ),
    );
    const participants = @min(workers.len, units / minimum_units);
    if (participants < 2) return convert(format, source, destination);
    const samples_per_unit = std.math.mul(
        usize,
        layout.frames_per_block,
        @backingInt(format.channels()),
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
            .source = source[begin * layout.block_bytes .. end * layout.block_bytes],
            .destination = destination[sample_begin..sample_end],
            .failure = null,
        };
        if (index != 0) group.async(io, DecodeWorker.run, .{worker});
    }
    workers[0].run();
    try group.await(io);
    // Input order chooses the reported content failure, regardless of completion order.
    for (workers[0..participants]) |worker| if (worker.failure) |failure| return failure;
}
