//! Raw LZ4 blocks, dictionary history and resumable block recovery. Calls borrow exact disjoint
//! buffers and allocate nothing.

const std = @import("std");
const builtin = @import("builtin");
const copy = @import("copy.zig");

/// Practical encoding bound, matching LZ4 1.10.0's public input contract.
pub const maximum_input_bytes: usize = 0x7e00_0000;

/// Maximum representable independent match distance.
pub const maximum_distance: usize = 65535;

/// Byte-format and supplied-storage failures. Output may contain an unpublished prefix.
pub const Error = error{
    Truncated,
    OutputTooSmall,
    OutputSizeMismatch,
    InvalidOffset,
    InvalidTermination,
    SizeOverflow,
    InputTooLarge,
    Aliasing,
};

/// Address-stable encoder scratch; no allocator, source or output pointers are retained.
pub const EncoderWorkspace = struct {
    positions: [4096]u32,

    /// Allocates scratch directly at its final address; encoding initializes all table cells.
    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*EncoderWorkspace {
        return allocator.create(EncoderWorkspace);
    }

    /// Releases this sole allocation through the authority used by create.
    pub fn destroy(self: *EncoderWorkspace, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

/// Two chronological, borrowed history spans. Only their last 65,535 bytes can be referenced. Empty
/// spans represent an independent block. This permits a dictionary followed by already decoded
/// linked blocks without concatenating them. Both spans must remain immutable during the call.
pub const HistoryView = struct {
    older: []const u8 = &.{},
    newer: []const u8 = &.{},

    fn trimmed(self: HistoryView) HistoryView {
        const newer = dictionarySuffix(self.newer);
        const older_count = @min(self.older.len, maximum_distance - newer.len);
        const older = self.older[self.older.len - older_count ..];
        return .{ .older = older, .newer = newer };
    }
};

/// Sufficient output capacity for any native encoding of this input length, including empty.
/// Oversized input/arithmetic fail without allocation. encodeBlock requires this full capacity.
pub fn blockEncodeBound(input_bytes: usize) Error!usize {
    if (input_bytes > maximum_input_bytes) return error.InputTooLarge;
    return std.math.add(usize, input_bytes, input_bytes / 255 + 16) catch error.SizeOverflow;
}

/// Required restored extent for a complete raw block. The complete supplied source is always
/// parsed.
pub const OutputSize = enum { bounded, exact };

/// Complete-block counts. Source length supplies the block boundary; consumed equals source.len.
pub const DecodeResult = struct { consumed: usize, produced: usize };

/// Complete-block policy. Empty dictionary spans select independent history; only their reachable
/// suffixes must be disjoint from destination. Source and dictionary may overlap each other.
pub const BlockDecodeOptions = struct {
    dictionary: HistoryView = .{},
    output_size: OutputSize = .exact,
    limits: DecodeLimits = .{},
};

/// Complete-block resource exhaustion in addition to malformed input and supplied capacity errors.
pub const BlockDecodeError = Error || error{LimitExceeded};

/// Decodes one complete raw block. Exact output is the default; bounded output reports its used
/// prefix. Optional two-span history and cumulative byte admission are independent. Complete input
/// and disjointness are required; trailing encoded bytes cannot bypass parsing. Returns copied
/// counts. Failure may change output, but never writes outside it or mutates source.
///
/// The doctest's helper checks an application-selected decoded-byte cap before allocating exact
/// output. Failure frees unpublished output; success transfers the complete allocation to the
/// caller. Source can then retire. The enclosing record still supplies its integrity policy before
/// publication.
pub fn decodeBlock(
    source: []const u8,
    output: []u8,
    options: BlockDecodeOptions,
) BlockDecodeError!DecodeResult {
    const history = options.dictionary.trimmed();
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
    const has_dictionary = options.dictionary.older.len != 0 or options.dictionary.newer.len != 0;
    const use_independent_exact_kernel = options.output_size == .exact and !has_dictionary;
    const produced = if (use_independent_exact_kernel) blk: {
        try decodeIndependentExact(source, output);
        break :blk output.len;
    } else blk: {
        // A bounded block with no dictionary has the same history as a zero-length prefix. The
        // smaller parser helps generic x86 without changing wide-target code.
        const use_prefix = if (comptime builtin.cpu.arch == .x86_64 and !std.Target.x86
            .featureSetHas(
            builtin.cpu.features,
            .avx2,
        )) !has_dictionary else false;
        const decoded = if (use_prefix) decodeBounded(
            true,
            source,
            output[0..capacity],
            .{},
            0,
        ) else decodeBounded(false, source, output[0..capacity], options.dictionary, 0);
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

test decodeBlock {
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
            _ = try decodeBlock(source, output, .{});
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

/// Decodes a complete bounded block into the suffix of a frame's contiguous output. The prefix is
/// already produced and may be referenced by matches; only the suffix is written.
pub noinline fn decodeBlockWithPrefix(
    source: []const u8,
    output: []u8,
    prefix_len: usize,
) Error!DecodeResult {
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
    history: HistoryView,
    prefix_len: usize,
) Error!usize {
    const view = if (contiguous_prefix) HistoryView{} else history.trimmed();
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

/// Greedy block encoding, with optional immutable external history for this call.
pub const BlockEncodeOptions = struct { dictionary: []const u8 = &.{} };

/// Produces a deterministic raw block, borrowing the used prefix of output. Requires
/// blockEncodeBound(source.len) capacity and disjoint source/output/workspace before writing. Fills
/// no trailing bytes. EncoderWorkspace is completely reset for every call.
// Stabilize the hot word-match loop's placement as other codec bodies grow.
pub fn encodeBlock(
    source: []const u8,
    output: []u8,
    workspace: *EncoderWorkspace,
    options: BlockEncodeOptions,
) align(64) Error![]u8 {
    const dictionary = dictionarySuffix(options.dictionary);
    if (dictionary.len != 0) return encodeWithHistory(
        source,
        output,
        workspace,
        dictionary,
        null,
        false,
        false,
    );
    const bound = try blockEncodeBound(source.len);
    const scratch = std.mem.asBytes(workspace);
    if (try overlaps(source, output)) return error.Aliasing;
    if (try overlaps(source, scratch) or try overlaps(output, scratch)) return error.Aliasing;
    if (output.len < bound) return error.OutputTooSmall;

    if (source.len == 65536) return encodeBlockWide64K(source, output, workspace);
    if (source.len < 65536) return encodeBlockRaw(true, false, source, output, workspace, 0);
    return encodeBlockRaw(false, false, source, output, workspace, 0);
}

/// A full raw block keeps 32-bit hash entries usable by later linked blocks. This kernel seeds byte
/// zero into that table, then follows a greedy five-byte hash search. After a match it probes the
/// two positions immediately before and at the new cursor to continue an adjacent match chain
/// without restarting the ordinary skip schedule.
fn encodeBlockWide64K(source: []const u8, output: []u8, workspace: *EncoderWorkspace) []u8 {
    const positions = &workspace.positions;
    // Position zero is the useful candidate for an empty slot. Store it as one here so the
    // one-based rolling table needs no empty-slot selection on each first-block probe.
    @memset(positions, 1);
    var writer: Writer = .{ .bytes = output };
    var anchor: usize = 0;
    var position: usize = 1;
    const search_limit = source.len - 12;
    const match_limit = source.len - 5;
    positions[hashFivePosition(source, 0)] = 1;
    var forward_hash = hashFivePosition(source, position);
    var attempts: usize = 64;
    var step: usize = 1;

    while (position <= search_limit) {
        const hash = forward_hash;
        const previous = positions[hash];
        positions[hash] = @intCast(position + 1);
        const candidate: usize = previous - 1;
        const next = position + step;
        step = attempts >> 6;
        attempts += 1;
        if (next > search_limit) break;
        forward_hash = hashFivePosition(source, next);
        if (std.mem.readInt(
            u32,
            source[position..][0..4],
            .little,
        ) != std.mem.readInt(u32, source[candidate..][0..4], .little)) {
            position = next;
            continue;
        }

        var reference = candidate;
        match_chain: while (true) {
            while (position > anchor and reference > 0 and source[position - 1] ==
                source[reference - 1])
            {
                position -= 1;
                reference -= 1;
            }
            const match = 4 + commonBytes(false, source, position + 4, reference + 4, match_limit);
            const offset: u16 = @intCast(position - reference);
            if (position == anchor) {
                writer.sequenceNoLiterals(offset, match);
            } else {
                writer.sequenceWild(source[anchor..], position - anchor, offset, match);
            }
            position += match;
            anchor = position;
            attempts = 64;
            step = 1;
            if (position > search_limit) break :match_chain;

            const prev_hash = hashFivePosition(source, position - 1);
            const prev_index = positions[prev_hash];
            positions[prev_hash] = @intCast(position);
            const current_hash = hashFivePosition(source, position);
            const current_index = positions[current_hash];
            positions[current_hash] = @intCast(position + 1);

            const prev_candidate: usize = prev_index;
            const current_candidate: usize = current_index - 1;
            const successor = if (std.mem.readInt(
                u64,
                source[prev_candidate..][0..8],
                .little,
            ) == std.mem.readInt(
                u64,
                source[position..][0..8],
                .little,
            )) prev_candidate else current_candidate;
            if (std.mem.readInt(
                u32,
                source[successor..][0..4],
                .little,
            ) == std.mem.readInt(u32, source[position..][0..4], .little)) {
                reference = successor;
                continue :match_chain;
            }
            position += 1;
            if (position <= search_limit) forward_hash = hashFivePosition(source, position);
            break :match_chain;
        }
    }
    writer.final(source[anchor..]);
    return output[0..writer.cursor];
}

fn encodeBlockRaw(
    comptime compact: bool,
    comptime prepared: bool,
    source: []const u8,
    output: []u8,
    workspace: *EncoderWorkspace,
    initial_position: usize,
) []u8 {
    // This greedy kernel keeps one prior position per hash instead of a chain. Misses become
    // progressively cheaper through a skip schedule; a hit extends backward into pending literals
    // and forward to the last position that still leaves LZ4's required five final literals. The
    // compact and wide tables occupy the same workspace bytes. Only independent blocks up to 64 KiB
    // use 16-bit positions; larger blocks and linked history keep 32-bit positions.
    const positions = if (compact) @as(
        *[8192]u16,
        @ptrCast(&workspace.positions),
    ) else &workspace.positions;
    if (!prepared) @memset(positions, 0);

    var writer: Writer = .{ .bytes = output };
    var anchor: usize = 0;
    // Compact tables hold direct positions. Starting at byte one makes zero a safe source-byte-zero
    // candidate in the raw loop.
    const direct_zero = compact;
    var position: usize = if (direct_zero and !prepared) 1 else initial_position;
    if (source.len >= 13) {
        const search_limit = source.len - 12;
        const match_limit = source.len - 5;
        var search_attempts: usize = if (prepared) 128 else 64;
        while (position <= search_limit) {
            const hash = if (compact) hashFiveCompact(
                source,
                position,
            ) else hashFivePosition(source, position);
            const previous = positions[hash];
            positions[hash] = @intCast(if (direct_zero) position else position + 1);
            // Wide tables reserve zero for an empty slot; compact tables use zero as the valid
            // position of the first input byte.
            const candidate: usize = if (direct_zero) previous else if (previous == 0)
                position
            else
                @as(
                    usize,
                    previous,
                ) - 1;
            const matched = blk: {
                if (!direct_zero) {
                    if (previous == 0 or candidate >= position) break :blk false;
                    if (position - candidate > maximum_distance) break :blk false;
                }
                const current_word = std.mem.readInt(u32, source[position..][0..4], .little);
                const candidate_word = std.mem.readInt(u32, source[candidate..][0..4], .little);
                break :blk current_word == candidate_word;
            };
            if (!matched) {
                const step = search_attempts >> 6;
                search_attempts += 1;
                if (step > search_limit - position) break;
                position += step;
                continue;
            }

            var reference = candidate;
            // Backward extension remains in the unpublished literal run and available input.
            while (position > anchor and reference > 0 and source[position - 1] ==
                source[reference - 1])
            {
                position -= 1;
                reference -= 1;
            }
            const match_tail = commonBytes(true, source, position + 4, reference + 4, match_limit);
            const match_length = 4 + match_tail;
            const distance: u16 = @intCast(position - reference);
            writer.sequence(source[anchor..position], distance, match_length);
            position += match_length;
            anchor = position;
            search_attempts = if (prepared) 128 else 64;

            // A match leaves five literals, proving these two four-byte hash loads fit.
            if (position <= search_limit) {
                positions[
                    if (compact) hashFiveCompact(
                        source,
                        position - 2,
                    ) else hashFivePosition(source, position - 2)
                ] = @intCast(if (direct_zero) position - 2 else position - 1);
                positions[
                    if (compact) hashFiveCompact(
                        source,
                        position - 1,
                    ) else hashFivePosition(source, position - 1)
                ] = @intCast(if (direct_zero) position - 1 else position);
            }
        }
    }

    writer.final(source[anchor..]);
    return output[0..writer.cursor];
}

// Keep the prepared raw loop aligned independently of linked-history code size.
noinline fn encodePreparedRaw(
    source: []const u8,
    output: []u8,
    workspace: *EncoderWorkspace,
    initial_position: usize,
) align(64) []u8 {
    return @call(
        .always_inline,
        encodeBlockRaw,
        .{ true, true, source, output, workspace, initial_position },
    );
}

/// Encode an independent block of at most 64 KiB after searching its source once. The preliminary
/// scan lets frame encoding avoid a second full pass and the encoded-output copy for incompressible
/// input. A null result means no match exists and a frame can store the original caller-owned
/// bytes.
pub fn encodeBlockWithInitialProbe(
    source: []const u8,
    output: []u8,
    workspace: *EncoderWorkspace,
) Error!?[]u8 {
    if (source.len > 65536) return error.InputTooLarge;
    const bound = try blockEncodeBound(source.len);
    const scratch = std.mem.asBytes(workspace);
    if (try overlaps(source, output)) return error.Aliasing;
    if (try overlaps(source, scratch) or try overlaps(output, scratch)) return error.Aliasing;
    if (output.len < bound) return error.OutputTooSmall;

    const positions: *[8192]u16 = @ptrCast(&workspace.positions);
    @memset(positions, 0);
    if (source.len < 13) return null;
    const search_limit = source.len - 12;
    var position: usize = 1;
    var attempts: usize = 128;
    while (position <= search_limit) {
        const hash = hashFiveCompact(source, position);
        const previous = positions[hash];
        positions[hash] = @intCast(position);
        // Skip the ambiguous zero entry in this preliminary probe. A nonzero candidate precedes the
        // probe and is within the 64 KiB distance limit.
        if (previous != 0 and std.mem.readInt(
            u32,
            source[position..][0..4],
            .little,
        ) == std.mem.readInt(u32, source[@as(usize, previous)..][0..4], .little)) {
            positions[hash] = previous;
            return encodePreparedRaw(source, output, workspace, position);
        }
        const step = attempts >> 6;
        attempts += 1;
        if (step > search_limit - position) return null;
        position += step;
    }
    return null;
}

test "LZ4 initial probe preserves raw bytes and leaves no-match output untouched" {
    const allocator = std.testing.allocator;
    const probed = try EncoderWorkspace.create(allocator);
    defer probed.destroy(allocator);
    const ordinary = try EncoderWorkspace.create(allocator);
    defer ordinary.destroy(allocator);
    const source = try allocator.alloc(u8, 65536);
    defer allocator.free(source);
    const bound = try blockEncodeBound(source.len);
    const output = try allocator.alloc(u8, bound + 1);
    defer allocator.free(output);
    const expected = try allocator.alloc(u8, bound);
    defer allocator.free(expected);

    var random: std.Random.DefaultPrng = .init(0x5180_7204);
    random.random().bytes(source);
    @memset(output, 0xa5);
    try std.testing.expect(
        (try encodeBlockWithInitialProbe(source[0..12], output[0..bound], probed)) == null,
    );
    try std.testing.expect(
        (try encodeBlockWithInitialProbe(source, output[0..bound], probed)) == null,
    );
    try std.testing.expect(std.mem.allEqual(u8, output, 0xa5));

    @memset(source, 'a');
    const compressed = (try encodeBlockWithInitialProbe(source, output[0..bound], probed)).?;
    const ordinary_bytes = try encodeBlock(source, expected, ordinary, .{});
    var decoded: [65536]u8 = undefined;
    _ = try decodeBlock(compressed, &decoded, .{});
    try std.testing.expectEqualSlices(u8, source, &decoded);
    _ = try decodeBlock(ordinary_bytes, &decoded, .{});
    try std.testing.expectEqualSlices(u8, source, &decoded);
    try std.testing.expectEqual(@as(u8, 0xa5), output[bound]);
}

test encodeBlock {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);

    const source = "an independent raw LZ4 block";
    const destination = try allocator.alloc(u8, try blockEncodeBound(source.len));
    defer allocator.free(destination);
    const record = .{
        .bytes = try encodeBlock(source, destination, workspace, .{}),
        .decoded_size = source.len,
    };

    var output: [source.len]u8 = undefined;
    _ = try decodeBlock(record.bytes, output[0..record.decoded_size], .{});
    try std.testing.expectEqualStrings(source, &output);
}

test "LZ4 linked literal copies preserve the encoded suffix and output guard" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);

    var input: [128]u8 = undefined;
    for (input[0..64], 0..) |*byte, index| byte.* = @intCast(index % 17);
    @memcpy(input[64..128], input[0..64]);
    var storage: [96]u8 = @splat(0xa5);
    var decoded: [64]u8 = undefined;

    @memset(&workspace.positions, 0);
    workspace.positions[hashFivePosition(input[64..128], 0)] = 1;
    var state: RollingState = .{ .ready = true, .end = 64, .five_byte_hash = true };
    const rolling = try encodeBlockRolling(
        input[64..128],
        storage[0..80],
        workspace,
        input[0..64],
        true,
        &state,
    );
    try std.testing.expectEqual(@as(u8, 0), rolling[0] >> 4);
    try std.testing.expect(std.mem.allEqual(u8, storage[rolling.len..], 0xa5));
    _ = try decodeBlock(rolling, &decoded, .{ .dictionary = .{ .newer = input[0..64] } });
    try std.testing.expectEqualSlices(u8, input[64..128], &decoded);

    @memset(&storage, 0xa5);
    const borrowed = try encodeBlock(
        input[64..128],
        storage[0..80],
        workspace,
        .{ .dictionary = input[0..64] },
    );
    try std.testing.expectEqual(@as(u8, 0), borrowed[0] >> 4);
    try std.testing.expect(std.mem.allEqual(u8, storage[borrowed.len..], 0xa5));
    _ = try decodeBlock(borrowed, &decoded, .{ .dictionary = .{ .newer = input[0..64] } });
    try std.testing.expectEqualSlices(u8, input[64..128], &decoded);
}

test "LZ4 raw table switches at the 64 KiB boundary" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);

    var source: [65537]u8 = undefined;
    var state: u64 = 0x1234_5678_9abc_def0;
    for (&source) |*byte| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        byte.* = @truncate(state);
    }

    for ([_]usize{ 65535, 65536, 65537 }) |block_len| {
        const encoded = try allocator.alloc(u8, try blockEncodeBound(block_len));
        defer allocator.free(encoded);
        const decoded = try allocator.alloc(u8, block_len);
        defer allocator.free(decoded);

        const wire = try encodeBlock(source[0..block_len], encoded, workspace, .{});
        const result = try decodeBlock(wire, decoded, .{});
        try std.testing.expectEqual(block_len, result.produced);
        try std.testing.expectEqualSlices(u8, source[0..block_len], decoded);
    }
}

