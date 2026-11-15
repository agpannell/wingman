//! Complete raw-block recovery and admitted sequence kernels. Decoded history is borrowed;
//! streaming workers supply a read-only ring view without coupling these kernels to their state.
const std = @import("std");
const byte_ranges = @import("../common/byte_ranges.zig");
const overlaps = byte_ranges.overlapsChecked;
const builtin = @import("builtin");
const maximum_distance = @import("block.zig").maximum_distance;
const match_copy = @import("match_copy.zig");
const copyMatch = match_copy.expand;
const TestWriter = @import("BlockWriter.zig"); // Inline match/guard fixtures only.
const test_fixtures = @import("block_fixtures.zig");
const test_encoding = @import("greedy_encode.zig"); // Inline round-trip fixtures only.
pub const Limits = @import("BlockDecodeLimits.zig");
const OutputSize = @import("../lz4.zig").OutputSize;

/// Complete raw-block format, storage or admission failure; no accepted result is returned.
pub const Error = error{
    Truncated,
    OutputTooSmall,
    OutputSizeMismatch,
    InvalidOffset,
    InvalidTermination,
    SizeOverflow,
    Aliasing,
    LimitExceeded,
};

/// A borrowed snapshot of the streaming ring before a sequence batch. Pending output is supplied
/// separately; only the caller updates the ring after the batch.
pub const RingHistory = struct {
    /// Borrowed ring backing. Only its available-byte suffix before write_position may be read;
    /// bytes from the current batch live in its separate output span.
    history: *const [65536]u8,
    /// Next-write index in history, in the range 0..65536.
    write_position: usize,
    /// Reachable initialized suffix length, in bytes, capped at the 65,535-byte match distance.
    available: usize,
};

/// Two chronological, borrowed history spans. Only their last 65,535 bytes can be referenced. Empty
/// spans represent an independent block. This permits a dictionary followed by already decoded
/// linked blocks without concatenating them. Both spans must remain immutable during the call.
pub const History = struct {
    /// Earlier retained bytes; discarded first when the combined history exceeds the window.
    older: []const u8 = &.{},
    /// Later retained bytes, immediately following older in decoded order.
    newer: []const u8 = &.{},

    fn trimmed(self: History) History {
        const newer = historySuffix(self.newer);
        const older_count = @min(self.older.len, maximum_distance - newer.len);
        const older = self.older[self.older.len - older_count ..];
        return .{ .older = older, .newer = newer };
    }
};

/// Complete-block counts. Source length supplies the block boundary; consumed equals source.len.
pub const Result = struct {
    /// Encoded bytes validated; equals the complete source length.
    consumed: usize,
    /// Restored bytes in the used output prefix.
    produced: usize,
};

/// Complete-block policy. Empty history spans select an independent block; only their reachable
/// suffixes must be disjoint from destination. Source and history may overlap each other.
pub const Options = struct {
    /// Borrowed bytes preceding this block in decoded order.
    history: History = .{},
    /// Require the complete destination extent or return the used prefix.
    output_size: OutputSize = .exact,
    /// Encoded-byte, restored-byte and combined-work ceilings for this call.
    limits: Limits = .{},
};

/// Decodes one complete raw block. Exact output is the default; bounded output reports its used
/// prefix. Optional two-span history and per-call byte admission are independent. Complete input
/// and disjointness are required; trailing encoded bytes cannot bypass parsing. Returns copied
/// counts. Failure may change output, but never writes outside it or mutates source.
///
/// The doctest's helper checks an application-selected decoded-byte cap before allocating exact
/// output. Failure frees unpublished output; success transfers the complete allocation to the
/// caller. Source can then retire. The enclosing record still supplies its integrity policy before
/// publication.
pub fn into(source: []const u8, output: []u8, options: Options) Error!Result {
    const history = options.history.trimmed();
    if (try overlaps(source, output)) return error.Aliasing;
    if (try overlaps(history.older, output)) return error.Aliasing;
    if (try overlaps(history.newer, output)) return error.Aliasing;
    const limits = options.limits;
    if (source.len > limits.input_bytes or source.len > limits.work_units)
        return error.LimitExceeded;
    const remaining_work = limits.work_units - source.len;
    const output_budget = @min(output.len, limits.output_bytes);
    const admitted_output_bytes = @min(output_budget, remaining_work);
    const capacity: usize = @intCast(admitted_output_bytes);
    if (options.output_size == .exact and capacity < output.len) return error.LimitExceeded;
    const has_history = options.history.older.len != 0 or options.history.newer.len != 0;
    const use_independent_exact_kernel = options.output_size == .exact and !has_history;
    const produced = if (use_independent_exact_kernel) blk: {
        try decodeIndependentExact(source, output);
        break :blk output.len;
    } else blk: {
        // A bounded block with no external history has the same history as a zero-length prefix.
        // The smaller parser helps generic x86 without changing wide-target code.
        const use_prefix = if (comptime builtin.cpu.arch == .x86_64 and !std.Target.x86
            .featureSetHas(
            builtin.cpu.features,
            .avx2,
        )) !has_history else false;
        const decoded = if (use_prefix) decodeBounded(
            true,
            source,
            output[0..capacity],
            .{},
            0,
        ) else decodeBounded(false, source, output[0..capacity], options.history, 0);
        break :blk decoded;
    } catch |err| switch (err) {
        error.OutputTooSmall,
        => if (capacity < output.len) return error.LimitExceeded else return err,
        else => return err,
    };
    if (options.output_size == .exact and produced != output.len) return error.OutputSizeMismatch;
    return .{ .consumed = source.len, .produced = produced };
}

