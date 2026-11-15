//! Reusable DEFLATE decoding tables with no source/output history or retained allocator. One call
//! borrows a workspace exclusively; success or failure permits reuse. Construct at its final
//! address with create or caller-owned typed storage. create reserves allocation_bytes, including a
//! private allocation header and worst-case padding; destroy requires the same allocator.
//!
//! literal is a tag-free extern union. Dynamic-header admission selects its live interpretation;
//! prepared payload entries may remain after completion or failure, and the next construction
//! initializes the interpretation it needs. The allocation header lies outside all mutable fields.

const std = @import("std");
const huffman = @import("huffman.zig");
const packed_huffman = @import("packed_huffman.zig");
const fixtures = @import("decode_fixtures.zig");
const test_complete = @import("decode.zig"); // Used only by inline workspace-reuse tests.

const DecodeWorkspace = @This();
const LiteralTable = huffman.LiteralTable;
const ExpandedLiteralTable = huffman.ExpandedLiteralTable;
const ExpandedWideLiteralTable = huffman.ExpandedWideLiteralTable;
const WideLiteralTable = huffman.WideLiteralTable;
const PairedLiteralTable = huffman.PairedLiteralTable;
const DistanceTable = huffman.DistanceTable;
const PrecodeTable = huffman.Huffman(7, 19, .symbols);
const Entry = huffman.Entry;
const paired_literals = fixtures.paired_literals;

/// Complete byte request made by create; caller-supplied values need only their type size.
pub const allocation_bytes = workspace_storage.allocationBytes(DecodeWorkspace);

// The admitted block class selects one interpretation. A tag-free union lets constructors
// initialize it directly, without a large union temporary.
/// Private dynamic literal/length table; initialized when a stream needs it.
literal: extern union {
    ordinary: LiteralTable,
    packed_tables: packed_huffman.Tables,
    expanded: ExpandedLiteralTable,
    expanded_wide: ExpandedWideLiteralTable,
    // Large roots fit beneath the existing paired owner without more storage.
    wide: WideLiteralTable,
    paired: PairedLiteralTable,
},
/// Private dynamic distance table; initialized when a stream needs it.
distance: DistanceTable,
/// Private code-length table used during dynamic-header construction.
precode: PrecodeTable,
/// Private bounded code-length scratch; contents are not a decoded result.
lengths: [320]u8,

/// Allocates an address-stable workspace without initializing unused private scratch. Call
/// `destroy` with the same allocator after the last decode. `OutOfMemory` publishes no workspace.
/// Reserve during initialization for allocation-free repeated decoding.
pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*DecodeWorkspace {
    return workspace_storage.create(allocator, DecodeWorkspace);
}

/// Releases a workspace created through this same allocator. No decode may still be using it. This
/// invalidates the workspace pointer, while caller-owned source/output buffers remain valid.
pub fn destroy(self: *DecodeWorkspace, allocator: std.mem.Allocator) void {
    workspace_storage.destroy(allocator, self);
}