/// Deterministic greedy compression with external history. Empty dictionaries use encodeBlock
/// unchanged. The dictionary is borrowed only for this call; output/workspace must be disjoint from
/// all input. Each call rebuilds its table, including the retained dictionary suffix. Use
/// encodeBlockHc for deeper search.
fn encodeWithHistory(
    source: []const u8,
    output: []u8,
    workspace: *EncoderWorkspace,
    dictionary: []const u8,
    rolling_end: ?u32,
    contiguous_history: bool,
    five_byte_hash: bool,
) Error![]u8 {
    const dict = dictionarySuffix(dictionary);
    std.debug.assert(dict.len != 0);
    std.debug.assert(!five_byte_hash or rolling_end != null);
    const bound = try blockEncodeBound(source.len);
    const scratch = std.mem.asBytes(workspace);
    if (try overlaps(source, output)) return error.Aliasing;
    if (try overlaps(source, scratch) or try overlaps(output, scratch)) return error.Aliasing;
    if (try overlaps(dict, output) or try overlaps(dict, scratch)) return error.Aliasing;
    if (output.len < bound) return error.OutputTooSmall;

    const start: usize = rolling_end orelse @intCast(dict.len);
    const base = start - dict.len;
    if (rolling_end == null) @memset(&workspace.positions, 0);
    if (rolling_end == null and dict.len >= 4) {
        for (0..dict.len - 3) |i| {
            workspace.positions[hashFourPosition(dict, i)] = @intCast(i + 1);
        }
    }

    if (contiguous_history) std.debug.assert(
        @intFromPtr(dict.ptr) + dict.len == @intFromPtr(source.ptr),
    );

    // Pointer-based linked search is safe only when history immediately precedes source. Five-byte
    // hashing is retained only for streams whose first block established that hash width; a
    // dictionary-started stream must keep using the four-byte table representation.
    if (contiguous_history and five_byte_hash) {
        if (dict.len == maximum_distance) return encodeLinkedFive(
            true,
            source,
            output,
            workspace,
            dict,
            @intCast(start),
            @intCast(base),
        );
        return encodeLinkedFive(
            false,
            source,
            output,
            workspace,
            dict,
            @intCast(start),
            @intCast(base),
        );
    }
    if (five_byte_hash) {
        return encodeWithHistoryLoop(false, true, source, output, workspace, dict, start, base);
    }
    if (contiguous_history) return encodeWithHistoryLoop(
        true,
        false,
        source,
        output,
        workspace,
        dict,
        start,
        base,
    );
    return encodeWithHistoryLoop(false, false, source, output, workspace, dict, start, base);
}