// Exact independent decoding has no external-history work or caller-visible spare output. Keep its
// fast sequence path separate so it can use the complete output extent while the checked loop still
// validates every extension, offset and final-literal rule.
fn decodeIndependentExact(source: []const u8, output: []u8) Error!void {
    if (try overlaps(source, output)) return error.Aliasing;

    var input_cursor: usize = 0;
    var output_cursor: usize = 0;
    var last_match: ?usize = null;
    while (true) {
        var sequence_start: usize = 0;
        if (fastExactSequence(source, output, &input_cursor, &output_cursor, &sequence_start)) {
            last_match = sequence_start;
            continue;
        }
        if (input_cursor == source.len) return error.Truncated;
        const token = source[input_cursor];
        input_cursor += 1;

        const literals = try length(source, &input_cursor, token >> 4);
        if (literals > source.len - input_cursor) return error.Truncated;
        if (literals > output.len - output_cursor) return error.OutputTooSmall;
        if (literals != 0) @memcpy(
            output[output_cursor..][0..literals],
            source[input_cursor..][0..literals],
        );
        input_cursor += literals;
        output_cursor += literals;

        if (input_cursor == source.len) {
            if (output_cursor != output.len) return error.OutputSizeMismatch;
            if (last_match) |start| {
                if (literals < 5 or output.len - start < 12) return error.InvalidTermination;
            }
            return;
        }

        if (source.len - input_cursor < 2) return error.Truncated;
        const distance = std.mem.readInt(u16, source[input_cursor..][0..2], .little);
        input_cursor += 2;
        if (distance == 0 or distance > output_cursor) return error.InvalidOffset;
        const match_field = try length(source, &input_cursor, token & 15);
        const match = std.math.add(usize, match_field, 4) catch return error.SizeOverflow;
        if (match > output.len - output_cursor) return error.OutputTooSmall;
        last_match = output_cursor;
        @call(.always_inline, copyMatch, .{ output, output_cursor, distance, match });
        output_cursor += match;
    }
}

/// Decodes a complete bounded block into the suffix of a frame's contiguous output. The prefix is
/// already produced and may be referenced by matches; only the suffix is written.
pub noinline fn intoWithPrefix(source: []const u8, output: []u8, prefix_len: usize) Error!Result {
    if (prefix_len > output.len) return error.OutputTooSmall;
    const end = try decodeBounded(true, source, output, .{}, prefix_len);
    return .{ .consumed = source.len, .produced = end - prefix_len };
}

