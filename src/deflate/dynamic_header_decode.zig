//! Decode a dynamic DEFLATE header, validate its canonical code lengths and choose the compatible
//! table layout and block worker. Admission initializes that layout directly in shared workspace
//! backing. A declined specialization may have touched it; later construction restores the selected
//! interpretation before any lookup. Selection precedence is part of decoding behavior.

const std = @import("std");
const BitReader = @import("BitReader.zig");
const fixture_data = @import("decode_fixtures.zig");
const huffman = @import("huffman.zig");
const protocol = @import("format.zig");
const DecodeWorkspace = @import("DecodeWorkspace.zig");
const test_complete = @import("decode.zig"); // Used only by inline cross-operation tests.

/// A dynamic block header declares an invalid or incomplete codebook.
pub const Error = error{InvalidStream};
const length_extra = protocol.length_extra;
const precode_order = protocol.precode_order;

const Huffman = huffman.Huffman;
const PairedLiteralTable = huffman.PairedLiteralTable;
const PrecodeTable = Huffman(7, 19, .symbols);
const WideLiteralTable = huffman.WideLiteralTable;

const buildExpandedLiteral = huffman.buildExpandedLiteral;

const frozen_fixtures = fixture_data.frozen_fixtures;
const general_pairs = fixture_data.general_pairs;
const wide_literals = fixture_data.wide_literals;

/// Initial workspace interpretation and its compatible full-window worker. The driver uses this
/// single plan to select execution; the literal union carries no second tag. Every non-packed plan
/// uses workspace.distance. Packed tables contain both alphabets in literal.packed_tables instead.
///
/// Prefix margins below are unread source bytes / remaining output bytes. Input is measured from
/// BitReader.position, the next byte to load; buffered lookahead is excluded. Smaller windows use
/// checked workers with a per-match window guard; packed and expanded admission are disabled for
/// them.
pub const DecodePlan = enum {
    /// Packed literal/distance tables: 25/300 prefix, then the packed checked worker.
    packed_tables,
    /// Ordinary literal table: small-period repetition at 8/8, then the ordinary checked tail.
    short_period,
    /// Ordinary table containing only one one-bit EOB; consume its zero bit without output.
    end_only,
    /// Ordinary literal table and checked dynamic-token worker.
    ordinary,
    /// Wide literal table and checked wide-token worker.
    wide,
    /// Paired literal table with one-bit short distances; batches need 48 buffered bits/8 output.
    paired,
    /// Paired literal table with general distances: 8/8 prefix, then the checked paired worker.
    paired_general,
    /// Ordinary literal table: 8/8 combined length-payload prefix, then the ordinary checked tail.
    match_payload,
    /// Expanded exact-length leaves: 8/8 prefix, then the expanded checked tail.
    expanded_lengths,
    /// Wide-root expanded exact-length leaves: 8/8 prefix, then the wide-expanded checked tail.
    wide_expanded_lengths,
    /// Wide literal table: 8/8 combined length-payload prefix, then the wide checked tail.
    wide_match_payload,
    /// Ordinary literal table: literal batches need 8/8, or 8/298 for exact output; ordinary tail.
    literal_batch,
    /// Wide literal table: literal batches need 8/8, or 8/298 for exact output; wide checked tail.
    wide_literal_batch,
    /// Ordinary literal table: sixteen-byte-period repetition at 8/8, then the ordinary tail.
    sixteen_byte_period,
    /// Ordinary literal table: window-period repetition at 8/8, then the ordinary checked tail.
    window_period,
};

const PayloadKind = enum { none, matches, literals };

const RootWidth = enum { ordinary, wide };

