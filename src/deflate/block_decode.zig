//! Execute stored, fixed and admitted dynamic DEFLATE blocks in caller output. Output supplies
//! match history; each worker retains its validated table interpretation and buffer margins. Input
//! margins are measured from the next byte to load, not consumed(), which subtracts lookahead.

const builtin = @import("builtin");
const std = @import("std");
const BitReader = @import("BitReader.zig");
const copying = @import("match_copy.zig");
const fixture_data = @import("decode_fixtures.zig");
const huffman = @import("huffman.zig");
const protocol = @import("format.zig");
const DecodeWorkspace = @import("DecodeWorkspace.zig");
const packed_huffman = @import("packed_huffman.zig");
const test_complete = @import("decode.zig"); // Used only by inline cross-operation tests.
const header_decoding = @import("dynamic_header_decode.zig");

// DEFLATE decoding mechanisms studied in libdeflate:
// https://github.com/ebiggers/libdeflate/blob/92e6a0db9fa848d742f9eb286c92afc60f2c3dda/lib/decompress_template.h

const PackedBitReader = packed_huffman.BitReader;

/// Malformed block data or insufficient destination capacity.
pub const Error = error{ InvalidStream, OutputTooSmall };
const IndexShift = std.math.Log2Int(usize);
/// Copied byte counts for the first successfully decoded stream, excluding trailing bytes. Counts
/// describe the current input stream and supplied output; they can outlive them. Any derived slice
/// retains its source/output lifetime. On error no partial counts return.
pub const Result = struct {
    /// Encoded bytes occupied by the stream, including framing where applicable.
    consumed: usize,

    /// Output bytes written; bytes beyond this count remain unchanged.
    produced: usize,
};
const distance_base = protocol.distance_base;
const distance_extra = protocol.distance_extra;
const length_base = protocol.length_base;
const length_extra = protocol.length_extra;

const PackedTables = packed_huffman.Tables;
const DistanceTable = huffman.DistanceTable;
const Entry = huffman.Entry;
const ExpandedLiteralTable = huffman.ExpandedLiteralTable;
const ExpandedWideLiteralTable = huffman.ExpandedWideLiteralTable;
const FixedDistanceTable = huffman.FixedDistanceTable;
const FixedLiteralTable = huffman.FixedLiteralTable;
const LiteralTable = huffman.LiteralTable;
const PairedLiteralTable = huffman.PairedLiteralTable;
const PayloadFormat = huffman.PayloadFormat;
const WideLiteralTable = huffman.WideLiteralTable;

const decodeCombinedPayloadBuffered = huffman.decodeCombinedPayloadBuffered;
const distancePayloadValue = huffman.distancePayloadValue;
const fixed = huffman.fixed;
const fixed_payload = huffman.fixed_payload;
const payloadValue = huffman.payloadValue;
const transformPayloadTable = huffman.transformPayloadTable;

const copyExtendedWords = copying.copyExtendedWords;
const copyMatch = copying.copyMatch;
const copyPeriodicBytes = copying.copyPeriodicBytes;
const copyWindowPeriod = copying.copyWindowPeriod;
const copy_bytes = copying.copy_bytes;
const repeatPeriodic = copying.repeatPeriodic;

const frozen_fixtures = fixture_data.frozen_fixtures;
const general_pairs = fixture_data.general_pairs;
const paired_dense = fixture_data.paired_dense;
const paired_literals = fixture_data.paired_literals;
const wide_literals = fixture_data.wide_literals;

// Separate tail identities keep LLVM's outlined instances from also outlining the ordinary
// dynamic/wide callers. The tables and checked decoding remain identical.
const BlockKind = enum {
    fixed,
    dynamic,
    expanded,
    expanded_wide,
    wide,
    paired,
    paired_general,
    tail_dynamic,
    tail_expanded,
    tail_expanded_wide,
    tail_wide,
};

const RepetitionKind = enum { short, sixteen, window };

/// Restores a complete stream using output as its only history. Admission has already made source,
/// output and workspace disjoint and bounded their extents. The explicit window selects checked
/// smaller-window execution without bringing dictionary, trailing-data or budget policies here.
pub fn decode(
    comptime exact: bool,
    source: []const u8,
    output: []u8,
    workspace: *DecodeWorkspace,
    window_bytes: usize,
) (Error || error{InvalidOptions})!Result {
    if (window_bytes == 0 or window_bytes > 32768) return error.InvalidOptions;
    if (window_bytes == 32768) {
        return decodeRawSized(false, exact, source, output, workspace, 0);
    }
    return decodeRawSized(true, exact, source, output, workspace, window_bytes);
}

fn decodeRawSized(
    comptime windowed: bool,
    comptime exact: bool,
    source: []const u8,
    output: []u8,
    workspace: *DecodeWorkspace,
    window: usize,
) Error!Result {
    var bits = BitReader{ .source = source };
    var written: usize = 0;
    while (true) {
        const final_block = try bits.take(1) != 0;
        switch (try bits.take(2)) {
            0 => {
                bits.alignByte();
                const offset = bits.consumed();
                if (source.len - offset < 4) return error.InvalidStream;
                const length = std.mem.readInt(u16, source[offset..][0..2], .little);
                const complement = std.mem.readInt(u16, source[offset + 2 ..][0..2], .little);
                if (length != ~complement or source.len - offset - 4 < length)
                    return error.InvalidStream;
                if (output.len - written < length) return error.OutputTooSmall;
                @memcpy(output[written..][0..length], source[offset + 4 ..][0..length]);
                written += length;
                bits = .{ .source = source, .position = offset + 4 + length };
            },
            // A compact separate loop helps fixed literals. Dynamic decoding may inline to keep
            // repeated-match state local to the outer decoder.
            1 => try @call(
                .never_inline,
                fixedBlock,
                .{ windowed, &bits, output, &written, window },
            ),
            2 => {
                const tables = try header_decoding.read(!windowed, !windowed, &bits, workspace);
                if (windowed) {
                    try windowedBlock(tables, &bits, output, &written, workspace, window);
                } else switch (tables) {
                    .packed_tables => try @call(
                        .never_inline,
                        packedBlock,
                        .{ exact, &bits, output, &written, &workspace.literal.packed_tables },
                    ),
                    .short_period => try @call(
                        .never_inline,
                        repetitionBlock,
                        .{
                            .short,
                            &bits,
                            output,
                            &written,
                            &workspace.literal.ordinary,
                            &workspace.distance,
                        },
                    ),
                    .sixteen_byte_period => try @call(
                        .never_inline,
                        repetitionBlock,
                        .{
                            .sixteen,
                            &bits,
                            output,
                            &written,
                            &workspace.literal.ordinary,
                            &workspace.distance,
                        },
                    ),
                    .window_period => try @call(
                        .never_inline,
                        repetitionBlock,
                        .{
                            .window,
                            &bits,
                            output,
                            &written,
                            &workspace.literal.ordinary,
                            &workspace.distance,
                        },
                    ),
                    .ordinary => try compressedBlock(
                        .dynamic,
                        false,
                        &bits,
                        output,
                        &written,
                        &workspace.literal.ordinary,
                        &workspace.distance,
                        0,
                    ),
                    .expanded_lengths => try @call(
                        .never_inline,
                        expandedPayloadBlock,
                        .{
                            .expanded,
                            &bits,
                            output,
                            &written,
                            &workspace.literal.expanded,
                            &workspace.distance,
                        },
                    ),
                    .match_payload => try @call(
                        .never_inline,
                        payloadBlock,
                        .{
                            .dynamic,
                            false,
                            exact,
                            &bits,
                            output,
                            &written,
                            &workspace.literal.ordinary,
                            &workspace.distance,
                        },
                    ),
                    .literal_batch => try @call(
                        .never_inline,
                        payloadBlock,
                        .{
                            .dynamic,
                            true,
                            exact,
                            &bits,
                            output,
                            &written,
                            &workspace.literal.ordinary,
                            &workspace.distance,
                        },
                    ),
                    .wide_expanded_lengths => try @call(
                        .never_inline,
                        expandedPayloadBlock,
                        .{
                            .expanded_wide,
                            &bits,
                            output,
                            &written,
                            &workspace.literal.expanded_wide,
                            &workspace.distance,
                        },
                    ),
                    .wide_match_payload => try @call(
                        .never_inline,
                        payloadBlock,
                        .{
                            .wide,
                            false,
                            exact,
                            &bits,
                            output,
                            &written,
                            &workspace.literal.wide,
                            &workspace.distance,
                        },
                    ),
                    .wide_literal_batch => try @call(
                        .never_inline,
                        payloadBlock,
                        .{
                            .wide,
                            true,
                            exact,
                            &bits,
                            output,
                            &written,
                            &workspace.literal.wide,
                            &workspace.distance,
                        },
                    ),
                    .wide => try compressedBlock(
                        .wide,
                        false,
                        &bits,
                        output,
                        &written,
                        &workspace.literal.wide,
                        &workspace.distance,
                        0,
                    ),
                    .paired => try compressedBlock(
                        .paired,
                        false,
                        &bits,
                        output,
                        &written,
                        &workspace.literal.paired,
                        &workspace.distance,
                        0,
                    ),
                    .paired_general => try compressedBlock(
                        .paired_general,
                        false,
                        &bits,
                        output,
                        &written,
                        &workspace.literal.paired,
                        &workspace.distance,
                        0,
                    ),
                    .end_only => {
                        // EOB is mandatory; the sole admitted incomplete literal tree has one
                        // one-bit EOB and an invalid other half.
                        if (try bits.take(1) != 0) return error.InvalidStream;
                    },
                }
            },
            else => return error.InvalidStream,
        }
        if (final_block) {
            bits.alignByte();
            return .{ .consumed = bits.consumed(), .produced = written };
        }
    }
}

// Smaller zlib windows use the checked token loop for each admitted table layout. Full-window/raw
// decoding retains its match prefixes without another per-match guard.
fn windowedBlock(
    tables: header_decoding.DecodePlan,
    bits: *BitReader,
    output: []u8,
    written: *usize,
    workspace: *DecodeWorkspace,
    window: usize,
) Error!void {
    switch (tables) {
        .packed_tables => unreachable,
        .wide_expanded_lengths => try compressedBlock(
            .expanded_wide,
            true,
            bits,
            output,
            written,
            &workspace.literal.expanded_wide,
            &workspace.distance,
            window,
        ),
        .expanded_lengths => try compressedBlock(
            .expanded,
            true,
            bits,
            output,
            written,
            &workspace.literal.expanded,
            &workspace.distance,
            window,
        ),
        .ordinary,
        .match_payload,
        .literal_batch,
        .short_period,
        .sixteen_byte_period,
        .window_period,
        => try compressedBlock(
            .dynamic,
            true,
            bits,
            output,
            written,
            &workspace.literal.ordinary,
            &workspace.distance,
            window,
        ),
        .wide, .wide_match_payload, .wide_literal_batch => try compressedBlock(
            .wide,
            true,
            bits,
            output,
            written,
            &workspace.literal.wide,
            &workspace.distance,
            window,
        ),
        .paired => try compressedBlock(
            .paired,
            true,
            bits,
            output,
            written,
            &workspace.literal.paired,
            &workspace.distance,
            window,
        ),
        .paired_general => try compressedBlock(
            .paired_general,
            true,
            bits,
            output,
            written,
            &workspace.literal.paired,
            &workspace.distance,
            window,
        ),
        .end_only => if (try bits.take(1) != 0) return error.InvalidStream,
    }
}

fn packedPrefix(
    comptime exact: bool,
    noalias bits: *BitReader,
    output: []u8,
    noalias written: *usize,
    noalias tables: *const PackedTables,
) Error!bool {
    var position = written.*;
    if (bits.source.len - bits.position < 25 or output.len - position < 300) return false;
    var reader = PackedBitReader{
        .source = bits.source,
        .value = bits.value,
        .count = bits.count,
        .position = bits.position,
    };
    const literal_mask = (@as(usize, 1) << @as(IndexShift, @intCast(tables.literal_bits))) - 1;
    reader.refill();
    var entry = tables.literal[@as(usize, @truncate(reader.value)) & literal_mask];
    tokens: while (true) {
        var saved = reader.value;
        reader.drop(entry);
        match: {
            if (entry & PackedTables.literal_flag != 0) {
                extras: {
                    inline for (0..2) |_| {
                        const byte: u8 = @truncate(entry >> 16);
                        entry = tables.literal[@as(usize, @truncate(reader.value)) & literal_mask];
                        saved = reader.value;
                        reader.drop(entry);
                        output[position] = byte;
                        position += 1;
                        if (entry & PackedTables.literal_flag == 0) break :extras;
                    }
                    // The third direct literal shares emission with a literal resolved through a
                    // secondary table below.
                    break :match;
                }
            }
            if (entry & PackedTables.exceptional != 0) {
                @branchHint(.unlikely);
                if (entry & PackedTables.end_flag != 0) {
                    reader.publish(bits);
                    written.* = position;
                    return true;
                }
                std.debug.assert(entry & PackedTables.subtable != 0);
                const suffix: u8 = @intCast((entry >> 8) & 63);
                const mask = (@as(usize, 1) << @as(IndexShift, @intCast(suffix))) - 1;
                const index = @as(usize, @truncate(reader.value)) & mask;
                entry = tables.literal[(entry >> 16) + index];
                saved = reader.value;
                reader.drop(entry);
                if (entry & PackedTables.literal_flag != 0) break :match;
                if (entry & PackedTables.end_flag != 0) {
                    reader.publish(bits);
                    written.* = position;
                    return true;
                }
            }
            const decoded_literal: PackedTables.Decoded = .{ .entry = entry, .saved = saved };
            const length = decoded_literal.matchValue();
            var distance = tables.distance[@as(u8, @truncate(reader.value))];
            if (distance & PackedTables.exceptional != 0) {
                @branchHint(.unlikely);
                std.debug.assert(distance & PackedTables.subtable != 0);
                if (@as(u8, @truncate(reader.count)) < 38) reader.refill();
                reader.drop(distance);
                const suffix: u8 = @intCast((distance >> 8) & 63);
                const mask = (@as(usize, 1) << @as(IndexShift, @intCast(suffix))) - 1;
                const index = @as(usize, @truncate(reader.value)) & mask;
                distance = tables.distance[(distance >> 16) + index];
            } else if (@as(u8, @truncate(reader.count)) < 31) reader.refill();
            saved = reader.value;
            reader.drop(distance);
            const decoded_distance: PackedTables.Decoded = .{ .entry = distance, .saved = saved };
            const offset = decoded_distance.matchValue();
            if (offset > position) {
                @branchHint(.unlikely);
                return error.InvalidStream;
            }
            // Preload independently of the unconditional refill before issuing match stores, so the
            // next lookup and copy are available together.
            entry = tables.literal[@as(usize, @truncate(reader.value)) & literal_mask];
            reader.refill();
            if (exact and offset >= 8 and length <= 40) {
                // At most two preceding literals leave the existing 298-byte word-copy margin.
                // Exact-size success fills the whole output; a short stream fails before
                // publication.
                @call(
                    .always_inline,
                    copyExtendedWords,
                    .{ output[position..], output[position - offset ..], length },
                );
            } else {
                // Long matches retain wide exact copies; bounded decoding preserves spare output.
                @call(.always_inline, copyMatch, .{ output, position, offset, length });
            }
            position += length;
            if (reader.source.len - reader.position < 25 or output.len - position < 300)
                break :tokens;
            continue :tokens;
        }
        // Only a resolved literal reaches here; its bits were consumed above.
        const byte: u8 = @truncate(entry >> 16);
        entry = tables.literal[@as(usize, @truncate(reader.value)) & literal_mask];
        reader.refill();
        output[position] = byte;
        position += 1;
        if (reader.source.len - reader.position < 25 or output.len - position < 300) break :tokens;
    }
    reader.publish(bits);
    written.* = position;
    return false;
}

fn packedBlock(
    comptime exact: bool,
    noalias bits: *BitReader,
    output: []u8,
    noalias written: *usize,
    noalias tables: *const PackedTables,
) Error!void {
    if (try packedPrefix(exact, bits, output, written, tables)) return;
    try packedChecked(bits, output, written, tables);
}

fn packedChecked(
    noalias bits: *BitReader,
    output: []u8,
    noalias written: *usize,
    noalias tables: *const PackedTables,
) Error!void {
    var position = written.*;
    while (true) {
        const literal = try tables.read(false, bits);
        if (literal.entry & PackedTables.literal_flag != 0) {
            if (position == output.len) return error.OutputTooSmall;
            output[position] = @truncate(literal.entry >> 16);
            position += 1;
            continue;
        }
        if (literal.entry & PackedTables.end_flag != 0) {
            written.* = position;
            return;
        }
        const length = literal.matchValue();
        const distance = try tables.read(true, bits);
        const offset = distance.matchValue();
        // Preserve selected decoding's invalid-distance-before-capacity priority.
        if (offset > position) return error.InvalidStream;
        if (length > output.len - position) return error.OutputTooSmall;
        copyMatch(output, position, offset, length);
        position += length;
    }
}

fn fixedBlock(
    comptime windowed: bool,
    noalias bits: *BitReader,
    output: []u8,
    noalias written: *usize,
    window: usize,
) Error!void {
    if (!windowed) {
        if (try @call(.always_inline, fixedPayloadPrefix, .{ bits, output, written })) return;
    }
    try @call(
        .never_inline,
        compressedBlock,
        .{ .fixed, windowed, bits, output, written, &fixed.literal, &fixed.distance, window },
    );
}

