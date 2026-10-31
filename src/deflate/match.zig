//! Exact overlapping DEFLATE match copies and periodic history kernels.

const builtin = @import("builtin");
const std = @import("std");

/// Store width selected from the compile-time backend and CPU features.
pub const copy_bytes: usize = blk: {
    if (builtin.zig_backend != .stage2_llvm) break :blk 16;
    if (builtin.cpu.arch != .x86 and builtin.cpu.arch != .x86_64) break :blk 16;
    if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) break :blk 32;
    break :blk 16;
};

/// Copies a 3..258-byte match at distance >= 8 into a 298-byte destination reservation. Only
/// exact-size decoding may leave temporary bytes beyond an individual match. The margin covers five
/// eager eight-byte words and all later paired words. Sequential stores precede dependent history
/// reads. Success overwrites the complete supplied output; a final short stream fails before
/// publication.
pub fn copyExtendedWords(destination: []u8, source: []const u8, length: usize) void {
    std.debug.assert(destination.len >= 298 and length >= 3 and length <= 258);
    inline for (0..5) |word| destination[word * 8 ..][0..8].* = source[word * 8 ..][0..8].*;
    var offset: usize = 40;
    while (offset < length) : (offset += 16) {
        destination[offset..][0..8].* = source[offset..][0..8].*;
        destination[offset + 8 ..][0..8].* = source[offset + 8 ..][0..8].*;
    }
}

/// Restores a 3..258-byte match within output. The caller admits a nonzero distance into
/// initialized history and enough space for the exact match; no spare capacity is written.
pub fn copyMatch(output: []u8, position: usize, distance: usize, length: usize) void {
    const destination = output[position..][0..length];
    // Each word reads initialized history and stays inside the match. A head store precedes the
    // tail load, so an overlapping tail may read newly expanded bytes.
    if (length < 8) {
        const source = output[position - distance ..];
        std.debug.assert(length >= 3);
        if (distance >= 4 and length >= 4) {
            destination[0..4].* = source[0..4].*;
            destination[length - 4 ..][0..4].* = source[length - 4 ..][0..4].*;
            return;
        }
        var offset: usize = 0;
        if (distance >= 2) {
            destination[0..2].* = source[0..2].*;
            offset = 2;
        }
        while (offset < length) : (offset += 1) destination[offset] = source[offset];
        return;
    }

    // Shorter exact head/tail copies precede the long-match fallback. An eight-byte history span
    // separates word copies from short-period cases.
    if (distance >= 8) {
        const source = output[position - distance ..];
        if (length < 16) {
            destination[0..8].* = source[0..8].*;
            destination[length - 8 ..][0..8].* = source[length - 8 ..][0..8].*;
            return;
        }
        if (length <= 32 and distance >= 16) {
            // The head initializes any history needed by the overlapping tail. Both complete words
            // stay inside this 16..32-byte match.
            destination[0..16].* = source[0..16].*;
            destination[length - 16 ..][0..16].* = source[length - 16 ..][0..16].*;
            return;
        }
        if (length <= 64 and distance >= 32) {
            // Earlier cases handled shorter matches. The head also initializes any history needed
            // by the overlapping exact-width tail.
            destination[0..32].* = source[0..32].*;
            destination[length - 32 ..][0..32].* = source[length - 32 ..][0..32].*;
            return;
        }
        if (length <= 128 and distance >= 64) {
            // Earlier cases handled lengths <= 64. The head initializes every history byte the
            // overlapping tail can read, without overcopy.
            destination[0..64].* = source[0..64].*;
            destination[length - 64 ..][0..64].* = source[length - 64 ..][0..64].*;
            return;
        }
        if (distance >= 128) {
            // Earlier cases handled lengths <= 128. Each full word reads history before its
            // destination, including when distance is exactly 128.
            std.debug.assert(length <= 258);
            destination[0..128].* = source[0..128].*;
            if (length <= 256) {
                destination[length - 128 ..][0..128].* = source[length - 128 ..][0..128].*;
            } else {
                // Only the two maximum lengths remain. The second prefix precedes this exact tail's
                // history read, so distance-128 expansion is valid.
                destination[128..256].* = source[128..256].*;
                destination[length - 2 ..][0..2].* = source[length - 2 ..][0..2].*;
            }
            return;
        }
        @call(.always_inline, copyGrowingHistory, .{ destination, source, distance });
    } else if (distance == 1) {
        repeatWord(u8, destination, output[position - 1 ..][0..1]);
    } else if (distance == 2) {
        repeatWord(u16, destination, output[position - 2 ..][0..2]);
    } else if (distance == 4) {
        repeatWord(u32, destination, output[position - 4 ..][0..4]);
    } else {
        const source = output[position - distance ..];
        for (destination, 0..) |*byte, offset| byte.* = source[offset];
    }
}