/// Reads code lengths and initializes the chosen interpretation. Optional packed/expanded tables
/// are for complete-source, full-window execution. A declined representation may modify scratch;
/// the subsequent constructor reconstructs its own layout before a plan is returned.
pub fn read(
    comptime expand_lengths: bool,
    comptime packed_tables: bool,
    bits: *BitReader,
    workspace: *DecodeWorkspace,
) Error!DecodePlan {
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
    if (packed_tables) {
        if (try workspace.literal.packed_tables.build(
            literal_lengths,
            distance_lengths,
        )) return .packed_tables;
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
        if (try workspace.literal.ordinary.build(
            literal_lengths,
            false,
            true,
        )) return .short_period;
        return .end_only;
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
            )) return .sixteen_byte_period;
            return .end_only;
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
                )) return .window_period;
                return .end_only;
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
            )) return .wide_expanded_lengths;
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
                break :blk if (dominant) .wide_literal_batch else .wide;
            },
            .matches => .wide_match_payload,
            .literals => .wide_literal_batch,
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
        if (!try workspace.literal.ordinary.build(literal_lengths, false, true)) return .end_only;
        return .short_period;
    }
    const payload = @call(.never_inline, payloadKind, .{ .ordinary, match_lengths });
    if (expand_lengths and payload == .matches) {
        if (try buildExpandedLiteral(
            &workspace.literal.expanded,
            literal_lengths,
        )) return .expanded_lengths;
    }
    if (!try workspace.literal.ordinary.build(literal_lengths, false, true)) return .end_only;
    // Byte-dominant complete narrow books can amortize the same literal prefix as wide books. Keep
    // earlier pair/repetition/payload classes unchanged.
    return switch (payload) {
        .none => blk: {
            const dominant = @call(.never_inline, dominantByteCodes, .{byte_lengths});
            break :blk if (dominant) .literal_batch else .ordinary;
        },
        .matches => .match_payload,
        .literals => .literal_batch,
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
fn payloadKind(comptime kind: RootWidth, lengths: []const u8) PayloadKind {
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

test "wide literal admission fits existing storage and excludes sparse alphabets" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    try std.testing.expectEqual(
        if (@sizeOf(usize) == 8) 20952 else 20940,
        @sizeOf(DecodeWorkspace),
    );
    try std.testing.expect(@sizeOf(WideLiteralTable) <= @sizeOf(PairedLiteralTable));

    const fixture = wide_literals;
    var bits = BitReader{ .source = fixture.source };
    try std.testing.expectEqual(1, try bits.take(1));
    try std.testing.expectEqual(2, try bits.take(2));
    try std.testing.expectEqual(
        DecodePlan.wide_literal_batch,
        try read(false, false, &bits, workspace),
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
    const workspace = try DecodeWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var bits = BitReader{ .source = fixture.source };
    try std.testing.expectEqual(4, try bits.take(3));
    try std.testing.expectEqual(.paired_general, try read(false, false, &bits, workspace));
    try std.testing.expect(workspace.literal.paired.nodes != 0);
    try std.testing.expectEqual(2, workspace.distance.root[0].bits);
}

test "short-match wide payload admission excludes minimum-only and sparse books" {
    var lengths: [29]u8 = @splat(0);
    lengths[1] = 3;
    try std.testing.expectEqual(PayloadKind.literals, payloadKind(.wide, &lengths));
    try std.testing.expectEqual(PayloadKind.none, payloadKind(.ordinary, &lengths));
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
    @memset(&lengths, 0);
    @memset(lengths[0..16], 5);
    try std.testing.expectEqual(PayloadKind.literals, payloadKind(.ordinary, &lengths));
}

test "short maximum-length books with empty or singleton distances keep ordinary admission" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // Independent RFC 1951 HLIT=286 books: A/EOB widths 2 and length-258 width 1; HDIST=1
    // empty/singleton and HDIST=2 complete controls. Python zlib 1.3.2 independently expands each
    // exact wire to A. These are literal-only streams.
    const wires = [_][]const u8{
        &[_]u8{
            0xed, 0xc0, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
            0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x03, 0x00, 0x00, 0x40, 0x1a,
        },
        &[_]u8{
            0xed, 0xc0, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
            0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x03, 0x00, 0x00, 0x40, 0x35,
        },
        &[_]u8{
            0xed, 0xc1, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
            0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x03, 0x00, 0x00, 0x40, 0xd5,
        },
    };
    for (wires) |wire| {
        var bits = BitReader{ .source = wire };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        const tables = try read(false, false, &bits, workspace);
        try std.testing.expect(tables != .short_period);
        var output: [4]u8 = @splat(0xa5);
        const result = try test_complete.into(wire, &output, .{ .workspace = workspace }, .{});
        try std.testing.expectEqual(wire.len, result.consumed);
        try std.testing.expectEqual(1, result.produced);
        try std.testing.expectEqual('A', output[0]);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5 }, output[1..]);
    }
}

test "repetition admission excludes distance-two and distance-four-only books" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // Independent RFC 1951 headers carry code 285 at width 1. Distance codes 0/3 (offsets 1/4) and
    // 1/2 (offsets 2/3) retain ordinary tables; codes 0/2 (offsets 1/3) and 0/4 (offsets 1/5)
    // select repetition. Python zlib 1.3.2 validates all four literal-only wires. Earlier fixtures
    // cover paired-path precedence.
    const fixtures = [_]struct {
        wire: []const u8,
        tables: DecodePlan,
    }{
        .{
            .tables = .ordinary,
            .wire = &[_]u8{
                0xed, 0xc3, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
                0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x40, 0x51, 0x03,
            },
        },
        .{
            .tables = .ordinary,
            .wire = &[_]u8{
                0xed, 0xc2, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
                0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x40, 0xaa, 0x01,
            },
        },
        .{
            .tables = .short_period,
            .wire = &[_]u8{
                0xed, 0xc2, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
                0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x40, 0xa9, 0x01,
            },
        },
        .{
            .tables = .short_period,
            .wire = &[_]u8{
                0xed, 0xc4, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
                0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x40, 0xa1, 0x06,
            },
        },
    };
    for (fixtures) |fixture| {
        var bits = BitReader{ .source = fixture.wire };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(fixture.tables, try read(false, false, &bits, workspace));
        var output: [4]u8 = @splat(0xa5);
        const decoded = try test_complete.into(
            fixture.wire,
            &output,
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(fixture.wire.len, decoded.consumed);
        try std.testing.expectEqual(1, decoded.produced);
        try std.testing.expectEqual('A', output[0]);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5 }, output[1..]);
    }
}

