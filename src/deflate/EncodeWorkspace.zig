//! Exclusive native encoder scratch, initialized on demand and borrowed until reset/end of use.
//! Construct at its final address. Allocation uses the exact typed size; no allocator is retained.
//! The fixed reservation is below 8 MiB on supported targets, independent of stream length. Query
//! @sizeOf/@alignOf for the selected target. Contents are private to the active encoder except its
//! explicit input/framing loans.

const std = @import("std");
const MatchFinder = @import("MatchFinder.zig");
const MatchCandidates = @import("MatchCandidates.zig");
const Token = @import("Lz77Parser.zig").Token;
const HuffmanCodebook = @import("HuffmanCodebook.zig");
const DynamicBlockHeader = @import("DynamicBlockHeader.zig");
const Segment = @import("BlockSelector.zig").Segment;
const search_bytes = MatchFinder.storage_bytes;
const search_alignment = MatchFinder.storage_alignment;

const EncodeWorkspace = @This();
const slab_bytes = 65535;
const window_bytes = 32768;

/// Copied history followed by the active input slab. Producer loans point into its unused suffix.
data: [window_bytes + slab_bytes]u8,
/// Shared chain/tree arena. The selected search profile determines its active interpretation.
search: [search_bytes]u8 align(search_alignment),
/// Ordered match candidates for each position of the active slab.
matches: [slab_bytes]MatchCandidates,
/// Suffix prices for offline parsing, including the end-of-slab entry.
costs: [slab_bytes + 1]u32,
/// The chosen next token at each source position during priced parsing.
choices: [slab_bytes]Token,
/// Current parse in source order.
tokens: [slab_bytes]Token,
/// Best parse retained across price-refinement passes and block splitting.
best: [slab_bytes]Token,
/// Pending encoded output, with room for final tokens and bounded wide stores. The initial framing
/// loan temporarily borrows this storage before raw encoding starts.
wire: [slab_bytes + 128]u8,
/// Shared length-limited Huffman construction scratch.
huffman: HuffmanCodebook.Scratch,
/// Candidate books/header, also supplying prices when stored or fixed wins.
header: DynamicBlockHeader,
/// One code-length repricing trial; never aliases the retained candidate header.
header_trial: DynamicBlockHeader,
/// At most sixteen token/source ranges selected by bounded recursive splitting.
segments: [16]Segment,

/// Reserves undefined scratch without creating a large temporary.
pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!*EncodeWorkspace {
    return allocator.create(EncodeWorkspace);
}

/// Releases scratch through its construction allocator after all borrows.
pub fn destroy(self: *EncodeWorkspace, allocator: std.mem.Allocator) void {
    allocator.destroy(self);
}

/// Erases retained input, history and parsing scratch after ending its use.
pub fn clear(self: *EncodeWorkspace) void {
    std.crypto.secureZero(u8, std.mem.asBytes(self));
}