fn encodeWithHistoryLoop(
    comptime contiguous: bool,
    comptime five_byte_hash: bool,
    source: []const u8,
    output: []u8,
    workspace: *EncoderWorkspace,
    dict: []const u8,
    start: usize,
    base: usize,
) Error![]u8 {
    // Dictionary and source positions share one chronological index space. Contiguous callers can
    // read them as one span; other callers use explicit dictionary/source access at the boundary.
    // The compile-time flags select those address and hash rules without a runtime branch per
    // probe.
    const combined: []const u8 = if (contiguous) dict.ptr[0 .. dict.len + source.len] else &.{};
    var writer: Writer = .{ .bytes = output };
    var anchor: usize = 0;
    var position: usize = 0;
    if (source.len >= 12) {
        const search_limit = source.len - 12;
        const match_limit = source.len - 5;
        var attempts: usize = 64;
        while (position <= search_limit) {
            const hash = if (five_byte_hash) hashFivePosition(
                source,
                position,
            ) else hashFourPosition(source, position);
            const previous = workspace.positions[hash];
            const absolute = dict.len + position;
            workspace.positions[hash] = @intCast(start + position + 1);
            const candidate: usize = if (contiguous) blk: {
                const current = start + position + 1;
                const distance = current -% previous;
                const valid = previous > base and distance -% 1 < maximum_distance;
                break :blk if (valid) absolute - distance else absolute;
            } else if (previous <= base) absolute else previous - 1 - base;
            const matched = blk: {
                if (contiguous) {
                    const equal = std.mem.readInt(
                        u32,
                        combined[candidate..][0..4],
                        .little,
                    ) == std.mem.readInt(u32, source[position..][0..4], .little);
                    break :blk candidate != absolute and equal;
                }
                if (previous <= base or candidate >= absolute) break :blk false;
                if (absolute - candidate > maximum_distance) break :blk false;
                break :blk equalFour(dict, source, candidate, position);
            };
            if (!matched) {
                const step_size = searchStep(attempts);
                attempts += 1;
                if (step_size > search_limit - position) break;
                position += step_size;
                continue;
            }

            var reference = candidate;
            while (position > anchor and reference > 0) {
                const previous_byte = if (contiguous) combined[reference - 1] else historyByte(
                    dict,
                    source,
                    reference - 1,
                );
                if (source[position - 1] != previous_byte) break;
                position -= 1;
                reference -= 1;
            }
            const match = if (contiguous) 4 + commonBytes(
                false,
                combined,
                dict.len + position + 4,
                reference + 4,
                dict.len + match_limit,
            ) else blk: {
                var count: usize = 4;
                while (position + count < match_limit and reference + count < dict.len and
                    source[position + count] == dict[reference + count]) count += 1;
                if (reference + count >= dict.len) {
                    count += commonBytes(
                        false,
                        source,
                        position + count,
                        reference + count - dict.len,
                        match_limit,
                    );
                }
                break :blk count;
            };
            writer.sequenceWild(
                source[anchor..],
                position - anchor,
                @intCast(dict.len + position - reference),
                match,
            );
            position += match;
            anchor = position;
            attempts = 64;
            if (!five_byte_hash or position <= search_limit) {
                const penultimate_hash = if (five_byte_hash) hashFivePosition(
                    source,
                    position - 2,
                ) else hashFourPosition(source, position - 2);
                workspace.positions[penultimate_hash] = @intCast(start + position - 1);
                const last_hash = if (five_byte_hash) hashFivePosition(
                    source,
                    position - 1,
                ) else hashFourPosition(source, position - 1);
                workspace.positions[last_hash] = @intCast(start + position);
            }
        }
    }

    writer.final(source[anchor..]);
    return output[0..writer.cursor];
}

// The linked kernel keeps input, match, and output cursors as pointers. The caller has already
// checked disjoint storage and the full block output bound.
fn encodeLinkedFive(
    comptime full_prefix: bool,
    source: []const u8,
    output: []u8,
    workspace: *EncoderWorkspace,
    dict: []const u8,
    start: u32,
    base: u32,
) []u8 {
    // This pointer kernel is for contiguous linked input, where dictionary and source have one
    // address origin. Keeping that origin lets the hot search compare raw pointers while the table
    // stores wrapping u32 positions. `full_prefix` selects whether the dictionary fills the entire
    // 65,535-byte reference window, which changes the validity checks for old table entries.
    // Contiguous history gives source.ptr - start and dict.ptr - base the same index origin.
    const index_base_address = @intFromPtr(source.ptr) -% @as(usize, start);
    const history_address = @intFromPtr(dict.ptr);
    const positions = &workspace.positions;
    var input = source.ptr;
    var anchor = source.ptr;
    var op = output.ptr;
    if (source.len >= 12) {
        const search_limit = @intFromPtr(source.ptr) + source.len - 12;
        const match_limit = source.ptr + source.len - 5;
        var attempts: usize = 64;
        while (@intFromPtr(input) <= search_limit) {
            const hash = hashFivePointer(input);
            const previous = positions[hash];
            const current: u32 = @intCast(@intFromPtr(input) -% index_base_address +% 1);
            positions[hash] = current;
            const age = current -% previous;
            const valid = if (full_prefix) age -% 1 < maximum_distance else previous > base and
                previous < current and age <= maximum_distance;
            if (!valid or std.mem.readInt(
                u32,
                @as(
                    [*]const u8,
                    @ptrFromInt(index_base_address +% @as(usize, previous) -% 1),
                )[0..4],
                .little,
            ) != std.mem.readInt(u32, input[0..4], .little)) {
                const step = searchStep(attempts);
                attempts += 1;
                if (step > search_limit - @intFromPtr(input)) break;
                input += step;
                continue;
            }

            var reference: [*]const u8 = @ptrFromInt(
                index_base_address +% @as(usize, previous) -% 1,
            );
            var immediate = false;
            match_chain: while (true) {
                if (!immediate) {
                    // A full prefix and a valid offset keep the reference above dict.ptr.
                    while (@intFromPtr(
                        input,
                    ) > @intFromPtr(
                        anchor,
                    ) and (full_prefix or @intFromPtr(
                        reference,
                    ) > history_address) and (input - 1)[0] == (reference - 1)[0]) {
                        input -= 1;
                        reference -= 1;
                    }
                }

                const token = op;
                op += 1;
                const literal_count = @intFromPtr(input) - @intFromPtr(anchor);
                token[0] = @as(u8, @intCast(@min(literal_count, 15))) << 4;
                if (literal_count >= 15) {
                    var remaining = literal_count - 15;
                    while (remaining >= 255) : (remaining -= 255) {
                        op[0] = 255;
                        op += 1;
                    }
                    op[0] = @intCast(remaining);
                    op += 1;
                }
                if (literal_count != 0) {
                    // The offset and required final literals cover the spare bytes of this wild
                    // copy.
                    var copied: usize = 0;
                    while (true) : (copied += 8) {
                        @memcpy(op[copied..][0..8], anchor[copied..][0..8]);
                        if (copied + 8 >= literal_count) break;
                    }
                    op += literal_count;
                }
                const match = 4 + commonBytesPointer(input + 4, reference + 4, match_limit);
                const offset: u16 = @intCast(@intFromPtr(input) - @intFromPtr(reference));
                op[0] = @truncate(offset);
                op[1] = @intCast(offset >> 8);
                op += 2;

                input += match;
                const field = match - 4;
                token[0] |= @intCast(@min(field, 15));
                if (field >= 15) {
                    var remaining = field - 15;
                    while (remaining >= 255) : (remaining -= 255) {
                        op[0] = 255;
                        op += 1;
                    }
                    op[0] = @intCast(remaining);
                    op += 1;
                }
                anchor = input;
                attempts = 64;
                immediate = false;
                if (@intFromPtr(input) > search_limit) break :match_chain;

                // Test the predecessor and current successor slots at the match boundary first.
                // Reusing an equal slot extends a chain of adjacent matches without hashing every
                // byte skipped by the match.
                const last_hash = hashFivePointer(input - 1);
                const predecessor = positions[last_hash];
                const next_current: u32 = @intCast(@intFromPtr(input) -% index_base_address +% 1);
                positions[last_hash] = next_current - 1;
                const next_hash = hashFivePointer(input);
                const predecessor_valid = if (full_prefix) next_current -% predecessor -% 2 <
                    maximum_distance else predecessor > base and predecessor + 1 < next_current and
                    next_current - predecessor - 1 <= maximum_distance;
                if (predecessor_valid and std.mem.readInt(
                    u64,
                    @as(
                        [*]const u8,
                        @ptrFromInt(index_base_address +% @as(usize, predecessor)),
                    )[0..8],
                    .little,
                ) == std.mem.readInt(u64, input[0..8], .little)) {
                    positions[next_hash] = next_current;
                    reference = @ptrFromInt(index_base_address +% @as(usize, predecessor));
                    immediate = true;
                    continue :match_chain;
                }
                const next_previous = positions[next_hash];
                positions[next_hash] = next_current;
                const next_valid = if (full_prefix) next_current -% next_previous -% 1 <
                    maximum_distance else next_previous > base and next_previous < next_current and
                    next_current - next_previous <= maximum_distance;
                if (next_valid and std.mem.readInt(
                    u32,
                    @as(
                        [*]const u8,
                        @ptrFromInt(index_base_address +% @as(usize, next_previous) -% 1),
                    )[0..4],
                    .little,
                ) == std.mem.readInt(u32, input[0..4], .little)) {
                    reference = @ptrFromInt(index_base_address +% @as(usize, next_previous) -% 1);
                    immediate = true;
                    continue :match_chain;
                }
                input += 1;
                attempts = 65;
                break :match_chain;
            }
        }
    }
    const final_count = @intFromPtr(source.ptr + source.len) - @intFromPtr(anchor);
    op[0] = @as(u8, @intCast(@min(final_count, 15))) << 4;
    op += 1;
    if (final_count >= 15) {
        var remaining = final_count - 15;
        while (remaining >= 255) : (remaining -= 255) {
            op[0] = 255;
            op += 1;
        }
        op[0] = @intCast(remaining);
        op += 1;
    }
    @memcpy(op[0..final_count], anchor[0..final_count]);
    op += final_count;
    return output[0 .. @intFromPtr(op) - @intFromPtr(output.ptr)];
}

