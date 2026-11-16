//! Owns naturally aligned interleaved audio samples independently of encoded source and scratch.
//! The complete byte allocation includes alignment padding. Copies share ownership: release it
//! exactly once with the original allocator after every sample borrow retires. No allocator is
//! retained. Use View to describe samples borrowed from this owner or from caller storage.

const std = @import("std");
const Format = @import("Format.zig");
const Audio = @This();

/// Source frame rate in frames per second; no resampling is performed.
sample_rate: u32,
/// Interleaved sample values per frame, in source channel order.
channels: Format.Channels,
/// Mutable decoded samples within allocation. Retire immutable views before modifying them.
samples: []f32,
/// Complete owned byte reservation, including padding; release through deinit, not samples.
allocation: []u8,
/// Extensible speaker mask; null means ordinary WAVE, zero means unspecified speaker assignments.
channel_mask: ?u32 = null,

/// Borrowed interleaved audio with copied metadata. Samples may belong to an Audio owner or caller
/// storage. Keep them alive and unchanged while this view is in use. Copying a view copies its
/// borrow; it does not transfer ownership.
pub const View = struct {
    /// Frame rate in frames per second.
    sample_rate: u32,
    /// Interleaved sample values per frame, in source channel order.
    channels: Format.Channels,
    /// Borrowed complete frames; finite floating samples may lie outside [-1, 1].
    samples: []const f32,
    /// Extensible speaker mask; null means ordinary WAVE, zero means unspecified assignments.
    channel_mask: ?u32 = null,
};

/// Borrows immutable samples and copies metadata until the samples are modified or released.
pub fn view(self: Audio) View {
    return .{
        .sample_rate = self.sample_rate,
        .channels = self.channels,
        .samples = self.samples,
        .channel_mask = self.channel_mask,
    };
}

/// Releases the complete reservation, including padding, and invalidates every sample borrow.
pub fn deinit(self: *Audio, allocator: std.mem.Allocator) void {
    allocator.free(self.allocation);
    self.* = undefined;
}
