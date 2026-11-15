//! Greedy LZ4 encoding maps byte hashes to earlier positions and emits a found match immediately.
//! Linked blocks reuse that table: positions, absolute origin, hash width and compact/wide
//! representation form one invariant. Physical reservations remain caller-owned; a continuation
//! must stay paired with its table until the stream is restarted.
const std = @import("std");
const byte_ranges = @import("../common/byte_ranges.zig");
const overlaps = byte_ranges.overlapsChecked;
const Writer = @import("BlockWriter.zig");
const test_recovery = @import("block_recovery.zig"); // Inline round-trip/linked-history tests only.
const maximum_distance = @import("block.zig").maximum_distance;
pub const Workspace = @import("BlockEncodeWorkspace.zig");

/// Encoding input, capacity, arithmetic or disjoint-storage failure. Output stays unpublished.
pub const Error = error{ OutputTooSmall, SizeOverflow, InputTooLarge, Aliasing };

/// Practical encoding bound, matching LZ4 1.10.0's public input contract.
pub const max_input_bytes: usize = 0x7e00_0000;

/// Sufficient output capacity for any native encoding of this input length, including empty.
/// Oversized input/arithmetic fail without allocation. into requires this full capacity.
pub fn bound(input_bytes: usize) error{ InputTooLarge, SizeOverflow }!usize {
    if (input_bytes > max_input_bytes) return error.InputTooLarge;
    return std.math.add(usize, input_bytes, input_bytes / 255 + 16) catch error.SizeOverflow;
}

/// Greedy block encoding, with optional immutable external history for this call.
pub const Options = struct {
    /// Immutable initial history for this call; only its last 65,535 bytes are reachable.
    dictionary: []const u8 = &.{},
};

/// Produces a deterministic raw block, borrowing the used prefix of output. Requires
/// bound(source.len) capacity and disjoint source/output/workspace before writing. Fills no
/// trailing bytes. Workspace is completely reset for every call.
// Stabilize the hot word-match loop's placement as other codec bodies grow.
pub fn into(
    source: []const u8,
    output: []u8,
    workspace: *Workspace,
    options: Options,
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
    const required_capacity = try bound(source.len);
    const scratch = std.mem.asBytes(workspace);
    if (try overlaps(source, output)) return error.Aliasing;
    if (try overlaps(source, scratch) or try overlaps(output, scratch)) return error.Aliasing;
    if (output.len < required_capacity) return error.OutputTooSmall;

    if (source.len == 65536) return encodeBlockWide64K(source, output, workspace);
    if (source.len < 65536) return encodeBlockRaw(true, false, source, output, workspace, 0);
    return encodeBlockRaw(false, false, source, output, workspace, 0);
}