fn hashFivePointer(input: [*]const u8) usize {
    const word = std.mem.readInt(u64, input[0..8], .little);
    return ((word << 24) *% 889523592379) >> 52;
}

// One offset advances both loads through a long match without carrying two pointer increments.
fn commonBytesPointer(first: [*]const u8, second: [*]const u8, limit: [*]const u8) usize {
    const bytes = @intFromPtr(limit) - @intFromPtr(first);
    var count: usize = 0;
    if (bytes >= 8) {
        while (true) {
            const difference = std.mem.readInt(
                u64,
                first[count..][0..8],
                .little,
            ) ^ std.mem.readInt(u64, second[count..][0..8], .little);
            if (difference != 0) return count + @ctz(difference) / 8;
            count += 8;
            if (bytes - count < 8) break;
        }
    }
    while (count < bytes and first[count] == second[count]) count += 1;
    return count;
}

/// Hash positions remain absolute across linked frame blocks. The first block selects the hash used
/// by every later lookup: raw input uses five bytes, while an initial dictionary uses four. The
/// frame resets this state before each new member; normalization is needed only near the u32 index
/// limit.
pub const RollingState = struct {
    ready: bool = false,
    end: u32 = 0,
    five_byte_hash: bool = false,
    compact_first: bool = false,
};

/// Reuses the match table across linked blocks without rebasing each block. After a short first
/// block, rebuilds the wide table once from its history. `contiguous_history` requires dictionary
/// and source slices of the same caller buffer.
pub fn encodeBlockRolling(
    source: []const u8,
    output: []u8,
    workspace: *EncoderWorkspace,
    dictionary: []const u8,
    contiguous_history: bool,
    state: *RollingState,
) Error![]u8 {
    const dict = dictionarySuffix(dictionary);
    if (!state.ready) {
        // Let the ordinary independent encoder initialize the first block, then remember the
        // absolute position origin and hash width needed to continue into later blocks.
        const result = try encodeBlock(source, output, workspace, .{ .dictionary = dict });
        state.* = .{
            .ready = true,
            .end = @intCast(dict.len + source.len),
            .five_byte_hash = dict.len == 0,
            .compact_first = dict.len == 0 and source.len < 65536,
        };
        return result;
    }
    if (state.compact_first) {
        // The first block used 16-bit direct positions in these same bytes; linked lookups require
        // 32-bit one-based absolute positions.
        @memset(&workspace.positions, 0);
        const base = state.end - @as(u32, @intCast(dict.len));
        if (dict.len >= 8) {
            for (0..dict.len - 7) |i| {
                workspace.positions[hashFivePosition(dict, i)] = base + @as(u32, @intCast(i)) + 1;
            }
        }
        state.compact_first = false;
    }
    if (state.end > 0x8000_0000 - source.len) {
        const shift = state.end - @min(state.end, maximum_distance);
        for (&workspace.positions) |*entry| {
            if (entry.* <= shift) entry.* = 0 else entry.* -= shift;
        }
        state.end -= shift;
    }
    const result = try encodeWithHistory(
        source,
        output,
        workspace,
        dict,
        state.end,
        contiguous_history,
        state.five_byte_hash,
    );
    state.end += @intCast(source.len);
    return result;
}

test "LZ4 rolling hash renormalization preserves linked block output" {
    const allocator = std.testing.allocator;
    const ordinary = try EncoderWorkspace.create(allocator);
    defer ordinary.destroy(allocator);
    const near_limit = try EncoderWorkspace.create(allocator);
    defer near_limit.destroy(allocator);
    var first: [128]u8 = undefined;
    for (&first, 0..) |*byte, i| byte.* = @intCast((i * 29) % 251);
    const second = first[32..112];
    var initial_wire: [256]u8 = undefined;
    var ordinary_state: RollingState = .{};
    _ = try encodeBlockRolling(&first, &initial_wire, ordinary, &.{}, false, &ordinary_state);

    near_limit.* = ordinary.*;
    var near_state = ordinary_state;
    const advance: u32 = 0x8000_0000 - near_state.end - @as(u32, second.len) + 1;
    near_state.end += advance;
    for (&near_limit.positions) |*entry| {
        if (entry.* != 0) entry.* += advance;
    }

    var ordinary_wire: [256]u8 = undefined;
    var near_wire: [256]u8 = undefined;
    const expected = try encodeBlockRolling(
        second,
        &ordinary_wire,
        ordinary,
        &first,
        false,
        &ordinary_state,
    );
    try std.testing.expect(expected.len < second.len / 2);
    const actual = try encodeBlockRolling(
        second,
        &near_wire,
        near_limit,
        &first,
        false,
        &near_state,
    );
    try std.testing.expectEqualSlices(u8, expected, actual);
    var restored: [second.len]u8 = undefined;
    _ = try decodeBlock(actual, &restored, .{ .dictionary = .{ .newer = &first } });
    try std.testing.expectEqualSlices(u8, second, &restored);
}

test "LZ4 rolling encoder rebuilds compact first-block history" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var first: [4096]u8 = undefined;
    var random: u64 = 0x1234_5678_9abc_def0;
    for (&first) |*byte| {
        random ^= random << 13;
        random ^= random >> 7;
        random ^= random << 17;
        byte.* = @truncate(random);
    }
    const second = first[512..1536];
    const first_storage = try allocator.alloc(u8, try blockEncodeBound(first.len));
    defer allocator.free(first_storage);
    const second_storage = try allocator.alloc(u8, try blockEncodeBound(second.len));
    defer allocator.free(second_storage);
    var rolling: RollingState = .{};
    _ = try encodeBlockRolling(&first, first_storage, workspace, &.{}, false, &rolling);
    try std.testing.expect(rolling.compact_first);
    const wire = try encodeBlockRolling(second, second_storage, workspace, &first, false, &rolling);
    try std.testing.expect(!rolling.compact_first);
    try std.testing.expect(wire.len < 64);
    var decoded: [second.len]u8 = undefined;
    _ = try decodeBlock(wire, &decoded, .{ .dictionary = .{ .newer = &first } });
    try std.testing.expectEqualSlices(u8, second, &decoded);
}

/// A fragment's final flag identifies the end of the block, not merely this fragment. Resubmit any
/// unconsumed suffix with the same flag. Consumed bytes and produced output can retire immediately
/// after step returns.
pub const Input = struct { bytes: []const u8, final: bool = false };

/// A blocking status or successful end of a raw block.
pub const DecodeStatus = enum {
    /// Supply more block bytes, preserving any unconsumed suffix and its final flag.
    need_input,
    /// Supply output capacity and resubmit any unconsumed input.
    need_output,
    /// The complete raw block was validated; any enclosing integrity check is still separate.
    complete,
};

/// Copied fragment counts. No source or output borrow is retained.
pub const DecodeProgress = struct { consumed: usize, produced: usize, status: DecodeStatus };

/// Per-block cumulative byte and work limits. Work charges accepted encoded bytes plus produced
/// decoded bytes once; copied initial history is excluded.
pub const DecodeLimits = struct {
    input_bytes: u64 = std.math.maxInt(u64),
    output_bytes: u64 = std.math.maxInt(u64),
    work_units: u64 = std.math.maxInt(u64),
};

/// Resumable raw policy; dictionary history is copied during reset or setDictionary.
pub const StreamDecodeOptions = struct {
    dictionary: []const u8 = &.{},
    limits: DecodeLimits = .{},
};

/// Resumption, storage and cumulative resource failures, in addition to raw format failures. Every
/// step error poisons the decoder until reset.
pub const DecodeError = Error || error{ NeedReset, InvalidState, LimitExceeded, CounterOverflow };

