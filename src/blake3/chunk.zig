//! One algorithm chunk: copied tail bytes and deferred final-block compression.
const std = @import("std");
const compression = @import("compression.zig");
const ChainingValue = compression.Cv;
const Output = compression.Output;
const block_bytes = compression.block_bytes;
const chunk_bytes = compression.chunk_bytes;
const mode_flags = compression.flags;
const Digest = [32]u8;

// Owns one chunk's chaining value and pending final block. The tree owner admits at most the
// remaining chunk capacity before calling update.
pub const ChunkState = struct {
    cv: ChainingValue,
    block: [block_bytes]u8,
    block_len: u8,
    blocks_compressed: u8,
    counter: u64,

    pub fn reset(self: *ChunkState, key: ChainingValue, counter: u64) void {
        self.cv = key;
        self.block_len = 0;
        self.blocks_compressed = 0;
        self.counter = counter;
    }

    pub fn length(self: *const ChunkState) usize {
        const compressed_bytes = @as(usize, self.blocks_compressed) * block_bytes;
        return compressed_bytes + self.block_len;
    }

    fn startFlag(self: *const ChunkState) u32 {
        return if (self.blocks_compressed == 0) mode_flags.chunk_start else 0;
    }

    pub inline fn update(
        self: *ChunkState,
        comptime kernel: compression.Kernel,
        input: []const u8,
        mode: u32,
    ) void {
        std.debug.assert(input.len <= chunk_bytes - self.length());
        var bytes = input;
        while (bytes.len != 0) {
            if (self.block_len == block_bytes) {
                self.compressBlock(kernel, &self.block, mode);
                self.block_len = 0;
            }

            // Read complete interior blocks directly. The final block stays buffered so
            // finalization can still apply CHUNK_END and ROOT.
            if (self.block_len == 0 and bytes.len > block_bytes) {
                self.compressBlock(kernel, bytes[0..block_bytes], mode);
                bytes = bytes[block_bytes..];
            } else {
                const take = @min(bytes.len, block_bytes - @as(usize, self.block_len));
                @memcpy(self.block[self.block_len..][0..take], bytes[0..take]);
                self.block_len += @intCast(take);
                bytes = bytes[take..];
            }
        }
    }

    inline fn compressBlock(
        self: *ChunkState,
        comptime kernel: compression.Kernel,
        bytes: []const u8,
        mode: u32,
    ) void {
        const block = compression.loadBlock(bytes);
        self.cv = compression.chaining(
            kernel,
            self.cv,
            block,
            self.counter,
            block_bytes,
            mode | self.startFlag(),
        );
        self.blocks_compressed += 1;
    }

    pub fn output(self: *const ChunkState, mode: u32) Output {
        return .{
            .cv = self.cv,
            .block = compression.loadBlock(self.block[0..self.block_len]),
            .counter = self.counter,
            .length = self.block_len,
            .flags = mode | self.startFlag() | mode_flags.chunk_end,
        };
    }

    // Whole short inputs avoid tree admission and per-block buffering while retaining the same
    // chunk state for a later update or final snapshot.
    pub inline fn hashWhole(
        self: *ChunkState,
        comptime kernel: compression.Kernel,
        input: []const u8,
    ) Digest {
        var remaining = input;
        var cv = self.cv;
        var blocks: u8 = 0;
        while (remaining.len > block_bytes) {
            cv = compression.chaining(
                kernel,
                cv,
                compression.loadBlock(remaining[0..block_bytes]),
                0,
                block_bytes,
                if (blocks == 0) mode_flags.chunk_start else 0,
            );
            blocks += 1;
            remaining = remaining[block_bytes..];
        }

        self.cv = cv;
        self.blocks_compressed = blocks;
        @memcpy(self.block[0..remaining.len], remaining);
        self.block_len = @intCast(remaining.len);
        const start_flag: u32 = if (blocks == 0) mode_flags.chunk_start else 0;
        const final_block: Output = .{
            .cv = cv,
            .block = compression.loadBlock(remaining),
            .counter = 0,
            .length = @intCast(remaining.len),
            .flags = start_flag | mode_flags.chunk_end,
        };
        return final_block.rootDigest(kernel);
    }
};
