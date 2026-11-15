//! Address-stable streaming history and copied dictionary. Recovery requires 128 KiB regardless of
//! block size; no compressed block is buffered.

const std = @import("std");
const FrameDecodeWorkspace = @This();

/// Raw decoder ring of copied dictionary and decoded bytes, indexed by its worker.
history: [65536]u8,
/// Copied initial dictionary suffix, separate from the changing linked history.
dictionary: [65536]u8,

/// Allocates uninitialized storage at its final address.
pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*FrameDecodeWorkspace {
    return allocator.create(FrameDecodeWorkspace);
}

/// Releases this allocation using the allocator supplied to create.
pub fn destroy(self: *FrameDecodeWorkspace, allocator: std.mem.Allocator) void {
    allocator.destroy(self);
}
