//! Acclaim's owned data, borrowed views and explicit channel identities.
const std = @import("std");

/// Unit used by stored axis angles or motion rotation channels.
pub const AngleUnit = enum { degrees, radians };

/// Order of fixed-axis rotations; XYZ applies X, then Y, then Z to a column vector.
pub const RotationOrder = enum { xyz, xzy, yxz, yzx, zxy, zyx };

/// One motion value's meaning. `l` is a stored length channel, not a rotation.
pub const Channel = enum { tx, ty, tz, rx, ry, rz, l };

/// Editing limits from ASF; they do not clamp or invalidate motion samples.
pub const Range = struct { lower: f64, upper: f64 };

/// Declared metadata. Optional mass/length scalars do not identify universal SI units.
pub const Units = struct { mass: ?f64 = null, length: ?f64 = null, angle: AngleUnit };

/// One named segment. Index zero is root (ID zero); nonroot IDs are independent of array indices.
/// Fields describe file coordinates. Root `axis` is its orientation and `position` its static
/// position; nonroot position is supplied by the parent segment's direction and length. Keep parsed
/// records immutable while any skeleton view or motion uses them.
pub const Bone = struct {
    id: u32 = 0,
    name: []const u8 = "root",
    /// Parent's index in `Skeleton.bones`, or null for root; this is not the parent's ASF ID.
    parent: ?u32 = null,
    direction: [3]f64 = .{ 0, 0, 0 },
    length: f64 = 0,
    position: [3]f64 = .{ 0, 0, 0 },
    axis: [3]f64 = .{ 0, 0, 0 },
    axis_order: RotationOrder = .xyz,
    dofs: [7]Channel = @splat(.rx),
    dof_count: u8 = 0,
    /// First value for this segment in each sample's channel array.
    channel_offset: u32 = 0,
    limits: [7]?Range = @splat(null),

    /// Ordered channel meanings for this segment's AMC values.
    pub fn channelOrder(self: *const Bone) []const Channel {
        return self.dofs[0..self.dof_count];
    }
};

/// Immutable skeleton backing borrowed from a live `Skeleton`. Views and motions expire when their
/// source owner is released or modified. Construct views through `Skeleton.view`.
pub const SkeletonView = struct {
    bones: []const Bone,
    topology: []const u32,
    units: Units,
    channel_count: u32,

    /// Finds an exact case-sensitive name, including the implicit `root` at index zero.
    pub fn findBone(self: SkeletonView, name: []const u8) ?u32 {
        for (self.bones, 0..) |bone, index| {
            if (std.mem.eql(u8, bone.name, name)) return @intCast(index);
        }
        return null;
    }
};

/// Owns the copied ASF source, segment records and parent-before-child traversal order. Copies of
/// this descriptor alias ownership; release exactly once through the original allocator.
pub const Skeleton = struct {
    source: []const u8,
    bones: []const Bone,
    topology: []const u32,
    units: Units,
    name: []const u8,
    documentation: []const u8,
    channel_count: u32,

    /// Borrows immutable identity/channel/geometry data for one or more motion clips.
    pub fn view(self: *const Skeleton) SkeletonView {
        return .{
            .bones = self.bones,
            .topology = self.topology,
            .units = self.units,
            .channel_count = self.channel_count,
        };
    }

    /// Releases owned backing. Every borrowed view, name and motion becomes invalid.
    pub fn deinit(self: *Skeleton, allocator: std.mem.Allocator) void {
        allocator.free(self.topology);
        allocator.free(self.bones);
        allocator.free(self.source);
        self.* = undefined;
    }
};

/// A numbered sample borrowing a motion's dense values and its immutable skeleton.
/// Translation/length values retain source units; rotations use `angle_unit`.
pub const Sample = struct {
    number: u32,
    values: []const f64,
    skeleton: SkeletonView,
    angle_unit: AngleUnit,

    /// Borrows a segment's ordered values, or returns null for an invalid segment index.
    pub fn boneValues(self: Sample, bone_index: u32) ?[]const f64 {
        if (bone_index >= self.skeleton.bones.len) return null;
        const bone = self.skeleton.bones[bone_index];
        return self.values[bone.channel_offset..][0..bone.dof_count];
    }
};

/// Owns complete frame IDs, frame-major binary64 channel values and copied AMC header metadata.
/// Borrows skeleton backing until deinit. AMC source may retire immediately after parsing. Missing
/// segments in sparse files have already been carried forward; no interpolation is implied.
pub const Motion = struct {
    skeleton: SkeletonView,
    frame_numbers: []const u32,
    values: []const f64,
    header: []const u8,
    angle_unit: AngleUnit,
    fully_specified: bool,

    /// Borrows a sample by zero-based array position, independent of its original frame number.
    pub fn frame(self: *const Motion, index: usize) ?Sample {
        if (index >= self.frame_numbers.len) return null;
        const width = self.skeleton.channel_count;
        return .{
            .number = self.frame_numbers[index],
            .values = self.values[index * width ..][0..width],
            .skeleton = self.skeleton,
            .angle_unit = self.angle_unit,
        };
    }

    /// Releases this clip's backing using its construction allocator; leaves the skeleton alive.
    pub fn deinit(self: *Motion, allocator: std.mem.Allocator) void {
        allocator.free(self.header);
        allocator.free(self.values);
        allocator.free(self.frame_numbers);
        self.* = undefined;
    }
};
