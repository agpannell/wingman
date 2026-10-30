//! Bounded participant scratch and ordered subtree results for parallel updates.
const std = @import("std");
const compression = @import("compression.zig");
const ChunkState = @import("chunk.zig").ChunkState;
const Output = compression.Output;
const ChainingValue = compression.Cv;
const chunk_bytes = compression.chunk_bytes;

/// Admission thresholds for explicitly scheduled hashing. Tune for the caller's scheduler and CPU.
/// Small updates always use the ordinary update path.
pub const ParallelOptions = struct {
    /// Minimum update bytes before any tasks are submitted.
    minimum_bytes: usize = 256 * 1024,
    /// Minimum bytes per participant, rounded up to whole chunks with a minimum of two chunks.
    minimum_job_bytes: usize = 64 * 1024,
};

/// Address-stable scratch for one parallel participant, including the calling thread. Reserve a
/// slice within the application's worker budget. No allocator is retained. Input pointers retire
/// before return, but key-derived words remain until overwritten or explicitly cleared.
pub const Worker = struct {
    key: ChainingValue,
    mode: u32,
    input: []const u8,
    counter: u64,
    result: [2]ChainingValue,
    batch: [128]ChainingValue,
    messages: [256]u32 align(64),

    /// Erases the entire reservation, including key-derived scratch. No initialization is needed
    /// before reuse by another parallel operation.
    pub fn clear(self: *Worker) void {
        const bytes: [*]volatile u8 = @ptrCast(self);
        for (bytes[0..@sizeOf(Worker)]) |*byte| byte.* = 0;
    }

    fn run(self: *Worker, comptime kernel: compression.Kernel) void {
        self.result = self.subtree(
            kernel,
            self.input.ptr,
            self.input.len / chunk_bytes,
            self.counter,
        );
    }

    fn runNative(self: *Worker) void {
        self.run(compression.preferred);
    }

    fn runScalar(self: *Worker) void {
        self.run(.scalar);
    }

    fn subtree(
        self: *Worker,
        comptime kernel: compression.Kernel,
        input: [*]const u8,
        count: usize,
        counter: u64,
    ) [2]ChainingValue {
        std.debug.assert(count >= 2 and std.math.isPowerOfTwo(count));
        if (count > self.batch.len) {
            const half = count / 2;
            const left = self.subtree(kernel, input, half, counter);
            const right = self.subtree(kernel, input + half * chunk_bytes, half, counter + half);
            return .{
                self.parent(kernel, left[0], left[1]),
                self.parent(kernel, right[0], right[1]),
            };
        }

        if (kernel == .scalar) {
            for (0..count) |i| {
                var chunk: ChunkState = undefined;
                chunk.reset(self.key, counter + i);
                chunk.update(.scalar, input[i * chunk_bytes ..][0..chunk_bytes], self.mode);
                self.batch[i] = chunk.output(self.mode).chaining(.scalar);
            }
        } else {
            compression.batchChunks(
                self.key,
                input,
                counter,
                self.mode,
                count,
                &self.messages,
                &self.batch,
            );
        }

        // Keep the last two children separate so finalization can still apply ROOT to their parent.
        var remaining = count;
        while (remaining > 2) : (remaining /= 2) {
            if (kernel == .scalar) {
                for (0..remaining / 2) |i| {
                    const left = self.batch[i * 2];
                    const right = self.batch[i * 2 + 1];
                    self.batch[i] = self.parent(kernel, left, right);
                }
            } else {
                compression.batchParents(
                    self.key,
                    &self.batch,
                    self.mode,
                    remaining / 2,
                    &self.messages,
                    &self.batch,
                );
            }
        }
        return self.batch[0..2].*;
    }

    fn parent(
        self: *const Worker,
        comptime kernel: compression.Kernel,
        left: ChainingValue,
        right: ChainingValue,
    ) ChainingValue {
        return Output.parent(self.key, left, right, self.mode).chaining(kernel);
    }
};

// The state owner schedules these existing functions without exposing worker internals.
pub const run = Worker.run;
pub const runNative = Worker.runNative;
pub const runScalar = Worker.runScalar;

test "clear erases the complete worker reservation" {
    var worker: Worker = undefined;
    @memset(std.mem.asBytes(&worker), 0xa5);
    worker.clear();
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&worker), 0));
}
