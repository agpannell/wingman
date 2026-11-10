//! Shared byte-allocation ownership, alignment and bounded temporary storage.

const std = @import("std");

/// Backing exhaustion or overflow in reservation size or total requested bytes.
pub const Error = std.mem.Allocator.Error || error{SizeOverflow};

/// Requested storage bytes and successful allocation calls, excluding allocator overhead. In-place
/// padding growth counts the final size once. A released alignment probe and its replacement both
/// count when the backing allocator cannot grow that first span.
pub const AllocationCost = struct {
    /// Total requested storage, including required codec-owned alignment padding.
    bytes: usize = 0,
    /// Successful allocation calls; resize is not a new allocation.
    allocations: usize = 0,
};

/// A naturally aligned typed slice backed by a complete owned byte allocation. Exact-sized requests
/// preserve backing allocator size classes when the returned span is already aligned. Otherwise,
/// grow it in place for padding, or release that probe before requesting one replacement with
/// enough padding for any returned address. `initPadded` instead reserves maximum padding in one
/// request, without a resize or probe. No allocator is retained; `deinit(allocator)` uses the
/// original construction allocator.
pub fn AlignedAllocation(comptime Sample: type) type {
    if (@sizeOf(Sample) == 0) @compileError("a storage element must occupy storage");
    return struct {
        /// Complete byte owner, including padding; typed samples borrow this storage.
        storage: []u8,
        /// Naturally aligned storage elements; initialization remains the caller's responsibility.
        samples: []Sample,
        /// Requests used to construct this owner, including a discarded alignment probe.
        cost: AllocationCost,

        const Self = @This();

        /// Allocates aligned storage without retaining its allocator or borrowing prior owners.
        /// Zero elements allocate nothing. Exhaustion frees any probe; no fallback heap exists.
        /// SizeOverflow also covers the combined byte requests for a probe and its replacement.
        pub fn init(allocator: std.mem.Allocator, count: usize) Error!Self {
            return initInternal(allocator, count, true);
        }

        /// Allocates the same aligned storage without cumulative request accounting. Only actual
        /// reservation sizes can overflow. The caller owns the complete returned byte span.
        pub fn initStorage(
            allocator: std.mem.Allocator,
            count: usize,
        ) Error!struct { storage: []u8, samples: []Sample } {
            const result = try initInternal(allocator, count, false);
            return .{ .storage = result.storage, .samples = result.samples };
        }

        fn initInternal(
            allocator: std.mem.Allocator,
            count: usize,
            comptime account_requests: bool,
        ) Error!Self {
            if (count == 0) return .{ .storage = &.{}, .samples = &.{}, .cost = .{} };
            const bytes = std.math.mul(
                usize,
                count,
                @sizeOf(Sample),
            ) catch return error.SizeOverflow;
            var storage = try allocator.alloc(u8, bytes);
            errdefer allocator.free(storage);
            var cost: AllocationCost = .{ .bytes = bytes, .allocations = 1 };
            const address = @intFromPtr(storage.ptr);
            const padding = std.mem.alignForward(usize, address, @alignOf(Sample)) - address;
            if (padding != 0) {
                const extended = std.math.add(
                    usize,
                    bytes,
                    padding,
                ) catch return error.SizeOverflow;
                if (allocator.resize(storage, extended)) {
                    storage = storage.ptr[0..extended];
                    cost.bytes = extended;
                } else {
                    const replacement = std.math.add(
                        usize,
                        bytes,
                        @alignOf(Sample) - 1,
                    ) catch return error.SizeOverflow;
                    if (account_requests) {
                        cost.bytes = std.math.add(
                            usize,
                            bytes,
                            replacement,
                        ) catch return error.SizeOverflow;
                    }
                    allocator.free(storage);
                    storage = &.{};
                    storage = try allocator.alloc(u8, replacement);
                    cost.allocations = 2;
                }
            }
            return fromStorage(storage, count, cost);
        }

        /// Bytes required for count aligned elements, including maximum leading padding. Empty
        /// regions need no bytes; this checks sizing without reserving storage.
        pub fn storageSize(count: usize) error{SizeOverflow}!usize {
            if (count == 0) return 0;
            const bytes = std.math.mul(
                usize,
                count,
                @sizeOf(Sample),
            ) catch return error.SizeOverflow;
            return std.math.add(usize, bytes, @alignOf(Sample) - 1) catch return error.SizeOverflow;
        }

        /// Allocates once with maximum alignment padding, without requesting a resize. The nonempty
        /// byte request is storageSize(count). Zero elements allocate nothing. Overflow or
        /// exhaustion publishes no storage.
        pub fn initPadded(allocator: std.mem.Allocator, count: usize) Error!Self {
            if (count == 0) return .{ .storage = &.{}, .samples = &.{}, .cost = .{} };
            const reserved = try storageSize(count);
            const storage = try allocator.alloc(u8, reserved);
            return fromStorage(storage, count, .{ .bytes = reserved, .allocations = 1 });
        }

        /// Releases the complete span, including padding; no sample view may remain in use.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.storage);
            self.* = .{ .storage = &.{}, .samples = &.{}, .cost = .{} };
        }

        fn fromStorage(storage: []u8, count: usize, cost: AllocationCost) Self {
            const address = std.mem.alignForward(usize, @intFromPtr(storage.ptr), @alignOf(Sample));
            const padding = address - @intFromPtr(storage.ptr);
            std.debug.assert(
                padding <= storage.len and count <= (storage.len - padding) / @sizeOf(Sample),
            );
            const pointer: [*]Sample = @ptrFromInt(address);
            return .{ .storage = storage, .samples = pointer[0..count], .cost = cost };
        }
    };
}