/// Decodes a complete block into bounded output. External history may overlap the source, but not
/// output; a contiguous prefix is already in output. Success leaves spare output untouched.
fn decodeBounded(
    comptime contiguous_prefix: bool,
    source: []const u8,
    output: []u8,
    history: History,
    prefix_len: usize,
) Error!usize {
    const view = if (contiguous_prefix) History{} else history.trimmed();
    if (try overlaps(source, output)) return error.Aliasing;
    if (try overlaps(view.older, output) or try overlaps(view.newer, output)) return error.Aliasing;

    var read: usize = 0;
    var written: usize = prefix_len;
    var last_match: ?usize = null;
    while (true) {
        // The 32-byte margins admit short literals, the offset and fixed copies. A miss falls
        // through to the bulk or checked path at the same cursors.
        fast: {
            if (source.len - read < 32 or output.len - written < 32) break :fast;
            const token = source[read];
            const literals = token >> 4;
            const match_field = token & 15;
            if (literals == 15) break :fast;
            const literal_position = read + 1;
            const begin = written + literals;
            const offset_position = literal_position + literals;
            const distance = std.mem.readInt(u16, source[offset_position..][0..2], .little);
            if (match_field == 15) {
                if (distance < 32 or distance > begin) break :fast;
                const extension = source[offset_position + 2];
                const maximum_extension: u8 = if (contiguous_prefix) 45 else 13;
                if (extension > maximum_extension) break :fast;
                const match: usize = 19 + extension;
                const cursor = offset_position + 3;
                if (contiguous_prefix and (output.len - written < 64 or distance < 64 or output
                    .len - begin < 64 or source.len - cursor < 66)) break :fast;
                const from = begin - distance;
                if (comptime contiguous_prefix) {
                    // The remaining 66 encoded bytes guarantee that a valid suffix will produce at
                    // least 64 bytes. The 64-byte copy stays within output and its speculative tail
                    // is replaced before a successful bounded result is returned.
                    if (literals != 0) @memcpy(
                        output[written..][0..literals],
                        source[literal_position..][0..literals],
                    );
                    if (match <= 32) {
                        @memcpy(output[begin..][0..32], output[from..][0..32]);
                    } else {
                        @memcpy(output[begin..][0..64], output[from..][0..64]);
                    }
                } else {
                    // Capture both stripes before either overlapping store.
                    @memcpy(output[written..][0..16], source[literal_position..][0..16]);
                    const first = output[from..][0..16].*;
                    const last = output[from + match - 16 ..][0..16].*;
                    @memcpy(output[begin..][0..16], &first);
                    @memcpy(output[begin + match - 16 ..][0..16], &last);
                }
                read = cursor;
                written = begin + match;
                last_match = begin;
                continue;
            }
            if (distance < 8 or distance > begin) break :fast;

            const match: usize = match_field + @as(usize, 4);
            @memcpy(output[written..][0..16], source[literal_position..][0..16]);
            const from = begin - distance;

            // The fixed copies are disjoint only at the admitted distances.
            if (match <= 8) {
                @memcpy(output[begin..][0..8], output[from..][0..8]);
            } else if (match <= 16 and distance >= 16) {
                @memcpy(output[begin..][0..16], output[from..][0..16]);
            } else if (distance >= 18) {
                @memcpy(output[begin..][0..18], output[from..][0..18]);
            } else {
                @memcpy(output[begin..][0..8], output[from..][0..8]);
                @memcpy(output[begin + 8 ..][0..8], output[from + 8 ..][0..8]);
                @memcpy(output[begin + 16 ..][0..2], output[from + 16 ..][0..2]);
            }
            read = offset_position + 2;
            written = begin + match;
            last_match = begin;
            continue;
        }
        // The bulk path handles longer sequences; the checked path handles the remaining boundaries
        // and reports malformed input precisely.
        var sequence_start: usize = 0;
        const decoded = if (contiguous_prefix) false else @call(
            .always_inline,
            bulkSequence,
            .{ false, source, output, &read, &written, &sequence_start, null, 0 },
        );
        if (decoded) {
            last_match = sequence_start;
            continue;
        }
        if (read == source.len) return error.Truncated;
        const token = source[read];
        read += 1;

        const literals = try length(source, &read, token >> 4);
        if (literals > source.len - read) return error.Truncated;
        if (literals > output.len - written) return error.OutputTooSmall;
        @memcpy(output[written..][0..literals], source[read..][0..literals]);
        read += literals;
        written += literals;

        if (read == source.len) {
            if (last_match) |start| {
                if (literals < 5 or written - start < 12) return error.InvalidTermination;
            }
            return written;
        }

        if (source.len - read < 2) return error.Truncated;
        const distance = std.mem.readInt(u16, source[read..][0..2], .little);
        read += 2;
        // Include decoded bytes and both borrowed history spans when validating the offset.
        const external_history = view.older.len + view.newer.len;
        const available_history = written +| external_history;
        if (distance == 0 or distance > available_history) return error.InvalidOffset;

        const match_field = try length(source, &read, token & 15);
        const match = std.math.add(usize, match_field, 4) catch return error.SizeOverflow;
        if (match > output.len - written) return error.OutputTooSmall;
        last_match = written;

        var remaining = match;
        if (!contiguous_prefix and distance > written) {
            // The match begins before this output block. Copy the part available from the older and
            // newer external spans, then let copyMatch handle any overlap into this block.
            const external = distance - written;
            const count = @min(remaining, external);
            const newer_count = view.newer.len;
            if (external > newer_count) {
                const older_count = @min(count, external - newer_count);
                const older_start = view.older.len - (external - newer_count);
                @memcpy(
                    output[written..][0..older_count],
                    view.older[older_start..][0..older_count],
                );
                written += older_count;
                remaining -= older_count;
            }
            const newer_bytes = @min(remaining, distance - written);
            if (newer_bytes != 0) {
                const newer_start = view.newer.len - (distance - written);
                @memcpy(
                    output[written..][0..newer_bytes],
                    view.newer[newer_start..][0..newer_bytes],
                );
                written += newer_bytes;
                remaining -= newer_bytes;
            }
        }
        if (remaining != 0) {
            @call(.always_inline, copyMatch, .{ output, written, distance, remaining });
            written += remaining;
        }
    }
}

