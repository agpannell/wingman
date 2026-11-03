//! Native RFC 1951 encoding, bounded match caching and offline parsing. The public namespace is
//! re-exported by deflate.zig. This implementation follows RFC 1951; an ordinary Huffman tree
//! supplies a book when it fits the length limit, and package-merge handles longer trees. Iterative
//! parsing and serialized cost selection were informed by:
//! https://github.com/ebiggers/libdeflate/blob/v1.26/lib/deflate_compress.c
//! https://github.com/google/zopfli/blob/zopfli-1.0.3/src/zopfli/squeeze.c No reference
//! implementation is called or linked by this library.

const std = @import("std");

const protocol = @import("format.zig");
const match_tree = @import("match_tree.zig");
const distance_base = protocol.distance_base;
const distance_extra = protocol.distance_extra;
const length_base = protocol.length_base;
const length_extra = protocol.length_extra;
const precode_order = protocol.precode_order;

const slab_bytes = 65535;
const window_bytes = 32768;
const alternatives = match_tree.alternatives;
const no_position = std.math.maxInt(u32);
const no_symbol = std.math.maxInt(u16);

/// A failed encoder call returns no progress value and poisons the owner until reset. Counters may
/// include bytes and effort admitted before failure; already returned output remains a partial
/// stream. No operation allocates.
pub const EncodeError = error{
    /// Unsupported window/profile configuration or another invalid encoding option.
    InvalidOptions,
    /// The action or dictionary attachment is not valid at this stream boundary.
    InvalidState,
    /// A previous step failed; reset the encoder before continuing.
    NeedReset,
    /// Source, output, dictionary or scratch overlap where independent storage is required.
    StorageOverlap,
    /// The complete-buffer destination cannot hold the encoded result; output may be changed.
    OutputTooSmall,
    /// A configured input/output/work allowance was exhausted.
    LimitExceeded,
    /// Required capacity or cumulative byte accounting cannot be represented.
    CounterOverflow,
};

/// Compression effort and optional strategy for ordinary RFC 1951 streams.
pub const Compression = struct {
    /// Level 0 stores bytes; 1–3 use greedy matching, 4–6 use lazy matching and 7–9 use offline
    /// parsing. Levels select different search budgets and usually trade speed for size, but
    /// neither size nor latency is guaranteed to be monotonic. Values above 9 return
    /// InvalidOptions. The default 6 uses lazy matching. Levels are not equivalent to another
    /// library's numbers.
    level: u8 = 6,
    /// Level 0 always stores bytes; otherwise this selects ordinary or literal-only encoding.
    strategy: Strategy = .default,
    /// Search effort for the next position when a lazy match is pending. Reduced lookahead is
    /// available only with ordinary matching at levels 4–6. It can change the wire, work consumed
    /// and whether a finite work limit is reached; neither size nor speed is guaranteed to improve.
    /// Full lookahead is the default and has no effect on levels without lazy matching.
    lazy_lookahead: LazyLookahead = .full,
    /// Effort spent pricing retained match lengths and distances during offline parsing. Choices
    /// other than full are available only with ordinary matching at levels 7–9. They can change
    /// output and work; neither size nor speed is guaranteed to improve. Full is the default.
    offline_pricing: OfflinePricing = .full,
    /// When to stop refining offline prices. Early stopping is available only with ordinary
    /// matching at levels 7–9. It can change output and work; neither size nor speed is guaranteed
    /// to improve. Standard refinement is the default.
    offline_refinement: OfflineRefinement = .standard,

    /// Rejects unsupported level and strategy combinations without changing encoder state.
    pub fn validate(self: Compression) error{InvalidOptions}!void {
        if (self.level > 9) return error.InvalidOptions;
        if (self.lazy_lookahead == .reduced and (self.level < 4 or self.level > 6 or self
            .strategy != .default)) return error.InvalidOptions;
        if (self.offline_pricing != .full and (self.level < 7 or self.level > 9 or self.strategy !=
            .default)) return error.InvalidOptions;
        if (self.offline_refinement != .standard and (self.level < 7 or self.level > 9 or self
            .strategy != .default)) return error.InvalidOptions;
    }

    test validate {
        for (0..10) |level| {
            for ([_]Strategy{ .default, .huffman_only }) |strategy| {
                const full: Compression = .{ .level = @intCast(level), .strategy = strategy };
                try full.validate();
                var reduced = full;
                reduced.lazy_lookahead = .reduced;
                if (level >= 4 and level <= 6 and strategy == .default) {
                    try reduced.validate();
                } else {
                    try std.testing.expectError(error.InvalidOptions, reduced.validate());
                }
                inline for (.{ .reduced, .maximum_lengths }) |policy| {
                    var pruned_offline = full;
                    pruned_offline.offline_pricing = policy;
                    if (level >= 7 and strategy == .default) {
                        try pruned_offline.validate();
                    } else {
                        try std.testing.expectError(
                            error.InvalidOptions,
                            pruned_offline.validate(),
                        );
                    }
                }
                var early = full;
                early.offline_refinement = .early;
                if (level >= 7 and strategy == .default) {
                    try early.validate();
                } else {
                    try std.testing.expectError(error.InvalidOptions, early.validate());
                }
            }
        }
        try std.testing.expectError(error.InvalidOptions, (Compression{ .level = 10 }).validate());
        try std.testing.expectError(error.InvalidOptions, (Compression{ .level = 255 }).validate());
    }

    /// Optional restriction on how the encoder represents source bytes.
    pub const Strategy = enum {
        /// Select the matching and parsing work described by the level.
        default,
        /// Emit literals without match search, while still selecting stored or Huffman blocks.
        huffman_only,
    };

    /// Effort spent pricing retained lengths and distances for offline matches.
    pub const OfflinePricing = enum {
        /// Consider every retained match that supports each length and use the least costly,
        /// choosing the nearer distance on a tie.
        full,
        /// Consider the first retained match that supports each length. It need not be the nearest.
        reduced,
        /// Consider only the maximum length of each retained match. This skips shorter lengths and
        /// distances that are useful only at those lengths. For equal prices, retain the earlier
        /// candidate; the resulting distance need not be the nearest.
        maximum_lengths,
    };

    /// Controls the number of price-refinement passes for offline parsing.
    pub const OfflineRefinement = enum {
        /// Continue until dynamic cost stops improving or the eight-pass bound is reached.
        standard,
        /// After the second pass, stop if its dynamic cost improved by at most 1% over the first.
        /// Otherwise continue with standard refinement. The reference parse and both passes remain
        /// eligible. This stopping threshold does not bound the change in final compressed size.
        early,
    };

    /// Effort spent checking whether the position after a lazy match is preferable.
    pub const LazyLookahead = enum {
        /// Use the level's ordinary search effort.
        full,
        /// Spend less effort on the lookahead search while retaining the initial search effort.
        reduced,
    };
};

test {
    _ = Compression;
    _ = match_tree;
}

const Profile = enum { stored, huffman, greedy, lazy, offline };

const Effort = struct { profile: Profile, depth: u16 };

fn effort(compression: Compression) EncodeError!Effort {
    try compression.validate();
    if (compression.level == 0) return .{ .profile = .stored, .depth = 0 };
    if (compression.strategy == .huffman_only) return .{ .profile = .huffman, .depth = 0 };
    // Greedy and lazy levels use hash chains; offline levels use a prefix-aware tree. Increasing
    // the level spends different bounded search effort without promising monotonic output size.
    return switch (compression.level) {
        1 => .{ .profile = .greedy, .depth = 4 },
        2 => .{ .profile = .greedy, .depth = 8 },
        3 => .{ .profile = .greedy, .depth = 32 },
        4 => .{ .profile = .lazy, .depth = 64 },
        5 => .{ .profile = .lazy, .depth = 128 },
        6 => .{ .profile = .lazy, .depth = 256 },
        7 => .{ .profile = .offline, .depth = 35 },
        8 => .{ .profile = .offline, .depth = 100 },
        9 => .{ .profile = .offline, .depth = 300 },
        else => unreachable,
    };
}

/// Finite caller-selected bounds, cumulative across suspensions and flushes.
pub const EncodeLimits = struct {
    /// Accepted source bytes; dictionary bytes are excluded.
    input_bytes: u64 = std.math.maxInt(u64),
    /// Returned wire bytes, including enclosing framing when used by a wrapper.
    output_bytes: u64 = std.math.maxInt(u64),
    /// Match probes/comparisons, parser edges and book/header work units. This is an algorithmic
    /// bound, not an instruction or time count. Offline search charges prior candidates and
    /// eight-byte comparisons, including dictionary preparation and replayed history. Offline
    /// pricing charges the full logical length range even when a pricing choice skips lengths.
    /// Bounded table initialization, tree checkpoints, byte tails, cached-match scans, price-run
    /// discovery, state comparisons and ordinary-tree attempts before a package-merge fallback are
    /// uncharged. Also set input_bytes to bound source-dependent scan effort; dictionary and
    /// wrapper metadata may require separate bounds. Callers must also bound repeated steps or
    /// flushes when bounding aggregate fixed setup work.
    work_units: u64 = std.math.maxInt(u64),
};

/// Raw encoding configuration. Optional dictionary history is copied during reset.
pub const EncodeOptions = struct {
    /// Optional preset dictionary, copied during reset; raw streams carry no dictionary identity.
    dictionary: ?[]const u8 = null,
    /// Compression level, lazy-lookahead effort and optional literal-only strategy.
    compression: Compression = .{},
    /// Maximum match distance, in 256..32768 and a power of two.
    window_bytes: usize = 32768,
    /// Cumulative bounds; exhaustion requires reset.
    limits: EncodeLimits = .{},
};

/// End-of-fragment operation. Repeat an action with any unconsumed suffix. Flush/finish latch when
/// that fragment has been accepted. While draining a latched action, supply empty input and the
/// same action until its boundary.
pub const EncodeAction = enum {
    /// Accumulate input until a bounded slab can be encoded.
    process,
    /// Emit a byte-aligned synchronization point, retaining match history.
    flush,
    /// Emit a synchronization point and forget history for subsequent input.
    full_flush,
    /// Close the final block and pad the last byte; no further input is legal.
    finish,
};

/// Blocking or terminal encoder boundary.
pub const EncodeStatus = enum {
    /// The encoder can accept more source bytes.
    need_input,
    /// Drain pending encoded bytes into another output span using the same action.
    need_output,
    /// The requested flush/full-flush boundary is fully emitted; a new action may begin.
    flushed,
    /// The final block and padding are fully emitted; no more source bytes may be added.
    complete,
};

/// Copied per-call progress. Accepted input and returned output may retire.
pub const EncodeProgress = struct {
    /// Accepted bytes from this fragment.
    consumed: usize,
    /// Initialized bytes in this output span; its suffix is untouched.
    produced: usize,
    /// Required resource or completed action.
    status: EncodeStatus,
};

/// Copied cumulative effort and byte accounting; reset starts all counts anew.
pub const EncodeStats = struct {
    /// Source bytes admitted internally, excluding dictionary bytes.
    input_bytes: u64 = 0,
    /// Wire bytes copied to output; wrappers may include framing bytes.
    output_bytes: u64 = 0,
    /// Charged algorithmic units, including all attempted parses and splits.
    work_units: u64 = 0,
    /// Prior match candidates examined by the selected search, including history preparation.
    match_probes: u64 = 0,
    /// Logical match-length edges charged, including lengths skipped by maximum-length pricing.
    parse_edges: u64 = 0,
    /// Serialized blocks, including synchronization blocks.
    blocks: u64 = 0,
    /// Selected stored blocks.
    stored_blocks: u64 = 0,
    /// Selected fixed-Huffman blocks.
    fixed_blocks: u64 = 0,
    /// Selected dynamic-Huffman blocks.
    dynamic_blocks: u64 = 0,
};

const Match = match_tree.Match;
const Matches = match_tree.Matches;

// A zero length identifies a literal byte in value; otherwise value is the match distance.
const Token = struct { length: u16, value: u16 };
const Run = struct { symbol: u8, extra: u8 };
const RunChoice = struct { symbol: u8, take: u8 };
const Book = struct { widths: [286]u8, codes: [286]u16 };

const Header = struct {
    literal: Book,
    distance: Book,
    precode: Book,
    runs: [316]Run,
    run_count: usize,
    literal_count: usize,
    distance_count: usize,
    precode_count: usize,
    bits: u32,
};

const Package = struct { weight: u64, left: u16, right: u16, symbol: u16 };

const HuffmanScratch = struct {
    nodes: [286 * 16]Package,
    lists: [2][572]u16,
    leaves: [286]u16,
    packages: [286]u16,
};

const Kind = enum { stored, fixed, dynamic };
const SearchStats = struct { units: u32, probes: u32 };
const Selection = struct { bits: u32, kind: Kind, dynamic_bits: u32 = 0 };
const Segment = struct { first: usize, end: usize, start: usize, bytes: usize };
const ChainWorkspace = struct { heads: [65536]u32, previous: [window_bytes + slab_bytes]u32 };
const search_bytes = @max(@sizeOf(ChainWorkspace), @sizeOf(match_tree.Workspace));
const search_alignment = @max(@alignOf(ChainWorkspace), @alignOf(match_tree.Workspace));

/// Exclusive bounded scratch, with no allocator retained. Construct directly at its final address
/// using create or caller storage. Encoder borrows it until reset/end of use. Contents are private
/// and initialized on demand. The fixed reservation is below 8 MiB on supported targets,
/// independent of stream length. Query @sizeOf/@alignOf for the selected target.
pub const EncoderWorkspace = struct {
    data: [window_bytes + slab_bytes]u8,
    // Chain and tree searches are mutually exclusive within one encoder reset.
    search: [search_bytes]u8 align(search_alignment),
    matches: [slab_bytes]Matches,
    costs: [slab_bytes + 1]u32,
    choices: [slab_bytes]Token,
    tokens: [slab_bytes]Token,
    best: [slab_bytes]Token,
    wire: [slab_bytes + 128]u8,
    huffman: HuffmanScratch,
    header: Header,
    header_trial: Header,
    segments: [16]Segment,

    fn chain(self: *EncoderWorkspace) *ChainWorkspace {
        return @ptrCast(&self.search);
    }

    fn tree(self: *EncoderWorkspace) *match_tree.Workspace {
        return @ptrCast(&self.search);
    }

    // Pricing and token arrays are dead during match search. Borrow their bytes for the tree
    // checkpoint, restoring the tree before pricing and token selection overwrite those arrays.
    fn copyTreeCheckpoint(self: *EncoderWorkspace, comptime restore: bool) void {
        const pricing_bytes = @sizeOf(@TypeOf(self.costs)) + @sizeOf(@TypeOf(self.choices));
        const token_bytes = @sizeOf(@TypeOf(self.tokens)) + @sizeOf(@TypeOf(self.best));
        comptime std.debug.assert(pricing_bytes + token_bytes >= @sizeOf(match_tree.Workspace));
        const tree_bytes = std.mem.asBytes(self.tree());
        const segments = .{
            std.mem.asBytes(&self.costs),
            std.mem.asBytes(&self.choices),
            std.mem.asBytes(&self.tokens),
            std.mem.asBytes(&self.best),
        };
        var offset: usize = 0;
        inline for (segments) |segment| {
            const count = @min(segment.len, tree_bytes.len - offset);
            if (restore) {
                @memcpy(tree_bytes[offset..][0..count], segment[0..count]);
            } else {
                @memcpy(segment[0..count], tree_bytes[offset..][0..count]);
            }
            offset += count;
        }
        std.debug.assert(offset == tree_bytes.len);
    }

    /// Reserves undefined scratch without creating a large temporary.
    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*EncoderWorkspace {
        return allocator.create(EncoderWorkspace);
    }

    /// Releases scratch through its construction allocator after all borrows.
    pub fn destroy(self: *EncoderWorkspace, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    /// Erases retained input, history and parsing scratch after ending its use.
    pub fn clear(self: *EncoderWorkspace) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};

/// Bound for one complete-buffer encode call, including final padding. Overflow returns
/// CounterOverflow. Streaming can add blocks when process fills a slab or flush/finish forces a
/// boundary; use step's backpressure. Each empty stored synchronization marker occupies at most six
/// bytes.
pub fn encodeBound(source_bytes: usize) EncodeError!usize {
    const partial = @intFromBool(source_bytes % slab_bytes != 0);
    const slabs = @max(1, source_bytes / slab_bytes + partial);
    const overhead = std.math.mul(usize, slabs, 5) catch return error.CounterOverflow;
    return std.math.add(usize, source_bytes, overhead + 1) catch error.CounterOverflow;
}

/// Encodes one independent stream into exact unpadded caller storage. The returned prefix borrows
/// output. Source/output/workspace must be disjoint; failures may change output. No state or
/// allocator survives this call.
pub fn encode(
    source: []const u8,
    output: []u8,
    workspace: *EncoderWorkspace,
    options: EncodeOptions,
) EncodeError![]u8 {
    try disjoint(source, output);
    try disjoint(source, std.mem.asBytes(workspace));
    try disjoint(output, std.mem.asBytes(workspace));
    if (options.dictionary) |dictionary| try disjoint(dictionary, output);
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, options);
    const result = try encoder.step(source, output, .finish);
    if (result.status != .complete) return error.OutputTooSmall;
    return output[0..result.produced];
}

