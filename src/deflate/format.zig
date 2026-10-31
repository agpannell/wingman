//! RFC 1951 fields, raw decoding contracts and distance admission.

const std = @import("std");

/// Decoding failures with no published result counts. `InvalidStream` covers malformed/truncated
/// input. `InvalidOptions` refuses unsupported policy or missing dictionary history.
/// `OutputTooSmall` means caller output cannot hold the next decoded operation. StorageOverlap
/// refuses overlapping spans before mutation. Other errors may leave output changed. These failures
/// do not grow storage or use a fallback allocator.
pub const Error = error{
    /// Malformed or truncated raw DEFLATE input.
    InvalidStream,
    /// The selected window or storage configuration is invalid.
    InvalidOptions,
    /// The selected input, output or work allowance cannot admit the operation.
    LimitExceeded,
    /// The complete-buffer destination cannot hold the decoded result; no progress counts return.
    OutputTooSmall,
    /// Source, output or scratch overlap where independent storage is required.
    StorageOverlap,
};

/// Copied byte counts for the first successfully decoded stream, excluding trailing bytes. Counts
/// describe the current input stream and supplied output; they can outlive them. Any derived slice
/// retains its source/output lifetime. On error no partial counts return.
pub const DecodeResult = struct {
    /// Input bytes occupied by the raw stream.
    consumed: usize,

    /// Output bytes written; bytes beyond this count remain unchanged.
    produced: usize,
};

/// Required restored extent for one complete decode; independent of trailing input policy.
pub const OutputSize = enum { bounded, exact };

/// Whether bytes beyond the selected stream may remain unconsumed.
pub const TrailingData = enum { allow, reject };

/// Cumulative decode admission. Work units count accepted input plus restored output bytes, once
/// each. A failed operation may modify unpublished output; limits never authorize allocation.
pub const DecodeLimits = struct {
    /// Maximum accepted encoded bytes, excluding trailing input.
    input_bytes: u64 = std.math.maxInt(u64),
    /// Maximum restored bytes, excluding dictionary history.
    output_bytes: u64 = std.math.maxInt(u64),
    /// Maximum sum of accepted and restored bytes.
    work_units: u64 = std.math.maxInt(u64),
};

/// Policy for one complete raw stream. Optional dictionary bytes are borrowed until return;
/// dictionary decoding also requires a history reservation in `DecodeStorage`.
pub const DecodeOptions = struct {
    /// Maximum backward match distance in 1..32768. Stored bytes/literals require no history.
    window_bytes: usize = 32768,
    /// Preset history selected by the enclosing format; raw streams carry no dictionary identity.
    dictionary: ?[]const u8 = null,
    /// Bounded preserves the unused output suffix; exact requires the complete destination length.
    output_size: OutputSize = .bounded,
    /// Allow preserves following application bytes; reject requires complete source consumption.
    trailing_data: TrailingData = .allow,
    /// Input/output/work admission for this call.
    limits: DecodeLimits = .{},
};

/// Resumable policy. Output capacity and final input belong to each `step`, so complete-call extent
/// and trailing-data selections are deliberately absent. Dictionary history is copied during reset.
pub const StreamDecodeOptions = struct {
    /// Maximum backward match distance in 1..32768.
    window_bytes: usize = 32768,
    /// Optional initial dictionary, copied before any source is accepted.
    dictionary: ?[]const u8 = null,
    /// Cumulative admission across every suspension.
    limits: DecodeLimits = .{},
};

/// RFC 1951 wire order of the dynamic block's code-length alphabet.
pub const precode_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// Match lengths for symbols 257..285, before their extra bits are added.
pub const length_base = [_]u16{
    3,   4,   5,   6,   7,   8,   9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99,
    115, 131, 163, 195, 227, 258,
};

/// Extra-bit counts corresponding to length_base.
pub const length_extra = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
};

/// Match distances for symbols 0..29, before their extra bits are added.
pub const distance_base = [_]u16{
    1,   2,   3,   4,    5,    7,    9,    13,   17,   25,   33,    49,    65,    97, 129, 193, 257,
    385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};

/// Extra-bit counts corresponding to distance_base.
pub const distance_extra = [_]u8{
    0,  0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13,
};