/// Constructs undefined storage for an address-stable value, retaining no allocator. A private
/// header owns the complete byte reservation, including alignment padding. Initializing or
/// resetting the entire value cannot overwrite that ownership record. Initialize the returned value
/// directly at its final address, then pair with `destroy` through the same allocator. An
/// unrepresentable reservation reports `OutOfMemory`. Caller-supplied values do not use this
/// allocation protocol.
pub fn create(allocator: std.mem.Allocator, comptime T: type) std.mem.Allocator.Error!*T {
    const reserved = AlignedAllocation(Owner(T)).init(allocator, 1) catch return error.OutOfMemory;
    const owner = &reserved.samples[0];
    owner.allocation = reserved.storage;
    return &owner.value;
}

/// Reserves one final-address root and trailing caller-managed bytes in one allocation. A private
/// header retains the complete allocation independently of root reset. Tail storage follows the
/// complete aligned owner; consumers account for any alignment required inside that byte span. Pair
/// the value with destroy through the same allocator after the final root/tail borrow.
pub fn createWithTail(
    allocator: std.mem.Allocator,
    comptime T: type,
    tail_bytes: usize,
) std.mem.Allocator.Error!struct { value: *T, tail: []u8 } {
    const header_bytes = std.math.add(
        usize,
        @sizeOf(Owner(T)),
        @alignOf(Owner(T)) - 1,
    ) catch return error.OutOfMemory;
    const total = std.math.add(usize, header_bytes, tail_bytes) catch return error.OutOfMemory;
    const allocation = try allocator.alloc(u8, total);
    const address = std.mem.alignForward(usize, @intFromPtr(allocation.ptr), @alignOf(Owner(T)));
    const owner: *Owner(T) = @ptrFromInt(address);
    owner.allocation = allocation;
    const offset = address - @intFromPtr(allocation.ptr) + @sizeOf(Owner(T));
    return .{ .value = &owner.value, .tail = allocation[offset..][0..tail_bytes] };
}

/// Releases a value constructed by `create` or `createWithTail`, including its allocation. Retire
/// any separately owned children first. Value/source/backing borrows remain governed by their
/// concrete owner; freeing a caller-supplied value through this function is invalid.
pub fn destroy(allocator: std.mem.Allocator, value: anytype) void {
    const pointer = @typeInfo(@TypeOf(value)).pointer;
    if (pointer.size != .one) @compileError("value must be a single item pointer");
    // `create` aligned the complete owner; the value's narrower type may lose that fact.
    const owner: *const Owner(pointer.child) = @alignCast(@fieldParentPtr("value", value));
    allocator.free(owner.allocation);
}

fn Owner(comptime T: type) type {
    return struct { allocation: []u8, value: T };
}

