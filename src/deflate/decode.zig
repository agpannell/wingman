//! Complete-buffer DEFLATE recovery, codebook selection and decoding workspace ownership.
//! Literal/length (LL) tables yield bytes, match lengths or end-of-block markers; distance tables
//! yield backward offsets. Each decoding worker uses its validated table layout and buffer margins.

const builtin = @import("builtin");
const std = @import("std");

const bit_io = @import("bits.zig");
const copying = @import("match.zig");
const fixture_data = @import("fixtures.zig");
const huffman = @import("huffman.zig");
const protocol = @import("format.zig");
const stream = @import("stream.zig");

const Bits = bit_io.Bits;
const CommonFastBits = bit_io.CommonFastBits;

const Error = protocol.Error;
const IndexShift = std.math.Log2Int(usize);
const DecodeOptions = protocol.DecodeOptions;
const DecodeResult = protocol.DecodeResult;
const distance_base = protocol.distance_base;
const distance_extra = protocol.distance_extra;
const length_base = protocol.length_base;
const length_extra = protocol.length_extra;
const precode_order = protocol.precode_order;

const CommonTables = huffman.CommonTables;
const DistanceTable = huffman.DistanceTable;
const Entry = huffman.Entry;
const ExpandedLiteralTable = huffman.ExpandedLiteralTable;
const ExpandedWideLiteralTable = huffman.ExpandedWideLiteralTable;
const FixedDistanceTable = huffman.FixedDistanceTable;
const FixedLiteralTable = huffman.FixedLiteralTable;
const Huffman = huffman.Huffman;
const LiteralTable = huffman.LiteralTable;
const PairedLiteralTable = huffman.PairedLiteralTable;
const PrecodeTable = Huffman(7, 19, .symbols);
const PayloadFormat = huffman.PayloadFormat;
const PayloadLeaf = huffman.PayloadLeaf;
const TableKind = huffman.TableKind;
const WideLiteralTable = huffman.WideLiteralTable;

const buildExpandedLiteral = huffman.buildExpandedLiteral;
const decodeCombinedPayloadBuffered = huffman.decodeCombinedPayloadBuffered;
const distancePayloadValue = huffman.distancePayloadValue;
const fixed = huffman.fixed;
const fixed_payload = huffman.fixed_payload;
const payloadValue = huffman.payloadValue;
const payloadWords = huffman.payloadWords;
const transformPayloadSpan = huffman.transformPayloadSpan;
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
const raw_window_boundary = fixture_data.raw_window_boundary;
const wide_literals = fixture_data.wide_literals;

/// Reusable decoding tables and code lengths with no retained allocator or source/output pointer.
/// Construct at its final address with create(allocator). Release it with destroy(allocator)
/// through the same allocator. Private state is initialized as needed, so callers must not inspect
/// uninitialized fields. One workspace serves one call at a time; independent parallel calls need
/// separate workspaces. Success or failure permits reuse without a reset. Output supplies LZ
/// history. Caller-owned state occupies @sizeOf(DecoderWorkspace) bytes with its natural alignment.
/// `create` reserves `allocation_bytes` including its private header and alignment padding.
/// Ordinary, expanded, wide, paired and packed tables share storage without a second owner.
pub const DecoderWorkspace = struct {
    /// Complete byte request made by create; caller-supplied values need only their type size.
    pub const allocation_bytes = workspace_storage.allocationBytes(DecoderWorkspace);

    // The admitted block class selects one interpretation. A tag-free union lets constructors
    // initialize it directly, without a large union temporary.
    /// Private dynamic literal/length table; initialized when a stream needs it.
    literal: extern union {
        ordinary: LiteralTable,
        common: CommonTables,
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
    /// `destroy` with the same allocator after the last decode. `OutOfMemory` publishes no
    /// workspace. Reserve during initialization for allocation-free repeated decoding.
    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*DecoderWorkspace {
        return workspace_storage.create(allocator, DecoderWorkspace);
    }

    /// Releases a workspace created through this same allocator. No decode may still be using it.
    /// This invalidates the workspace pointer, while caller-owned source/output buffers remain
    /// valid.
    pub fn destroy(self: *DecoderWorkspace, allocator: std.mem.Allocator) void {
        workspace_storage.destroy(allocator, self);
    }
};

/// Mutable storage for a complete decode. Ordinary streams use only the table reservation;
/// supplying a dictionary additionally requires independent history. No allocator is retained.
pub const DecodeStorage = struct {
    /// Address-stable decoding tables, reusable after either success or failure.
    workspace: *DecoderWorkspace,
    /// Required only when `DecodeOptions.dictionary` is non-null.
    history: ?*[32768]u8 = null,
};

/// Decodes one complete raw stream without allocating or retaining buffer pointers. Output extent,
/// trailing input and cumulative admission are independent selections. Dictionary-free calls retain
/// direct-buffer kernels and require no separate history. Missing dictionary history or an invalid
/// window returns `InvalidOptions`; failure may change unpublished output and scratch.
pub fn decode(
    source: []const u8,
    output: []u8,
    storage: DecodeStorage,
    options: DecodeOptions,
) stream.DecodeError!DecodeResult {
    const limits = options.limits;
    if (options.window_bytes == 0 or options.window_bytes > 32768) return error.InvalidOptions;
    const result = if (options.dictionary) |dictionary| blk: {
        const history = storage.history orelse return error.InvalidOptions;
        // Reset copies dictionary history. Admit caller buffers first so an overlap refusal
        // preserves source, output and both reservations.
        const state = std.mem.asBytes(storage.workspace);
        try disjoint(source, output);
        try disjoint(source, state);
        try disjoint(output, state);
        try disjoint(source, history);
        try disjoint(output, history);
        var decoder: stream.Decoder = undefined;
        try decoder.reset(
            .{ .workspace = storage.workspace, .history = history },
            .{ .window_bytes = options.window_bytes, .dictionary = dictionary, .limits = limits },
        );
        const progress = try decoder.step(.{ .bytes = source, .final = true }, output);
        if (progress.status == .need_output) return error.OutputTooSmall;
        break :blk DecodeResult{ .consumed = progress.consumed, .produced = progress.produced };
    } else blk: {
        const workspace = storage.workspace;
        try disjoint(source, output);
        try disjoint(source, std.mem.asBytes(workspace));
        try disjoint(output, std.mem.asBytes(workspace));
        // Cap each axis before decoding. Work counts are checked before result publication; errors
        // expose no accepted counts and may have modified only the admitted output prefix.
        const input_count: usize = @intCast(
            @min(source.len, limits.input_bytes, limits.work_units),
        );
        const output_count: usize = @intCast(
            @min(output.len, limits.output_bytes, limits.work_units),
        );
        if (options.output_size == .exact and output_count < output.len) return error.LimitExceeded;
        const decoded = if (options.output_size == .exact) decodeWithOptions(
            true,
            source[0..input_count],
            output[0..output_count],
            storage.workspace,
            options,
        ) else decodeWithOptions(
            false,
            source[0..input_count],
            output[0..output_count],
            storage.workspace,
            options,
        );
        break :blk decoded catch |err| switch (err) {
            error.InvalidStream => {
                if (input_count < source.len) return error.LimitExceeded;
                return err;
            },
            error.OutputTooSmall => {
                if (output_count < output.len) return error.LimitExceeded;
                return err;
            },
            else => return err,
        };
    };
    if (result.consumed > limits.input_bytes or result.produced > limits.output_bytes)
        return error.LimitExceeded;
    if (result.consumed > limits.work_units or result.produced > limits.work_units - result
        .consumed) return error.LimitExceeded;
    if (options.output_size == .exact and result.produced != output.len) return error.InvalidStream;
    if (options.trailing_data == .reject and result.consumed != source.len)
        return error.InvalidStream;
    return result;
}

test decode {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);

    // A stored raw stream containing "hello", followed by the next application record.
    const source = [_]u8{
        0x01, 0x05, 0x00, 0xfa, 0xff, 0x68, 0x65, 0x6c,
        0x6c, 0x6f, 0x6e, 0x65, 0x78, 0x74,
    };
    var output: [32]u8 = undefined;
    const result = try decode(&source, &output, .{ .workspace = workspace }, .{});
    const payload = .{ .decoded = output[0..result.produced], .next = source[result.consumed..] };

    try std.testing.expectEqualStrings("hello", payload.decoded);
    try std.testing.expectEqualStrings("next", payload.next);
}

/// Rejects overlapping nonempty spans without computing an end address that could overflow.
pub fn disjoint(first: []const u8, second: []const u8) Error!void {
    if (first.len == 0 or second.len == 0) return;
    const a = @intFromPtr(first.ptr);
    const b = @intFromPtr(second.ptr);
    const overlap = if (a <= b) b - a < first.len else a - b < second.len;
    if (overlap) return error.StorageOverlap;
}

const DynamicTables = enum {
    common,
    repetition,
    incomplete,
    complete,
    wide,
    paired,
    paired_general,
    payload,
    expanded_payload,
    expanded_wide_payload,
    wide_payload,
    payload_literals,
    wide_payload_literals,
    repetition_sixteen,
    repetition_window,
};

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

const PayloadKind = enum { none, matches, literals };

const RepetitionKind = enum { short, sixteen, window };

fn decodeWithOptions(
    comptime exact: bool,
    source: []const u8,
    output: []u8,
    workspace: *DecoderWorkspace,
    options: DecodeOptions,
) Error!DecodeResult {
    if (options.window_bytes == 0 or options.window_bytes > 32768) return error.InvalidOptions;
    if (options.window_bytes == 32768) {
        return decodeRawSized(false, exact, source, output, workspace, 0);
    }
    return decodeRawSized(true, exact, source, output, workspace, options.window_bytes);
}

