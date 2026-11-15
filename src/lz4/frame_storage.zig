//! Disjoint-storage admission for the frame encoder owner, block buffers and selected HC scratch.

const std = @import("std");
const byte_ranges = @import("../common/byte_ranges.zig");
const overlaps = byte_ranges.overlapsChecked;
const FrameEncodeWorkspace = @import("FrameEncodeWorkspace.zig");
const hc_encoder = @import("block.zig").encode.hc;

pub const Error = error{ Aliasing, SizeOverflow };

// The encoder mutates its owner and workspaces while borrowing the current caller span. Reject
// every overlap among those objects up front so staged bytes, hash tables and pending fields cannot
// overwrite one another during a later step.
pub fn checkEncoder(
    state: []const u8,
    workspace: *FrameEncodeWorkspace,
    hc_workspace: ?*hc_encoder.Workspace,
    bytes: []const u8,
) Error!void {
    const backing = std.mem.asBytes(workspace);
    if (hc_workspace) |scratch| {
        const memory = std.mem.asBytes(scratch);
        if (try overlaps(memory, state) or try overlaps(memory, backing)) return error.Aliasing;
        if (try overlaps(
            memory,
            workspace.input,
        ) or try overlaps(memory, workspace.encoded)) return error.Aliasing;
        if (try overlaps(memory, bytes)) return error.Aliasing;
    }
    if (try overlaps(state, backing)) return error.Aliasing;
    if (try overlaps(
        state,
        workspace.input,
    ) or try overlaps(state, workspace.encoded)) return error.Aliasing;
    if (try overlaps(
        backing,
        workspace.input,
    ) or try overlaps(backing, workspace.encoded)) return error.Aliasing;
    if (try overlaps(workspace.input, workspace.encoded)) return error.Aliasing;
    if (try overlaps(bytes, state) or try overlaps(bytes, backing)) return error.Aliasing;
    if (try overlaps(
        bytes,
        workspace.input,
    ) or try overlaps(bytes, workspace.encoded)) return error.Aliasing;
}
