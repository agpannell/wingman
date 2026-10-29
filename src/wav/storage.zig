//! WAVE-owned sample allocation and borrowed-span admission. Byte-backed allocation preserves exact
//! aligned requests, grows a misaligned tail when possible, and releases a refused probe before
//! requesting one padded replacement. No allocator or request accounting is retained.
const std = @import("std");

pub fn overlaps(first: []const u8, second: []const u8) bool {
    if (first.len == 0 or second.len == 0) return false;
    const a = @intFromPtr(first.ptr);
    const b = @intFromPtr(second.ptr);
    return if (a <= b) b - a < first.len else a - b < second.len;
}

pub fn allocateSamples(
    allocator: std.mem.Allocator,
    count: usize,
) (std.mem.Allocator.Error || error{SizeOverflow})!struct { storage: []u8, samples: []f32 } {
    if (count == 0) return .{ .storage = &.{}, .samples = &.{} };
    const bytes = std.math.mul(usize, count, @sizeOf(f32)) catch return error.SizeOverflow;
    var storage = try allocator.alloc(u8, bytes);
    errdefer allocator.free(storage);
    const address = @intFromPtr(storage.ptr);
    const padding = std.mem.alignForward(usize, address, @alignOf(f32)) - address;
    if (padding != 0) {
        const extended = std.math.add(usize, bytes, padding) catch return error.SizeOverflow;
        if (allocator.resize(storage, extended)) {
            storage = storage.ptr[0..extended];
        } else {
            const replacement = std.math.add(
                usize,
                bytes,
                @alignOf(f32) - 1,
            ) catch return error.SizeOverflow;
            allocator.free(storage);
            storage = &.{};
            storage = try allocator.alloc(u8, replacement);
        }
    }
    const aligned = std.mem.alignForward(usize, @intFromPtr(storage.ptr), @alignOf(f32));
    const leading = aligned - @intFromPtr(storage.ptr);
    std.debug.assert(leading <= storage.len and count <= (storage.len - leading) / @sizeOf(f32));
    const pointer: [*]f32 = @ptrFromInt(aligned);
    return .{ .storage = storage, .samples = pointer[0..count] };
}

test "sample storage restores misaligned bounded backing after success or replacement refusal" {
    var backing: [256]u8 align(8) = undefined;
    for (0..8) |residue| {
        for ([_]usize{ 0, 1, 2 }) |fail_index| {
            for ([_]bool{ false, true }) |refuse_resize| {
                @memset(&backing, 0xa5);
                var fixed = std.heap.FixedBufferAllocator.init(backing[residue..]);
                @memset(try fixed.allocator().alloc(u8, 37), 0x3c);
                var failing = std.testing.FailingAllocator.init(
                    fixed.allocator(),
                    .{
                        .fail_index = fail_index,
                        .resize_fail_index = if (refuse_resize) 0 else std.math.maxInt(usize),
                    },
                );
                if (allocateSamples(failing.allocator(), 7)) |owner| {
                    try std.testing.expectEqual(7, owner.samples.len);
                    try std.testing.expectEqual(0, @intFromPtr(owner.samples.ptr) % @alignOf(f32));
                    @memset(owner.samples, 1);
                    failing.allocator().free(owner.storage);
                } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(37, fixed.end_index);
                try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
                try std.testing.expect(std.mem.allEqual(u8, fixed.buffer[0..37], 0x3c));
                try std.testing.expect(std.mem.allEqual(u8, backing[0..residue], 0xa5));
            }
        }
    }
}

test "empty and overflowing sample requests publish no allocation" {
    const empty = try allocateSamples(std.testing.failing_allocator, 0);
    try std.testing.expectEqual(0, empty.samples.len);
    try std.testing.expectEqual(0, empty.storage.len);
    try std.testing.expectError(
        error.SizeOverflow,
        allocateSamples(std.testing.failing_allocator, std.math.maxInt(usize)),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        allocateSamples(std.testing.failing_allocator, 1),
    );
}
