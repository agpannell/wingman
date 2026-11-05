//! CRC-32C instructions operate on reflected, unfinalized remainders.
// Research reference for independent instruction chains and polynomial skip operators:
// https://github.com/google/crc32c/blob/89f69843a135108ff1fcc82660bb3d784f4f987a/src/crc32c_sse42.cc
// Skip tables here are derived from the reflected recurrence rather than imported constants.
const std = @import("std");
const builtin = @import("builtin");
const x86 = builtin.cpu.arch == .x86_64 and builtin.cpu.hasAll(.x86, &.{.crc32});
const arm = builtin.cpu.arch == .aarch64 and builtin.cpu.hasAll(.aarch64, &.{.crc});
pub const available = builtin.zig_backend == .stage2_llvm and (x86 or arm);
// Longer x86 blocks amortize joins; ARM keeps its previously qualified block schedule.
const block_sizes: []const usize = if (x86) &.{ 4096, 1024, 256 } else &.{256};

inline fn word(initial: u32, value: u64) u32 {
    if (x86) {
        return @truncate(asm ("crc32q %[value], %[crc]"
            : [crc] "=r" (-> u64),
            : [value] "r" (value),
              [initial] "0" (@as(u64, initial)),
        ));
    }
    return asm ("crc32cx %[out:w], %[crc:w], %[value]"
        : [out] "=r" (-> u32),
        : [crc] "r" (initial),
          [value] "r" (value),
    );
}

inline fn byte(initial: u32, value: u8) u32 {
    if (x86) {
        return asm ("crc32b %[value], %[crc]"
            : [crc] "=r" (-> u32),
            : [value] "r" (value),
              [initial] "0" (initial),
        );
    }
    return asm ("crc32cb %[out:w], %[crc:w], %[value:w]"
        : [out] "=r" (-> u32),
        : [crc] "r" (initial),
          [value] "r" (@as(u32, value)),
    );
}

fn applyMatrix(columns: [32]u32, input: u32) u32 {
    var remaining = input;
    var result: u32 = 0;
    var bit: usize = 0;
    while (remaining != 0) : (bit += 1) {
        if (remaining & 1 != 0) result ^= columns[bit];
        remaining >>= 1;
    }
    return result;
}

// Build the zero-byte advance map by squaring a one-byte map. Each table then contains the
// contribution of one register byte. This avoids evaluating every zero bit for every table entry.
fn makeSkipTable(comptime span: usize) [4][256]u32 {
    @setEvalBranchQuota(1000000);
    var columns: [32]u32 = undefined;
    var step: [32]u32 = undefined;
    for (&columns, &step, 0..) |*identity, *next, bit| {
        const basis = @as(u32, 1) << @intCast(bit);
        identity.* = basis;
        var value = basis;
        for (0..8) |_| {
            const carry = value & 1 != 0;
            value >>= 1;
            if (carry) value ^= 0x82f63b78;
        }
        next.* = value;
    }
    var length = span;
    while (length != 0) : (length >>= 1) {
        if (length & 1 != 0) {
            for (&columns) |*column| column.* = applyMatrix(step, column.*);
        }
        var squared: [32]u32 = undefined;
        for (&squared, step) |*column, previous| column.* = applyMatrix(step, previous);
        step = squared;
    }
    var result: [4][256]u32 = undefined;
    for (0..4) |position| {
        for (0..256) |value| {
            const contribution = @as(u32, @intCast(value)) << @intCast(8 * position);
            result[position][value] = applyMatrix(columns, contribution);
        }
    }
    return result;
}

fn advance(comptime span: usize, remainder: u32) u32 {
    const skip = comptime makeSkipTable(span);
    var result: u32 = 0;
    inline for (0..4) |position| {
        const index: u8 = @truncate(remainder >> (position * 8));
        result ^= skip[position][index];
    }
    return result;
}

/// Appends exact input to the raw register. Three chains overlap instruction latency for bulk
/// blocks; zero-initialized secondary chains contribute only their own input. Polynomial skips then
/// place each contribution at the same final position. Larger x86 spans amortize those joins, with
/// smaller spans covering the remainder. Short calls avoid parallel setup.
pub fn update(initial: u32, bytes: []const u8) u32 {
    if (x86) {
        // Keep small calls inlinable without duplicating the bulk hierarchy in every caller.
        const minimum_parallel_bytes = 3 * 256;
        if (bytes.len >= minimum_parallel_bytes) {
            return @call(.never_inline, updateBlocks, .{ initial, bytes });
        }
        return updateTail(initial, bytes);
    }
    return updateBlocks(initial, bytes);
}