test "padded aligned storage keeps one request and restores misaligned bounded backing" {
    const allocator = std.testing.allocator;
    inline for (.{ u16, u64, [3]f32, u128 }) |Sample| {
        const alignment = @alignOf(Sample);
        const requested = 3 * @sizeOf(Sample) + alignment - 1;
        const backing = try allocator.alignedAlloc(u8, .@"16", requested + alignment + 48);
        defer allocator.free(backing);
        for (0..alignment) |residue| {
            @memset(backing, 0xa5);
            const start = 16 + residue;
            var fixed = std.heap.FixedBufferAllocator.init(backing[start..][0 .. 17 + requested]);
            const prefix = try fixed.allocator().alloc(u8, 17);
            @memset(prefix, 0x5a);
            var authority = std.testing.FailingAllocator.init(
                fixed.allocator(),
                .{ .fail_index = 1, .resize_fail_index = 0 },
            );
            var owner = try AlignedAllocation(Sample).initPadded(authority.allocator(), 3);
            try std.testing.expectEqual(3, owner.samples.len);
            try std.testing.expectEqual(0, @intFromPtr(owner.samples.ptr) % alignment);
            try std.testing.expectEqual(requested, owner.storage.len);
            try std.testing.expectEqual(
                AllocationCost{ .bytes = requested, .allocations = 1 },
                owner.cost,
            );
            @memset(std.mem.sliceAsBytes(owner.samples), 0x3c);
            owner.deinit(authority.allocator());
            try std.testing.expectEqual(1, authority.alloc_index);
            try std.testing.expectEqual(requested, authority.freed_bytes);
            try std.testing.expectEqual(17, fixed.end_index);
            try std.testing.expect(std.mem.allEqual(u8, prefix, 0x5a));
            try std.testing.expect(std.mem.allEqual(u8, backing[0..start], 0xa5));
            try std.testing.expect(std.mem.allEqual(u8, backing[start + 17 + requested ..], 0xa5));

            fixed.buffer = fixed.buffer[0 .. fixed.buffer.len - 1];
            try std.testing.expectError(
                error.OutOfMemory,
                AlignedAllocation(Sample).initPadded(fixed.allocator(), 3),
            );
            try std.testing.expectEqual(17, fixed.end_index);
        }

        var empty = try AlignedAllocation(Sample).initPadded(std.testing.failing_allocator, 0);
        try std.testing.expectEqual(0, empty.storage.len);
        try std.testing.expectEqual(0, empty.samples.len);
        try std.testing.expectEqual(AllocationCost{}, empty.cost);
        empty.deinit(std.testing.failing_allocator);
        try std.testing.expectError(
            error.SizeOverflow,
            AlignedAllocation(
                Sample,
            ).initPadded(std.testing.failing_allocator, std.math.maxInt(usize)),
        );
    }
}