// Each row rounds a copy width up to a whole number of history periods. The effective distance is
// >= width and < width+distance. Once width bytes are initialized, the source begins within the
// original history and ends before the current store; the period multiple preserves every output
// byte.
const growing_distances = blk: {
    var rows: [4][128]u8 = @splat(@splat(0));
    for (.{ 16, 32, 64, 128 }, 0..) |width, row| {
        for (1..128) |distance| {
            const periods = (width + distance - 1) / distance;
            rows[row][distance] = @intCast(periods * distance);
        }
    }
    break :blk rows;
};

// All callers supply an RFC 1951 match of at most 258 bytes. This bound makes one ascending pass
// and one descending tail sufficient for the complete match.
fn copyGrowingHistory(destination: []u8, source: []const u8, distance: usize) void {
    std.debug.assert(distance >= 8 and distance < 128 and destination.len >= 16);
    // Ordered eight-byte stores seed sixteen bytes even at distance eight.
    destination[0..8].* = source[0..8].*;
    destination[8..16].* = source[8..16].*;
    var offset: usize = 16;
    inline for (.{ 16, 32, 64, 128 }, 0..) |width, row| {
        if (destination.len - offset >= width) {
            const effective: usize = growing_distances[row][distance];
            const source_position = offset + distance - effective;
            destination[offset..][0..width].* = source[source_position..][0..width].*;
            offset += width;
        }
    }
    // The first declined width exceeds the remaining tail. Descending stores reuse the initialized
    // prefix; their effective distances stay period-aligned.
    inline for (.{ 64, 32, 16 }, .{ 2, 1, 0 }) |width, row| {
        if (destination.len - offset >= width) {
            const effective: usize = growing_distances[row][distance];
            const source_position = offset + distance - effective;
            destination[offset..][0..width].* = source[source_position..][0..width].*;
            offset += width;
        }
    }
    if (destination.len - offset >= 8) {
        destination[offset..][0..8].* = source[offset..][0..8].*;
        offset += 8;
    }
    if (offset < destination.len) {
        const tail = destination.len - 8;
        destination[tail..][0..8].* = source[tail..][0..8].*;
    }
}

/// Repeats initialized history at distance 3, 5, 6, 7 or 16. Destination holds at least copy_bytes
/// bytes. As in zlib-ng's chunk magazine, one phase-aligned pattern supplies exact bounded stores.
pub fn copyPeriodicBytes(destination: []u8, source: []const u8, distance: usize) void {
    switch (distance) {
        3 => @call(.always_inline, repeatPeriodic, .{ 3, destination, source[0..3] }),
        5 => @call(.always_inline, repeatPeriodic, .{ 5, destination, source[0..5] }),
        6 => @call(.always_inline, repeatPeriodic, .{ 6, destination, source[0..6] }),
        7 => @call(.always_inline, repeatPeriodic, .{ 7, destination, source[0..7] }),
        16 => @call(.always_inline, repeatPeriodic, .{ 16, destination, source[0..16] }),
        else => unreachable,
    }
}

/// Fills at least copy_bytes destination bytes from an initialized 1..32-byte period. The period
/// must fit the selected store width; no seed padding or output overcopy is needed.
pub fn repeatPeriodic(comptime period: usize, destination: []u8, seed: *const [period]u8) void {
    return @call(.always_inline, repeatPeriodicWithWidth, .{
        period, copy_bytes, destination, seed,
    });
}

/// Repeats initialized history at distance 8..32 through a destination of at least 64 bytes.
pub fn copyWindowPeriod(destination: []u8, source: []const u8, distance: usize) void {
    // Twenty-five constant periods each construct a bounded shuffle and tail.
    @setEvalBranchQuota(4096);
    std.debug.assert(destination.len >= 64 and distance >= 8 and distance <= 32);
    switch (distance) {
        inline 8...32 => |period| @call(
            .always_inline,
            repeatPeriodicWithWidth,
            .{ period, 32, destination, source[0..period] },
        ),
        else => unreachable,
    }
}