// This declaration-linked example demonstrates a complete call and a fragmented stream using the
// same caller-owned workspace. Raw DEFLATE carries neither a dictionary identifier nor a checksum.
test encode {
    const decoding = @import("decode.zig");
    const allocator = std.testing.allocator;
    const source = "shared history: a small record with a shared history";
    const dictionary = "common shared history: ";
    const encoding_workspace = try EncoderWorkspace.create(allocator);
    defer encoding_workspace.destroy(allocator);
    const decoding_workspace = try decoding.DecoderWorkspace.create(allocator);
    defer decoding_workspace.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const capacity = try encodeBound(source.len);
    const complete_wire = try allocator.alloc(u8, capacity);
    defer allocator.free(complete_wire);
    const fragmented_wire = try allocator.alloc(u8, capacity);
    defer allocator.free(fragmented_wire);
    const restored = try allocator.alloc(u8, source.len);
    defer allocator.free(restored);

    // Omitting compression selects level 6. The returned slice borrows complete_wire; neither the
    // source nor the dictionary is retained after this complete call.
    const options: EncodeOptions = .{ .dictionary = dictionary };
    const wire = try encode(source, complete_wire, encoding_workspace, options);
    const storage: decoding.DecodeStorage = .{
        .workspace = decoding_workspace,
        .history = history,
    };
    const recovered = try decoding.decode(
        wire,
        restored,
        storage,
        .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(source.len, recovered.produced);
    try std.testing.expectEqualSlices(u8, source, restored);

    // Level 9 spends more effort on offline parsing for callers that favor size. Reduced offline
    // pricing and early refinement are optional speed/size tradeoffs; their effects depend on the
    // data.
    const offline_wire = try encode(
        source,
        fragmented_wire,
        encoding_workspace,
        .{
            .dictionary = dictionary,
            .compression = .{
                .level = 9,
                .offline_pricing = .reduced,
                .offline_refinement = .early,
            },
        },
    );
    const restored_offline = try decoding.decode(
        offline_wire,
        restored,
        storage,
        .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(source.len, restored_offline.produced);
    try std.testing.expectEqualSlices(u8, source, restored);

    // Reduced lazy lookahead is an opt-in tradeoff at levels 4–6. It can change output and work;
    // the default retains full lookahead.
    const reduced_wire = try encode(
        source,
        fragmented_wire,
        encoding_workspace,
        .{ .dictionary = dictionary, .compression = .{ .lazy_lookahead = .reduced } },
    );
    const restored_reduced = try decoding.decode(
        reduced_wire,
        restored,
        storage,
        .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(source.len, restored_reduced.produced);
    try std.testing.expectEqualSlices(u8, source, restored);

    // Streaming keeps the workspace borrowed but lets each accepted input and returned output span
    // retire. Repeat finish while draining pending output; enclosing formats own integrity checks.
    var encoder: Encoder = undefined;
    try encoder.reset(encoding_workspace, options);
    var read: usize = 0;
    var written: usize = 0;
    while (true) {
        const end = @min(source.len, read + 7);
        const action: EncodeAction = if (end == source.len) .finish else .process;
        const output_end = @min(fragmented_wire.len, written + 11);
        const progress = try encoder.step(
            source[read..end],
            fragmented_wire[written..output_end],
            action,
        );
        read += progress.consumed;
        written += progress.produced;
        if (progress.status == .complete) break;
        try std.testing.expect(progress.consumed != 0 or progress.produced != 0);
    }
    const streamed = try decoding.decode(
        fragmented_wire[0..written],
        restored,
        storage,
        .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(source.len, streamed.produced);
    try std.testing.expectEqualSlices(u8, source, restored);
}

/// Persistent bounded encoder. Accepted input and returned output may retire after every step; no
/// caller input/output pointer or allocator is retained. Construct the owner at its final address
/// and serialize its exclusive workspace borrow. Errors require reset; reset abandons unpublished
/// pending wire bytes.
pub const Encoder = struct {
    workspace: *EncoderWorkspace,
    options: struct {
        profile: Profile,
        depth: u16,
        reduced_lookahead: bool,
        offline_pricing: Compression.OfflinePricing,
        offline_refinement: Compression.OfflineRefinement,
        window_bytes: usize,
        limits: EncodeLimits,
    },
    stats: EncodeStats,

    history: usize,
    buffered: usize,

    pending: usize,
    sent: usize,
    bits: u64,
    bit_count: u6,

    boundary: ?EncodeAction,
    finished: bool,
    failed: bool,
    started: bool,

    /// Initializes existing storage, copying optional dictionary history. Invalid options and
    /// overlaps among the incoming dictionary, owner and workspace are refused before mutation.
    pub fn reset(
        self: *Encoder,
        workspace: *EncoderWorkspace,
        options: EncodeOptions,
    ) EncodeError!void {
        try disjoint(std.mem.asBytes(self), std.mem.asBytes(workspace));
        if (options.window_bytes < 256 or options.window_bytes > window_bytes)
            return error.InvalidOptions;
        if (!std.math.isPowerOfTwo(options.window_bytes)) return error.InvalidOptions;
        const selected = try effort(options.compression);
        if (options.dictionary) |dictionary| {
            // The dictionary may point into the old owner. Admit it before replacing self so a
            // refused reset cannot corrupt the bytes the caller supplied.
            try disjoint(dictionary, std.mem.asBytes(self));
            try disjoint(dictionary, std.mem.asBytes(workspace));
        }
        self.* = .{
            .workspace = workspace,
            .options = .{
                .profile = selected.profile,
                .depth = selected.depth,
                .reduced_lookahead = options.compression.lazy_lookahead == .reduced,
                .offline_pricing = options.compression.offline_pricing,
                .offline_refinement = options.compression.offline_refinement,
                .window_bytes = options.window_bytes,
                .limits = options.limits,
            },
            .stats = .{},
            .history = 0,
            .buffered = 0,
            .pending = 0,
            .sent = 0,
            .bits = 0,
            .bit_count = 0,
            .boundary = null,
            .finished = false,
            .failed = false,
            .started = false,
        };
        if (options.dictionary) |dictionary| try self.setDictionary(dictionary);
    }

    /// Copies only the reachable dictionary suffix before the first step. Dictionary bytes may
    /// retire on return. Multiple attachments replace the previous history; invalid state/overlap
    /// poisons the owner.
    pub fn setDictionary(self: *Encoder, dictionary: []const u8) EncodeError!void {
        if (self.failed) return error.NeedReset;
        self.attach(dictionary) catch |err| {
            self.failed = true;
            return err;
        };
    }

    /// Returns copied byte/effort counters without exposing internal scratch. After failure, counts
    /// may include bytes and effort admitted during the failed step even though it returned no
    /// progress. Reset starts counts anew.
    pub fn counts(self: *const Encoder) EncodeStats {
        return self.stats;
    }

    /// Processes one fragment. An empty output span may still accept input into scratch. A flush
    /// boundary is returned once; resume with a new operation. Complete is idempotent only with
    /// empty input and finish. Failure may change output, returns no progress value and requires
    /// reset. Counts may still include work or bytes admitted during the failed call.
    pub fn step(
        self: *Encoder,
        input: []const u8,
        output: []u8,
        action: EncodeAction,
    ) EncodeError!EncodeProgress {
        if (self.failed) {
            @branchHint(.unlikely);
            return error.NeedReset;
        }
        return self.advance(input, output, action) catch |err| {
            @branchHint(.cold);
            self.failed = true;
            return err;
        };
    }

    fn attach(self: *Encoder, dictionary: []const u8) EncodeError!void {
        if (self.started) return error.InvalidState;
        try disjoint(dictionary, std.mem.asBytes(self));
        try disjoint(dictionary, std.mem.asBytes(self.workspace));
        self.history = @min(dictionary.len, self.options.window_bytes);
        @memcpy(self.workspace.data[0..self.history], dictionary[dictionary.len - self.history ..]);
    }

    fn advance(
        self: *Encoder,
        input: []const u8,
        output: []u8,
        action: EncodeAction,
    ) EncodeError!EncodeProgress {
        try disjoint(input, output);
        inline for (.{ std.mem.asBytes(self), std.mem.asBytes(self.workspace) }) |reservation| {
            try disjoint(input, reservation);
            try disjoint(output, reservation);
        }
        if (self.finished) {
            if (input.len != 0 or action != .finish) return error.InvalidState;
            return .{ .consumed = 0, .produced = 0, .status = .complete };
        }
        if (self.boundary) |latched| {
            if (input.len != 0 or latched != action) return error.InvalidState;
        }
        self.started = true;
        if (self.options.profile == .stored and action == .finish) {
            if (try self.finishStored(
                input,
                output,
            )) |written| return .{
                .consumed = input.len,
                .produced = written,
                .status = .complete,
            };
        }

        var read: usize = 0;
        var written: usize = 0;
        while (true) {
            const output_left = self.options.limits.output_bytes -| self.stats.output_bytes;
            const available: usize = @intCast(@min(output.len - written, output_left));
            const amount = @min(available, self.pending - self.sent);
            @memcpy(output[written..][0..amount], self.workspace.wire[self.sent..][0..amount]);
            self.sent += amount;
            written += amount;
            self.stats.output_bytes = try addCount(self.stats.output_bytes, amount);
            if (self.sent != self.pending) {
                if (self.stats.output_bytes == self.options.limits.output_bytes)
                    return error.LimitExceeded;
                return .{ .consumed = read, .produced = written, .status = .need_output };
            }
            self.pending = 0;
            self.sent = 0;
            if (self.boundary) |latched| {
                self.boundary = null;
                if (latched == .finish) self.finished = true;
                if (latched == .full_flush) self.history = 0;
                return .{
                    .consumed = read,
                    .produced = written,
                    .status = if (latched == .finish) .complete else .flushed,
                };
            }
            const input_left = self.options.limits.input_bytes -| self.stats.input_bytes;
            const room: usize = @intCast(@min(slab_bytes - self.buffered, input_left));
            const take = @min(room, input.len - read);
            @memcpy(
                self.workspace.data[self.history + self.buffered ..][0..take],
                input[read..][0..take],
            );
            self.buffered += take;
            read += take;
            self.stats.input_bytes = try addCount(self.stats.input_bytes, take);
            if (read < input.len and self.stats.input_bytes == self.options.limits.input_bytes)
                return error.LimitExceeded;
            const at_end = read == input.len;
            if (self.buffered == slab_bytes or (at_end and action != .process)) {
                const closing = at_end and action != .process;
                try self.buildBlock(closing and action == .finish);
                if (closing) {
                    if (action != .finish) {
                        try self.stored(&.{}, false);
                    } else {
                        self.alignBits();
                    }
                    self.boundary = action;
                }
                continue;
            }
            return .{ .consumed = read, .produced = written, .status = .need_input };
        }
    }

    // A complete stored finish needs neither staged input nor a retained match history. Use the
    // ordinary path when buffering, pending output or a limit can suspend/refuse this operation.
    fn finishStored(self: *Encoder, input: []const u8, output: []u8) EncodeError!?usize {
        if (self.buffered != 0 or self.pending != 0 or self.boundary != null) return null;
        if (self.bit_count != 0) return null;
        const blocks = @max(1, input.len / slab_bytes + @intFromBool(input.len % slab_bytes != 0));
        const overhead = std.math.mul(usize, blocks, 5) catch return null;
        const bytes = std.math.add(usize, input.len, overhead) catch return null;
        const input_left = self.options.limits.input_bytes -| self.stats.input_bytes;
        const output_left = self.options.limits.output_bytes -| self.stats.output_bytes;
        if (bytes > output.len or input.len > input_left or bytes > output_left) return null;

        var next_stats = self.stats;
        next_stats.input_bytes = try addCount(next_stats.input_bytes, input.len);
        next_stats.output_bytes = try addCount(next_stats.output_bytes, bytes);
        next_stats.blocks = try addCount(next_stats.blocks, blocks);
        next_stats.stored_blocks = try addCount(next_stats.stored_blocks, blocks);

        var read: usize = 0;
        var written: usize = 0;
        for (0..blocks) |index| {
            const take: usize = @min(slab_bytes, input.len - read);
            output[written] = @intFromBool(index + 1 == blocks);
            writeStoredBody(input[read..][0..take], output[written + 1 ..][0 .. take + 4]);
            read += take;
            written += take + 5;
        }
        self.stats = next_stats;
        self.history = 0;
        self.finished = true;
        return written;
    }

    fn work(self: *Encoder, units: u64) EncodeError!void {
        if (units > self.options.limits.work_units -| self.stats.work_units)
            return error.LimitExceeded;
        self.stats.work_units = try addCount(self.stats.work_units, units);
    }

    fn buildBlock(self: *Encoder, final: bool) EncodeError!void {
        const workspace = self.workspace;
        if (self.options.profile == .stored) {
            try self.stored(workspace.data[self.history..][0..self.buffered], final);
        } else {
            try self.compressedBlock(final);
        }
        const total = self.history + self.buffered;
        self.history = @min(total, self.options.window_bytes);
        std.mem.copyForwards(
            u8,
            workspace.data[0..self.history],
            workspace.data[total - self.history .. total],
        );
        self.buffered = 0;
    }

    fn compressedBlock(self: *Encoder, final: bool) EncodeError!void {
        const workspace = self.workspace;
        if (self.options.profile == .offline) {
            try self.findOfflineTreeMatches(final);
        } else if (self.options.profile != .huffman) {
            try self.findMatches();
        }
        var count = self.referenceParse(
            self.options.profile == .lazy or self.options.profile == .offline,
        );
        var selection = try self.select(workspace.tokens[0..count], self.buffered, self.bit_count);
        if (self.options.profile != .offline) {
            // Selection leaves the exact chosen books/header ready for emission. Only offline
            // parsing can replace these tokens or split them into separately priced blocks.
            return self.emit(
                workspace.tokens[0..count],
                .{ .first = 0, .end = count, .start = 0, .bytes = self.buffered },
                selection.kind,
                final,
            );
        }

        // The reusable state needs a long run of identical match metadata. Prices can split such
        // runs but cannot create one, so this scan may conservatively select the reuse path.
        const reuse_possible = mayReusePricing(workspace.matches[0..self.buffered]);
        var best_count = count;
        var best_bits = selection.bits;
        @memcpy(workspace.best[0..count], workspace.tokens[0..count]);
        fixedBook(&workspace.header.literal, false);
        fixedBook(&workspace.header.distance, true);
        var previous_dynamic_best: ?u32 = null;
        for (0..8) |pass| {
            const literal_widths = workspace.header.literal.widths;
            const distance_widths = workspace.header.distance.widths[0..30].*;
            const work_before = self.stats.work_units;
            const edges_before = self.stats.parse_edges;
            count = switch (self.options.offline_pricing) {
                .maximum_lengths => if (reuse_possible) try self.priceParse(
                    true,
                    .maximum_lengths,
                    &workspace.header.literal,
                    &workspace.header.distance,
                ) else try self.priceParse(
                    false,
                    .maximum_lengths,
                    &workspace.header.literal,
                    &workspace.header.distance,
                ),
                .reduced => if (reuse_possible) try self.priceParse(
                    true,
                    .reduced,
                    &workspace.header.literal,
                    &workspace.header.distance,
                ) else try self.priceParse(
                    false,
                    .reduced,
                    &workspace.header.literal,
                    &workspace.header.distance,
                ),
                .full => if (reuse_possible) try self.priceParse(
                    true,
                    .full,
                    &workspace.header.literal,
                    &workspace.header.distance,
                ) else try self.priceParse(
                    false,
                    .full,
                    &workspace.header.literal,
                    &workspace.header.distance,
                ),
            };
            selection = try self.select(workspace.tokens[0..count], self.buffered, self.bit_count);
            if (selection.bits < best_bits) {
                best_bits = selection.bits;
                best_count = count;
                @memcpy(workspace.best[0..count], workspace.tokens[0..count]);
            }
            // Both stopping rules consider the triggering pass before returning the best parse.
            if (self.options.offline_refinement == .early and earlyStop(
                pass,
                previous_dynamic_best,
                selection.dynamic_bits,
            )) break;
            // Standard refinement stops on equal or worse dynamic cost; a one-bit gain continues.
            if (adaptiveStop(previous_dynamic_best, selection.dynamic_bits)) break;
            previous_dynamic_best = selection.dynamic_bits;
            // select constructs the next dynamic price books, including when a fixed/stored
            // candidate won the serialized choice.
            if (!std.mem.eql(
                u8,
                &literal_widths,
                &workspace.header.literal.widths,
            ) or !std.mem.eql(
                u8,
                &distance_widths,
                workspace.header.distance.widths[0..30],
            )) continue;
            // Stable books guarantee that the next pass has the same dynamic price and stops.
            // Reserve that one logical pass only when it fits. Otherwise execute it normally so
            // refusal still reports the actual admission point and partial counters.
            const remaining: u64 = if (pass < 7) 1 else 0;
            const units = std.math.mul(
                u64,
                self.stats.work_units - work_before,
                remaining,
            ) catch continue;
            const edges = std.math.mul(
                u64,
                self.stats.parse_edges - edges_before,
                remaining,
            ) catch continue;
            const work_left = self.options.limits.work_units -| self.stats.work_units;
            const edges_left = std.math.maxInt(u64) - self.stats.parse_edges;
            if (units > work_left or edges > edges_left) continue;
            try self.work(units);
            self.stats.parse_edges += edges;
            break;
        }
        workspace.segments[0] = .{
            .first = 0,
            .end = best_count,
            .start = 0,
            .bytes = self.buffered,
        };
        var segments: usize = 1;
        if (self.buffered >= 4096) {
            segments = try self.split(0, best_count, 0, self.buffered, self.bit_count, 0, 0);
        }
        for (workspace.segments[0..segments], 0..) |segment, index| {
            const tokens = workspace.best[segment.first..segment.end];
            const chosen = try self.select(tokens, segment.bytes, self.bit_count);
            try self.emit(tokens, segment, chosen.kind, final and index + 1 == segments);
        }
    }

    // A checkpoint excludes the final 257 positions whose comparisons may need later bytes.
    // Coordinates are derived from accepted input counts, so no additional owner state is kept.
    noinline fn findOfflineTreeMatches(self: *Encoder, final: bool) EncodeError!void {
        const processed = self.stats.input_bytes - self.buffered;
        const cycle: u64 = 1 << 31;
        const phase: usize = @intCast(processed & (cycle - 1));
        // Rebuild near each coordinate rollover. The margin exceeds a slab plus any history,
        // covering the block that crossed the boundary even after a short flush.
        const near_rollover = processed >= cycle and phase < slab_bytes + window_bytes;
        const rebuild = processed == 0 or self.history == 0 or near_rollover;
        if (final and rebuild) return self.findOfflineTreeMatchesStandalone();
        const workspace = self.workspace;
        const total = self.history + self.buffered;
        const data = workspace.data[0..total];
        const depth: usize = self.options.depth;
        const nice: usize = if (depth <= 35) 75 else if (depth <= 100) 150 else 258;
        const origin = self.options.window_bytes + phase - self.history;
        if (rebuild) workspace.tree().resetAll();
        const pending = if (final) 0 else @min(total, self.options.window_bytes, 257);
        const checkpoint = total - pending;
        const first = if (rebuild) @as(usize, 0) else self.history - @min(self.history, 257);
        std.debug.assert(first <= checkpoint);
        for (first..total) |position| {
            if (pending != 0 and position == checkpoint) workspace.copyTreeCheckpoint(false);
            const remaining = self.options.limits.work_units - self.stats.work_units;
            const matches = if (position < self.history) null else &workspace.matches[
                position -
                    self.history
            ];
            var partial: match_tree.Stats = undefined;
            const result = if (remaining >= depth * 34 + 1) match_tree.insertAndFindAt(
                false,
                workspace.tree(),
                data,
                position,
                origin,
                self.options.window_bytes,
                depth,
                nice,
                matches,
                remaining,
                &partial,
            ) else match_tree.insertAndFindAt(
                true,
                workspace.tree(),
                data,
                position,
                origin,
                self.options.window_bytes,
                depth,
                nice,
                matches,
                remaining,
                &partial,
            );
            const stats = result catch |err| {
                try self.work(partial.units);
                self.stats.match_probes = try addCount(self.stats.match_probes, partial.probes);
                return err;
            };
            try self.work(stats.units);
            self.stats.match_probes = try addCount(self.stats.match_probes, stats.probes);
        }
        if (pending != 0) workspace.copyTreeCheckpoint(true);
    }

    // Rebuild the bounded tree for a standalone slab, including copied dictionary history.
    noinline fn findOfflineTreeMatchesStandalone(self: *Encoder) EncodeError!void {
        const workspace = self.workspace;
        const total = self.history + self.buffered;
        const depth: usize = self.options.depth;
        const nice: usize = if (depth <= 35) 75 else if (depth <= 100) 150 else 258;
        workspace.tree().reset(workspace.data[0..total]);
        for (0..total) |position| {
            const remaining = self.options.limits.work_units - self.stats.work_units;
            const matches = if (position < self.history) null else &workspace.matches[
                position -
                    self.history
            ];
            var partial: match_tree.Stats = undefined;
            const result = if (remaining >= depth * 34 + 1) match_tree.insertAndFind(
                false,
                workspace.tree(),
                workspace.data[0..total],
                position,
                self.options.window_bytes,
                depth,
                nice,
                matches,
                remaining,
                &partial,
            ) else match_tree.insertAndFind(
                true,
                workspace.tree(),
                workspace.data[0..total],
                position,
                self.options.window_bytes,
                depth,
                nice,
                matches,
                remaining,
                &partial,
            );
            const stats = result catch |err| {
                try self.work(partial.units);
                self.stats.match_probes = try addCount(self.stats.match_probes, partial.probes);
                return err;
            };
            try self.work(stats.units);
            self.stats.match_probes = try addCount(self.stats.match_probes, stats.probes);
        }
    }

    fn findMatches(self: *Encoder) EncodeError!void {
        if (self.options.reduced_lookahead) return self.findMatchesMode(true);
        return self.findMatchesMode(false);
    }

    // Select the lookahead policy once per block, keeping it out of the full-search loop.
    noinline fn findMatchesMode(self: *Encoder, comptime reduced: bool) EncodeError!void {
        const workspace = self.workspace;
        const total = self.history + self.buffered;
        if (total <= 256) {
            // Only hashes present in this slab can be read below. Clear those heads first so short
            // inputs avoid clearing the whole table, even when keys collide or scratch was reused.
            for (0..total -| 2) |position| {
                workspace.chain().heads[hash3(workspace.data[position..][0..3])] = no_position;
            }
        } else {
            @memset(&workspace.chain().heads, no_position);
        }
        const depth: usize = self.options.depth;
        const lazy = self.options.profile == .lazy;
        var next_search = self.history;
        var pending_length: usize = 0;
        for (0..total) |position| {
            if (total - position < 3) {
                if (position >= self.history) workspace.matches[position - self.history].count = 0;
                continue;
            }
            const hash = hash3(workspace.data[position..][0..3]);
            const candidate = workspace.chain().heads[hash];
            workspace.chain().previous[position] = candidate;
            workspace.chain().heads[hash] = @intCast(position);
            if (position < self.history) continue;
            // Every position enters the chain, including bytes covered by an earlier match.
            // Greedy/lazy parsing only needs matches at the next token and its lazy lookahead.
            if (position < next_search) continue;
            const matches = &workspace.matches[position - self.history];
            matches.count = 0;
            const remaining = self.options.limits.work_units - self.stats.work_units;
            const search_depth = if (reduced and pending_length != 0) depth / 2 else depth;
            // One candidate plus at most 31 word comparisons fits this bound. Admit the whole
            // position when possible, otherwise check each charged operation. Both paths publish
            // identical exact counters.
            var partial: SearchStats = undefined;
            const result = if (remaining >= search_depth * 34) self.scanMatches(
                false,
                position,
                total,
                candidate,
                search_depth,
                remaining,
                &partial,
            ) else self.scanMatches(
                true,
                position,
                total,
                candidate,
                search_depth,
                remaining,
                &partial,
            );
            const measured = result catch |err| {
                try self.work(partial.units);
                self.stats.match_probes = try addCount(self.stats.match_probes, partial.probes);
                return err;
            };
            try self.work(measured.units);
            self.stats.match_probes = try addCount(self.stats.match_probes, measured.probes);
            var length: usize = 0;
            if (matches.count != 0) length = matches.items[matches.count - 1].length;
            if (lazy and pending_length != 0 and length <= pending_length) {
                // The previous position's match wins; this position was its lookahead.
                next_search = position + pending_length - 1;
                pending_length = 0;
            } else {
                // A longer lookahead makes the previous byte a literal. It is now the next token.
                pending_length = if (lazy) length else 0;
                next_search = position + if (lazy) 1 else @max(1, length);
            }
        }
    }

    fn scanMatches(
        self: *Encoder,
        comptime bounded: bool,
        position: usize,
        total: usize,
        first: u32,
        depth: usize,
        budget: u64,
        partial: *SearchStats,
    ) EncodeError!SearchStats {
        const workspace = self.workspace;
        const matches = &workspace.matches[position - self.history];
        const maximum = @min(258, total - position);
        const earliest = position -| self.options.window_bytes;
        const source = workspace.data[position..];
        var candidate = first;
        var longest: usize = 2;
        var measured: SearchStats = .{ .units = 0, .probes = 0 };
        defer partial.* = measured;
        while (candidate != no_position and candidate >= earliest and measured.probes < depth) {
            const candidate_position: usize = candidate;
            try searchWork(bounded, &measured.units, budget);
            measured.probes += 1;
            const prior = workspace.data[candidate_position..];
            if (prior[longest] == source[longest] and std.mem.eql(u8, prior[0..3], source[0..3])) {
                var length: usize = 3;
                while (length + 8 <= maximum) : (length += 8) {
                    try searchWork(bounded, &measured.units, budget);
                    const prior_word = std.mem.readInt(u64, prior[length..][0..8], .little);
                    const source_word = std.mem.readInt(u64, source[length..][0..8], .little);
                    if (prior_word != source_word) break;
                }
                while (length < maximum and prior[length] == source[length]) : (length += 1) {}
                if (length > longest) {
                    const slot = @min(matches.count, alternatives - 1);
                    matches.items[slot] = .{
                        .length = @intCast(length),
                        .distance = @intCast(position - candidate_position),
                    };
                    matches.count = @min(alternatives, matches.count + 1);
                    longest = length;
                    if (length == maximum) break;
                }
            }
            candidate = workspace.chain().previous[candidate_position];
        }
        return measured;
    }

    inline fn searchWork(comptime bounded: bool, units: *u32, budget: u64) EncodeError!void {
        if (bounded and units.* >= budget) return error.LimitExceeded;
        units.* += 1;
    }

    fn referenceParse(self: *Encoder, lazy: bool) usize {
        const workspace = self.workspace;
        var count: usize = 0;
        var position: usize = 0;
        while (position < self.buffered) {
            const matches = &workspace.matches[position];
            var length: usize = 0;
            var distance: u16 = 0;
            if (self.options.profile != .huffman and matches.count != 0) {
                const match = matches.items[matches.count - 1];
                length = match.length;
                distance = match.distance;
                if (lazy and position + 1 < self.buffered) {
                    const next = &workspace.matches[position + 1];
                    if (next.count != 0 and next.items[next.count - 1].length > length) length = 0;
                }
            }
            const value: u16 = if (length == 0) workspace.data[
                self.history +
                    position
            ] else distance;
            workspace.tokens[count] = .{ .length = @intCast(length), .value = value };
            position += @max(1, length);
            count += 1;
        }
        return count;
    }

    noinline fn priceParse(
        self: *Encoder,
        comptime reuse: bool,
        comptime policy: Compression.OfflinePricing,
        literal: *const Book,
        distance: *const Book,
    ) EncodeError!usize {
        const workspace = self.workspace;
        // Copy prices: header construction after this parse may replace books.
        var literal_prices: [286]u32 = undefined;
        var distance_prices: [30]u32 = undefined;
        for (&literal_prices, literal.widths) |*cost, width| cost.* = if (width == 0) 13 else width;
        for (&distance_prices, distance.widths[0..30], 0..) |*cost, width, i| {
            const code_price: u32 = if (width == 0) 10 else width;
            cost.* = code_price + distance_extra[i];
        }
        var length_prices: [259]u32 = undefined;
        for (3..259) |length| {
            const slot = lengthSlot(length);
            length_prices[length] = literal_prices[257 + @as(usize, slot)] + length_extra[slot];
        }
        workspace.costs[self.buffered] = 0;
        var run: PriceRun = .{ .first = self.buffered };
        var position = self.buffered;
        while (position != 0) {
            position -= 1;
            if (reuse and position < run.first) run = PriceRun.find(
                self,
                position,
                &literal_prices,
            );
            const value = workspace.data[self.history + position];
            var cost = literal_prices[value] + workspace.costs[position + 1];
            var choice: Token = .{ .length = 0, .value = value };
            const matches = &workspace.matches[position];
            if (matches.count != 0) {
                const maximum = matches.items[matches.count - 1].length;
                // Charge the full logical length range even when a pricing choice skips lengths.
                try self.work(maximum - 2);
                self.stats.parse_edges = try addCount(self.stats.parse_edges, maximum - 2);
                if (policy == .maximum_lengths) {
                    // Only retained maximum lengths participate in this pruned parse.
                    for (matches.items[0..matches.count]) |match| {
                        const length: usize = match.length;
                        const distance_price = distance_prices[distanceSlot(match.distance)];
                        const candidate = distance_price + length_prices[length] + workspace
                            .costs[position + length];
                        if (candidate < cost) {
                            cost = candidate;
                            choice = .{ .length = match.length, .value = match.distance };
                        }
                    }
                } else if (reuse and matches.count == 1) {
                    const match = matches.items[0];
                    self.priceSingleMatch(
                        position,
                        match,
                        &length_prices,
                        distance_prices[distanceSlot(match.distance)],
                        &cost,
                        &choice,
                    );
                } else if (policy == .reduced) {
                    var length: usize = 3;
                    for (matches.items[0..matches.count]) |match| {
                        const distance_price = distance_prices[distanceSlot(match.distance)];
                        while (length <= match.length) : (length += 1) {
                            const candidate = distance_price + length_prices[length] + workspace
                                .costs[position + length];
                            if (candidate < cost) {
                                cost = candidate;
                                choice = .{ .length = @intCast(length), .value = match.distance };
                            }
                        }
                    }
                } else {
                    var suffix: [alternatives]u8 = undefined;
                    var match_prices: [alternatives]u32 = undefined;
                    for (matches.items[0..matches.count], 0..) |match, i| {
                        match_prices[i] = distance_prices[distanceSlot(match.distance)];
                    }
                    var i: usize = matches.count;
                    var cheapest: usize = i - 1;
                    while (i != 0) {
                        i -= 1;
                        if (match_prices[i] < match_prices[cheapest] or (match_prices[i] ==
                            match_prices[cheapest] and matches.items[i].distance < matches
                            .items[cheapest].distance))
                        {
                            cheapest = i;
                        }
                        suffix[i] = @intCast(cheapest);
                    }
                    var index: usize = 0;
                    // The first sixteen price bands contain at most four lengths each. Direct scans
                    // avoid range/reduction overhead for short matches.
                    if (maximum < 35) {
                        var length: usize = 3;
                        while (length <= maximum) {
                            while (matches.items[index].length < length) index += 1;
                            const selected = suffix[index];
                            // The cheapest usable distance stays cheapest until its match ends.
                            const match = matches.items[selected];
                            const distance_price = match_prices[selected];
                            while (length <= match.length) : (length += 1) {
                                const match_price = length_prices[length] + distance_price;
                                const candidate = match_price + workspace.costs[position + length];
                                if (candidate < cost) {
                                    cost = candidate;
                                    choice = .{
                                        .length = @intCast(length),
                                        .value = match.distance,
                                    };
                                }
                            }
                        }
                    } else {
                        var slot: usize = 0;
                        var length: usize = 3;
                        while (length <= maximum) {
                            while (matches.items[index].length < length) index += 1;
                            const selected = suffix[index];
                            const match = matches.items[selected];
                            // Length-code prices are constant within an RFC band. The cheapest
                            // usable retained distance stays selected until that match ends,
                            // including nearest ties among retained alternatives.
                            const band_end = if (slot == 28) 258 else length_base[slot + 1] - 1;
                            const end = @min(band_end, match.length);
                            const first_cost = position + length;
                            const suffix_costs = workspace.costs[first_cost .. position + end + 1];
                            const take = if (end == length) length else length + minimumCostIndex(
                                suffix_costs,
                            );
                            const match_price = length_prices[length] + match_prices[selected];
                            const candidate = match_price + workspace.costs[position + take];
                            if (candidate < cost) {
                                cost = candidate;
                                choice = .{ .length = @intCast(take), .value = match.distance };
                            }
                            length = end + 1;
                            if (end == band_end) slot += 1;
                        }
                    }
                }
            }
            workspace.costs[position] = cost;
            workspace.choices[position] = choice;
            if (reuse) position = try run.reuse(self, position);
        }
        position = 0;
        var count: usize = 0;
        while (position < self.buffered) {
            const token = workspace.choices[position];
            workspace.tokens[count] = token;
            position += @max(1, token.length);
            count += 1;
        }
        return count;
    }

    // A single retained distance needs neither suffix-price selection nor frontier-boundary checks.
    // Keep this concrete path inline so each range shares that distance's price and choice.
    inline fn priceSingleMatch(
        self: *Encoder,
        position: usize,
        match: Match,
        length_prices: *const [259]u32,
        distance_price: u32,
        cost: *u32,
        choice: *Token,
    ) void {
        const costs = &self.workspace.costs;
        if (match.length < 35) {
            for (3..@as(usize, match.length) + 1) |length| {
                const candidate = distance_price + length_prices[length] + costs[position + length];
                if (candidate < cost.*) {
                    cost.* = candidate;
                    choice.* = .{ .length = @intCast(length), .value = match.distance };
                }
            }
            return;
        }
        var slot: usize = 0;
        var length: usize = 3;
        while (length <= match.length) {
            const band_end = if (slot == 28) 258 else length_base[slot + 1] - 1;
            const end = @min(band_end, match.length);
            const suffix = costs[position + length .. position + end + 1];
            const take = if (end == length) length else length + minimumCostIndex(suffix);
            const candidate = distance_price + length_prices[length] + costs[position + take];
            if (candidate < cost.*) {
                cost.* = candidate;
                choice.* = .{ .length = @intCast(take), .value = match.distance };
            }
            length = end + 1;
            slot += 1;
        }
    }

    fn split(
        self: *Encoder,
        first: usize,
        end: usize,
        start: usize,
        bytes: usize,
        offset: u6,
        depth: usize,
        slot: usize,
    ) EncodeError!usize {
        const workspace = self.workspace;
        workspace.segments[slot] = .{ .first = first, .end = end, .start = start, .bytes = bytes };
        if (depth == 4 or bytes < 4096 or end - first < 2) return slot + 1;
        const whole = try self.select(workspace.best[first..end], bytes, offset);
        var middle = first;
        var left_bytes: usize = 0;
        while (middle + 1 < end and left_bytes < bytes / 2) : (middle += 1) {
            left_bytes += @max(1, workspace.best[middle].length);
        }
        if (middle == first or middle == end) return slot + 1;
        const left = try self.select(workspace.best[first..middle], left_bytes, offset);
        const right_offset: u6 = @intCast((offset + @as(u32, left.bits)) % 8);
        const right = try self.select(
            workspace.best[middle..end],
            bytes - left_bytes,
            right_offset,
        );
        if (left.bits + right.bits >= whole.bits) return slot + 1;
        const next = try self.split(first, middle, start, left_bytes, offset, depth + 1, slot);
        // Child splits may alter alignment; recompute their exact cost.
        var next_offset = offset;
        for (workspace.segments[slot..next]) |segment| {
            const choice = try self.select(
                workspace.best[segment.first..segment.end],
                segment.bytes,
                next_offset,
            );
            next_offset = @intCast((next_offset + @as(u32, choice.bits)) % 8);
        }
        return self.split(
            middle,
            end,
            start + left_bytes,
            bytes - left_bytes,
            next_offset,
            depth + 1,
            next,
        );
    }

    fn select(
        self: *Encoder,
        tokens: []const Token,
        bytes: usize,
        offset: u6,
    ) EncodeError!Selection {
        var literal_frequencies: [286]u32 = @splat(0);
        var distance_frequencies: [30]u32 = @splat(0);
        literal_frequencies[256] = 1;
        var extra_bits: u32 = 0;
        for (tokens) |token| {
            if (token.length == 0) {
                literal_frequencies[token.value] += 1;
            } else {
                const length_slot = lengthSlot(token.length);
                const distance_slot = distanceSlot(token.value);
                literal_frequencies[257 + @as(usize, length_slot)] += 1;
                distance_frequencies[distance_slot] += 1;
                extra_bits += @as(u32, length_extra[length_slot]) + distance_extra[distance_slot];
            }
        }
        const header = &self.workspace.header;
        try self.makeBook(&literal_frequencies, 15, &header.literal);
        try self.makeBook(&distance_frequencies, 15, &header.distance);
        try self.makeHeader();
        var dynamic_bits: u32 = 3 + header.bits + extra_bits;
        var fixed_bits: u32 = 3 + extra_bits;
        for (literal_frequencies, 0..) |frequency, symbol| {
            dynamic_bits += frequency * header.literal.widths[symbol];
            fixed_bits += frequency * fixedWidth(symbol);
        }
        for (distance_frequencies, 0..) |frequency, symbol| {
            dynamic_bits += frequency * header.distance.widths[symbol];
            fixed_bits += frequency * 5;
        }
        const padding = (8 - (@as(u32, offset) + 3) % 8) % 8;
        const stored_bits: u32 = @intCast(3 + padding + 32 + bytes * 8);
        var best: Selection = .{ .bits = stored_bits, .kind = .stored };
        if (fixed_bits < best.bits) best = .{ .bits = fixed_bits, .kind = .fixed };
        if (dynamic_bits < best.bits) best = .{ .bits = dynamic_bits, .kind = .dynamic };
        best.dynamic_bits = dynamic_bits;
        try self.work(tokens.len + 1);
        return best;
    }

    // Package-merge, Larmore and Hirschberg, JACM 37 (1990), pp. 464-473.
    // https://web.cs.unlv.edu/larmore/Research/larHir90.pdf
    fn makeBook(
        self: *Encoder,
        frequencies: []const u32,
        maximum: u8,
        book: *Book,
    ) EncodeError!void {
        const scratch = &self.workspace.huffman;
        @memset(&book.widths, 0);
        var count: usize = 0;
        for (frequencies, 0..) |frequency, symbol| {
            if (frequency == 0) continue;
            scratch.nodes[count] = .{
                .weight = frequency,
                .left = 0,
                .right = 0,
                .symbol = @intCast(symbol),
            };
            scratch.leaves[count] = @intCast(count);
            count += 1;
        }
        if (count <= 1) {
            book.widths[if (count == 0) 0 else scratch.nodes[0].symbol] = 1;
            canonical(book);
            return;
        }
        const Context = struct {
            nodes: []const Package,

            fn lessThan(context: @This(), left_index: u16, right_index: u16) bool {
                const left = context.nodes[left_index];
                const right = context.nodes[right_index];
                if (left.weight != right.weight) return left.weight < right.weight;
                return left.symbol < right.symbol;
            }
        };
        std.mem.sort(
            u16,
            scratch.leaves[0..count],
            Context{ .nodes = &scratch.nodes },
            Context.lessThan,
        );
        if (ordinaryBook(scratch, count, maximum, book)) {
            // Preserve package-merge's existing logical work charge, including its exact refusal
            // boundary. The ordinary-tree attempt is bounded by the fixed alphabet size.
            var logical_nodes = count;
            var logical_list_count = count;
            for (1..maximum) |_| {
                const packages = logical_list_count / 2;
                logical_nodes += packages;
                logical_list_count = @min(count * 2 - 2, count + packages);
            }
            try self.work(logical_nodes + @as(usize, maximum) * count);
            canonical(book);
            return;
        }
        @memcpy(scratch.lists[0][0..count], scratch.leaves[0..count]);
        var list_count = count;
        var nodes = count;
        var previous: usize = 0;
        for (1..maximum) |_| {
            const packages = list_count / 2;
            for (0..packages) |i| {
                const left = scratch.lists[previous][2 * i];
                const right = scratch.lists[previous][2 * i + 1];
                scratch.nodes[nodes] = .{
                    .weight = scratch.nodes[left].weight + scratch.nodes[right].weight,
                    .left = left,
                    .right = right,
                    .symbol = no_symbol,
                };
                scratch.packages[i] = @intCast(nodes);
                nodes += 1;
            }
            const current = 1 - previous;
            var leaf: usize = 0;
            var package: usize = 0;
            list_count = @min(count * 2 - 2, count + packages);
            for (0..list_count) |i| {
                // Leaves precede equal-weight packages; package creation order and symbol order
                // make all construction ties deterministic.
                const take_leaf = blk: {
                    if (leaf == count) break :blk false;
                    if (package == packages) break :blk true;
                    const leaf_weight = scratch.nodes[scratch.leaves[leaf]].weight;
                    const package_weight = scratch.nodes[scratch.packages[package]].weight;
                    break :blk leaf_weight <= package_weight;
                };
                if (take_leaf) {
                    scratch.lists[current][i] = scratch.leaves[leaf];
                    leaf += 1;
                } else {
                    scratch.lists[current][i] = scratch.packages[package];
                    package += 1;
                }
            }
            previous = current;
        }
        for (scratch.lists[previous][0 .. count * 2 - 2]) |node| {
            addLengths(scratch, node, &book.widths);
        }
        try self.work(nodes + @as(usize, maximum) * count);
        canonical(book);
    }

    fn makeHeader(self: *Encoder) EncodeError!void {
        const workspace = self.workspace;
        const header = &workspace.header;
        header.literal_count = 286;
        while (header.literal_count > 257) {
            if (header.literal.widths[header.literal_count - 1] != 0) break;
            header.literal_count -= 1;
        }
        header.distance_count = 30;
        while (header.distance_count > 1) {
            if (header.distance.widths[header.distance_count - 1] != 0) break;
            header.distance_count -= 1;
        }
        var widths: [316]u8 = undefined;
        @memcpy(widths[0..header.literal_count], header.literal.widths[0..header.literal_count]);
        @memcpy(
            widths[header.literal_count..][0..header.distance_count],
            header.distance.widths[0..header.distance_count],
        );
        const size = header.literal_count + header.distance_count;
        var prices: [19]u16 = @splat(4);
        var best_bits: u32 = std.math.maxInt(u32);
        var previous_run_count: usize = 0;
        var previous_work: u64 = 0;
        // Reprice code-length runs with each trial precode, keeping the cheapest serialized header.
        for (0..4) |pass| {
            const work_before = self.stats.work_units;
            var choices: [316]RunChoice = undefined;
            _ = priceRuns(widths[0..size], &prices, choices[0..size]);
            const trial = &workspace.header_trial;
            var frequencies: [19]u32 = @splat(0);
            var position: usize = 0;
            var unchanged = pass != 0;
            trial.run_count = 0;
            while (position < size) {
                const choice = choices[position];
                const extra: u8 = switch (choice.symbol) {
                    16, 17 => choice.take - 3,
                    18 => choice.take - 11,
                    else => 0,
                };
                const run: Run = .{ .symbol = choice.symbol, .extra = extra };
                if (unchanged and trial.run_count < previous_run_count) {
                    const previous = trial.runs[trial.run_count];
                    unchanged = run.symbol == previous.symbol and run.extra == previous.extra;
                } else unchanged = false;
                trial.runs[trial.run_count] = run;
                frequencies[choice.symbol] += 1;
                trial.run_count += 1;
                position += choice.take;
            }
            // Identical runs produce the same precode and future prices. Reuse the remaining trials
            // only when their exact logical charges fit; otherwise execute them to preserve partial
            // failure counts. Each trial's work is bounded by 316 widths.
            if (unchanged and trial.run_count == previous_run_count) {
                const remaining: u64 = @intCast(4 - pass);
                const units = previous_work * remaining;
                if (units <= self.options.limits.work_units -| self.stats.work_units) {
                    try self.work(units);
                    return;
                }
            }
            try self.makeBook(&frequencies, 7, &trial.precode);
            trial.precode_count = 19;
            while (trial.precode_count > 4) {
                const symbol = precode_order[trial.precode_count - 1];
                if (trial.precode.widths[symbol] != 0) break;
                trial.precode_count -= 1;
            }
            trial.bits = @intCast(14 + trial.precode_count * 3);
            for (trial.runs[0..trial.run_count]) |run| {
                trial.bits += @as(u32, trial.precode.widths[run.symbol]) + runExtra(run.symbol);
            }
            if (trial.bits < best_bits) {
                best_bits = trial.bits;
                header.bits = trial.bits;
                header.precode = trial.precode;
                header.precode_count = trial.precode_count;
                header.run_count = trial.run_count;
                @memcpy(header.runs[0..header.run_count], trial.runs[0..header.run_count]);
            }
            for (&prices, trial.precode.widths[0..19]) |*price, width| {
                price.* = if (width == 0) 7 else width;
            }
            // Charge the same logical edge bound even when range minima avoid visiting each edge.
            try self.work(size * 138);
            previous_run_count = trial.run_count;
            previous_work = self.stats.work_units - work_before;
        }
    }

    fn emit(
        self: *Encoder,
        tokens: []const Token,
        segment: Segment,
        kind: Kind,
        final: bool,
    ) EncodeError!void {
        const header = &self.workspace.header;
        if (kind == .stored) {
            const start = self.history + segment.start;
            const bytes = self.workspace.data[start..][0..segment.bytes];
            return self.stored(bytes, final);
        }
        self.put(@intFromBool(final), 1);
        self.put(if (kind == .fixed) 1 else 2, 2);
        if (kind == .fixed) {
            fixedBook(&header.literal, false);
            fixedBook(&header.distance, true);
            self.stats.fixed_blocks = try addCount(self.stats.fixed_blocks, 1);
        } else {
            self.put(header.literal_count - 257, 5);
            self.put(header.distance_count - 1, 5);
            self.put(header.precode_count - 4, 4);
            for (
                precode_order[0..header.precode_count],
            ) |symbol| self.put(header.precode.widths[symbol], 3);
            for (header.runs[0..header.run_count]) |run| {
                self.putSymbol(&header.precode, run.symbol);
                self.put(run.extra, runExtra(run.symbol));
            }
            self.stats.dynamic_blocks = try addCount(self.stats.dynamic_blocks, 1);
        }
        for (tokens) |token| {
            if (token.length == 0) {
                self.putSymbol(&header.literal, token.value);
            } else {
                const length = lengthSlot(token.length);
                const distance = distanceSlot(token.value);
                self.putSymbol(&header.literal, 257 + @as(usize, length));
                self.put(token.length - length_base[length], @intCast(length_extra[length]));
                self.putSymbol(&header.distance, distance);
                self.put(token.value - distance_base[distance], @intCast(distance_extra[distance]));
            }
        }
        self.putSymbol(&header.literal, 256);
        self.stats.blocks = try addCount(self.stats.blocks, 1);
    }

    fn stored(self: *Encoder, bytes: []const u8, final: bool) EncodeError!void {
        self.put(@intFromBool(final), 1);
        self.put(0, 2);
        self.alignBits();
        writeStoredBody(bytes, self.workspace.wire[self.pending..][0 .. bytes.len + 4]);
        self.pending += bytes.len + 4;
        self.stats.blocks = try addCount(self.stats.blocks, 1);
        self.stats.stored_blocks = try addCount(self.stats.stored_blocks, 1);
    }

    fn putSymbol(self: *Encoder, book: *const Book, value: usize) void {
        self.put(book.codes[value], @intCast(book.widths[value]));
    }

    fn put(self: *Encoder, value: usize, width: u6) void {
        self.bits |= @as(u64, @intCast(value)) << self.bit_count;
        self.bit_count += width;
        while (self.bit_count >= 8) {
            self.workspace.wire[self.pending] = @truncate(self.bits);
            self.pending += 1;
            self.bits >>= 8;
            self.bit_count -= 8;
        }
    }

    fn alignBits(self: *Encoder) void {
        if (self.bit_count != 0) self.put(0, 8 - self.bit_count);
    }
};

// RFC 1951 stored bodies are byte-aligned LEN/NLEN pairs followed by uncompressed bytes.
fn writeStoredBody(source: []const u8, output: []u8) void {
    const length: u16 = @intCast(source.len);
    std.mem.writeInt(u16, output[0..2], length, .little);
    std.mem.writeInt(u16, output[2..4], length ^ 65535, .little);
    @memcpy(output[4..], source);
}

// A missing prior pass never stops. Equal or worse dynamic cost stops without overflow.
fn adaptiveStop(previous: ?u32, current: u32) bool {
    return if (previous) |best| current >= best else false;
}

fn earlyStop(pass: usize, previous: ?u32, current: u32) bool {
    if (pass != 1) return false;
    const prior = previous orelse return false;
    return current >= prior - prior / 100;
}

test "early refinement stops at the second-pass percentage boundary" {
    try std.testing.expect(!earlyStop(1, null, 0));
    try std.testing.expect(!earlyStop(0, 1000, 1000));
    try std.testing.expect(!earlyStop(2, 1000, 1000));
    try std.testing.expect(earlyStop(1, 1000, 990));
    try std.testing.expect(!earlyStop(1, 1000, 989));
    try std.testing.expect(earlyStop(1, 99, 99));
    try std.testing.expect(!earlyStop(1, 99, 98));
    try std.testing.expect(earlyStop(1, std.math.maxInt(u32), std.math.maxInt(u32)));
}

test "adaptive dynamic price stop preserves triggering pass order" {
    try std.testing.expect(!adaptiveStop(null, std.math.maxInt(u32)));
    try std.testing.expect(adaptiveStop(100, 100));
    try std.testing.expect(adaptiveStop(100, 101));
    try std.testing.expect(!adaptiveStop(100, 99));
    try std.testing.expect(adaptiveStop(std.math.maxInt(u32), std.math.maxInt(u32)));
    // A triggering candidate is considered before stopping, while a later improvement is not.
    const prices = [_]u32{ 100, 100, 80 };
    const selected = [_]u32{ 110, 90, 70 };
    var previous: ?u32 = null;
    var best: u32 = 120;
    var executed: usize = 0;
    for (prices, selected) |price, bits| {
        best = @min(best, bits);
        executed += 1;
        if (adaptiveStop(previous, price)) break;
        previous = price;
    }
    try std.testing.expectEqual(2, executed);
    try std.testing.expectEqual(90, best);
}

// Any reusable price run must contain more than twice its match length in consecutive rows with the
// same single match. Ignoring literal prices may admit extra rows, but cannot miss a real run.
fn mayReusePricing(matches: []const Matches) bool {
    var run: usize = 0;
    var previous_length: u16 = 0;
    var previous_distance: u16 = 0;
    for (matches) |*row| {
        if (row.count != 1 or row.items[0].length < 35) {
            run = 0;
            continue;
        }
        const match = row.items[0];
        if (run != 0 and match.length == previous_length and match.distance == previous_distance) {
            run += 1;
        } else {
            run = 1;
            previous_length = match.length;
            previous_distance = match.distance;
        }
        if (run > 2 * @as(usize, match.length)) return true;
    }
    return false;
}

// When a run has identical match choices and literal prices, equality of the complete future-cost
// state up to a constant proves that earlier choices repeat. Copy completed rows while retaining
// their logical work charges and the actual literal byte at each source position.
const PriceRun = struct {
    first: usize,
    anchor: usize = 0,
    maximum: usize = 0,
    attempts: u8 = 0,

    fn find(encoder: *const Encoder, position: usize, prices: *const [286]u32) PriceRun {
        const workspace = encoder.workspace;
        const matches = &workspace.matches[position];
        if (matches.count != 1 or matches.items[0].length < 35) return .{ .first = position };
        const maximum = matches.items[0].length;
        const distance = matches.items[0].distance;
        const price = prices[workspace.data[encoder.history + position]];
        var first = position;
        while (first != 0) {
            const prior = &workspace.matches[first - 1];
            if (prior.count != 1 or prior.items[0].length != maximum or prior.items[0].distance !=
                distance or prices[workspace.data[encoder.history + first - 1]] != price) break;
            first -= 1;
        }
        return .{
            .first = first,
            .anchor = position,
            .maximum = if (position - first + 1 > 2 * maximum) maximum else 0,
        };
    }

    fn reuse(self: *PriceRun, encoder: *Encoder, position: usize) EncodeError!usize {
        const maximum = self.maximum;
        if (maximum == 0 or position == self.anchor) return position;
        const period = self.anchor - position;
        std.debug.assert(period <= maximum);
        const workspace = encoder.workspace;
        const costs = &workspace.costs;
        var same = costs[position] > costs[self.anchor];
        const delta = costs[position] -| costs[self.anchor];
        if (same) {
            for (0..maximum) |offset| {
                if (costs[position + offset] != costs[self.anchor + offset] + delta) {
                    same = false;
                    break;
                }
            }
        }
        if (!same) {
            // Bound discovery even when constant transitions never acquire a short cycle.
            if (period == maximum) {
                self.attempts += 1;
                if (self.attempts == 5 or position - self.first <= maximum) {
                    self.maximum = 0;
                } else self.anchor = position;
            }
            return position;
        }
        self.maximum = 0;
        const per_row: u64 = @intCast(maximum - 2);
        const capacity = @min(
            (encoder.options.limits.work_units - encoder.stats.work_units) / per_row,
            (std.math.maxInt(u64) - encoder.stats.parse_edges) / per_row,
        );
        const rows: usize = @intCast(@min(@as(u64, @intCast(position - self.first)), capacity));
        if (rows == 0) return position;
        // Admit only complete rows. The ordinary path preserves the next refusal and its counter
        // publication order when either work or edge accounting reaches its limit.
        const units = @as(u64, @intCast(rows)) * per_row;
        try encoder.work(units);
        encoder.stats.parse_edges = try addCount(encoder.stats.parse_edges, units);
        const first = position - rows;
        var next = position;
        while (next != first) {
            next -= 1;
            costs[next] = costs[next + period] + delta;
            const choice = workspace.choices[next + period];
            workspace.choices[next] = if (choice.length == 0) .{
                .length = 0,
                .value = workspace.data[encoder.history + next],
            } else choice;
        }
        return first;
    }
};

// Exact first minimum in one length-price band (at most 32 suffixes). Vector loads stay inside the
// initialized cost range; equal minima retain the shorter match on every target.
fn minimumCostIndex(costs: []const u32) usize {
    var best: usize = 0;
    var position: usize = 0;
    while (position + 8 <= costs.len) : (position += 8) {
        const values: @Vector(8, u32) = costs[position..][0..8].*;
        const minimum = @reduce(.Min, values);
        if (minimum < costs[best]) {
            best = position + std.simd.firstIndexOfValue(values, minimum).?;
        }
    }
    while (position < costs.len) : (position += 1) {
        if (costs[position] < costs[best]) best = position;
    }
    return best;
}

// Minimum suffix cost for a range whose endpoints move backward one position at a time. Entries
// descend by position and increase by cost. Equal costs keep the newer, shorter repeat.
const RunMinimum = struct {
    positions: [128]u16 = undefined,
    first: usize = 0,
    count: usize = 0,

    fn add(self: *RunMinimum, costs: []const u32, first: usize, last: usize) usize {
        while (self.count != 0 and self.positions[self.first] > last) {
            self.first = (self.first + 1) % self.positions.len;
            self.count -= 1;
        }
        while (self.count != 0) {
            const tail = (self.first + self.count - 1) % self.positions.len;
            if (costs[self.positions[tail]] < costs[first]) break;
            self.count -= 1;
        }
        std.debug.assert(self.count < self.positions.len);
        self.positions[(self.first + self.count) % self.positions.len] = @intCast(first);
        self.count += 1;
        return self.positions[self.first];
    }
};

fn priceRuns(widths: []const u8, prices: *const [19]u16, choices: []RunChoice) u32 {
    var costs: [317]u32 = undefined;
    costs[widths.len] = 0;
    var zeros: RunMinimum = .{};
    var same: usize = 0;
    var position = widths.len;
    while (position != 0) {
        position -= 1;
        const value = widths[position];
        if (same != 0 and widths[position + 1] == value) {
            same = @min(same + 1, 138);
        } else {
            same = 1;
            zeros = .{};
        }
        var cost: u32 = prices[value] + costs[position + 1];
        var choice: RunChoice = .{ .symbol = value, .take = 1 };
        const repeats_previous = position != 0 and widths[position - 1] == value;
        inline for (.{ @as(u8, 16), 17 }) |symbol| {
            const allowed = if (symbol == 16) repeats_previous else value == 0;
            if (allowed) {
                const maximum = @min(same, if (symbol == 16) @as(usize, 6) else 10);
                const repeat_bits = prices[symbol] + @as(u32, runExtra(symbol));
                var take: usize = 3;
                while (take <= maximum) : (take += 1) {
                    const candidate = repeat_bits + costs[position + take];
                    if (candidate < cost) {
                        cost = candidate;
                        choice = .{ .symbol = symbol, .take = @intCast(take) };
                    }
                }
            }
        }
        if (value == 0 and same >= 11) {
            // Every repeat of 11..138 zeros has the same symbol/extra price. Query the exact
            // cheapest suffix instead of scanning all 128 edges at each position.
            const end = zeros.add(&costs, position + 11, position + same);
            const candidate = prices[18] + @as(u32, runExtra(18)) + costs[end];
            if (candidate < cost) {
                cost = candidate;
                choice = .{ .symbol = 18, .take = @intCast(end - position) };
            }
        }
        costs[position] = cost;
        choices[position] = choice;
    }
    return costs[0];
}

// Try the ordinary minimum-cost tree, with the same leaf-before-package tie order as the bounded
// construction. If its lengths exceed the bound, the caller runs package-merge.
fn ordinaryBook(scratch: *HuffmanScratch, count: usize, maximum: u8, book: *Book) bool {
    const Queue = struct {
        fn take(
            state: *HuffmanScratch,
            leaf_count: usize,
            leaf: *usize,
            head: *usize,
            tail: usize,
        ) u16 {
            if (leaf.* < leaf_count and (head.* == tail or state.nodes[state.leaves[leaf.*]]
                .weight <= state.nodes[state.packages[head.*]].weight))
            {
                const value = state.leaves[leaf.*];
                leaf.* += 1;
                return value;
            }
            const value = state.packages[head.*];
            head.* += 1;
            return value;
        }
    };
    var leaf: usize = 0;
    var head: usize = 0;
    var tail: usize = 0;
    var nodes = count;
    while (count - leaf + tail - head > 1) {
        const left = Queue.take(scratch, count, &leaf, &head, tail);
        const right = Queue.take(scratch, count, &leaf, &head, tail);
        scratch.nodes[nodes] = .{
            .weight = scratch.nodes[left].weight + scratch.nodes[right].weight,
            .left = left,
            .right = right,
            .symbol = no_symbol,
        };
        scratch.packages[tail] = @intCast(nodes);
        nodes += 1;
        tail += 1;
    }
    // Parent indices follow child indices, so one backward pass computes every depth without
    // recursion or an additional stack. Do not publish widths until the bound is known to fit.
    @memset(scratch.lists[0][0..nodes], 0);
    var index = nodes;
    while (index > count) {
        index -= 1;
        const depth = scratch.lists[0][index] + 1;
        if (depth > maximum) return false;
        const node = scratch.nodes[index];
        scratch.lists[0][node.left] = depth;
        scratch.lists[0][node.right] = depth;
    }
    for (scratch.nodes[0..count], 0..) |node, i| {
        book.widths[node.symbol] = @intCast(scratch.lists[0][i]);
    }
    return true;
}

fn addLengths(scratch: *const HuffmanScratch, node: u16, widths: *[286]u8) void {
    const item = scratch.nodes[node];
    if (item.symbol != no_symbol) {
        widths[item.symbol] += 1;
    } else {
        addLengths(scratch, item.left, widths);
        addLengths(scratch, item.right, widths);
    }
}

fn canonical(book: *Book) void {
    var counts: [16]u16 = @splat(0);
    for (book.widths) |width| counts[width] += 1;
    counts[0] = 0;
    var next: [16]u16 = @splat(0);
    var code: u16 = 0;
    for (1..16) |width| {
        code = (code + counts[width - 1]) << 1;
        next[width] = code;
    }
    for (&book.codes, book.widths) |*result, width| {
        if (width == 0) {
            result.* = 0;
            continue;
        }
        result.* = @bitReverse(next[width]) >> @as(u4, @intCast(16 - width));
        next[width] += 1;
    }
}

fn fixedWidth(symbol: usize) u8 {
    if (symbol < 144) return 8;
    if (symbol < 256) return 9;
    return if (symbol < 280) 7 else 8;
}

fn fixedBook(book: *Book, distance: bool) void {
    // The reserved fixed symbols 286/287 are absent from Book. Their canonical codes still affect
    // lower symbols only through the known RFC formulas.
    for (&book.widths, &book.codes, 0..) |*width, *code, symbol| {
        if (distance) {
            width.* = 5;
            code.* = @bitReverse(@as(u16, @intCast(symbol))) >> 11;
        } else {
            width.* = fixedWidth(symbol);
            const canonical_code = blk: {
                if (symbol < 144) break :blk 48 + symbol;
                if (symbol < 256) break :blk 400 + symbol - 144;
                if (symbol < 280) break :blk symbol - 256;
                break :blk 192 + symbol - 280;
            };
            const value: u16 = @intCast(canonical_code);
            code.* = @bitReverse(value) >> @as(u4, @intCast(16 - width.*));
        }
    }
}

fn hash3(bytes: *const [3]u8) u16 {
    const value = @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
    return @truncate((value *% 0x1e35a7bd) >> 16);
}

fn lengthSlot(length: usize) u8 {
    if (length == 258) return 28;
    if (length <= 10) return @intCast(length - 3);
    const order: u8 = @intCast(std.math.log2_int(usize, length - 3) - 2);
    const shift: std.math.Log2Int(usize) = @intCast(order);
    return @intCast(@as(usize, order) * 4 + ((length - 3) >> shift));
}

fn distanceSlot(distance: usize) u8 {
    if (distance <= 4) return @intCast(distance - 1);
    const order: u8 = @intCast(std.math.log2_int(usize, distance - 1) - 1);
    const shift: std.math.Log2Int(usize) = @intCast(order);
    return @intCast(@as(usize, order) * 2 + ((distance - 1) >> shift));
}

fn runExtra(symbol: u8) u6 {
    return switch (symbol) {
        16 => 2,
        17 => 3,
        18 => 7,
        else => 0,
    };
}

fn addCount(a: u64, b: u64) EncodeError!u64 {
    return std.math.add(u64, a, b) catch error.CounterOverflow;
}

fn disjoint(a: []const u8, b: []const u8) EncodeError!void {
    if (a.len == 0 or b.len == 0) return;
    const x = @intFromPtr(a.ptr);
    const y = @intFromPtr(b.ptr);
    const overlap = if (x <= y) y - x < a.len else x - y < b.len;
    if (overlap) return error.StorageOverlap;
}

test "compression levels select distinct bounded search effort" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    const position = 20000;
    const total = position + 258;
    for (0..position / 4) |i| workspace.data[i * 4 ..][0..4].* = "AAAx".*;
    @memset(workspace.data[position..total], 'q');
    workspace.data[position..][0..4].* = "AAAz".*;
    @memset(&workspace.chain().heads, no_position);
    for (0..position) |i| {
        const hash = hash3(workspace.data[i..][0..3]);
        workspace.chain().previous[i] = workspace.chain().heads[hash];
        workspace.chain().heads[hash] = @intCast(i);
    }
    const candidate = workspace.chain().heads[hash3(workspace.data[position..][0..3])];
    const depths = [_]u16{ 4, 8, 32, 64, 128, 256, 35, 100, 300 };
    for (depths[0..6], 1..) |depth, level| {
        try encoder.reset(workspace, .{ .compression = .{ .level = @intCast(level) } });
        encoder.buffered = total;
        workspace.matches[position].count = 0;
        // Thousands of equal three-byte prefixes force each selected level to visit its own maximum
        // candidate count; no earlier candidate can match the differing fourth byte.
        var partial: SearchStats = undefined;
        const measured = try encoder.scanMatches(
            false,
            position,
            total,
            candidate,
            encoder.options.depth,
            std.math.maxInt(u64),
            &partial,
        );
        try std.testing.expectEqual(measured, partial);
        try std.testing.expectEqual(depth, encoder.options.depth);
        try std.testing.expectEqual(depth, measured.probes);
    }

    for (depths[6..], 7..) |depth, level| {
        try encoder.reset(workspace, .{ .compression = .{ .level = @intCast(level) } });
        try std.testing.expectEqual(Profile.offline, encoder.options.profile);
        try std.testing.expectEqual(depth, encoder.options.depth);
    }

    // Invalid levels must refuse reset before replacing an existing owner or workspace. Level zero
    // remains store-only even when a literal-only strategy was also selected.
    try encoder.reset(workspace, .{ .compression = .{ .level = 0, .strategy = .huffman_only } });
    try std.testing.expectEqual(Profile.stored, encoder.options.profile);
    encoder.stats.input_bytes = 42;
    workspace.data[0] = 0xa5;
    for (
        [_]Compression{
            .{ .level = 10 },
            .{ .level = 255 },
            .{ .level = 3, .lazy_lookahead = .reduced },
            .{ .level = 6, .strategy = .huffman_only, .lazy_lookahead = .reduced },
            .{ .level = 6, .offline_refinement = .early },
            .{ .level = 9, .strategy = .huffman_only, .offline_refinement = .early },
        },
    ) |invalid| {
        try std.testing.expectError(
            error.InvalidOptions,
            encoder.reset(workspace, .{ .compression = invalid }),
        );
        try std.testing.expectEqual(42, encoder.stats.input_bytes);
        try std.testing.expectEqual(0xa5, workspace.data[0]);
    }
    try encoder.reset(workspace, .{ .compression = .{ .strategy = .huffman_only } });
    try std.testing.expectEqual(Profile.huffman, encoder.options.profile);
}

test "chain refusal reports admitted probes and requires reset" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var output: [128]u8 = undefined;
    for ([_]u8{ 3, 6 }) |level| {
        try encoder.reset(
            workspace,
            .{ .compression = .{ .level = level }, .limits = .{ .work_units = 1 } },
        );
        try std.testing.expectError(
            error.LimitExceeded,
            encoder.step("aaaaaaaaaaaa", &output, .finish),
        );
        try std.testing.expectEqual(1, encoder.counts().work_units);
        try std.testing.expectEqual(1, encoder.counts().match_probes);
        try std.testing.expectError(error.NeedReset, encoder.step("", &output, .finish));
        try encoder.reset(workspace, .{ .compression = .{ .level = level } });
        const progress = try encoder.step("aaaaaaaaaaaa", &output, .finish);
        try std.testing.expectEqual(.complete, progress.status);
    }
}

test "work limits retain exact boundaries with and without history" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var output: [512]u8 = undefined;
    const source = "aaaaaaaaaaaa";
    for (
        [_]Compression{
            .{ .level = 3 },
            .{ .level = 4, .lazy_lookahead = .reduced },
            .{ .level = 5, .lazy_lookahead = .reduced },
            .{ .level = 6, .lazy_lookahead = .reduced },
            .{ .level = 6 },
            .{ .level = 9 },
            .{ .level = 9, .offline_refinement = .early },
        },
    ) |compression| {
        for ([_]?[]const u8{ null, "aaaaaaaaaaaa" }) |dictionary| {
            var options: EncodeOptions = .{ .compression = compression, .dictionary = dictionary };
            try encoder.reset(workspace, options);
            const complete = try encoder.step(source, &output, .finish);
            try std.testing.expectEqual(.complete, complete.status);
            const full = encoder.counts();
            try std.testing.expect(full.work_units > 1);
            for ([_]u64{ 0, 1, full.work_units - 1, full.work_units }) |budget| {
                options.limits.work_units = budget;
                try encoder.reset(workspace, options);
                const result = encoder.step(source, &output, .finish);
                if (budget == full.work_units) {
                    const progress = try result;
                    try std.testing.expectEqual(.complete, progress.status);
                    try std.testing.expectEqual(full, encoder.counts());
                } else {
                    try std.testing.expectError(error.LimitExceeded, result);
                    try std.testing.expect(encoder.counts().work_units <= budget);
                    try std.testing.expectError(
                        error.NeedReset,
                        encoder.step("", &output, .finish),
                    );
                }
            }
        }
    }
}

test "offline refusal reports admitted probes and requires reset" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var output: [128]u8 = undefined;
    try encoder.reset(
        workspace,
        .{ .compression = .{ .level = 9 }, .limits = .{ .work_units = 1 } },
    );
    try std.testing.expectError(error.LimitExceeded, encoder.step("aaaaa", &output, .finish));
    try std.testing.expectEqual(1, encoder.counts().work_units);
    try std.testing.expectEqual(1, encoder.counts().match_probes);
    try std.testing.expectError(error.NeedReset, encoder.step("", &output, .finish));
    try encoder.reset(workspace, .{ .compression = .{ .level = 9 } });
    const progress = try encoder.step("aaaaa", &output, .finish);
    try std.testing.expectEqual(.complete, progress.status);
}

