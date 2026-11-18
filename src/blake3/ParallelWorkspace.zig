//! Caller-owned storage for one participant in a BLAKE3 parallel update, including the calling
//! thread. Reserve one entry per allowed participant and keep its address stable until return.
//! updateParallel initializes participating entries and joins every acquired task before retiring
//! their input pointers. Unused entries are untouched. No allocator or live task remains here;
//! key-derived words can remain until overwritten or explicitly cleared. Callers modify this
//! storage only through hashing or clear.

const std = @import("std");
const compression = @import("compression.zig");
const ParallelWorkspace = @This();
const ChainingValue = compression.Cv;

/// Internal copied mode key; retained until overwritten or clear erases it.
key: ChainingValue,
/// Internal hashing-mode flags for the admitted job.
mode: u32,
/// Internal borrowed job bytes; empty after this entry's jobs join. Unused entries stay untouched.
input: []const u8,
/// Zero-based index of the job's first complete chunk.
counter: u64,
/// Ordered left/right subtree children, kept separate for possible root compression.
result: [2]ChainingValue,
/// Temporary chunk/parent values. Only the current job's active prefix is initialized.
batch: [128]ChainingValue,
/// Aligned transpose/compression scratch; it can retain key-derived words between operations.
messages: [256]u32 align(64),

/// Erases the entire reservation, including key-derived scratch. No initialization is needed before
/// reuse by another parallel operation.
pub fn clear(self: *ParallelWorkspace) void {
    const bytes: [*]volatile u8 = @ptrCast(self);
    for (bytes[0..@sizeOf(ParallelWorkspace)]) |*byte| byte.* = 0;
}

test "clear erases the complete parallel workspace reservation" {
    var workspace: ParallelWorkspace = undefined;
    @memset(std.mem.asBytes(&workspace), 0xa5);
    workspace.clear();
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&workspace), 0));
}