fn repeatPeriodicWithWidth(
    comptime period: usize,
    comptime width: usize,
    destination: []u8,
    seed: *const [period]u8,
) void {
    std.debug.assert(destination.len >= width);
    // Power-of-two backing gives the shuffle initialized lanes without reading beyond the actual
    // history period. Zero spare lanes; a power-of-two period fills its seed.
    const seed_width: usize = blk: {
        if (period <= 8) break :blk 8;
        if (period <= 16) break :blk 16;
        break :blk 32;
    };
    var seed_bytes: [seed_width]u8 = @splat(0);
    inline for (0..period) |index| seed_bytes[index] = seed[index];
    const seed_vector: @Vector(seed_width, u8) = seed_bytes;
    const indexes: @Vector(width, i32) = comptime blk: {
        var lanes: [width]i32 = undefined;
        for (0..width) |index| lanes[index] = @intCast(index % period);
        break :blk lanes;
    };
    const vector = @shuffle(u8, seed_vector, seed_vector, indexes);
    const pattern: [width]u8 = vector;
    // The largest whole-period step keeps each repeated store in the same phase. Its overlapping
    // suffix agrees with the following store; no overcopy occurs.
    const advance = width / period * period;
    var offset: usize = 0;
    while (destination.len - offset >= width) : (offset += advance) {
        // Keep the complete store vector-shaped; array assignment scalarizes non-power-of-two
        // patterns.
        const output: *align(1) @Vector(width, u8) = @ptrCast(destination[offset..].ptr);
        output.* = vector;
    }
    // Constant-width tail stores keep this leaf free of a variable memcpy call. The full-period
    // step leaves pattern phase zero at offset, and every store advances the corresponding pattern
    // prefix by the same exact width.
    var tail = destination[offset..];
    var phase: usize = 0;
    inline for (.{ 16, 8, 4, 2, 1 }) |bytes| {
        if (bytes < width and tail.len >= bytes) {
            tail[0..bytes].* = pattern[phase..][0..bytes].*;
            tail = tail[bytes..];
            phase += bytes;
        }
    }
}

// An overlapping one/two/four-byte period is uniform work. Load only initialized history through
// native unaligned words, then store native vector lanes. The paired loads/stores preserve its
// bytes on either endian without logical bitcast packing. Every store stays inside the declared
// match length.
inline fn repeatWord(comptime Word: type, destination: []u8, seed: *const [@sizeOf(Word)]u8) void {
    std.debug.assert(destination.len >= 8);
    const native_word = @as(*align(1) const Word, @ptrCast(seed)).*;
    var offset: usize = 0;
    while (destination.len - offset >= copy_bytes) : (offset += copy_bytes) {
        storeRepeatedWord(Word, copy_bytes, destination[offset..][0..copy_bytes], native_word);
    }
    if (copy_bytes > 16 and destination.len - offset >= 16) {
        storeRepeatedWord(Word, 16, destination[offset..][0..16], native_word);
        offset += 16;
    }
    if (destination.len - offset >= 8) {
        storeRepeatedWord(Word, 8, destination[offset..][0..8], native_word);
        offset += 8;
    }
    if (offset < destination.len) {
        // At least eight output bytes are admitted. Overlap the published prefix with an exact tail
        // word, rotating the repeated seed to the tail phase.
        const tail = destination.len - 8;
        const phase = tail & (@sizeOf(Word) - 1);
        const repeat_multiplier = std.math.maxInt(u64) / std.math.maxInt(Word);
        const word = @as(u64, std.mem.readInt(Word, seed, .little)) * repeat_multiplier;
        const tail_word = std.math.rotr(u64, word, phase * 8);
        std.mem.writeInt(u64, destination[tail..][0..8], tail_word, .little);
    }
}

inline fn storeRepeatedWord(
    comptime Word: type,
    comptime bytes: usize,
    destination: *[bytes]u8,
    word: Word,
) void {
    const Repeated = @Vector(bytes / @sizeOf(Word), Word);
    @as(*align(1) Repeated, @ptrCast(destination)).* = @splat(word);
}

test "match overlap and boundary copies preserve repeating history" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, 1024);
    defer allocator.free(bytes);
    for (0..33) |prefix| {
        for (1..260) |distance| {
            for (3..259) |length| {
                @memset(bytes, 0x5a);
                for (0..distance) |index| bytes[prefix + index] = @truncate(index * 31 + 7);
                const end = prefix + distance + length;
                copyMatch(bytes[0..end], prefix + distance, distance, length);
                for (0..length) |index| {
                    const expected: u8 = @truncate((index % distance) * 31 + 7);
                    try std.testing.expectEqual(expected, bytes[prefix + distance + index]);
                }
                for (0..distance) |index| {
                    const expected: u8 = @truncate(index * 31 + 7);
                    try std.testing.expectEqual(expected, bytes[prefix + index]);
                }
                for (bytes[0..prefix]) |byte| try std.testing.expectEqual(0x5a, byte);
                for (bytes[end..][0..16]) |byte| try std.testing.expectEqual(0x5a, byte);
            }
        }
    }
}

