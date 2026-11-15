//! Verifies the DEFLATE body, CRC-32 and modulo-2^32 size following an admitted member header. The
//! caller supplies Header.parse's result for this same source and admits the complete source,
//! output and workspace spans before this operation can change output or scratch.

const std = @import("std");
const Crc32IsoHdlc = @import("../crc.zig").Crc32IsoHdlc;
const deflate = @import("../deflate.zig");
const Header = @import("Header.zig");

const Workspace = deflate.decode.Workspace;
pub const Result = deflate.decode.Result;
pub const Error = error{ InvalidStream, LimitExceeded, OutputTooSmall, StorageOverlap };
pub const Options = struct {
    /// Extent required of this member's restored payload.
    output_size: deflate.decode.OutputSize = .bounded,
    /// Admission for the raw payload; the enclosing caller separately checks framing totals.
    limits: deflate.decode.Limits = .{},
};

pub fn verify(
    source: []const u8,
    output: []u8,
    workspace: *Workspace,
    header: Header.Result,
    options: Options,
) Error!Result {
    const raw = deflate.decode.into(
        source[header.consumed..],
        output,
        .{ .workspace = workspace },
        .{ .output_size = options.output_size, .limits = options.limits },
    ) catch |err| switch (err) {
        // A raw extent failure occurs before this member's CRC and size are checked.
        error.InvalidStream, error.OutputSizeMismatch => return error.InvalidStream,
        // This call fixes a valid full window and supplies no dictionary. Configuration refusal is
        // unreachable; the direct-buffer path also has no streaming EOF or counter accounting.
        error.InvalidOptions, error.Truncated, error.CounterOverflow => unreachable,
        error.OutputTooSmall => return error.OutputTooSmall,
        error.StorageOverlap => return error.StorageOverlap,
        error.LimitExceeded => return error.LimitExceeded,
    };
    const footer = header.consumed + raw.consumed;
    if (source.len - footer < 8) return error.InvalidStream;
    const expected_crc = std.mem.readInt(u32, source[footer..][0..4], .little);
    if (expected_crc != Crc32IsoHdlc.hash(output[0..raw.produced])) return error.InvalidStream;
    const expected_size = std.mem.readInt(u32, source[footer + 4 ..][0..4], .little);
    const restored_size: u32 = @truncate(raw.produced);
    if (expected_size != restored_size) return error.InvalidStream;
    return .{ .consumed = footer + 8, .produced = raw.produced };
}