test "allocated retained roots preserve ownership outside replaced values" {
    const allocator = std.testing.allocator;
    inline for (.{ u8, u16, f32, [3]f32, u64, u128, [1024 * 1024]u8 }) |T| {
        const backing = try allocator.alignedAlloc(u8, .@"8", @sizeOf(Owner(T)) + 128);
        defer allocator.free(backing);
        for (0..@alignOf(Owner(T))) |residue| {
            const prefix = 16 + residue;
            inline for (.{ false, true }) |decline_resize| {
                var index: usize = 0;
                while (true) : (index += 1) {
                    try std.testing.expect(index < 3);
                    @memset(backing, 0xa5);
                    var fixed = std.heap.FixedBufferAllocator.init(backing[8 .. backing.len - 8]);
                    @memset(try fixed.allocator().alloc(u8, prefix), 0x3c);
                    var failing = std.testing.FailingAllocator.init(
                        fixed.allocator(),
                        .{
                            .fail_index = index,
                            .resize_fail_index = if (decline_resize) 0 else std.math.maxInt(usize),
                        },
                    );
                    var succeeded = false;
                    if (create(failing.allocator(), T)) |value| {
                        try std.testing.expectEqual(0, @intFromPtr(value) % @alignOf(T));
                        const live = fixed.end_index;
                        const requests = failing.alloc_index;
                        for (0..2) |_| @memset(std.mem.asBytes(value), 0x6d);
                        try std.testing.expectEqual(live, fixed.end_index);
                        try std.testing.expectEqual(requests, failing.alloc_index);
                        destroy(failing.allocator(), @as(*const T, value));
                        succeeded = true;
                    } else |failure| try std.testing.expectEqual(error.OutOfMemory, failure);
                    try std.testing.expectEqual(prefix, fixed.end_index);
                    for (fixed.buffer[0..prefix]) |byte| try std.testing.expectEqual(0x3c, byte);
                    for (backing[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
                    for (
                        backing[backing.len - 8 ..],
                    ) |byte| try std.testing.expectEqual(0xa5, byte);
                    if (succeeded) break;
                }
            }
        }
    }
}

test "aligned storage restores each natural alignment after success and exhaustion" {
    const allocator = std.testing.allocator;
    const backing = try allocator.alignedAlloc(u8, .@"8", 1024 + 16);
    defer allocator.free(backing);
    inline for (.{ u8, u16, f32, [3]f32, u64 }) |Sample| {
        for (0..@alignOf(Sample) + 1) |prefix| {
            inline for (.{ false, true }) |decline_resize| {
                var index: usize = 0;
                while (true) : (index += 1) {
                    try std.testing.expect(index < 3);
                    @memset(backing, 0x6d);
                    var fixed: std.heap.FixedBufferAllocator = .init(backing[8 .. backing.len - 8]);
                    @memset(try fixed.allocator().alloc(u8, prefix), 0x6d);
                    var failing: std.testing.FailingAllocator = .init(
                        fixed.allocator(),
                        .{
                            .fail_index = index,
                            .resize_fail_index = if (decline_resize) 0 else std.math.maxInt(usize),
                        },
                    );
                    const result = AlignedAllocation(Sample).init(failing.allocator(), 7);
                    if (result) |reserved| {
                        var owner = reserved;
                        try std.testing.expectEqual(
                            0,
                            @intFromPtr(owner.samples.ptr) % @alignOf(Sample),
                        );
                        try std.testing.expectEqual(fixed.buffer[prefix..].ptr, owner.storage.ptr);
                        try std.testing.expectEqual(prefix + owner.storage.len, fixed.end_index);
                        const bytes = std.mem.sliceAsBytes(owner.samples);
                        const offset = @intFromPtr(bytes.ptr) - @intFromPtr(owner.storage.ptr);
                        try std.testing.expect(offset + bytes.len <= owner.storage.len);
                        @memset(bytes, 0xa5);
                        owner.deinit(failing.allocator());
                        try std.testing.expectEqual(0, owner.storage.len);
                        try std.testing.expectEqual(0, owner.samples.len);
                    } else |err| {
                        try std.testing.expectEqual(error.OutOfMemory, err);
                        try std.testing.expect(failing.has_induced_failure);
                    }
                    try std.testing.expectEqual(prefix, fixed.end_index);
                    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
                    for (backing[0 .. 8 + prefix]) |byte| try std.testing.expectEqual(0x6d, byte);
                    for (
                        backing[backing.len - 8 ..],
                    ) |byte| try std.testing.expectEqual(0x6d, byte);
                    if (result) |_| break else |_| {}
                }
            }
        }
    }
}

test "aligned planes replace an unaligned probe when backing cannot resize" {
    const allocator = std.testing.allocator;
    const backing = try allocator.alignedAlloc(u8, .@"2", 8 + 17 + 307 + 8);
    defer allocator.free(backing);
    @memset(backing, 0xa5);
    var fixed: std.heap.FixedBufferAllocator = .init(backing[8..][0 .. 17 + 307]);
    const prefix = try fixed.allocator().alloc(u8, 17);
    @memset(prefix, 0x3c);
    var failing: std.testing.FailingAllocator = .init(
        fixed.allocator(),
        .{ .resize_fail_index = 0 },
    );
    var plane = try AlignedAllocation(u16).init(failing.allocator(), 153);
    defer plane.deinit(failing.allocator());
    try std.testing.expectEqualDeep(AllocationCost{ .bytes = 613, .allocations = 2 }, plane.cost);
    try std.testing.expectEqual(307, plane.storage.len);
    try std.testing.expectEqual(153, plane.samples.len);
    try std.testing.expectEqual(0, @intFromPtr(plane.samples.ptr) % 2);
    for (plane.samples, 0..) |*sample, index| sample.* = @intCast(1024 + index);
    for (
        plane.samples,
        0..,
    ) |sample, index| try std.testing.expectEqual(@as(u16, @intCast(1024 + index)), sample);
    plane.deinit(failing.allocator());
    try std.testing.expectEqual(17, fixed.end_index);
    try std.testing.expectEqual(613, failing.allocated_bytes);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    const empty = try AlignedAllocation(u16).init(std.testing.failing_allocator, 0);
    try std.testing.expectEqual(0, empty.storage.len);
    try std.testing.expectEqual(0, empty.samples.len);
    try std.testing.expectEqualDeep(AllocationCost{}, empty.cost);
    try std.testing.expectError(
        error.SizeOverflow,
        AlignedAllocation(u16).init(std.testing.failing_allocator, std.math.maxInt(usize)),
    );
    for (prefix) |byte| try std.testing.expectEqual(0x3c, byte);
    for (backing[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
    for (backing[backing.len - 8 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
}

test "aligned plane padding distinguishes scratch policy from backing exhaustion" {
    const allocator = std.testing.allocator;
    const backing = try allocator.alignedAlloc(u8, .@"2", 8 + 17 + 307 + 8);
    defer allocator.free(backing);
    for (
        [_]struct {
            limit: usize,
            available: usize,
        }{
            .{ .limit = 306, .available = 307 },
            .{ .limit = 307, .available = 306 },
            .{ .limit = 307, .available = 307 },
        },
    ) |case| {
        @memset(backing, 0xa5);
        var fixed: std.heap.FixedBufferAllocator = .init(backing[8..][0 .. 17 + case.available]);
        const prefix = try fixed.allocator().alloc(u8, 17);
        @memset(prefix, 0x3c);
        var scratch: Scratch = .{ .backing = fixed.allocator(), .maximum_bytes = case.limit };
        const result = AlignedAllocation(u16).init(scratch.allocator(), 153);
        if (case.limit == 307 and case.available == 307) {
            var plane = try result;
            defer plane.deinit(scratch.allocator());
            try std.testing.expectEqualDeep(
                AllocationCost{ .bytes = 307, .allocations = 1 },
                plane.cost,
            );
            try std.testing.expectEqual(307, scratch.live_bytes);
            @memset(plane.samples, 0x1234);
            plane.deinit(scratch.allocator());
        } else {
            try std.testing.expectError(error.OutOfMemory, result);
            try std.testing.expectEqual(case.limit == 306, scratch.refused);
        }
        try std.testing.expectEqual(0, scratch.live_bytes);
        try std.testing.expectEqual(17, fixed.end_index);
        for (prefix) |byte| try std.testing.expectEqual(0x3c, byte);
        for (backing[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (backing[8 + 17 + case.available ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

/// Call-local scratch authority with no additional backing storage or headers. Construct it at its
/// final address and keep it and `backing` active while its allocator is borrowed. Free temporary
/// allocations through that allocator before the synchronous call ends; transferred storage can
/// later be freed by the original backing allocator. Do not copy or concurrently use the active
/// accounting owner.
///
/// Its allocator reports policy refusal as `OutOfMemory`, like backing exhaustion. Classify the
/// failure through `classifyFailure` while `refused` describes the request, before another can
/// clear it.
pub const Scratch = struct {
    /// Caller-supplied authority, borrowed only for this synchronous operation.
    backing: std.mem.Allocator,
    /// Maximum live requested bytes; backing exhaustion never falls back to another heap.
    maximum_bytes: usize,
    /// Current live requested bytes, maintained across successful resize/remap and free.
    live_bytes: usize = 0,
    /// True when the latest allocation, resize or remap handled here exceeded this policy.
    /// Admitting a request clears it, even if backing storage subsequently refuses that request.
    refused: bool = false,

    /// Borrows allocation authority tied to this small owner's stable address.
    pub fn allocator(self: *Scratch) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    /// Classifies OutOfMemory from an operation using this scratch allocator. The latest refused
    /// callback reports ScratchBudgetExceeded; backing exhaustion remains OutOfMemory. Other
    /// failures pass through unchanged, and the returned error set adds only ScratchBudgetExceeded
    /// to the supplied error value's set. No allocator call occurs. A handled optional refusal must
    /// be followed by the operation's own failing callback before attributing a later allocation
    /// failure to this owner.
    pub fn classifyFailure(
        self: *const Scratch,
        failure: anytype,
    ) (@TypeOf(failure) || error{ScratchBudgetExceeded}) {
        return if (failure == error.OutOfMemory and self.refused)
            error.ScratchBudgetExceeded
        else
            failure;
    }

    fn permits(self: *Scratch, old: usize, new: usize) bool {
        std.debug.assert(old <= self.live_bytes);
        const remaining = self.live_bytes - old;
        self.refused = new > self.maximum_bytes -| remaining;
        return !self.refused;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        if (!self.permits(0, len)) return null;
        const result = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.live_bytes += len;
        return result;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        if (!self.permits(memory.len, new_len)) return false;
        if (!self.backing.rawResize(memory, alignment, new_len, ra)) return false;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return true;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        if (!self.permits(memory.len, new_len)) return null;
        const result = self.backing.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.live_bytes = self.live_bytes - memory.len + new_len;
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        std.debug.assert(memory.len <= self.live_bytes);
        self.live_bytes -= memory.len;
        self.backing.rawFree(memory, alignment, ra);
    }
};

test "scratch policy distinguishes backing failure and reclaims released reservations" {
    var backing: [16]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var scratch: Scratch = .{ .backing = fixed.allocator(), .maximum_bytes = 16 };
    const allocator = scratch.allocator();
    const a = try allocator.alloc(u8, 10);
    const b = try allocator.alloc(u8, 6);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expect(scratch.refused);
    try std.testing.expectEqual(
        error.ScratchBudgetExceeded,
        scratch.classifyFailure(error.OutOfMemory),
    );
    try std.testing.expectEqual(error.InvalidData, scratch.classifyFailure(error.InvalidData));
    allocator.free(b);
    try std.testing.expectEqual(10, scratch.live_bytes);
    a[0] = 7;
    try std.testing.expect(allocator.remap(a, 17) == null);
    try std.testing.expect(scratch.refused);
    try std.testing.expectEqual(10, scratch.live_bytes);
    try std.testing.expectEqual(7, a[0]);
    try std.testing.expect(allocator.resize(a, 4));
    try std.testing.expectEqual(4, scratch.live_bytes);
    allocator.free(@as([]u8, a[0..4]));
    try std.testing.expectEqual(0, scratch.live_bytes);

    scratch.backing = std.testing.failing_allocator;
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expect(!scratch.refused);
    try std.testing.expectEqual(error.OutOfMemory, scratch.classifyFailure(error.OutOfMemory));
    try std.testing.expectEqual(
        std.mem.Allocator.Error || error{ScratchBudgetExceeded},
        @TypeOf(scratch.classifyFailure(@as(std.mem.Allocator.Error, error.OutOfMemory))),
    );
    try std.testing.expectEqual(0, scratch.live_bytes);
}

test "scratch resize preserves sibling storage and admits exact replacement charges" {
    var storage: [16]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var backing = std.testing.FailingAllocator.init(fixed.allocator(), .{});
    var scratch: Scratch = .{ .backing = backing.allocator(), .maximum_bytes = 16 };
    const allocator = scratch.allocator();
    var first = try allocator.alloc(u8, 8);
    defer allocator.free(first);
    var second = try allocator.alloc(u8, 8);
    defer allocator.free(second);
    @memcpy(first, "abcdefgh");
    @memcpy(second, "ijklmnop");

    try std.testing.expect(!allocator.resize(second, 9));
    try std.testing.expect(scratch.refused);
    try std.testing.expectEqual(0, backing.resize_index);
    try std.testing.expectEqual(16, scratch.live_bytes);
    try std.testing.expectEqualSlices(u8, "ijklmnop", second);

    try std.testing.expect(allocator.resize(second, 4));
    second = second[0..4];
    try std.testing.expect(!scratch.refused);
    try std.testing.expectEqual(12, scratch.live_bytes);
    try std.testing.expectEqualSlices(u8, "ijkl", second);
    try std.testing.expect(!allocator.resize(first, 9));
    try std.testing.expect(!scratch.refused);
    try std.testing.expectEqual(1, backing.resize_index);
    try std.testing.expectEqual(12, scratch.live_bytes);
    try std.testing.expectEqualSlices(u8, "abcdefgh", first);
    try std.testing.expectEqualSlices(u8, "ijkl", second);

    second = allocator.remap(second, 0).?;
    try std.testing.expectEqual(8, scratch.live_bytes);
    try std.testing.expect(allocator.resize(first, 16));
    first = first.ptr[0..16];
    try std.testing.expectEqual(16, scratch.live_bytes);
    try std.testing.expectEqualSlices(u8, "abcdefgh", first[0..8]);
    try std.testing.expect(!allocator.resize(first, 17));
    try std.testing.expect(scratch.refused);
    try std.testing.expectEqual(2, backing.resize_index);
    try std.testing.expectEqualSlices(u8, "abcdefgh", first[0..8]);

    allocator.free(first);
    first = first[0..0];
    try std.testing.expectEqual(0, scratch.live_bytes);
    try std.testing.expectEqual(24, backing.allocated_bytes);
    try std.testing.expectEqual(24, backing.freed_bytes);
    try std.testing.expectEqual(2, backing.deallocations);
}

test "scratch remap preserves relocated aligned storage and distinguishes refusals" {
    const Relocating = struct {
        const Relocating = @This();

        backing: std.mem.Allocator,
        attempts: usize = 0,
        frees: usize = 0,
        deny: bool = false,
        last_alignment: ?std.mem.Alignment = null,

        fn allocator(self: *Relocating) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = std.mem.Allocator.noResize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *Relocating = @ptrCast(@alignCast(ctx));
            return self.backing.rawAlloc(len, alignment, ra);
        }

        fn remap(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ra: usize,
        ) ?[*]u8 {
            const self: *Relocating = @ptrCast(@alignCast(ctx));
            self.attempts += 1;
            self.last_alignment = alignment;
            if (self.deny) return null;

            // Keeping the old allocation live forces a distinct replacement address.
            const result = self.backing.rawAlloc(new_len, alignment, ra) orelse return null;
            const copy_length = @min(memory.len, new_len);
            @memcpy(result[0..copy_length], memory[0..copy_length]);
            self.backing.rawFree(memory, alignment, ra);
            return result;
        }

        fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *Relocating = @ptrCast(@alignCast(ctx));
            self.frees += 1;
            self.backing.rawFree(memory, alignment, ra);
        }
    };

    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var relocating: Relocating = .{ .backing = backing.allocator() };
    var scratch: Scratch = .{ .backing = relocating.allocator(), .maximum_bytes = 12 };
    const allocator = scratch.allocator();
    var memory = try allocator.alignedAlloc(u8, .@"16", 8);
    defer allocator.free(memory);
    @memcpy(memory, "abcdefgh");
    const first_address = @intFromPtr(memory.ptr);

    memory = allocator.remap(memory, 12) orelse return error.UnexpectedRemapFailure;
    try std.testing.expect(@intFromPtr(memory.ptr) != first_address);
    try std.testing.expectEqual(12, scratch.live_bytes);
    try std.testing.expectEqual(std.mem.Alignment.@"16", relocating.last_alignment);
    try std.testing.expectEqualSlices(u8, "abcdefgh", memory[0..8]);
    const second_address = @intFromPtr(memory.ptr);
    memory = allocator.remap(memory, 4) orelse return error.UnexpectedRemapFailure;
    try std.testing.expect(@intFromPtr(memory.ptr) != second_address);
    try std.testing.expectEqual(4, scratch.live_bytes);
    try std.testing.expectEqualSlices(u8, "abcd", memory);

    try std.testing.expect(allocator.remap(memory, 13) == null);
    try std.testing.expect(scratch.refused);
    try std.testing.expectEqual(2, relocating.attempts);
    relocating.deny = true;
    try std.testing.expect(allocator.remap(memory, 6) == null);
    try std.testing.expect(!scratch.refused);
    try std.testing.expectEqual(3, relocating.attempts);
    try std.testing.expectEqual(4, scratch.live_bytes);
    try std.testing.expectEqualSlices(u8, "abcd", memory);

    allocator.free(memory);
    memory = memory[0..0];
    try std.testing.expectEqual(0, scratch.live_bytes);
    try std.testing.expectEqual(1, relocating.frees);
    try std.testing.expectEqual(3, backing.allocations);
    try std.testing.expectEqual(3, backing.deallocations);
    try std.testing.expectEqual(24, backing.allocated_bytes);
    try std.testing.expectEqual(24, backing.freed_bytes);
}

test "scratch realloc fallback admits overlapping requests and preserves refused input" {
    var backing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .resize_fail_index = 0 },
    );
    var scratch: Scratch = .{ .backing = backing.allocator(), .maximum_bytes = 12 };
    const allocator = scratch.allocator();
    var memory = try allocator.alloc(u8, 5);
    defer allocator.free(memory);
    @memcpy(memory, "abcde");
    const original_address = @intFromPtr(memory.ptr);

    try std.testing.expectError(error.OutOfMemory, allocator.realloc(memory, 8));
    try std.testing.expect(scratch.refused);
    try std.testing.expectEqual(5, scratch.live_bytes);
    try std.testing.expectEqual(1, backing.allocations);
    try std.testing.expectEqual(0, backing.deallocations);
    try std.testing.expectEqualSlices(u8, "abcde", memory);

    scratch.maximum_bytes = 13;
    backing.fail_index = 1;
    try std.testing.expectError(error.OutOfMemory, allocator.realloc(memory, 8));
    try std.testing.expect(!scratch.refused);
    try std.testing.expectEqual(5, scratch.live_bytes);
    try std.testing.expectEqual(1, backing.allocations);
    try std.testing.expectEqual(0, backing.deallocations);
    try std.testing.expectEqualSlices(u8, "abcde", memory);

    backing.fail_index = std.math.maxInt(usize);
    memory = try allocator.realloc(memory, 8);
    try std.testing.expect(@intFromPtr(memory.ptr) != original_address);
    try std.testing.expectEqual(8, scratch.live_bytes);
    try std.testing.expect(!scratch.refused);
    try std.testing.expectEqualSlices(u8, "abcde", memory[0..5]);
    try std.testing.expectEqual(2, backing.allocations);
    try std.testing.expectEqual(1, backing.deallocations);
    try std.testing.expectEqual(13, backing.allocated_bytes);
    try std.testing.expectEqual(5, backing.freed_bytes);

    memory = try allocator.realloc(memory, 0);
    try std.testing.expectEqual(0, scratch.live_bytes);
    try std.testing.expectEqual(2, backing.deallocations);
    try std.testing.expectEqual(13, backing.freed_bytes);
}

test "retained roots and tails share one padded owner across full-value reset and refusal" {
    const Value = struct { wide: u128 = 0, number: u32 = 0 };
    var backing: [513]u8 = @splat(0xa5);
    var fixed: std.heap.FixedBufferAllocator = .init(backing[1..]);
    const allocator = fixed.allocator();
    const prefix = try allocator.alloc(u8, 17);
    @memset(prefix, 0x5a);
    const reservation = try createWithTail(allocator, Value, 43);
    reservation.value.* = .{ .wide = 19, .number = 31 };
    @memset(reservation.tail, 0x3c);
    reservation.value.* = .{};
    try std.testing.expectEqual(43, reservation.tail.len);
    try std.testing.expect(std.mem.allEqual(u8, reservation.tail, 0x3c));
    destroy(allocator, reservation.value);
    try std.testing.expectEqual(17, fixed.end_index);
    try std.testing.expect(std.mem.allEqual(u8, prefix, 0x5a));
    try std.testing.expectEqual(0xa5, backing[0]);
    try std.testing.expectError(
        error.OutOfMemory,
        createWithTail(std.testing.failing_allocator, Value, std.math.maxInt(usize)),
    );
    try std.testing.expectError(
        error.OutOfMemory,
        createWithTail(std.testing.failing_allocator, Value, 1),
    );
}

test "workspaces preserve typed alignment and earlier bytes in bounded caller storage" {
    const Aligned = struct { value: u64 align(64) };
    const backing = try std.testing.allocator.alloc(u8, 1024 + 64);
    defer std.testing.allocator.free(backing);
    for (0..64) |offset| {
        var memory = std.heap.FixedBufferAllocator.init(backing[offset..][0..1024]);
        const allocator = memory.allocator();
        const prefix = try allocator.alloc(u8, 37);
        @memset(prefix, 0x5a);
        for ([_]usize{ 0, 1, 3 }) |count| {
            var workspace = try AlignedAllocation(Aligned).initPadded(allocator, count);
            try std.testing.expectEqual(count, workspace.samples.len);
            try std.testing.expectEqual(0, @intFromPtr(workspace.samples.ptr) % 64);
            for (workspace.samples, 0..) |*value, ordinal| value.value = ordinal + 1;
            for (
                workspace.samples,
                0..,
            ) |value, ordinal| try std.testing.expectEqual(ordinal + 1, value.value);
            workspace.deinit(allocator);
            try std.testing.expectEqual(prefix.len, memory.end_index);
            for (prefix) |byte| try std.testing.expectEqual(0x5a, byte);
        }
    }
}

test "workspace size overflow and allocation failure leave earlier bytes unchanged" {
    const backing = try std.testing.allocator.alloc(u8, 64);
    defer std.testing.allocator.free(backing);
    var memory = std.heap.FixedBufferAllocator.init(backing);
    const allocator = memory.allocator();
    const prefix = try allocator.alloc(u8, 37);
    @memset(prefix, 0x6b);
    try std.testing.expectError(
        error.SizeOverflow,
        AlignedAllocation(u64).initPadded(allocator, std.math.maxInt(usize)),
    );
    try std.testing.expectEqual(prefix.len, memory.end_index);
    try std.testing.expectError(
        error.OutOfMemory,
        AlignedAllocation(u64).initPadded(allocator, 64),
    );
    try std.testing.expectEqual(prefix.len, memory.end_index);
    for (prefix) |byte| try std.testing.expectEqual(0x6b, byte);
}
