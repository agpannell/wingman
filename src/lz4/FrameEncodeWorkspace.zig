//! Address-stable encoder storage. Reserve input and encoded block buffers for the selected block
//! size; history/dictionary/codec tables stay in this value. Construct with create rather than
//! copying a large temporary owner.

const std = @import("std");
// Inline allocation-failure test only.
const FrameDecodeWorkspace = @import("FrameDecodeWorkspace.zig");
const FrameEncodeWorkspace = @This();
const blocks = @import("block.zig");
const framing = @import("frame.zig");

/// Owned full allocation for staged source bytes; sized for the selected maximum block.
input: []u8,
/// Owned full allocation for the raw encoding bound; retains unused capacity for reuse.
encoded: []u8,
/// Initialized prefix holds the reachable suffix of the dictionary and preceding linked blocks.
history: [65536]u8,
/// Initialized prefix holds the copied initial dictionary, reused by independent blocks.
dictionary: [65536]u8,
/// Greedy hash-table backing; its representation is governed by the private greedy owner.
codec: blocks.encode.Workspace,

/// Allocates the owner and both block buffers, cleaning up on failure.
pub fn create(
    allocator: std.mem.Allocator,
    block_size: framing.BlockSize,
) std.mem.Allocator.Error!*FrameEncodeWorkspace {
    const self = try allocator.create(FrameEncodeWorkspace);
    errdefer allocator.destroy(self);
    self.input = try allocator.alloc(u8, block_size.bytes());
    errdefer allocator.free(self.input);
    const encoded_capacity = blocks.encode.bound(block_size.bytes()) catch unreachable;
    self.encoded = try allocator.alloc(u8, encoded_capacity);
    return self;
}

/// Releases both full buffers and this owner with the construction allocator.
pub fn destroy(self: *FrameEncodeWorkspace, allocator: std.mem.Allocator) void {
    allocator.free(self.encoded);
    allocator.free(self.input);
    allocator.destroy(self);
}

fn allocationCheck(allocator: std.mem.Allocator) !void {
    const workspace = try FrameEncodeWorkspace.create(allocator, .k64);
    defer workspace.destroy(allocator);
    const decoder = try FrameDecodeWorkspace.create(allocator);
    defer decoder.destroy(allocator);
}

test "LZ4 frame workspace construction cleans partial allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCheck, .{});
}
