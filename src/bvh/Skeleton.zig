//! Retained BVH hierarchy: joint identities, static offsets and ordered channel meanings. A Motion
//! owns this descriptor's joint records and copied hierarchy text; release the complete Motion.
//! Descriptor copies and views alias that storage. Keep the descriptor and backing immutable while
//! any view or frame uses them. Positions retain file units and axes; rotations are in degrees.
const Skeleton = @This();

/// Joint records in source preorder, including roots and unnamed end sites. Parents precede
/// children.
joints: []const Joint,
/// Number of scalar channel values in every frame across all joints.
channel_count: u32,
/// Copied hierarchy prefix backing joint names; excludes the MOTION section. Owned by Motion.
source: []const u8,

/// One stored value's meaning. Position values retain source units; rotations are in degrees.
pub const Channel = enum { tx, ty, tz, rx, ry, rz };

/// One node in source preorder. A null name identifies an unanimated end site; every named node is
/// a joint, including roots. Names need not be unique. Keep records immutable while borrowed.
pub const Joint = struct {
    /// Case-sensitive name borrowed from the hierarchy text, or null for an end site.
    name: ?[]const u8,
    /// Parent array index, or null for each root. Parents always precede their children.
    parent: ?u32,
    /// Parent-relative static offset in file units and parent axes; root offsets use file axes.
    offset: [3]f64,
    /// Ordered channel meanings; only the first channel_count entries are active.
    channels: [6]Channel = @splat(.rx),
    /// Active channel count, at most six. End sites and other static joints use zero.
    channel_count: u8 = 0,
    /// First value for this joint in a frame's channel array; static joints consume no values.
    channel_offset: u32 = 0,

    /// Channel meanings in exactly the order used by each stored frame.
    pub fn channelOrder(self: *const Joint) []const Channel {
        return self.channels[0..self.channel_count];
    }
};

/// Borrows immutable joint records and names from a live Motion. Array indices identify joints,
/// including repeated names and unnamed end sites. Construct through Skeleton.view.
pub const View = struct {
    /// Borrowed source-preorder records, including unnamed end sites.
    joints: []const Joint,
    /// Required width of a frame's flat channel values.
    channel_count: u32,
};

/// Borrows immutable hierarchy/channel data until the owning Motion is released or modified.
pub fn view(self: *const Skeleton) View {
    return .{ .joints = self.joints, .channel_count = self.channel_count };
}