/// Resumable raw-block decoder. Reserve this value and a disjoint 64 KiB ring at their final
/// addresses, then reset before use. Only that ring is borrowed across calls. No caller fragment or
/// allocator is retained. Output remains unpublished until completion and any enclosing integrity
/// check succeeds.
pub const Decoder = struct {
    history: *[65536]u8,
    write_position: usize,
    available: usize,
    phase: Phase,
    token: u8,
    remaining: usize,
    literals: usize,
    distance: usize,
    last_match: ?u64,
    final_input: bool,
    limits: DecodeLimits,
    input_bytes: u64,
    output_bytes: u64,
    work_units: u64,

    const Phase = enum {
        token,
        literal_length,
        literals,
        after_literals,
        offset_high,
        match_length,
        match,
        done,
        failed,
    };

    /// Starts a block, optionally copying initial dictionary bytes. History is initialized as
    /// dictionary/output bytes arrive; the options and dictionary may retire on return.
    pub fn reset(
        self: *Decoder,
        history: *[65536]u8,
        options: StreamDecodeOptions,
    ) DecodeError!void {
        const limits = options.limits;
        if (try overlaps(std.mem.asBytes(self), history)) return error.Aliasing;
        const dictionary = dictionarySuffix(options.dictionary);
        if (try overlaps(
            dictionary,
            history,
        ) or try overlaps(dictionary, std.mem.asBytes(self))) return error.Aliasing;
        self.* = .{
            .history = history,
            .write_position = 0,
            .available = 0,
            .phase = .token,
            .token = 0,
            .remaining = 0,
            .literals = 0,
            .distance = 0,
            .last_match = null,
            .final_input = false,
            .limits = limits,
            .input_bytes = 0,
            .output_bytes = 0,
            .work_units = 0,
        };
        if (options.dictionary.len != 0) try self.setDictionary(options.dictionary);
    }

    /// Copies an initial dictionary suffix before accepting block input. Replaces existing history.
    /// Its source may retire on return.
    pub fn setDictionary(self: *Decoder, dictionary: []const u8) DecodeError!void {
        if (self.phase == .failed) return error.NeedReset;
        if (self.phase != .token or self.input_bytes != 0) return error.InvalidState;
        const bytes = dictionarySuffix(dictionary);
        if (try overlaps(bytes, self.history)) return error.Aliasing;
        if (try overlaps(bytes, std.mem.asBytes(self))) return error.Aliasing;
        self.write_position = 0;
        self.available = 0;
        self.remember(bytes);
    }

    /// Starts another block after completion or before any block input. Keep history for linked
    /// blocks; otherwise clear it and optionally set another dictionary. Per-block counts/limits
    /// restart; no allocation occurs.
    pub fn nextBlock(self: *Decoder, retain_history: bool) DecodeError!void {
        if (self.phase == .failed) return error.NeedReset;
        if (self.phase != .done and !(self.phase == .token and self.input_bytes == 0))
            return error.InvalidState;
        self.phase = .token;
        self.remaining = 0;
        self.literals = 0;
        self.last_match = null;
        self.final_input = false;
        self.input_bytes = 0;
        self.output_bytes = 0;
        self.work_units = 0;
        if (!retain_history) {
            self.write_position = 0;
            self.available = 0;
        }
    }

    /// Adds already decoded bytes between compressed blocks, for a container's uncompressed blocks.
    /// Updates history only, without charging raw-block counts. The container owns those bytes'
    /// bounds and resource accounting.
    pub fn appendHistory(self: *Decoder, bytes: []const u8) DecodeError!void {
        if (self.phase == .failed) return error.NeedReset;
        if (self.phase != .done and !(self.phase == .token and self.input_bytes == 0))
            return error.InvalidState;
        if (try overlaps(bytes, self.history)) return error.Aliasing;
        if (try overlaps(bytes, std.mem.asBytes(self))) return error.Aliasing;
        self.remember(bytes);
    }

    /// Advances one block. No read/write exceeds the supplied exact spans. Repeated completion
    /// returns zero counts; every failure requires reset.
    pub fn step(self: *Decoder, input: Input, output: []u8) DecodeError!DecodeProgress {
        if (self.phase == .failed) return error.NeedReset;
        errdefer self.phase = .failed;
        const state = std.mem.asBytes(self);
        if (try overlaps(input.bytes, output)) return error.Aliasing;
        if (try overlaps(input.bytes, self.history) or try overlaps(output, self.history)) {
            return error.Aliasing;
        }
        if (try overlaps(input.bytes, state) or try overlaps(output, state)) return error.Aliasing;
        if (self.final_input and input.bytes.len != 0) return error.InvalidState;

        // A container can admit a complete bounded block here. Keep ring maintenance and suspension
        // out of its token loop, then retain only the final history suffix. Smaller fragments use
        // the state machine.
        const complete_block = blk: {
            if (self.phase != .token or self.input_bytes != 0 or !input.final) break :blk false;
            if (output.len < self.limits.output_bytes) break :blk false;
            if (input.bytes.len > self.limits.input_bytes) break :blk false;
            if (self.limits.work_units < input.bytes.len) break :blk false;
            break :blk self.limits.output_bytes <= self.limits.work_units - input.bytes.len;
        };
        if (complete_block) {
            const start = (self.write_position + 65536 - self.available) & 65535;
            const first = @min(self.available, 65536 - start);
            const recovered = decodeBlock(
                input.bytes,
                output[0..@intCast(self.limits.output_bytes)],
                .{
                    .dictionary = .{
                        .older = self.history[start..][0..first],
                        .newer = self.history[0 .. self.available - first],
                    },
                    .output_size = .bounded,
                },
            ) catch |err| {
                @branchHint(.unlikely);
                return if (err == error.OutputTooSmall) error.LimitExceeded else err;
            };
            const count = recovered.produced;
            try self.charge(input.bytes.len, count);
            self.remember(output[0..count]);
            self.final_input = true;
            self.phase = .done;
            return .{ .consumed = input.bytes.len, .produced = count, .status = .complete };
        }

        // Each phase consumes only the bytes it can finish with the current fragment. The decoder
        // keeps parsed token state between calls, but copies produced bytes into the 64 KiB ring so
        // later matches remain valid after the caller retires an output fragment.
        var read: usize = 0;
        var written: usize = 0;
        while (true) switch (self.phase) {
            .token => {
                // Batch complete sequences, including retained ring history. Splitting the
                // remaining work admission between input and output makes the batch safe before
                // touching any bytes; exact accounting and one ring update follow the batch.
                const half_work = (self.limits.work_units - self.work_units) / 2;
                const input_budget = self.limits.input_bytes - self.input_bytes;
                const output_budget = self.limits.output_bytes - self.output_bytes;
                const admitted_input: usize = @intCast(
                    @min(input.bytes.len - read, input_budget, half_work),
                );
                const admitted_output: usize = @intCast(
                    @min(output.len - written, output_budget, half_work),
                );
                const input_end = read + admitted_input;
                const output_end = written + admitted_output;
                const old_read = read;
                const old_written = written;
                var sequence_start: usize = 0;
                while (@call(
                    .always_inline,
                    bulkSequence,
                    .{
                        true,
                        input.bytes[0..input_end],
                        output[0..output_end],
                        &read,
                        &written,
                        &sequence_start,
                        self,
                        old_written,
                    },
                )) {}
                if (read != old_read) {
                    self.last_match = self.output_bytes + sequence_start - old_written;
                    try self.charge(read - old_read, written - old_written);
                    self.remember(output[old_written..written]);
                    continue;
                }
                if (read == input.bytes.len) return self.blocked(input, read, written, .need_input);
                self.token = try self.take(input.bytes, &read);
                self.literals = self.token >> 4;
                self.remaining = self.literals;
                self.phase = if (self.remaining == 15) .literal_length else .literals;
            },
            .literal_length, .match_length => {
                if (read == input.bytes.len) return self.blocked(input, read, written, .need_input);
                const byte = try self.take(input.bytes, &read);
                self.remaining = std.math.add(
                    usize,
                    self.remaining,
                    byte,
                ) catch return error.SizeOverflow;
                if (self.phase == .literal_length) self.literals = self.remaining;
                if (byte != 255) {
                    self.phase = if (self.phase == .literal_length) .literals else .match;
                }
            },
            .literals => {
                if (self.remaining == 0) {
                    self.phase = .after_literals;
                    continue;
                }
                if (read == input.bytes.len) return self.blocked(input, read, written, .need_input);
                if (written == output.len) return self.blocked(input, read, written, .need_output);
                const count = @min(self.remaining, input.bytes.len - read, output.len - written);
                try self.charge(count, count);
                @memcpy(output[written..][0..count], input.bytes[read..][0..count]);
                self.remember(output[written..][0..count]);
                read += count;
                written += count;
                self.remaining -= count;
            },
            .after_literals => {
                if (read == input.bytes.len) {
                    if (!self.final_input and !input.final) {
                        return self.blocked(input, read, written, .need_input);
                    }
                    if (self.last_match) |start| {
                        if (self.literals < 5 or self.output_bytes - start < 12)
                            return error.InvalidTermination;
                    }
                    self.phase = .done;
                    return self.blocked(input, read, written, .complete);
                }
                self.distance = try self.take(input.bytes, &read);
                self.phase = .offset_high;
            },
            .offset_high => {
                if (read == input.bytes.len) return self.blocked(input, read, written, .need_input);
                self.distance |= @as(usize, try self.take(input.bytes, &read)) << 8;
                if (self.distance == 0 or self.distance > self.available)
                    return error.InvalidOffset;
                self.remaining = @as(usize, self.token & 15) + 4;
                self.last_match = self.output_bytes;
                self.phase = if ((self.token & 15) == 15) .match_length else .match;
            },
            .match => {
                if (self.remaining == 0) {
                    self.phase = .token;
                    continue;
                }
                if (written == output.len) return self.blocked(input, read, written, .need_output);
                var count = @min(self.remaining, output.len - written);
                if (self.distance <= written) {
                    try self.charge(0, count);
                    @call(.always_inline, copyMatch, .{ output, written, self.distance, count });
                } else {
                    const start = (self.write_position + 65536 - self.distance) & 65535;
                    count = @min(count, self.distance, 65536 - start);
                    try self.charge(0, count);
                    @memcpy(output[written..][0..count], self.history[start..][0..count]);
                }
                self.remember(output[written..][0..count]);
                written += count;
                self.remaining -= count;
            },
            .done => return self.blocked(input, read, written, .complete),
            .failed => unreachable,
        };
    }

    fn take(self: *Decoder, bytes: []const u8, read: *usize) DecodeError!u8 {
        try self.charge(1, 0);
        const byte = bytes[read.*];
        read.* += 1;
        return byte;
    }

    fn charge(self: *Decoder, consumed: usize, produced: usize) DecodeError!void {
        const input_bytes = std.math.add(
            u64,
            self.input_bytes,
            consumed,
        ) catch return error.CounterOverflow;
        const output_bytes = std.math.add(
            u64,
            self.output_bytes,
            produced,
        ) catch return error.CounterOverflow;
        const amount = std.math.add(u64, consumed, produced) catch return error.CounterOverflow;
        const work_units = std.math.add(
            u64,
            self.work_units,
            amount,
        ) catch return error.CounterOverflow;
        if (input_bytes > self.limits.input_bytes) return error.LimitExceeded;
        if (output_bytes > self.limits.output_bytes or work_units > self.limits.work_units)
            return error.LimitExceeded;

        self.input_bytes = input_bytes;
        self.output_bytes = output_bytes;
        self.work_units = work_units;
    }

    fn remember(self: *Decoder, bytes: []const u8) void {
        const kept = bytes[bytes.len - @min(bytes.len, 65536) ..];
        const end = (self.write_position + (bytes.len & 65535)) & 65535;
        const start = (end + 65536 - kept.len) & 65535;
        const first = @min(kept.len, 65536 - start);
        @memcpy(self.history[start..][0..first], kept[0..first]);
        @memcpy(self.history[0 .. kept.len - first], kept[first..]);
        self.write_position = end;
        self.available = @min(maximum_distance, self.available +| bytes.len);
    }

    fn blocked(
        self: *Decoder,
        input: Input,
        read: usize,
        written: usize,
        status: DecodeStatus,
    ) DecodeError!DecodeProgress {
        if (input.final and read == input.bytes.len) self.final_input = true;
        if (status == .need_input and self.final_input) return error.Truncated;
        return .{ .consumed = read, .produced = written, .status = status };
    }
};

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
fn bulkSequence(
    comptime with_ring: bool,
    source: []const u8,
    output: []u8,
    read: *usize,
    written: *usize,
    last_match: *usize,
    decoder: ?*const Decoder,
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
        if (prior_output + distance - begin > decoder.?.available) return false;
    }
    if (with_ring and literals > 32) {
        @memcpy(output[written.*..][0..literals], source[literal_position..][0..literals]);
    } else if (literals != 0) {
        copySmall(output[written.*..], source[literal_position..], literals);
    }
    var copied: usize = 0;
    if (with_ring and distance > begin) {
        const state = decoder.?;
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
            const decoded = try decodeBlock(wire[0..cursor], &output, .{ .output_size = .bounded });
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
                const result = try decodeBlockWithPrefix(wire[0..cursor], &actual, 64);
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
    try std.testing.expectError(error.Truncated, decodeBlock(&wire, output[0..32], .{}));
    try std.testing.expectEqual(@as(u8, 0xa5), output[32]);

    @memset(&output, 0xa5);
    try std.testing.expectError(error.OutputTooSmall, decodeBlock(&wire, output[0..31], .{}));
    try std.testing.expectEqual(@as(u8, 0xa5), output[31]);

    @memset(&output, 0xa5);
    try std.testing.expectError(error.Truncated, decodeBlock(wire[0..16], output[0..32], .{}));
    try std.testing.expectEqual(@as(u8, 0xa5), output[32]);

    const chained = [_]u8{
        0x9e, '1', '2', '3', '4', '5', '6', '7', '8', '9', 8, 0, 0x50, 'T', 'A', 'I', 'L', '!',
    };
    @memset(&output, 0xa5);
    const result = try decodeBlock(&chained, output[0..32], .{});
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
    const result = try decodeBlock(&wire, &output, .{ .output_size = .bounded });
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
    const ordinary = try decodeBlock(
        &wire,
        expected[32..94],
        .{ .dictionary = .{ .newer = expected[0..32] }, .output_size = .bounded },
    );
    const contiguous = try decodeBlockWithPrefix(&wire, actual[0..94], 32);
    try std.testing.expectEqual(@as(usize, 62), ordinary.produced);
    try std.testing.expectEqual(ordinary.produced, contiguous.produced);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
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

fn copyMatch(output: []u8, begin: usize, distance: usize, count: usize) void {
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

fn hashFourPosition(source: []const u8, position: usize) usize {
    const word = std.mem.readInt(u32, source[position..][0..4], .little);
    return (word *% 2654435761) >> 20;
}

fn hashFiveCompact(source: []const u8, position: usize) usize {
    const word = std.mem.readInt(u64, source[position..][0..8], .little);
    return ((word << 24) *% 889523592379) >> 51;
}

fn hashFivePosition(source: []const u8, position: usize) usize {
    // The native-width load needs eight input bytes; search admission and post-match updates leave
    // that margin. The shift uses only the low five bytes for the table index.
    const word = std.mem.readInt(u64, source[position..][0..8], .little);
    return ((word << 24) *% 889523592379) >> 52;
}

inline fn searchStep(attempts: usize) usize {
    // Matches reset the count to 64. A long miss run needs fewer hash probes.
    const extra = if (attempts >= 128) (attempts - 128) >> 3 else @as(usize, 0);
    return (attempts >> 6) + extra;
}

fn commonBytes(
    comptime wide_tail: bool,
    source: []const u8,
    first: usize,
    second: usize,
    end: usize,
) usize {
    // Return the equal prefix without reading beyond `end`. Wide raw blocks can use word loads
    // while preserving five final literals; compact blocks use a guarded wide tail and exact
    // smaller comparisons for the remainder.
    var count: usize = 0;
    if (wide_tail) {
        while (end - first - count >= 8) : (count += 8) {
            const first_word = std.mem.readInt(u64, source[first + count ..][0..8], .little);
            const second_word = std.mem.readInt(u64, source[second + count ..][0..8], .little);
            const difference = first_word ^ second_word;
            if (difference != 0) return count + @ctz(difference) / 8;
        }
    } else if (end - first >= 8) {
        while (true) {
            const first_word = std.mem.readInt(u64, source[first + count ..][0..8], .little);
            const second_word = std.mem.readInt(u64, source[second + count ..][0..8], .little);
            const difference = first_word ^ second_word;
            if (difference != 0) return count + @ctz(difference) / 8;
            count += 8;
            if (end - first - count < 8) break;
        }
    }
    if (wide_tail and count >= 64 and end - first - count >= 3) {
        // Five final literals leave room for a word load three bytes before the match limit.
        const difference = std.mem.readInt(
            u64,
            source[first + count ..][0..8],
            .little,
        ) ^ std.mem.readInt(u64, source[second + count ..][0..8], .little);
        return count + @min(@as(usize, @ctz(difference) / 8), end - first - count);
    }
    if (wide_tail and end - first - count >= 4 and std.mem.readInt(
        u32,
        source[first + count ..][0..4],
        .little,
    ) == std.mem.readInt(u32, source[second + count ..][0..4], .little)) count += 4;
    if (wide_tail and end - first - count >= 2 and std.mem.readInt(
        u16,
        source[first + count ..][0..2],
        .little,
    ) == std.mem.readInt(u16, source[second + count ..][0..2], .little)) count += 2;
    if (wide_tail) {
        if (first + count < end and source[first + count] == source[second + count]) count += 1;
    } else {
        while (first + count < end and source[first + count] == source[second + count]) count += 1;
    }
    return count;
}

fn dictionarySuffix(bytes: []const u8) []const u8 {
    return bytes[bytes.len - @min(bytes.len, maximum_distance) ..];
}

fn historyByte(dict: []const u8, source: []const u8, position: usize) u8 {
    return if (position < dict.len) dict[position] else source[position - dict.len];
}

fn equalFour(dict: []const u8, source: []const u8, candidate: usize, position: usize) bool {
    const word = source[position..][0..4];
    if (candidate >= dict.len) {
        const prior = source[candidate - dict.len ..][0..4];
        return std.mem.eql(u8, prior, word);
    }
    if (dict.len - candidate >= 4) return std.mem.eql(u8, dict[candidate..][0..4], word);

    inline for (0..4) |i| {
        if (historyByte(dict, source, candidate + i) != source[position + i]) return false;
    }
    return true;
}

// Every caller reserves blockEncodeBound for the complete uncompressed input before writing. The
// encoded representation is no larger than that bound, so individual writes need no additional
// capacity checks.
const Writer = struct {
    bytes: []u8,
    cursor: usize = 0,

    fn byte(self: *Writer, value: u8) void {
        self.bytes[self.cursor] = value;
        self.cursor += 1;
    }

    fn extension(self: *Writer, value: usize) void {
        var remaining = value;
        while (remaining >= 255) : (remaining -= 255) self.byte(255);
        self.byte(@intCast(remaining));
    }

    fn literal(self: *Writer, bytes: []const u8) void {
        @memcpy(self.bytes[self.cursor..][0..bytes.len], bytes);
        self.cursor += bytes.len;
    }

    fn sequence(self: *Writer, literals: []const u8, distance: u16, match: usize) void {
        self.writeSequence(false, literals, literals.len, distance, match);
    }

    fn sequenceWild(
        self: *Writer,
        source: []const u8,
        literal_count: usize,
        distance: u16,
        match: usize,
    ) void {
        // Search leaves twelve input bytes. Even a zero-literal match is followed by its offset and
        // a final token with five literals, so later writes replace the speculative suffix.
        self.writeSequence(true, source, literal_count, distance, match);
    }

    fn sequenceNoLiterals(self: *Writer, distance: u16, match: usize) void {
        const field = match - 4;
        self.byte(@intCast(@min(field, 15)));
        self.byte(@truncate(distance));
        self.byte(@intCast(distance >> 8));
        if (field >= 15) self.extension(field - 15);
    }

    fn writeSequence(
        self: *Writer,
        comptime wild: bool,
        source: []const u8,
        literal_count: usize,
        distance: u16,
        match: usize,
    ) void {
        const field = match - 4;
        const literal_bits: u8 = @as(u8, @intCast(@min(literal_count, 15))) << 4;
        const match_bits: u8 = @intCast(@min(field, 15));
        self.byte(literal_bits | match_bits);
        if (literal_count >= 15) self.extension(literal_count - 15);
        if (wild) {
            var copied: usize = 0;
            while (true) : (copied += 8) {
                @memcpy(self.bytes[self.cursor + copied ..][0..8], source[copied..][0..8]);
                if (copied + 8 >= literal_count) break;
            }
            self.cursor += literal_count;
        } else self.literal(source[0..literal_count]);
        self.byte(@truncate(distance));
        self.byte(@intCast(distance >> 8));
        if (field >= 15) self.extension(field - 15);
    }

    fn final(self: *Writer, literals: []const u8) void {
        self.byte(@as(u8, @intCast(@min(literals.len, 15))) << 4);
        if (literals.len >= 15) self.extension(literals.len - 15);
        self.literal(literals);
    }
};

fn overlaps(first: []const u8, second: []const u8) Error!bool {
    if (first.len == 0 or second.len == 0) return false;
    const a = @intFromPtr(first.ptr);
    const b = @intFromPtr(second.ptr);
    const end_a = std.math.add(usize, a, first.len) catch return error.SizeOverflow;
    const end_b = std.math.add(usize, b, second.len) catch return error.SizeOverflow;
    return a < end_b and b < end_a;
}

// Independent raw blocks produced by upstream LZ4 1.10.0
// (ebb370ca83af193212df4dcbadcc5d87bc0de2f0). Reference encoder source is BSD-2-Clause:
// https://github.com/lz4/lz4/blob/ebb370ca83af193212df4dcbadcc5d87bc0de2f0/lib/LICENSE Source bytes
// are zero-filled or input[i] = i % 251; no native encoder constructs expectations.

// Frozen reference output and independently described source bytes.
const ReferenceVector = struct {
    // Complete encoded raw block.
    encoded: []const u8,
    // Exact recovered byte count.
    size: usize,
    // Zero-filled when true, otherwise input[i] = i % 251.
    zeros: bool,
};

// Pinned-reference blocks retain literal/match extension and long overlapping-history cases.
const long_zero_block = blk: {
    const prefix = [_]u8{ 0x1f, 0x00, 0x01, 0x00 };
    const extensions: [256]u8 = @splat(0xff);
    const suffix = [_]u8{ 0xe7, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00 };
    break :blk prefix ++ extensions ++ suffix;
};

const reference_vectors = [_]ReferenceVector{
    .{ .size = 0, .zeros = true, .encoded = &.{0x00} },
    .{
        .size = 1024,
        .zeros = true,
        .encoded = &.{
            0x1f, 0x00, 0x01, 0x00, 0xff, 0xff, 0xff, 0xea,
            0x50, 0x00, 0x00, 0x00, 0x00, 0x00,
        },
    },
    .{ .size = 65536, .zeros = true, .encoded = &long_zero_block },
    .{
        .size = 8192,
        .zeros = false,
        .encoded = &.{
            0xff, 0xec, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
            0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d,
            0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
            0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d,
            0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25,
            0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d,
            0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
            0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d,
            0x3e, 0x3f, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45,
            0x46, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d,
            0x4e, 0x4f, 0x50, 0x51, 0x52, 0x53, 0x54, 0x55,
            0x56, 0x57, 0x58, 0x59, 0x5a, 0x5b, 0x5c, 0x5d,
            0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65,
            0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d,
            0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75,
            0x76, 0x77, 0x78, 0x79, 0x7a, 0x7b, 0x7c, 0x7d,
            0x7e, 0x7f, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85,
            0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d,
            0x8e, 0x8f, 0x90, 0x91, 0x92, 0x93, 0x94, 0x95,
            0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d,
            0x9e, 0x9f, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5,
            0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad,
            0xae, 0xaf, 0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5,
            0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbb, 0xbc, 0xbd,
            0xbe, 0xbf, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5,
            0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xcb, 0xcc, 0xcd,
            0xce, 0xcf, 0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5,
            0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xdb, 0xdc, 0xdd,
            0xde, 0xdf, 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5,
            0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xeb, 0xec, 0xed,
            0xee, 0xef, 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5,
            0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xfb, 0x00, 0xff,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0c, 0x50,
            0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
        },
    },
};

test "LZ4 short sequences match field oracles and preserve unused bounded output" {
    var wire: [512]u8 = undefined;
    var expected: [256]u8 = undefined;
    var output: [256]u8 = undefined;
    var history: [65536]u8 = undefined;
    var prefix: [64]u8 = undefined;
    for (&prefix, 0..) |*byte, i| byte.* = @intCast(i);
    for (0..15) |literals| {
        for (4..19) |match| {
            for ([_]usize{ 1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32 }) |distance| {
                var writer: Writer = .{ .bytes = &wire };
                writer.sequence(&prefix, 1, 7);
                @memcpy(expected[0..64], &prefix);
                @memset(expected[64..71], 63);
                var count: usize = 71;
                for (0..4) |_| {
                    writer.sequence(prefix[0..literals], @intCast(distance), match);
                    @memcpy(expected[count..][0..literals], prefix[0..literals]);
                    count += literals;
                    for (0..match) |_| {
                        expected[count] = expected[count - distance];
                        count += 1;
                    }
                }
                writer.sequence(&.{}, 1, 7);
                @memset(expected[count..][0..7], expected[count - 1]);
                count += 7;
                writer.final("TAIL!");
                @memcpy(expected[count..][0..5], "TAIL!");
                count += 5;
                const block = wire[0..writer.cursor];
                _ = try decodeBlock(block, output[0..count], .{});
                try std.testing.expectEqualSlices(u8, expected[0..count], output[0..count]);
                @memset(&output, 0xa7);
                try std.testing.expectEqual(
                    count,
                    (try decodeBlock(
                        block,
                        &output,
                        .{ .dictionary = .{}, .output_size = .bounded },
                    )).produced,
                );
                try std.testing.expectEqualSlices(u8, expected[0..count], output[0..count]);
                try std.testing.expect(std.mem.allEqual(u8, output[count..], 0xa7));
                var decoder: Decoder = undefined;
                try decoder.reset(&history, .{ .limits = .{} });
                var read: usize = 0;
                var written: usize = 0;
                while (true) {
                    const end = @min(block.len, read + 47);
                    const part = try decoder.step(
                        .{ .bytes = block[read..end], .final = end == block.len },
                        output[written..@min(count, written + 63)],
                    );
                    read += part.consumed;
                    written += part.produced;
                    if (part.status == .complete) break;
                    try std.testing.expect(part.consumed != 0 or part.produced != 0);
                }
                try std.testing.expectEqualSlices(u8, expected[0..count], output[0..count]);
            }
        }
    }
}

test "LZ4 dictionary views cross both spans and grow overlapping matches" {
    // Field-level oracle: match distance seven, match length nineteen, followed by five literals.
    // It must start in older, cross newer, then copy output.
    const block = [_]u8{ 0x0f, 0x07, 0x00, 0x00, 0x50, 'T', 'A', 'I', 'L', '!' };
    var output: [40]u8 = @splat(0xa7);
    const count = (try decodeBlock(
        &block,
        &output,
        .{ .dictionary = .{ .older = "ignore:ABCD", .newer = "EFG" }, .output_size = .bounded },
    )).produced;
    try std.testing.expectEqual(24, count);
    try std.testing.expectEqualStrings("ABCDEFGABCDEFGABCDETAIL!", output[0..count]);
    try std.testing.expect(std.mem.allEqual(u8, output[count..], 0xa7));
    try std.testing.expectError(
        error.InvalidOffset,
        decodeBlock(
            &block,
            &output,
            .{ .dictionary = .{ .newer = "EFG" }, .output_size = .bounded },
        ),
    );
    _ = try decodeBlock(&block, output[0..count], .{ .dictionary = .{ .newer = "ABCDEFG" } });
    try std.testing.expectError(
        error.OutputSizeMismatch,
        decodeBlock(&block, &output, .{ .dictionary = .{ .newer = "ABCDEFG" } }),
    );
}

test "LZ4 dictionary encoder uses initial matches and preserves independent bytes" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const dictionary = try allocator.alloc(u8, 70000);
    defer allocator.free(dictionary);
    var random: std.Random.DefaultPrng = .init(91);
    random.random().bytes(dictionary);
    var encoded: [4096]u8 = undefined;
    var independent: [4096]u8 = undefined;
    var output: [1024]u8 = undefined;
    const source = dictionary[dictionary.len - output.len ..];
    const block = try encodeBlock(source, &encoded, workspace, .{ .dictionary = dictionary });
    try std.testing.expect(block.len < 32);
    _ = try decodeBlock(block, &output, .{ .dictionary = .{ .newer = dictionary } });
    try std.testing.expectEqualSlices(u8, source, &output);
    const ordinary = try encodeBlock(source, &independent, workspace, .{});
    const empty_dict = try encodeBlock(source, &encoded, workspace, .{ .dictionary = &.{} });
    try std.testing.expectEqualSlices(u8, ordinary, empty_dict);
}

test "LZ4 streaming retires fragments through extension and history wrap boundaries" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([65536]u8);
    defer allocator.destroy(history);
    const source = try allocator.alloc(u8, 140003);
    defer allocator.free(source);
    for (source, 0..) |*byte, i| byte.* = @intCast((i / 17) % 251);
    const encoded = try allocator.alloc(u8, try blockEncodeBound(source.len));
    defer allocator.free(encoded);
    const block = try encodeBlock(source, encoded, workspace, .{});
    const recovered = try allocator.alloc(u8, source.len);
    defer allocator.free(recovered);
    for ([_]usize{ 1, 2, 7, 63, 65535, 65536, 65537, 200000 }) |chunk| {
        var decoder: Decoder = undefined;
        try decoder.reset(history, .{ .limits = .{} });
        var read: usize = 0;
        var written: usize = 0;
        var fragment: [257]u8 = undefined;
        var temporary: [257]u8 = undefined;
        while (true) {
            const in_count = @min(chunk, block.len - read, fragment.len);
            @memcpy(fragment[0..in_count], block[read..][0..in_count]);
            const part = try decoder.step(
                .{ .bytes = fragment[0..in_count], .final = read + in_count == block.len },
                temporary[0..@min(chunk, temporary.len, source.len - written)],
            );
            @memcpy(recovered[written..][0..part.produced], temporary[0..part.produced]);
            @memset(&fragment, 0xa7);
            @memset(&temporary, 0xa7);
            read += part.consumed;
            written += part.produced;
            if (part.status == .complete) break;
            try std.testing.expect(part.consumed != 0 or part.produced != 0);
        }
        try std.testing.expectEqual(block.len, read);
        try std.testing.expectEqualSlices(u8, source, recovered);
        try std.testing.expectEqual(block.len + source.len, decoder.work_units);
        try decoder.nextBlock(true);
        const linked = [_]u8{ 0x03, 0x01, 0x00, 0x50, 1, 2, 3, 4, 5 };
        var tail: [12]u8 = undefined;
        const part = try decoder.step(.{ .bytes = &linked, .final = true }, &tail);
        try std.testing.expectEqual(DecodeStatus.complete, part.status);
        try std.testing.expect(std.mem.allEqual(u8, tail[0..7], source[source.len - 1]));
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, tail[7..]);
    }
}