test "search storage switches profiles after refusal and clears completely" {
    const allocator = std.testing.allocator;
    const reused = try EncoderWorkspace.create(allocator);
    defer reused.destroy(allocator);
    const fresh = try EncoderWorkspace.create(allocator);
    defer fresh.destroy(allocator);
    var source: [1024]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = "phase-switch-pattern"[i % 20];
    var expected: [2048]u8 = undefined;
    var actual: [2048]u8 = undefined;
    var encoder: Encoder = undefined;
    try encoder.reset(reused, .{ .compression = .{ .level = 9 }, .limits = .{ .work_units = 1 } });
    try std.testing.expectError(error.LimitExceeded, encoder.step("aaaaa", &actual, .finish));
    try std.testing.expectError(error.NeedReset, encoder.step("", &actual, .finish));
    for ([_]usize{ 3, 17, 255, 256, 257, 1024 }) |size| {
        for ([_]u8{ 9, 3, 6, 9 }) |level| {
            const options: EncodeOptions = .{ .compression = .{ .level = level } };
            const reference = try encode(source[0..size], &expected, fresh, options);
            const observed = try encode(source[0..size], &actual, reused, options);
            try std.testing.expectEqualSlices(u8, reference, observed);
        }
    }
    reused.clear();
    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(reused), 0));
}