const workspace_storage = struct {
    /// Complete byte request for a `create` call, including its private header and worst-case
    /// padding. Backing allocator overhead remains separate. An unrepresentable type is a compile
    /// error.
    fn allocationBytes(comptime T: type) usize {
        return comptime std.math.add(
            usize,
            @sizeOf(Owner(T)),
            @alignOf(Owner(T)) - 1,
        ) catch @compileError("the complete root reservation must fit usize");
    }

    /// Allocates undefined working state directly at its final naturally aligned address.
    /// Initialize the returned value there; replacing it cannot overwrite the private header. Pair
    /// with `destroy` through this same allocator. Failure publishes no value or storage.
    fn create(allocator: std.mem.Allocator, comptime T: type) std.mem.Allocator.Error!*T {
        const bytes = try allocator.alloc(u8, allocationBytes(T));
        const address = @intFromPtr(bytes.ptr);
        const padding = std.mem.alignForward(usize, address, @alignOf(Owner(T))) - address;
        const owner: *Owner(T) = @ptrCast(@alignCast(bytes[padding..].ptr));
        owner.allocation = bytes;
        return &owner.value;
    }

    /// Releases the complete reservation of a value returned by a `create` call. Retire its
    /// children/active borrows first. Caller-supplied values use their own lifetime; releasing them
    /// or another allocation protocol through this function is invalid.
    fn destroy(allocator: std.mem.Allocator, value: anytype) void {
        const pointer = @typeInfo(@TypeOf(value)).pointer;
        if (pointer.size != .one) @compileError("value must be a single item pointer");
        // The complete owner was aligned during creation, even when its value type is less aligned.
        const owner: *const Owner(pointer.child) = @alignCast(@fieldParentPtr("value", value));
        allocator.free(owner.allocation);
    }

    fn Owner(comptime T: type) type {
        return struct { allocation: []u8, value: T };
    }

    test "root reservations admit exact declared capacity and reject one byte less" {
        const allocator = std.testing.allocator;
        inline for (.{ u8, u16, f32, u64, u128, [1024 * 1024]u8 }) |T| {
            const capacity = allocationBytes(T);
            for (0..@alignOf(Owner(T))) |residue| {
                const prefix = 16 + residue;
                // Leave separate guard bytes even for the largest header alignment residue.
                const extended = try allocator.alignedAlloc(u8, .@"8", capacity + prefix + 16);
                defer allocator.free(extended);
                @memset(extended, 0xa5);
                var bounded = std.heap.FixedBufferAllocator.init(extended[8 .. extended.len - 8]);
                @memset(try bounded.allocator().alloc(u8, prefix), 0x3c);
                var failing = std.testing.FailingAllocator.init(
                    bounded.allocator(),
                    .{ .fail_index = 1 },
                );
                const value = try workspace_storage.create(failing.allocator(), T);
                try std.testing.expectEqual(0, @intFromPtr(value) % @alignOf(T));
                @memset(std.mem.asBytes(value), 0x6d);
                try std.testing.expectEqual(prefix + capacity, bounded.end_index);
                try std.testing.expectEqual(1, failing.alloc_index);
                workspace_storage.destroy(failing.allocator(), @as(*const T, value));
                try std.testing.expectEqual(prefix, bounded.end_index);
                bounded.buffer = bounded.buffer[0 .. bounded.buffer.len - 1];
                try std.testing.expectError(
                    error.OutOfMemory,
                    workspace_storage.create(bounded.allocator(), T),
                );
                try std.testing.expectEqual(prefix, bounded.end_index);
                for (bounded.buffer[0..prefix]) |byte| try std.testing.expectEqual(0x3c, byte);
                for (extended[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
                for (extended[extended.len - 8 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
            }
        }
    }
};

test "DEFLATE workspaces restore bounded backing after decoding and exhaustion" {
    const allocator = std.testing.allocator;
    const fixture = paired_literals;
    const backing = try allocator.alignedAlloc(u8, .@"8", @sizeOf(DecodeWorkspace) + 128);
    defer allocator.free(backing);
    for (0..@alignOf(DecodeWorkspace)) |residue| {
        const prefix = 16 + residue;
        for (0..2) |index| {
            @memset(backing, 0xa5);
            var bounded = std.heap.FixedBufferAllocator.init(backing[8 .. backing.len - 8]);
            @memset(try bounded.allocator().alloc(u8, prefix), 0x3c);
            var failing = std.testing.FailingAllocator.init(
                bounded.allocator(),
                .{ .fail_index = index },
            );
            if (DecodeWorkspace.create(failing.allocator())) |workspace| {
                const live = bounded.end_index;
                const requests = failing.alloc_index;
                var output: [fixture.expected.len + 8]u8 = undefined;
                for (0..2) |_| {
                    @memset(std.mem.asBytes(workspace), 0x6d);
                    try std.testing.expectError(
                        error.InvalidStream,
                        test_complete.into(
                            fixture.source[0 .. fixture.source.len / 2],
                            &output,
                            .{ .workspace = workspace },
                            .{},
                        ),
                    );
                    @memset(&output, 0xa5);
                    const decoded = try test_complete.into(
                        fixture.source,
                        output[0..fixture.expected.len],
                        .{ .workspace = workspace },
                        .{},
                    );
                    try std.testing.expectEqual(fixture.source.len, decoded.consumed);
                    try std.testing.expectEqual(fixture.expected.len, decoded.produced);
                    try std.testing.expectEqualSlices(
                        u8,
                        fixture.expected,
                        output[0..decoded.produced],
                    );
                    for (output[decoded.produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
                }
                try std.testing.expectEqual(live, bounded.end_index);
                try std.testing.expectEqual(requests, failing.alloc_index);
                workspace.destroy(failing.allocator());
            } else |failure| try std.testing.expectEqual(error.OutOfMemory, failure);
            try std.testing.expectEqual(prefix, bounded.end_index);
            for (bounded.buffer[0..prefix]) |byte| try std.testing.expectEqual(0x3c, byte);
            for (backing[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
            for (backing[backing.len - 8 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
    }
}

test "paired tables retain bounded workspace and entry sizes" {
    try std.testing.expectEqual(4, @sizeOf(Entry));
    try std.testing.expectEqual(
        if (@sizeOf(usize) == 8) 20952 else 20940,
        @sizeOf(DecodeWorkspace),
    );
}

test {
    _ = workspace_storage;
}
