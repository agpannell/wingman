//! Address-stable greedy LZ4 match-table reservation. One encoding owner borrows it at a time.
const std = @import("std");
const BlockEncodeWorkspace = @This();

/// Internal match-table cells, initialized by complete encoding and advanced by linked framing.
positions: [4096]u32,

/// Allocates scratch directly at its final address; encoding initializes all table cells.
pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*BlockEncodeWorkspace {
    return allocator.create(BlockEncodeWorkspace);
}

/// Releases this sole allocation through the authority used by create.
pub fn destroy(self: *BlockEncodeWorkspace, allocator: std.mem.Allocator) void {
    allocator.destroy(self);
}
