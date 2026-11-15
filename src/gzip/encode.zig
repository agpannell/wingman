//! Encode one gzip member or drive a resumable member stream. Complete calls return a prefix
//! borrowed from caller output; streaming metadata is copied during reset. Every member has an
//! independent DEFLATE history, CRC-32 and size trailer.
const std = @import("std");
const deflate = @import("../deflate.zig");
const overlaps = @import("../common/byte_ranges.zig").overlaps;
const header_encode = @import("header_encode.zig");
const decoding = @import("decode.zig");
const Header = @import("Header.zig");
const DecoderWorkspace = deflate.decode.Workspace;

pub const Options = @import("EncodeOptions.zig");
pub const StreamEncoder = @import("StreamEncoder.zig");
pub const Workspace = deflate.encode.Workspace;
pub const Compression = deflate.encode.Compression;
pub const Limits = deflate.encode.Limits;
pub const Action = deflate.encode.Action;
pub const Status = deflate.encode.Status;
pub const Progress = deflate.encode.Progress;
pub const Stats = deflate.encode.Stats;

/// Complete-member failures; no lifecycle errors escape an independent call.
pub const Error = deflate.encode.Error || error{HeaderTooLong};

/// Sufficient capacity for one member and its selected metadata. Header admission and checked size
/// overflow fail before output can change; compression policy is validated by into/reset.
pub fn bound(
    source_bytes: usize,
    options: Options,
) error{ HeaderTooLong, CounterOverflow, InvalidOptions }!usize {
    return std.math.add(
        usize,
        try deflate.encode.bound(source_bytes),
        try header_encode.size(options) + 8,
    ) catch error.CounterOverflow;
}

/// Encode one member into unpadded caller storage. Source/output/workspace must be disjoint;
/// metadata cannot overlap output. The output prefix borrows the destination. Failure may change
/// output and scratch and returns no partial result. No pointer or allocator survives this call.
pub fn into(source: []const u8, output: []u8, workspace: *Workspace, options: Options) Error![]u8 {
    if (overlaps(source, output)) return error.StorageOverlap;
    if (overlaps(source, std.mem.asBytes(workspace))) return error.StorageOverlap;
    if (overlaps(output, std.mem.asBytes(workspace))) return error.StorageOverlap;
    inline for (.{ options.extra, options.name, options.comment }) |field| {
        if (field) |bytes| if (overlaps(bytes, output)) return error.StorageOverlap;
    }
    var encoder: StreamEncoder = undefined;
    try encoder.reset(workspace, options);
    const progress = encoder.step(source, output, .finish) catch |err| switch (err) {
        // This is the only step, using a complete source and finish action.
        error.InvalidState, error.NeedReset => unreachable,
        else => |failure| return failure,
    };
    if (progress.status != .complete) return error.OutputTooSmall;
    return output[0..progress.produced];
}

test {
    _ = Options;
    _ = StreamEncoder;
}
