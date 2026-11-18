//! Copied inputs for a deferred BLAKE3 compression. A chunk keeps its final block and a parent
//! keeps both child chaining values until finalization knows which node is the root. An interior
//! chaining value uses the retained chunk counter; root bytes add ROOT and use an output-block
//! counter instead. Keeping these inputs permits both choices and repeated snapshots.

const std = @import("std");
const compression = @import("compression.zig");
const CompressionInput = @This();
const ChainingValue = compression.Cv;
const MessageBlock = compression.Block;
const block_bytes = compression.block_bytes;
const mode_flags = compression.flags;
const Digest = [32]u8;

/// Incoming chaining words, copied from the chunk or the parent mode's key.
cv: ChainingValue,
/// Final chunk block or two ordered child chaining values, in algorithm word order.
block: MessageBlock,
/// Chunk index for a chaining value. Root output substitutes its own 64-byte output-block index.
counter: u64,
/// Meaningful bytes in the block, from zero through 64; absent tail bytes are zero-padded.
length: u32,
/// Chunk/parent and hashing-mode flags. Root conversion adds the ROOT flag.
flags: u32,

/// Computes the interior node's chaining value without changing these inputs.
pub inline fn chainingValue(
    self: CompressionInput,
    comptime kernel: compression.Kernel,
) ChainingValue {
    return compression.chaining(kernel, self.cv, self.block, self.counter, self.length, self.flags);
}

/// Describes a parent of two ordered child chaining values; no compression runs yet.
pub inline fn parent(
    key: ChainingValue,
    left: ChainingValue,
    right: ChainingValue,
    mode: u32,
) CompressionInput {
    return .{
        .cv = key,
        .block = left ++ right,
        .counter = 0,
        .length = block_bytes,
        .flags = mode | mode_flags.parent,
    };
}

/// Computes the default 32 root bytes with output-block counter zero.
pub inline fn rootDigest(self: CompressionInput, comptime kernel: compression.Kernel) Digest {
    const cv = compression.chaining(
        kernel,
        self.cv,
        self.block,
        0,
        self.length,
        self.flags | mode_flags.root,
    );
    var result: Digest = undefined;
    compression.storeCv(cv, &result);
    return result;
}

/// Copies a range of root output. The hasher admits the output range and disjoint destination.
pub fn writeRootBytes(
    self: CompressionInput,
    comptime kernel: compression.Kernel,
    offset: u64,
    out: []u8,
) void {
    var counter = offset / block_bytes;
    var skip: usize = @intCast(offset % block_bytes);
    var remaining = out;
    while (remaining.len != 0) {
        const words = compression.compress(
            kernel,
            self.cv,
            self.block,
            counter,
            self.length,
            self.flags | mode_flags.root,
        );
        var bytes: [block_bytes]u8 = undefined;
        for (words, 0..) |word, i| {
            const word_offset = i * @sizeOf(u32);
            std.mem.writeInt(u32, bytes[word_offset..][0..4], word, .little);
        }

        const count = @min(remaining.len, block_bytes - skip);
        @memcpy(remaining[0..count], bytes[skip..][0..count]);
        remaining = remaining[count..];
        counter += 1;
        skip = 0;
    }
}
