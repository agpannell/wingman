//! BVH joint identity, owned skeleton/motion data and immutable borrowed samples.
const std = @import("std");

/// One stored value's meaning. Position values retain source units; rotations are in degrees.
pub const Channel = enum { tx, ty, tz, rx, ry, rz };

/// One node in source preorder. A null name identifies an unanimated end site; every named node is
/// a joint, including roots. Names need not be unique. Keep records immutable while borrowed.
pub const Joint = struct {
    name: ?[]const u8,
    /// Parent array index, or null for each root. Parents always precede their children.
    parent: ?u32,
    /// Parent-relative static offset in source coordinates; a root's offset uses file axes.
    offset: [3]f64,
    channels: [6]Channel = @splat(.rx),
    channel_count: u8 = 0,
    /// First value for this joint in a sample's flat channel array; end sites consume no values.
    channel_offset: u32 = 0,

    /// Channel meanings in exactly the order used by each stored sample.
    pub fn channelOrder(self: *const Joint) []const Channel {
        return self.channels[0..self.channel_count];
    }
};

/// Borrows immutable joint records and names from a live skeleton. Array indices identify joints,
/// including repeated names and unnamed end sites. Construct through `Skeleton.view`.
pub const SkeletonView = struct { joints: []const Joint, channel_count: u32 };

/// Owns joint records and copied hierarchy text backing their names. `Motion` normally owns this
/// value; release its motion rather than releasing this nested skeleton separately. Copies alias
/// ownership. No allocator is retained.
pub const Skeleton = struct {
    joints: []const Joint,
    channel_count: u32,
    /// Complete owned hierarchy prefix; names borrow these bytes. It excludes the MOTION section.
    source: []const u8,

    /// Borrows immutable hierarchy/channel data until this skeleton is released or modified.
    pub fn view(self: *const Skeleton) SkeletonView {
        return .{ .joints = self.joints, .channel_count = self.channel_count };
    }

    /// Releases the joint records and copied text using their construction allocator.
    pub fn deinit(self: *Skeleton, allocator: std.mem.Allocator) void {
        allocator.free(self.joints);
        allocator.free(self.source);
        self.* = undefined;
    }
};

/// One sample borrowing the motion's immutable values and skeleton; `time` is seconds from frame
/// zero. Rotations remain degrees and positions remain in source coordinates and units.
pub const Sample = struct {
    index: u32,
    time: f64,
    values: []const f64,
    skeleton: SkeletonView,

    /// Borrows the named joint or end site's ordered values; returns null for an invalid index. End
    /// sites and other static joints return an empty slice.
    pub fn jointValues(self: Sample, joint_index: u32) ?[]const f64 {
        if (joint_index >= self.skeleton.joints.len) return null;
        const joint = self.skeleton.joints[joint_index];
        return self.values[joint.channel_offset..][0..joint.channel_count];
    }
};

/// Owns a skeleton and dense frame-major binary64 samples, independent of the original input.
/// Copies alias ownership; release once with `deinit(allocator)`. Views, names and samples expire
/// when the owner is released or modified. No interpolation, trimming or unit conversion is
/// implied.
pub const Motion = struct {
    skeleton: Skeleton,
    values: []const f64,
    frame_count: u32,
    /// Positive finite encoded interval in seconds, preserved without rounding to an assumed rate.
    frame_time: f64,

    /// Borrows a frame by zero-based index, or returns null beyond the recorded frames. Every
    /// sample time is finite. Static skeletons can have frames with empty channel arrays.
    pub fn frame(self: *const Motion, index: usize) ?Sample {
        if (index >= self.frame_count) return null;
        const channel_count = self.skeleton.channel_count;
        const frame_index: u32 = @intCast(index);
        const elapsed_intervals: f64 = @floatFromInt(index);
        const time = elapsed_intervals * self.frame_time;
        const frame_start = index * channel_count;
        return .{
            .index = frame_index,
            .time = time,
            .values = self.values[frame_start..][0..channel_count],
            .skeleton = self.skeleton.view(),
        };
    }

    /// Releases all backing through the allocator used by `parseAlloc`. Every borrowed view and
    /// owner copy expires, including views of the nested skeleton.
    pub fn deinit(self: *Motion, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        self.skeleton.deinit(allocator);
        self.* = undefined;
    }
};
