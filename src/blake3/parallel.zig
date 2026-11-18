//! Hashes admitted, aligned power-of-two subtrees in caller-owned parallel workspaces. The hasher
//! owns byte-range admission, task submission and joining; these jobs compute ordered subtree
//! children without deciding whether their final parent is the root.
const std = @import("std");
const compression = @import("compression.zig");
const ChunkState = @import("ChunkState.zig");
const ParallelWorkspace = @import("ParallelWorkspace.zig");
const CompressionInput = @import("CompressionInput.zig");
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

pub fn run(workspace: *ParallelWorkspace, comptime kernel: compression.Kernel) void {
    workspace.result = subtree(
        workspace,
        kernel,
        workspace.input.ptr,
        workspace.input.len / chunk_bytes,
        workspace.counter,
    );
}

pub fn runNative(workspace: *ParallelWorkspace) void {
    run(workspace, compression.preferred);
}

pub fn runScalar(workspace: *ParallelWorkspace) void {
    run(workspace, .scalar);
}

fn subtree(
    workspace: *ParallelWorkspace,
    comptime kernel: compression.Kernel,
    input: [*]const u8,
    count: usize,
    counter: u64,
) [2]ChainingValue {
    std.debug.assert(count >= 2 and std.math.isPowerOfTwo(count));
    if (count > workspace.batch.len) {
        const half = count / 2;
        const left = subtree(workspace, kernel, input, half, counter);
        const right = subtree(workspace, kernel, input + half * chunk_bytes, half, counter + half);
        return .{
            parent(workspace, kernel, left[0], left[1]),
            parent(workspace, kernel, right[0], right[1]),
        };
    }

    if (kernel == .scalar) {
        for (0..count) |i| {
            var chunk: ChunkState = undefined;
            chunk.reset(workspace.key, counter + i);
            chunk.update(.scalar, input[i * chunk_bytes ..][0..chunk_bytes], workspace.mode);
            workspace.batch[i] = chunk.compressionInput(workspace.mode).chainingValue(.scalar);
        }
    } else {
        compression.batchChunks(
            workspace.key,
            input,
            counter,
            workspace.mode,
            count,
            &workspace.messages,
            &workspace.batch,
        );
    }

    // Keep the last two children separate so finalization can still apply ROOT to their parent.
    var remaining = count;
    while (remaining > 2) : (remaining /= 2) {
        if (kernel == .scalar) {
            for (0..remaining / 2) |i| {
                const left = workspace.batch[i * 2];
                const right = workspace.batch[i * 2 + 1];
                workspace.batch[i] = parent(workspace, kernel, left, right);
            }
        } else {
            compression.batchParents(
                workspace.key,
                &workspace.batch,
                workspace.mode,
                remaining / 2,
                &workspace.messages,
                &workspace.batch,
            );
        }
    }
    return workspace.batch[0..2].*;
}

fn parent(
    workspace: *const ParallelWorkspace,
    comptime kernel: compression.Kernel,
    left: ChainingValue,
    right: ChainingValue,
) ChainingValue {
    return CompressionInput.parent(
        workspace.key,
        left,
        right,
        workspace.mode,
    ).chainingValue(kernel);
}