fn compressedBlock(
    comptime kind: BlockKind,
    comptime windowed: bool,
    noalias bits: *BitReader,
    output: []u8,
    noalias written: *usize,
    noalias literal: *const switch (kind) {
        .fixed => FixedLiteralTable,
        .dynamic, .tail_dynamic => LiteralTable,
        .expanded, .tail_expanded => ExpandedLiteralTable,
        .expanded_wide, .tail_expanded_wide => ExpandedWideLiteralTable,
        .wide, .tail_wide => WideLiteralTable,
        .paired, .paired_general => PairedLiteralTable,
    },
    noalias distance: *const if (kind == .fixed) FixedDistanceTable else DistanceTable,
    window: usize,
) Error!void {
    const direct = kind == .fixed;
    const paired = kind == .paired or kind == .paired_general;
    const expanded = kind == .expanded or kind == .expanded_wide or kind == .tail_expanded or
        kind == .tail_expanded_wide;
    if (!windowed and kind == .paired_general) {
        if (try pairedPrefix(bits, output, written, literal, distance)) return;
    }
    var position = written.*;
    while (true) {
        const mode = if (direct) .root else if (paired) .paired else .complete;
        const entry = try literal.decode(bits, mode);
        const value = if (direct) entry else entry.value;
        const is_literal = if (paired or expanded) entry.literals != 0 else value < 256;
        if (is_literal) {
            if (paired) {
                const count: usize = entry.literals;
                if (count > output.len - position) {
                    @branchHint(.unlikely);
                    if (position < output.len) output[position] = @truncate(value);
                    return error.OutputTooSmall;
                }
                // For a single, both stores hit the same byte and agree. For a pair, they hit its
                // two actual bytes. No produced suffix is touched.
                output[position] = @truncate(value);
                output[position + count - 1] = @truncate(value >> 8);
                position += count;
            } else {
                if (position == output.len) {
                    @branchHint(.unlikely);
                    return error.OutputTooSmall;
                }
                output[position] = @intCast(value);
                position += 1;
            }
            if (kind == .paired and output.len - position >= 8) {
                // Four entries need at most 48 bits and eight actual output bytes. Stop before a
                // nonliteral; no speculative suffix stores.
                bits.refill(48);
                if (bits.count >= 48) {
                    position += pairedLiterals(4, bits, literal, output[position..][0..8]);
                }
            }
            if (direct and output.len - position >= 4) {
                // Fixed codes use at most nine bits. Batch only after a literal, keeping the extra
                // lookup away from consecutive match tokens.
                bits.refill(4 * 9);
                if (bits.count >= 4 * 9) position += fixedLiterals(bits, output[position..][0..4]);
            }
        } else {
            const is_end = if (expanded) entry.unused != 0 else value == 256;
            if (is_end) {
                written.* = position;
                return;
            }

            const length: usize = blk: {
                if (direct) {
                    if (value > 285) {
                        @branchHint(.unlikely);
                        return error.InvalidStream;
                    }
                    const index = value - 257;
                    break :blk length_base[index] + try bits.take(length_extra[index]);
                }
                if (expanded) break :blk value;
                // Header admission bounds this value. Preserve the reserved length guard before
                // applying the base's bias.
                if (value > 514) {
                    @branchHint(.unlikely);
                    return error.InvalidStream;
                }
                break :blk value - 256 + try bits.take(entry.extra);
            };
            const offset: usize = if (kind == .paired) blk: {
                const side = try bits.take(1);
                // A singleton distance-one tree leaves code 1 invalid. Full one-bit trees instead
                // map it to distance two.
                if (side != 0 and distance.root[1].bits == 0) {
                    @branchHint(.unlikely);
                    return error.InvalidStream;
                }
                break :blk 1 + @as(usize, side);
            } else blk: {
                const offset_entry = try distance.decode(bits, if (direct) .root else .distance);
                if (direct) {
                    if (offset_entry > 29) {
                        @branchHint(.unlikely);
                        return error.InvalidStream;
                    }
                    const extra = try bits.take(distance_extra[offset_entry]);
                    break :blk distance_base[offset_entry] + extra;
                } else {
                    if (offset_entry.value == 0) {
                        @branchHint(.unlikely);
                        return error.InvalidStream;
                    }
                    break :blk offset_entry.value + try bits.take(offset_entry.extra);
                }
            };
            if (offset > position or (windowed and offset > window)) {
                @branchHint(.unlikely);
                return error.InvalidStream;
            }
            if (length > output.len - position) {
                @branchHint(.unlikely);
                return error.OutputTooSmall;
            }
            if (length == 3) {
                // Noisy streams overwhelmingly use minimum matches. Avoid the copy helper call;
                // forward stores also preserve one/two-byte overlap.
                output[position] = output[position - offset];
                output[position + 1] = output[position - offset + 1];
                output[position + 2] = output[position - offset + 2];
            } else {
                // The 32-byte repetition path benefits from avoiding this extra input read at short
                // distances. The 16-byte token loop retains its scheduled refills: adding a
                // distance guard slows long matches.
                const scheduled_refill = !direct and (copy_bytes == 16 or offset > 4);
                if (scheduled_refill and bits.source.len - bits.position >= 8) {
                    bits.refillWide();
                }
                // Keep token state in registers across the bounded history copy. An outlined helper
                // spills that state on match-heavy streams.
                @call(.always_inline, copyMatch, .{ output, position, offset, length });
            }
            position += length;
        }
    }
}

// Expanded length entries already consume their payload; only distance leaves need width
// preparation. The checked tail sees exact lengths and zero extras.
fn expandedPayloadBlock(
    comptime kind: BlockKind,
    noalias bits: *BitReader,
    output: []u8,
    noalias written: *usize,
    noalias literal: *if (kind == .expanded) ExpandedLiteralTable else ExpandedWideLiteralTable,
    noalias distance: *DistanceTable,
) Error!void {
    if (bits.source.len - bits.position >= 8 and output.len - written.* >= 8) {
        transformPayloadTable(.widths, true, distance);
        if (try payloadPrefix(kind, false, false, bits, output, written, literal, distance)) return;
        transformPayloadTable(.widths, false, distance);
    }
    try @call(
        .never_inline,
        compressedBlock,
        .{
            if (kind == .expanded) .tail_expanded else .tail_expanded_wide,
            false,
            bits,
            output,
            written,
            literal,
            distance,
            0,
        },
    );
}

// Prepare admitted wide or literal-batched roots before the full-width prefix. Narrow unbatched
// payloads preserve ordinary values and predicates, caching only total/code widths. Keep
// preparation and checked tails outside the hot loop. Completion or failure may leave prepared
// entries in scratch; falling back must restore them before any canonical checked lookup.
fn payloadBlock(
    comptime kind: BlockKind,
    comptime batch_literals: bool,
    comptime exact: bool,
    noalias bits: *BitReader,
    output: []u8,
    noalias written: *usize,
    noalias literal: *if (kind == .dynamic) LiteralTable else WideLiteralTable,
    noalias distance: *DistanceTable,
) Error!void {
    // Rounded copies require a promised final size. Limit them to literal batches: the extra
    // output-budget check slows unbatched payloads on filtered-image data.
    const extended = exact and batch_literals;
    const tagged = kind == .wide or batch_literals;
    const width_only = kind == .dynamic and !batch_literals;
    const margin: usize = if (extended) 298 else 8;
    const admitted = blk: {
        if (!tagged and !width_only) break :blk false;
        if (bits.source.len - bits.position < 8) break :blk false;
        break :blk output.len - written.* >= margin;
    };
    if (admitted) {
        // Cache total/code widths, retaining ordinary predicates in width-only tables. Restore both
        // alphabets before entering the checked tail.
        const format: PayloadFormat = if (tagged) .tagged else .widths;
        transformPayloadTable(format, true, literal);
        transformPayloadTable(.widths, true, distance);
        if (try payloadPrefix(
            kind,
            batch_literals,
            extended,
            bits,
            output,
            written,
            literal,
            distance,
        )) return;
        transformPayloadTable(format, false, literal);
        transformPayloadTable(.widths, false, distance);
    }
    try @call(
        .never_inline,
        compressedBlock,
        .{
            if (kind == .dynamic) .tail_dynamic else .tail_wide,
            false,
            bits,
            output,
            written,
            literal,
            distance,
            0,
        },
    );
}

// One eager word refill proves a complete token: 15+5 length bits and 15+13 distance bits fit in 48
// bits. A literal group uses at most 37 bits and three bytes, then refills before the next token.
// Exact stores retain the caller's output boundary; the ordinary checked loop handles the final
// input/output margin.
fn payloadPrefix(
    comptime kind: BlockKind,
    comptime batch_literals: bool,
    comptime exact: bool,
    noalias bits: *BitReader,
    output: []u8,
    noalias written: *usize,
    noalias literal: *const switch (kind) {
        .dynamic => LiteralTable,
        .expanded => ExpandedLiteralTable,
        .expanded_wide => ExpandedWideLiteralTable,
        else => WideLiteralTable,
    },
    noalias distance: *const DistanceTable,
) Error!bool {
    const expanded = kind == .expanded or kind == .expanded_wide;
    const prepared = kind == .wide or batch_literals or expanded;
    const margin = if (exact) 298 else 8;
    var position = written.*;
    if (bits.source.len - bits.position < 8 or output.len - position < margin) return false;
    bits.refillWide();
    var first = literal.root[@as(usize, @truncate(bits.value)) & (literal.root.len - 1)];
    while (true) {
        var decoded = @call(
            .always_inline,
            decodeCombinedPayloadBuffered,
            .{ literal, bits, first },
        );
        var entry = decoded.entry;
        const is_literal = if (prepared) entry.literals != 0 else entry.value < 256;
        if (is_literal) {
            if (batch_literals) {
                // The first literal uses at most 15 bits; two additional root literals use at most
                // 22 bits. The 56-bit budget and eight-byte output margin cover all three,
                // retaining at least 27 real lookahead bits.
                var next = literal.root[@as(usize, @truncate(bits.value)) & (literal.root.len - 1)];
                output[position] = @intCast(entry.value);
                position += 1;
                if (next.literals != 0) {
                    bits.drop(next.bits);
                    output[position] = @intCast(next.value);
                    position += 1;
                    next = literal.root[@as(usize, @truncate(bits.value)) & (literal.root.len - 1)];
                    if (next.literals != 0) {
                        bits.drop(next.bits);
                        output[position] = @intCast(next.value);
                        position += 1;
                        const index = @as(usize, @truncate(bits.value)) & (literal.root.len - 1);
                        next = literal.root[index];
                    }
                }
                if (bits.source.len - bits.position < 8 or output.len - position < margin) break;
                first = next;
                bits.refillWide();
                // The group refill supplies a full token budget. A direct following length/EOB can
                // fall through without another loop iteration; nodes and following literals retain
                // routing.
                if (next.node or next.literals != 0) continue;
                decoded = @call(
                    .always_inline,
                    decodeCombinedPayloadBuffered,
                    .{ literal, bits, next },
                );
                entry = decoded.entry;
            } else {
                output[position] = @intCast(entry.value);
                position += 1;
                if (bits.source.len - bits.position < 8 or output.len - position < margin) break;
                first = literal.root[@as(usize, @truncate(bits.value)) & (literal.root.len - 1)];
                bits.refillWide();
                continue;
            }
        }
        const is_end = if (prepared) entry.unused != 0 else entry.value == 256;
        if (is_end) {
            written.* = position;
            return true;
        }
        // Retain the unbatched length guard before biased-base arithmetic.
        if (!batch_literals and !expanded and entry.value > (if (prepared) 258 else 514))
            return error.InvalidStream;
        const base: u16 = entry.value - (if (prepared) @as(u16, 0) else 256);
        const extra: u16 = if (expanded) 0 else payloadValue(decoded);
        const length: usize = base + extra;
        const offset_decoded = @call(
            .always_inline,
            decodeCombinedPayloadBuffered,
            .{
                distance,
                bits,
                distance.root[@as(usize, @truncate(bits.value)) & (distance.root.len - 1)],
            },
        );
        const offset_entry = offset_decoded.entry;
        if (offset_entry.value == 0) return error.InvalidStream;
        const offset: usize = offset_entry.value + distancePayloadValue(offset_decoded);
        if (offset > position) return error.InvalidStream;
        // Entry and repeat admission prove remaining >= 8. The next-token margin proves this match
        // fits too; only the final token needs capacity refusal. Only narrow literal batches share
        // the capacity and next-token check. Preserve invalid-distance priority and the ordinary
        // precise-copy bounds.
        const again = blk: {
            const remaining = output.len - position;
            if (exact) {
                // The initial margin covers every valid length <= 258 and the bounded five-word
                // extension. Distances retain ordinary checks.
                break :blk bits.source.len - bits.position >= 8 and remaining - length >= margin;
            }
            if (kind == .dynamic and batch_literals) {
                const has_margin = bits.source.len - bits.position >= 8 and length <= remaining - 8;
                if (!has_margin and length > remaining) return error.OutputTooSmall;
                break :blk has_margin;
            }
            if (length > remaining) return error.OutputTooSmall;
            break :blk bits.source.len - bits.position >= 8 and remaining - length >= 8;
        };
        if (again) {
            // The word refill loaded 64 real bits before a <=48-bit token. Its remaining lookahead
            // proves this <=11-bit root preload before refill.
            first = literal.root[@as(usize, @truncate(bits.value)) & (literal.root.len - 1)];
            bits.refillWide();
        }
        if (exact and offset >= 8) {
            @call(
                .always_inline,
                copyExtendedWords,
                .{ output[position..], output[position - offset ..], length },
            );
        } else if (length == 3) {
            output[position] = output[position - offset];
            output[position + 1] = output[position - offset + 1];
            output[position + 2] = output[position - offset + 2];
        } else {
            @call(.always_inline, copyMatch, .{ output, position, offset, length });
        }
        position += length;
        if (!again) break;
    }
    written.* = position;
    return false;
}

fn pairedPrefix(
    noalias bits: *BitReader,
    output: []u8,
    noalias written: *usize,
    noalias literal: *const PairedLiteralTable,
    noalias distance: *const DistanceTable,
) Error!bool {
    var position = written.*;
    // The refill supplies at least 56 bits. A match consumes at most 48: literal/length 15 +
    // payload 5 + distance 15 + payload 13. A continuation literal plus three paired entries
    // consumes at most 15 + 3 * 12 = 51 bits and produces at most eight actual bytes.
    while (bits.source.len - bits.position >= 8 and output.len - position >= 8) {
        bits.refillWide();
        const entry = try literal.decode(bits, .buffered_paired);
        if (entry.literals != 0) {
            const count: usize = entry.literals;
            output[position] = @truncate(entry.value);
            output[position + count - 1] = @truncate(entry.value >> 8);
            position += count;
            position += pairedLiterals(3, bits, literal, output[position..][0..6]);
            continue;
        }
        if (entry.value == 256) {
            written.* = position;
            return true;
        }
        if (entry.value > 514) {
            @branchHint(.unlikely);
            return error.InvalidStream;
        }
        const length: usize = entry.value - 256 + bits.takeBuffered(entry.extra);
        const offset_entry = try distance.decode(bits, .buffered_distance);
        if (offset_entry.value == 0) {
            @branchHint(.unlikely);
            return error.InvalidStream;
        }
        const offset: usize = offset_entry.value + bits.takeBuffered(offset_entry.extra);
        if (offset > position) {
            @branchHint(.unlikely);
            return error.InvalidStream;
        }
        if (length > output.len - position) {
            @branchHint(.unlikely);
            return error.OutputTooSmall;
        }
        if (length == 3) {
            output[position] = output[position - offset];
            output[position + 1] = output[position - offset + 1];
            output[position + 2] = output[position - offset + 2];
        } else {
            @call(.always_inline, copyMatch, .{ output, position, offset, length });
        }
        position += length;
    }
    written.* = position;
    return false;
}

// One budget proves all root lookups and exact stores in this literal batch. Stop before nodes, EOB
// and matches without consuming their code.
fn pairedLiterals(
    comptime entries: usize,
    noalias bits: *BitReader,
    noalias literal: *const PairedLiteralTable,
    noalias output: *[2 * entries]u8,
) usize {
    std.debug.assert(bits.count >= 12 * entries);
    var position: usize = 0;
    inline for (0..entries) |_| {
        const entry = literal.root[@as(usize, @truncate(bits.value)) & (literal.root.len - 1)];
        if (entry.literals == 0) return position;
        bits.drop(entry.bits);
        const count: usize = entry.literals;
        output[position] = @truncate(entry.value);
        output[position + count - 1] = @truncate(entry.value >> 8);
        position += count;
    }
    return position;
}