fn length(source: []const u8, cursor: *usize, nibble: u8) Error!usize {
    var result: usize = nibble;
    if (nibble == 15) {
        while (true) {
            if (cursor.* == source.len) return error.Truncated;
            const byte = source[cursor.*];
            cursor.* += 1;
            result = std.math.add(usize, result, byte) catch return error.SizeOverflow;
            if (byte != 255) break;
        }
    }
    return result;
}

// A complete block with an exact output extent can admit a short sequence before reading its
// fields. The 17-byte input and 32-byte output margins cover the token, up to 14 literals, offset,
// and speculative copies. The checked loop validates the final suffix or malformed input.
fn fastExactSequence(
    source: []const u8,
    output: []u8,
    read: *usize,
    written: *usize,
    last_match: *usize,
) bool {
    if (source.len - read.* < 17 or output.len - written.* < 32) return false;
    const token = source[read.*];
    const literals = token >> 4;
    const match_field = token & 15;
    if (literals == 15 or match_field == 15) return false;

    const literal_position = read.* + 1;
    const begin = written.* + literals;
    const distance = std.mem.readInt(u16, source[literal_position + literals ..][0..2], .little);
    if (distance < 8 or distance > begin) return false;
    const match = match_field + @as(usize, 4);
    @memcpy(output[written.*..][0..16], source[literal_position..][0..16]);

    const from = begin - distance;
    if (match <= 8) {
        @memcpy(output[begin..][0..8], output[from..][0..8]);
    } else if (match <= 16 and distance >= 16) {
        @memcpy(output[begin..][0..16], output[from..][0..16]);
    } else if (distance >= 18) {
        @memcpy(output[begin..][0..18], output[from..][0..18]);
    } else {
        @memcpy(output[begin..][0..8], output[from..][0..8]);
        @memcpy(output[begin + 8 ..][0..8], output[from + 8 ..][0..8]);
        @memcpy(output[begin + 16 ..][0..2], output[from + 16 ..][0..2]);
    }
    read.* = literal_position + literals + 2;
    written.* = begin + match;
    last_match.* = begin;
    return true;
}

// Bounded blocks admit only short sequences here. The streaming ring variant also admits complete
// extended sequences inside the supplied spans; incomplete fields and backpressure fall back
// without advancing any cursor. Loads/stores stay inside the sequence and unused output remains
// untouched.
pub fn bulkSequence(
    comptime with_ring: bool,
    source: []const u8,
    output: []u8,
    read: *usize,
    written: *usize,
    last_match: *usize,
    ring: ?RingHistory,
    prior_output: usize,
) bool {
    if (read.* == source.len) return false;
    const token = source[read.*];
    var literals: usize = token >> 4;
    var match: usize = (token & 15) + @as(usize, 4);
    if (!with_ring) {
        if (literals == 15 or (token & 15) == 15) return false;
        if (source.len - read.* < 17 or output.len - written.* < 32) return false;
    }
    var cursor = read.* + 1;
    if (with_ring and literals == 15) {
        literals = peekLength(source, &cursor, literals) orelse return false;
    }
    // In the independent path, the 17-byte input and 32-byte output margins above already cover the
    // largest short sequence: one token, fourteen literals, two offset bytes, and at most fourteen
    // literals plus eighteen match bytes. Streaming extensions still need exact checks.
    if (with_ring and (literals > source.len - cursor or literals > output.len - written.*))
        return false;
    const literal_position = cursor;
    cursor += literals;
    if (with_ring and source.len - cursor < 2) return false;
    const begin = written.* + literals;
    const distance = std.mem.readInt(u16, source[cursor..][0..2], .little);
    cursor += 2;
    if (with_ring and match == 19) match = peekLength(source, &cursor, match) orelse return false;
    if (with_ring and match > output.len - begin) return false;
    if (distance == 0) return false;
    if (distance > begin) {
        if (!with_ring) return false;
        if (prior_output + distance - begin > ring.?.available) return false;
    }
    if (with_ring and literals > 32) {
        @memcpy(output[written.*..][0..literals], source[literal_position..][0..literals]);
    } else if (literals != 0) {
        copySmall(output[written.*..], source[literal_position..], literals);
    }
    var copied: usize = 0;
    if (with_ring and distance > begin) {
        const state = ring.?;
        // The ring already contains prior_output bytes from this output fragment. Pending sequences
        // live only in output until the batch ends.
        const ring_distance = prior_output + distance - begin;
        const position = (state.write_position + 65536 - ring_distance) & 65535;
        copied = @min(match, distance - begin);
        const first = @min(copied, 65536 - position);
        @memcpy(output[begin..][0..first], state.history[position..][0..first]);
        @memcpy(output[begin + first ..][0 .. copied - first], state.history[0 .. copied - first]);
    }
    if (copied != match) {
        const next = begin + copied;
        const remaining = match - copied;
        if (distance >= remaining and remaining <= 32) {
            copySmall(output[next..], output[next - distance ..], remaining);
        } else {
            @call(.always_inline, copyMatch, .{ output, next, distance, remaining });
        }
    }
    read.* = cursor;
    written.* = begin + match;
    last_match.* = begin;
    return true;
}

