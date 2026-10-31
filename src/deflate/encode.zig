//! Native RFC 1951 encoding, bounded match caching and offline parsing. The public namespace is
//! re-exported by deflate.zig. This implementation follows RFC 1951; package-merge constructs
//! optimal length-limited books. Iterative parsing and serialized cost selection were informed by:
//! https://github.com/ebiggers/libdeflate/blob/v1.26/lib/deflate_compress.c
//! https://github.com/google/zopfli/blob/zopfli-1.0.3/src/zopfli/squeeze.c No reference
//! implementation is called or linked by this library.

const std = @import("std");

const protocol = @import("format.zig");
const distance_base = protocol.distance_base;
const distance_extra = protocol.distance_extra;
const length_base = protocol.length_base;
const length_extra = protocol.length_extra;
const precode_order = protocol.precode_order;

const slab_bytes = 65535;
const window_bytes = 32768;
const alternatives = 16;
const no_position = std.math.maxInt(u32);
const no_symbol = std.math.maxInt(u16);

/// Encoder failure publishes no progress and poisons the owner until reset. Already returned output
/// remains a partial stream. No operation allocates.
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

/// Increasing encoder effort; all profiles produce ordinary RFC 1951 streams.
pub const EncodeProfile = enum {
    /// Byte-aligned uncompressed blocks, without match or entropy work.
    stored,
    /// Literal Huffman coding, without match search.
    huffman,
    /// Longest-match parsing with at most 32 chain probes per token position.
    greedy,
    /// One-position lazy parsing with at most 256 probes per token or lookahead position.
    lazy,
    /// Up to 4096 probes, 16 cached alternatives, eight pricing passes and four levels of
    /// cost-tested block splitting. Searches for smaller output with bounded effort and
    /// deterministic tie-breaking.
    offline,
};

/// Finite caller-selected bounds, cumulative across suspensions and flushes.
pub const EncodeLimits = struct {
    /// Accepted source bytes; dictionary bytes are excluded.
    input_bytes: u64 = std.math.maxInt(u64),
    /// Returned raw DEFLATE bytes.
    output_bytes: u64 = std.math.maxInt(u64),
    /// Match probes/comparisons, parser edges and book/header work units. This is an algorithmic
    /// bound, not an instruction or time count.
    work_units: u64 = std.math.maxInt(u64),
};