/// A full raw block keeps 32-bit hash entries usable by later linked blocks. This kernel seeds byte
/// zero into that table, then follows a greedy five-byte hash search. After a match it probes the
/// two positions immediately before and at the new cursor to continue an adjacent match chain
/// without restarting the ordinary skip schedule.
fn encodeBlockWide64K(source: []const u8, output: []u8, workspace: *Workspace) []u8 {
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
    workspace: *Workspace,
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
    workspace: *Workspace,
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
/// input. A null result means the heuristic found no usable match; a frame can store the original
/// caller-owned bytes.
pub fn encodeWithInitialProbe(source: []const u8, output: []u8, workspace: *Workspace) Error!?[]u8 {
    if (source.len > 65536) return error.InputTooLarge;
    const required_capacity = try bound(source.len);
    const scratch = std.mem.asBytes(workspace);
    if (try overlaps(source, output)) return error.Aliasing;
    if (try overlaps(source, scratch) or try overlaps(output, scratch)) return error.Aliasing;
    if (output.len < required_capacity) return error.OutputTooSmall;

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

// Encode against borrowed external history. A null rolling origin rebuilds the match table from
// that history; a continuation reuses its absolute positions and selected hash width. Output and
// workspace must be disjoint from both source spans.
fn encodeWithHistory(
    source: []const u8,
    output: []u8,
    workspace: *Workspace,
    dictionary: []const u8,
    rolling_end: ?u32,
    contiguous_history: bool,
    five_byte_hash: bool,
) Error![]u8 {
    const dict = dictionarySuffix(dictionary);
    std.debug.assert(dict.len != 0);
    std.debug.assert(!five_byte_hash or rolling_end != null);
    const required_capacity = try bound(source.len);
    const scratch = std.mem.asBytes(workspace);
    if (try overlaps(source, output)) return error.Aliasing;
    if (try overlaps(source, scratch) or try overlaps(output, scratch)) return error.Aliasing;
    if (try overlaps(dict, output) or try overlaps(dict, scratch)) return error.Aliasing;
    if (output.len < required_capacity) return error.OutputTooSmall;

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
    workspace: *Workspace,
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
    workspace: *Workspace,
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
pub const Continuation = struct {
    /// The paired table has been initialized by a first block.
    ready: bool = false,
    /// Absolute position immediately after the previous block.
    end: u32 = 0,
    /// The first block seeded five-byte hashes rather than dictionary four-byte hashes.
    five_byte_hash: bool = false,
    /// The first block used compact cells; the next linked call must rebuild wide cells.
    compact_first: bool = false,
};

/// Reuses the match table across linked blocks without rebasing each block. After a short first
/// block, rebuilds the wide table once from its history. `contiguous_history` requires dictionary
/// and source slices of the same caller buffer.
pub fn encodeRolling(
    source: []const u8,
    output: []u8,
    workspace: *Workspace,
    dictionary: []const u8,
    contiguous_history: bool,
    state: *Continuation,
) Error![]u8 {
    const dict = dictionarySuffix(dictionary);
    if (!state.ready) {
        // Let the ordinary independent encoder initialize the first block, then remember the
        // absolute position origin and hash width needed to continue into later blocks.
        const result = try into(source, output, workspace, .{ .dictionary = dict });
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

test "LZ4 initial probe preserves raw bytes and leaves no-match output untouched" {
    const allocator = std.testing.allocator;
    const probed = try Workspace.create(allocator);
    defer probed.destroy(allocator);
    const ordinary = try Workspace.create(allocator);
    defer ordinary.destroy(allocator);
    const source = try allocator.alloc(u8, 65536);
    defer allocator.free(source);
    const required_capacity = try bound(source.len);
    const output = try allocator.alloc(u8, required_capacity + 1);
    defer allocator.free(output);
    const expected = try allocator.alloc(u8, required_capacity);
    defer allocator.free(expected);

    var random: std.Random.DefaultPrng = .init(0x5180_7204);
    random.random().bytes(source);
    @memset(output, 0xa5);
    try std.testing.expect(
        (try encodeWithInitialProbe(source[0..12], output[0..required_capacity], probed)) == null,
    );
    try std.testing.expect(
        (try encodeWithInitialProbe(source, output[0..required_capacity], probed)) == null,
    );
    try std.testing.expect(std.mem.allEqual(u8, output, 0xa5));

    @memset(source, 'a');
    const compressed = (try encodeWithInitialProbe(source, output[0..required_capacity], probed)).?;
    const ordinary_bytes = try into(source, expected, ordinary, .{});
    var decoded: [65536]u8 = undefined;
    _ = try test_recovery.into(compressed, &decoded, .{});
    try std.testing.expectEqualSlices(u8, source, &decoded);
    _ = try test_recovery.into(ordinary_bytes, &decoded, .{});
    try std.testing.expectEqualSlices(u8, source, &decoded);
    try std.testing.expectEqual(@as(u8, 0xa5), output[required_capacity]);
}

test into {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);

    const source = "an independent raw LZ4 block";
    const destination = try allocator.alloc(u8, try bound(source.len));
    defer allocator.free(destination);
    const record = .{
        .bytes = try into(source, destination, workspace, .{}),
        .decoded_size = source.len,
    };

    var output: [source.len]u8 = undefined;
    _ = try test_recovery.into(record.bytes, output[0..record.decoded_size], .{});
    try std.testing.expectEqualStrings(source, &output);
}

test "LZ4 linked literal copies preserve the encoded suffix and output guard" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);

    var input: [128]u8 = undefined;
    for (input[0..64], 0..) |*byte, index| byte.* = @intCast(index % 17);
    @memcpy(input[64..128], input[0..64]);
    var storage: [96]u8 = @splat(0xa5);
    var decoded: [64]u8 = undefined;

    @memset(&workspace.positions, 0);
    workspace.positions[hashFivePosition(input[64..128], 0)] = 1;
    var state: Continuation = .{ .ready = true, .end = 64, .five_byte_hash = true };
    const rolling = try encodeRolling(
        input[64..128],
        storage[0..80],
        workspace,
        input[0..64],
        true,
        &state,
    );
    try std.testing.expectEqual(@as(u8, 0), rolling[0] >> 4);
    try std.testing.expect(std.mem.allEqual(u8, storage[rolling.len..], 0xa5));
    _ = try test_recovery.into(rolling, &decoded, .{ .history = .{ .newer = input[0..64] } });
    try std.testing.expectEqualSlices(u8, input[64..128], &decoded);

    @memset(&storage, 0xa5);
    const borrowed = try into(
        input[64..128],
        storage[0..80],
        workspace,
        .{ .dictionary = input[0..64] },
    );
    try std.testing.expectEqual(@as(u8, 0), borrowed[0] >> 4);
    try std.testing.expect(std.mem.allEqual(u8, storage[borrowed.len..], 0xa5));
    _ = try test_recovery.into(borrowed, &decoded, .{ .history = .{ .newer = input[0..64] } });
    try std.testing.expectEqualSlices(u8, input[64..128], &decoded);
}

test "LZ4 raw table switches at the 64 KiB boundary" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
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
        const encoded = try allocator.alloc(u8, try bound(block_len));
        defer allocator.free(encoded);
        const decoded = try allocator.alloc(u8, block_len);
        defer allocator.free(decoded);

        const wire = try into(source[0..block_len], encoded, workspace, .{});
        const result = try test_recovery.into(wire, decoded, .{});
        try std.testing.expectEqual(block_len, result.produced);
        try std.testing.expectEqualSlices(u8, source[0..block_len], decoded);
    }
}