fn updateBlocks(initial: u32, bytes: []const u8) u32 {
    var remainder = initial;
    var position: usize = 0;
    inline for (block_sizes) |span| {
        while (bytes.len - position >= 3 * span) : (position += 3 * span) {
            var first = remainder;
            var second: u32 = 0;
            var third: u32 = 0;
            var offset: usize = 0;
            while (offset < span) : (offset += 8) {
                first = word(
                    first,
                    std.mem.readInt(u64, bytes[position + offset ..][0..8], .little),
                );
                second = word(
                    second,
                    std.mem.readInt(u64, bytes[position + span + offset ..][0..8], .little),
                );
                third = word(
                    third,
                    std.mem.readInt(u64, bytes[position + 2 * span + offset ..][0..8], .little),
                );
            }
            remainder = advance(span, advance(span, first) ^ second) ^ third;
        }
    }
    return updateTail(remainder, bytes[position..]);
}

fn updateTail(initial: u32, bytes: []const u8) u32 {
    var remainder = initial;
    var position: usize = 0;
    while (bytes.len - position >= 8) : (position += 8) {
        remainder = word(remainder, std.mem.readInt(u64, bytes[position..][0..8], .little));
    }
    for (bytes[position..]) |value| remainder = byte(remainder, value);
    return remainder;
}

fn referenceUpdate(initial: u32, bytes: []const u8) u32 {
    var remainder = initial;
    for (bytes) |value| {
        remainder ^= value;
        for (0..8) |_| {
            const carry = remainder & 1 != 0;
            remainder >>= 1;
            if (carry) remainder ^= 0x82f63b78;
        }
    }
    return remainder;
}

test "CRC32C zero-byte maps match independent bit recurrence" {
    const testing = std.testing;
    const zeros: [4096]u8 = @splat(0);
    inline for (.{ 256, 1024, 4096 }) |span| {
        for (0..32) |bit| {
            const initial = @as(u32, 1) << @intCast(bit);
            try testing.expectEqual(
                referenceUpdate(initial, zeros[0..span]),
                advance(span, initial),
            );
        }
    }
}

test "CRC32C hierarchical blocks preserve raw states and exact boundaries" {
    if (!available) return error.SkipZigTest;
    var data: [65536 + 64]u8 = undefined;
    for (&data, 0..) |*value, index| value.* = @truncate((index * 179 + 13) ^ (index >> 5));
    const lengths = [_]usize{ 767, 768, 769, 3071, 3072, 3073, 12287, 12288, 12289, 65536 };
    for ([_]usize{ 0, 1, 7, 63 }) |offset| {
        for (lengths) |length| {
            const input = data[offset..][0..length];
            for (0..34) |state_index| {
                const initial: u32 = switch (state_index) {
                    0 => 0,
                    1 => 0xffffffff,
                    else => @as(u32, 1) << @intCast(state_index - 2),
                };
                const expected = referenceUpdate(initial, input);
                try std.testing.expectEqual(expected, update(initial, input));
                const split = length / 3 + 1;
                const prefix = update(initial, input[0..split]);
                try std.testing.expectEqual(expected, update(prefix, input[split..]));
            }
        }
    }
}

test "CRC32C hierarchical reads respect both protected boundaries" {
    if (!available or builtin.os.tag != .linux) return error.SkipZigTest;
    const page = std.heap.pageSize();
    const capacity = 16 * page;
    const mapping = try std.posix.mmap(
        null,
        capacity + 2 * page,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(mapping);
    const backing = mapping[page..][0..capacity];
    for (backing, 0..) |*value, index| value.* = @truncate((index *% 53 +% 11) ^ (index >> 4));
    for ([_]usize{ 0, page + capacity }) |offset| {
        const result = std.os.linux.mprotect(mapping.ptr + offset, page, .{});
        try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(result));
    }
    const read_only = std.os.linux.mprotect(backing.ptr, capacity, .{ .READ = true });
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(read_only));
    for ([_]usize{ 767, 768, 769, 3071, 3072, 3073, 12287, 12288, 12289, 65535 }) |length| {
        for ([_][]const u8{ backing[0..length], backing[capacity - length ..] }) |input| {
            try std.testing.expectEqual(
                referenceUpdate(0xffffffff, input),
                update(0xffffffff, input),
            );
        }
    }
}