// The caller has consumed the first literal. Four following equal-width code addresses are
// independent. Resolve every leaf before committing more bits or output; failure leaves the
// caller's current reservoir and output unchanged.
inline fn fixedFiveLiterals(first: Entry, bits: *BitReader, output: *[5]u8) bool {
    const width: u6 = @intCast(first.bits);
    std.debug.assert(first.literals == 1 and (width == 8 or width == 9));
    std.debug.assert(bits.count >= 56 - @as(u8, width));
    const second = fixed_payload.literal[@as(usize, @truncate(bits.value)) & 511];
    const third = fixed_payload.literal[@as(usize, @truncate(bits.value >> width)) & 511];
    const fourth = fixed_payload.literal[@as(usize, @truncate(bits.value >> (width * 2))) & 511];
    const fifth = fixed_payload.literal[@as(usize, @truncate(bits.value >> (width * 3))) & 511];
    const tag: u32 = @bitCast(first);
    const second_tag: u32 = @bitCast(second);
    const third_tag: u32 = @bitCast(third);
    const fourth_tag: u32 = @bitCast(fourth);
    const fifth_tag: u32 = @bitCast(fifth);
    const differences = (second_tag ^ tag) | (third_tag ^ tag) | (fourth_tag ^ tag) | (fifth_tag ^
        tag);
    if (differences & 0xffff != 0) return false;

    var literal_word: u32 = first.value;
    literal_word |= @as(u32, second.value) << 8;
    literal_word |= @as(u32, third.value) << 16;
    literal_word |= @as(u32, fourth.value) << 24;
    std.mem.writeInt(u32, output[0..4], literal_word, .little);
    output[4] = @intCast(fifth.value);
    bits.drop(@as(u8, width) * 4);
    return true;
}

// One refill covers any fixed token: LL<=9+5 and D=5+13, at most 32 bits. Five literals use at most
// 45 bits, leaving a nine-bit next-root preload. Precise stores and source/output margins hand the
// remaining work to the checked tail.
fn fixedPayloadPrefix(noalias bits: *BitReader, output: []u8, noalias written: *usize) Error!bool {
    var position = written.*;
    if (bits.source.len - bits.position < 8 or output.len - position < 8) return false;
    bits.refillWide();
    var entry = fixed_payload.literal[@as(usize, @truncate(bits.value)) & 511];
    while (true) {
        const saved = bits.value;
        bits.drop(entry.bits);
        if (entry.literals != 0) {
            if (fixedFiveLiterals(entry, bits, output[position..][0..5])) {
                position += 5;
                if (bits.source.len - bits.position < 8 or output.len - position < 8) break;
                entry = fixed_payload.literal[@as(usize, @truncate(bits.value)) & 511];
                bits.refillWide();
                continue;
            }
            output[position] = @intCast(entry.value);
            position += 1;
            extra: {
                inline for (0..4) |_| {
                    const next = fixed_payload.literal[@as(usize, @truncate(bits.value)) & 511];
                    if (next.literals == 0) break :extra;
                    bits.drop(next.bits);
                    output[position] = @intCast(next.value);
                    position += 1;
                }
            }
            if (bits.source.len - bits.position < 8 or output.len - position < 8) break;
            entry = fixed_payload.literal[@as(usize, @truncate(bits.value)) & 511];
            bits.refillWide();
            continue;
        }
        if (entry.unused != 0) {
            if (entry.value == 0) {
                written.* = position;
                return true;
            }
            // The fixed constructor tags only symbol 285: length 258, no extra bits. Distance and
            // capacity checks retain the ordinary error precedence.
            const offset_entry = fixed_payload.distance[@as(usize, @truncate(bits.value)) & 31];
            const offset_saved = bits.value;
            bits.drop(offset_entry.bits);
            if (offset_entry.value == 0) return error.InvalidStream;
            const offset: usize = offset_entry.value + distancePayloadValue(
                .{ .entry = offset_entry, .saved_value = offset_saved },
            );
            if (offset > position) return error.InvalidStream;
            if (258 > output.len - position) return error.OutputTooSmall;
            const again = bits.source.len - bits.position >= 8 and output.len - position - 258 >= 8;
            if (again) {
                entry = fixed_payload.literal[@as(usize, @truncate(bits.value)) & 511];
                bits.refillWide();
            }
            if (offset >= 8 and offset <= 32) {
                copyWindowPeriod(output[position..][0..258], output[position - offset ..], offset);
            } else {
                @call(.always_inline, copyMatch, .{ output, position, offset, 258 });
            }
            position += 258;
            if (!again) break;
            continue;
        }
        if (entry.value > 258) return error.InvalidStream;
        const length: usize = entry.value + payloadValue(.{ .entry = entry, .saved_value = saved });
        const offset_entry = fixed_payload.distance[@as(usize, @truncate(bits.value)) & 31];
        const offset_saved = bits.value;
        bits.drop(offset_entry.bits);
        if (offset_entry.value == 0) return error.InvalidStream;
        const offset: usize = offset_entry.value + distancePayloadValue(
            .{ .entry = offset_entry, .saved_value = offset_saved },
        );
        if (offset > position) return error.InvalidStream;
        if (length > output.len - position) return error.OutputTooSmall;
        const again = bits.source.len - bits.position >= 8 and output.len - position - length >= 8;
        if (again) {
            entry = fixed_payload.literal[@as(usize, @truncate(bits.value)) & 511];
            bits.refillWide();
        }
        if (length == 3) {
            output[position] = output[position - offset];
            output[position + 1] = output[position - offset + 1];
            output[position + 2] = output[position - offset + 2];
        } else {
            @call(.always_inline, copyMatch, .{ output, position, offset, length });
        }
        position += length;
        if (!again) break;
    }
    written.* = position;
    return false;
}

// The caller guarantees 36 available bits and four output bytes. Stop before consuming a nonliteral
// so EOB, reserved symbols and matches retain normal checks.
fn fixedLiterals(noalias bits: *BitReader, noalias output: *[4]u8) usize {
    inline for (0..4) |index| {
        const root_index = @as(usize, @truncate(bits.value)) & (fixed.literal.root.len - 1);
        const entry = fixed.literal.root[root_index];
        if (entry.value >= 256) return index;
        bits.drop(entry.bits);
        output[index] = @intCast(entry.value);
    }
    return 4;
}

// The eight-byte real-input/output margin admits a complete <=48-bit token. The checked tail owns
// short input/capacity, declared windows and error order.

fn repetitionBlock(
    comptime kind: RepetitionKind,
    noalias bits: *BitReader,
    output: []u8,
    noalias written: *usize,
    noalias literal: *const LiteralTable,
    noalias distance: *const DistanceTable,
) Error!void {
    var position = written.*;
    while (bits.source.len - bits.position >= 8 and output.len - position >= 8) {
        bits.refillWide();
        const decoded = literal.decodePayloadBuffered(
            bits,
            literal.root[@as(usize, @truncate(bits.value)) & (literal.root.len - 1)],
        );
        const entry = decoded.entry;
        if (entry.value < 256) {
            output[position] = @intCast(entry.value);
            position += 1;
            continue;
        }
        if (entry.value == 256) {
            written.* = position;
            return;
        }
        const length: usize = entry.value - 256 + payloadValue(decoded);
        const offset: usize = if (kind == .sixteen) blk: {
            // The constructor admits only complete distance 0/7 or singleton7. A singleton's other
            // one-bit distance_leaf stays invalid. Code7 needs two payload bits; every possible
            // valid offset is 1 or 13..16.
            const distance_leaf = distance.root[bits.takeBuffered(1)];
            if (distance_leaf.bits == 0) return error.InvalidStream;
            std.debug.assert(
                distance_leaf.bits == 1 and !distance_leaf.node and (distance_leaf.value == 1 or
                    distance_leaf.value == 13),
            );
            break :blk if (distance_leaf.value == 1) 1 else 13 + @as(usize, bits.takeBuffered(2));
        } else blk: {
            const decoded_distance = distance.decodePayloadBuffered(
                bits,
                distance.root[@as(usize, @truncate(bits.value)) & (distance.root.len - 1)],
            );
            if (decoded_distance.entry.value == 0) return error.InvalidStream;
            break :blk decoded_distance.entry.value + distancePayloadValue(decoded_distance);
        };
        if (offset > position) return error.InvalidStream;
        if (length > output.len - position) return error.OutputTooSmall;
        if (kind == .window and offset >= 8 and offset <= 32 and length >= 64) {
            @call(
                .never_inline,
                copyWindowPeriod,
                .{ output[position..][0..length], output[position - offset ..], offset },
            );
            position += length;
            continue;
        }
        const periodic = if (kind == .sixteen) offset == 16 else offset == 3 or offset == 5 or
            offset == 6 or offset == 7;
        if (length >= copy_bytes and periodic) {
            if (kind == .sixteen) {
                @call(
                    .always_inline,
                    repeatPeriodic,
                    .{ 16, output[position..][0..length], output[position - offset ..][0..16] },
                );
            } else {
                @call(
                    .always_inline,
                    copyPeriodicBytes,
                    .{ output[position..][0..length], output[position - offset ..], offset },
                );
            }
        } else {
            @call(.always_inline, copyMatch, .{ output, position, offset, length });
        }
        position += length;
    }
    written.* = position;
    try @call(
        .never_inline,
        compressedBlock,
        .{ .tail_dynamic, false, bits, output, written, literal, distance, 0 },
    );
}