test "default and stored compression selections retain their exact contracts" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    const source = "a small repeated payload, a small repeated payload";
    var default_wire: [512]u8 = undefined;
    var explicit_wire: [512]u8 = undefined;
    var encoder: Encoder = undefined;

    // The common default must be the documented level, including its copied work counters.
    try encoder.reset(workspace, .{});
    const first = try encoder.step(source, &default_wire, .finish);
    const counts = encoder.counts();
    try encoder.reset(workspace, .{ .compression = .{ .level = 6 } });
    const second = try encoder.step(source, &explicit_wire, .finish);
    try std.testing.expectEqual(EncodeStatus.complete, first.status);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualDeep(counts, encoder.counts());
    try std.testing.expectEqualSlices(
        u8,
        default_wire[0..first.produced],
        explicit_wire[0..second.produced],
    );

    for ([_]u8{ 4, 5, 6 }) |level| {
        try encoder.reset(workspace, .{ .compression = .{ .level = level } });
        const implicit = try encoder.step(source, &default_wire, .finish);
        const implicit_counts = encoder.counts();
        try encoder.reset(
            workspace,
            .{ .compression = .{ .level = level, .lazy_lookahead = .full } },
        );
        const explicit = try encoder.step(source, &explicit_wire, .finish);
        try std.testing.expectEqual(implicit, explicit);
        try std.testing.expectEqualDeep(implicit_counts, encoder.counts());
        try std.testing.expectEqualSlices(
            u8,
            default_wire[0..implicit.produced],
            explicit_wire[0..explicit.produced],
        );
    }

    // Level zero takes precedence over the optional strategy and still emits the same stored wire.
    const stored = try encode(
        source,
        &default_wire,
        workspace,
        .{ .compression = .{ .level = 0 } },
    );
    const stored_with_strategy = try encode(
        source,
        &explicit_wire,
        workspace,
        .{ .compression = .{ .level = 0, .strategy = .huffman_only } },
    );
    try std.testing.expectEqualSlices(u8, stored, stored_with_strategy);
}