// Inspect a complete extension field using a private cursor. On exhaustion or target-size overflow,
// the checked resumable path owns progress and errors.
inline fn peekLength(source: []const u8, cursor: *usize, initial: usize) ?usize {
    var count = initial;
    while (cursor.* != source.len) {
        const byte = source[cursor.*];
        cursor.* += 1;
        count = std.math.add(usize, count, byte) catch return null;
        if (byte != 255) return count;
    }
    return null;
}

inline fn copySmall(output: []u8, source: []const u8, count: usize) void {
    inline for (.{ 16, 8, 4, 2 }) |width| {
        if (count >= width) {
            const first = source[0..width].*;
            const last = source[count - width ..][0..width].*;
            @memcpy(output[0..width], &first);
            @memcpy(output[count - width ..][0..width], &last);
            return;
        }
    }
    if (count != 0) output[0] = source[0];
}

test into {
    const Example = struct {
        fn recoverBlock(
            allocator: std.mem.Allocator,
            source: []const u8,
            decoded_size: usize,
            maximum_decoded_bytes: usize,
        ) ![]u8 {
            if (decoded_size > maximum_decoded_bytes) return error.DecodedSizeLimit;
            const output = try allocator.alloc(u8, decoded_size);
            errdefer allocator.free(output);
            _ = try into(source, output, .{});
            return output;
        }
    };

    const allocator = std.testing.allocator;
    // One literal-only raw block containing "hello".
    const source = [_]u8{ 0x50, 0x68, 0x65, 0x6c, 0x6c, 0x6f };
    const output = try Example.recoverBlock(allocator, &source, 5, 64);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("hello", output);

    try std.testing.expectError(
        error.DecodedSizeLimit,
        Example.recoverBlock(allocator, &source, 5, 4),
    );
    try std.testing.expectError(
        error.Truncated,
        Example.recoverBlock(allocator, source[0..1], 5, 64),
    );
}

