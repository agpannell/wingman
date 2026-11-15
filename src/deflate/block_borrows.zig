//! Assemble short-lived mechanism views from the stream's admitted slab and reservations. These
//! functions allocate nothing and retain no view. Algorithms receive their required spans and
//! counters; only this composition seam knows the stream's complete storage arrangement.

const std = @import("std");
const EncodeWorkBudget = @import("EncodeWorkBudget.zig");
const BlockWriter = @import("BlockWriter.zig");
const MatchFinder = @import("MatchFinder.zig");
const Lz77Parser = @import("Lz77Parser.zig");
const BlockSelector = @import("BlockSelector.zig");
const runs = @import("four_byte_runs.zig");
const BlockEncoder = @import("BlockEncoder.zig");

pub fn work(encoder: anytype) EncodeWorkBudget {
    return .{ .limit = encoder.options.limits.work_units, .stats = &encoder.stats };
}

pub fn writer(encoder: anytype) BlockWriter {
    return .{
        .data = &encoder.workspace.data,
        .history = encoder.history,
        .wire = &encoder.workspace.wire,
        .bits = &encoder.bits,
        .bit_count = &encoder.bit_count,
        .pending = &encoder.pending,
        .stats = &encoder.stats,
    };
}

pub fn search(encoder: anytype) MatchFinder {
    const workspace = encoder.workspace;
    return .{
        .data = &workspace.data,
        .history = encoder.history,
        .buffered = encoder.buffered,
        .input_bytes = encoder.stats.input_bytes,
        .depth = encoder.options.depth,
        .window = encoder.options.window_bytes,
        .lazy = encoder.options.profile == .lazy,
        .reduced_lookahead = encoder.options.reduced_lookahead,
        .search = &workspace.search,
        .matches = &workspace.matches,
        .checkpoint = .{
            std.mem.asBytes(&workspace.costs),
            std.mem.asBytes(&workspace.choices),
            std.mem.asBytes(&workspace.tokens),
            std.mem.asBytes(&workspace.best),
        },
        .work = work(encoder),
    };
}

pub fn parser(encoder: anytype) Lz77Parser {
    const workspace = encoder.workspace;
    return .{
        .source = workspace.data[encoder.history..][0..encoder.buffered],
        .literal_only = encoder.options.profile == .huffman,
        .matches = &workspace.matches,
        .costs = &workspace.costs,
        .choices = &workspace.choices,
        .tokens = &workspace.tokens,
        .work = work(encoder),
    };
}

pub fn selector(encoder: anytype) BlockSelector {
    const workspace = encoder.workspace;
    return .{
        .header = &workspace.header,
        .header_trial = &workspace.header_trial,
        .huffman = &workspace.huffman,
        .best = &workspace.best,
        .segments = &workspace.segments,
        .work = work(encoder),
    };
}

pub fn fourByteRuns(encoder: anytype) runs.BlockEncoder {
    return .{
        .data = &encoder.workspace.data,
        .history = encoder.history,
        .buffered = encoder.buffered,
        .wire = &encoder.workspace.wire,
        .bits = &encoder.bits,
        .bit_count = &encoder.bit_count,
        .pending = &encoder.pending,
        .work = work(encoder),
        .writer = writer(encoder),
    };
}

pub fn ordinary(encoder: anytype) BlockEncoder {
    return .{
        .buffered = encoder.buffered,
        .profile = encoder.options.profile,
        .pricing = encoder.options.offline_pricing,
        .refinement = encoder.options.offline_refinement,
        .search = search(encoder),
        .parser = parser(encoder),
        .selector = selector(encoder),
        .writer = writer(encoder),
        .work = work(encoder),
    };
}