test "LZ4 rolling hash renormalization preserves linked block output" {
    const allocator = std.testing.allocator;
    const ordinary = try Workspace.create(allocator);
    defer ordinary.destroy(allocator);
    const near_limit = try Workspace.create(allocator);
    defer near_limit.destroy(allocator);
    var first: [128]u8 = undefined;
    for (&first, 0..) |*byte, i| byte.* = @intCast((i * 29) % 251);
    const second = first[32..112];
    var initial_wire: [256]u8 = undefined;
    var ordinary_state: Continuation = .{};
    _ = try encodeRolling(&first, &initial_wire, ordinary, &.{}, false, &ordinary_state);

    near_limit.* = ordinary.*;
    var near_state = ordinary_state;
    const advance: u32 = 0x8000_0000 - near_state.end - @as(u32, second.len) + 1;
    near_state.end += advance;
    for (&near_limit.positions) |*entry| {
        if (entry.* != 0) entry.* += advance;
    }

    var ordinary_wire: [256]u8 = undefined;
    var near_wire: [256]u8 = undefined;
    const expected = try encodeRolling(
        second,
        &ordinary_wire,
        ordinary,
        &first,
        false,
        &ordinary_state,
    );
    try std.testing.expect(expected.len < second.len / 2);
    const actual = try encodeRolling(second, &near_wire, near_limit, &first, false, &near_state);
    try std.testing.expectEqualSlices(u8, expected, actual);
    var restored: [second.len]u8 = undefined;
    _ = try test_recovery.into(actual, &restored, .{ .history = .{ .newer = &first } });
    try std.testing.expectEqualSlices(u8, second, &restored);
}

test "LZ4 rolling encoder rebuilds compact first-block history" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
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
    const first_storage = try allocator.alloc(u8, try bound(first.len));
    defer allocator.free(first_storage);
    const second_storage = try allocator.alloc(u8, try bound(second.len));
    defer allocator.free(second_storage);
    var rolling: Continuation = .{};
    _ = try encodeRolling(&first, first_storage, workspace, &.{}, false, &rolling);
    try std.testing.expect(rolling.compact_first);
    const wire = try encodeRolling(second, second_storage, workspace, &first, false, &rolling);
    try std.testing.expect(!rolling.compact_first);
    try std.testing.expect(wire.len < 64);
    var decoded: [second.len]u8 = undefined;
    _ = try test_recovery.into(wire, &decoded, .{ .history = .{ .newer = &first } });
    try std.testing.expectEqualSlices(u8, second, &decoded);
}

test "LZ4 dictionary encoder uses initial matches and preserves independent bytes" {
    const allocator = std.testing.allocator;
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    const dictionary = try allocator.alloc(u8, 70000);
    defer allocator.free(dictionary);
    var random: std.Random.DefaultPrng = .init(91);
    random.random().bytes(dictionary);
    var encoded: [4096]u8 = undefined;
    var independent: [4096]u8 = undefined;
    var output: [1024]u8 = undefined;
    const source = dictionary[dictionary.len - output.len ..];
    const block = try into(source, &encoded, workspace, .{ .dictionary = dictionary });
    try std.testing.expect(block.len < 32);
    _ = try test_recovery.into(block, &output, .{ .history = .{ .newer = dictionary } });
    try std.testing.expectEqualSlices(u8, source, &output);
    const ordinary = try into(source, &independent, workspace, .{});
    const empty_dict = try into(source, &encoded, workspace, .{ .dictionary = &.{} });
    try std.testing.expectEqualSlices(u8, ordinary, empty_dict);
}

test "LZ4 greedy admission rejects insufficient capacity overlap and oversized input" {
    const allocator = std.testing.allocator;
    const output = try allocator.alloc(u8, 300);
    defer allocator.free(output);
    const workspace = try Workspace.create(allocator);
    defer workspace.destroy(allocator);
    try std.testing.expectError(error.OutputTooSmall, into("abc", output[0..3], workspace, .{}));
    try std.testing.expectError(error.Aliasing, into(output[0..4], output, workspace, .{}));
    const scratch = std.mem.asBytes(workspace);
    try std.testing.expectError(error.Aliasing, into(scratch[0..4], output, workspace, .{}));
    try std.testing.expectError(error.InputTooLarge, bound(max_input_bytes + 1));
    const block = try into("abc", output, workspace, .{});
    var decoded: [3]u8 = undefined;
    _ = try test_recovery.into(block, &decoded, .{});
    try std.testing.expectEqualStrings("abc", &decoded);
}
