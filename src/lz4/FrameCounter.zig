//! Checked cumulative byte/work/frame admission shared by LZ4 framing operations.

const std = @import("std");
const FrameCounter = @This();

pub const Error = error{ CounterOverflow, LimitExceeded };

/// Cumulative accepted source, produced wire bytes and frame count. Byte work is input plus output;
/// HC search has a separate policy allowance. Dictionary copying is excluded.
pub const Limits = struct {
    /// Maximum accepted original bytes.
    input_bytes: u64 = std.math.maxInt(u64),
    /// Maximum admitted wire bytes, including frame fields.
    output_bytes: u64 = std.math.maxInt(u64),
    /// Maximum original input plus wire output byte work.
    work_units: u64 = std.math.maxInt(u64),
    /// Maximum frame headers admitted.
    frames: u64 = std.math.maxInt(u64),
};

/// Admitted source bytes: original input when encoding, encoded input when decoding.
input: u64 = 0,
/// Admitted destination bytes: encoded output when encoding, restored output when decoding.
output: u64 = 0,
/// Admitted source plus destination byte work, excluding copied dictionary setup.
work_units: u64 = 0,
/// Admitted frame headers, including skippable frames when decoding.
frames: u64 = 0,
/// Common byte/work/frame ceilings, interpreted in the active operation's direction.
limits: Limits,

/// Projects the shared admission fields from an encode or decode policy. Decode-only descriptor
/// limits stay with the decoder; this counter enforces cumulative bytes, byte work and frame count.
pub fn init(limits: anytype) FrameCounter {
    return .{
        .limits = .{
            .input_bytes = limits.input_bytes,
            .output_bytes = limits.output_bytes,
            .work_units = limits.work_units,
            .frames = limits.frames,
        },
    };
}

/// Admits another source/destination contribution. Refusal leaves all totals unchanged.
pub fn add(self: *FrameCounter, input: usize, output: usize) Error!void {
    const total_input = std.math.add(u64, self.input, input) catch return error.CounterOverflow;
    const total_output = std.math.add(u64, self.output, output) catch return error.CounterOverflow;
    const amount = std.math.add(u64, input, output) catch return error.CounterOverflow;
    const total_work = std.math.add(
        u64,
        self.work_units,
        amount,
    ) catch return error.CounterOverflow;
    if (total_input > self.limits.input_bytes) return error.LimitExceeded;
    if (total_output > self.limits.output_bytes or total_work > self.limits.work_units)
        return error.LimitExceeded;

    self.input = total_input;
    self.output = total_output;
    self.work_units = total_work;
}

pub fn frame(self: *FrameCounter) Error!void {
    const frames = std.math.add(u64, self.frames, 1) catch return error.CounterOverflow;
    if (frames > self.limits.frames) return error.LimitExceeded;
    self.frames = frames;
}

pub fn outputCapacity(self: *const FrameCounter, capacity: usize) usize {
    const remaining_output_bytes = self.limits.output_bytes - self.output;
    const remaining_work_units = self.limits.work_units - self.work_units;
    const admitted_bytes = @min(capacity, remaining_output_bytes, remaining_work_units);
    return @intCast(admitted_bytes);
}