test "LZ4 streaming finality limits poisoning aliasing and counter overflow" {
    var history: [65536]u8 = undefined;
    var decoder: Decoder = undefined;
    var output: [12]u8 = undefined;
    const block = [_]u8{ 0x03, 0x01, 0x00, 0x50, 1, 2, 3, 4, 5 };
    try decoder.reset(
        &history,
        .{
            .limits = .{
                .input_bytes = block.len,
                .output_bytes = output.len,
                .work_units = block.len + output.len,
            },
        },
    );
    try decoder.setDictionary("x");
    _ = try decoder.step(.{ .bytes = &block, .final = true }, &output);
    try decoder.reset(&history, .{ .limits = .{ .output_bytes = output.len - 1 } });
    try decoder.setDictionary("x");
    try std.testing.expectError(
        error.LimitExceeded,
        decoder.step(.{ .bytes = &block, .final = true }, &output),
    );
    try std.testing.expectError(
        error.NeedReset,
        decoder.step(.{ .bytes = &.{}, .final = true }, &output),
    );
    try decoder.reset(&history, .{ .limits = .{} });
    try std.testing.expectError(
        error.Truncated,
        decoder.step(.{ .bytes = &.{0xf0}, .final = true }, &output),
    );
    try decoder.reset(&history, .{ .limits = .{} });
    try std.testing.expectError(error.Aliasing, decoder.step(.{ .bytes = history[0..1] }, &output));
    try decoder.reset(&history, .{ .limits = .{} });
    decoder.input_bytes = std.math.maxInt(u64);
    try std.testing.expectError(error.CounterOverflow, decoder.step(.{ .bytes = &.{0} }, &output));
    try decoder.reset(&history, .{ .limits = .{} });
    try std.testing.expectEqual(
        DecodeStatus.need_input,
        (try decoder.step(.{ .bytes = &.{} }, &.{})).status,
    );
    try std.testing.expectEqual(
        DecodeStatus.complete,
        (try decoder.step(.{ .bytes = &.{0}, .final = true }, &.{})).status,
    );
}