test "sixteen-byte repetition admission requires the bounded distance book" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    // Independent RFC 1951 HLIT=286/code 285 width 1 headers, validated by Python zlib 1.3.2: codes
    // 0/7 and singleton7 keep the sixteen-byte path; HDIST=7, inactive7 and active middle codes
    // select the wider repetition worker.
    const fixtures = [_]struct {
        wire: []const u8,
        tables: DecodePlan,
    }{
        .{
            .tables = .sixteen_byte_period,
            .wire = &[_]u8{
                0xed, 0xc7, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
                0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x40, 0x01, 0x35,
            },
        },
        .{
            .tables = .sixteen_byte_period,
            .wire = &[_]u8{
                0xed, 0xc7, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
                0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x40, 0x80, 0x1a,
            },
        },
        .{
            .tables = .window_period,
            .wire = &[_]u8{
                0xed, 0xc6, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
                0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x40, 0x81, 0x1a,
            },
        },
        .{
            .tables = .window_period,
            .wire = &[_]u8{
                0xed, 0xc7, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
                0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x40, 0x81, 0x34,
            },
        },
        .{
            .tables = .window_period,
            .wire = &[_]u8{
                0xed, 0xc7, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
                0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x40, 0x81, 0x6f,
            },
        },
        .{
            .tables = .window_period,
            .wire = &[_]u8{
                0xed, 0xc7, 0x01, 0x04, 0x00, 0x00, 0x00, 0x80,
                0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x40, 0x0d, 0x6e,
            },
        },
    };
    for (fixtures) |fixture| {
        var bits = BitReader{ .source = fixture.wire };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(fixture.tables, try read(false, false, &bits, workspace));
        var output: [4]u8 = @splat(0xa5);
        const decoded = try test_complete.into(
            fixture.wire,
            &output,
            .{ .workspace = workspace },
            .{},
        );
        try std.testing.expectEqual(fixture.wire.len, decoded.consumed);
        try std.testing.expectEqual(1, decoded.produced);
        try std.testing.expectEqual('A', output[0]);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5 }, output[1..]);
    }
}

test "raw repetition admission respects length widths and distance exclusions" {
    const allocator = std.testing.allocator;
    const workspace = try DecodeWorkspace.create(allocator);
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
            .route = DecodePlan.short_period,
        },
        .{
            .period = 3,
            .source = &frozen_fixtures.ordinary_guard_width7_period3_deflate,
            .route = DecodePlan.match_payload,
        },
        .{
            .period = 2,
            .source = &frozen_fixtures.ordinary_guard_distance2_deflate,
            .route = DecodePlan.match_payload,
        },
        .{
            .period = 4,
            .source = &frozen_fixtures.ordinary_guard_distance4_deflate,
            .route = DecodePlan.match_payload,
        },
        .{
            .period = 9,
            .source = &frozen_fixtures.ordinary_guard_distance9_deflate,
            .route = DecodePlan.match_payload,
        },
    };
    inline for (cases) |fixture| {
        const period = fixture.period;
        const source = fixture.source;
        var bits = BitReader{ .source = source };
        try std.testing.expectEqual(1, try bits.take(1));
        try std.testing.expectEqual(2, try bits.take(2));
        try std.testing.expectEqual(fixture.route, try read(false, false, &bits, workspace));
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
    const workspace = try DecodeWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    try std.testing.expect(!try buildExpandedLiteral(&workspace.literal.expanded, &widths));
    try std.testing.expect(
        workspace.literal.expanded.nodes <= workspace.literal.expanded.children.len,
    );
    try std.testing.expect(try workspace.literal.ordinary.build(&widths, false, false));
    var eob = BitReader{ .source = &.{0}, .position = 1, .value = 0, .count = 8 };
    const leaf_entry = try workspace.literal.ordinary.decode(&eob, .complete);
    try std.testing.expectEqual(256, leaf_entry.value);
    try std.testing.expectEqual(7, eob.count);
    inline for (.{ false, true }) |expanded| {
        var reader = BitReader{ .source = source };
        try std.testing.expectEqual(5, try reader.take(3));
        const admitted = try read(expanded, false, &reader, workspace);
        try std.testing.expectEqual(DecodePlan.wide_literal_batch, admitted);
    }
    const result = try test_complete.into(
        source,
        &.{},
        .{ .workspace = workspace },
        .{ .output_size = .exact },
    );
    try std.testing.expectEqual(source.len, result.consumed);
    try std.testing.expectEqual(0, result.produced);
}