test "LZ4 bounded extended short match copies exact output" {
    for ([_]u8{ 0, 4 }) |second_literals| {
        for ([_]u8{ 0, 13, 14 }) |extension| {
            var wire: [74]u8 = undefined;
            var cursor: usize = 0;
            wire[cursor] = 0xf0;
            cursor += 1;
            wire[cursor] = 17; // Thirty-two initial literals.
            cursor += 1;
            for (0..32) |index| wire[cursor + index] = @intCast('A' + index % 26);
            cursor += 32;
            wire[cursor] = 32;
            wire[cursor + 1] = 0;
            cursor += 2;
            wire[cursor] = (second_literals << 4) | 0x0f;
            cursor += 1;
            @memcpy(wire[cursor..][0..second_literals], "qrst"[0..second_literals]);
            cursor += second_literals;
            wire[cursor] = 32;
            wire[cursor + 1] = 0;
            wire[cursor + 2] = extension;
            cursor += 3;
            wire[cursor] = 0xf0;
            wire[cursor + 1] = 13; // Twenty-eight final literals.
            cursor += 2;
            @memset(wire[cursor..][0..28], 'Z');
            cursor += 28;
            try std.testing.expectEqual(@as(usize, 70) + second_literals, cursor);

            var output: [108]u8 = @splat(0xa5);
            const decoded = try into(wire[0..cursor], &output, .{ .output_size = .bounded });
            const match_length: usize = 19 + extension;
            const begin: usize = 36 + second_literals;
            const produced = begin + match_length + 28;
            try std.testing.expectEqual(produced, decoded.produced);
            try std.testing.expectEqualSlices(u8, wire[2..34], output[0..32]);
            try std.testing.expectEqualSlices(u8, wire[2..6], output[32..36]);
            try std.testing.expectEqualSlices(u8, "qrst"[0..second_literals], output[36..begin]);
            try std.testing.expectEqualSlices(
                u8,
                output[begin - 32 .. begin - 32 + match_length],
                output[begin .. begin + match_length],
            );
            for (output[begin + match_length .. produced]) |byte| {
                try std.testing.expectEqual(@as(u8, 'Z'), byte);
            }
            for (output[produced..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        }
    }
}

test "LZ4 prefix wild match leaves successful spare output untouched" {
    for ([_]usize{ 0, 4 }) |literals| {
        for ([_]usize{ 19, 32, 33, 64 }) |match| {
            for ([_]usize{ 63, 64, 65 }) |final_literals| {
                var wire: [75]u8 = undefined;
                var cursor: usize = 0;
                wire[cursor] = (@as(u8, @intCast(literals)) << 4) | 0x0f;
                cursor += 1;
                @memcpy(wire[cursor..][0..literals], "qrst"[0..literals]);
                cursor += literals;
                wire[cursor] = 64;
                wire[cursor + 1] = 0;
                wire[cursor + 2] = @intCast(match - 19);
                cursor += 3;
                wire[cursor] = 0xf0;
                wire[cursor + 1] = @intCast(final_literals - 15);
                cursor += 2;
                @memset(wire[cursor..][0..final_literals], 'Z');
                cursor += final_literals;

                var expected: [224]u8 = @splat(0xa5);
                var actual: [224]u8 = @splat(0xa5);
                for (expected[0..64], 0..) |*byte, index| byte.* = @intCast('A' + index % 26);
                @memcpy(actual[0..64], expected[0..64]);
                @memcpy(expected[64..][0..literals], "qrst"[0..literals]);
                const begin = 64 + literals;
                for (0..match) |index| expected[begin + index] = expected[begin + index - 64];
                @memset(expected[begin + match ..][0..final_literals], 'Z');
                const result = try intoWithPrefix(wire[0..cursor], &actual, 64);
                try std.testing.expectEqual(literals + match + final_literals, result.produced);
                try std.testing.expectEqualSlices(u8, &expected, &actual);
            }
        }
    }
}

test "LZ4 independent bulk admission respects exact input and output margins" {
    // The short-sequence kernel may consume all seventeen input bytes and write exactly thirty-two
    // output bytes before rejecting the absent final literals. No byte beyond output is writable.
    var wire: [17]u8 = undefined;
    // Fourteen literals, then an eighteen-byte distance-one match.
    wire[0] = 0xee;
    @memset(wire[1..15], 'a');
    wire[15] = 1;
    wire[16] = 0;
    var output: [33]u8 = @splat(0xa5);
    try std.testing.expectError(error.Truncated, into(&wire, output[0..32], .{}));
    try std.testing.expectEqual(@as(u8, 0xa5), output[32]);

    @memset(&output, 0xa5);
    try std.testing.expectError(error.OutputTooSmall, into(&wire, output[0..31], .{}));
    try std.testing.expectEqual(@as(u8, 0xa5), output[31]);

    @memset(&output, 0xa5);
    try std.testing.expectError(error.Truncated, into(wire[0..16], output[0..32], .{}));
    try std.testing.expectEqual(@as(u8, 0xa5), output[32]);

    const chained = [_]u8{
        0x9e, '1', '2', '3', '4', '5', '6', '7', '8', '9', 8, 0, 0x50, 'T', 'A', 'I', 'L', '!',
    };
    @memset(&output, 0xa5);
    const result = try into(&chained, output[0..32], .{});
    try std.testing.expectEqual(@as(usize, 32), result.produced);
    try std.testing.expectEqualStrings("123456789234567892345678923TAIL!", output[0..32]);
    try std.testing.expectEqual(@as(u8, 0xa5), output[32]);
}

test "LZ4 bounded short copies leave the unused output tail untouched" {
    const wire = [_]u8{
        0xe0, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 8, 0, 0xe0, 'A',
        'B',  'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N',
    };
    var output: [48]u8 = @splat(0xa5);
    const result = try into(&wire, &output, .{ .output_size = .bounded });
    try std.testing.expectEqual(@as(usize, 32), result.produced);
    try std.testing.expectEqualStrings("abcdefghijklmnghijABCDEFGHIJKLMN", output[0..32]);
    for (output[32..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}

test "LZ4 contiguous prefix decoding matches external history and guards spare output" {
    var wire: [60]u8 = undefined;
    var cursor: usize = 0;
    for (0..3) |_| {
        wire[cursor] = 0xe0;
        cursor += 1;
        @memcpy(wire[cursor..][0..14], "abcdefghijklmn");
        cursor += 14;
        wire[cursor] = 32;
        wire[cursor + 1] = 0;
        cursor += 2;
    }
    wire[cursor] = 0x80;
    cursor += 1;
    @memcpy(wire[cursor..][0..8], "TAIL!!!!");
    cursor += 8;
    try std.testing.expectEqual(wire.len, cursor);

    var expected: [100]u8 = @splat(0xa5);
    var actual: [100]u8 = @splat(0xa5);
    for (expected[0..32], 0..) |*byte, i| byte.* = @intCast('A' + i % 26);
    @memcpy(actual[0..32], expected[0..32]);
    const ordinary = try into(
        &wire,
        expected[32..94],
        .{ .history = .{ .newer = expected[0..32] }, .output_size = .bounded },
    );
    const contiguous = try intoWithPrefix(&wire, actual[0..94], 32);
    try std.testing.expectEqual(@as(usize, 62), ordinary.produced);
    try std.testing.expectEqual(ordinary.produced, contiguous.produced);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "LZ4 dictionary views cross both spans and grow overlapping matches" {
    // Field-level oracle: match distance seven, match length nineteen, followed by five literals.
    // It must start in older, cross newer, then copy output.
    const block = [_]u8{ 0x0f, 0x07, 0x00, 0x00, 0x50, 'T', 'A', 'I', 'L', '!' };
    var output: [40]u8 = @splat(0xa7);
    const count = (try into(
        &block,
        &output,
        .{ .history = .{ .older = "ignore:ABCD", .newer = "EFG" }, .output_size = .bounded },
    )).produced;
    try std.testing.expectEqual(24, count);
    try std.testing.expectEqualStrings("ABCDEFGABCDEFGABCDETAIL!", output[0..count]);
    try std.testing.expect(std.mem.allEqual(u8, output[count..], 0xa7));
    try std.testing.expectError(
        error.InvalidOffset,
        into(&block, &output, .{ .history = .{ .newer = "EFG" }, .output_size = .bounded }),
    );
    _ = try into(&block, output[0..count], .{ .history = .{ .newer = "ABCDEFG" } });
    try std.testing.expectError(
        error.OutputSizeMismatch,
        into(&block, &output, .{ .history = .{ .newer = "ABCDEFG" } }),
    );
}

test "LZ4 exact literal extensions empty blocks and independent matches" {
    const allocator = std.testing.allocator;
    const workspace = try test_encoding.Workspace.create(allocator);
    defer workspace.destroy(allocator);
    var random: std.Random.DefaultPrng = .init(0x4c5a3401);
    for (
        [_]usize{
            0,      1, 4, 5, 12, 13, 14, 15, 16, 19, 255, 269, 270, 271, 1024, 65535, 65536, 65537,
            131072,
        },
    ) |size| {
        const input = try allocator.alloc(u8, size);
        defer allocator.free(input);
        const encoded = try allocator.alloc(u8, try test_encoding.bound(size));
        defer allocator.free(encoded);
        const output = try allocator.alloc(u8, size);
        defer allocator.free(output);
        for (0..4) |mode| {
            switch (mode) {
                0 => random.random().bytes(input),
                1 => @memset(input, 0),
                2 => for (input, 0..) |*b, i| {
                    b.* = @intCast(i % 251);
                },
                3 => for (input, 0..) |*b, i| {
                    b.* = @intCast((i / 17) % 7);
                },
                else => unreachable,
            }
            const block = try test_encoding.into(input, encoded, workspace, .{});
            _ = try into(block, output, .{});
            try std.testing.expectEqualSlices(u8, input, output);
            if (mode == 1 and size >= 256) try std.testing.expect(block.len < size / 4);
        }
    }
}

test "LZ4 overlapping distances exact tails and guard bytes" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 255, 256, 65535 }) |distance| {
        const literals = distance;
        const match = @max(7, distance * 2 + 3);
        const total = literals + match + 5;
        const encoded = try allocator.alloc(u8, try test_encoding.bound(total));
        defer allocator.free(encoded);
        const history = try allocator.alloc(u8, literals);
        defer allocator.free(history);
        for (history, 0..) |*b, i| b.* = @intCast(i % 251);
        var writer: TestWriter = .{ .bytes = encoded };
        writer.sequence(history, @intCast(distance), match);
        writer.final("TAIL!");
        const guarded = try allocator.alloc(u8, total + 32);
        defer allocator.free(guarded);
        @memset(guarded, 0xa7);
        const output = guarded[16..][0..total];
        _ = try into(encoded[0..writer.cursor], output, .{});
        for (output[0 .. literals + match], 0..) |byte, i| {
            try std.testing.expectEqual(history[i % distance], byte);
        }
        try std.testing.expectEqualStrings("TAIL!", output[literals + match ..]);
        try std.testing.expect(std.mem.allEqual(u8, guarded[0..16], 0xa7));
        try std.testing.expect(std.mem.allEqual(u8, guarded[16 + total ..], 0xa7));
        for (0..writer.cursor) |cut| {
            @memset(guarded[0..16], 0xa7);
            @memset(guarded[16 + total ..], 0xa7);
            if (into(encoded[0..cut], output, .{})) |_| {
                return error.TruncatedBlockAccepted;
            } else |_| {}
            try std.testing.expect(std.mem.allEqual(u8, guarded[0..16], 0xa7));
            try std.testing.expect(std.mem.allEqual(u8, guarded[16 + total ..], 0xa7));
        }
    }
}

test "LZ4 long periodic matches preserve pattern and guard bytes" {
    const allocator = std.testing.allocator;
    for ([_]usize{ 2, 79, 128 }) |distance| {
        for ([_]usize{ 8192, 65531 }) |match| {
            const total = distance + match + 5;
            const encoded = try allocator.alloc(u8, try test_encoding.bound(total));
            defer allocator.free(encoded);
            const history = try allocator.alloc(u8, distance);
            defer allocator.free(history);
            for (history, 0..) |*byte, i| byte.* = @intCast((i * 29) % 251);
            var writer: TestWriter = .{ .bytes = encoded };
            writer.sequence(history, @intCast(distance), match);
            writer.final("TAIL!");

            const guarded = try allocator.alloc(u8, total + 32);
            defer allocator.free(guarded);
            @memset(guarded, 0xa7);
            const output = guarded[16..][0..total];
            _ = try into(encoded[0..writer.cursor], output, .{});
            for (output[0 .. distance + match], 0..) |byte, i| {
                try std.testing.expectEqual(history[i % distance], byte);
            }
            try std.testing.expectEqualStrings("TAIL!", output[distance + match ..]);
            try std.testing.expect(std.mem.allEqual(u8, guarded[0..16], 0xa7));
            try std.testing.expect(std.mem.allEqual(u8, guarded[16 + total ..], 0xa7));
        }
    }
}

test "LZ4 malformed lengths offsets termination and storage fail within exact bounds" {
    const allocator = std.testing.allocator;
    const output = try allocator.alloc(u8, 300);
    defer allocator.free(output);
    try std.testing.expectError(error.Truncated, into(&.{}, output, .{}));
    try std.testing.expectError(error.Truncated, into(&.{ 0xf0, 255 }, output, .{}));
    try std.testing.expectError(error.InvalidOffset, into(&.{ 0, 0, 0 }, output, .{}));
    try std.testing.expectError(error.InvalidOffset, into(&.{ 0, 1, 0 }, output, .{}));
    try std.testing.expectError(error.Truncated, into(&.{ 0x10, 'a', 1 }, output, .{}));
    try std.testing.expectError(error.Truncated, into(&.{ 0x1f, 'a', 1, 0, 255 }, output, .{}));
    try std.testing.expectError(
        error.InvalidTermination,
        into(&.{ 0x10, 'a', 1, 0, 0 }, output[0..5], .{}),
    );
    try std.testing.expectError(
        error.InvalidTermination,
        into(&.{ 0x10, 'a', 1, 0, 0x50, 1, 2, 3, 4, 5 }, output[0..10], .{}),
    );
    try std.testing.expectError(error.OutputSizeMismatch, into(&.{0}, output[0..1], .{}));
    try std.testing.expectError(error.OutputTooSmall, into(&.{ 0x10, 'a' }, output[0..0], .{}));
    try std.testing.expectError(error.Aliasing, into(output[0..1], output[0..1], .{}));
}

test "LZ4 decodes frozen independent upstream blocks with exact recovery" {
    const allocator = std.testing.allocator;
    for (test_fixtures.vectors) |vector| {
        const output = try allocator.alloc(u8, vector.size);
        defer allocator.free(output);
        _ = try into(vector.encoded, output, .{});
        for (output, 0..) |byte, i| {
            const expected: u8 = if (vector.zeros) 0 else @intCast(i % 251);
            try std.testing.expectEqual(expected, byte);
        }
    }
}

/// The reachable suffix of one borrowed decoded-history span.
pub fn historySuffix(bytes: []const u8) []const u8 {
    return bytes[bytes.len - @min(bytes.len, maximum_distance) ..];
}
