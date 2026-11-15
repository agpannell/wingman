//! Admit complete logical work charges against one borrowed live encoding counter record.
const std = @import("std");
const EncodeStats = @import("EncodeStats.zig");

const EncodeWorkBudget = @This();

/// Cumulative work allowance for this stream; copying the view does not grant a new allowance.
limit: u64,
/// Borrowed live counters. Their fields share the stream's fixed representation and lifetime.
stats: *EncodeStats,

pub const Error = error{ LimitExceeded, CounterOverflow };

/// Admits a complete logical charge. Refusal leaves this counter unchanged; callers preserve the
/// order of other counter updates and any already-mutated scratch.
pub fn admit(self: EncodeWorkBudget, units: u64) Error!void {
    if (units > self.limit -| self.stats.work_units) return error.LimitExceeded;
    self.stats.work_units = try addCount(self.stats.work_units, units);
}

pub fn addCount(a: u64, b: u64) error{CounterOverflow}!u64 {
    return std.math.add(u64, a, b) catch error.CounterOverflow;
}
