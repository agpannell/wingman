//! Expand admitted LZ4 backward matches, including newly produced overlapping history. The caller
//! proves distance, destination extent and initialized source history before entering these
//! kernels.
const std = @import("std");
const builtin = @import("builtin");
const copy = @import("copy.zig");

pub fn expand(output: []u8, begin: usize, distance: usize, count: usize) void {
    if (distance == 1) {
        @memset(output[begin..][0..count], output[begin - 1]);
        return;
    }
    if (distance >= count) {
        // Common short nonoverlapping matches use exact bounded first/last copies. Both source
        // chunks are captured before their destinations are written.
        inline for (.{ 4, 8, 16, 32 }) |width| {
            if (count <= width * 2) {
                if (count >= width) {
                    const first = output[begin - distance ..][0..width].*;
                    const last = output[begin - distance + count - width ..][0..width].*;
                    @memcpy(output[begin..][0..width], &first);
                    @memcpy(output[begin + count - width ..][0..width], &last);
                } else {
                    @memcpy(output[begin..][0..count], output[begin - distance ..][0..count]);
                }
                return;
            }
        }
        @memcpy(output[begin..][0..count], output[begin - distance ..][0..count]);
        return;
    }
    if (distance <= 128 and count >= 4096) {
        // Long periodic matches can be expanded from a repeated motif in one large copy path.
        copyPeriodic(output, begin, distance, count);
        return;
    }
    // Seed one complete period, then repeatedly double the initialized prefix. LZ4's overlapping
    // semantics are preserved because every new chunk reads only bytes already produced.
    @memcpy(output[begin..][0..distance], output[begin - distance ..][0..distance]);
    var copied = distance;
    while (copied < count) {
        const next = @min(copied, count - copied);
        // The copied prefix already contains the complete distance-byte period.
        @memcpy(output[begin + copied ..][0..next], output[begin..][0..next]);
        copied += next;
    }
}

// Expand an overlapping match as a sequence of nonoverlapping copies. Moving the source forward
// after a large copy keeps each next source range initialized, while small distances grow the
// available prefix geometrically without reading bytes that the current copy is writing.
inline fn copyGeometric(output: []u8, begin: usize, distance: usize, count: usize) void {
    var destination = begin;
    var source = begin - distance;
    var remaining = count;
    while (remaining > destination - source) {
        const available = destination - source;
        copy.nonOverlapping(output[destination..][0..available], output[source..][0..available]);
        destination += available;
        remaining -= available;
        if (available >= 2048) source += available;
    }
    copy.nonOverlapping(output[destination..][0..remaining], output[source..][0..remaining]);
}

noinline fn copyPeriodic(output: []u8, begin: usize, distance: usize, count: usize) void {
    const wide_copy = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(
        builtin.cpu.features,
        .avx512f,
    );
    if (wide_copy) {
        // The native wide-copy path reuses a small motif that stays hot in cache.
        var motif: [2048]u8 = undefined;
        const width = distance * 16;
        @memcpy(motif[0..distance], output[begin - distance ..][0..distance]);
        var filled = distance;
        while (filled < width) {
            const next = @min(filled, width - filled);
            @memcpy(motif[filled..][0..next], motif[0..next]);
            filled += next;
        }
        var copied: usize = 0;
        while (count - copied >= width) : (copied += width) {
            @memcpy(output[begin + copied ..][0..width], motif[0..width]);
        }
        if (copied != count) {
            @memcpy(output[begin + copied ..][0 .. count - copied], motif[0 .. count - copied]);
        }
        return;
    }

    copyGeometric(output, begin, distance, count);
}
