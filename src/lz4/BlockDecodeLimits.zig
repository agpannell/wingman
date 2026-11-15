//! Per-block input/output admission. Work charges encoded plus decoded bytes once; copied initial
//! history is excluded. A streaming worker restarts these counters at each nextBlock.
const std = @import("std");

/// Maximum accepted encoded bytes in one raw block.
input_bytes: u64 = std.math.maxInt(u64),
/// Maximum restored bytes in one raw block.
output_bytes: u64 = std.math.maxInt(u64),
/// Maximum accepted encoded plus restored bytes.
work_units: u64 = std.math.maxInt(u64),