test "LZ4 exact literal extensions empty blocks and independent matches" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
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
        const encoded = try allocator.alloc(u8, try blockEncodeBound(size));
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
            const block = try encodeBlock(input, encoded, workspace, .{});
            _ = try decodeBlock(block, output, .{});
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
        const encoded = try allocator.alloc(u8, try blockEncodeBound(total));
        defer allocator.free(encoded);
        const history = try allocator.alloc(u8, literals);
        defer allocator.free(history);
        for (history, 0..) |*b, i| b.* = @intCast(i % 251);
        var writer: Writer = .{ .bytes = encoded };
        writer.sequence(history, @intCast(distance), match);
        writer.final("TAIL!");
        const guarded = try allocator.alloc(u8, total + 32);
        defer allocator.free(guarded);
        @memset(guarded, 0xa7);
        const output = guarded[16..][0..total];
        _ = try decodeBlock(encoded[0..writer.cursor], output, .{});
        for (output[0 .. literals + match], 0..) |byte, i| {
            try std.testing.expectEqual(history[i % distance], byte);
        }
        try std.testing.expectEqualStrings("TAIL!", output[literals + match ..]);
        try std.testing.expect(std.mem.allEqual(u8, guarded[0..16], 0xa7));
        try std.testing.expect(std.mem.allEqual(u8, guarded[16 + total ..], 0xa7));
        for (0..writer.cursor) |cut| {
            @memset(guarded[0..16], 0xa7);
            @memset(guarded[16 + total ..], 0xa7);
            if (decodeBlock(encoded[0..cut], output, .{})) |_| {
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
            const encoded = try allocator.alloc(u8, try blockEncodeBound(total));
            defer allocator.free(encoded);
            const history = try allocator.alloc(u8, distance);
            defer allocator.free(history);
            for (history, 0..) |*byte, i| byte.* = @intCast((i * 29) % 251);
            var writer: Writer = .{ .bytes = encoded };
            writer.sequence(history, @intCast(distance), match);
            writer.final("TAIL!");

            const guarded = try allocator.alloc(u8, total + 32);
            defer allocator.free(guarded);
            @memset(guarded, 0xa7);
            const output = guarded[16..][0..total];
            _ = try decodeBlock(encoded[0..writer.cursor], output, .{});
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
    try std.testing.expectError(error.Truncated, decodeBlock(&.{}, output, .{}));
    try std.testing.expectError(error.Truncated, decodeBlock(&.{ 0xf0, 255 }, output, .{}));
    try std.testing.expectError(error.InvalidOffset, decodeBlock(&.{ 0, 0, 0 }, output, .{}));
    try std.testing.expectError(error.InvalidOffset, decodeBlock(&.{ 0, 1, 0 }, output, .{}));
    try std.testing.expectError(error.Truncated, decodeBlock(&.{ 0x10, 'a', 1 }, output, .{}));
    try std.testing.expectError(
        error.Truncated,
        decodeBlock(&.{ 0x1f, 'a', 1, 0, 255 }, output, .{}),
    );
    try std.testing.expectError(
        error.InvalidTermination,
        decodeBlock(&.{ 0x10, 'a', 1, 0, 0 }, output[0..5], .{}),
    );
    try std.testing.expectError(
        error.InvalidTermination,
        decodeBlock(&.{ 0x10, 'a', 1, 0, 0x50, 1, 2, 3, 4, 5 }, output[0..10], .{}),
    );
    try std.testing.expectError(error.OutputSizeMismatch, decodeBlock(&.{0}, output[0..1], .{}));
    try std.testing.expectError(
        error.OutputTooSmall,
        decodeBlock(&.{ 0x10, 'a' }, output[0..0], .{}),
    );
    try std.testing.expectError(error.Aliasing, decodeBlock(output[0..1], output[0..1], .{}));
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    try std.testing.expectError(
        error.OutputTooSmall,
        encodeBlock("abc", output[0..3], workspace, .{}),
    );
    try std.testing.expectError(error.Aliasing, encodeBlock(output[0..4], output, workspace, .{}));
    const scratch = std.mem.asBytes(workspace);
    try std.testing.expectError(error.Aliasing, encodeBlock(scratch[0..4], output, workspace, .{}));
    try std.testing.expectError(error.InputTooLarge, blockEncodeBound(maximum_input_bytes + 1));
    const block = try encodeBlock("abc", output, workspace, .{});
    var decoded: [3]u8 = undefined;
    _ = try decodeBlock(block, &decoded, .{});
    try std.testing.expectEqualStrings("abc", &decoded);
}

test "LZ4 decodes frozen independent upstream blocks with exact recovery" {
    const allocator = std.testing.allocator;
    for (reference_vectors) |vector| {
        const output = try allocator.alloc(u8, vector.size);
        defer allocator.free(output);
        _ = try decodeBlock(vector.encoded, output, .{});
        for (output, 0..) |byte, i| {
            const expected: u8 = if (vector.zeros) 0 else @intCast(i % 251);
            try std.testing.expectEqual(expected, byte);
        }
    }
}

test "LZ4 complete options separate extent history and byte admission" {
    const wire = [_]u8{ 0x50, 'h', 'e', 'l', 'l', 'o' };
    var output: [8]u8 = @splat(0xa7);
    const result = try decodeBlock(&wire, &output, .{ .output_size = .bounded });
    try std.testing.expectEqual(wire.len, result.consumed);
    try std.testing.expectEqual(5, result.produced);
    try std.testing.expectEqualStrings("hello", output[0..result.produced]);
    try std.testing.expect(std.mem.allEqual(u8, output[5..], 0xa7));
    try std.testing.expectError(error.OutputSizeMismatch, decodeBlock(&wire, &output, .{}));
    _ = try decodeBlock(
        &wire,
        output[0..5],
        .{ .limits = .{ .input_bytes = wire.len, .output_bytes = 5, .work_units = wire.len + 5 } },
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decodeBlock(
            &wire,
            &output,
            .{ .output_size = .bounded, .limits = .{ .work_units = wire.len + 4 } },
        ),
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decodeBlock(&wire, output[0..5], .{ .limits = .{ .input_bytes = wire.len - 1 } }),
    );
    // A reachable dictionary overlapping even unused destination capacity is still an alias.
    try std.testing.expectError(
        error.Aliasing,
        decodeBlock(
            &wire,
            &output,
            .{
                .output_size = .bounded,
                .dictionary = .{ .older = output[6..] },
                .limits = .{ .output_bytes = 5 },
            },
        ),
    );
    const allocator = std.testing.allocator;
    const history = try allocator.create([65536]u8);
    defer allocator.destroy(history);
    var dictionary = [_]u8{ 'a', 'b', 'c', 'd' };
    var decoder: Decoder = undefined;
    try decoder.reset(history, .{ .dictionary = &dictionary });
    @memset(&dictionary, 0);
    // Match four dictionary bytes, then eight independent final literals.
    const external = [_]u8{ 0, 4, 0, 0x80, '1', '2', '3', '4', '5', '6', '7', '8' };
    var restored: [12]u8 = undefined;
    const progress = try decoder.step(.{ .bytes = &external, .final = true }, &restored);
    try std.testing.expectEqual(DecodeStatus.complete, progress.status);
    try std.testing.expectEqualStrings("abcd12345678", &restored);
}