fn decodeRawSized(
    comptime windowed: bool,
    comptime exact: bool,
    source: []const u8,
    output: []u8,
    workspace: *DecoderWorkspace,
    window: usize,
) Error!DecodeResult {
    var bits = Bits{ .source = source };
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
                const tables = try dynamicTablesImpl(!windowed, !windowed, &bits, workspace);
                if (windowed) {
                    try windowedBlock(tables, &bits, output, &written, workspace, window);
                } else switch (tables) {
                    .common => try @call(
                        .never_inline,
                        commonBlock,
                        .{ exact, &bits, output, &written, &workspace.literal.common },
                    ),
                    .repetition => try @call(
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
                    .repetition_sixteen => try @call(
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
                    .repetition_window => try @call(
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
                    .complete => try compressedBlock(
                        .dynamic,
                        false,
                        &bits,
                        output,
                        &written,
                        &workspace.literal.ordinary,
                        &workspace.distance,
                        0,
                    ),
                    .expanded_payload => try @call(
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
                    .payload => try @call(
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
                    .payload_literals => try @call(
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
                    .expanded_wide_payload => try @call(
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
                    .wide_payload => try @call(
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
                    .wide_payload_literals => try @call(
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
                    .incomplete => {
                        // EOB is mandatory; the sole admitted incomplete literal tree has one
                        // one-bit EOB and an invalid other half.
                        if (try bits.take(1) != 0) return error.InvalidStream;
                    },
                }
            },
            else => return error.InvalidStream,
        }
        if (final_block) {
            if (exact and written != output.len) return error.InvalidStream;
            bits.alignByte();
            return .{ .consumed = bits.consumed(), .produced = written };
        }
    }
}

fn dynamicTables(bits: *Bits, workspace: *DecoderWorkspace) Error!DynamicTables {
    return dynamicTablesImpl(false, false, bits, workspace);
}

fn dynamicTablesImpl(
    comptime expand_lengths: bool,
    comptime common: bool,
    bits: *Bits,
    workspace: *DecoderWorkspace,
) Error!DynamicTables {
    const literal_count: usize = 257 + @as(usize, try bits.take(5));
    const distance_count: usize = 1 + @as(usize, try bits.take(5));
    const precode_count: usize = 4 + @as(usize, try bits.take(4));
    if (literal_count > 286) return error.InvalidStream;

    var pre_lengths: [19]u8 = @splat(0);
    for (precode_order[0..precode_count]) |symbol| pre_lengths[symbol] = @intCast(try bits.take(3));
    _ = try workspace.precode.build(&pre_lengths, false, false);
    const total = literal_count + distance_count;
    var position: usize = 0;
    while (position < total) {
        // Three-bit widths cannot exceed the seven-bit root. Construction requires a complete
        // codebook, so every lookup is a direct leaf; input availability remains checked. Keeping
        // this short read in the header loop also keeps its bit reservoir in local registers.
        const symbol = try @call(
            .always_inline,
            PrecodeTable.decode,
            .{ &workspace.precode, bits, .root },
        );
        if (symbol < 16) {
            workspace.lengths[position] = @intCast(symbol);
            position += 1;
        } else {
            const value: u8 = if (symbol == 16) blk: {
                if (position == 0) return error.InvalidStream;
                break :blk workspace.lengths[position - 1];
            } else 0;
            const repeat: usize = switch (symbol) {
                16 => 3 + @as(usize, try bits.take(2)),
                17 => 3 + @as(usize, try bits.take(3)),
                18 => 11 + @as(usize, try bits.take(7)),
                else => return error.InvalidStream,
            };
            if (repeat > total - position) return error.InvalidStream;
            @memset(workspace.lengths[position..][0..repeat], value);
            position += repeat;
        }
    }
    if (workspace.lengths[256] == 0) return error.InvalidStream;

    const literal_lengths = workspace.lengths[0..literal_count];
    const distance_lengths = workspace.lengths[literal_count..total];
    const byte_lengths = literal_lengths[0..256];
    const match_lengths = literal_lengths[257..];

    // Flat tables admit complete books directly. Incomplete, reserved-distance and capacity
    // exceptions reconstruct their ordinary representation in the same workspace below.
    if (common) {
        if (try workspace.literal.common.build(literal_lengths, distance_lengths)) return .common;
    }
    _ = try workspace.distance.build(distance_lengths, true, true);
    // Preserve the earlier short-literal, one-bit distance packet path. Dense general-distance
    // codebooks are admitted separately below.
    const one_bit_distance = blk: {
        const first = workspace.distance.root[0];
        if (first.bits != 1 or first.node or first.value != 1) break :blk false;
        const second = workspace.distance.root[1];
        if (second.bits == 0) break :blk true;
        break :blk second.bits == 1 and !second.node and second.value == 2;
    };
    if (one_bit_distance) {
        for (byte_lengths) |length| {
            if (length != 0 and length <= 4) {
                // EOB plus this literal require at least two codes; paired construction admits a
                // complete tree and rejects all holes.
                try workspace.literal.paired.buildPaired(literal_lengths);
                return .paired;
            }
        }
    }
    // A short maximum-match code and offsets <=8 predict useful repetition. Exclude distance-two
    // and pure distance-four books: their existing loops are cheaper in the measured controls. Code
    // structure is not token frequency.
    const short_maximum_match = blk: {
        if (literal_count != 286) break :blk false;
        const width = literal_lengths[285];
        break :blk width != 0 and width <= 2;
    };
    if (short_maximum_match and shortPeriodDistances(distance_lengths)) {
        if (try workspace.literal.ordinary.build(literal_lengths, false, true)) return .repetition;
        return .incomplete;
    }

    // With only codes 0/7 active, validated completeness or singleton admission proves one-bit
    // distance leaves. Keep this packet specialization separate from short-distance repetition so
    // its token work stays unchanged.
    if (short_maximum_match and distance_count == 8 and distance_lengths[7] != 0) {
        const middle = distance_lengths[1..7];
        for (middle) |length| {
            if (length != 0) break;
        } else {
            if (try workspace.literal.ordinary.build(
                literal_lengths,
                false,
                true,
            )) return .repetition_sixteen;
            return .incomplete;
        }
    }

    // A short maximum-length code plus active offsets 9..32 identifies another repetition-oriented
    // book, after the existing small/sixteen-byte precedences.
    if (short_maximum_match and distance_count >= 7 and distance_count <= 10) {
        for (distance_lengths[6..]) |length| {
            if (length != 0) {
                if (try workspace.literal.ordinary.build(
                    literal_lengths,
                    false,
                    true,
                )) return .repetition_window;
                return .incomplete;
            }
        }
    }

    if (denseLiteralPairs(byte_lengths)) {
        try workspace.literal.paired.buildPaired(literal_lengths);
        return .paired_general;
    }
    if (wideLiterals(byte_lengths)) {
        const wide_payload = @call(.never_inline, payloadKind, .{ .wide, match_lengths });
        if (expand_lengths and wide_payload == .matches) {
            if (try @call(
                .never_inline,
                buildExpandedLiteral,
                .{ &workspace.literal.expanded_wide, literal_lengths },
            )) return .expanded_wide_payload;
        }
        // A byte and mandatory EOB require a complete tree; the sole admitted incomplete literal
        // tree contains just one one-bit EOB. Keep wide sorting temporaries out of the narrow
        // decoder's register allocation.
        _ = try @call(
            .never_inline,
            WideLiteralTable.build,
            .{ &workspace.literal.wide, literal_lengths, false, false },
        );
        // Keep both classifiers in separate calls. Inlining the ordinary policy adds measured costs
        // despite unchanged token loops.
        return switch (wide_payload) {
            .none => blk: {
                const dominant = @call(.never_inline, dominantByteCodes, .{byte_lengths});
                break :blk if (dominant) .wide_payload_literals else .wide;
            },
            .matches => .wide_payload,
            .literals => .wide_payload_literals,
        };
    }
    // Earlier repetition, paired and wide books retain their precedence. Build the final
    // representation once; the expanded form validates completeness itself and ordinary
    // construction remains the bounded-capacity fallback.
    const ordinary_period = blk: {
        if (literal_count != 286) break :blk false;
        const width = literal_lengths[285];
        if (width < 3 or width > 6) break :blk false;
        break :blk shortPeriodDistances(distance_lengths);
    };
    if (ordinary_period) {
        if (!try workspace.literal.ordinary.build(literal_lengths, false, true)) return .incomplete;
        return .repetition;
    }
    const payload = @call(.never_inline, payloadKind, .{ .dynamic, match_lengths });
    if (expand_lengths and payload == .matches) {
        if (try buildExpandedLiteral(
            &workspace.literal.expanded,
            literal_lengths,
        )) return .expanded_payload;
    }
    if (!try workspace.literal.ordinary.build(literal_lengths, false, true)) return .incomplete;
    // Byte-dominant complete narrow books can amortize the same literal prefix as wide books. Keep
    // earlier pair/repetition/payload classes unchanged.
    return switch (payload) {
        .none => blk: {
            const dominant = @call(.never_inline, dominantByteCodes, .{byte_lengths});
            break :blk if (dominant) .payload_literals else .complete;
        },
        .matches => .payload,
        .literals => .payload_literals,
    };
}

// Require a distance-3 or distance-5..8 code within the small alphabet. Exclude distance two and
// distance-four-only books; their existing workers are cheaper. The caller admits the length code.
fn shortPeriodDistances(lengths: []const u8) bool {
    if (lengths.len < 3 or lengths.len > 6) return false;
    if (lengths[1] != 0) return false;
    if (lengths[2] != 0) return true;
    if (lengths.len >= 5 and lengths[4] != 0) return true;
    return lengths.len >= 6 and lengths[5] != 0;
}

// Select match-heavy books before literal batching. Wide roots also admit short matches, excluding
// minimum-only and long-only coverage. Paired admission precedes these full-stream policies.
fn payloadKind(comptime kind: BlockKind, lengths: []const u8) PayloadKind {
    var active: usize = 0;
    var payload_mass: u32 = 0;
    for (lengths, 0..) |code, index| {
        if (code == 0) continue;
        active += 1;
        if (length_extra[index] != 0) payload_mass += @as(u32, 1) << @as(u5, @intCast(15 - code));
    }
    if (active >= 24 and payload_mass >= 8192) return .matches;
    const admitted = blk: {
        if (kind == .wide) break :blk active >= 15 and active < 24 and payload_mass >= 2048;
        break :blk active >= 16 and payload_mass >= 4096;
    };
    if (admitted) return .literals;
    if (kind == .wide) {
        // A short-match codebook can amortize the prepared whole-token loop even without
        // substantial extra-bit mass. Exclude minimum-only matches.
        var short_mass: u32 = 0;
        for (lengths, 0..) |code, index| {
            if (code != 0 and index >= 1 and index <= 10) {
                short_mass += @as(u32, 1) << @as(u5, @intCast(15 - code));
            }
        }
        if (short_mass >= 4096) return .literals;
    }
    return .none;
}

fn dominantByteCodes(lengths: []const u8) bool {
    var mass: u32 = 0;
    for (lengths) |width| {
        if (width != 0) mass += @as(u32, 1) << @as(u5, @intCast(15 - width));
    }
    return mass >= 7 * 32768 / 8;
}

fn denseLiteralPairs(lengths: []const u8) bool {
    var slots: u16 = 0;
    for (lengths) |length| {
        if (length == 0) continue;
        if (length < 5) return false;
        if (length <= 6) slots += @as(u16, 1) << @as(u4, @intCast(6 - length));
    }
    return slots >= 48;
}

// Expanded roots amortize their construction only over a substantial alphabet. Rare long byte codes
// in sparse match-heavy trees retain narrow continuations.
fn wideLiterals(lengths: []const u8) bool {
    var used: u16 = 0;
    var maximum: u8 = 0;
    for (lengths) |length| {
        used += @intFromBool(length != 0);
        maximum = @max(maximum, length);
    }
    return used >= 64 and maximum > 9;
}

// Smaller zlib windows use the checked token loop for each admitted table layout. Full-window/raw
// decoding retains its match prefixes without another per-match guard.
fn windowedBlock(
    tables: DynamicTables,
    bits: *Bits,
    output: []u8,
    written: *usize,
    workspace: *DecoderWorkspace,
    window: usize,
) Error!void {
    switch (tables) {
        .common => unreachable,
        .expanded_wide_payload => try compressedBlock(
            .expanded_wide,
            true,
            bits,
            output,
            written,
            &workspace.literal.expanded_wide,
            &workspace.distance,
            window,
        ),
        .expanded_payload => try compressedBlock(
            .expanded,
            true,
            bits,
            output,
            written,
            &workspace.literal.expanded,
            &workspace.distance,
            window,
        ),
        .complete,
        .payload,
        .payload_literals,
        .repetition,
        .repetition_sixteen,
        .repetition_window,
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
        .wide, .wide_payload, .wide_payload_literals => try compressedBlock(
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
        .incomplete => if (try bits.take(1) != 0) return error.InvalidStream,
    }
}

fn commonPrefix(
    comptime exact: bool,
    noalias bits: *Bits,
    output: []u8,
    noalias written: *usize,
    noalias tables: *const CommonTables,
) Error!bool {
    var position = written.*;
    if (bits.source.len - bits.position < 25 or output.len - position < 300) return false;
    var reader = CommonFastBits{
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
            if (entry & CommonTables.literal_flag != 0) {
                extras: {
                    inline for (0..2) |_| {
                        const byte: u8 = @truncate(entry >> 16);
                        entry = tables.literal[@as(usize, @truncate(reader.value)) & literal_mask];
                        saved = reader.value;
                        reader.drop(entry);
                        output[position] = byte;
                        position += 1;
                        if (entry & CommonTables.literal_flag == 0) break :extras;
                    }
                    // The third direct literal shares emission with a literal resolved through a
                    // secondary table below.
                    break :match;
                }
            }
            if (entry & CommonTables.exceptional != 0) {
                @branchHint(.unlikely);
                if (entry & CommonTables.end_flag != 0) {
                    reader.publish(bits);
                    written.* = position;
                    return true;
                }
                std.debug.assert(entry & CommonTables.subtable != 0);
                const suffix: u8 = @intCast((entry >> 8) & 63);
                const mask = (@as(usize, 1) << @as(IndexShift, @intCast(suffix))) - 1;
                const index = @as(usize, @truncate(reader.value)) & mask;
                entry = tables.literal[(entry >> 16) + index];
                saved = reader.value;
                reader.drop(entry);
                if (entry & CommonTables.literal_flag != 0) break :match;
                if (entry & CommonTables.end_flag != 0) {
                    reader.publish(bits);
                    written.* = position;
                    return true;
                }
            }
            const decoded_literal: CommonTables.Decoded = .{ .entry = entry, .saved = saved };
            const length = decoded_literal.matchValue();
            var distance = tables.distance[@as(u8, @truncate(reader.value))];
            if (distance & CommonTables.exceptional != 0) {
                @branchHint(.unlikely);
                std.debug.assert(distance & CommonTables.subtable != 0);
                if (@as(u8, @truncate(reader.count)) < 38) reader.refill();
                reader.drop(distance);
                const suffix: u8 = @intCast((distance >> 8) & 63);
                const mask = (@as(usize, 1) << @as(IndexShift, @intCast(suffix))) - 1;
                const index = @as(usize, @truncate(reader.value)) & mask;
                distance = tables.distance[(distance >> 16) + index];
            } else if (@as(u8, @truncate(reader.count)) < 31) reader.refill();
            saved = reader.value;
            reader.drop(distance);
            const decoded_distance: CommonTables.Decoded = .{ .entry = distance, .saved = saved };
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

fn commonBlock(
    comptime exact: bool,
    noalias bits: *Bits,
    output: []u8,
    noalias written: *usize,
    noalias tables: *const CommonTables,
) Error!void {
    if (try commonPrefix(exact, bits, output, written, tables)) return;
    try commonChecked(bits, output, written, tables);
}

fn commonChecked(
    noalias bits: *Bits,
    output: []u8,
    noalias written: *usize,
    noalias tables: *const CommonTables,
) Error!void {
    var position = written.*;
    while (true) {
        const literal = try tables.read(false, bits);
        if (literal.entry & CommonTables.literal_flag != 0) {
            if (position == output.len) return error.OutputTooSmall;
            output[position] = @truncate(literal.entry >> 16);
            position += 1;
            continue;
        }
        if (literal.entry & CommonTables.end_flag != 0) {
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
    noalias bits: *Bits,
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
    noalias bits: *Bits,
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
    noalias bits: *Bits,
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
// preparation and checked tails outside the hot loop.
fn payloadBlock(
    comptime kind: BlockKind,
    comptime batch_literals: bool,
    comptime exact: bool,
    noalias bits: *Bits,
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
    noalias bits: *Bits,
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
        var decoded = @call(.always_inline, decodeCombinedPayloadBuffered, .{
            literal, bits, first,
        });
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
                decoded = @call(.always_inline, decodeCombinedPayloadBuffered, .{
                    literal, bits, next,
                });
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
    noalias bits: *Bits,
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
    noalias bits: *Bits,
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
inline fn fixedFiveLiterals(first: Entry, bits: *Bits, output: *[5]u8) bool {
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
fn fixedPayloadPrefix(noalias bits: *Bits, output: []u8, noalias written: *usize) Error!bool {
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
fn fixedLiterals(noalias bits: *Bits, noalias output: *[4]u8) usize {
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
    noalias bits: *Bits,
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
    try @call(.never_inline, compressedBlock, .{
        .tail_dynamic, false, bits, output, written, literal, distance, 0,
    });
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
                const value = try create(failing.allocator(), T);
                try std.testing.expectEqual(0, @intFromPtr(value) % @alignOf(T));
                @memset(std.mem.asBytes(value), 0x6d);
                try std.testing.expectEqual(prefix + capacity, bounded.end_index);
                try std.testing.expectEqual(1, failing.alloc_index);
                destroy(failing.allocator(), @as(*const T, value));
                try std.testing.expectEqual(prefix, bounded.end_index);
                bounded.buffer = bounded.buffer[0 .. bounded.buffer.len - 1];
                try std.testing.expectError(error.OutOfMemory, create(bounded.allocator(), T));
                try std.testing.expectEqual(prefix, bounded.end_index);
                for (bounded.buffer[0..prefix]) |byte| try std.testing.expectEqual(0x3c, byte);
                for (extended[0..8]) |byte| try std.testing.expectEqual(0xa5, byte);
                for (extended[extended.len - 8 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
            }
        }
    }
};

fn checkDynamicFixture(
    source: []const u8,
    expected: []const u8,
    invalid_distance_bit: usize,
    comptime all_alignments: bool,
) !void {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
                    decode(exact, target, .{ .workspace = workspace }, .{}),
                );
            } else {
                const result = try decode(exact, target, .{ .workspace = workspace }, .{});
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
                    decode(
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
        @memcpy(input[offset + source.len ..][0..8], &[_]u8{
            0x74, 0x72, 0x61, 0x69, 0x6c, 0x69, 0x6e, 0x67,
        });
        @memset(output, 0x5a);
        const result = try decode(
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
            decode(exact, output[offset..][0..expected.len], .{ .workspace = workspace }, .{}),
        );
        for (input[0..offset]) |byte| try std.testing.expectEqual(0x5a, byte);
        for (input[offset + source.len + 8 ..]) |byte| try std.testing.expectEqual(0x5a, byte);
    }
}

test "DEFLATE workspaces restore bounded backing after decoding and exhaustion" {
    const allocator = std.testing.allocator;
    const fixture = paired_literals;
    const backing = try allocator.alignedAlloc(u8, .@"8", @sizeOf(DecoderWorkspace) + 128);
    defer allocator.free(backing);
    for (0..@alignOf(DecoderWorkspace)) |residue| {
        const prefix = 16 + residue;
        for (0..2) |index| {
            @memset(backing, 0xa5);
            var bounded = std.heap.FixedBufferAllocator.init(backing[8 .. backing.len - 8]);
            @memset(try bounded.allocator().alloc(u8, prefix), 0x3c);
            var failing = std.testing.FailingAllocator.init(
                bounded.allocator(),
                .{ .fail_index = index },
            );
            if (DecoderWorkspace.create(failing.allocator())) |workspace| {
                const live = bounded.end_index;
                const requests = failing.alloc_index;
                var output: [fixture.expected.len + 8]u8 = undefined;
                for (0..2) |_| {
                    @memset(std.mem.asBytes(workspace), 0x6d);
                    try std.testing.expectError(
                        error.InvalidStream,
                        decode(
                            fixture.source[0 .. fixture.source.len / 2],
                            &output,
                            .{ .workspace = workspace },
                            .{},
                        ),
                    );
                    @memset(&output, 0xa5);
                    const decoded = try decode(
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

test "wide literal admission fits existing storage and excludes sparse alphabets" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    try std.testing.expectEqual(
        if (@sizeOf(usize) == 8) 20952 else 20940,
        @sizeOf(DecoderWorkspace),
    );
    try std.testing.expect(@sizeOf(WideLiteralTable) <= @sizeOf(PairedLiteralTable));

    const fixture = wide_literals;
    var bits = Bits{ .source = fixture.source };
    try std.testing.expectEqual(1, try bits.take(1));
    try std.testing.expectEqual(2, try bits.take(2));
    try std.testing.expectEqual(
        DynamicTables.wide_payload_literals,
        try dynamicTables(&bits, workspace),
    );
    try std.testing.expect(workspace.literal.wide.nodes != 0);

    var lengths: [256]u8 = @splat(0);
    @memset(lengths[0..64], 8);
    lengths[63] = 10;
    try std.testing.expect(wideLiterals(&lengths));
    lengths[62] = 0;
    try std.testing.expect(!wideLiterals(&lengths));
    lengths[62] = 8;
    lengths[63] = 9;
    try std.testing.expect(!wideLiterals(&lengths));
}

test "independent dense codebook reaches the buffered general-distance loop" {
    const fixture = general_pairs;
    const workspace = try DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var bits = Bits{ .source = fixture.source };
    try std.testing.expectEqual(4, try bits.take(3));
    try std.testing.expectEqual(.paired_general, try dynamicTables(&bits, workspace));
    try std.testing.expect(workspace.literal.paired.nodes != 0);
    try std.testing.expectEqual(2, workspace.distance.root[0].bits);
}

test "paired tables retain bounded workspace and entry sizes" {
    try std.testing.expectEqual(4, @sizeOf(Entry));
    try std.testing.expectEqual(
        if (@sizeOf(usize) == 8) 20952 else 20940,
        @sizeOf(DecoderWorkspace),
    );
}

test "eight-bit distance roots preserve replicated payload bits and reserved leaves" {
    const workspace = try DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    const table = &workspace.distance;
    const lengths: [32]u8 = @splat(5);
    try std.testing.expect(try table.build(&lengths, false, false));
    // RFC 1951 bases; canonical equal-length codes are reversed five-bit symbols.
    const bases = [_]u16{
        1,   2,   3,   4,   5,    7,    9,    13,   17,   25,   33,   49,    65,    97,    129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 0,   0,
    };
    try std.testing.expectEqual(256, table.root.len);
    for (table.root, 0..) |entry, index| {
        const symbol = @bitReverse(@as(u5, @truncate(index)));
        try std.testing.expectEqual(@as(u8, 5), entry.bits);
        try std.testing.expect(!entry.node);
        try std.testing.expectEqual(bases[symbol], entry.value);
    }
    transformPayloadTable(.widths, true, table);
    for (0..32) |symbol| {
        const payload_width: u4 = if (symbol < 4 or symbol >= 30) 0 else @intCast(symbol / 2 - 1);
        const mask = (@as(u16, 1) << payload_width) - 1;
        for ([_]u16{ 0, mask }) |payload| {
            const code = @bitReverse(@as(u5, @intCast(symbol)));
            const used: u6 = 5 + @as(u6, payload_width);
            const wire = @as(u64, code) | (@as(u64, payload) << 5) | (@as(u64, 0xa5) << used);
            var bits: Bits = .{ .source = &.{}, .value = wire, .count = 56 };
            const decoded = decodeCombinedPayloadBuffered(
                table,
                &bits,
                table.root[@as(usize, @truncate(wire)) & 255],
            );
            try std.testing.expectEqual(bases[symbol], decoded.entry.value);
            try std.testing.expectEqual(payload, payloadValue(decoded));
            try std.testing.expectEqual(@as(u64, 0xa5), bits.value);
            try std.testing.expectEqual(56 - @as(u8, used), bits.count);
        }
    }
    transformPayloadTable(.widths, false, table);
    for (table.root, 0..) |entry, index| {
        const symbol = @bitReverse(@as(u5, @truncate(index)));
        try std.testing.expectEqual(@as(u8, 5), entry.bits);
        try std.testing.expectEqual(bases[symbol], entry.value);
    }
}

test "private payload conversion reaches every active continuation child and preserves spare backing" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const table = &workspace.literal.ordinary;
    @memset(&table.root, Entry{ .bits = 1, .value = 65 });
    table.nodes = 3;
    const original_pair = [2]Entry{
        .{ .bits = 1, .extra = 1, .value = 267 },
        .{ .bits = 1, .value = 256 },
    };
    for (table.children[0..4]) |*pair| pair.* = original_pair;
    transformPayloadTable(.tagged, true, table);
    for (table.children[0..3]) |pair| {
        try std.testing.expectEqual(Entry{ .bits = 2, .extra = 1, .value = 11 }, pair[0]);
        try std.testing.expectEqual(Entry{ .bits = 1, .extra = 1, .unused = 1 }, pair[1]);
    }
    try std.testing.expectEqual(Entry{ .bits = 1, .extra = 1, .value = 267 }, table.children[3][0]);
    try std.testing.expectEqual(Entry{ .bits = 1, .value = 256 }, table.children[3][1]);
    transformPayloadTable(.tagged, false, table);
    for (table.children[0..4]) |pair| {
        try std.testing.expectEqual(Entry{ .bits = 1, .extra = 1, .value = 267 }, pair[0]);
        try std.testing.expectEqual(Entry{ .bits = 1, .value = 256 }, pair[1]);
    }
}

test "short-match wide payload admission excludes minimum-only and sparse books" {
    var lengths: [29]u8 = @splat(0);
    lengths[1] = 3;
    try std.testing.expectEqual(PayloadKind.literals, payloadKind(.wide, &lengths));
    try std.testing.expectEqual(PayloadKind.none, payloadKind(.dynamic, &lengths));
    lengths[1] = 4;
    try std.testing.expectEqual(PayloadKind.none, payloadKind(.wide, &lengths));
    lengths[10] = 4;
    try std.testing.expectEqual(PayloadKind.literals, payloadKind(.wide, &lengths));
    lengths[10] = 0;
    lengths[0] = 2;
    try std.testing.expectEqual(PayloadKind.none, payloadKind(.wide, &lengths));
    lengths[1] = 0;
    lengths[11] = 2;
    try std.testing.expectEqual(PayloadKind.none, payloadKind(.wide, &lengths));
}

test "short-match wide payload wires preserve exact guards and small-window decoding" {
    // Independent RFC 1951 wires have separately stated period-32 goldens, verified with Python
    // zlib 1.3.2. Literal widths are 9/10, EOB is 3 bits, and the one-bit distance tree covers
    // distances 25..32.
    const fixtures = [_]struct {
        source: []const u8,
        size: usize,
        route: DynamicTables,
    }{
        .{
            .source = &frozen_fixtures.short_wide_four_deflate,
            .size = 6464,
            .route = .wide_payload_literals,
        },
        .{
            .source = &frozen_fixtures.short_wide_thirteen_deflate,
            .size = 7004,
            .route = .wide_payload_literals,
        },
        .{ .source = &frozen_fixtures.minimum_wide_deflate, .size = 6404, .route = .wide },
    };
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
        var bits = Bits{ .source = fixture.source };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(fixture.route, try dynamicTables(&bits, workspace));
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
                const decoded = try decode(input, output, .{ .workspace = workspace }, .{});
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
                decode(fixture.source, backing[1..][0..capacity], .{ .workspace = workspace }, .{}),
            );
            try std.testing.expectEqual(0xa5, backing[0]);
            for (backing[capacity + 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
        for (0..fixture.source.len) |cut| {
            @memset(backing, 0xa5);
            try std.testing.expectError(
                error.InvalidStream,
                decode(
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
        const decoded = try decode(
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

test "short maximum-length books with empty or singleton distances keep ordinary admission" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // Independent RFC 1951 HLIT=286 books: A/EOB widths 2 and length-258 width 1; HDIST=1
    // empty/singleton and HDIST=2 complete controls. Python zlib 1.3.2 independently expands each
    // exact wire to A. These are literal-only streams.
    const wires = [_][]const u8{ &[_]u8{
        0xed, 0xc0, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0x1a,
    }, &[_]u8{
        0xed, 0xc0, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0x35,
    }, &[_]u8{
        0xed, 0xc1, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0xd5,
    } };
    for (wires) |wire| {
        var bits = Bits{ .source = wire };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        const tables = try dynamicTables(&bits, workspace);
        try std.testing.expect(tables != .repetition);
        var output: [4]u8 = @splat(0xa5);
        const result = try decode(wire, &output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(wire.len, result.consumed);
        try std.testing.expectEqual(1, result.produced);
        try std.testing.expectEqual('A', output[0]);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5 }, output[1..]);
    }
}

test "repetition admission excludes distance-two and distance-four-only books" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // Independent RFC 1951 headers carry code 285 at width 1. Distance codes 0/3 (offsets 1/4) and
    // 1/2 (offsets 2/3) retain ordinary tables; codes 0/2 (offsets 1/3) and 0/4 (offsets 1/5)
    // select repetition. Python zlib 1.3.2 validates all four literal-only wires. Earlier fixtures
    // cover paired-path precedence.
    const fixtures = [_]struct {
        wire: []const u8,
        tables: DynamicTables,
    }{ .{ .tables = .complete, .wire = &[_]u8{
        0xed, 0xc3, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0x51, 0x03,
    } }, .{ .tables = .complete, .wire = &[_]u8{
        0xed, 0xc2, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0xaa, 0x01,
    } }, .{ .tables = .repetition, .wire = &[_]u8{
        0xed, 0xc2, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0xa9, 0x01,
    } }, .{ .tables = .repetition, .wire = &[_]u8{
        0xed, 0xc4, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0xa1, 0x06,
    } } };
    for (fixtures) |fixture| {
        var bits = Bits{ .source = fixture.wire };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(fixture.tables, try dynamicTables(&bits, workspace));
        var output: [4]u8 = @splat(0xa5);
        const decoded = try decode(fixture.wire, &output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(fixture.wire.len, decoded.consumed);
        try std.testing.expectEqual(1, decoded.produced);
        try std.testing.expectEqual('A', output[0]);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5 }, output[1..]);
    }
}

test "sixteen-byte repetition admission requires the bounded distance book" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // Independent RFC 1951 HLIT=286/code 285 width 1 headers, validated by Python zlib 1.3.2: codes
    // 0/7 and singleton7 keep the sixteen-byte path; HDIST=7, inactive7 and active middle codes
    // select the wider repetition worker.
    const fixtures = [_]struct {
        wire: []const u8,
        tables: DynamicTables,
    }{ .{ .tables = .repetition_sixteen, .wire = &[_]u8{
        0xed, 0xc7, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0x01, 0x35,
    } }, .{ .tables = .repetition_sixteen, .wire = &[_]u8{
        0xed, 0xc7, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0x80, 0x1a,
    } }, .{ .tables = .repetition_window, .wire = &[_]u8{
        0xed, 0xc6, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0x81, 0x1a,
    } }, .{ .tables = .repetition_window, .wire = &[_]u8{
        0xed, 0xc7, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0x81, 0x34,
    } }, .{ .tables = .repetition_window, .wire = &[_]u8{
        0xed, 0xc7, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0x81, 0x6f,
    } }, .{ .tables = .repetition_window, .wire = &[_]u8{
        0xed, 0xc7, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x40, 0x0d, 0x6e,
    } } };
    for (fixtures) |fixture| {
        var bits = Bits{ .source = fixture.wire };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(fixture.tables, try dynamicTables(&bits, workspace));
        var output: [4]u8 = @splat(0xa5);
        const decoded = try decode(fixture.wire, &output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(fixture.wire.len, decoded.consumed);
        try std.testing.expectEqual(1, decoded.produced);
        try std.testing.expectEqual('A', output[0]);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5 }, output[1..]);
    }
}

test "sixteen-byte distance packets preserve all offsets singleton holes and guards" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // Independent RFC 1951 complete literal books: code 285 width 1, literals 0..14 width 5 and
    // literal 15/EOB width 6. Distance0/7 or singleton7 has one-bit codes. Python zlib 1.3.2
    // validates offsets 1,13..16 and rejects the singleton hole.
    const fixtures = [_]struct {
        wire: []const u8,
        offset: usize,
        invalid: bool,
    }{ .{ .offset = 1, .invalid = false, .wire = &[_]u8{
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
    } }, .{ .offset = 13, .invalid = false, .wire = &[_]u8{
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
    } }, .{ .offset = 14, .invalid = false, .wire = &[_]u8{
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
    } }, .{ .offset = 15, .invalid = false, .wire = &[_]u8{
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
    } }, .{ .offset = 16, .invalid = false, .wire = &[_]u8{
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
    } }, .{ .offset = 16, .invalid = false, .wire = &[_]u8{
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
    } }, .{ .offset = 16, .invalid = true, .wire = &[_]u8{
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
    } } };
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
                decode(source, output[1..275], .{ .workspace = workspace }, .{}),
            );
            for (output[275..]) |byte| try std.testing.expectEqual(0xa5, byte);
        } else {
            const result = try decode(source, output[1..291], .{ .workspace = workspace }, .{});
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
    const workspace = try DecoderWorkspace.create(allocator);
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
    var bits = Bits{ .source = &wire };
    try std.testing.expectEqual(1, try bits.take(1));
    try std.testing.expectEqual(2, try bits.take(2));
    try std.testing.expectEqual(DynamicTables.payload, try dynamicTables(&bits, workspace));
    for (0..951) |capacity| {
        @memset(backing, 0xa5);
        const output = backing[1..][0..capacity];
        if (capacity < expected.len) {
            try std.testing.expectError(
                error.OutputTooSmall,
                decode(input, output, .{ .workspace = workspace }, .{}),
            );
        } else {
            const result = try decode(input, output, .{ .workspace = workspace }, .{});
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
        decode(input, backing[1..][0..expected.len], .{ .workspace = workspace }, .{}),
    );
    try std.testing.expectEqual(0xa5, backing[0]);
    for (backing[expected.len + 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
}

test "both encodings of length 258 preserve continuation history and boundaries" {
    const raw = &frozen_fixtures.length_258_two_codes_deflate;
    // Independent wire: 128 byte codes of width 12, literal 128/EOB/all 29 lengths of width 5,
    // singleton distance 9. Seed0..31 then284+31 and285 each copy258 bytes at distance 32. Python
    // zlib independently validates the complete golden.
    const workspace = try DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var header = Bits{ .source = raw };
    try std.testing.expectEqual(1, try header.take(1));
    try std.testing.expectEqual(2, try header.take(2));
    try std.testing.expectEqual(DynamicTables.wide_payload, try dynamicTables(&header, workspace));
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
                    decode(source, output, .{ .workspace = workspace }, .{}),
                );
            } else {
                const result = try decode(source, output, .{ .workspace = workspace }, .{});
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
        decode(&framed, backing[64..][0..580], .{ .workspace = workspace }, .{}),
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
    const workspace = try DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var header = Bits{ .source = raw };
    try std.testing.expectEqual(1, try header.take(1));
    try std.testing.expectEqual(2, try header.take(2));
    try std.testing.expectEqual(
        DynamicTables.payload_literals,
        try dynamicTables(&header, workspace),
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
                    decode(source, output, .{ .workspace = workspace }, .{}),
                );
            } else {
                const result = try decode(source, output, .{ .workspace = workspace }, .{});
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
        decode(&framed, backing[64..][0..580], .{ .workspace = workspace }, .{}),
    );
    try std.testing.expectEqualSlices(u8, golden[0..290], backing[64..][0..290]);
    for (backing[0..64]) |byte| try std.testing.expectEqual(0xd1, byte);
    for (backing[64 + 290 ..]) |byte| try std.testing.expectEqual(0xd1, byte);
}

test "raw window-period streams preserve history and exact boundaries" {
    // Python zlib 1.3.2 level6 encodes 4MiB+47 bytes repeating seed[i]=(31*i+7)&255. An independent
    // RFC parser confirms all matches, exact framing and the golden.
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
        var bits = Bits{ .source = fixture.wire };
        _ = try bits.take(1);
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(
            DynamicTables.repetition_window,
            try dynamicTables(&bits, workspace),
        );
        @memset(backing, 0xa5);
        const output = backing[64 .. backing.len - 64];
        const result = try decode(fixture.wire, output, .{ .workspace = workspace }, .{});
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
            decode(fixture.wire, output[0 .. size - 1], .{ .workspace = workspace }, .{}),
        );
        for (backing[64 + size - 1 ..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "raw ordinary small periods retain phase and exact bounds" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
        var bits = Bits{ .source = source };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(DynamicTables.repetition, try dynamicTables(&bits, workspace));
        for (0..33) |alignment| {
            @memset(backing, 0xa5);
            const output = backing[alignment..][0 .. output_bytes + 32];
            const result = try decode(source, output, .{ .workspace = workspace }, .{});
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
            decode(source, backing[1..][0 .. output_bytes - 1], .{ .workspace = workspace }, .{}),
        );
        try std.testing.expectEqual(0xa5, backing[0]);
        for (backing[output_bytes..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "raw repetition admission respects length widths and distance exclusions" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const output_bytes = 4096 + 47;
    const backing = try allocator.alloc(u8, output_bytes + 64);
    defer allocator.free(backing);
    // Independently assembled complete LL/precodes isolate code 285 widths 3/7, and distance 2,
    // pure distance 4 and distance 9 exclusions. Python zlib 1.3.2 validates complete bytes
    // i%period and framing, independent of this decoder.
    const cases = .{
        .{
            .period = 3,
            .source = &frozen_fixtures.ordinary_guard_width3_period3_deflate,
            .route = DynamicTables.repetition,
        },
        .{
            .period = 3,
            .source = &frozen_fixtures.ordinary_guard_width7_period3_deflate,
            .route = DynamicTables.payload,
        },
        .{
            .period = 2,
            .source = &frozen_fixtures.ordinary_guard_distance2_deflate,
            .route = DynamicTables.payload,
        },
        .{
            .period = 4,
            .source = &frozen_fixtures.ordinary_guard_distance4_deflate,
            .route = DynamicTables.payload,
        },
        .{
            .period = 9,
            .source = &frozen_fixtures.ordinary_guard_distance9_deflate,
            .route = DynamicTables.payload,
        },
    };
    inline for (cases) |fixture| {
        const period = fixture.period;
        const source = fixture.source;
        var bits = Bits{ .source = source };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(fixture.route, try dynamicTables(&bits, workspace));
        for (0..33) |alignment| {
            @memset(backing, 0xa5);
            const output = backing[alignment..][0 .. output_bytes + 32];
            const result = try decode(source, output, .{ .workspace = workspace }, .{});
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
            decode(source, backing[1..][0 .. output_bytes - 1], .{ .workspace = workspace }, .{}),
        );
        try std.testing.expectEqual(0xa5, backing[0]);
        for (backing[output_bytes..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
}

test "exact-size decoding verifies full extent before raw success" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const source = &frozen_fixtures.literal_length_prefixes_deflate;
    const expected = &frozen_fixtures.literal_length_prefixes_golden;
    const input = try allocator.alloc(u8, source.len + 32);
    defer allocator.free(input);
    @memcpy(input[0..source.len], source);
    @memset(input[source.len..], 0x5a);
    const backing = try allocator.alloc(u8, expected.len + 96);
    defer allocator.free(backing);
    // Independent 197-byte RFC wire and 606-byte golden contain short/long matches at distance 32;
    // this unbatched route retains precise copies. Existing Python zlib 1.3.2 facts validate bytes,
    // not this decoder's copying choices.
    var bits = Bits{ .source = source };
    try std.testing.expectEqual(1, try bits.take(1));
    try std.testing.expectEqual(2, try bits.take(2));
    try std.testing.expectEqual(DynamicTables.payload, try dynamicTables(&bits, workspace));
    for (0..33) |alignment| {
        for (0..expected.len + 33) |capacity| {
            @memset(backing, 0xa5);
            const output = backing[alignment..][0..capacity];
            if (capacity < expected.len) {
                try std.testing.expectError(
                    error.OutputTooSmall,
                    decode(input, output, .{ .workspace = workspace }, .{ .output_size = .exact }),
                );
            } else if (capacity > expected.len) {
                try std.testing.expectError(
                    error.InvalidStream,
                    decode(input, output, .{ .workspace = workspace }, .{ .output_size = .exact }),
                );
            } else {
                const result = try decode(
                    input,
                    output,
                    .{ .workspace = workspace },
                    .{ .output_size = .exact },
                );
                try std.testing.expectEqual(source.len, result.consumed);
                try std.testing.expectEqual(expected.len, result.produced);
                try std.testing.expectEqualSlices(u8, expected, output);
            }
            for (backing[0..alignment]) |byte| try std.testing.expectEqual(0xa5, byte);
            for (backing[alignment + capacity ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        }
    }
    for (0..source.len) |cut| {
        @memset(backing, 0xa5);
        try std.testing.expectError(
            error.InvalidStream,
            decode(
                source[0..cut],
                backing[0..expected.len],
                .{ .workspace = workspace },
                .{ .output_size = .exact },
            ),
        );
        for (backing[expected.len..]) |byte| try std.testing.expectEqual(0xa5, byte);
    }
    const empty = [_]u8{ 0x03, 0x00 };
    try std.testing.expectEqual(
        @as(usize, 0),
        (try decode(
            &empty,
            &.{},
            .{ .workspace = workspace },
            .{ .output_size = .exact },
        )).produced,
    );
    try std.testing.expectError(
        error.InvalidStream,
        decode(&empty, backing[0..1], .{ .workspace = workspace }, .{ .output_size = .exact }),
    );
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
    const workspace = try DecoderWorkspace.create(allocator);
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
        var bits = Bits{ .source = fixture.source };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(
            DynamicTables.wide_payload_literals,
            try dynamicTables(&bits, workspace),
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
                        decode(
                            input,
                            output,
                            .{ .workspace = workspace },
                            .{ .output_size = .exact },
                        ),
                    );
                } else if (capacity > fixture.size) {
                    try std.testing.expectError(
                        error.InvalidStream,
                        decode(
                            input,
                            output,
                            .{ .workspace = workspace },
                            .{ .output_size = .exact },
                        ),
                    );
                } else {
                    const result = try decode(
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
                decode(
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
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const output = try allocator.alloc(u8, 33152 + 16);
    defer allocator.free(output);
    for ([_][]const u8{ &.{ 3, 0 }, &.{ 1, 0, 0, 255, 255 } }) |source| {
        const result = try decode(source, &.{}, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(source.len, result.consumed);
        try std.testing.expectEqual(0, result.produced);
    }
    const hello = &frozen_fixtures.hello_deflate;
    const decoded = try decode(hello, output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(hello.len, decoded.consumed);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x68, 0x65,
        0x6c, 0x6c, 0x6f, 0x20, 0x68, 0x65, 0x6c, 0x6c,
        0x6f, 0x0a,
    }, output[0..decoded.produced]);

    const cases = .{ .{ .source = &frozen_fixtures.runs_deflate, .pattern = [_]u8{
        0x61, 0x62,
        0x63,
    }, .size = 30000 }, .{ .source = &frozen_fixtures.blocks_deflate, .pattern = [_]u8{
        0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    }, .size = 16000 } };
    inline for (cases) |fixture| {
        const result = try decode(fixture.source, output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(fixture.source.len, result.consumed);
        try std.testing.expectEqual(fixture.size, result.produced);
        for (output[0..result.produced], 0..) |byte, index| {
            try std.testing.expectEqual(fixture.pattern[index % fixture.pattern.len], byte);
        }
    }
    const skew = &frozen_fixtures.skew_deflate;
    const result = try decode(skew, output, .{ .workspace = workspace }, .{});
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
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // Canonical RFC fixed codes, independently accepted by Python zlib 1.3.2. Nine-bit literals
    // 200..207 put EOB at each prefix length and refill position.
    const expected = [_]u8{ 200, 201, 202, 203, 204, 205, 206, 207 };
    const prefixes = [_][]const u8{ &[_]u8{
        0x03, 0x00,
    }, &[_]u8{
        0x3b, 0x01,
        0x00,
    }, &[_]u8{
        0x3b, 0x71, 0x12, 0x00,
    }, &[_]u8{
        0x3b, 0x71, 0xf2, 0x14,
        0x00,
    }, &[_]u8{
        0x3b, 0x71, 0xf2, 0xd4,
        0x69, 0x00,
    }, &[_]u8{
        0x3b, 0x71, 0xf2, 0xd4,
        0xe9, 0x33, 0x00,
    }, &[_]u8{
        0x3b, 0x71, 0xf2, 0xd4, 0xe9, 0x33, 0x67, 0x01,
    }, &[_]u8{
        0x3b, 0x71, 0xf2, 0xd4, 0xe9, 0x33, 0x67, 0xcf,
        0x01, 0x00,
    }, &[_]u8{
        0x3b, 0x71, 0xf2, 0xd4, 0xe9, 0x33, 0x67, 0xcf,
        0x9d, 0x07, 0x00,
    } };
    var output: [16]u8 = undefined;
    var with_trailing: [19]u8 = undefined;
    for (prefixes, 0..) |source, length| {
        const exact = try decode(source, output[0..length], .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(source.len, exact.consumed);
        try std.testing.expectEqual(length, exact.produced);
        try std.testing.expectEqualSlices(u8, expected[0..length], output[0..length]);
        for (0..source.len) |end| {
            try std.testing.expectError(
                error.InvalidStream,
                decode(source[0..end], &output, .{ .workspace = workspace }, .{}),
            );
        }
        for (0..length) |capacity| {
            try std.testing.expectError(
                error.OutputTooSmall,
                decode(source, output[0..capacity], .{ .workspace = workspace }, .{}),
            );
        }
        @memset(&output, 0x5a);
        @memcpy(with_trailing[0..source.len], source);
        @memcpy(with_trailing[source.len..][0..8], &[_]u8{
            0x74, 0x72, 0x61, 0x69, 0x6c, 0x69, 0x6e, 0x67,
        });
        const trailing = try decode(
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
    const decoded = try decode(&matched, &output, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(matched.len, decoded.consumed);
    try std.testing.expectEqual(8, decoded.produced);
    try std.testing.expectEqualSlices(u8, &.{
        200, 201, 202, 203, 204, 204, 204, 204,
    }, output[0..8]);
    for (output[8..]) |byte| try std.testing.expectEqual(0x5a, byte);
    // Reserved symbol 286 after four literals; zlib independently refuses it.
    try std.testing.expectError(error.InvalidStream, decode(&[_]u8{
        0x3b, 0x71, 0xf2, 0xd4,
        0xe9, 0x31, 0x00,
    }, &output, .{ .workspace = workspace }, .{}));
}

test "raw boundary ignores trailing bytes and checks every truncation and output limit" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
                decode(fixture.source[0..length], output, .{ .workspace = workspace }, .{}),
            );
        }
        @memset(output, 0x5a);
        const result = try decode(fixture.source ++ [_]u8{
            0x74, 0x72, 0x61, 0x69, 0x6c, 0x69, 0x6e, 0x67,
        }, output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(fixture.source.len, result.consumed);
        try std.testing.expectEqual(fixture.size, result.produced);
        for (output[result.produced..]) |byte| try std.testing.expectEqual(0x5a, byte);
        try std.testing.expectError(
            error.OutputTooSmall,
            decode(fixture.source, output[0 .. fixture.size - 1], .{ .workspace = workspace }, .{}),
        );
    }
}

test "RFC wire facts reach maximum history distance and reject reserved symbols" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
    const fixtures = [_]struct { tail: []const u8, distance: usize }{ .{ .tail = &.{
        0x1b, 0xbd, 0xff, 0x1f, 0,
    }, .distance = 32768 }, .{
        .tail = &frozen_fixtures.distance_direct_min_deflate,
        .distance = 24577,
    }, .{
        .tail = &frozen_fixtures.distance_direct_max_deflate,
        .distance = 32768,
    }, .{ .tail = &frozen_fixtures.distance_continued_max_deflate, .distance = 32768 } };
    // Independent RFC 1951 dynamic tails, accepted by Python zlib 1.3.2. The literal tree gives
    // EOB/285 one-bit codes. Direct distance 0/29 codes use one bit; the continued tree gives 29 a
    // fifteen-bit code. Thirteen extra bits select the lower and upper endpoints of the maximum
    // distance range.
    for (fixtures) |fixture| {
        @memcpy(source[32773..][0..fixture.tail.len], fixture.tail);
        const encoded = source[0 .. 32773 + fixture.tail.len];
        @memset(output_backing, 0x5a);
        const result = try decode(encoded, output, .{ .workspace = workspace }, .{});
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
                decode(source[0 .. 32773 + length], output, .{ .workspace = workspace }, .{}),
            );
        }
        try std.testing.expectError(
            error.OutputTooSmall,
            decode(encoded, output[0 .. output.len - 1], .{ .workspace = workspace }, .{}),
        );
    }
    // Final fixed blocks: reserved literal/length 286; reserved distance 30; length 3 / distance 1
    // with no preceding output. Reserved BTYPE is also invalid.
    for ([_][]const u8{ &.{
        0x1b, 3,
    }, &.{
        3, 0x3e,
    }, &.{
        3, 2,
    }, &.{7}, &.{
        1, 1, 0, 255, 255,
    } }) |invalid| try std.testing.expectError(
        error.InvalidStream,
        decode(invalid, output, .{ .workspace = workspace }, .{}),
    );
}

test "maximum-width dynamic tokens preserve history boundaries and byte alignment" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
            const result = try decode(encoded, output, .{ .workspace = workspace }, .{});
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
            decode(
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
        decode(
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
    const workspace = try DecoderWorkspace.create(allocator);
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
                    decode(source, output, .{ .workspace = workspace }, .{}),
                );
            } else {
                const result = try decode(source, output, .{ .workspace = workspace }, .{});
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
                    decode(
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
        const result = try decode(
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
    const workspace = try DecoderWorkspace.create(allocator);
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
    const no_bytes = try decode(&empty, &.{}, .{ .workspace = workspace }, .{});
    try std.testing.expectEqual(empty.len, no_bytes.consumed);
    try std.testing.expectEqual(0, no_bytes.produced);
    const decoded = try decode(&literals, &output, .{ .workspace = workspace }, .{});
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
                decode(fixture.source[0..length], &output, .{ .workspace = workspace }, .{}),
            );
        }
        @memset(&output, 0x5a);
        const result = try decode(fixture.source ++ [_]u8{
            0x74, 0x72, 0x61, 0x69, 0x6c, 0x69, 0x6e, 0x67,
        }, &output, .{ .workspace = workspace }, .{});
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
            decode(source, &output, .{ .workspace = workspace }, .{}),
        );
    }
}

test "bounded arbitrary input preserves decoder bounds and workspace reuse" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const output = try allocator.alloc(u8, 4096);
    defer allocator.free(output);
    var bytes: [128]u8 = undefined;
    var random: std.Random.DefaultPrng = .init(0x6465666c617465);
    for (0..4096) |iteration| {
        random.random().bytes(&bytes);
        const source = bytes[0 .. iteration % (bytes.len + 1)];
        const result = decode(source, output, .{ .workspace = workspace }, .{}) catch continue;
        try std.testing.expect(result.consumed <= source.len);
        try std.testing.expect(result.produced <= output.len);
    }
    const result = try decode(
        &frozen_fixtures.hello_deflate,
        output,
        .{ .workspace = workspace },
        .{},
    );
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x68, 0x65,
        0x6c, 0x6c, 0x6f, 0x20, 0x68, 0x65, 0x6c, 0x6c,
        0x6f, 0x0a,
    }, output[0..result.produced]);
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
    const workspace = try DecoderWorkspace.create(std.testing.allocator);
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
                        decode(source, output, .{ .workspace = workspace }, .{}),
                    );
                } else {
                    const result = try decode(source, output, .{ .workspace = workspace }, .{});
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
                decode(source[0..length], output, .{ .workspace = workspace }, .{}),
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
    const workspace = try DecoderWorkspace.create(allocator);
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
            const result = try decode(
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

            const trailing = try decode(
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
                    decode(exact, output[start..][0..capacity], .{ .workspace = workspace }, .{}),
                );
                for (output[0..start]) |byte| try std.testing.expectEqual(0xd1, byte);
                for (output[start + capacity ..]) |byte| try std.testing.expectEqual(0xd1, byte);
            }
        }
        for (0..source.len) |cut| {
            @memset(output, 0xd1);
            try std.testing.expectError(
                error.InvalidStream,
                decode(
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
    const workspace = try DecoderWorkspace.create(allocator);
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
        const result = try decode(
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
        const trailing = try decode(
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
                decode(exact, output[start..][0..capacity], .{ .workspace = workspace }, .{}),
            );
            for (output[0..start]) |byte| try std.testing.expectEqual(0xd1, byte);
            for (output[start + capacity ..]) |byte| try std.testing.expectEqual(0xd1, byte);
        }
    }
    for (0..source.len) |cut| {
        @memset(output, 0xd1);
        try std.testing.expectError(
            error.InvalidStream,
            decode(source[0..cut], output[64..][0..expected.len], .{ .workspace = workspace }, .{}),
        );
        for (output[0..64]) |byte| try std.testing.expectEqual(0xd1, byte);
        for (output[64 + expected.len ..]) |byte| try std.testing.expectEqual(0xd1, byte);
    }
}

test "prepared payload history admission preserves reserved and capacity error priority" {
    const workspace = try DecoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var lengths: [288]u8 = @splat(0);
    for (0..15) |symbol| lengths[symbol] = 5;
    lengths[256] = 5;
    for (257..273) |symbol| lengths[symbol] = 5;
    try std.testing.expectEqual(PayloadKind.literals, payloadKind(.dynamic, lengths[257..286]));
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
                    var bits = Bits{ .source = source[alignment..] };
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
                    try std.testing.expectEqualSlices(u8, &.{
                        0x11, 0x22, 0x33, 0x44,
                    }, output[0..4]);
                    for (output[written..]) |byte| try std.testing.expectEqual(0xd1, byte);
                    for (backing[0..8]) |byte| try std.testing.expectEqual(0xd1, byte);
                    for (backing[8 + output.len ..]) |byte| try std.testing.expectEqual(0xd1, byte);
                }
            }
        }
    }
}

test "unbatched payload literals matches and EOB preserve margins and spare output" {
    const workspace = try DecoderWorkspace.create(std.testing.allocator);
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
                var bits = Bits{ .source = source[alignment..] };
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

test "dominant byte admission uses validated Kraft mass without claiming frequency" {
    var widths: [256]u8 = @splat(9);
    try std.testing.expect(!dominantByteCodes(&widths));
    @memset(widths[0..192], 8);
    try std.testing.expect(dominantByteCodes(&widths));
    widths[191] = 9;
    try std.testing.expect(!dominantByteCodes(&widths));
    @memset(&widths, 0);
    try std.testing.expect(!dominantByteCodes(&widths));
}

fn expectExpandedLiteralLengths(comptime Table: type) !void {
    const allocator = std.testing.allocator;
    const table = try allocator.create(Table);
    defer allocator.destroy(table);
    const ordinary = try allocator.create(LiteralTable);
    defer allocator.destroy(ordinary);
    var lengths: [286]u8 = @splat(0);
    for (0..14) |symbol| lengths[symbol] = @intCast(symbol + 1);
    lengths[256] = 15;
    lengths[284] = 15;
    _ = try ordinary.build(&lengths, false, false);
    try std.testing.expect(try buildExpandedLiteral(table, &lengths));
    try std.testing.expectEqual(
        @as(usize, if (@sizeOf(usize) == 8) 20952 else 20940),
        @sizeOf(DecoderWorkspace),
    );
    for (0..32768) |prefix| {
        for ([_]u5{ 0, 15, 31 }) |payload| {
            const ordinal: usize = @ctz(~@as(u16, @intCast(prefix)));
            const width: u8 = @intCast(@min(ordinal + 1, 15));
            const used = width + @as(u8, if (ordinal == 15) 5 else 0);
            const wire = @as(u64, prefix) | (@as(u64, payload) << 15) | (@as(u64, 0xa5) << 20);
            var expanded_bits = Bits{ .source = &.{}, .value = wire, .count = 56 };
            var ordinary_bits = expanded_bits;
            const expanded = try table.decode(&expanded_bits, .complete);
            const original = try ordinary.decode(&ordinary_bits, .complete);
            const value = original.value + try ordinary_bits.take(original.extra);
            const expected: u16 = blk: {
                if (ordinal < 14) break :blk @intCast(ordinal);
                if (ordinal == 14) break :blk 256;
                break :blk 483 + @as(u16, payload);
            };
            try std.testing.expectEqual(expected, value);
            // Expected original symbols/biased lengths above come from the independent canonical
            // wire; tags distinguish cached exact lengths.
            try std.testing.expectEqual(@as(u2, @intFromBool(ordinal < 14)), expanded.literals);
            try std.testing.expectEqual(@as(u1, @intFromBool(ordinal == 14)), expanded.unused);
            const expected_base: u16 = blk: {
                if (ordinal < 14) break :blk expected;
                break :blk if (ordinal == 14) 0 else expected - 256;
            };
            try std.testing.expectEqual(expected_base, expanded.value);
            try std.testing.expectEqual(0, expanded.extra);
            try std.testing.expectEqual(56 - used, expanded_bits.count);
            try std.testing.expectEqual(expanded_bits.count, ordinary_bits.count);
            try std.testing.expectEqual(expanded_bits.value, ordinary_bits.value);
        }
    }
    @memset(&lengths, 0);
    lengths[256] = 1;
    try std.testing.expectError(error.InvalidStream, buildExpandedLiteral(table, &lengths));
    lengths[65] = 16;
    try std.testing.expectError(error.InvalidStream, buildExpandedLiteral(table, &lengths));
}

test "expanded length codebooks preserve tagged exact lengths and twenty-bit retirement" {
    try expectExpandedLiteralLengths(ExpandedLiteralTable);
}

test "wide expanded tables preserve tagged exact lengths and twenty-bit retirement" {
    try expectExpandedLiteralLengths(ExpandedWideLiteralTable);
}

test "expanded admission and maximum token preserve raw boundaries and exact-size paths" {
    // Independent RFC 1951 encoder and Python-zlib raw/checked goldens. A stored block supplies
    // full history; sparse bytes and 29 active length slots admit the ordinary match-heavy class.
    // The first aligned match consumes 20+28 bits.
    const source = &frozen_fixtures.expanded_48bit_deflate;
    const golden = &frozen_fixtures.expanded_48bit_golden;
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var reader = Bits{ .source = source[32773..] };
    try std.testing.expectEqual(5, try reader.take(3));
    try std.testing.expectEqual(
        DynamicTables.expanded_payload,
        try dynamicTablesImpl(true, false, &reader, workspace),
    );
    reader = .{ .source = source[32773..] };
    _ = try reader.take(3);
    try std.testing.expectEqual(
        DynamicTables.payload,
        try dynamicTablesImpl(false, false, &reader, workspace),
    );
    const input = try allocator.alloc(u8, source.len + 32 + 9);
    defer allocator.free(input);
    const backing = try allocator.alloc(u8, golden.len + 128);
    defer allocator.free(backing);
    for (0..32) |alignment| {
        @memset(input, 0xa7);
        @memcpy(input[alignment..][0..source.len], source);
        @memcpy(input[alignment + source.len ..][0..9], &[_]u8{
            0x41, 0x46, 0x54, 0x45, 0x52, 0x2d, 0x45, 0x4e,
            0x44,
        });
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
                const result = if (exact) decode(
                    bytes,
                    output,
                    .{ .workspace = workspace },
                    .{ .output_size = .exact },
                ) else decode(bytes, output, .{ .workspace = workspace }, .{});
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
            decode(
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

test "expanded large complete book stays within caller table backing" {
    // A deterministic independent canonical-tree search found this complete book requiring 3396
    // secondary slots. This exercises substantial occupancy, without claiming the search proves the
    // maximum or reaches capacity decline.
    const widths = [_]u8{
        15, 15, 15, 15, 0,  15, 8,  10, 15, 3,  15, 10, 12, 15, 0,  15, 15, 15, 15, 4,  15, 15, 15,
        15, 15, 15, 9,  12, 15, 15, 15, 10, 7,  15, 15, 15, 10, 8,  15, 15, 15, 15, 15, 15, 15, 15,
        15, 9,  15, 15, 0,  15, 8,  15, 8,  0,  15, 15, 13, 15, 7,  10, 0,  10, 0,  15, 15, 15, 15,
        0,  15, 15, 6,  15, 15, 15, 10, 15, 15, 15, 15, 0,  15, 15, 5,  8,  15, 15, 15, 15, 6,  15,
        15, 8,  15, 15, 15, 15, 15, 15, 15, 15, 15, 6,  15, 15, 8,  7,  15, 4,  0,  15, 9,  15, 15,
        15, 7,  12, 15, 0,  7,  15, 9,  15, 9,  14, 0,  15, 15, 15, 15, 7,  15, 15, 15, 15, 15, 15,
        15, 11, 15, 15, 11, 8,  15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 9,  7,  15,
        15, 15, 15, 10, 15, 10, 15, 0,  15, 15, 7,  11, 15, 15, 8,  15, 15, 15, 10, 0,  10, 15, 15,
        15, 15, 15, 15, 10, 15, 15, 15, 11, 0,  7,  0,  6,  15, 8,  15, 15, 15, 15, 8,  15, 15, 15,
        15, 15, 10, 0,  15, 15, 15, 7,  0,  15, 0,  4,  15, 15, 9,  15, 6,  15, 15, 15, 15, 15, 15,
        15, 15, 10, 0,  10, 15, 15, 11, 15, 15, 6,  15, 10, 8,  11, 15, 15, 15, 9,  15, 9,  0,  10,
        15, 9,  8,  8,  15, 15, 15, 15, 3,  15, 9,  15, 15, 15, 15, 15, 15, 3,  15, 15, 15, 15, 15,
        15, 15, 8,  12, 15, 9,  14, 15, 10, 3,
    };
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    try std.testing.expect(try buildExpandedLiteral(&workspace.literal.expanded, &widths));
    try std.testing.expectEqual(@as(usize, 3396), workspace.literal.expanded.nodes);
    // Reconstruct the ordinary representation in the same union after expansion. This checks the
    // representation transition without a second memory owner.
    try std.testing.expect(try workspace.literal.ordinary.build(&widths, false, false));
    var invalid = widths;
    invalid[256] = 16;
    try std.testing.expectError(
        error.InvalidStream,
        buildExpandedLiteral(&workspace.literal.expanded, &invalid),
    );
}

test "expanded capacity decline retains valid ordinary reconstruction and prior wide admission" {
    // Independent complete canonical codebook needs 4224 secondary slots, above the 4096 limit.
    // Decline changes private table work, then ordinary rebuild restores a valid representation.
    // Production keeps the earlier wide class.
    const source = &frozen_fixtures.expanded_capacity_decline_deflate;
    const widths = [_]u8{
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
        15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 0,  0,
        0,  0,  0,  1,  2,  3,  4,  5,  6,  8,  9,  10, 11, 12, 13, 14, 0,  0,  0,  0,  0,  0,  0,
        0,  0,  0,  0,  0,  14, 14, 14, 15, 0,
    };
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    try std.testing.expect(!try buildExpandedLiteral(&workspace.literal.expanded, &widths));
    try std.testing.expect(
        workspace.literal.expanded.nodes <= workspace.literal.expanded.children.len,
    );
    try std.testing.expect(try workspace.literal.ordinary.build(&widths, false, false));
    var eob = Bits{ .source = &.{0}, .position = 1, .value = 0, .count = 8 };
    const leaf_entry = try workspace.literal.ordinary.decode(&eob, .complete);
    try std.testing.expectEqual(256, leaf_entry.value);
    try std.testing.expectEqual(7, eob.count);
    inline for (.{ false, true }) |expanded| {
        var reader = Bits{ .source = source };
        try std.testing.expectEqual(5, try reader.take(3));
        const admitted = try dynamicTablesImpl(expanded, false, &reader, workspace);
        try std.testing.expectEqual(DynamicTables.wide_payload_literals, admitted);
    }
    const result = try decode(
        source,
        &.{},
        .{ .workspace = workspace },
        .{ .output_size = .exact },
    );
    try std.testing.expectEqual(source.len, result.consumed);
    try std.testing.expectEqual(0, result.produced);
}

test "raw admission checks storage and window limits before decoding" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const state = std.mem.asBytes(workspace);
    var source = [_]u8{ 1, 0, 0, 255, 255 };
    const original = source;
    var output: [304]u8 = undefined;
    inline for (.{ protocol.OutputSize.bounded, protocol.OutputSize.exact }) |extent| {
        @memset(state, 0x6d);
        @memset(&output, 0xa5);
        for ([_]usize{ 0, 32769, std.math.maxInt(usize) }) |window| {
            try std.testing.expectError(
                error.InvalidOptions,
                decode(
                    &source,
                    &output,
                    .{ .workspace = workspace },
                    .{ .window_bytes = window, .output_size = extent },
                ),
            );
        }
        try std.testing.expect(std.mem.allEqual(u8, state, 0x6d));
        try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
        try std.testing.expectError(
            error.StorageOverlap,
            decode(&source, source[0..1], .{ .workspace = workspace }, .{ .output_size = extent }),
        );
        try std.testing.expectError(
            error.StorageOverlap,
            decode(&source, state, .{ .workspace = workspace }, .{ .output_size = extent }),
        );
        try std.testing.expectEqualSlices(u8, &original, &source);
        try std.testing.expect(std.mem.allEqual(u8, state, 0x6d));
        @memcpy(state[0..source.len], &source);
        try std.testing.expectError(
            error.StorageOverlap,
            decode(
                state[0..source.len],
                &output,
                .{ .workspace = workspace },
                .{ .output_size = extent },
            ),
        );
        try std.testing.expectEqualSlices(u8, &source, state[0..source.len]);
        try std.testing.expect(std.mem.allEqual(u8, state[source.len..], 0x6d));
        try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));

        // Independent RFC fixed wire: A, length-three/distance-one, then EOB. Python zlib 1.3.2
        // verifies the complete four-byte result.
        const result = try decode(&[_]u8{
            0x73, 0x04, 0x02, 0x00,
        }, output[0..4], .{
            .workspace = workspace,
        }, .{ .window_bytes = 1, .output_size = extent });
        try std.testing.expectEqual(4, result.consumed);
        try std.testing.expectEqual(4, result.produced);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x41, 0x41, 0x41 }, output[0..4]);
        try std.testing.expect(std.mem.allEqual(u8, output[4..], 0xa5));

        // The independently authored window wire supplies 300 literals before a length-three match
        // at distance 256. Test both API size policies.
        const bytes = &raw_window_boundary;
        @memset(&output, 0xa5);
        try std.testing.expectEqual(
            303,
            (try decode(
                bytes,
                output[0..303],
                .{ .workspace = workspace },
                .{ .window_bytes = 256, .output_size = extent },
            )).produced,
        );
        try std.testing.expect(std.mem.allEqual(u8, output[0..303], 'A'));
        try std.testing.expectEqual(0xa5, output[303]);
        @memset(&output, 0xa5);
        try std.testing.expectError(
            error.InvalidStream,
            decode(
                bytes,
                output[0..303],
                .{ .workspace = workspace },
                .{ .window_bytes = 255, .output_size = extent },
            ),
        );
        try std.testing.expect(std.mem.allEqual(u8, output[300..], 0xa5));
    }
}

test "dictionary decode admission preserves buffers before any history copy" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const state = std.mem.asBytes(workspace);
    // Independent RFC fixed block: length 3, distance 1 and EOB, using preset history A.
    const original = [_]u8{ 0x03, 0x02, 0x00 };
    var output: [3]u8 = undefined;
    inline for (.{ protocol.OutputSize.bounded, protocol.OutputSize.exact }) |extent| {
        for (0..5) |overlap| {
            @memset(state, 0x6d);
            @memset(history, 0xa5);
            @memset(&output, 0xc7);
            var input = original;
            const source: []const u8 = switch (overlap) {
                1 => blk: {
                    @memcpy(state[0..original.len], &original);
                    break :blk state[0..original.len];
                },
                3 => blk: {
                    @memcpy(history[0..original.len], &original);
                    break :blk history[0..original.len];
                },
                else => &input,
            };
            const target: []u8 = switch (overlap) {
                0 => &input,
                2 => state[0..original.len],
                4 => history[0..original.len],
                else => &output,
            };
            try std.testing.expectError(
                error.StorageOverlap,
                decode(
                    source,
                    target,
                    .{ .workspace = workspace, .history = history },
                    .{ .dictionary = "A", .output_size = extent },
                ),
            );
            try std.testing.expectEqualSlices(u8, &original, &input);
            try std.testing.expect(std.mem.allEqual(u8, &output, 0xc7));
            if (overlap == 1) {
                try std.testing.expectEqualSlices(u8, &original, state[0..original.len]);
                try std.testing.expect(std.mem.allEqual(u8, state[original.len..], 0x6d));
            } else try std.testing.expect(std.mem.allEqual(u8, state, 0x6d));
            if (overlap == 3) {
                try std.testing.expectEqualSlices(u8, &original, history[0..original.len]);
                try std.testing.expect(std.mem.allEqual(u8, history[original.len..], 0xa5));
            } else try std.testing.expect(std.mem.allEqual(u8, history, 0xa5));
        }
    }
}

test "byte-dominant narrow books retain partial literal batches matches and exact bounds" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const source = &frozen_fixtures.byte_dominant_narrow_deflate;
    const golden = &frozen_fixtures.byte_dominant_narrow_golden;
    var bits = Bits{ .source = source };
    try std.testing.expectEqual(5, try bits.take(3));
    try std.testing.expectEqual(
        DynamicTables.payload_literals,
        try dynamicTablesImpl(true, false, &bits, workspace),
    );
    const backing = try allocator.alloc(u8, golden.len + 96);
    defer allocator.free(backing);
    for ([_]usize{ 0, 1, 7, 15, 31 }) |alignment| {
        inline for (.{ false, true }) |exact| {
            @memset(backing, 0xa6);
            const spare: usize = if (exact) 0 else 32;
            const output = backing[alignment..][0 .. golden.len + spare];
            const result = blk: {
                if (exact) break :blk try decode(
                    source,
                    output,
                    .{ .workspace = workspace },
                    .{ .output_size = .exact },
                );
                break :blk try decode(source, output, .{ .workspace = workspace }, .{});
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
        decode(
            source,
            backing[0 .. golden.len - 1],
            .{ .workspace = workspace },
            .{ .output_size = .exact },
        ),
    );
    for (backing[golden.len - 1 ..]) |byte| try std.testing.expectEqual(0xa6, byte);
}

test "wide expanded admission preserves long dependent matches tails framing and successful suffixes" {
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const source = &frozen_fixtures.wide_expanded_deflate;
    const golden = &frozen_fixtures.wide_expanded_golden;
    var bits = Bits{ .source = source };
    try std.testing.expectEqual(5, try bits.take(3));
    try std.testing.expectEqual(
        DynamicTables.expanded_wide_payload,
        try dynamicTablesImpl(true, false, &bits, workspace),
    );
    const backing = try allocator.alloc(u8, golden.len + 96);
    defer allocator.free(backing);
    for ([_]usize{ 0, 1, 7, 15, 31 }) |alignment| {
        inline for (.{ false, true }) |exact| {
            @memset(backing, 0xa6);
            const spare: usize = if (exact) 0 else 32;
            const output = backing[alignment..][0 .. golden.len + spare];
            const result = blk: {
                if (exact) break :blk try decode(
                    source,
                    output,
                    .{ .workspace = workspace },
                    .{ .output_size = .exact },
                );
                break :blk try decode(source, output, .{ .workspace = workspace }, .{});
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
        decode(
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
    const workspace = try DecoderWorkspace.create(allocator);
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
                    var bits = Bits{ .source = wire };
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

fn testAppendBatchBits(bytes: []u8, cursor: *usize, value: u16, width: u5) void {
    for (0..width) |bit| {
        const one: u8 = @truncate((value >> @as(u4, @intCast(bit))) & 1);
        bytes[cursor.* / 8] |= one << @as(u3, @truncate(cursor.*));
        cursor.* += 1;
    }
}

test "common packed checked worker preserves real EOF precise suffix and error priority" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(CommonTables);
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
        var bits = Bits{ .source = source };
        var written: usize = 0;
        const result = commonChecked(&bits, output, &written, tables);
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
    var bits = Bits{ .source = &.{} };
    try std.testing.expectError(
        error.InvalidStream,
        commonChecked(&bits, &backing, &written, tables),
    );
    // Eight real zero bits encode eight literals and no EOB. No implicit input zeroes may be
    // consumed after that byte, even with ample output capacity.
    bits = .{ .source = &[_]u8{0x00} };
    try std.testing.expectError(
        error.InvalidStream,
        commonChecked(&bits, &backing, &written, tables),
    );
    // Length3 followed by distance 2 at output position zero is invalid, including when output
    // capacity is zero. Preserve distance-before-capacity priority.
    bits = .{ .source = &[_]u8{0x0f} };
    try std.testing.expectError(error.InvalidStream, commonChecked(&bits, &.{}, &written, tables));
}

test "common packed exact dynamic admission reaches independent maximum token" {
    try std.testing.expect(
        @sizeOf(CommonTables) <= @sizeOf(@TypeOf(@as(DecoderWorkspace, undefined).literal)),
    );
    try std.testing.expectEqual(
        @as(usize, if (@sizeOf(usize) == 8) 20952 else 20940),
        @sizeOf(DecoderWorkspace),
    );
    const raw = &frozen_fixtures.expanded_48bit_deflate;
    const golden = &frozen_fixtures.expanded_48bit_golden;
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var bits = Bits{ .source = raw[32773..] };
    try std.testing.expectEqual(5, try bits.take(3));
    try std.testing.expectEqual(
        DynamicTables.common,
        try dynamicTablesImpl(true, true, &bits, workspace),
    );
    const output = try allocator.alloc(u8, golden.len + 32);
    defer allocator.free(output);
    @memset(output, 0xa6);
    const result = try decode(
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

test "common packed throughput literal batches and margin handoff preserve real framing" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(CommonTables);
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
        var bits = Bits{ .source = source };
        var written: usize = 0;
        const done = try commonPrefix(false, &bits, output, &written, tables);
        try std.testing.expect(written != 0);
        if (!done) try commonChecked(&bits, output, &written, tables);
        try std.testing.expectEqual(@as(usize, 6), written);
        try std.testing.expectEqual(@as(usize, 1), bits.consumed());
        for (output[0..6]) |byte| try std.testing.expectEqual(0, byte);
        for (output[6..]) |byte| try std.testing.expectEqual(0xa6, byte);
        for (backing[0..31]) |byte| try std.testing.expectEqual(0xa6, byte);
        for (backing[31 + capacity ..]) |byte| try std.testing.expectEqual(0xa6, byte);
    }
}

test "common packed throughput reaches independent 48bit match before checked tail" {
    const raw = &frozen_fixtures.expanded_48bit_deflate;
    const golden = &frozen_fixtures.expanded_48bit_golden;
    const allocator = std.testing.allocator;
    const workspace = try DecoderWorkspace.create(allocator);
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
    var bits = Bits{ .source = input[32773..] };
    try std.testing.expectEqual(5, try bits.take(3));
    try std.testing.expectEqual(
        DynamicTables.common,
        try dynamicTablesImpl(true, true, &bits, workspace),
    );
    var written: usize = 32768;
    const done = try commonPrefix(false, &bits, output, &written, &workspace.literal.common);
    try std.testing.expect(written > 32768);
    if (!done) try commonChecked(&bits, output, &written, &workspace.literal.common);
    try std.testing.expectEqual(golden.len, written);
    try std.testing.expectEqual(raw.len - 32773, bits.consumed());
    try std.testing.expectEqualSlices(u8, golden, output);
    for (backing[golden.len..]) |byte| try std.testing.expectEqual(0xa6, byte);
}

test "common packed exact word copies admit two preceding literals at the minimum margin" {
    const allocator = std.testing.allocator;
    const tables = try allocator.create(CommonTables);
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
                    var bits = Bits{ .source = &source };
                    _ = try bits.take(@intCast(phase));
                    var written: usize = 8;
                    try std.testing.expect(
                        !try commonPrefix(exact, &bits, output, &written, tables),
                    );
                    try std.testing.expectEqual(8 + literals + 3, written);
                    try commonChecked(&bits, output, &written, tables);
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
    const workspace = try DecoderWorkspace.create(allocator);
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
        const result = try decode(input[0..length], output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(raw.len, result.consumed);
        try std.testing.expectEqual(expected.len, result.produced);
        try std.testing.expectEqualSlices(u8, expected, output[0..result.produced]);
        for (backing[0..31]) |byte| try std.testing.expectEqual(0xa5, byte);
        for (backing[31 + result.produced ..]) |byte| try std.testing.expectEqual(0xa5, byte);
        try std.testing.expectError(
            error.InvalidStream,
            decode(
                input[0..length],
                output,
                .{ .workspace = workspace },
                .{ .output_size = .exact },
            ),
        );
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
        var bits: Bits = .{ .source = &.{}, .value = value, .count = 56 };
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

test {
    _ = workspace_storage;
}