test "short-match wide payload wires preserve exact guards and small-window decoding" {
    // Independent RFC 1951 wires have separately stated period-32 goldens, verified with Python
    // zlib 1.3.2. Literal widths are 9/10, EOB is 3 bits, and the one-bit distance tree covers
    // distances 25..32.
    const fixtures = [_]struct {
        source: []const u8,
        size: usize,
        route: header_decoding.DecodePlan,
    }{
        .{
            .source = &frozen_fixtures.short_wide_four_deflate,
            .size = 6464,
            .route = .wide_literal_batch,
        },
        .{
            .source = &frozen_fixtures.short_wide_thirteen_deflate,
            .size = 7004,
            .route = .wide_literal_batch,
        },
        .{ .source = &frozen_fixtures.minimum_wide_deflate, .size = 6404, .route = .wide },
    };
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const seed = [_]u8{
        0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x41,
        0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x41, 0x42,
        0x43, 0x44, 0x45, 0x46, 0x47, 0x41, 0x42, 0x43,
        0x44, 0x45, 0x46, 0x47, 0x41, 0x42, 0x43, 0x44,
    };
    for (fixtures) |fixture| {
        const expected = try allocator.alloc(u8, fixture.size);
        defer allocator.free(expected);
        for (expected, 0..) |*byte, index| byte.* = seed[index % seed.len];
        var bits = BitReader{ .source = fixture.source };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(
            fixture.route,
            try header_decoding.read(false, false, &bits, workspace),
        );
        const backing = try allocator.alloc(u8, fixture.size + 66);
        defer allocator.free(backing);
        const input = try allocator.alloc(u8, fixture.source.len + 16);
        defer allocator.free(input);
        @memcpy(input[0..fixture.source.len], fixture.source);
        @memset(input[fixture.source.len..], 0xd7);
        for (0..32) |alignment| {
            for ([_]usize{ fixture.size, fixture.size + 16 }) |capacity| {
                @memset(backing, 0xa5);
                const output = backing[alignment + 1 ..][0..capacity];
                const decoded = try test_complete.into(
                    input,
                    output,
                    .{ .workspace = workspace },
                    .{},
                );
                try std.testing.expectEqual(fixture.source.len, decoded.consumed);
                try std.testing.expectEqual(fixture.size, decoded.produced);
                try std.testing.expectEqualSlices(u8, expected, output[0..fixture.size]);
                for (backing[0 .. alignment + 1]) |byte| try std.testing.expectEqual(0xa5, byte);
                for (backing[alignment + 1 + fixture.size ..]) |byte| {
                    try std.testing.expectEqual(0xa5, byte);
                }
            }
        }
        const capacities = [_]usize{
            0,
            1,
            3,
            4,
            7,
            8,
            15,
            16,
            32,
            fixture.size - 258,
            fixture.size - 16,
            fixture.size - 1,
        };
        for (capacities) |capacity| {
            @memset(backing, 0xa5);
            try std.testing.expectError(
                error.OutputTooSmall,
                test_complete.into(
                    fixture.source,
                    backing[1..][0..capacity],
                    .{ .workspace = workspace },
                    .{},
                ),
            );
            try std.testing.expectEqual(0xa5, backing[0]);
            for (backing[capacity + 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
        for (0..fixture.source.len) |cut| {
            @memset(backing, 0xa5);
            try std.testing.expectError(
                error.InvalidStream,
                test_complete.into(
                    fixture.source[0..cut],
                    backing[1..][0..fixture.size],
                    .{ .workspace = workspace },
                    .{},
                ),
            );
            try std.testing.expectEqual(0xa5, backing[0]);
            for (backing[fixture.size + 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
        @memset(backing, 0xa5);
        const decoded = try test_complete.into(
            fixture.source,
            backing[1..][0 .. fixture.size + 16],
            .{ .workspace = workspace },
            .{ .window_bytes = 256 },
        );
        try std.testing.expectEqual(fixture.source.len, decoded.consumed);
        try std.testing.expectEqual(fixture.size, decoded.produced);
        try std.testing.expectEqualSlices(u8, expected, backing[1..][0..fixture.size]);
        for (backing[fixture.size + 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "sixteen-byte distance packets preserve all offsets singleton holes and guards" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // Independent RFC 1951 complete literal books: code 285 width 1, literals 0..14 width 5 and
    // literal 15/EOB width 6. Distance0/7 or singleton7 has one-bit codes. Python zlib 1.3.2
    // validates offsets 1,13..16 and rejects the singleton hole.
    const fixtures = [_]struct {
        wire: []const u8,
        offset: usize,
        invalid: bool,
    }{
        .{
            .offset = 1,
            .invalid = false,
            .wire = &[_]u8{
                0xed, 0xc7, 0x01, 0x08, 0x80, 0x20, 0x00, 0x00,
                0xa0, 0xaa, 0xaa, 0xaa, 0x6a, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x14, 0x00, 0x0c, 0x31, 0xe5, 0x52, 0x5b, 0x1f,
                0x73, 0xed, 0x73, 0xdf, 0xc7, 0x0f,
            },
        },
        .{
            .offset = 13,
            .invalid = false,
            .wire = &[_]u8{
                0xed, 0xc7, 0x01, 0x08, 0x80, 0x20, 0x00, 0x00,
                0xa0, 0xaa, 0xaa, 0xaa, 0x6a, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x14, 0x00, 0x0c, 0x31, 0xe5, 0x52, 0x5b, 0x1f,
                0x73, 0xed, 0x73, 0xdf, 0x27, 0x3f,
            },
        },
        .{
            .offset = 14,
            .invalid = false,
            .wire = &[_]u8{
                0xed, 0xc7, 0x01, 0x08, 0x80, 0x20, 0x00, 0x00,
                0xa0, 0xaa, 0xaa, 0xaa, 0x6a, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x14, 0x00, 0x0c, 0x31, 0xe5, 0x52, 0x5b, 0x1f,
                0x73, 0xed, 0x73, 0xdf, 0x67, 0x3f,
            },
        },
        .{
            .offset = 15,
            .invalid = false,
            .wire = &[_]u8{
                0xed, 0xc7, 0x01, 0x08, 0x80, 0x20, 0x00, 0x00,
                0xa0, 0xaa, 0xaa, 0xaa, 0x6a, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x14, 0x00, 0x0c, 0x31, 0xe5, 0x52, 0x5b, 0x1f,
                0x73, 0xed, 0x73, 0xdf, 0xa7, 0x3f,
            },
        },
        .{
            .offset = 16,
            .invalid = false,
            .wire = &[_]u8{
                0xed, 0xc7, 0x01, 0x08, 0x80, 0x20, 0x00, 0x00,
                0xa0, 0xaa, 0xaa, 0xaa, 0x6a, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x14, 0x00, 0x0c, 0x31, 0xe5, 0x52, 0x5b, 0x1f,
                0x73, 0xed, 0x73, 0xdf, 0xe7, 0x3f,
            },
        },
        .{
            .offset = 16,
            .invalid = false,
            .wire = &[_]u8{
                0xed, 0xc7, 0x01, 0x08, 0x80, 0x20, 0x00, 0x00,
                0xa0, 0xaa, 0xaa, 0xaa, 0x6a, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x04, 0x00, 0x0c, 0x31, 0xe5, 0x52, 0x5b, 0x1f,
                0x73, 0xed, 0x73, 0xdf, 0xc7, 0x3f,
            },
        },
        .{
            .offset = 16,
            .invalid = true,
            .wire = &[_]u8{
                0xed, 0xc7, 0x01, 0x08, 0x80, 0x20, 0x00, 0x00,
                0xa0, 0xaa, 0xaa, 0xaa, 0x6a, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x04, 0x00, 0x0c, 0x31, 0xe5, 0x52, 0x5b, 0x1f,
                0x73, 0xed, 0x73, 0xdf, 0xe7, 0x3f,
            },
        },
    };
    const input = try allocator.alloc(u8, 192);
    defer allocator.free(input);
    const output = try allocator.alloc(u8, 512);
    defer allocator.free(output);
    for (fixtures) |fixture| {
        @memset(input, 0x5a);
        @memcpy(input[0..fixture.wire.len], fixture.wire);
        // Real trailing input keeps the specialized prefix eligible for the match; the decoder must
        // still publish the exact first-stream consumed count.
        const source = input[0 .. fixture.wire.len + 16];
        @memset(output, 0xa5);
        if (fixture.invalid) {
            try std.testing.expectError(
                error.InvalidStream,
                test_complete.into(source, output[1..275], .{ .workspace = workspace }, .{}),
            );
            for (output[275..]) |byte| try std.testing.expectEqual(0xa5, byte);
        } else {
            const result = try test_complete.into(
                source,
                output[1..291],
                .{ .workspace = workspace },
                .{},
            );
            try std.testing.expectEqual(fixture.wire.len, result.consumed);
            try std.testing.expectEqual(274, result.produced);
            for (0..16) |index| try std.testing.expectEqual(index, output[index + 1]);
            for (0..258) |index| {
                const expected: u8 = @intCast(16 - fixture.offset + index % fixture.offset);
                try std.testing.expectEqual(expected, output[index + 17]);
            }
            for (output[275..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
        try std.testing.expectEqual(0xa5, output[0]);
        for (output[291..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "consecutive matches preserve dependent history boundaries and invalid second tokens" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // Independent RFC 1951 five-bit LL book: A/B, EOB and all 29 lengths. Singleton distance 9 plus
    // payload 7 selects distance 32. Match lengths are 258,258,3,3,128,5,258,3; Python zlib 1.3.2
    // validates the 948-byte AB golden and rejects the second distance's unused singleton leaf. The
    // second match borrows newly written history from the first; copy order must stay intact.
    const wire = [_]u8{
        0xed, 0xc9, 0x01, 0x04, 0x00, 0x20, 0x00, 0x00,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x0f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x1f, 0x40, 0x00, 0x02, 0x08, 0x20, 0x80, 0x00,
        0x02, 0x08, 0x20, 0x80, 0x00, 0x02, 0x08, 0x20,
        0x80, 0x00, 0x02, 0x08, 0x20, 0x80, 0xef, 0xfb,
        0xfb, 0x8e, 0x1d, 0xfb, 0x6a, 0xa7, 0xfe, 0xbe,
        0x63, 0x47,
    };
    const input = try allocator.alloc(u8, wire.len + 16);
    defer allocator.free(input);
    @memcpy(input[0..wire.len], &wire);
    @memset(input[wire.len..], 0x5a);
    const expected = try allocator.alloc(u8, 948);
    defer allocator.free(expected);
    for (expected, 0..) |*byte, index| byte.* = if (index % 2 == 0) 'A' else 'B';
    const backing = try allocator.alloc(u8, 1024);
    defer allocator.free(backing);
    var bits = BitReader{ .source = &wire };
    try std.testing.expectEqual(1, try bits.take(1));
    try std.testing.expectEqual(2, try bits.take(2));
    try std.testing.expectEqual(
        header_decoding.DecodePlan.match_payload,
        try header_decoding.read(false, false, &bits, workspace),
    );
    for (0..951) |capacity| {
        @memset(backing, 0xa5);
        const output = backing[1..][0..capacity];
        if (capacity < expected.len) {
            try std.testing.expectError(
                error.OutputTooSmall,
                test_complete.into(input, output, .{ .workspace = workspace }, .{}),
            );
        } else {
            const result = try test_complete.into(input, output, .{ .workspace = workspace }, .{});
            try std.testing.expectEqual(wire.len, result.consumed);
            try std.testing.expectEqual(expected.len, result.produced);
            try std.testing.expectEqualSlices(u8, expected, output[0..result.produced]);
            for (output[result.produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
        try std.testing.expectEqual(0xa5, backing[0]);
        for (backing[capacity + 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
    @memset(backing, 0xa5);
    input[73] ^= 1;
    try std.testing.expectError(
        error.InvalidStream,
        test_complete.into(input, backing[1..][0..expected.len], .{ .workspace = workspace }, .{}),
    );
    try std.testing.expectEqual(0xa5, backing[0]);
    for (backing[expected.len + 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
}

test "both encodings of length 258 preserve continuation history and boundaries" {
    const raw = &frozen_fixtures.length_258_two_codes_deflate;
    // Independent wire: 128 byte codes of width 12, literal 128/EOB/all 29 lengths of width 5,
    // singleton distance 9. Seed0..31 then284+31 and285 each copy258 bytes at distance 32. Python
    // zlib independently validates the complete golden.
    const workspace = try DecodeWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var header = BitReader{ .source = raw };
    try std.testing.expectEqual(1, try header.take(1));
    try std.testing.expectEqual(2, try header.take(2));
    try std.testing.expectEqual(
        header_decoding.DecodePlan.wide_match_payload,
        try header_decoding.read(false, false, &header, workspace),
    );
    const backing = try std.testing.allocator.alloc(u8, 580 + 128);
    defer std.testing.allocator.free(backing);
    const golden = try std.testing.allocator.alloc(u8, 548);
    defer std.testing.allocator.free(golden);
    for (golden, 0..) |*byte, index| byte.* = @intCast(index % 32);
    var framed: [raw.len + 16]u8 = @splat(0xa7);
    @memcpy(framed[0..raw.len], raw);
    for ([_][]const u8{ raw, &framed }) |source| {
        for (0..581) |capacity| {
            @memset(backing, 0xd1);
            const output = backing[64..][0..capacity];
            if (capacity < golden.len) {
                try std.testing.expectError(
                    error.OutputTooSmall,
                    test_complete.into(source, output, .{ .workspace = workspace }, .{}),
                );
            } else {
                const result = try test_complete.into(
                    source,
                    output,
                    .{ .workspace = workspace },
                    .{},
                );
                try std.testing.expectEqual(raw.len, result.consumed);
                try std.testing.expectEqual(golden.len, result.produced);
                try std.testing.expectEqualSlices(u8, golden, output[0..golden.len]);
                for (output[golden.len..]) |byte| try std.testing.expectEqual(0xd1, byte);
            }
            for (backing[0..64]) |byte| try std.testing.expectEqual(0xd1, byte);
            for (backing[64 + capacity ..]) |byte| try std.testing.expectEqual(0xd1, byte);
        }
    }
    // The independent writer locates the second singleton distance bit at 1066. Selecting its
    // unused leaf must fail after the first match, even with lookahead.
    framed[1066 / 8] ^= 1 << (1066 % 8);
    @memset(backing, 0xd1);
    try std.testing.expectError(
        error.InvalidStream,
        test_complete.into(&framed, backing[64..][0..580], .{ .workspace = workspace }, .{}),
    );
    try std.testing.expectEqualSlices(u8, golden[0..290], backing[64..][0..290]);
    for (backing[0..64]) |byte| try std.testing.expectEqual(0xd1, byte);
    for (backing[64 + 290 ..]) |byte| try std.testing.expectEqual(0xd1, byte);
}

test "narrow payloads keep both length 258 encodings and exact boundaries" {
    const raw = &frozen_fixtures.length_258_two_codes_narrow_deflate;
    // Independent wire: 196 byte codes of width 8 and EOB/all 29 lengths of width 7, singleton
    // distance 9. Seed0..31 then284+31 and285 each copy258 bytes at distance 32. Python zlib
    // independently validates the complete golden.
    const workspace = try DecodeWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var header = BitReader{ .source = raw };
    try std.testing.expectEqual(1, try header.take(1));
    try std.testing.expectEqual(2, try header.take(2));
    try std.testing.expectEqual(
        header_decoding.DecodePlan.literal_batch,
        try header_decoding.read(false, false, &header, workspace),
    );
    const backing = try std.testing.allocator.alloc(u8, 580 + 128);
    defer std.testing.allocator.free(backing);
    const golden = try std.testing.allocator.alloc(u8, 548);
    defer std.testing.allocator.free(golden);
    for (golden, 0..) |*byte, index| byte.* = @intCast(index % 32);
    var framed: [raw.len + 16]u8 = @splat(0xa7);
    @memcpy(framed[0..raw.len], raw);
    for ([_][]const u8{ raw, &framed }) |source| {
        for (0..581) |capacity| {
            @memset(backing, 0xd1);
            const output = backing[64..][0..capacity];
            if (capacity < golden.len) {
                try std.testing.expectError(
                    error.OutputTooSmall,
                    test_complete.into(source, output, .{ .workspace = workspace }, .{}),
                );
            } else {
                const result = try test_complete.into(
                    source,
                    output,
                    .{ .workspace = workspace },
                    .{},
                );
                try std.testing.expectEqual(raw.len, result.consumed);
                try std.testing.expectEqual(golden.len, result.produced);
                try std.testing.expectEqualSlices(u8, golden, output[0..golden.len]);
                for (output[golden.len..]) |byte| try std.testing.expectEqual(0xd1, byte);
            }
            for (backing[0..64]) |byte| try std.testing.expectEqual(0xd1, byte);
            for (backing[64 + capacity ..]) |byte| try std.testing.expectEqual(0xd1, byte);
        }
    }
    // The independent writer locates the second singleton distance bit at 942. Selecting its unused
    // leaf must fail after the first match, even with lookahead.
    framed[942 / 8] ^= 1 << (942 % 8);
    @memset(backing, 0xd1);
    try std.testing.expectError(
        error.InvalidStream,
        test_complete.into(&framed, backing[64..][0..580], .{ .workspace = workspace }, .{}),
    );
    try std.testing.expectEqualSlices(u8, golden[0..290], backing[64..][0..290]);
    for (backing[0..64]) |byte| try std.testing.expectEqual(0xd1, byte);
    for (backing[64 + 290 ..]) |byte| try std.testing.expectEqual(0xd1, byte);
}

test "raw window-period streams preserve history and exact boundaries" {
    // Python zlib 1.3.2 level6 encodes 4MiB+47 bytes repeating seed[i]=(31*i+7)&255. An independent
    // RFC parser confirms all matches, exact framing and the golden.
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const size = 4 * 1024 * 1024 + 47;
    const backing = try allocator.alloc(u8, size + 128);
    defer allocator.free(backing);
    const cases = [_]struct {
        wire: []const u8,
        period: usize,
    }{
        .{ .wire = &frozen_fixtures.window_period9_deflate, .period = 9 },
        .{ .wire = &frozen_fixtures.window_period24_deflate, .period = 24 },
    };
    for (cases) |fixture| {
        var bits = BitReader{ .source = fixture.wire };
        _ = try bits.take(1);
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(
            header_decoding.DecodePlan.window_period,
            try header_decoding.read(false, false, &bits, workspace),
        );
        @memset(backing, 0xa5);
        const output = backing[64 .. backing.len - 64];
        const result = try test_complete.into(
            fixture.wire,
            output,
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(fixture.wire.len, result.consumed);
        try std.testing.expectEqual(size, result.produced);
        for (output, 0..) |byte, index| {
            try std.testing.expectEqual(@as(u8, @truncate(index % fixture.period * 31 + 7)), byte);
        }
        for (backing[0..64]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (backing[backing.len - 64 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        @memset(backing, 0xa5);
        try std.testing.expectError(
            error.OutputTooSmall,
            test_complete.into(
                fixture.wire,
                output[0 .. size - 1],
                .{ .workspace = workspace },
                .{},
            ),
        );
        for (backing[64 + size - 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "raw ordinary small periods retain phase and exact bounds" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const output_bytes = 4096 + 47;
    const backing = try allocator.alloc(u8, output_bytes + 64);
    defer allocator.free(backing);
    // Independent RFC 1951 wires use a complete six-bit LL book: literals 0..33, EOB and all 29
    // lengths. A singleton distance code selects period 3, 5, 6 or 7. Symbol 285's six-bit code
    // bypasses the short maximum-length rule. Literals cover 34/64 of the prefix space, excluding
    // paired admission. Python zlib 1.3.2 verifies each byte i%period; early match lengths
    // 8/15/16/31/32/33 exercise pattern widths and phase before long runs.
    const cases = .{
        .{ .period = 3, .source = &frozen_fixtures.general_small_period3_deflate },
        .{ .period = 5, .source = &frozen_fixtures.general_small_period5_deflate },
        .{ .period = 6, .source = &frozen_fixtures.general_small_period6_deflate },
        .{ .period = 7, .source = &frozen_fixtures.general_small_period7_deflate },
    };
    inline for (cases) |fixture| {
        const period = fixture.period;
        const source = fixture.source;
        var bits = BitReader{ .source = source };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(
            header_decoding.DecodePlan.short_period,
            try header_decoding.read(false, false, &bits, workspace),
        );
        for (0..33) |alignment| {
            @memset(backing, 0xa5);
            const output = backing[alignment..][0 .. output_bytes + 32];
            const result = try test_complete.into(source, output, .{ .workspace = workspace }, .{});
            try std.testing.expectEqual(source.len, result.consumed);
            try std.testing.expectEqual(output_bytes, result.produced);
            for (output[0..output_bytes], 0..) |byte, index| {
                try std.testing.expectEqual(@as(u8, @intCast(index % period)), byte);
            }
            for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xa5, byte);
            for (backing[alignment + output_bytes ..]) |byte| {
                try std.testing.expectEqual(0xa5, byte);
            }
        }
        @memset(backing, 0xa5);
        try std.testing.expectError(
            error.OutputTooSmall,
            test_complete.into(
                source,
                backing[1..][0 .. output_bytes - 1],
                .{ .workspace = workspace },
                .{},
            ),
        );
        try std.testing.expectEqual(0xa5, backing[0]);
        for (backing[output_bytes..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "exact-size batched payloads preserve independent bytes framing and outside guards" {
    // Existing independent RFC wires, checked with Python zlib 1.3.2, contain distance-32 matches
    // and wide literal batches. Their output exceeds the rounded-copy margin, so this checks the
    // changed integrated prefix route.
    const fixtures = [_]struct {
        source: []const u8,
        size: usize,
    }{
        .{ .source = &frozen_fixtures.short_wide_four_deflate, .size = 6464 },
        .{ .source = &frozen_fixtures.short_wide_thirteen_deflate, .size = 7004 },
    };
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const seed = [_]u8{
        0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x41,
        0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x41, 0x42,
        0x43, 0x44, 0x45, 0x46, 0x47, 0x41, 0x42, 0x43,
        0x44, 0x45, 0x46, 0x47, 0x41, 0x42, 0x43, 0x44,
    };
    for (fixtures) |fixture| {
        const expected = try allocator.alloc(u8, fixture.size);
        defer allocator.free(expected);
        for (expected, 0..) |*byte, i| byte.* = seed[i % seed.len];
        var bits = BitReader{ .source = fixture.source };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(
            header_decoding.DecodePlan.wide_literal_batch,
            try header_decoding.read(false, false, &bits, workspace),
        );
        const input = try allocator.alloc(u8, fixture.source.len + 32);
        defer allocator.free(input);
        @memcpy(input[0..fixture.source.len], fixture.source);
        @memset(input[fixture.source.len..], 0xd7);
        const backing = try allocator.alloc(u8, fixture.size + 96);
        defer allocator.free(backing);
        for (0..33) |alignment| {
            const capacities = [_]usize{
                0,
                1,
                3,
                8,
                32,
                fixture.size - 298,
                fixture.size - 16,
                fixture.size - 1,
                fixture.size,
                fixture.size + 1,
                fixture.size + 32,
            };
            for (capacities) |capacity| {
                @memset(backing, 0xa5);
                const output = backing[alignment..][0..capacity];
                if (capacity < fixture.size) {
                    try std.testing.expectError(
                        error.OutputTooSmall,
                        test_complete.into(
                            input,
                            output,
                            .{ .workspace = workspace },
                            .{ .output_size = .exact },
                        ),
                    );
                } else if (capacity > fixture.size) {
                    try std.testing.expectError(
                        error.OutputSizeMismatch,
                        test_complete.into(
                            input,
                            output,
                            .{ .workspace = workspace },
                            .{ .output_size = .exact },
                        ),
                    );
                } else {
                    const result = try test_complete.into(
                        input,
                        output,
                        .{ .workspace = workspace },
                        .{ .output_size = .exact },
                    );
                    try std.testing.expectEqual(fixture.source.len, result.consumed);
                    try std.testing.expectEqual(fixture.size, result.produced);
                    try std.testing.expectEqualSlices(u8, expected, output);
                }
                for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xa5, byte);
                for (backing[alignment + capacity ..]) |byte| {
                    try std.testing.expectEqual(0xa5, byte);
                }
            }
        }
        for (0..fixture.source.len) |cut| {
            @memset(backing, 0xa5);
            try std.testing.expectError(
                error.InvalidStream,
                test_complete.into(
                    fixture.source[0..cut],
                    backing[0..fixture.size],
                    .{ .workspace = workspace },
                    .{ .output_size = .exact },
                ),
            );
            for (backing[fixture.size..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
    }
}

test "dynamic literal pairs preserve codebook transitions tails and exact output bounds" {
    // Independent RFC 1951 wire, admitted by Python zlib 1.3.2 and disassembled by infgen 1e36c3da.
    // Five blocks use singleton distance one, one-bit distances one/two, ordinary five-bit
    // literals, a single EOB, then singleton distance one. The paired trees contain codes 1..15;
    // matches use lengths 3/258. Bytes 0/255 exercise repeated and mixed packet words independently
    // of the production table.
    const fixture = paired_literals;
    try checkDynamicFixture(fixture.source, fixture.expected, fixture.invalid_distance_bit, true);
}

test "dense paired codebooks preserve continuation reuse and packet boundaries" {
    const fixture = paired_dense;
    try checkDynamicFixture(fixture.source, fixture.expected, fixture.invalid_distance_bit, false);
}

test "general-distance literal pairs preserve continuations tails and exact output bounds" {
    const fixture = general_pairs;
    try checkDynamicFixture(fixture.source, fixture.expected, fixture.invalid_distance_bit, false);
}

test "literal prefixes preserve length payloads tails and invalid distances" {
    // Independently emitted RFC 1951 wire: 32 five-bit LL codes for A/B, EOB and all 29 lengths;
    // singleton distance 9 plus payload 7 selects distance 32. After 128 AB seed bytes, each of 18
    // literals precedes a match with length 3..18, 34 or 258. Python zlib 1.3.2 validates the
    // separate 606-byte golden and rejects the first distance's unused singleton leaf at bit 1313.
    // The longest match uses code 284 plus31; the two-code fixtures also cover285.
    try checkDynamicFixture(
        &frozen_fixtures.literal_length_prefixes_deflate,
        &frozen_fixtures.literal_length_prefixes_golden,
        1313,
        true,
    );
}

test "wide literal roots preserve deep matches tails and exact output bounds" {
    const fixture = wide_literals;
    try checkDynamicFixture(fixture.source, &fixture.expected, fixture.invalid_distance_bit, false);
}

test "external stored fixed dynamic and cross-block streams decode exactly" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const output = try allocator.alloc(u8, 33152 + 16);
    defer allocator.free(output);
    for ([_][]const u8{ &.{ 3, 0 }, &.{ 1, 0, 0, 255, 255 } }) |source| {
        const result = try test_complete.into(source, &.{}, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(source.len, result.consumed);
        try std.testing.expectEqual(0, result.produced);
    }
    const hello = &frozen_fixtures.hello_deflate;
    const decoded = try test_complete.into(hello, output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(hello.len, decoded.consumed);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x68, 0x65,
            0x6c, 0x6c, 0x6f, 0x20, 0x68, 0x65, 0x6c, 0x6c,
            0x6f, 0x0a,
        },
        output[0..decoded.produced],
    );

    const cases = .{
        .{
            .source = &frozen_fixtures.runs_deflate,
            .pattern = [_]u8{ 0x61, 0x62, 0x63 },
            .size = 30000,
        },
        .{
            .source = &frozen_fixtures.blocks_deflate,
            .pattern = [_]u8{ 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68 },
            .size = 16000,
        },
    };
    inline for (cases) |fixture| {
        const result = try test_complete.into(
            fixture.source,
            output,
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(fixture.source.len, result.consumed);
        try std.testing.expectEqual(fixture.size, result.produced);
        for (output[0..result.produced], 0..) |byte, index| {
            try std.testing.expectEqual(fixture.pattern[index % fixture.pattern.len], byte);
        }
    }
    const skew = &frozen_fixtures.skew_deflate;
    const result = try test_complete.into(skew, output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(skew.len, result.consumed);
    try std.testing.expectEqual(33152, result.produced);
    var position: usize = 0;
    for (0..256) |symbol| {
        try std.testing.expectEqual(@as(u8, @intCast(symbol)), output[position]);
        position += 1;
        for (output[position..][0 .. symbol + 1]) |byte| try std.testing.expectEqual('a', byte);
        position += symbol + 1;
    }
}

test "fixed literal prefixes retain exact boundaries history and invalid symbols" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // Canonical RFC fixed codes, independently accepted by Python zlib 1.3.2. Nine-bit literals
    // 200..207 put EOB at each prefix length and refill position.
    const expected = [_]u8{ 200, 201, 202, 203, 204, 205, 206, 207 };
    const prefixes = [_][]const u8{
        &[_]u8{ 0x03, 0x00 },
        &[_]u8{ 0x3b, 0x01, 0x00 },
        &[_]u8{ 0x3b, 0x71, 0x12, 0x00 },
        &[_]u8{ 0x3b, 0x71, 0xf2, 0x14, 0x00 },
        &[_]u8{ 0x3b, 0x71, 0xf2, 0xd4, 0x69, 0x00 },
        &[_]u8{ 0x3b, 0x71, 0xf2, 0xd4, 0xe9, 0x33, 0x00 },
        &[_]u8{ 0x3b, 0x71, 0xf2, 0xd4, 0xe9, 0x33, 0x67, 0x01 },
        &[_]u8{ 0x3b, 0x71, 0xf2, 0xd4, 0xe9, 0x33, 0x67, 0xcf, 0x01, 0x00 },
        &[_]u8{ 0x3b, 0x71, 0xf2, 0xd4, 0xe9, 0x33, 0x67, 0xcf, 0x9d, 0x07, 0x00 },
    };
    var output: [16]u8 = undefined;
    var with_trailing: [19]u8 = undefined;
    for (prefixes, 0..) |source, length| {
        const exact = try test_complete.into(
            source,
            output[0..length],
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(source.len, exact.consumed);
        try std.testing.expectEqual(length, exact.produced);
        try std.testing.expectEqualSlices(u8, expected[0..length], output[0..length]);
        for (0..source.len) |end| {
            try std.testing.expectError(
                error.InvalidStream,
                test_complete.into(source[0..end], &output, .{ .workspace = workspace }, .{}),
            );
        }
        for (0..length) |capacity| {
            try std.testing.expectError(
                error.OutputTooSmall,
                test_complete.into(source, output[0..capacity], .{ .workspace = workspace }, .{}),
            );
        }
        @memset(&output, 0x5a);
        @memcpy(with_trailing[0..source.len], source);
        @memcpy(
            with_trailing[source.len..][0..8],
            &[_]u8{ 0x74, 0x72, 0x61, 0x69, 0x6c, 0x69, 0x6e, 0x67 },
        );
        const trailing = try test_complete.into(
            with_trailing[0 .. source.len + 8],
            &output,
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(source.len, trailing.consumed);
        try std.testing.expectEqual(length, trailing.produced);
        try std.testing.expectEqualSlices(u8, expected[0..length], output[0..length]);
        for (output[length..]) |byte| try std.testing.expectEqual(0x5a, byte);
    }
    // Five literals, length 3/distance 1, EOB; the match uses the published prefix.
    const matched = [_]u8{ 0x3b, 0x71, 0xf2, 0xd4, 0xe9, 0x33, 0x40, 0x00, 0x00 };
    @memset(&output, 0x5a);
    const decoded = try test_complete.into(&matched, &output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(matched.len, decoded.consumed);
    try std.testing.expectEqual(8, decoded.produced);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 200, 201, 202, 203, 204, 204, 204, 204 },
        output[0..8],
    );
    for (output[8..]) |byte| try std.testing.expectEqual(0x5a, byte);
    // Reserved symbol 286 after four literals; zlib independently refuses it.
    try std.testing.expectError(
        error.InvalidStream,
        test_complete.into(
            &[_]u8{ 0x3b, 0x71, 0xf2, 0xd4, 0xe9, 0x31, 0x00 },
            &output,
            .{ .workspace = workspace },
            .{},
        ),
    );
}

test "raw boundary ignores trailing bytes and checks every truncation and output limit" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const fixtures = .{
        .{ .source = &frozen_fixtures.hello_deflate, .size = 18 },
        .{ .source = &frozen_fixtures.runs_deflate, .size = 30000 },
        .{ .source = &frozen_fixtures.skew_deflate, .size = 33152 },
        .{ .source = &frozen_fixtures.blocks_deflate, .size = 16000 },
    };
    const output = try allocator.alloc(u8, 33152 + 16);
    defer allocator.free(output);
    inline for (fixtures) |fixture| {
        for (0..fixture.source.len) |length| {
            try std.testing.expectError(
                error.InvalidStream,
                test_complete.into(
                    fixture.source[0..length],
                    output,
                    .{ .workspace = workspace },
                    .{},
                ),
            );
        }
        @memset(output, 0x5a);
        const result = try test_complete.into(
            fixture.source ++ [_]u8{ 0x74, 0x72, 0x61, 0x69, 0x6c, 0x69, 0x6e, 0x67 },
            output,
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(fixture.source.len, result.consumed);
        try std.testing.expectEqual(fixture.size, result.produced);
        for (output[result.produced..]) |byte| try std.testing.expectEqual(0x5a, byte);
        try std.testing.expectError(
            error.OutputTooSmall,
            test_complete.into(
                fixture.source,
                output[0 .. fixture.size - 1],
                .{ .workspace = workspace },
                .{},
            ),
        );
    }
}

test "RFC wire facts reach maximum history distance and reject reserved symbols" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // A nonfinal stored block supplies 32768 bytes before final fixed/dynamic blocks encode length
    // 258, maximum distance extras and EOB.
    const source = try allocator.alloc(u8, 5 + 32768 + 171);
    defer allocator.free(source);
    @memcpy(source[0..5], &[_]u8{ 0, 0, 128, 255, 127 });
    for (source[5..][0..32768], 0..) |*byte, index| byte.* = @truncate(index * 31 + index / 17);
    const output_backing = try allocator.alloc(u8, 1 + 32768 + 258 + 16);
    defer allocator.free(output_backing);
    const output = output_backing[1..][0 .. 32768 + 258];
    const fixtures = [_]struct {
        tail: []const u8,
        distance: usize,
    }{
        .{ .tail = &.{ 0x1b, 0xbd, 0xff, 0x1f, 0 }, .distance = 32768 },
        .{ .tail = &frozen_fixtures.distance_direct_min_deflate, .distance = 24577 },
        .{ .tail = &frozen_fixtures.distance_direct_max_deflate, .distance = 32768 },
        .{ .tail = &frozen_fixtures.distance_continued_max_deflate, .distance = 32768 },
    };
    // Independent RFC 1951 dynamic tails, accepted by Python zlib 1.3.2. The literal tree gives
    // EOB/285 one-bit codes. Direct distance 0/29 codes use one bit; the continued tree gives 29 a
    // fifteen-bit code. Thirteen extra bits select the lower and upper endpoints of the maximum
    // distance range.
    for (fixtures) |fixture| {
        @memcpy(source[32773..][0..fixture.tail.len], fixture.tail);
        const encoded = source[0 .. 32773 + fixture.tail.len];
        @memset(output_backing, 0x5a);
        const result = try test_complete.into(encoded, output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(encoded.len, result.consumed);
        try std.testing.expectEqual(output.len, result.produced);
        for (output, 0..) |byte, index| {
            const original = if (index < 32768) index else index - fixture.distance;
            try std.testing.expectEqual(@as(u8, @truncate(original * 31 + original / 17)), byte);
        }
        for (output_backing[0..1]) |byte| try std.testing.expectEqual(0x5a, byte);
        for (output_backing[1 + output.len ..]) |byte| try std.testing.expectEqual(0x5a, byte);
        for (0..fixture.tail.len) |length| {
            try std.testing.expectError(
                error.InvalidStream,
                test_complete.into(
                    source[0 .. 32773 + length],
                    output,
                    .{ .workspace = workspace },
                    .{},
                ),
            );
        }
        try std.testing.expectError(
            error.OutputTooSmall,
            test_complete.into(
                encoded,
                output[0 .. output.len - 1],
                .{ .workspace = workspace },
                .{},
            ),
        );
    }
    // Final fixed blocks: reserved literal/length 286; reserved distance 30; length 3 / distance 1
    // with no preceding output. Reserved BTYPE is also invalid.
    for (
        [_][]const u8{ &.{ 0x1b, 3 }, &.{ 3, 0x3e }, &.{ 3, 2 }, &.{7}, &.{ 1, 1, 0, 255, 255 } },
    ) |invalid| try std.testing.expectError(
        error.InvalidStream,
        test_complete.into(invalid, output, .{ .workspace = workspace }, .{}),
    );
}

test "maximum-width dynamic tokens preserve history boundaries and byte alignment" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const tail = &frozen_fixtures.maximum_width_tokens_deflate;
    const source_length = 5 + 32768 + tail.len;
    const output_length = 32768 + 24 + 64 * 257 + 64 * 3;
    const source_storage = try allocator.alloc(u8, source_length + 32 + 16);
    defer allocator.free(source_storage);
    const output_storage = try allocator.alloc(u8, output_length + 32 + 64);
    defer allocator.free(output_storage);

    // Independent RFC 1951 wire, accepted by Python zlib 1.3.2. A stored block supplies 32768
    // history bytes. Six length-4/distance-33 matches align the following tokens to bit zero. Each
    // of 64 length-257/distance-32768 matches consumes the maximum 15 + 5 + 15 + 13 = 48 bits.
    // Sixty-four length-3/ distance-33 matches and EOB follow. Both trees require 15-bit
    // continuations; the literal tree also has 64 primary continuation prefixes.
    for (0..32) |alignment| {
        @memset(source_storage, 0xca);
        const source = source_storage[alignment..][0..source_length];
        @memcpy(source[0..5], &[_]u8{ 0, 0, 128, 255, 127 });
        for (source[5..][0..32768], 0..) |*byte, index| byte.* = @truncate(index * 31 + index / 17);
        @memcpy(source[32773..], tail);
        for ([_]usize{ 0, 17 }) |spare| {
            @memset(output_storage, 0x5a);
            const output = output_storage[alignment..][0 .. output_length + spare];
            const trailer_length: usize = if (spare == 0) 0 else 16;
            const encoded = source_storage[alignment..][0 .. source_length + trailer_length];
            const result = try test_complete.into(
                encoded,
                output,
                .{ .workspace = workspace },
                .{},
            );
            try std.testing.expectEqual(source_length, result.consumed);
            try std.testing.expectEqual(output_length, result.produced);
            for (output[0..output_length], 0..) |byte, index| {
                const history_index = blk: {
                    if (index < 32768) break :blk index;
                    if (index < 32792) break :blk 32735 + index - 32768;
                    if (index < 49240) break :blk 24 + index - 32792;
                    break :blk 16439 + (index - 49240) % 33;
                };
                try std.testing.expectEqual(
                    @as(u8, @truncate(history_index * 31 + history_index / 17)),
                    byte,
                );
            }
            for (output_storage[0..alignment]) |byte| try std.testing.expectEqual(0x5a, byte);
            for (output_storage[alignment + output_length ..]) |byte| {
                try std.testing.expectEqual(0x5a, byte);
            }
        }
    }

    const source = source_storage[31..][0..source_length];
    for (0..tail.len) |length| {
        @memset(output_storage, 0x5a);
        try std.testing.expectError(
            error.InvalidStream,
            test_complete.into(
                source[0 .. 32773 + length],
                output_storage[1..][0..output_length],
                .{ .workspace = workspace },
                .{},
            ),
        );
        try std.testing.expectEqual(0x5a, output_storage[0]);
        for (output_storage[1 + output_length ..]) |byte| try std.testing.expectEqual(0x5a, byte);
    }
    @memset(output_storage, 0x5a);
    try std.testing.expectError(
        error.OutputTooSmall,
        test_complete.into(
            source,
            output_storage[1..][0 .. output_length - 1],
            .{ .workspace = workspace },
            .{},
        ),
    );
    try std.testing.expectEqual(0x5a, output_storage[0]);
    for (output_storage[output_length..]) |byte| try std.testing.expectEqual(0x5a, byte);
}

test "general-distance pairs preserve maximum-width matches and continuation budgets" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const tail = general_pairs.maximum_tail;
    const source_length = 32773 + tail.len;
    const output_length = 32768 + 4 + 64 * 257;
    const source_storage = try allocator.alloc(u8, source_length + 64);
    defer allocator.free(source_storage);
    const output_backing = try allocator.alloc(u8, output_length + 64);
    defer allocator.free(output_backing);
    const expected = try allocator.alloc(u8, output_length);
    defer allocator.free(expected);
    for (expected[0..32768], 0..) |*byte, i| byte.* = @truncate(i * 31 + i / 17);
    @memcpy(expected[32768..][0..4], &[_]u8{ 5, 7, 11, 13 });
    for (expected[32772..], 4..) |*byte, history| byte.* = @truncate(history * 31 + history / 17);
    for (1..33) |alignment| {
        @memset(source_storage, 0xca);
        const source = source_storage[alignment..][0..source_length];
        @memcpy(source[0..5], &[_]u8{ 0, 0, 128, 255, 127 });
        @memcpy(source[5..][0..32768], expected[0..32768]);
        @memcpy(source[32773..], tail);
        const capacities = [_]usize{
            32767,
            32768,
            32769,
            32772,
            33028,
            33029,
            output_length - 1,
            output_length,
            output_length + 17,
        };
        for (capacities) |capacity| {
            @memset(output_backing, 0x5a);
            const output = output_backing[alignment..][0..capacity];
            if (capacity < output_length) {
                try std.testing.expectError(
                    error.OutputTooSmall,
                    test_complete.into(source, output, .{ .workspace = workspace }, .{}),
                );
            } else {
                const result = try test_complete.into(
                    source,
                    output,
                    .{ .workspace = workspace },
                    .{},
                );
                try std.testing.expectEqual(source_length, result.consumed);
                try std.testing.expectEqual(output_length, result.produced);
                try std.testing.expectEqualSlices(u8, expected, output[0..output_length]);
                for (output[output_length..]) |byte| try std.testing.expectEqual(0x5a, byte);
            }
            for (output_backing[0..alignment]) |byte| try std.testing.expectEqual(0x5a, byte);
            for (output_backing[alignment + capacity ..]) |byte| {
                try std.testing.expectEqual(0x5a, byte);
            }
        }
        if (alignment == 1) {
            for (0..tail.len) |end| {
                @memset(output_backing, 0x5a);
                try std.testing.expectError(
                    error.InvalidStream,
                    test_complete.into(
                        source[0 .. 32773 + end],
                        output_backing[alignment..][0..output_length],
                        .{ .workspace = workspace },
                        .{},
                    ),
                );
                for (output_backing[0..alignment]) |byte| try std.testing.expectEqual(0x5a, byte);
                for (output_backing[alignment + output_length ..]) |byte| {
                    try std.testing.expectEqual(0x5a, byte);
                }
            }
        }
        @memset(output_backing, 0x5a);
        const result = try test_complete.into(
            source_storage[alignment..][0 .. source_length + 16],
            output_backing[alignment..][0 .. output_length + 17],
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(source_length, result.consumed);
        try std.testing.expectEqual(output_length, result.produced);
        try std.testing.expectEqualSlices(
            u8,
            expected,
            output_backing[alignment..][0..output_length],
        );
        for (output_backing[alignment + output_length ..]) |byte| {
            try std.testing.expectEqual(0x5a, byte);
        }
    }
}

test "dynamic single-symbol and empty-distance trees retain strict invalid holes" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // RFC 1951 dynamic blocks, HLIT=257/HDIST=1: precode 0 has length 1, 1/18 have length 2. Two
    // zero repeats precede EOB's sole one-bit code. The second valid block also gives literal 0
    // length 1 and writes ten zeros. Python zlib 1.3.2 independently accepts these and rejects all
    // three mutations.
    const empty = [_]u8{ 0x05, 0xc0, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00, 0xa0, 0xff, 0xaf, 0x03 };
    const literals = [_]u8{
        0x05, 0xc0, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00,
        0xa0, 0xfe, 0xaf, 0x0e, 0x00, 0x01,
    };
    // HLIT=258: literal 0/EOB/length 257 have lengths 1/2/2. Distance 0 has a sole one-bit code.
    // Literal zero plus length 3/distance 1 yields four zeros. Python zlib 1.3.2 accepts this and
    // rejects the flipped distance-code hole below.
    const matched = [_]u8{
        0x0d, 0xc0, 0x01, 0x09, 0x00, 0x00, 0x00, 0x80,
        0x20, 0xff, 0xaf, 0x2e, 0x2d,
    };
    // HLIT=258 with the same literal codes; two one-bit distance codes form a complete tree.
    // Literal zero plus length 3/distance 1 again yields four zeros. The flipped distance code
    // requests distance 2 with only one byte of history. Python zlib 1.3.2 independently accepts
    // the valid wire and rejects the history mutation.
    const complete = blk: {
        const prefix = [_]u8{ 0x0d, 0xc1, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80, 0xa0 };
        const zeros: [32]u8 = @splat(0x00);
        const suffix = [_]u8{ 0x5f, 0x16 };
        break :blk prefix ++ zeros ++ suffix;
    };
    // HDIST=32 with all distance lengths five is also complete, but symbols 30/31 remain reserved.
    // Python zlib rejects these too, at its earlier HDIST>30 gate.
    const reserved = blk: {
        const prefix = [_]u8{ 0x0d, 0xdf, 0x01, 0x08, 0x00, 0x20, 0x00, 0x80, 0x20, 0x01 };
        const zeros: [62]u8 = @splat(0x00);
        const middle = [_]u8{ 0x80, 0xfa };
        const fill_2: [7]u8 = @splat(0xff);
        const suffix = [_]u8{0xf7};
        break :blk prefix ++ zeros ++ middle ++ fill_2 ++ suffix;
    };
    var output: [10]u8 = undefined;
    const no_bytes = try test_complete.into(&empty, &.{}, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(empty.len, no_bytes.consumed);
    try std.testing.expectEqual(0, no_bytes.produced);
    const decoded = try test_complete.into(&literals, &output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(literals.len, decoded.consumed);
    try std.testing.expectEqual(10, decoded.produced);
    try std.testing.expectEqualSlices(u8, &@as([10]u8, @splat(0)), &output);
    const cases = .{
        .{ .source = &empty, .size = 0 },
        .{ .source = &literals, .size = 10 },
        .{ .source = &matched, .size = 4 },
        .{ .source = &complete, .size = 4 },
    };
    inline for (cases) |fixture| {
        for (0..fixture.source.len) |length| {
            try std.testing.expectError(
                error.InvalidStream,
                test_complete.into(
                    fixture.source[0..length],
                    &output,
                    .{ .workspace = workspace },
                    .{},
                ),
            );
        }
        @memset(&output, 0x5a);
        const result = try test_complete.into(
            fixture.source ++ [_]u8{ 0x74, 0x72, 0x61, 0x69, 0x6c, 0x69, 0x6e, 0x67 },
            &output,
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(fixture.source.len, result.consumed);
        try std.testing.expectEqual(fixture.size, result.produced);
        const expected: [fixture.size]u8 = @splat(0);
        try std.testing.expectEqualSlices(u8, &expected, output[0..fixture.size]);
        for (output[fixture.size..]) |byte| try std.testing.expectEqual(0x5a, byte);
    }
    const invalid = [_][]const u8{
        // RFC 1951 HLIT values 30/31 request reserved counts 287/288. Python zlib 1.3.2
        // independently rejects these before reading code lengths. Their remaining trees and empty
        // blocks are valid if the counts are admitted.
        &frozen_fixtures.reserved_literal_count_287_deflate,
        &frozen_fixtures.reserved_literal_count_288_deflate,
        // Code-length repeat exceeds the declared alphabet.
        &[_]u8{ 0x05, 0xc0, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00, 0xa0, 0xff, 0xff, 0x01 },
        // Literal/length alphabet omits EOB.
        &[_]u8{ 0x05, 0xc0, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00, 0xa0, 0xff, 0xb7, 0x01 },
        // Singleton EOB selects its unused one-bit code.
        &[_]u8{ 0x05, 0xc0, 0x01, 0x05, 0x00, 0x00, 0x00, 0x00, 0xa0, 0xff, 0xaf, 0x13 },
        // Singleton distance selects its unused one-bit code.
        &[_]u8{ 0x0d, 0xc0, 0x01, 0x09, 0x00, 0x00, 0x00, 0x80, 0x20, 0xff, 0xaf, 0x2e, 0x3d },
        // Distance precedes initialized output history.
        complete[0 .. complete.len - 1] ++ [_]u8{0x1e},
        &reserved ++ [_]u8{0x0b}, // complete tree, reserved distance 30
        &reserved ++ [_]u8{0x0f}, // complete tree, reserved distance 31
    };
    for (invalid) |source| {
        try std.testing.expectError(
            error.InvalidStream,
            test_complete.into(source, &output, .{ .workspace = workspace }, .{}),
        );
    }
}

test "bounded arbitrary input preserves decoder bounds and workspace reuse" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const output = try allocator.alloc(u8, 4096);
    defer allocator.free(output);
    var bytes: [128]u8 = undefined;
    var random: std.Random.DefaultPrng = .init(0x6465666c617465);
    for (0..4096) |iteration| {
        random.random().bytes(&bytes);
        const source = bytes[0 .. iteration % (bytes.len + 1)];
        const result = test_complete.into(
            source,
            output,
            .{ .workspace = workspace },
            .{},
        ) catch continue;
        try std.testing.expect(result.consumed <= source.len);
        try std.testing.expect(result.produced <= output.len);
    }
    const result = try test_complete.into(
        &frozen_fixtures.hello_deflate,
        output,
        .{ .workspace = workspace },
        .{},
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x68, 0x65,
            0x6c, 0x6c, 0x6f, 0x20, 0x68, 0x65, 0x6c, 0x6c,
            0x6f, 0x0a,
        },
        output[0..result.produced],
    );
}

test "paired streams stay between inaccessible pages" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const posix = std.posix;
    const page_size = std.heap.pageSize();
    const memory = try posix.mmap(
        null,
        6 * page_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer posix.munmap(memory);
    for ([_]usize{ 0, 2, 3, 5 }) |page| {
        try std.testing.expectEqual(
            .SUCCESS,
            posix.errno(std.os.linux.mprotect(memory.ptr + page * page_size, page_size, .{})),
        );
    }
    const fixture = general_pairs;
    const input_page = memory[page_size .. 2 * page_size];
    const output_page = memory[4 * page_size .. 5 * page_size];
    const workspace = try DecodeWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    for ([_]usize{ 0, page_size - fixture.source.len }) |input_offset| {
        const source = input_page[input_offset..][0..fixture.source.len];
        @memcpy(source, fixture.source);
        const capacities = [_]usize{
            0,
            1,
            7,
            8,
            9,
            fixture.expected.len - 1,
            fixture.expected.len,
            fixture.expected.len + 8,
        };
        for (capacities) |capacity| {
            for ([_]usize{ 0, page_size - capacity }) |output_offset| {
                @memset(output_page, 0xa5);
                const output = output_page[output_offset..][0..capacity];
                if (capacity < fixture.expected.len) {
                    try std.testing.expectError(
                        error.OutputTooSmall,
                        test_complete.into(source, output, .{ .workspace = workspace }, .{}),
                    );
                } else {
                    const result = try test_complete.into(
                        source,
                        output,
                        .{ .workspace = workspace },
                        .{},
                    );
                    try std.testing.expectEqual(fixture.source.len, result.consumed);
                    try std.testing.expectEqual(fixture.expected.len, result.produced);
                    try std.testing.expectEqualSlices(
                        u8,
                        fixture.expected,
                        output[0..result.produced],
                    );
                    for (output[result.produced..]) |byte| try std.testing.expectEqual(0xa5, byte);
                }
                for (output_page[0..output_offset]) |byte| try std.testing.expectEqual(0xa5, byte);
                for (output_page[output_offset + capacity ..]) |byte| {
                    try std.testing.expectEqual(0xa5, byte);
                }
            }
        }
        const output = output_page[page_size - fixture.expected.len ..];
        for (0..source.len) |length| {
            @memset(output_page, 0xa5);
            try std.testing.expectError(
                error.InvalidStream,
                test_complete.into(source[0..length], output, .{ .workspace = workspace }, .{}),
            );
            for (output_page[0 .. page_size - output.len]) |byte| {
                try std.testing.expectEqual(0xa5, byte);
            }
        }
    }
}

test "whole-token lookahead preserves a following deep code after 48 bits" {
    // Independent RFC 1951 wires, checked by Python zlib 1.3.2. The fixed seed supplies 32768 bytes
    // of history. Dynamic byte 1 consumes six bits, then a byte-aligned token uses a 15-bit length
    // code, five payload bits, a 15-bit distance code and thirteen payload bits. Length
    // 257/distance 32768 precede sixteen deep-coded zero bytes. Both ordinary and wide literal
    // roots apply. Wire SHA-256s: ordinary
    // 886a8fbb9b17015023322e5eed7f030b496feb522fac57c446ef42c49a9af2e4; wide
    // 248a35299be6be9efbebdbadf9ea26400892f66d0ce1129e5c5f2db4de4425a0. Golden SHA-256:
    // 30fbb9cd555aa3affc9cc48508a7c65700afca1636d3bd00a6c389ec732672b5.
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const expected = try allocator.alloc(u8, 33042);
    defer allocator.free(expected);
    @memset(expected[0..32768], 7);
    expected[32768] = 1;
    @memset(expected[32769..33026], 7);
    @memset(expected[33026..], 0);
    const output = try allocator.alloc(u8, expected.len + 128);
    defer allocator.free(output);
    const wires = [_][]const u8{
        &frozen_fixtures.payload_ordinary_deflate,
        &frozen_fixtures.payload_wide_deflate,
    };
    for (wires) |source| {
        const input = try allocator.alloc(u8, source.len + 80);
        defer allocator.free(input);
        for (0..32) |offset| {
            @memset(input, 0xa7);
            @memcpy(input[offset..][0..source.len], source);
            const exact = input[offset..][0..source.len];
            const start = 64 + offset;
            @memset(output, 0xd1);
            const result = try test_complete.into(
                exact,
                output[start..][0 .. expected.len + 16],
                .{ .workspace = workspace },
                .{},
            );
            try std.testing.expectEqual(source.len, result.consumed);
            try std.testing.expectEqual(expected.len, result.produced);
            try std.testing.expectEqualSlices(u8, expected, output[start..][0..expected.len]);
            for (output[0..start]) |byte| try std.testing.expectEqual(0xd1, byte);
            for (output[start + expected.len ..]) |byte| try std.testing.expectEqual(0xd1, byte);

            const trailing = try test_complete.into(
                input[offset..][0 .. source.len + 8],
                output[start..][0..expected.len],
                .{ .workspace = workspace },
                .{},
            );
            try std.testing.expectEqual(source.len, trailing.consumed);
            try std.testing.expectEqual(expected.len, trailing.produced);
            try std.testing.expectEqualSlices(u8, expected, output[start..][0..expected.len]);
            for ([_]usize{ 32768, 32769, 33025, 33026, 33033, 33041 }) |capacity| {
                @memset(output, 0xd1);
                try std.testing.expectError(
                    error.OutputTooSmall,
                    test_complete.into(
                        exact,
                        output[start..][0..capacity],
                        .{ .workspace = workspace },
                        .{},
                    ),
                );
                for (output[0..start]) |byte| try std.testing.expectEqual(0xd1, byte);
                for (output[start + capacity ..]) |byte| try std.testing.expectEqual(0xd1, byte);
            }
        }
        for (0..source.len) |cut| {
            @memset(output, 0xd1);
            try std.testing.expectError(
                error.InvalidStream,
                test_complete.into(
                    source[0..cut],
                    output[64..][0..expected.len],
                    .{ .workspace = workspace },
                    .{},
                ),
            );
            for (output[0..64]) |byte| try std.testing.expectEqual(0xd1, byte);
            for (output[64 + expected.len ..]) |byte| try std.testing.expectEqual(0xd1, byte);
        }
    }
}

test "wide literal groups preserve 37-bit budgets and exact boundaries" {
    // Independent RFC 1951 wire, checked by Python zlib 1.3.2. Each group consumes a deep 15-bit
    // zero followed by two 11-bit root literals. A length-19, distance-one match separates the
    // first group from sixteen more. The complete tree has 66 byte codes and fifteen length codes.
    // Wire SHA-256: 4f22161b51c6e27ca8013569d5cdc04a2d121fe830759a38f544f7a3cc480aaf. Golden
    // SHA-256: 9818970bbf4b8847a0d3533eccb6b29258adbc7077ce48f92014d1abbf27d3b5.
    const source = &frozen_fixtures.payload_literal_budget_deflate;
    const expected = blk: {
        const prefix = [_]u8{ 0x00, 0x01, 0x02 };
        const fill: [19]u8 = @splat(0x02);
        const copies: [16][prefix.len]u8 = @splat(prefix);
        const repeated: [16 * prefix.len]u8 = @bitCast(copies);
        break :blk prefix ++ fill ++ repeated;
    };
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const input = try allocator.alloc(u8, source.len + 80);
    defer allocator.free(input);
    const output = try allocator.alloc(u8, expected.len + 128);
    defer allocator.free(output);
    for (0..32) |offset| {
        @memset(input, 0xa7);
        @memcpy(input[offset..][0..source.len], source);
        const exact = input[offset..][0..source.len];
        const start = 64 + offset;
        @memset(output, 0xd1);
        const result = try test_complete.into(
            exact,
            output[start..][0 .. expected.len + 16],
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(source.len, result.consumed);
        try std.testing.expectEqual(expected.len, result.produced);
        try std.testing.expectEqualSlices(u8, &expected, output[start..][0..expected.len]);
        for (output[0..start]) |byte| try std.testing.expectEqual(0xd1, byte);
        for (output[start + expected.len ..]) |byte| try std.testing.expectEqual(0xd1, byte);
        const trailing = try test_complete.into(
            input[offset..][0 .. source.len + 8],
            output[start..][0..expected.len],
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(source.len, trailing.consumed);
        try std.testing.expectEqual(expected.len, trailing.produced);
        try std.testing.expectEqualSlices(u8, &expected, output[start..][0..expected.len]);
        try std.testing.expectEqualSlices(u8, source, exact);
        for (0..expected.len) |capacity| {
            @memset(output, 0xd1);
            try std.testing.expectError(
                error.OutputTooSmall,
                test_complete.into(
                    exact,
                    output[start..][0..capacity],
                    .{ .workspace = workspace },
                    .{},
                ),
            );
            for (output[0..start]) |byte| try std.testing.expectEqual(0xd1, byte);
            for (output[start + capacity ..]) |byte| try std.testing.expectEqual(0xd1, byte);
        }
    }
    for (0..source.len) |cut| {
        @memset(output, 0xd1);
        try std.testing.expectError(
            error.InvalidStream,
            test_complete.into(
                source[0..cut],
                output[64..][0..expected.len],
                .{ .workspace = workspace },
                .{},
            ),
        );
        for (output[0..64]) |byte| try std.testing.expectEqual(0xd1, byte);
        for (output[64 + expected.len ..]) |byte| try std.testing.expectEqual(0xd1, byte);
    }
}

test "prepared payload history admission preserves reserved and capacity error priority" {
    const workspace = try DecodeWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var lengths: [288]u8 = @splat(0);
    for (0..15) |symbol| lengths[symbol] = 5;
    lengths[256] = 5;
    for (257..273) |symbol| lengths[symbol] = 5;
    const cases = [_]struct {
        symbol: u8,
        distance: usize,
    }{
        .{ .symbol = 0, .distance = 1 },
        .{ .symbol = 3, .distance = 4 },
        .{ .symbol = 4, .distance = 5 },
        .{ .symbol = 30, .distance = 0 },
        .{ .symbol = 31, .distance = 0 },
    };
    var source: [48]u8 = undefined;
    var backing: [64]u8 = undefined;
    for (0..32) |alignment| {
        for ([_]usize{ 3, 11 }) |length| {
            for ([_]usize{ 8, 32 }) |remaining| {
                for (cases) |case| {
                    @memset(&source, 0xd1);
                    @memset(&backing, 0xd1);
                    const output = backing[8..][0 .. 4 + remaining];
                    output[0..4].* = .{ 0x11, 0x22, 0x33, 0x44 };
                    // Independent 32-leaf LL alphabet: symbol 257 has ordinal 16/reversed code 1;
                    // symbol 265 has ordinal 24/reversed code 3 and one zero extra bit for length
                    // 11. EOB has ordinal 15/reversed code 30. The 32 distance leaves use five
                    //     bits.
                    const ll_bits: u6 = if (length == 3) 5 else 6;
                    const distance_bits: u6 = if (case.symbol == 4) 6 else 5;
                    const distance_code = @bitReverse(case.symbol) >> 3;
                    const length_code: u64 = if (length == 3) 1 else 3;
                    const distance_field = @as(u64, distance_code) << ll_bits;
                    const end_field = @as(u64, 30) << (ll_bits + distance_bits);
                    const wire = length_code | distance_field | end_field;
                    std.mem.writeInt(u64, source[alignment..][0..8], wire, .little);
                    _ = try workspace.literal.ordinary.build(&lengths, false, false);
                    _ = try workspace.distance.build(&@as([32]u8, @splat(5)), false, false);
                    transformPayloadTable(.tagged, true, &workspace.literal.ordinary);
                    transformPayloadTable(.widths, true, &workspace.distance);
                    var bits = BitReader{ .source = source[alignment..] };
                    var written: usize = 4;
                    const result = payloadPrefix(
                        .dynamic,
                        true,
                        false,
                        &bits,
                        output,
                        &written,
                        &workspace.literal.ordinary,
                        &workspace.distance,
                    );
                    if (case.distance == 0 or case.distance > 4) {
                        try std.testing.expectError(error.InvalidStream, result);
                        try std.testing.expectEqual(4, written);
                    } else if (length > remaining) {
                        try std.testing.expectError(error.OutputTooSmall, result);
                        try std.testing.expectEqual(4, written);
                    } else {
                        try std.testing.expectEqual(remaining - length >= 8, try result);
                        try std.testing.expectEqual(4 + length, written);
                        for (0..length) |index| {
                            try std.testing.expectEqual(
                                output[4 - case.distance + index % case.distance],
                                output[4 + index],
                            );
                        }
                    }
                    try std.testing.expectEqualSlices(
                        u8,
                        &.{ 0x11, 0x22, 0x33, 0x44 },
                        output[0..4],
                    );
                    for (output[written..]) |byte| try std.testing.expectEqual(0xd1, byte);
                    for (backing[0..8]) |byte| try std.testing.expectEqual(0xd1, byte);
                    for (backing[8 + output.len ..]) |byte| try std.testing.expectEqual(0xd1, byte);
                }
            }
        }
    }
}

test "unbatched payload literals matches and EOB preserve margins and spare output" {
    const workspace = try DecodeWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var lengths: [288]u8 = @splat(0);
    for (0..14) |symbol| lengths[symbol] = 5;
    lengths[255] = 5;
    lengths[256] = 5;
    for (257..273) |symbol| lengths[symbol] = 5;
    // Independent complete32-leafbook: bytes 0/255 have reversed codes 0/14, length 3/11 use
    // reversed codes 1/3 with zero extra bits; EOB is30. Every DD symbol uses5 bits; code 0
    // supplies distance 1 for both matches.
    const literals: u64 = @as(u64, 14) << 5;
    const first_match = @as(u64, 1) << 10;
    const second_match = @as(u64, 3) << 20;
    const end = @as(u64, 30) << 31;
    const wire = literals | first_match | second_match | end;
    var source: [64]u8 = undefined;
    var backing: [64]u8 = undefined;
    inline for (.{ BlockKind.dynamic, BlockKind.wide }) |kind| {
        for (0..32) |alignment| {
            for ([_]usize{ 8, 12, 13, 16, 24, 32 }) |capacity| {
                @memset(&source, 0xd1);
                @memset(&backing, 0xd1);
                std.mem.writeInt(u64, source[alignment..][0..8], wire, .little);
                const literal = blk: {
                    if (kind == .dynamic) break :blk &workspace.literal.ordinary;
                    break :blk &workspace.literal.wide;
                };
                _ = try literal.build(&lengths, false, false);
                _ = try workspace.distance.build(&@as([32]u8, @splat(5)), false, false);
                transformPayloadTable(if (kind == .dynamic) .widths else .tagged, true, literal);
                transformPayloadTable(.widths, true, &workspace.distance);
                var bits = BitReader{ .source = source[alignment..] };
                var written: usize = 0;
                const output = backing[8..][0..capacity];
                const result = payloadPrefix(
                    kind,
                    false,
                    false,
                    &bits,
                    output,
                    &written,
                    literal,
                    &workspace.distance,
                );
                const produced: usize = blk: {
                    if (capacity == 8) break :blk 1;
                    break :blk if (capacity < 16) 5 else 16;
                };
                if (capacity == 13) {
                    try std.testing.expectError(error.OutputTooSmall, result);
                    // Errors publish no counts although preceding complete tokens may have changed
                    // the destination, as allowed by the decoder.
                    try std.testing.expectEqual(@as(usize, 0), written);
                } else {
                    try std.testing.expectEqual(capacity >= 24, try result);
                    try std.testing.expectEqual(produced, written);
                    const consumed: usize = blk: {
                        if (capacity == 8) break :blk 1;
                        if (capacity == 12) break :blk 3;
                        break :blk if (capacity == 16) 4 else 5;
                    };
                    try std.testing.expectEqual(consumed, bits.consumed());
                }
                try std.testing.expectEqual(@as(u8, 0), output[0]);
                for (output[1..produced]) |byte| try std.testing.expectEqual(@as(u8, 255), byte);
                for (output[produced..]) |byte| try std.testing.expectEqual(@as(u8, 0xd1), byte);
                for (backing[0..8]) |byte| try std.testing.expectEqual(@as(u8, 0xd1), byte);
                for (backing[8 + capacity ..]) |byte| {
                    try std.testing.expectEqual(@as(u8, 0xd1), byte);
                }
            }
        }
    }
}

test "expanded admission and maximum token preserve raw boundaries and exact-size paths" {
    // Independent RFC 1951 encoder and Python-zlib raw/checked goldens. A stored block supplies
    // full history; sparse bytes and 29 active length slots admit the ordinary match-heavy class.
    // The first aligned match consumes 20+28 bits.
    const source = &frozen_fixtures.expanded_48bit_deflate;
    const golden = &frozen_fixtures.expanded_48bit_golden;
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var reader = BitReader{ .source = source[32773..] };
    try std.testing.expectEqual(5, try reader.take(3));
    try std.testing.expectEqual(
        header_decoding.DecodePlan.expanded_lengths,
        try header_decoding.read(true, false, &reader, workspace),
    );
    reader = .{ .source = source[32773..] };
    _ = try reader.take(3);
    try std.testing.expectEqual(
        header_decoding.DecodePlan.match_payload,
        try header_decoding.read(false, false, &reader, workspace),
    );
    const input = try allocator.alloc(u8, source.len + 32 + 9);
    defer allocator.free(input);
    const backing = try allocator.alloc(u8, golden.len + 128);
    defer allocator.free(backing);
    for (0..32) |alignment| {
        @memset(input, 0xa7);
        @memcpy(input[alignment..][0..source.len], source);
        @memcpy(
            input[alignment + source.len ..][0..9],
            &[_]u8{ 0x41, 0x46, 0x54, 0x45, 0x52, 0x2d, 0x45, 0x4e, 0x44 },
        );
        for ([_]bool{ false, true }) |exact| {
            const capacities = [_]usize{
                32768,
                32769,
                golden.len - 1,
                golden.len,
                golden.len + 16,
            };
            for (capacities) |capacity| {
                if (exact and capacity > golden.len) continue;
                @memset(backing, 0xd1);
                const start = 64 + alignment;
                const output = backing[start..][0..capacity];
                const bytes = input[alignment..][0 .. source.len + 9];
                const result = if (exact) test_complete.into(
                    bytes,
                    output,
                    .{ .workspace = workspace },
                    .{ .output_size = .exact },
                ) else test_complete.into(bytes, output, .{ .workspace = workspace }, .{});
                if (capacity < golden.len) {
                    try std.testing.expectError(error.OutputTooSmall, result);
                } else {
                    const value = try result;
                    try std.testing.expectEqual(source.len, value.consumed);
                    try std.testing.expectEqual(golden.len, value.produced);
                    try std.testing.expectEqualSlices(u8, golden, output[0..value.produced]);
                    for (output[value.produced..]) |byte| {
                        try std.testing.expectEqual(0xd1, byte);
                    }
                }
                for (backing[0..start]) |byte| try std.testing.expectEqual(0xd1, byte);
                for (backing[start + capacity ..]) |byte| {
                    try std.testing.expectEqual(0xd1, byte);
                }
            }
        }
    }
    // Every byte truncation of the compressed header/payload is rejected. Stored-history
    // truncations remain covered by the existing owner/corpus.
    for (32773..source.len) |cut| {
        @memset(backing, 0xd1);
        try std.testing.expectError(
            error.InvalidStream,
            test_complete.into(
                source[0..cut],
                backing[64..][0..golden.len],
                .{ .workspace = workspace },
                .{ .output_size = .exact },
            ),
        );
        for (backing[0..64]) |byte| try std.testing.expectEqual(0xd1, byte);
        for (backing[64 + golden.len ..]) |byte| try std.testing.expectEqual(0xd1, byte);
    }
}

test "byte-dominant narrow books retain partial literal batches matches and exact bounds" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const source = &frozen_fixtures.byte_dominant_narrow_deflate;
    const golden = &frozen_fixtures.byte_dominant_narrow_golden;
    var bits = BitReader{ .source = source };
    try std.testing.expectEqual(5, try bits.take(3));
    try std.testing.expectEqual(
        header_decoding.DecodePlan.literal_batch,
        try header_decoding.read(true, false, &bits, workspace),
    );
    const backing = try allocator.alloc(u8, golden.len + 96);
    defer allocator.free(backing);
    for ([_]usize{ 0, 1, 7, 15, 31 }) |alignment| {
        inline for (.{ false, true }) |exact| {
            @memset(backing, 0xa6);
            const spare: usize = if (exact) 0 else 32;
            const output = backing[alignment..][0 .. golden.len + spare];
            const result = blk: {
                if (exact) break :blk try test_complete.into(
                    source,
                    output,
                    .{ .workspace = workspace },
                    .{ .output_size = .exact },
                );
                break :blk try test_complete.into(source, output, .{ .workspace = workspace }, .{});
            };
            try std.testing.expectEqual(source.len, result.consumed);
            try std.testing.expectEqual(golden.len, result.produced);
            try std.testing.expectEqualSlices(u8, golden, output[0..golden.len]);
            for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xa6, byte);
            for (backing[alignment + golden.len ..]) |byte| try std.testing.expectEqual(0xa6, byte);
        }
    }
    @memset(backing, 0xa6);
    try std.testing.expectError(
        error.OutputTooSmall,
        test_complete.into(
            source,
            backing[0 .. golden.len - 1],
            .{ .workspace = workspace },
            .{ .output_size = .exact },
        ),
    );
    for (backing[golden.len - 1 ..]) |byte| try std.testing.expectEqual(0xa6, byte);
}

test "wide expanded tables preserve dependent matches tails framing and unused output" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const source = &frozen_fixtures.wide_expanded_deflate;
    const golden = &frozen_fixtures.wide_expanded_golden;
    var bits = BitReader{ .source = source };
    try std.testing.expectEqual(5, try bits.take(3));
    try std.testing.expectEqual(
        header_decoding.DecodePlan.wide_expanded_lengths,
        try header_decoding.read(true, false, &bits, workspace),
    );
    const backing = try allocator.alloc(u8, golden.len + 96);
    defer allocator.free(backing);
    for ([_]usize{ 0, 1, 7, 15, 31 }) |alignment| {
        inline for (.{ false, true }) |exact| {
            @memset(backing, 0xa6);
            const spare: usize = if (exact) 0 else 32;
            const output = backing[alignment..][0 .. golden.len + spare];
            const result = blk: {
                if (exact) break :blk try test_complete.into(
                    source,
                    output,
                    .{ .workspace = workspace },
                    .{ .output_size = .exact },
                );
                break :blk try test_complete.into(source, output, .{ .workspace = workspace }, .{});
            };
            try std.testing.expectEqual(source.len, result.consumed);
            try std.testing.expectEqual(golden.len, result.produced);
            try std.testing.expectEqualSlices(u8, golden, output[0..golden.len]);
            for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xa6, byte);
            for (backing[alignment + golden.len ..]) |byte| try std.testing.expectEqual(0xa6, byte);
        }
    }
    @memset(backing, 0xa6);
    try std.testing.expectError(
        error.OutputTooSmall,
        test_complete.into(
            source,
            backing[0 .. golden.len - 1],
            .{ .workspace = workspace },
            .{ .output_size = .exact },
        ),
    );
    for (backing[golden.len - 1 ..]) |byte| try std.testing.expectEqual(0xa6, byte);
}

test "literal batch following matches retain groups distance retirement and guards" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const wire = try allocator.alloc(u8, 160);
    defer allocator.free(wire);
    const expected = try allocator.alloc(u8, 122);
    defer allocator.free(expected);
    const backing = try allocator.alloc(u8, expected.len + 128);
    defer allocator.free(backing);
    var widths: [286]u8 = @splat(0);
    @memset(widths[0..255], 9);
    widths[255] = 2;
    widths[256] = 9;
    widths[257] = 2;
    const distance_lengths = [_]u8{ 1, 1 };
    for (0..8) |phase| {
        @memset(wire, 0);
        expected[0] = 'P';
        expected[1] = 'Q';
        var at: usize = 2;
        var cursor: usize = phase;
        for (0..24) |group| {
            const count = group % 3 + 1;
            for (0..count) |i| {
                const byte: u8 = if (group % 4 == 0) 255 else @intCast('M' + i);
                // Byte 255 uses canonical two-bit code 00; remaining bytes use nine-bit codes
                // 256+symbol, independently reversed into wire order.
                const code: u16 = if (byte == 255) 0 else @bitReverse(@as(u9, 256) + @as(u9, byte));
                testAppendBatchBits(wire, &cursor, code, if (byte == 255) 2 else 9);
                expected[at] = byte;
                at += 1;
            }
            // Length-three symbol 257 is canonical 01, reversed 10. Both distance codes use one bit
            // and no payload; distance two keeps dependent ABA copies.
            testAppendBatchBits(wire, &cursor, 2, 2);
            testAppendBatchBits(wire, &cursor, @intCast(group % 2), 1);
            for (0..3) |_| {
                expected[at] = expected[at - (group % 2 + 1)];
                at += 1;
            }
        }
        try std.testing.expectEqual(expected.len, at);
        testAppendBatchBits(wire, &cursor, 511, 9);
        inline for (.{ BlockKind.dynamic, BlockKind.wide }) |kind| {
            for ([_]usize{ 0, 1, 7, 31 }) |alignment| {
                for ([_]usize{ expected.len - 1, expected.len, expected.len + 32 }) |capacity| {
                    const table = blk: {
                        if (kind == .dynamic) break :blk &workspace.literal.ordinary;
                        break :blk &workspace.literal.wide;
                    };
                    _ = try table.build(&widths, false, false);
                    _ = try workspace.distance.build(&distance_lengths, false, false);
                    @memset(backing, 0xa6);
                    const out = backing[alignment..][0..capacity];
                    @memcpy(out[0..2], expected[0..2]);
                    var bits = BitReader{ .source = wire };
                    _ = try bits.take(@intCast(phase));
                    var written: usize = 2;
                    const result = payloadBlock(
                        kind,
                        true,
                        false,
                        &bits,
                        out,
                        &written,
                        table,
                        &workspace.distance,
                    );
                    if (capacity < expected.len) {
                        try std.testing.expectError(error.OutputTooSmall, result);
                    } else {
                        try result;
                        try std.testing.expectEqual(expected.len, written);
                        try std.testing.expectEqual((cursor + 7) / 8, bits.consumed());
                        try std.testing.expectEqualSlices(u8, expected, out[0..written]);
                        for (out[written..]) |byte| try std.testing.expectEqual(0xa6, byte);
                    }
                    for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xa6, byte);
                    for (backing[alignment + capacity ..]) |byte| {
                        try std.testing.expectEqual(0xa6, byte);
                    }
                }
            }
        }
    }
}

test "packed checked worker preserves real EOF precise suffix and error priority" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(PackedTables);
    defer allocator.destroy(tables);
    var lengths: [286]u8 = @splat(0);
    lengths[0] = 1;
    lengths[256] = 2;
    lengths[257] = 2;
    try std.testing.expect(try tables.build(&lengths, &.{ 1, 1 }));
    // RFC canonical bits: literal 0, literal 0, length 3, distance 1, literal 0, EOB.
    // 0|0|11|0|0|10 occupies exactly one byte and restores six zero bytes.
    const source = &[_]u8{ 0x4c, 0x54, 0x52, 0x41, 0x49, 0x4c, 0x49, 0x4e, 0x47 };
    for (0..9) |capacity| {
        var backing: [32]u8 = @splat(0xa6);
        const output = backing[7..][0..capacity];
        var bits = BitReader{ .source = source };
        var written: usize = 0;
        const result = packedChecked(&bits, output, &written, tables);
        if (capacity < 6) {
            try std.testing.expectError(error.OutputTooSmall, result);
        } else {
            try result;
            try std.testing.expectEqual(@as(usize, 6), written);
            try std.testing.expectEqual(@as(usize, 1), bits.consumed());
            for (output[0..6]) |byte| try std.testing.expectEqual(0, byte);
            for (output[6..]) |byte| try std.testing.expectEqual(0xa6, byte);
        }
        for (backing[0..7]) |byte| try std.testing.expectEqual(0xa6, byte);
        for (backing[7 + capacity ..]) |byte| try std.testing.expectEqual(0xa6, byte);
    }
    var backing: [32]u8 = @splat(0xa6);
    var written: usize = 0;
    var bits = BitReader{ .source = &.{} };
    try std.testing.expectError(
        error.InvalidStream,
        packedChecked(&bits, &backing, &written, tables),
    );
    // Eight real zero bits encode eight literals and no EOB. No implicit input zeroes may be
    // consumed after that byte, even with ample output capacity.
    bits = .{ .source = &[_]u8{0x00} };
    try std.testing.expectError(
        error.InvalidStream,
        packedChecked(&bits, &backing, &written, tables),
    );
    // Length3 followed by distance 2 at output position zero is invalid, including when output
    // capacity is zero. Preserve distance-before-capacity priority.
    bits = .{ .source = &[_]u8{0x0f} };
    try std.testing.expectError(error.InvalidStream, packedChecked(&bits, &.{}, &written, tables));
}

test "packed exact dynamic admission reaches independent maximum token" {
    try std.testing.expect(
        @sizeOf(PackedTables) <= @sizeOf(@TypeOf(@as(DecodeWorkspace, undefined).literal)),
    );
    try std.testing.expectEqual(
        @as(usize, if (@sizeOf(usize) == 8) 20952 else 20940),
        @sizeOf(DecodeWorkspace),
    );
    const raw = &frozen_fixtures.expanded_48bit_deflate;
    const golden = &frozen_fixtures.expanded_48bit_golden;
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var bits = BitReader{ .source = raw[32773..] };
    try std.testing.expectEqual(5, try bits.take(3));
    try std.testing.expectEqual(
        header_decoding.DecodePlan.packed_tables,
        try header_decoding.read(true, true, &bits, workspace),
    );
    const output = try allocator.alloc(u8, golden.len + 32);
    defer allocator.free(output);
    @memset(output, 0xa6);
    const result = try test_complete.into(
        raw,
        output[0..golden.len],
        .{ .workspace = workspace },
        .{ .output_size = .exact },
    );
    try std.testing.expectEqual(raw.len, result.consumed);
    try std.testing.expectEqual(golden.len, result.produced);
    try std.testing.expectEqualSlices(u8, golden, output[0..golden.len]);
    for (output[golden.len..]) |byte| try std.testing.expectEqual(0xa6, byte);
}

test "packed throughput literal batches and margin handoff preserve real framing" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(PackedTables);
    defer allocator.destroy(tables);
    var lengths: [286]u8 = @splat(0);
    lengths[0] = 1;
    lengths[256] = 2;
    lengths[257] = 2;
    try std.testing.expect(try tables.build(&lengths, &.{ 1, 1 }));
    const backing = try allocator.alloc(u8, 512 + 128);
    defer allocator.free(backing);
    // The first byte is the independent six-zero stream from the checked test; all following bytes
    // are real supplied trailing input, not input padding.
    const source = &[_]u8{
        0x4c, 0x54, 0x52, 0x41, 0x49, 0x4c, 0x49, 0x4e,
        0x47, 0x54, 0x52, 0x41, 0x49, 0x4c, 0x49, 0x4e,
        0x47, 0x54, 0x52, 0x41, 0x49, 0x4c, 0x49, 0x4e,
        0x47, 0x54, 0x52, 0x41, 0x49, 0x4c, 0x49, 0x4e,
        0x47,
    };
    for ([_]usize{ 300, 512 }) |capacity| {
        @memset(backing, 0xa6);
        const output = backing[31..][0..capacity];
        var bits = BitReader{ .source = source };
        var written: usize = 0;
        const done = try packedPrefix(false, &bits, output, &written, tables);
        try std.testing.expect(written != 0);
        if (!done) try packedChecked(&bits, output, &written, tables);
        try std.testing.expectEqual(@as(usize, 6), written);
        try std.testing.expectEqual(@as(usize, 1), bits.consumed());
        for (output[0..6]) |byte| try std.testing.expectEqual(0, byte);
        for (output[6..]) |byte| try std.testing.expectEqual(0xa6, byte);
        for (backing[0..31]) |byte| try std.testing.expectEqual(0xa6, byte);
        for (backing[31 + capacity ..]) |byte| try std.testing.expectEqual(0xa6, byte);
    }
}

test "packed throughput reaches independent 48bit match before checked tail" {
    const raw = &frozen_fixtures.expanded_48bit_deflate;
    const golden = &frozen_fixtures.expanded_48bit_golden;
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const input = try allocator.alloc(u8, raw.len + 32);
    defer allocator.free(input);
    @memcpy(input[0..raw.len], raw);
    @memset(input[raw.len..], 0xd7);
    const backing = try allocator.alloc(u8, golden.len + 64);
    defer allocator.free(backing);
    @memset(backing, 0xa6);
    const output = backing[0..golden.len];
    @memcpy(output[0..32768], golden[0..32768]);
    var bits = BitReader{ .source = input[32773..] };
    try std.testing.expectEqual(5, try bits.take(3));
    try std.testing.expectEqual(
        header_decoding.DecodePlan.packed_tables,
        try header_decoding.read(true, true, &bits, workspace),
    );
    var written: usize = 32768;
    const done = try packedPrefix(false, &bits, output, &written, &workspace.literal.packed_tables);
    try std.testing.expect(written > 32768);
    if (!done) try packedChecked(&bits, output, &written, &workspace.literal.packed_tables);
    try std.testing.expectEqual(golden.len, written);
    try std.testing.expectEqual(raw.len - 32773, bits.consumed());
    try std.testing.expectEqualSlices(u8, golden, output);
    for (backing[golden.len..]) |byte| try std.testing.expectEqual(0xa6, byte);
}

test "packed exact word copies admit two preceding literals at the minimum margin" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(PackedTables);
    defer allocator.destroy(tables);
    var lengths: [258]u8 = @splat(0);
    lengths['A'] = 1;
    lengths[256] = 2;
    lengths[257] = 2;
    // Two complete books: A = 0, EOB = 10, length3 = 11; distance codes 0/5 = 0/1.
    try std.testing.expect(try tables.build(&lengths, &.{ 1, 0, 0, 0, 0, 1 }));
    inline for (.{ false, true }) |exact| {
        for (0..3) |literals| {
            for (0..8) |phase| {
                var source: [32]u8 = @splat(0);
                var cursor: usize = phase + literals; // Zero bits encode the preceding A literals.
                testAppendBatchBits(&source, &cursor, 3, 2); // Length3.
                testAppendBatchBits(&source, &cursor, 1, 1); // Distance code5.
                testAppendBatchBits(&source, &cursor, 1, 1); // Base7 + 1 = distance8.
                testAppendBatchBits(&source, &cursor, 1, 2); // EOB, reversed canonical 10.
                for ([_]usize{ 0, 1, 7, 31 }) |alignment| {
                    var backing: [8 + 300 + 64]u8 = @splat(0xa6);
                    const output = backing[alignment..][0 .. 8 + 300];
                    for (output[0..8], 0..) |*byte, index| byte.* = @truncate(index * 37 + 11);
                    var bits = BitReader{ .source = &source };
                    _ = try bits.take(@intCast(phase));
                    var written: usize = 8;
                    try std.testing.expect(
                        !try packedPrefix(exact, &bits, output, &written, tables),
                    );
                    try std.testing.expectEqual(8 + literals + 3, written);
                    try packedChecked(&bits, output, &written, tables);
                    try std.testing.expectEqual((cursor + 7) / 8, bits.consumed());
                    for (output[0..8], 0..) |byte, index| {
                        try std.testing.expectEqual(@as(u8, @truncate(index * 37 + 11)), byte);
                    }
                    for (output[8..][0..literals]) |byte| try std.testing.expectEqual('A', byte);
                    for (output[8 + literals .. written], literals..) |byte, index| {
                        try std.testing.expectEqual(@as(u8, @truncate(index * 37 + 11)), byte);
                    }
                    if (!exact) {
                        for (output[written..]) |byte| try std.testing.expectEqual(0xa6, byte);
                    }
                    for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xa6, byte);
                    for (backing[alignment + output.len ..]) |byte| {
                        try std.testing.expectEqual(0xa6, byte);
                    }
                }
            }
        }
    }
}

test "packed general recovery preserves large spare output and trailing input" {
    const raw = &frozen_fixtures.expanded_48bit_deflate;
    const expected = &frozen_fixtures.expanded_48bit_golden;
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const input = try allocator.alloc(u8, raw.len + 32);
    defer allocator.free(input);
    @memcpy(input[0..raw.len], raw);
    @memset(input[raw.len..], 0xd7);
    const backing = try allocator.alloc(u8, expected.len + 512 + 64);
    defer allocator.free(backing);
    for ([_]usize{ raw.len, input.len }) |length| {
        @memset(backing, 0xa5);
        const output = backing[31..][0 .. expected.len + 512];
        const result = try test_complete.into(
            input[0..length],
            output,
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(raw.len, result.consumed);
        try std.testing.expectEqual(expected.len, result.produced);
        try std.testing.expectEqualSlices(u8, expected, output[0..result.produced]);
        for (backing[0..31]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (backing[31 + result.produced ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        try std.testing.expectError(
            error.OutputSizeMismatch,
            test_complete.into(
                input[0..length],
                output,
                .{ .workspace = workspace },
                .{ .output_size = .exact },
            ),
        );
    }
}

test "fixed independent five literal lookups preserve uniform widths and atomic fallback" {
    const alphabet = [_]u16{ 1, 2, 144, 200, 256, 285, 286 };
    for ([_]u16{ 1, 144 }) |first_symbol| {
        for (alphabet) |second| {
            for (alphabet) |third| {
                for (alphabet) |fourth| {
                    for (alphabet) |fifth| {
                        const following = [_]u16{ second, third, fourth, fifth };
                        try checkFixedLiteralBatch(first_symbol, following);
                    }
                }
            }
        }
    }
}

fn checkDynamicFixture(
    source: []const u8,
    expected: []const u8,
    invalid_distance_bit: usize,
    comptime all_alignments: bool,
) !void {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const input = try allocator.alloc(u8, source.len + 64);
    defer allocator.free(input);
    const output = try allocator.alloc(u8, expected.len + 64);
    defer allocator.free(output);

    for (1..33) |offset| {
        @memset(input, 0x5a);
        @memcpy(input[offset..][0..source.len], source);
        const exact = input[offset..][0..source.len];
        for (0..expected.len + 2) |capacity| {
            // Dense construction needs every capacity once; other alignments emphasize packet-size
            // and final-output boundaries.
            if (!all_alignments and offset != 1 and capacity > 8 and capacity + 9 < expected.len)
                continue;
            @memset(output, 0x5a);
            const target = output[offset..][0..capacity];
            if (capacity < expected.len) {
                try std.testing.expectError(
                    error.OutputTooSmall,
                    test_complete.into(exact, target, .{ .workspace = workspace }, .{}),
                );
            } else {
                const result = try test_complete.into(
                    exact,
                    target,
                    .{ .workspace = workspace },
                    .{},
                );
                try std.testing.expectEqual(source.len, result.consumed);
                try std.testing.expectEqual(expected.len, result.produced);
                try std.testing.expectEqualSlices(u8, expected, target[0..result.produced]);
                for (target[result.produced..]) |byte| try std.testing.expectEqual(0x5a, byte);
            }
            for (output[0..offset]) |byte| try std.testing.expectEqual(0x5a, byte);
            for (output[offset + capacity ..]) |byte| try std.testing.expectEqual(0x5a, byte);
        }
        if (all_alignments or offset == 1) {
            for (0..source.len) |end| {
                @memset(output, 0x5a);
                try std.testing.expectError(
                    error.InvalidStream,
                    test_complete.into(
                        exact[0..end],
                        output[offset..][0..expected.len],
                        .{ .workspace = workspace },
                        .{},
                    ),
                );
                for (output[0..offset]) |byte| try std.testing.expectEqual(0x5a, byte);
                for (output[offset + expected.len ..]) |byte| {
                    try std.testing.expectEqual(0x5a, byte);
                }
            }
        }
        @memcpy(
            input[offset + source.len ..][0..8],
            &[_]u8{ 0x74, 0x72, 0x61, 0x69, 0x6c, 0x69, 0x6e, 0x67 },
        );
        @memset(output, 0x5a);
        const result = try test_complete.into(
            input[offset..][0 .. source.len + 8],
            output[offset..][0 .. expected.len + 1],
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(source.len, result.consumed);
        try std.testing.expectEqual(expected.len, result.produced);
        try std.testing.expectEqualSlices(u8, expected, output[offset..][0..expected.len]);
        for (output[0..offset]) |byte| try std.testing.expectEqual(0x5a, byte);
        for (output[offset + expected.len ..]) |byte| try std.testing.expectEqual(0x5a, byte);

        // The external decoder rejects this independently located distance hole.
        input[offset + invalid_distance_bit / 8] ^= @as(
            u8,
            1,
        ) << @as(u3, @intCast(invalid_distance_bit % 8));
        try std.testing.expectError(
            error.InvalidStream,
            test_complete.into(
                exact,
                output[offset..][0..expected.len],
                .{ .workspace = workspace },
                .{},
            ),
        );
        for (input[0..offset]) |byte| try std.testing.expectEqual(0x5a, byte);
        for (input[offset + source.len + 8 ..]) |byte| try std.testing.expectEqual(0x5a, byte);
    }
}

fn testAppendBatchBits(bytes: []u8, cursor: *usize, value: u16, width: u5) void {
    for (0..width) |bit| {
        const one: u8 = @truncate((value >> @as(u4, @intCast(bit))) & 1);
        bytes[cursor.* / 8] |= one << @as(u3, @truncate(cursor.*));
        cursor.* += 1;
    }
}

fn checkFixedLiteralBatch(first_symbol: u16, following: [4]u16) !void {
    const first_width: u6 = if (first_symbol < 144) 8 else 9;
    const first_canonical: u16 = blk: {
        if (first_symbol < 144) break :blk 0x30 + first_symbol;
        break :blk 0x190 + first_symbol - 144;
    };
    const first_shift: u4 = @intCast(16 - @as(u8, first_width));
    const first_code = @bitReverse(first_canonical) >> first_shift;
    const first = fixed_payload.literal[first_code];

    var value: u64 = 0;
    var width: u6 = 0;
    var compatible = true;
    for (following) |symbol| {
        const size: u6 = blk: {
            if (symbol < 144) break :blk 8;
            if (symbol < 256) break :blk 9;
            break :blk if (symbol < 280) 7 else 8;
        };
        const canonical: u16 = blk: {
            if (symbol < 144) break :blk 0x30 + symbol;
            if (symbol < 256) break :blk 0x190 + symbol - 144;
            break :blk if (symbol < 280) symbol - 256 else 0xc0 + symbol - 280;
        };
        const shift: u4 = @intCast(16 - @as(u8, size));
        const code = @bitReverse(canonical) >> shift;
        value |= @as(u64, code) << width;
        width += size;
        compatible = compatible and symbol < 256 and size == first_width;
    }
    value |= @as(u64, 0xa5) << width;

    for (0..32) |alignment| {
        var backing: [69]u8 = @splat(0xd1);
        var bits: BitReader = .{ .source = &.{}, .value = value, .count = 56 };
        try std.testing.expectEqual(
            compatible,
            fixedFiveLiterals(first, &bits, backing[alignment..][0..5]),
        );
        if (compatible) {
            const expected = [_]u8{
                @intCast(first_symbol),
                @intCast(following[0]),
                @intCast(following[1]),
                @intCast(following[2]),
                @intCast(following[3]),
            };
            try std.testing.expectEqualSlices(u8, &expected, backing[alignment..][0..5]);
            try std.testing.expectEqual(56 - @as(u8, first_width) * 4, bits.count);
            try std.testing.expectEqual(@as(u64, 0xa5), bits.value);
        } else {
            try std.testing.expectEqual(@as(u8, 56), bits.count);
            try std.testing.expectEqual(value, bits.value);
            for (backing[alignment..][0..5]) |byte| try std.testing.expectEqual(0xd1, byte);
        }
        for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xd1, byte);
        for (backing[alignment + 5 ..]) |byte| try std.testing.expectEqual(0xd1, byte);
    }
}