test "reduced lazy lookahead changes search work on a collision-heavy input" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var source: [8192]u8 = undefined;
    var state: u32 = 0x12a654cd;
    for (&source) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state & 3);
    }
    var output: [16384]u8 = undefined;
    var encoder: Encoder = undefined;
    for ([_]u8{ 4, 5, 6 }) |level| {
        try encoder.reset(workspace, .{ .compression = .{ .level = level } });
        try std.testing.expectEqual(
            EncodeStatus.complete,
            (try encoder.step(&source, &output, .finish)).status,
        );
        const full = encoder.counts();
        try encoder.reset(
            workspace,
            .{ .compression = .{ .level = level, .lazy_lookahead = .reduced } },
        );
        try std.testing.expectEqual(
            EncodeStatus.complete,
            (try encoder.step(&source, &output, .finish)).status,
        );
        try std.testing.expect(encoder.counts().match_probes < full.match_probes);
    }
}

test "reduced lazy lookahead preserves fragmented encoding and dictionary recovery" {
    const decoding = @import("decode.zig");
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const decoder = try decoding.DecoderWorkspace.create(allocator);
    defer decoder.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const dictionary = "a dictionary with recurring fragments and repeated fragments";
    var source: [4096]u8 = undefined;
    for (&source, 0..) |*byte, i| {
        byte.* = "recurring fragments with variations"[(i + i / 113) % 35];
    }
    var complete_wire: [8192]u8 = undefined;
    var fragmented_wire: [8192]u8 = undefined;
    var restored: [source.len]u8 = undefined;
    var encoder: Encoder = undefined;
    for ([_]u8{ 4, 5, 6 }) |level| {
        const options: EncodeOptions = .{
            .compression = .{ .level = level, .lazy_lookahead = .reduced },
            .dictionary = dictionary,
            .window_bytes = 256,
        };
        try encoder.reset(workspace, options);
        const complete = try encoder.step(&source, &complete_wire, .finish);
        try std.testing.expectEqual(EncodeStatus.complete, complete.status);
        const counts = encoder.counts();
        try encoder.reset(workspace, options);
        var read: usize = 0;
        var written: usize = 0;
        while (true) {
            const end = @min(source.len, read + 71);
            const action: EncodeAction = if (end == source.len) .finish else .process;
            const output_end = @min(fragmented_wire.len, written + 13);
            const progress = try encoder.step(
                source[read..end],
                fragmented_wire[written..output_end],
                action,
            );
            read += progress.consumed;
            written += progress.produced;
            if (progress.status == .complete) break;
            try std.testing.expect(progress.consumed != 0 or progress.produced != 0);
        }
        try std.testing.expectEqual(source.len, read);
        try std.testing.expectEqualSlices(
            u8,
            complete_wire[0..complete.produced],
            fragmented_wire[0..written],
        );
        try std.testing.expectEqualDeep(counts, encoder.counts());
        const result = try decoding.decode(
            fragmented_wire[0..written],
            &restored,
            .{ .workspace = decoder, .history = history },
            .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
        );
        try std.testing.expectEqual(source.len, result.produced);
        try std.testing.expectEqualSlices(u8, &source, &restored);
    }
}

test "encoder reset admits dictionary before replacing the owner" {
    const allocator = std.testing.allocator;
    const old_workspace = try EncoderWorkspace.create(allocator);
    defer old_workspace.destroy(allocator);
    const new_workspace = try EncoderWorkspace.create(allocator);
    defer new_workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(old_workspace, .{});
    _ = try encoder.step("ABCDEFGH", &.{}, .process);

    // A rejected dictionary may be a view of the previous owner's live counters. The source must
    // retain its bytes even though reset was asked to replace that owner.
    const owner_bytes = std.mem.asBytes(&encoder.stats.input_bytes);
    const before = owner_bytes[0..@sizeOf(u64)].*;
    try std.testing.expectError(
        error.StorageOverlap,
        encoder.reset(new_workspace, .{ .dictionary = owner_bytes }),
    );
    try std.testing.expectEqualSlices(u8, &before, owner_bytes);

    // The incoming workspace is still protected, but the retired workspace may supply a copied
    // dictionary because it does not overlap the new reservations.
    @memset(new_workspace.data[0..8], 0xa5);
    try std.testing.expectError(
        error.StorageOverlap,
        encoder.reset(new_workspace, .{ .dictionary = new_workspace.data[0..8] }),
    );
    try std.testing.expect(std.mem.allEqual(u8, new_workspace.data[0..8], 0xa5));
    @memcpy(old_workspace.data[0..8], "history!");
    try encoder.reset(new_workspace, .{ .dictionary = old_workspace.data[0..8] });
    try std.testing.expectEqualSlices(u8, "history!", new_workspace.data[0..encoder.history]);
}

test "stored finishes preserve independent RFC slab headers payloads and counters" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const source = try allocator.alloc(u8, 131071);
    defer allocator.free(source);
    for (source, 0..) |*byte, index| byte.* = @truncate(index * 37 + 11);
    const storage = try allocator.alloc(u8, source.len + 3 * 5 + 32);
    defer allocator.free(storage);
    // RFC 1951 section 3.2.4: BFINAL/BTYPE and little-endian LEN/complement. These boundary headers
    // are authored independently of the encoder and its capacity helper.
    const cases = [_]struct {
        bytes: usize,
        full_prefixes: usize,
        final_header: [5]u8,
    }{ .{ .bytes = 0, .full_prefixes = 0, .final_header = .{
        1, 0, 0, 255, 255,
    } }, .{ .bytes = 1, .full_prefixes = 0, .final_header = .{
        1, 1, 0, 254, 255,
    } }, .{ .bytes = 65534, .full_prefixes = 0, .final_header = .{
        1, 254, 255, 1, 0,
    } }, .{ .bytes = 65535, .full_prefixes = 0, .final_header = .{
        1, 255, 255, 0, 0,
    } }, .{ .bytes = 65536, .full_prefixes = 1, .final_header = .{
        1, 1, 0, 254, 255,
    } }, .{ .bytes = 131070, .full_prefixes = 1, .final_header = .{
        1, 255, 255, 0, 0,
    } }, .{ .bytes = 131071, .full_prefixes = 2, .final_header = .{
        1, 1, 0, 254, 255,
    } } };
    for (cases) |case| {
        const wire_bytes = case.bytes + (case.full_prefixes + 1) * 5;
        for ([_]usize{ 256, 32768 }) |window| {
            var encoder: Encoder = undefined;
            try encoder.reset(
                workspace,
                .{
                    .compression = .{ .level = 0 },
                    .window_bytes = window,
                    .dictionary = "copied preset history",
                    .limits = .{
                        .input_bytes = case.bytes,
                        .output_bytes = wire_bytes,
                        .work_units = 0,
                    },
                },
            );
            @memset(storage, 0xa7);
            const output = storage[1 .. wire_bytes + 9];
            const progress = try encoder.step(source[0..case.bytes], output, .finish);
            try std.testing.expectEqual(.complete, progress.status);
            try std.testing.expectEqual(case.bytes, progress.consumed);
            try std.testing.expectEqual(wire_bytes, progress.produced);
            var read: usize = 0;
            var written: usize = 0;
            for (0..case.full_prefixes) |_| {
                try std.testing.expectEqualSlices(u8, &.{
                    0, 255, 255, 0, 0,
                }, output[written..][0..5]);
                try std.testing.expectEqualSlices(
                    u8,
                    source[read..][0..65535],
                    output[written + 5 ..][0..65535],
                );
                read += 65535;
                written += 65540;
            }
            try std.testing.expectEqualSlices(u8, &case.final_header, output[written..][0..5]);
            try std.testing.expectEqualSlices(
                u8,
                source[read..case.bytes],
                output[written + 5 .. wire_bytes],
            );
            try std.testing.expectEqual(0xa7, storage[0]);
            try std.testing.expect(std.mem.allEqual(u8, storage[wire_bytes + 1 ..], 0xa7));
            try std.testing.expectEqual(
                EncodeStats{
                    .input_bytes = case.bytes,
                    .output_bytes = wire_bytes,
                    .blocks = case.full_prefixes + 1,
                    .stored_blocks = case.full_prefixes + 1,
                },
                encoder.counts(),
            );
            const repeated = try encoder.step(&.{}, &.{}, .finish);
            try std.testing.expectEqual(
                EncodeProgress{ .consumed = 0, .produced = 0, .status = .complete },
                repeated,
            );
        }
    }
    for (
        source,
        0..,
    ) |byte, index| try std.testing.expectEqual(@as(u8, @truncate(index * 37 + 11)), byte);
}

test "stored finishes retain buffered input retired spans and output suspensions" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const source = try allocator.alloc(u8, 65536);
    defer allocator.free(source);
    const output = try allocator.alloc(u8, 65547);
    defer allocator.free(output);
    const expected = try allocator.alloc(u8, 65546);
    defer allocator.free(expected);
    @memcpy(expected[0..5], &[_]u8{ 0, 255, 255, 0, 0 });
    @memset(expected[5..65540], 'c');
    @memcpy(expected[65540..], &[_]u8{ 1, 1, 0, 254, 255, 'c' });
    const expected_stats: EncodeStats = .{
        .input_bytes = 65536,
        .output_bytes = 65546,
        .blocks = 2,
        .stored_blocks = 2,
    };
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{ .compression = .{ .level = 0 } });
    @memset(source, 'c');
    const buffered = try encoder.step(source[0..13], &.{}, .process);
    try std.testing.expectEqual(
        EncodeProgress{ .consumed = 13, .produced = 0, .status = .need_input },
        buffered,
    );
    @memset(source[0..13], 'Z'); // Accepted bytes may retire before the finish.
    @memset(output, 0xa7);
    const complete = try encoder.step(source[13..], output[0..65546], .finish);
    try std.testing.expectEqual(.complete, complete.status);
    try std.testing.expectEqual(65523, complete.consumed);
    try std.testing.expectEqual(65546, complete.produced);
    try std.testing.expectEqualSlices(u8, expected, output[0..65546]);
    try std.testing.expectEqual(0xa7, output[65546]);
    try std.testing.expectEqual(expected_stats, encoder.counts());

    try encoder.reset(workspace, .{ .compression = .{ .level = 0 } });
    @memset(source, 'c');
    const suspended = try encoder.step(source, &.{}, .finish);
    try std.testing.expectEqual(
        EncodeProgress{ .consumed = 65535, .produced = 0, .status = .need_output },
        suspended,
    );
    @memset(source[0..suspended.consumed], 'Z');
    @memset(output, 0xa7);
    var read = suspended.consumed;
    var written: usize = 0;
    while (true) {
        const span = output[written..@min(written + 13, expected.len)];
        const progress = try encoder.step(source[read..], span, .finish);
        read += progress.consumed;
        written += progress.produced;
        if (progress.status == .complete) break;
        try std.testing.expectEqual(.need_output, progress.status);
        try std.testing.expect(progress.consumed + progress.produced != 0);
    }
    try std.testing.expectEqual(source.len, read);
    try std.testing.expectEqual(expected.len, written);
    try std.testing.expectEqualSlices(u8, expected, output[0..written]);
    try std.testing.expectEqual(0xa7, output[written]);
    try std.testing.expectEqual(expected_stats, encoder.counts());
}

test "stored finishes preserve flush accounting limit failures and overlap refusal" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    var output: [32]u8 = undefined;
    const expected = [_]u8{ 0, 1, 0, 254, 255, 'A', 0, 0, 0, 255, 255, 1, 1, 0, 254, 255, 'B' };
    for ([_]EncodeAction{ .flush, .full_flush }) |action| {
        try encoder.reset(
            workspace,
            .{
                .compression = .{ .level = 0 },
                .limits = .{ .input_bytes = 2, .output_bytes = expected.len, .work_units = 0 },
            },
        );
        const prefix = try encoder.step("A", &output, action);
        try std.testing.expectEqual(.flushed, prefix.status);
        const finish = try encoder.step("B", output[prefix.produced..], .finish);
        try std.testing.expectEqual(.complete, finish.status);
        try std.testing.expectEqualSlices(
            u8,
            &expected,
            output[0 .. prefix.produced + finish.produced],
        );
        try std.testing.expectEqual(
            EncodeStats{
                .input_bytes = 2,
                .output_bytes = expected.len,
                .blocks = 3,
                .stored_blocks = 3,
            },
            encoder.counts(),
        );
    }
    for ([_]EncodeLimits{ .{ .input_bytes = 0 }, .{ .output_bytes = 5 } }) |limits| {
        try encoder.reset(workspace, .{ .compression = .{ .level = 0 }, .limits = limits });
        try std.testing.expectError(error.LimitExceeded, encoder.step("A", &output, .finish));
        try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
    }
    try encoder.reset(workspace, .{ .compression = .{ .level = 0 } });
    output[0] = 'A';
    try std.testing.expectError(error.StorageOverlap, encoder.step(output[0..1], &output, .finish));
    try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
}

test "encoder slot formulas cover every RFC length and distance" {
    for (3..259) |length| {
        const slot = lengthSlot(length);
        const shift: std.math.Log2Int(usize) = @intCast(length_extra[slot]);
        const maximum = length_base[slot] + (@as(usize, 1) << shift) - 1;
        try std.testing.expect(length >= length_base[slot]);
        try std.testing.expect(length <= maximum);
        if (length == 258) try std.testing.expectEqual(28, slot);
    }
    for (1..32769) |distance| {
        const slot = distanceSlot(distance);
        const shift: std.math.Log2Int(usize) = @intCast(distance_extra[slot]);
        const maximum = distance_base[slot] + (@as(usize, 1) << shift) - 1;
        try std.testing.expect(distance >= distance_base[slot]);
        try std.testing.expect(distance <= maximum);
    }
}

test "package merge respects Kraft bounds and independent optimal costs" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{});
    var book: Book = undefined;
    // Exhaustively enumerate every admitted 3-bit assignment, independently of package merge.
    // Includes zero-weight symbols and skewed distributions.
    for (2..7) |symbols| {
        var frequencies: [6]u32 = @splat(0);
        for (0..symbols) |i| frequencies[i] = @as(u32, 1) << @as(u5, @intCast(i * 2));
        try encoder.makeBook(frequencies[0..symbols], 3, &book);
        var best: u32 = std.math.maxInt(u32);
        var combinations: usize = 1;
        for (0..symbols) |_| combinations *= 3;
        for (0..combinations) |combination| {
            var remaining = combination;
            var mass: u32 = 0;
            var cost: u32 = 0;
            for (0..symbols) |i| {
                const width: u5 = @intCast(remaining % 3 + 1);
                remaining /= 3;
                mass += @as(u32, 1) << (3 - width);
                cost += frequencies[i] * width;
            }
            if (mass == 8) best = @min(best, cost);
        }
        var actual: u32 = 0;
        for (0..symbols) |i| actual += frequencies[i] * book.widths[i];
        try std.testing.expectEqual(best, actual);
    }
    var frequencies: [286]u32 = @splat(0);
    for (&frequencies, 0..) |*frequency, i| {
        frequency.* = if (i < 25) @as(u32, 1) << @as(u5, @intCast(i)) else 1;
    }
    try encoder.makeBook(&frequencies, 15, &book);
    var mass: u32 = 0;
    for (book.widths) |width| {
        try std.testing.expect(width >= 1 and width <= 15);
        mass += @as(u32, 1) << @as(u5, @intCast(15 - width));
    }
    try std.testing.expectEqual(32768, mass);
    try std.testing.expect(@sizeOf(EncoderWorkspace) <= 8 * 1024 * 1024);
}