/// Raw encoding configuration. Optional dictionary history is copied during reset.
pub const EncodeOptions = struct {
    /// Optional preset dictionary, copied during reset; raw streams carry no dictionary identity.
    dictionary: ?[]const u8 = null,
    /// Offline size optimization is the default; encoding generally runs once.
    profile: EncodeProfile = .offline,
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
    /// Accepted source bytes, excluding dictionary bytes.
    input_bytes: u64 = 0,
    /// Returned raw wire bytes.
    output_bytes: u64 = 0,
    /// Charged algorithmic units, including all attempted parses and splits.
    work_units: u64 = 0,
    /// Hash-chain candidates visited.
    match_probes: u64 = 0,
    /// Shortest-path match-length edges considered.
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

const Match = struct { length: u16, distance: u16 };
const Matches = struct { items: [alternatives]Match, count: u8 };

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
const Selection = struct { bits: u32, kind: Kind };
const Segment = struct { first: usize, end: usize, start: usize, bytes: usize };

/// Exclusive bounded scratch, with no allocator retained. Construct directly at its final address
/// using create or caller storage. Encoder borrows it until reset/end of use. Contents are private
/// and initialized on demand. The fixed reservation is below 8 MiB on supported targets,
/// independent of stream length. Query @sizeOf/@alignOf for the selected target.
pub const EncoderWorkspace = struct {
    data: [window_bytes + slab_bytes]u8,
    heads: [65536]u32,
    previous: [window_bytes + slab_bytes]u32,
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

/// Persistent bounded encoder. Accepted input and returned output may retire after every step; no
/// caller input/output pointer or allocator is retained. Construct the owner at its final address
/// and serialize its exclusive workspace borrow. Errors require reset; reset abandons unpublished
/// pending wire bytes.
pub const Encoder = struct {
    workspace: *EncoderWorkspace,
    options: struct { profile: EncodeProfile, window_bytes: usize, limits: EncodeLimits },
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

    /// Initializes existing storage, copying optional dictionary history. Refuses invalid options
    /// and overlapping owner/scratch before mutation.
    pub fn reset(
        self: *Encoder,
        workspace: *EncoderWorkspace,
        options: EncodeOptions,
    ) EncodeError!void {
        try disjoint(std.mem.asBytes(self), std.mem.asBytes(workspace));
        if (options.window_bytes < 256 or options.window_bytes > window_bytes)
            return error.InvalidOptions;
        if (!std.math.isPowerOfTwo(options.window_bytes)) return error.InvalidOptions;
        self.* = .{
            .workspace = workspace,
            .options = .{
                .profile = options.profile,
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

    /// Returns copied byte/effort counters without exposing internal scratch.
    pub fn counts(self: *const Encoder) EncodeStats {
        return self.stats;
    }

    /// Processes one fragment. An empty output span may still accept input into scratch. A flush
    /// boundary is returned once; resume with a new operation. Complete is idempotent only with
    /// empty input and finish. Failure may change private output but publishes no progress and
    /// requires reset.
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
        if (self.options.profile != .huffman) try self.findMatches();
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

        var best_count = count;
        var best_bits = selection.bits;
        @memcpy(workspace.best[0..count], workspace.tokens[0..count]);
        fixedBook(&workspace.header.literal, false);
        fixedBook(&workspace.header.distance, true);
        for (0..8) |pass| {
            const literal_widths = workspace.header.literal.widths;
            const distance_widths = workspace.header.distance.widths[0..30].*;
            const work_before = self.stats.work_units;
            const edges_before = self.stats.parse_edges;
            count = try self.priceParse(&workspace.header.literal, &workspace.header.distance);
            selection = try self.select(workspace.tokens[0..count], self.buffered, self.bit_count);
            if (selection.bits < best_bits) {
                best_bits = selection.bits;
                best_count = count;
                @memcpy(workspace.best[0..count], workspace.tokens[0..count]);
            }
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
            // Stable books produce the same parse and serialized candidate in every later pass.
            // Charge their exact logical work together only when it all fits. Otherwise perform
            // normal passes to retain the original failure point and partial counters.
            const remaining: u64 = @intCast(7 - pass);
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

    fn findMatches(self: *Encoder) EncodeError!void {
        const workspace = self.workspace;
        @memset(&workspace.heads, no_position);
        const total = self.history + self.buffered;
        const depth: usize = switch (self.options.profile) {
            .greedy => 32,
            .lazy => 256,
            else => 4096,
        };
        const lazy = self.options.profile == .lazy;
        var next_search = self.history;
        var pending_length: usize = 0;
        for (0..total) |position| {
            if (total - position < 3) {
                if (position >= self.history) workspace.matches[position - self.history].count = 0;
                continue;
            }
            const hash = hash3(workspace.data[position..][0..3]);
            const candidate = workspace.heads[hash];
            workspace.previous[position] = candidate;
            workspace.heads[hash] = @intCast(position);
            if (position < self.history) continue;
            // Every position enters the chain, including bytes covered by an earlier match.
            // Greedy/lazy parsing only needs matches at the next token and its lazy lookahead.
            // Offline pricing can choose any position and retains the complete cache.
            if (self.options.profile != .offline and position < next_search) continue;
            const matches = &workspace.matches[position - self.history];
            matches.count = 0;
            const remaining = self.options.limits.work_units - self.stats.work_units;
            // One candidate plus at most 31 word comparisons fits this bound. Admit the whole
            // position when possible, otherwise check each charged operation. Both paths publish
            // identical exact counters.
            const measured = blk: {
                if (remaining >= depth * 34) {
                    break :blk try self.scanMatches(
                        false,
                        position,
                        total,
                        candidate,
                        depth,
                        remaining,
                    );
                }
                break :blk try self.scanMatches(true, position, total, candidate, depth, remaining);
            };
            try self.work(measured.units);
            self.stats.match_probes = try addCount(self.stats.match_probes, measured.probes);
            if (self.options.profile == .offline) continue;

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
    ) EncodeError!SearchStats {
        const workspace = self.workspace;
        const matches = &workspace.matches[position - self.history];
        const maximum = @min(258, total - position);
        const earliest = position -| self.options.window_bytes;
        const source = workspace.data[position..];
        var candidate = first;
        var longest: usize = 2;
        var measured: SearchStats = .{ .units = 0, .probes = 0 };
        while (candidate != no_position and candidate >= earliest and measured.probes < depth) {
            try searchWork(bounded, &measured.units, budget);
            measured.probes += 1;
            const candidate_position: usize = candidate;
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
            candidate = workspace.previous[candidate_position];
        }
        return measured;
    }

    inline fn searchWork(comptime bounded: bool, units: *u32, budget: u64) EncodeError!void {
        units.* += 1;
        if (bounded and units.* > budget) return error.LimitExceeded;
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

    fn priceParse(self: *Encoder, literal: *const Book, distance: *const Book) EncodeError!usize {
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
        var position = self.buffered;
        while (position != 0) {
            position -= 1;
            const value = workspace.data[self.history + position];
            var cost = literal_prices[value] + workspace.costs[position + 1];
            var choice: Token = .{ .length = 0, .value = value };
            const matches = &workspace.matches[position];
            if (matches.count != 0) {
                var suffix: [alternatives]u8 = undefined;
                var match_prices: [alternatives]u32 = undefined;
                for (matches.items[0..matches.count], 0..) |match, i| {
                    match_prices[i] = distance_prices[distanceSlot(match.distance)];
                }
                var i: usize = matches.count;
                var cheapest: usize = i - 1;
                while (i != 0) {
                    i -= 1;
                    if (match_prices[i] <= match_prices[cheapest]) cheapest = i;
                    suffix[i] = @intCast(cheapest);
                }
                const maximum = matches.items[matches.count - 1].length;
                // Charge every logical length edge, including those reduced as a range.
                try self.work(maximum - 2);
                self.stats.parse_edges = try addCount(self.stats.parse_edges, maximum - 2);
                var index: usize = 0;
                // The first sixteen price bands contain at most four lengths each. Direct scans
                // avoid range/reduction overhead for short matches.
                if (maximum < 35) {
                    for (3..@as(usize, maximum) + 1) |length| {
                        while (matches.items[index].length < length) index += 1;
                        const selected = suffix[index];
                        const match_price = length_prices[length] + match_prices[selected];
                        const candidate = match_price + workspace.costs[position + length];
                        if (candidate < cost) {
                            cost = candidate;
                            choice = .{
                                .length = @intCast(length),
                                .value = matches.items[selected].distance,
                            };
                        }
                    }
                } else {
                    var slot: usize = 0;
                    var length: usize = 3;
                    while (length <= maximum) {
                        while (matches.items[index].length < length) index += 1;
                        const selected = suffix[index];
                        const match = matches.items[selected];
                        // Length-code prices are constant within an RFC band. The cheapest usable
                        // distance stays selected until that match ends, including nearest ties.
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
            workspace.costs[position] = cost;
            workspace.choices[position] = choice;
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
        for (tokens) |token| {
            if (token.length == 0) {
                literal_frequencies[token.value] += 1;
            } else {
                literal_frequencies[257 + @as(usize, lengthSlot(token.length))] += 1;
                distance_frequencies[distanceSlot(token.value)] += 1;
            }
        }
        const header = &self.workspace.header;
        try self.makeBook(&literal_frequencies, 15, &header.literal);
        try self.makeBook(&distance_frequencies, 15, &header.distance);
        try self.makeHeader();
        var dynamic_bits: u32 = 3 + header.bits;
        var fixed_bits: u32 = 3 + 7;
        dynamic_bits += header.literal.widths[256];
        for (tokens) |token| {
            if (token.length == 0) {
                dynamic_bits += header.literal.widths[token.value];
                fixed_bits += fixedWidth(token.value);
            } else {
                const length_slot = lengthSlot(token.length);
                const distance_slot = distanceSlot(token.value);
                const length_symbol = 257 + @as(usize, length_slot);
                const length_payload_bits: u32 = length_extra[length_slot];
                const extras = length_payload_bits + distance_extra[distance_slot];
                const distance_code_bits: u32 = header.distance.widths[distance_slot];
                const code_bits = header.literal.widths[length_symbol] + distance_code_bits;
                dynamic_bits += code_bits + extras;
                fixed_bits += fixedWidth(length_symbol) + 5 + extras;
            }
        }
        const padding = (8 - (@as(u32, offset) + 3) % 8) % 8;
        const stored_bits: u32 = @intCast(3 + padding + 32 + bytes * 8);
        var best: Selection = .{ .bits = stored_bits, .kind = .stored };
        if (fixed_bits < best.bits) best = .{ .bits = fixed_bits, .kind = .fixed };
        if (dynamic_bits < best.bits) best = .{ .bits = dynamic_bits, .kind = .dynamic };
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
    } }, .{ .bytes = 131071, .full_prefixes = 2, .final_header = .{ 1, 1, 0, 254, 255 } } };
    for (cases) |case| {
        const wire_bytes = case.bytes + (case.full_prefixes + 1) * 5;
        for ([_]usize{ 256, 32768 }) |window| {
            var encoder: Encoder = undefined;
            try encoder.reset(
                workspace,
                .{
                    .profile = .stored,
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
    try encoder.reset(workspace, .{ .profile = .stored });
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

    try encoder.reset(workspace, .{ .profile = .stored });
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
                .profile = .stored,
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
        try encoder.reset(workspace, .{ .profile = .stored, .limits = limits });
        try std.testing.expectError(error.LimitExceeded, encoder.step("A", &output, .finish));
        try std.testing.expectError(error.NeedReset, encoder.step(&.{}, &output, .finish));
    }
    try encoder.reset(workspace, .{ .profile = .stored });
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
        fn check(encoder: *Encoder, literal: *const Book, distance: *const Book) !void {
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
                            if (match.length < length) continue;
                            const slot = distanceSlot(match.distance);
                            const bits = distance.widths[slot];
                            const candidate = @as(
                                u32,
                                if (bits == 0) 10 else bits,
                            ) + distance_extra[slot];
                            if (candidate < price or (candidate == price and match.distance <
                                nearest))
                            {
                                price = candidate;
                                nearest = match.distance;
                            }
                        }
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
            const count = try encoder.priceParse(literal, distance);
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
    };
    const workspace = try EncoderWorkspace.create(std.testing.allocator);
    defer workspace.destroy(std.testing.allocator);
    var encoder: Encoder = undefined;
    var literal: Book = undefined;
    var distance: Book = undefined;
    for ([_]usize{ 0, 1, 2, 3, 4, 8, 10, 11, 19, 35, 67, 131, 257, 258, 259, 768, 65535 }) |size| {
        const patterns: usize = if (size == 65535) 1 else 6;
        const pricings: usize = if (size == 65535) 1 else 4;
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
                            else => if (i == 'A') 1 else 3,
                        };
                    }
                    for (&distance.widths, 0..) |*width, i| {
                        width.* = switch (pricing) {
                            1 => 0,
                            2 => @intCast((i * 11 + 3) % 16),
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
                        const length = if (count == 1) maximum else 3 + (maximum - 3) * i / (count -
                            1);
                        match.* = .{
                            .length = @intCast(length),
                            .distance = if (pattern == 4) @intCast(
                                1 + i * 100,
                            ) else @as(u16, 1) << @intCast(i),
                        };
                    }
                    matches.count = @intCast(count);
                }
                try Reference.check(&encoder, &literal, &distance);
                if (size == 259 and pattern == 5 and pricing == 2) {
                    const units = encoder.counts().work_units;
                    for ([_]u64{ units, units - 1 }) |budget| {
                        try encoder.reset(workspace, .{ .limits = .{ .work_units = budget } });
                        encoder.history = window_bytes;
                        encoder.buffered = size;
                        if (budget == units) {
                            try Reference.check(&encoder, &literal, &distance);
                        } else {
                            try std.testing.expectError(
                                error.LimitExceeded,
                                encoder.priceParse(&literal, &distance),
                            );
                            try std.testing.expect(encoder.counts().work_units < units);
                        }
                    }
                }
            }
        }
    }
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
        try encoder.reset(workspace, .{});
        encoder.buffered = expected.len;
        try encoder.findMatches();
        const counters = encoder.counts();
        for (expected, workspace.matches[0..expected.len]) |*saved, matches| {
            saved.count = matches.count;
            @memcpy(saved.items[0..saved.count], matches.items[0..matches.count]);
        }
        try std.testing.expect(counters.work_units < 100000);
        try encoder.reset(workspace, .{ .limits = .{ .work_units = 100000 } });
        encoder.buffered = expected.len;
        try encoder.findMatches();
        try std.testing.expectEqual(counters, encoder.counts());
        for (expected, workspace.matches[0..expected.len]) |saved, matches| {
            try std.testing.expectEqual(saved.count, matches.count);
            for (saved.items[0..saved.count], matches.items[0..matches.count]) |a, b| {
                try std.testing.expectEqual(a.length, b.length);
                try std.testing.expectEqual(a.distance, b.distance);
            }
        }
        try encoder.reset(workspace, .{ .limits = .{ .work_units = counters.work_units - 1 } });
        encoder.buffered = expected.len;
        try std.testing.expectError(error.LimitExceeded, encoder.findMatches());
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
                inline for (.{ EncodeProfile.greedy, EncodeProfile.lazy }) |profile| {
                    const lazy = profile == .lazy;
                    const depth: usize = if (lazy) 256 else 32;
                    var count: usize = 0;
                    var position = history;
                    while (position < total) {
                        var match = Reference.longest(data, position, window, depth);
                        if (lazy and match.length != 0 and position + 1 < total) {
                            const next = Reference.longest(data, position + 1, window, depth);
                            if (next.length > match.length) match.length = 0;
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
                    try encoder.reset(workspace, .{ .profile = profile, .window_bytes = window });
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
                            .profile = profile,
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
                                .profile = profile,
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
                for ([_]EncodeProfile{ .greedy, .lazy }) |profile| {
                    const lazy = profile == .lazy;
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
                                .profile = profile,
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