test "periodic block chunks preserve every admitted alignment length and guard" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, 512);
    defer allocator.free(bytes);
    for (0..33) |prefix| {
        for ([_]usize{ 3, 5, 6, 7, 16 }) |period| {
            for (copy_bytes..259) |length| {
                @memset(bytes, 0x5a);
                for (0..period) |index| bytes[prefix + index] = @truncate(index * 31 + 7);
                const end = prefix + period + length;
                copyPeriodicBytes(bytes[prefix + period .. end], bytes[prefix..end], period);
                for (0..length) |index| {
                    const expected: u8 = @truncate((index % period) * 31 + 7);
                    try std.testing.expectEqual(expected, bytes[prefix + period + index]);
                }
                for (0..period) |index| {
                    const expected: u8 = @truncate(index * 31 + 7);
                    try std.testing.expectEqual(expected, bytes[prefix + index]);
                }
                for (bytes[0..prefix]) |byte| try std.testing.expectEqual(0x5a, byte);
                for (bytes[end..]) |byte| try std.testing.expectEqual(0x5a, byte);
            }
        }
    }
}

test "window-period copies reuse initialized seeds across all distances phases and exact guards" {
    const allocator = std.testing.allocator;
    const backing = try allocator.alloc(u8, 512);
    defer allocator.free(backing);
    for (0..33) |alignment| {
        for (8..33) |period| {
            for (64..259) |length| {
                @memset(backing, 0xa5);
                for (0..period) |index| backing[alignment + index] = @truncate(index * 31 + 7);
                const start = alignment + period;
                const end = start + length;
                copyWindowPeriod(backing[start..end], backing[alignment..end], period);
                for (0..length) |index| {
                    const expected: u8 = @truncate(index % period * 31 + 7);
                    try std.testing.expectEqual(expected, backing[start + index]);
                }
                for (0..period) |index| {
                    const expected: u8 = @truncate(index * 31 + 7);
                    try std.testing.expectEqual(expected, backing[alignment + index]);
                }
                for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xa5, byte);
                for (backing[end..]) |byte| try std.testing.expectEqual(0xa5, byte);
            }
        }
    }
}

test "extended words read dependent history in order and respect supplied bounds" {
    const allocator = std.testing.allocator;
    const capacity = 298;
    const backing = try allocator.alloc(u8, 64 + 33 + capacity + 32);
    defer allocator.free(backing);
    const expected = try allocator.alloc(u8, backing.len);
    defer allocator.free(expected);
    // Independent byte-at-a-time LZ expansion checks actual match bytes. The supplied 298-byte
    // destination is followed immediately by 32 guard bytes.
    for (8..65) |distance| {
        for (3..259) |length| {
            for (0..33) |alignment| {
                const start = distance + alignment;
                @memset(backing, 0xa5);
                for (backing[0..start], 0..) |*byte, i| byte.* = @truncate(i * 37 + 11);
                @memcpy(expected, backing);
                for (0..length) |i| expected[start + i] = expected[start - distance + i];
                copyExtendedWords(
                    backing[start..][0..capacity],
                    backing[start - distance ..],
                    length,
                );
                try std.testing.expectEqualSlices(
                    u8,
                    expected[0 .. start + length],
                    backing[0 .. start + length],
                );
                for (backing[start + capacity ..]) |byte| try std.testing.expectEqual(0xa5, byte);
            }
        }
    }
    const distant = try allocator.alloc(u8, 32768 + capacity + 32);
    defer allocator.free(distant);
    const distant_expected = try allocator.alloc(u8, distant.len);
    defer allocator.free(distant_expected);
    for ([_]usize{ 32767, 32768 }) |distance| {
        @memset(distant, 0xa5);
        for (distant[0..distance], 0..) |*byte, i| byte.* = @truncate(i * 37 + 11);
        @memcpy(distant_expected, distant);
        for (0..258) |i| distant_expected[distance + i] = distant_expected[i];
        copyExtendedWords(distant[distance..][0..capacity], distant, 258);
        try std.testing.expectEqualSlices(
            u8,
            distant_expected[0 .. distance + 258],
            distant[0 .. distance + 258],
        );
        for (distant[distance + capacity ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}