test "offline price ranges preserve exhaustive paths ties and logical edge budgets" {
    const Reference = struct {
        fn check(
            comptime policy: Compression.OfflinePricing,
            encoder: *Encoder,
            literal: *const Book,
            distance: *const Book,
        ) !void {
            const allocator = std.testing.allocator;
            const workspace = encoder.workspace;
            const size = encoder.buffered;
            const costs = try allocator.alloc(u32, size + 1);
            defer allocator.free(costs);
            const choices = try allocator.alloc(Token, size);
            defer allocator.free(choices);
            costs[size] = 0;
            var edges: u64 = 0;
            var position = size;
            while (position != 0) {
                position -= 1;
                const value = workspace.data[encoder.history + position];
                const width = literal.widths[value];
                var cost = @as(u32, if (width == 0) 13 else width) + costs[position + 1];
                var choice: Token = .{ .length = 0, .value = value };
                const matches = &workspace.matches[position];
                if (matches.count != 0) {
                    const maximum = matches.items[matches.count - 1].length;
                    edges += maximum - 2;
                    // Enumerate every length and usable cached distance, independently of range
                    // grouping, suffix-price selection and vector minima.
                    for (3..@as(usize, maximum) + 1) |length| {
                        var price: u32 = std.math.maxInt(u32);
                        var nearest: u16 = std.math.maxInt(u16);
                        for (matches.items[0..matches.count]) |match| {
                            if (match.length < length or (policy == .maximum_lengths and match
                                .length != length)) continue;
                            const slot = distanceSlot(match.distance);
                            const bits = distance.widths[slot];
                            const candidate = @as(
                                u32,
                                if (bits == 0) 10 else bits,
                            ) + distance_extra[slot];
                            if (policy == .reduced) {
                                price = candidate;
                                nearest = match.distance;
                                break;
                            }
                            if (policy == .maximum_lengths) {
                                if (candidate < price) {
                                    price = candidate;
                                    nearest = match.distance;
                                }
                                continue;
                            }
                            if (candidate < price or (candidate == price and match.distance <
                                nearest))
                            {
                                price = candidate;
                                nearest = match.distance;
                            }
                        }
                        if (price == std.math.maxInt(u32)) continue;
                        const slot = lengthSlot(length);
                        const bits = literal.widths[257 + @as(usize, slot)];
                        const candidate = @as(
                            u32,
                            if (bits == 0) 13 else bits,
                        ) + length_extra[slot] + price + costs[position + length];
                        if (candidate < cost) {
                            cost = candidate;
                            choice = .{ .length = @intCast(length), .value = nearest };
                        }
                    }
                }
                costs[position] = cost;
                choices[position] = choice;
            }
            // Both compiled paths must independently match the exhaustive price and tie oracle.
            inline for (.{ false, true }) |reuse| {
                encoder.stats = .{};
                const count = try encoder.priceParse(reuse, policy, literal, distance);
                try std.testing.expectEqual(edges, encoder.counts().work_units);
                try std.testing.expectEqual(edges, encoder.counts().parse_edges);
                try std.testing.expectEqualSlices(u32, costs, workspace.costs[0 .. size + 1]);
                try std.testing.expectEqualSlices(Token, choices, workspace.choices[0..size]);
                position = 0;
                var token: usize = 0;
                while (position < size) {
                    try std.testing.expectEqual(choices[position], workspace.tokens[token]);
                    position += @max(1, choices[position].length);
                    token += 1;
                }
                try std.testing.expectEqual(token, count);
            }
        }
    };
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var literal: Book = undefined;
    var distance: Book = undefined;
    const full_choices = try std.testing.allocator.alloc(Token, 65535);
    defer std.testing.allocator.free(full_choices);
    const reduced_choices = try std.testing.allocator.alloc(Token, 65535);
    defer std.testing.allocator.free(reduced_choices);
    var differences: [3]bool = @splat(false);
    for ([_]usize{
        0, 1, 2, 3, 4, 8, 10, 11, 19, 33, 34, 35, 36, 67, 131, 257, 258, 259, 768, 65535,
    }) |size| {
        const patterns: usize = if (size == 65535) 1 else 8;
        const pricings: usize = if (size == 65535) 1 else 5;
        for (0..patterns) |pattern| {
            for (0..pricings) |pricing| {
                try encoder.reset(workspace, .{});
                encoder.history = window_bytes;
                encoder.buffered = size;
                @memset(workspace.data[0 .. window_bytes + size], 'A');
                fixedBook(&literal, false);
                fixedBook(&distance, true);
                if (pricing != 0) {
                    for (&literal.widths, 0..) |*width, i| {
                        width.* = switch (pricing) {
                            1 => 0,
                            2 => @intCast((i * 3 + 7) % 16),
                            4 => 1,
                            else => if (i == 'A') 1 else 3,
                        };
                    }
                    for (&distance.widths, 0..) |*width, i| {
                        width.* = switch (pricing) {
                            1 => 0,
                            2 => @intCast((i * 11 + 3) % 16),
                            4 => 2,
                            else => 3,
                        };
                    }
                }
                for (workspace.matches[0..size], 0..) |*matches, position| {
                    matches.count = 0;
                    const available = @min(258, size - position);
                    if (available < 3 or (pattern == 0 and size != 65535)) continue;
                    if (pattern == 3 and position % 4 == 0) continue;
                    const maximum = if (pattern == 2) 3 else if (pattern == 5) 3 + (position * 17 +
                        11) % (available - 2) else available;
                    const count = if (pattern < 3) 1 else if (pattern == 5) 1 + position * 7919 %
                        @min(
                            alternatives,
                            maximum - 2,
                        ) else @min(alternatives, maximum - 2);
                    for (matches.items[0..count], 0..) |*match, i| {
                        const length = if (count == 1) maximum else if (pattern >= 6 and i + 1 <
                            count) 3 + (maximum - 3) * (i / 2) / (count / 2) else 3 + (maximum -
                            3) * i / (count - 1);
                        match.* = .{
                            .length = @intCast(length),
                            .distance = if (pattern == 4) @intCast(
                                1 + i * 100,
                            ) else if (pattern >= 6) @intCast(
                                if (pattern % 2 == 0) 1 + i else count - i,
                            ) else @as(u16, 1) << @intCast(if (pattern == 5) count - 1 - i else i),
                        };
                    }
                    matches.count = @intCast(count);
                }
                try Reference.check(.full, &encoder, &literal, &distance);
                @memcpy(full_choices[0..size], workspace.choices[0..size]);
                try Reference.check(.reduced, &encoder, &literal, &distance);
                @memcpy(reduced_choices[0..size], workspace.choices[0..size]);
                try Reference.check(.maximum_lengths, &encoder, &literal, &distance);
                for (workspace.choices[0..size], 0..) |choice, index| {
                    const pairs = .{
                        .{ full_choices[index], reduced_choices[index] },
                        .{ full_choices[index], choice },
                        .{ reduced_choices[index], choice },
                    };
                    inline for (pairs, 0..) |pair, pair_index| {
                        if (!differences[pair_index] and !std.meta.eql(pair[0], pair[1])) {
                            differences[pair_index] = true;
                        }
                    }
                }
                if (pattern == 2 and pricing == 4) {
                    for (workspace.choices[0..size]) |choice| {
                        try std.testing.expectEqual(@as(u16, 0), choice.length);
                    }
                }
                if (size == 259 and pattern == 5 and pricing == 2) {
                    const units = encoder.counts().work_units;
                    for ([_]u64{ units, units - 1 }) |budget| {
                        try encoder.reset(workspace, .{ .limits = .{ .work_units = budget } });
                        encoder.history = window_bytes;
                        encoder.buffered = size;
                        if (budget == units) {
                            try Reference.check(.full, &encoder, &literal, &distance);
                        } else {
                            try std.testing.expectError(
                                error.LimitExceeded,
                                encoder.priceParse(true, .full, &literal, &distance),
                            );
                            try std.testing.expect(encoder.counts().work_units < units);
                        }
                    }
                }
            }
        }
    }
    try std.testing.expect(differences[0] and differences[1] and differences[2]);
    // Period-256 data makes both distances real matches. Uniform and changing literal prices,
    // distance boundaries, and multiple alternatives exercise both reuse and fallback.
    for (0..4) |pattern| {
        try encoder.reset(workspace, .{});
        encoder.history = window_bytes;
        encoder.buffered = 4096;
        for (workspace.data[0 .. window_bytes + encoder.buffered], 0..) |*byte, position| {
            byte.* = @truncate(position);
        }
        literal.widths = @splat(13);
        literal.widths[285] = 1;
        if (pattern == 1) literal.widths[0] = 12;
        distance.widths = @splat(1);
        for (workspace.matches[0..encoder.buffered], 0..) |*matches, position| {
            const maximum = @min(258, encoder.buffered - position);
            matches.count = if (maximum < 3) 0 else 1;
            matches.items[0] = .{
                .length = @intCast(maximum),
                .distance = if (pattern == 2 and position / 1024 % 2 == 0) 512 else 256,
            };
            if (pattern == 3 and position == 2048) {
                matches.count = 2;
                matches.items[0] = .{ .length = 3, .distance = 256 };
                matches.items[1] = .{ .length = @intCast(maximum), .distance = 512 };
            }
        }
        try Reference.check(.full, &encoder, &literal, &distance);
        const full = encoder.counts().work_units;
        if (pattern == 0) {
            // Prove that the chosen input enters reuse and that every copied row agrees with the
            // independently computed parse, including literal values and equal-price ties.
            const costs = try std.testing.allocator.dupe(u32, workspace.costs[0..4097]);
            defer std.testing.allocator.free(costs);
            const choices = try std.testing.allocator.dupe(Token, workspace.choices[0..4096]);
            defer std.testing.allocator.free(choices);
            var prices: [286]u32 = undefined;
            for (&prices, literal.widths) |*price, width| price.* = if (width == 0) 13 else width;
            var run = PriceRun.find(&encoder, 3500, &prices);
            var position: usize = 3500;
            var copied = false;
            while (position > run.first and run.maximum != 0) {
                position -= 1;
                encoder.stats = .{};
                const prior = run;
                const first = try run.reuse(&encoder, position);
                if (first < position) {
                    @memset(std.mem.sliceAsBytes(workspace.costs[first..position]), 0xa5);
                    @memset(std.mem.sliceAsBytes(workspace.choices[first..position]), 0xa5);
                    run = prior;
                    encoder.stats = .{};
                    try std.testing.expectEqual(first, try run.reuse(&encoder, position));
                    try std.testing.expectEqualSlices(
                        u32,
                        costs[first..position],
                        workspace.costs[first..position],
                    );
                    try std.testing.expectEqualSlices(
                        Token,
                        choices[first..position],
                        workspace.choices[first..position],
                    );
                    copied = true;
                    break;
                }
            }
            try std.testing.expect(copied);
        }
        for ([_]u64{ 0, 98943, 98944, 98945, full / 2, full - 1, full }) |budget| {
            var admitted: u64 = 0;
            var position = encoder.buffered;
            while (position != 0) {
                position -= 1;
                const matches = &workspace.matches[position];
                const edges = if (matches.count == 0) 0 else matches.items[matches.count - 1]
                    .length - 2;
                if (edges > budget - admitted) break;
                admitted += edges;
            }
            encoder.stats = .{};
            encoder.options.limits.work_units = budget;
            @memset(std.mem.sliceAsBytes(workspace.costs[0 .. encoder.buffered + 1]), 0xa5);
            @memset(std.mem.sliceAsBytes(workspace.choices[0..encoder.buffered]), 0xa5);
            const result = encoder.priceParse(true, .full, &literal, &distance);
            if (budget < full) {
                try std.testing.expectError(error.LimitExceeded, result);
            } else _ = try result;
            try std.testing.expectEqual(admitted, encoder.counts().work_units);
            try std.testing.expectEqual(admitted, encoder.counts().parse_edges);
        }
        // Scalar accounting of the failing row verifies work-limit priority and the publication
        // order when the edge counter, rather than the work budget, is exhausted.
        for ([_]bool{ false, true }) |edge_overflow| {
            const initial: EncodeStats = if (edge_overflow) .{
                .parse_edges = std.math.maxInt(u64) - full / 2,
            } else .{ .work_units = std.math.maxInt(u64) - full / 2 };
            var expected = initial;
            var position = encoder.buffered;
            while (position != 0) {
                position -= 1;
                const matches = &workspace.matches[position];
                const edges: u64 = if (matches.count == 0) 0 else matches.items[matches.count - 1]
                    .length - 2;
                if (edges > std.math.maxInt(u64) - expected.work_units) break;
                expected.work_units += edges;
                if (edges > std.math.maxInt(u64) - expected.parse_edges) break;
                expected.parse_edges += edges;
            }
            encoder.stats = initial;
            encoder.options.limits.work_units = std.math.maxInt(u64);
            try std.testing.expectError(
                if (edge_overflow) error.CounterOverflow else error.LimitExceeded,
                encoder.priceParse(true, .full, &literal, &distance),
            );
            try std.testing.expectEqualDeep(expected, encoder.counts());
        }
    }
    // Real repeated input produces a coalesced one-match row, entering the single-match path. Check
    // its parse against the independent exhaustive oracle, including finite boundaries.
    try encoder.reset(workspace, .{ .compression = .{ .level = 9 } });
    encoder.buffered = 512;
    for (workspace.data[0..encoder.buffered], 0..) |*byte, i| byte.* = "abcdefgh"[i % 8];
    try encoder.findOfflineTreeMatchesStandalone();
    try std.testing.expectEqual(1, workspace.matches[8].count);
    try std.testing.expectEqual(
        Match{ .length = 258, .distance = 8 },
        workspace.matches[8].items[0],
    );
    fixedBook(&literal, false);
    fixedBook(&distance, true);
    for ([_]u8{ 0, 1, 7 }) |width| {
        @memset(&distance.widths, width);
        try Reference.check(.full, &encoder, &literal, &distance);
    }
    const repeated_work = encoder.counts().work_units;
    encoder.stats = .{};
    encoder.options.limits.work_units = repeated_work - 1;
    try std.testing.expectError(
        error.LimitExceeded,
        encoder.priceParse(true, .full, &literal, &distance),
    );
    encoder.options.limits.work_units = repeated_work;
    try Reference.check(.full, &encoder, &literal, &distance);

    var costs: [40]u32 = undefined;
    for (0..4) |pattern| {
        for (&costs, 0..) |*cost, i| {
            cost.* = switch (pattern) {
                0 => @intCast(i),
                1 => @intCast(costs.len - i),
                2 => std.math.maxInt(u32),
                else => @intCast((i * 123457 + i / 13) % 7),
            };
        }
        for (0..8) |offset| {
            for (1..33) |length| {
                const values = costs[offset..][0..length];
                var expected: usize = 0;
                for (values, 0..) |cost, i| {
                    if (cost < values[expected]) expected = i;
                }
                try std.testing.expectEqual(expected, minimumCostIndex(values));
            }
        }
    }
}

test "offline pricing selects among retained distance prices" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{});
    encoder.history = window_bytes;
    encoder.buffered = 4;
    @memset(workspace.data[0 .. window_bytes + 4], 'A');
    for (workspace.matches[0..4]) |*matches| matches.count = 0;
    workspace.matches[0].count = 2;
    workspace.matches[0].items[0] = .{ .length = 3, .distance = 1 };
    workspace.matches[0].items[1] = .{ .length = 4, .distance = 32768 };
    var literal: Book = undefined;
    var distance: Book = undefined;
    literal.widths = @splat(10);
    literal.widths[257] = 1;
    literal.widths[258] = 15;
    distance.widths = @splat(15);
    distance.widths[29] = 1;

    _ = try encoder.priceParse(false, .full, &literal, &distance);
    try std.testing.expectEqual(Token{ .length = 3, .value = 32768 }, workspace.choices[0]);
    const full_cost = workspace.costs[0];
    encoder.stats = .{};
    _ = try encoder.priceParse(false, .reduced, &literal, &distance);
    try std.testing.expectEqual(Token{ .length = 3, .value = 1 }, workspace.choices[0]);
    try std.testing.expect(full_cost < workspace.costs[0]);
}

test "header run minima preserve exhaustive prices repeat bounds and tie choices" {
    const Reference = struct {
        fn check(widths: []const u8, prices: *const [19]u16) !void {
            var actual: [316]RunChoice = undefined;
            const actual_cost = priceRuns(widths, prices, actual[0..widths.len]);
            var costs: [317]u32 = undefined;
            costs[widths.len] = 0;
            var position = widths.len;
            while (position != 0) {
                position -= 1;
                const value = widths[position];
                var cost: u32 = prices[value] + costs[position + 1];
                var choice: RunChoice = .{ .symbol = value, .take = 1 };
                var same: usize = 1;
                while (same < 138 and position + same < widths.len) : (same += 1) {
                    if (widths[position + same] != value) break;
                }
                for (16..19) |symbol| {
                    if (symbol == 16) {
                        if (position == 0 or widths[position - 1] != value) continue;
                    } else if (value != 0) continue;
                    const minimum: usize = if (symbol == 18) 11 else 3;
                    const maximum = @min(same, switch (symbol) {
                        16 => @as(usize, 6),
                        17 => 10,
                        else => 138,
                    });
                    var take = minimum;
                    while (take <= maximum) : (take += 1) {
                        const candidate = prices[symbol] + @as(
                            u32,
                            runExtra(@intCast(symbol)),
                        ) + costs[position + take];
                        if (candidate < cost) {
                            cost = candidate;
                            choice = .{ .symbol = @intCast(symbol), .take = @intCast(take) };
                        }
                    }
                }
                costs[position] = cost;
                try std.testing.expectEqual(choice, actual[position]);
            }
            try std.testing.expectEqual(costs[0], actual_cost);
        }
    };
    var widths: [316]u8 = undefined;
    for (0..6) |pricing| {
        var prices: [19]u16 = @splat(if (pricing == 0) 1 else 7);
        if (pricing >= 2) prices[pricing + 13] = 1;
        if (pricing == 5) prices[0] = 1;
        // Every short sequence over zero, the narrowest width and the widest width. Equal prices
        // exercise literal/earlier-symbol/shorter-repeat tie order independently.
        var combinations: usize = 1;
        for (0..9) |size| {
            for (0..combinations) |combination| {
                var remaining = combination;
                for (widths[0..size]) |*width| {
                    width.* = ([_]u8{ 0, 1, 15 })[remaining % 3];
                    remaining /= 3;
                }
                try Reference.check(widths[0..size], &prices);
            }
            combinations *= 3;
        }
        // Visit both sides of every repeat boundary, including runs longer than 138 and width
        // changes that retire the previous run's minimum queue.
        for (0..317) |size| {
            @memset(&widths, 0);
            try Reference.check(widths[0..size], &prices);
            @memset(&widths, 15);
            try Reference.check(widths[0..size], &prices);
            for (&widths, 0..) |*width, i| {
                width.* = if (i % 149 < 139) 0 else @intCast(i % 16);
            }
            try Reference.check(widths[0..size], &prices);
        }
    }
    // Arbitrary suffix costs also force a full 128-entry queue, expiry, wrap and equal minima.
    var costs: [317]u32 = undefined;
    for (0..4) |pattern| {
        for (&costs, 0..) |*cost, i| {
            cost.* = switch (pattern) {
                0 => @intCast(i),
                1 => @intCast(costs.len - i),
                2 => 7,
                else => @intCast((i * 123457 + i / 13) % 31),
            };
        }
        var queue: RunMinimum = .{};
        var position: usize = 306;
        while (position != 0) {
            position -= 1;
            const first = position + 11;
            const last = @min(position + 138, costs.len - 1);
            var expected = first;
            for (first + 1..last + 1) |i| {
                if (costs[i] < costs[expected]) expected = i;
            }
            try std.testing.expectEqual(expected, queue.add(&costs, first, last));
        }
    }
}

test "header repricing preserves exact finite work admission" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{});
    var frequencies: [286]u32 = @splat(0);
    frequencies['a'] = 23;
    frequencies['b'] = 7;
    frequencies[256] = 1;
    try encoder.makeBook(&frequencies, 15, &workspace.header.literal);
    try encoder.makeBook(&.{1}, 15, &workspace.header.distance);
    const literal = workspace.header.literal;
    const distance = workspace.header.distance;
    encoder.stats = .{};
    try encoder.makeHeader();
    const expected = workspace.header;
    const counts = encoder.counts();
    try std.testing.expect(counts.work_units >= 4 * 258 * 138);
    for ([_]u64{ counts.work_units, counts.work_units - 1 }) |budget| {
        try encoder.reset(workspace, .{ .limits = .{ .work_units = budget } });
        workspace.header.literal = literal;
        workspace.header.distance = distance;
        if (budget == counts.work_units) {
            try encoder.makeHeader();
            try std.testing.expectEqual(counts, encoder.counts());
            try std.testing.expectEqual(expected.bits, workspace.header.bits);
            try std.testing.expectEqual(expected.run_count, workspace.header.run_count);
            try std.testing.expectEqualSlices(
                Run,
                expected.runs[0..expected.run_count],
                workspace.header.runs[0..workspace.header.run_count],
            );
        } else {
            try std.testing.expectError(error.LimitExceeded, encoder.makeHeader());
            try std.testing.expect(encoder.counts().work_units < budget);
        }
    }
}

test "header trial reuse preserves exhaustive runs serialized ties and every work boundary" {
    const Reference = struct {
        // Enumerate every legal repeat edge, independently of priceRuns and trial convergence. The
        // unchanged package-merge builder supplies the precode; always execute all four trials.
        fn build(encoder: *Encoder, charges: *[8]u64, same: *u4) !void {
            const header = &encoder.workspace.header;
            header.literal_count = 257;
            for (header.literal.widths, 0..) |width, i| {
                if (width != 0) header.literal_count = @max(header.literal_count, i + 1);
            }
            header.distance_count = 1;
            for (header.distance.widths[0..30], 0..) |width, i| {
                if (width != 0) header.distance_count = i + 1;
            }
            var widths: [316]u8 = undefined;
            @memcpy(
                widths[0..header.literal_count],
                header.literal.widths[0..header.literal_count],
            );
            @memcpy(
                widths[header.literal_count..][0..header.distance_count],
                header.distance.widths[0..header.distance_count],
            );
            const size = header.literal_count + header.distance_count;
            var prices: [19]u16 = @splat(4);
            var best: u32 = std.math.maxInt(u32);
            var previous: [316]Run = undefined;
            var previous_count: usize = 0;
            for (0..4) |pass| {
                var costs: [317]u32 = undefined;
                var choices: [316]RunChoice = undefined;
                costs[size] = 0;
                var position = size;
                while (position != 0) {
                    position -= 1;
                    const value = widths[position];
                    costs[position] = prices[value] + costs[position + 1];
                    choices[position] = .{ .symbol = value, .take = 1 };
                    for (16..19) |symbol| {
                        if (symbol == 16) {
                            if (position == 0 or widths[position - 1] != value) continue;
                        } else if (value != 0) continue;
                        const first: usize = if (symbol == 18) 11 else 3;
                        const last: usize = switch (symbol) {
                            16 => 6,
                            17 => 10,
                            else => 138,
                        };
                        var take: usize = 1;
                        while (take <= last and position + take <= size) : (take += 1) {
                            if (widths[position + take - 1] != value) break;
                            if (take < first) continue;
                            const extra: u32 = switch (symbol) {
                                16 => 2,
                                17 => 3,
                                else => 7,
                            };
                            const cost = prices[symbol] + extra + costs[position + take];
                            if (cost < costs[position]) {
                                costs[position] = cost;
                                choices[position] = .{
                                    .symbol = @intCast(symbol),
                                    .take = @intCast(take),
                                };
                            }
                        }
                    }
                }
                var runs: [316]Run = undefined;
                var count: usize = 0;
                var frequencies: [19]u32 = @splat(0);
                position = 0;
                while (position < size) {
                    const choice = choices[position];
                    const extra: u8 = switch (choice.symbol) {
                        16, 17 => choice.take - 3,
                        18 => choice.take - 11,
                        else => 0,
                    };
                    runs[count] = .{ .symbol = choice.symbol, .extra = extra };
                    frequencies[choice.symbol] += 1;
                    count += 1;
                    position += choice.take;
                }
                if (pass != 0 and count == previous_count) {
                    var identical = true;
                    for (runs[0..count], previous[0..count]) |run, old| {
                        if (run.symbol != old.symbol or run.extra != old.extra) identical = false;
                    }
                    if (identical) same.* |= @as(u4, 1) << @intCast(pass);
                }
                @memcpy(previous[0..count], runs[0..count]);
                previous_count = count;
                var precode: Book = undefined;
                try encoder.makeBook(&frequencies, 7, &precode);
                charges[pass * 2] = encoder.counts().work_units;
                const order = [_]u8{
                    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
                };
                var precode_count: usize = 4;
                for (order, 0..) |symbol, i| {
                    if (precode.widths[symbol] != 0) precode_count = @max(precode_count, i + 1);
                }
                var bits: u32 = @intCast(14 + precode_count * 3);
                for (runs[0..count]) |run| {
                    const extra: u32 = switch (run.symbol) {
                        16 => 2,
                        17 => 3,
                        18 => 7,
                        else => 0,
                    };
                    bits += precode.widths[run.symbol] + extra;
                }
                if (bits < best) {
                    best = bits;
                    header.bits = bits;
                    header.precode = precode;
                    header.precode_count = precode_count;
                    header.run_count = count;
                    @memcpy(header.runs[0..count], runs[0..count]);
                }
                for (&prices, precode.widths[0..19]) |*price, width| {
                    price.* = if (width == 0) 7 else width;
                }
                try encoder.work(size * 138);
                charges[pass * 2 + 1] = encoder.counts().work_units;
            }
        }

        // RFC 1951 fields written one bit at a time, without Encoder.put/emit or runExtra.
        const Wire = struct {
            bytes: [512]u8 = @splat(0),
            bits: usize,

            fn put(self: *@This(), value: usize, width: usize) void {
                for (0..width) |bit| {
                    const shift: std.math.Log2Int(usize) = @intCast(bit);
                    const output_shift: u3 = @intCast(self.bits % 8);
                    const value_bit: u8 = @intCast((value >> shift) & 1);
                    self.bytes[self.bits / 8] |= value_bit << output_shift;
                    self.bits += 1;
                }
            }

            fn header(self: *@This(), expected: *const Header) void {
                self.put(1, 1);
                self.put(2, 2);
                self.put(expected.literal_count - 257, 5);
                self.put(expected.distance_count - 1, 5);
                self.put(expected.precode_count - 4, 4);
                const order = [_]u8{
                    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
                };
                for (
                    order[0..expected.precode_count],
                ) |symbol| self.put(expected.precode.widths[symbol], 3);
                for (expected.runs[0..expected.run_count]) |run| {
                    self.put(
                        expected.precode.codes[run.symbol],
                        expected.precode.widths[run.symbol],
                    );
                    self.put(run.extra, switch (run.symbol) {
                        16 => 2,
                        17 => 3,
                        18 => 7,
                        else => 0,
                    });
                }
                self.put(expected.literal.codes[256], expected.literal.widths[256]);
            }
        };
    };
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var state: u32 = 0x1951ca5e;
    var converged: u4 = 0;
    var changed_after_first: bool = false;
    for (0..80) |sample| {
        try encoder.reset(workspace, .{});
        var frequencies: [286]u32 = @splat(0);
        for (&frequencies, 0..) |*frequency, i| {
            state = state *% 1664525 +% 1013904223;
            const active = switch (sample % 4) {
                0 => i < sample,
                1 => i % (sample + 1) == 0,
                2 => i < 257,
                else => state % 7 < 3,
            };
            if (active) frequency.* = if (sample % 3 == 0) 1 else state % 1000 + 1;
        }
        frequencies[256] = 1;
        try encoder.makeBook(&frequencies, 15, &workspace.header.literal);
        @memset(&frequencies, 0);
        for (frequencies[0..30], 0..) |*frequency, i| {
            if (sample % 4 != 0 and i <= sample % 30) frequency.* = @intCast(i + 1);
        }
        try encoder.makeBook(frequencies[0..30], 15, &workspace.header.distance);
        const literal = workspace.header.literal;
        const distance = workspace.header.distance;
        encoder.stats = .{};
        var charges: [8]u64 = undefined;
        var same: u4 = 0;
        try Reference.build(&encoder, &charges, &same);
        converged |= same;
        changed_after_first = changed_after_first or same & 2 == 0;
        const expected = workspace.header;
        const total = charges[7];
        // Every charge boundary, one below and one above it, plus a counter near u64 overflow. The
        // expected refusal counter is the last wholly admitted reference charge.
        for ([_]u64{ 0, std.math.maxInt(u64) - total }) |initial| {
            for (charges) |boundary| {
                for ([_]u64{ boundary -| 1, boundary, @min(total, boundary + 1) }) |budget| {
                    try encoder.reset(
                        workspace,
                        .{ .limits = .{ .work_units = initial + budget } },
                    );
                    workspace.header.literal = literal;
                    workspace.header.distance = distance;
                    // Prior calls' scratch must not become a cross-call header cache.
                    @memset(std.mem.asBytes(&workspace.header_trial), 0xa5);
                    encoder.stats.work_units = initial;
                    var admitted: u64 = 0;
                    for (charges) |charge| {
                        if (charge > budget) break;
                        admitted = charge;
                    }
                    if (budget < total) {
                        try std.testing.expectError(error.LimitExceeded, encoder.makeHeader());
                    } else {
                        try encoder.makeHeader();
                        const actual = &workspace.header;
                        try std.testing.expectEqual(expected.bits, actual.bits);
                        try std.testing.expectEqual(expected.precode_count, actual.precode_count);
                        try std.testing.expectEqual(expected.run_count, actual.run_count);
                        try std.testing.expectEqual(expected.precode, actual.precode);
                        try std.testing.expectEqualSlices(
                            Run,
                            expected.runs[0..expected.run_count],
                            actual.runs[0..actual.run_count],
                        );
                    }
                    try std.testing.expectEqual(
                        EncodeStats{ .work_units = initial + admitted },
                        encoder.counts(),
                    );
                }
            }
        }
        for (0..8) |offset| {
            try encoder.reset(workspace, .{});
            workspace.header.literal = literal;
            workspace.header.distance = distance;
            try encoder.makeHeader();
            encoder.bit_count = @intCast(offset);
            var wire: Reference.Wire = .{ .bits = offset };
            wire.header(&expected);
            try encoder.emit(
                &.{},
                .{ .first = 0, .end = 0, .start = 0, .bytes = 0 },
                .dynamic,
                true,
            );
            encoder.alignBits();
            try std.testing.expectEqual((wire.bits + 7) / 8, encoder.pending);
            try std.testing.expectEqualSlices(
                u8,
                wire.bytes[0..encoder.pending],
                workspace.wire[0..encoder.pending],
            );
        }
    }
    try std.testing.expect(changed_after_first);
    try std.testing.expectEqual(@as(u4, 0b1110), converged);
}

test "serialized choices include every header run padding and token bit" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var tokens: [512]Token = undefined;
    @memset(workspace.data[0..512], 65);
    inline for (.{ Kind.stored, Kind.fixed, Kind.dynamic }) |kind| {
        const count: usize = if (kind == .fixed) 1 else tokens.len;
        for (tokens[0..count], 0..) |*token, i| {
            token.* = .{ .length = 0, .value = if (kind == .stored) @intCast(i % 256) else 65 };
        }
        for (0..8) |offset| {
            try encoder.reset(workspace, .{});
            encoder.bit_count = @intCast(offset);
            const chosen = try encoder.select(tokens[0..count], count, @intCast(offset));
            try std.testing.expectEqual(kind, chosen.kind);
            try encoder.emit(
                tokens[0..count],
                .{ .first = 0, .end = count, .start = 0, .bytes = count },
                chosen.kind,
                true,
            );
            const actual = encoder.pending * 8 + encoder.bit_count - offset;
            try std.testing.expectEqual(chosen.bits, actual);
        }
    }
}

test "search admission preserves exact caches counters and per-operation limits" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const expected = try allocator.alloc(Matches, 2048);
    defer allocator.free(expected);
    var encoder: Encoder = undefined;
    for (0..2) |pattern| {
        for (workspace.data[0..expected.len], 0..) |*byte, i| {
            byte.* = if (pattern == 0) 65 else @truncate((i *% 123457 +% i / 13) >> 4);
        }
        try encoder.reset(workspace, .{ .compression = .{ .level = 9 } });
        encoder.buffered = expected.len;
        try encoder.findOfflineTreeMatchesStandalone();
        const counters = encoder.counts();
        for (expected, workspace.matches[0..expected.len]) |*saved, matches| {
            saved.count = matches.count;
            @memcpy(saved.items[0..saved.count], matches.items[0..matches.count]);
        }
        try std.testing.expect(counters.work_units < 100000);
        try encoder.reset(
            workspace,
            .{ .compression = .{ .level = 9 }, .limits = .{ .work_units = 100000 } },
        );
        encoder.buffered = expected.len;
        try encoder.findOfflineTreeMatchesStandalone();
        try std.testing.expectEqual(counters, encoder.counts());
        for (expected, workspace.matches[0..expected.len]) |saved, matches| {
            try std.testing.expectEqual(saved.count, matches.count);
            for (saved.items[0..saved.count], matches.items[0..matches.count]) |a, b| {
                try std.testing.expectEqual(a.length, b.length);
                try std.testing.expectEqual(a.distance, b.distance);
            }
        }
        try encoder.reset(
            workspace,
            .{
                .compression = .{ .level = 9 },
                .limits = .{ .work_units = counters.work_units - 1 },
            },
        );
        encoder.buffered = expected.len;
        try std.testing.expectError(
            error.LimitExceeded,
            encoder.findOfflineTreeMatchesStandalone(),
        );
        try std.testing.expect(encoder.counts().work_units < counters.work_units);
    }
}

test "greedy and lazy caches preserve token choices while skipping covered positions" {
    const Reference = struct {
        // Walk prior bytes directly, independently of the encoder's hash-chain construction and
        // sparse-search schedule. Equal lengths keep the nearest candidate.
        fn longest(data: []const u8, position: usize, window: usize, depth: usize) Match {
            const maximum = @min(258, data.len - position);
            if (maximum < 3) return .{ .length = 0, .distance = 0 };
            const hash = hash3(data[position..][0..3]);
            const first = position -| window;
            var candidate = position;
            var probes: usize = 0;
            var best: Match = .{ .length = 0, .distance = 0 };
            while (candidate > first and probes < depth) {
                candidate -= 1;
                if (hash3(data[candidate..][0..3]) != hash) continue;
                probes += 1;
                var length: usize = 0;
                while (length < maximum and data[candidate + length] == data[position + length])
                    length += 1;
                if (length >= 3 and length > best.length) {
                    best = .{
                        .length = @intCast(length),
                        .distance = @intCast(position - candidate),
                    };
                    if (length == maximum) break;
                }
            }
            return best;
        }
    };
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var expected: [768]Token = undefined;
    var encoder: Encoder = undefined;
    for (0..4) |pattern| {
        for ([_]usize{ 0, 256 }) |history| {
            const total = history + expected.len;
            const data = workspace.data[0..total];
            for (data, 0..) |*byte, i| {
                byte.* = switch (pattern) {
                    0 => 'A',
                    1 => @intCast(i % 7),
                    2 => @truncate((i *% 123457 +% i / 13) >> 4),
                    else => "abcxabcabcabcabcdabcxabcd"[(i + i / 127) % 24],
                };
            }
            for ([_]usize{ 256, 32768 }) |window| {
                inline for (
                    .{
                        Compression{ .level = 3 },
                        Compression{ .level = 4, .lazy_lookahead = .reduced },
                        Compression{ .level = 5, .lazy_lookahead = .reduced },
                        Compression{ .level = 6, .lazy_lookahead = .reduced },
                        Compression{ .level = 6 },
                    },
                ) |compression| {
                    const lazy = compression.level >= 4;
                    const depth: usize = switch (compression.level) {
                        3 => 32,
                        4 => 64,
                        5 => 128,
                        6 => 256,
                        else => unreachable,
                    };
                    var count: usize = 0;
                    var position = history;
                    var pending: ?Match = null;
                    while (position < total) {
                        var match = pending orelse Reference.longest(data, position, window, depth);
                        pending = null;
                        if (lazy and match.length != 0 and position + 1 < total) {
                            const next_depth = if (compression.lazy_lookahead == .reduced) depth /
                                2 else depth;
                            const next = Reference.longest(data, position + 1, window, next_depth);
                            if (next.length > match.length) {
                                pending = next;
                                match.length = 0;
                            }
                        }
                        expected[count] = .{
                            .length = match.length,
                            .value = if (match.length == 0) data[position] else match.distance,
                        };
                        count += 1;
                        position += @max(1, match.length);
                    }
                    // Covered rows may retain unrelated bytes. Every token/lookahead read must use
                    // a row initialized by this search, including the final short tail.
                    @memset(std.mem.sliceAsBytes(workspace.matches[0..expected.len]), 0xa5);
                    try encoder.reset(
                        workspace,
                        .{ .compression = compression, .window_bytes = window },
                    );
                    encoder.history = history;
                    encoder.buffered = expected.len;
                    try encoder.findMatches();
                    const actual = encoder.referenceParse(lazy);
                    try std.testing.expectEqual(count, actual);
                    try std.testing.expectEqualSlices(
                        Token,
                        expected[0..count],
                        workspace.tokens[0..actual],
                    );
                    if (pattern == 0) try std.testing.expect(encoder.counts().match_probes < 20);

                    const counters = encoder.counts();
                    try encoder.reset(
                        workspace,
                        .{
                            .compression = compression,
                            .window_bytes = window,
                            .limits = .{ .work_units = counters.work_units },
                        },
                    );
                    encoder.history = history;
                    encoder.buffered = expected.len;
                    try encoder.findMatches();
                    try std.testing.expectEqual(counters, encoder.counts());
                    try std.testing.expectEqual(count, encoder.referenceParse(lazy));
                    try std.testing.expectEqualSlices(
                        Token,
                        expected[0..count],
                        workspace.tokens[0..count],
                    );
                    if (counters.work_units != 0) {
                        try encoder.reset(
                            workspace,
                            .{
                                .compression = compression,
                                .window_bytes = window,
                                .limits = .{ .work_units = counters.work_units - 1 },
                            },
                        );
                        encoder.history = history;
                        encoder.buffered = expected.len;
                        try std.testing.expectError(error.LimitExceeded, encoder.findMatches());
                        try std.testing.expect(encoder.counts().work_units < counters.work_units);
                    }
                }
            }
        }
    }
}

test "match cache initializes dictionary starts and every short tail before parsing" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    const sizes = [_]usize{
        0,   1,   2,   3,   4,   5,   6,   7,   8,   9,   10,  11,  15,  16,  17,  255, 256, 257,
        258, 259, 260, 261, 262, 511, 512, 513, 514, 515, 516, 517, 518, 519, 520, 767, 768, 769,
        770, 771, 772, 773, 774, 775, 776,
    };
    for (sizes) |size| {
        for ([_]usize{ 256, 32768 }) |window| {
            for ([_]usize{ 0, 1, 2, 255, 256, 32768 }) |history| {
                if (history > window) continue;
                for ([_]Compression{ .{ .level = 3 }, .{ .level = 6 } }) |compression| {
                    const lazy = compression.level == 6;
                    var expected: [8]Token = undefined;
                    var count: usize = 0;
                    var position: usize = 0;
                    // For an all-A source, the nearest preceding byte supplies the longest legal
                    // match, including overlap. The first byte without history and an uncovered
                    // one/two-byte remainder need literals. This expectation uses no hash or cached
                    // row.
                    while (position < size) {
                        const remaining = size - position;
                        const can_match = history + position != 0 and remaining >= 3;
                        const length: usize = if (can_match) @min(258, remaining) else 0;
                        expected[count] = .{
                            .length = @intCast(length),
                            .value = if (length == 0) 'A' else 1,
                        };
                        count += 1;
                        position += @max(1, length);
                    }
                    var full: EncodeStats = undefined;
                    for (0..2) |pass| {
                        const budget = if (pass == 0) std.math.maxInt(u64) else full.work_units;
                        try encoder.reset(
                            workspace,
                            .{
                                .compression = compression,
                                .window_bytes = window,
                                .limits = .{ .work_units = budget },
                            },
                        );
                        encoder.history = history;
                        encoder.buffered = size;
                        @memset(workspace.data[0 .. history + size], 'A');
                        @memset(std.mem.sliceAsBytes(workspace.matches[0..size]), 0xa5);
                        try encoder.findMatches();
                        if (pass == 0) {
                            full = encoder.counts();
                        } else {
                            try std.testing.expectEqual(full, encoder.counts());
                        }
                        try std.testing.expectEqual(count, encoder.referenceParse(lazy));
                        try std.testing.expectEqualSlices(
                            Token,
                            expected[0..count],
                            workspace.tokens[0..count],
                        );
                        // The final short rows must be safe even when they lie inside a match: a
                        // lazy lookahead can visit either one before choosing that match.
                        for (workspace.matches[size - @min(2, size) .. size]) |row| {
                            try std.testing.expectEqual(0, row.count);
                        }
                        if (size >= 8) {
                            const first_match: usize = if (history == 0) 1 else 0;
                            const skipped_offset: usize = if (lazy) 2 else 1;
                            const covered = first_match + skipped_offset;
                            // A covered non-tail row stays poisoned. This proves the selected
                            // initializer avoids that row while every actual parse read succeeds.
                            try std.testing.expectEqual(0xa5, workspace.matches[covered].count);
                        }
                    }
                }
            }
        }
    }
}

test "short hash initialization ignores retired workspace contents" {
    const decoding = @import("decode.zig");
    const allocator = std.testing.allocator;
    const left = try EncoderWorkspace.create(allocator);
    defer left.destroy(allocator);
    const right = try EncoderWorkspace.create(allocator);
    defer right.destroy(allocator);
    const decoder = try decoding.DecoderWorkspace.create(allocator);
    defer decoder.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const cases = [_]struct {
        dictionary: usize,
        input: usize,
    }{
        .{ .dictionary = 0, .input = 0 },
        .{ .dictionary = 0, .input = 1 },
        .{ .dictionary = 0, .input = 2 },
        .{ .dictionary = 0, .input = 3 },
        .{ .dictionary = 0, .input = 64 },
        .{ .dictionary = 0, .input = 255 },
        .{ .dictionary = 0, .input = 256 },
        .{ .dictionary = 0, .input = 257 },
        .{ .dictionary = 1, .input = 255 },
        .{ .dictionary = 2, .input = 254 },
        .{ .dictionary = 255, .input = 1 },
        .{ .dictionary = 256, .input = 0 },
        .{ .dictionary = 256, .input = 1 },
    };
    var source: [257]u8 = undefined;
    var dictionary: [256]u8 = undefined;
    var first_wire: [1024]u8 = undefined;
    var second_wire: [1024]u8 = undefined;
    var restored: [257]u8 = undefined;
    for (0..2) |pattern| {
        for (
            &source,
            0..,
        ) |*byte, i| byte.* = if (pattern == 0) @truncate(
            (i *% 29 +% i / 7) >> 2,
        ) else @as(u8, @intCast(i % 3)) + 'A';
        for (&dictionary, 0..) |*byte, i| byte.* = source[i];
        for (cases) |case| {
            const preset: ?[]const u8 = if (case.dictionary == 0) null else dictionary[0..case
                .dictionary];
            for ([_]u8{ 3, 6, 9 }) |level| {
                // The two workspaces retain incompatible arbitrary heads from earlier operations.
                // Identical wire and counts show that only keys in this operation influence it.
                @memset(&left.chain().heads, 0x3fff_ffff);
                @memset(&right.chain().heads, no_position);
                var encoder: Encoder = undefined;
                try encoder.reset(
                    left,
                    .{ .dictionary = preset, .compression = .{ .level = level } },
                );
                const a = try encoder.step(source[0..case.input], &first_wire, .finish);
                const counts = encoder.counts();
                try encoder.reset(
                    right,
                    .{ .dictionary = preset, .compression = .{ .level = level } },
                );
                const b = try encoder.step(source[0..case.input], &second_wire, .finish);
                try std.testing.expectEqual(EncodeStatus.complete, a.status);
                try std.testing.expectEqual(a, b);
                try std.testing.expectEqual(counts, encoder.counts());
                try std.testing.expectEqualSlices(
                    u8,
                    first_wire[0..a.produced],
                    second_wire[0..b.produced],
                );
                const result = try decoding.decode(
                    first_wire[0..a.produced],
                    restored[0..case.input],
                    .{ .workspace = decoder, .history = history },
                    .{ .dictionary = preset, .output_size = .exact, .trailing_data = .reject },
                );
                try std.testing.expectEqual(case.input, result.produced);
                try std.testing.expectEqualSlices(
                    u8,
                    source[0..case.input],
                    restored[0..case.input],
                );
            }
        }
    }
}

test "pricing reuse prefilter preserves strict run boundaries" {
    var rows: [522]Matches = undefined;
    for ([_]usize{ 35, 258 }) |length| {
        for ([_]usize{ 0, 3 }) |prefix| {
            for ([_]usize{ 2 * length - 1, 2 * length, 2 * length + 1 }) |count| {
                for (&rows) |*row| row.count = 0;
                for (rows[prefix..][0..count]) |*row| {
                    row.count = 1;
                    row.items[0] = .{ .length = @intCast(length), .distance = 7 };
                }
                // Price equality can split a metadata run but cannot produce one. Strictly more
                // than twice the maximum length is necessary regardless of run position.
                try std.testing.expectEqual(count > 2 * length, mayReusePricing(&rows));
                if (count <= 2 * length) continue;
                const middle = prefix + count / 2;
                rows[middle].items[0].distance = 8;
                try std.testing.expect(!mayReusePricing(&rows));
                rows[middle].items[0].distance = 7;
                rows[middle].items[0].length -= 1;
                try std.testing.expect(!mayReusePricing(&rows));
                rows[middle].items[0].length += 1;
                rows[middle].count = 2;
                try std.testing.expect(!mayReusePricing(&rows));
                rows[middle].count = 0;
                try std.testing.expect(!mayReusePricing(&rows));
            }
        }
    }
}

test "pricing prefilter admits real runs and permits price false positives" {
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{});
    encoder.history = 0;
    encoder.buffered = 71;
    for (workspace.matches[0..encoder.buffered], 0..) |*row, position| {
        row.count = 1;
        row.items[0] = .{ .length = 35, .distance = 7 };
        workspace.data[position] = if (position % 2 == 0) 'A' else 'B';
    }
    var prices: [286]u32 = @splat(3);
    const matches = workspace.matches[0..encoder.buffered];
    try std.testing.expect(mayReusePricing(matches));
    // A long run with equal literal prices can trigger actual reuse; changing literal prices can
    // split the same metadata run. The prefilter deliberately keeps this safe false positive.
    try std.testing.expect(PriceRun.find(&encoder, 70, &prices).maximum != 0);
    prices['B'] = 4;
    try std.testing.expectEqual(@as(usize, 0), PriceRun.find(&encoder, 70, &prices).maximum);
    try std.testing.expect(mayReusePricing(matches));
}

test "frequency selection equals direct token bit accounting" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var tokens: [512]Token = undefined;
    for (0..6) |pattern| {
        for (&tokens, 0..) |*token, i| {
            if ((i + pattern) % 4 == 0) {
                token.* = .{ .length = 0, .value = @intCast((i * 13 + pattern * 29) % 256) };
            } else {
                token.* = .{
                    .length = @intCast(3 + (i * 67 + pattern * 43) % 256),
                    .value = @intCast(1 + (i * 1877 + pattern * 6571) % 32768),
                };
            }
        }
        for ([_]usize{ 0, 1, 7, 64, 257, 512 }) |size| {
            const selected = tokens[0..size];
            var bytes: usize = 0;
            for (selected) |token| bytes += @max(1, token.length);
            try std.testing.expect(bytes <= 65535);
            for (0..8) |bit_offset| {
                try encoder.reset(workspace, .{});
                const actual = try encoder.select(selected, bytes, @intCast(bit_offset));
                const full_work = encoder.counts().work_units;
                const header = &workspace.header;
                var dynamic: u32 = 3 + header.bits + header.literal.widths[256];
                var fixed: u32 = 3 + 7;
                // Calculate directly from every token instead of multiplying frequencies.
                for (selected) |token| {
                    if (token.length == 0) {
                        dynamic += header.literal.widths[token.value];
                        fixed += fixedWidth(token.value);
                    } else {
                        const l = lengthSlot(token.length);
                        const d = distanceSlot(token.value);
                        const symbol = 257 + @as(usize, l);
                        const extras = @as(u32, length_extra[l]) + distance_extra[d];
                        dynamic += header.literal.widths[symbol] + @as(
                            u32,
                            header.distance.widths[d],
                        ) + extras;
                        fixed += fixedWidth(symbol) + @as(u32, 5) + extras;
                    }
                }
                const padding = (8 - (@as(u32, @intCast(bit_offset)) + 3) % 8) % 8;
                const stored: u32 = @intCast(3 + padding + 32 + bytes * 8);
                var expected: Selection = .{
                    .bits = stored,
                    .kind = .stored,
                    .dynamic_bits = dynamic,
                };
                if (fixed < expected.bits) expected = .{
                    .bits = fixed,
                    .kind = .fixed,
                    .dynamic_bits = dynamic,
                };
                if (dynamic < expected.bits) expected = .{
                    .bits = dynamic,
                    .kind = .dynamic,
                    .dynamic_bits = dynamic,
                };
                try std.testing.expectEqual(expected, actual);
                try std.testing.expect(full_work > 0);
                for ([_]u64{ full_work - 1, full_work }) |budget| {
                    try encoder.reset(workspace, .{ .limits = .{ .work_units = budget } });
                    const limited = encoder.select(selected, bytes, @intCast(bit_offset));
                    if (budget == full_work) {
                        try std.testing.expectEqual(expected, try limited);
                        try std.testing.expectEqual(full_work, encoder.counts().work_units);
                    } else {
                        try std.testing.expectError(error.LimitExceeded, limited);
                        try std.testing.expect(encoder.counts().work_units <= budget);
                    }
                }
            }
        }
    }
}

test "bounded books retain widths and work with ordinary-tree fast path" {
    // Expected widths come from an independent package-list construction. Equal weights exercise
    // deterministic symbol ties; the Fibonacci cases exceed the 7- and 15-bit bounds respectively.
    const Case = struct { frequencies: []const u32, widths: []const u8, maximum: u8 };
    const cases = [_]Case{ .{ .frequencies = &.{
        1, 1,
    }, .widths = &.{
        1, 1,
    }, .maximum = 7 }, .{ .frequencies = &.{
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    }, .widths = &.{
        4, 4, 4, 4, 3, 3, 3, 3, 3, 3,
    }, .maximum = 7 }, .{ .frequencies = &.{
        1, 1, 1, 2, 2, 3, 3, 5, 8,
    }, .widths = &.{
        5, 5, 4, 4, 4, 3, 3, 2, 2,
    }, .maximum = 7 }, .{ .frequencies = &.{
        0, 1, 1, 2, 0, 3, 5, 8, 13,
    }, .widths = &.{
        0, 6, 6, 5, 0, 4, 3, 2, 1,
    }, .maximum = 7 }, .{ .frequencies = &.{
        1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610,
    }, .widths = &.{
        7, 7, 7, 7, 7, 7, 6, 5, 5, 4, 4, 3, 3, 2, 2,
    }, .maximum = 7 }, .{ .frequencies = &.{
        1,     1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610, 987, 1597, 2584, 4181, 6765,
        10946,
    }, .widths = &.{
        15, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 6, 6, 5, 5, 4, 4, 3, 3, 2, 2,
    }, .maximum = 15 } };
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    for (cases) |case| {
        try encoder.reset(workspace, .{});
        var expected: Book = undefined;
        try encoder.makeBook(case.frequencies, case.maximum, &expected);
        try std.testing.expectEqualSlices(u8, case.widths, expected.widths[0..case.widths.len]);
        const full_work = encoder.counts().work_units;
        try std.testing.expect(full_work > 0);
        for ([_]u64{ 0, full_work - 1, full_work }) |budget| {
            try encoder.reset(workspace, .{ .limits = .{ .work_units = budget } });
            var actual: Book = undefined;
            const result = encoder.makeBook(case.frequencies, case.maximum, &actual);
            if (budget == full_work) {
                try result;
                try std.testing.expectEqual(expected, actual);
                try std.testing.expectEqual(full_work, encoder.counts().work_units);
            } else {
                try std.testing.expectError(error.LimitExceeded, result);
                try std.testing.expectEqual(expected.widths, actual.widths);
                try std.testing.expect(encoder.counts().work_units <= budget);
            }
        }
    }
}

test "bounded books minimize weighted cost for small frequency sets" {
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    try encoder.reset(workspace, .{});
    const weights = [_]u32{ 0, 1, 2, 5 };
    for (0..1024) |set| {
        var frequencies: [5]u32 = undefined;
        var value = set;
        var active: usize = 0;
        for (&frequencies) |*frequency| {
            frequency.* = weights[value % weights.len];
            value /= weights.len;
            if (frequency.* != 0) active += 1;
        }
        var book: Book = undefined;
        try encoder.makeBook(&frequencies, 3, &book);
        var cost: u32 = 0;
        var mass: u32 = 0;
        for (frequencies, 0..) |frequency, i| {
            const width = book.widths[i];
            if (frequency != 0) {
                try std.testing.expect(width >= 1 and width <= 3);
                cost += frequency * width;
                mass += @as(u32, 1) << @as(u5, @intCast(3 - width));
            } else if (active != 0 or i != 0) {
                try std.testing.expectEqual(0, width);
            }
        }
        if (active <= 1) {
            if (active == 0) {
                try std.testing.expectEqual(@as(u8, 1), book.widths[0]);
                try std.testing.expectEqual(@as(u16, 0), book.codes[0]);
            }
            try std.testing.expectEqual(@as(u32, if (active == 1) 4 else 0), mass);
            continue;
        }
        try std.testing.expectEqual(@as(u32, 8), mass);
        // Enumerate legal lengths independently of either tree-building algorithm.
        var possibilities: usize = 1;
        for (0..active) |_| possibilities *= 3;
        var best: u32 = std.math.maxInt(u32);
        for (0..possibilities) |assignment| {
            var rest = assignment;
            var candidate_mass: u32 = 0;
            var candidate_cost: u32 = 0;
            for (frequencies) |frequency| {
                if (frequency == 0) continue;
                const width: u5 = @intCast(rest % 3 + 1);
                rest /= 3;
                candidate_mass += @as(u32, 1) << (3 - width);
                candidate_cost += frequency * width;
            }
            if (candidate_mass == 8) best = @min(best, candidate_cost);
        }
        try std.testing.expectEqual(best, cost);
    }
}

test "offline tree retains correct matches across slab tails" {
    // A truncated tail once broke tree prefix reuse and produced an invalid match for this input.
    const Xorshift = struct {
        state: u32 = 10,

        fn next(self: *@This()) u32 {
            self.state ^= self.state << 13;
            self.state ^= self.state >> 17;
            self.state ^= self.state << 5;
            return self.state;
        }
    };
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 131073);
    defer allocator.free(source);
    var random: Xorshift = .{};
    var phrase: [257]u8 = undefined;
    for (&phrase) |*byte| byte.* = @truncate(random.next() >> 24);
    for (source, 0..) |*byte, i| {
        const roll = random.next();
        byte.* = if (roll & 31 == 0) @truncate(random.next() >> 24) else phrase[i % phrase.len];
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    try std.testing.expectEqualSlices(u8, &.{
        0x76, 0x0b, 0xda, 0xae, 0x3d, 0x16, 0x6b, 0xeb,
        0x0f, 0x64, 0xd9, 0x52, 0x30, 0xe5, 0x36, 0x19,
        0x36, 0x5c, 0xf7, 0x23, 0xe7, 0xba, 0x9f, 0x07,
        0x8e, 0x1c, 0x03, 0x1a, 0x7c, 0x84, 0xaf, 0xed,
    }, &digest);

    const encoding = try EncoderWorkspace.create(allocator);
    defer encoding.destroy(allocator);
    const wire = try allocator.alloc(u8, try encodeBound(source.len));
    defer allocator.free(wire);
    const decoding = @import("decode.zig");
    const decoder = try decoding.DecoderWorkspace.create(allocator);
    defer decoder.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const restored = try allocator.alloc(u8, source.len);
    defer allocator.free(restored);

    var encoder: Encoder = undefined;
    try encoder.reset(encoding, .{ .compression = .{ .level = 9 } });
    const complete = try encoder.step(source, wire, .finish);
    try std.testing.expectEqual(.complete, complete.status);
    const full_work = encoder.counts().work_units;
    try std.testing.expect(full_work > 1);
    const result = try decoding.decode(
        wire[0..complete.produced],
        restored,
        .{ .workspace = decoder, .history = history },
        .{ .output_size = .exact, .trailing_data = .reject },
    );
    try std.testing.expectEqual(source.len, result.produced);
    try std.testing.expect(std.mem.eql(u8, source, restored));

    // Refusal may leave a partially used checkpoint. The same owner and workspace must require
    // reset and then produce a valid stream again at every selected work boundary.
    for ([_]u64{ 0, full_work / 2, full_work - 1 }) |limit| {
        try encoder.reset(
            encoding,
            .{ .compression = .{ .level = 9 }, .limits = .{ .work_units = limit } },
        );
        try std.testing.expectError(error.LimitExceeded, encoder.step(source, wire, .finish));
        try std.testing.expect(encoder.counts().work_units <= limit);
        try std.testing.expectError(error.NeedReset, encoder.step("", &.{}, .finish));
        try encoder.reset(encoding, .{ .compression = .{ .level = 9 } });
        const reused = try encoder.step(source, wire, .finish);
        try std.testing.expectEqual(.complete, reused.status);
        try std.testing.expectEqual(full_work, encoder.counts().work_units);
        _ = try decoding.decode(
            wire[0..reused.produced],
            restored,
            .{ .workspace = decoder, .history = history },
            .{ .output_size = .exact, .trailing_data = .reject },
        );
        try std.testing.expect(std.mem.eql(u8, source, restored));
    }
}

test "retained coordinates rebuild at an artificial epoch rollover" {
    const decoding = @import("decode.zig");
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, 131073);
    defer allocator.free(input);
    for (input, 0..) |*byte, i| byte.* = @truncate((i *% 73 +% i / 11) ^ (i / 17));
    const output = try allocator.alloc(u8, try encodeBound(input.len) + 64);
    defer allocator.free(output);
    const restored = try allocator.alloc(u8, input.len);
    defer allocator.free(restored);
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const decoder = try decoding.DecoderWorkspace.create(allocator);
    defer decoder.destroy(allocator);
    const cycle: u64 = 1 << 31;
    for ([_]u64{ cycle - 65535, cycle - 32768, cycle - 100, cycle + 98303 }) |initial| {
        var encoder: Encoder = undefined;
        try encoder.reset(
            workspace,
            .{ .compression = .{ .level = 9, .offline_pricing = .maximum_lengths } },
        );
        // The initial history is empty; the synthetic count moves only the coordinate epoch.
        encoder.stats.input_bytes = initial;
        const first = try encoder.step(input[0..65535], output, .process);
        try std.testing.expectEqual(@as(usize, 65535), first.consumed);
        var read = first.consumed;
        var written = first.produced;
        while (true) {
            const part = try encoder.step(input[read..], output[written..], .finish);
            read += part.consumed;
            written += part.produced;
            if (part.status == .complete) break;
            try std.testing.expect(part.consumed + part.produced > 0);
        }
        try std.testing.expectEqual(input.len, read);
        try std.testing.expectEqual(initial + input.len, encoder.counts().input_bytes);
        const decoded = try decoding.decode(
            output[0..written],
            restored,
            .{ .workspace = decoder },
            .{ .output_size = .exact, .trailing_data = .reject },
        );
        try std.testing.expectEqual(input.len, decoded.produced);
        try std.testing.expectEqualSlices(u8, input, restored);
    }
}

test "empty flush before the first data block preserves dictionary behavior" {
    const decoding = @import("decode.zig");
    const allocator = std.testing.allocator;
    const workspace = try EncoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const decoder = try decoding.DecoderWorkspace.create(allocator);
    defer decoder.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const dictionary = "dictionary payload: repeated content for retained tree matching ";
    const input = try allocator.alloc(u8, 90000);
    defer allocator.free(input);
    for (input, 0..) |*byte, i| byte.* = dictionary[i % dictionary.len];
    const output = try allocator.alloc(u8, try encodeBound(input.len) + 128);
    defer allocator.free(output);
    const restored = try allocator.alloc(u8, input.len);
    defer allocator.free(restored);
    for ([_]EncodeAction{ .flush, .full_flush }) |action| {
        var encoder: Encoder = undefined;
        try encoder.reset(workspace, .{ .dictionary = dictionary, .compression = .{ .level = 9 } });
        const initial = try encoder.step(&.{}, output, action);
        try std.testing.expectEqual(.flushed, initial.status);
        var read: usize = 0;
        var written = initial.produced;
        while (true) {
            const part = try encoder.step(input[read..], output[written..], .finish);
            read += part.consumed;
            written += part.produced;
            if (part.status == .complete) break;
            try std.testing.expect(part.consumed + part.produced > 0);
        }
        try std.testing.expectEqual(input.len, read);
        const decoded = try decoding.decode(
            output[0..written],
            restored,
            .{ .workspace = decoder, .history = history },
            .{ .dictionary = dictionary, .output_size = .exact, .trailing_data = .reject },
        );
        try std.testing.expectEqual(input.len, decoded.produced);
        try std.testing.expectEqualSlices(u8, input, restored);
    }
}

test "retained search protects guarded poisoned workspace across failure and reuse" {
    const decoding = @import("decode.zig");
    const allocator = std.testing.allocator;
    const alignment = std.mem.Alignment.of(EncoderWorkspace);
    const margin = @max(64, @alignOf(EncoderWorkspace));
    const size = @sizeOf(EncoderWorkspace);
    const bytes = try allocator.alignedAlloc(u8, alignment, size + 2 * margin);
    defer allocator.free(bytes);
    const workspace: *EncoderWorkspace = @ptrCast(@alignCast(bytes[margin..].ptr));
    const guards: [margin]u8 = @splat(0xa5);
    const decoder = try decoding.DecoderWorkspace.create(allocator);
    defer decoder.destroy(allocator);
    const history = try allocator.create([32768]u8);
    defer allocator.destroy(history);
    const input = try allocator.alloc(u8, 131073);
    defer allocator.free(input);
    for (input, 0..) |*byte, i| byte.* = @truncate((i *% 73 +% i / 11) ^ (i / 17));
    const output = try allocator.alloc(u8, try encodeBound(input.len) + 128);
    defer allocator.free(output);
    const restored = try allocator.alloc(u8, input.len);
    defer allocator.free(restored);
    const dictionary = "a copied dictionary for exercising guarded history";
    for ([_]usize{ 256, 32768 }) |window| {
        @memset(bytes, 0xa5);
        var encoder: Encoder = undefined;
        const options: EncodeOptions = .{
            .dictionary = dictionary,
            .window_bytes = window,
            .compression = .{ .level = 9 },
        };
        try encoder.reset(workspace, options);
        const result = try encoder.step(input, output, .finish);
        try std.testing.expectEqual(.complete, result.status);
        const decoded = try decoding.decode(
            output[0..result.produced],
            restored,
            .{ .workspace = decoder, .history = history },
            .{
                .dictionary = dictionary,
                .window_bytes = window,
                .output_size = .exact,
                .trailing_data = .reject,
            },
        );
        try std.testing.expectEqual(input.len, decoded.produced);
        try std.testing.expectEqualSlices(u8, input, restored);
        try std.testing.expectEqualSlices(u8, &guards, bytes[0..margin]);
        try std.testing.expectEqualSlices(u8, &guards, bytes[margin + size ..]);
        var limited = options;
        limited.limits.work_units = 0;
        try encoder.reset(workspace, limited);
        try std.testing.expectError(error.LimitExceeded, encoder.step(input, output, .finish));
        try std.testing.expectError(error.NeedReset, encoder.step(&.{}, output, .finish));
        try std.testing.expectEqualSlices(u8, &guards, bytes[0..margin]);
        try std.testing.expectEqualSlices(u8, &guards, bytes[margin + size ..]);
        try encoder.reset(workspace, options);
        const reused = try encoder.step(input, output, .finish);
        try std.testing.expectEqual(.complete, reused.status);
        _ = try decoding.decode(
            output[0..reused.produced],
            restored,
            .{ .workspace = decoder, .history = history },
            .{
                .dictionary = dictionary,
                .window_bytes = window,
                .output_size = .exact,
                .trailing_data = .reject,
            },
        );
        try std.testing.expectEqualSlices(u8, input, restored);
        try std.testing.expectEqualSlices(u8, &guards, bytes[0..margin]);
        try std.testing.expectEqualSlices(u8, &guards, bytes[margin + size ..]);
    }
}
