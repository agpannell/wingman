//! Prepared Acclaim motion interpretation into caller-owned segment transforms.
//!
//! ASF directions describe segments in the unrotated file axes. A segment's motion rotates those
//! axes about its proximal joint; its children start at its distal endpoint. Preparing the static
//! axis bases once lets many clips reuse the same calibration without repeating its trigonometry.
const std = @import("std");
const overlaps = @import("../common/byte_ranges.zig").overlaps;
const model = @import("model.zig");
const rigid = @import("../common/rigid_transform.zig");
const RigidTransform = rigid.RigidTransform;
const multiply = rigid.multiply;
const finite = RigidTransform.isFinite;

/// Interpretation of nonzero ASF root orientation. Both choices agree when that orientation is
/// zero.
pub const RootOrientation = enum {
    /// Compose the declared rest rotation with motion: `C * M`, as in McCann's native reader.
    rest,
    /// Use orientation as a rotation basis: `C * M * transpose(C)`, as in the published axis rule.
    basis,
};

/// Fixed interpretation for an evaluator; parsed metadata and channels remain unchanged.
pub const PoseOptions = struct {
    /// Positive finite multiplier for all offsets and translations. One preserves file units. CMU's
    /// metres convention can be selected explicitly with `0.0254 / skeleton.units.length.?`.
    length_scale: f64 = 1,
    root_orientation: RootOrientation = .rest,
};

/// Pose admission or arithmetic failure. Unsupported channels remain accessible through raw
/// samples.
pub const PoseError = error{
    InvalidScale,
    UnsupportedChannel,
    WrongSkeleton,
    InvalidSample,
    OutputTooSmall,
    AliasedStorage,
    NonFiniteResult,
};

const Matrix = [3][3]f64;
const identity_matrix = RigidTransform.identity.rotation;
const PreparedBone = struct { basis: Matrix, translation: [3]f64 };

/// Owns prepared axis bases and offsets; borrows the original immutable skeleton. It can evaluate
/// samples from any clip sharing that exact backing, including caller-created finite sample values.
/// Copies alias ownership. Do not modify its fields or skeleton; release once with the allocator
/// supplied to `initAlloc`, before releasing the skeleton. Evaluations allocate nothing and may run
/// concurrently with distinct destinations.
pub const PoseEvaluator = struct {
    skeleton: model.SkeletonView,
    prepared: []const PreparedBone,
    root_orientation: RootOrientation,
    length_scale: f64,

    /// Prepares a parsed skeleton once for repeated local or global pose evaluation. Rejects length
    /// channels and nonroot translations whose interpretation is not established by this profile.
    /// Root translations always add to the static position in file axes, independently of where
    /// translations appear among the ordered rotation channels. Axis angles use ASF units; each
    /// sample's rotations use its own angle unit. C denotes the static axis rotation and M the
    /// ordered sample rotation. Failure publishes no owner and frees partial work.
    pub fn initAlloc(
        allocator: std.mem.Allocator,
        skeleton: model.SkeletonView,
        options: PoseOptions,
    ) (std.mem.Allocator.Error || PoseError)!PoseEvaluator {
        if (!std.math.isFinite(options.length_scale) or options.length_scale <= 0) {
            return error.InvalidScale;
        }
        for (skeleton.bones, 0..) |bone, index| {
            for (bone.channelOrder()) |channel| switch (channel) {
                .l => return error.UnsupportedChannel,
                .tx, .ty, .tz => if (index != 0) return error.UnsupportedChannel,
                .rx, .ry, .rz => {},
            };
        }
        const prepared = try allocator.alloc(PreparedBone, skeleton.bones.len);
        errdefer allocator.free(prepared);
        const scale = options.length_scale;
        for (skeleton.bones, prepared) |bone, *out| {
            out.basis = axisRotation(bone.axis, bone.axis_order, skeleton.units.angle);
            if (bone.parent) |parent_index| {
                const parent = skeleton.bones[parent_index];
                for (0..3) |axis| {
                    out.translation[axis] = parent.direction[axis] * parent.length * scale;
                }
            } else {
                for (0..3) |axis| out.translation[axis] = bone.position[axis] * scale;
            }
            if (!finite(.{ .rotation = out.basis, .translation = out.translation })) {
                return error.NonFiniteResult;
            }
        }
        return .{
            .skeleton = skeleton,
            .prepared = prepared,
            .root_orientation = options.root_orientation,
            .length_scale = options.length_scale,
        };
    }

    test initAlloc {
        const source =
            \\:version 1.10
            \\:units
            \\ angle deg
            \\:root
            \\ order TX TY TZ RX RY RZ
            \\ axis XYZ
            \\ position 0 0 0
            \\ orientation 0 0 0
            \\:bonedata
            \\:hierarchy
            \\ begin
            \\ end
        ;
        const allocator = std.testing.allocator;
        var skeleton = try parseSkeletonAlloc(allocator, source, null, .{});
        defer skeleton.deinit(allocator);
        var motion = try @import(
            "motion.zig",
        ).parseMotionAlloc(
            allocator,
            ":DEGREES\n1\nroot 1 2 3 0 0 90\n",
            skeleton.view(),
            null,
            .{},
        );
        defer motion.deinit(allocator);
        var evaluator = try PoseEvaluator.initAlloc(allocator, skeleton.view(), .{});
        defer evaluator.deinit(allocator);
        var output: [1]RigidTransform = undefined;
        const pose = try evaluator.globalPoseInto(motion.frame(0).?, &output);
        try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, &pose[0].translation);
        const point = pose[0].transformPoint(.{ 1, 0, 0 });
        try std.testing.expectApproxEqAbs(@as(f64, 3), point[1], 1e-14);
    }

    /// Releases preparation storage, leaving the skeleton and clips alive. All evaluator copies
    /// expire.
    pub fn deinit(self: *PoseEvaluator, allocator: std.mem.Allocator) void {
        allocator.free(self.prepared);
        self.* = undefined;
    }

    /// Writes one `wingman.RigidTransform` per bone, including root, in declaration order. Its
    /// origin is the proximal joint; transform the scaled direction times length to obtain the
    /// distal endpoint. Root has no segment length. A nonroot rotation is `C * M * transpose(C)`;
    /// its translation is the scaled parent segment vector. Rotations apply in declared channel
    /// order, with the first rotation applied first. Returns the used destination prefix and leaves
    /// its tail untouched. Admission failures leave output unchanged; NonFiniteResult may leave a
    /// partial prefix. The used output prefix must not alias the evaluator, its prepared/skeleton
    /// backing or the sample's values.
    pub fn localPoseInto(
        self: *const PoseEvaluator,
        sample: model.Sample,
        destination: []RigidTransform,
    ) PoseError![]RigidTransform {
        const output = try self.admit(sample, destination);
        for (output, 0..) |*out, index| {
            const value = self.local(sample, index);
            if (!finite(value)) return error.NonFiniteResult;
            out.* = value;
        }
        return output;
    }

    /// Writes transforms into the root's file coordinate system, composing each parent with its
    /// child's local transform. Output indices still follow declaration order even when a parent
    /// was declared after its child. Shares localPoseInto's capacity, alias and failure contracts;
    /// a numeric failure may leave a partial set in hierarchy traversal order.
    pub fn globalPoseInto(
        self: *const PoseEvaluator,
        sample: model.Sample,
        destination: []RigidTransform,
    ) PoseError![]RigidTransform {
        const output = try self.admit(sample, destination);
        for (self.skeleton.topology) |index| {
            const value = self.local(sample, index);
            const result = if (self.skeleton.bones[index].parent) |parent| output[parent].compose(
                value,
            ) else value;
            if (!finite(result)) return error.NonFiniteResult;
            output[index] = result;
        }
        return output;
    }

    fn admit(
        self: *const PoseEvaluator,
        sample: model.Sample,
        destination: []RigidTransform,
    ) PoseError![]RigidTransform {
        const source = sample.skeleton;
        const skeleton = self.skeleton;
        const bones = skeleton.bones;
        const order = skeleton.topology;
        const same_bones = source.bones.ptr == bones.ptr and source.bones.len == bones.len;
        const same_order = source.topology.ptr == order.ptr and source.topology.len == order.len;
        const same_units = std.meta.eql(source.units, skeleton.units);
        const same_width = source.channel_count == skeleton.channel_count;
        if (!same_bones or !same_order or !same_units or !same_width) {
            return error.WrongSkeleton;
        }
        if (sample.values.len != skeleton.channel_count) return error.InvalidSample;
        if (destination.len < skeleton.bones.len) return error.OutputTooSmall;
        const output = destination[0..skeleton.bones.len];
        const bytes = std.mem.sliceAsBytes(output);
        const inputs = [_][]const u8{
            std.mem.asBytes(self),
            std.mem.sliceAsBytes(self.prepared),
            std.mem.sliceAsBytes(skeleton.bones),
            std.mem.sliceAsBytes(skeleton.topology),
            std.mem.sliceAsBytes(sample.values),
        };
        for (inputs) |input| {
            if (overlaps(bytes, input)) return error.AliasedStorage;
        }
        for (sample.values) |value| {
            if (!std.math.isFinite(value)) return error.InvalidSample;
        }
        return output;
    }

    fn local(self: *const PoseEvaluator, sample: model.Sample, index: usize) RigidTransform {
        const bone = self.skeleton.bones[index];
        const prepared = self.prepared[index];
        var result: RigidTransform = .{
            .rotation = identity_matrix,
            .translation = prepared.translation,
        };
        const values = sample.values[bone.channel_offset..][0..bone.dof_count];
        for (bone.channelOrder(), values) |channel, value| switch (channel) {
            .rx => rotate(&result.rotation, 0, radians(value, sample.angle_unit)),
            .ry => rotate(&result.rotation, 1, radians(value, sample.angle_unit)),
            .rz => rotate(&result.rotation, 2, radians(value, sample.angle_unit)),
            .tx, .ty, .tz => {},
            .l => unreachable,
        };
        if (index == 0 and self.root_orientation == .rest) {
            result.rotation = multiply(prepared.basis, result.rotation);
        } else if (bone.dof_count != 0) {
            const basis_times_motion = multiply(prepared.basis, result.rotation);
            result.rotation = multiplyTranspose(basis_times_motion, prepared.basis);
        }
        // The root's channels are positions in file axes, not sequential affine translations.
        if (index == 0) {
            for (bone.channelOrder(), values) |channel, value| switch (channel) {
                .tx => result.translation[0] += value * self.length_scale,
                .ty => result.translation[1] += value * self.length_scale,
                .tz => result.translation[2] += value * self.length_scale,
                .rx, .ry, .rz => {},
                .l => unreachable,
            };
        }
        return result;
    }
};

fn radians(value: f64, unit: model.AngleUnit) f64 {
    return if (unit == .degrees) value * (std.math.pi / 180.0) else value;
}

fn axisRotation(angles: [3]f64, order: model.RotationOrder, unit: model.AngleUnit) Matrix {
    const axes: [3]u2 = switch (order) {
        .xyz => .{ 0, 1, 2 },
        .xzy => .{ 0, 2, 1 },
        .yxz => .{ 1, 0, 2 },
        .yzx => .{ 1, 2, 0 },
        .zxy => .{ 2, 0, 1 },
        .zyx => .{ 2, 1, 0 },
    };
    var result = identity_matrix;
    for (axes) |axis| rotate(&result, axis, radians(angles[axis], unit));
    return result;
}

fn rotate(matrix: *Matrix, axis: u2, angle: f64) void {
    const sine = @sin(angle);
    const cosine = @cos(angle);
    const first: usize = switch (axis) {
        0 => 1,
        1 => 2,
        2 => 0,
        else => unreachable,
    };
    const second: usize = switch (axis) {
        0 => 2,
        1 => 0,
        2 => 1,
        else => unreachable,
    };
    for (0..3) |column| {
        const first_row = matrix[first][column];
        const second_row = matrix[second][column];
        matrix[first][column] = cosine * first_row - sine * second_row;
        matrix[second][column] = sine * first_row + cosine * second_row;
    }
}

fn multiplyTranspose(left: Matrix, right: Matrix) Matrix {
    var result: Matrix = undefined;
    for (0..3) |row| {
        for (0..3) |column| {
            result[row][column] = 0;
            for (0..3) |inner| result[row][column] += left[row][inner] * right[column][inner];
        }
    }
    return result;
}

const fixtures = @import("fixtures.zig");
const parseSkeletonAlloc = @import("skeleton.zig").parseSkeletonAlloc;

fn expectVector(expected: [3]f64, actual: [3]f64) !void {
    for (expected, actual) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-12);
}

fn expectMatrix(expected: Matrix, actual: Matrix) !void {
    for (expected, actual) |a, b| try expectVector(a, b);
}

test "pose origins, endpoint, channel order, scale and both root interpretations" {
    const allocator = std.testing.allocator;
    var skeleton = try parseSkeletonAlloc(allocator, fixtures.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    // TZ TX TY RZ RX RY, tip RY RX, base RZ. Static fixed lies between base and tip.
    const sample: model.Sample = .{ .number = 7, .skeleton = skeleton.view(), .values = &.{
        1, 2, 3, 90, 90, 0, 0, 0, 90,
    }, .angle_unit = .degrees };
    var evaluator = try PoseEvaluator.initAlloc(allocator, skeleton.view(), .{ .length_scale = 2 });
    defer evaluator.deinit(allocator);
    var output: [5]RigidTransform = @splat(RigidTransform.identity);
    const local = try evaluator.localPoseInto(sample, &output);
    try std.testing.expectEqual(@as(usize, 4), local.len);
    try std.testing.expectEqual(RigidTransform.identity, output[4]);
    const root: Matrix = .{ .{ 0, 0, 1 }, .{ 0, -1, 0 }, .{ 1, 0, 0 } };
    const x90: Matrix = .{ .{ 1, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 1, 0 } };
    try expectMatrix(root, local[0].rotation);
    try expectVector(.{ 6, 10, 8 }, local[0].translation);
    try expectMatrix(x90, local[2].rotation);
    try expectVector(.{ 0, 0, 0 }, local[2].translation);
    try expectMatrix(identity_matrix, local[3].rotation);
    try expectVector(.{ 4, 0, 0 }, local[3].translation);
    try expectVector(.{ 0, 2, 0 }, local[1].translation);
    const global = try evaluator.globalPoseInto(sample, &output);
    try expectVector(.{ 6, 10, 8 }, global[2].translation);
    try expectVector(.{ 6, 10, 12 }, global[3].translation);
    try expectVector(.{ 8, 10, 12 }, global[1].translation);
    try expectVector(.{ 8, 16, 12 }, global[1].transformPoint(.{ 0, 0, 6 }));
    var basis = try PoseEvaluator.initAlloc(
        allocator,
        skeleton.view(),
        .{ .length_scale = 2, .root_orientation = .basis },
    );
    defer basis.deinit(allocator);
    const alternate = try basis.localPoseInto(sample, &output);
    try expectMatrix(.{ .{ 0, 0, 1 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } }, alternate[0].rotation);
    try expectVector(.{ 6, 10, 8 }, alternate[0].translation);
}

test "all six axis orders use independent basis-vector literals" {
    // Independently rotate the three basis vectors by 30,45,60 degrees. These constants do not
    // depend on the evaluator's matrix helpers. Noncommuting rotations distinguish all six orders.
    const cases = [_]struct {
        order: []const u8,
        expected: Matrix,
    }{ .{ .order = "XYZ", .expected = .{ .{
        0.35355339059327384, -0.57322330470336313, 0.73919891974011653,
    }, .{
        0.61237243569579458, 0.73919891974011664, 0.2803300858899106,
    }, .{
        -0.70710678118654746, 0.35355339059327373, 0.61237243569579458,
    } } }, .{ .order = "XZY", .expected = .{ .{
        0.35355339059327384, -0.17677669529663703, 0.91855865354369171,
    }, .{
        0.8660254037844386, 0.43301270189221946, -0.25,
    }, .{
        -0.35355339059327379, 0.88388347648318433, 0.3061862178478974,
    } } }, .{ .order = "YXZ", .expected = .{ .{
        0.047367172745376662, -0.75, 0.65973960844117108,
    }, .{
        0.78914913099243145, 0.43301270189221946, 0.4355957403991576,
    }, .{
        -0.61237243569579447, 0.49999999999999994, 0.61237243569579458,
    } } }, .{ .order = "YZX", .expected = .{ .{
        0.35355339059327384, -0.8660254037844386, 0.35355339059327379,
    }, .{
        0.88388347648318444, 0.43301270189221946, 0.17677669529663687,
    }, .{
        -0.30618621784789724, 0.25, 0.91855865354369182,
    } } }, .{ .order = "ZXY", .expected = .{ .{
        0.65973960844117108, -0.43559574039915772, 0.61237243569579447,
    }, .{
        0.75, 0.43301270189221946, -0.49999999999999994,
    }, .{
        -0.047367172745376551, 0.78914913099243134, 0.61237243569579458,
    } } }, .{ .order = "ZYX", .expected = .{ .{
        0.35355339059327384, -0.61237243569579458, 0.70710678118654746,
    }, .{
        0.92677669529663687, 0.12682648404432229, -0.35355339059327373,
    }, .{
        0.12682648404432195, 0.7803300858899106, 0.61237243569579458,
    } } } };
    const allocator = std.testing.allocator;
    for (cases) |case| {
        const root_axis = try std.fmt.allocPrint(allocator, "axis {s}", .{case.order});
        defer allocator.free(root_axis);
        const ordered = try std.mem.replaceOwned(
            u8,
            allocator,
            fixtures.skeleton,
            "axis ZYX",
            root_axis,
        );
        defer allocator.free(ordered);
        const source = try std.mem.replaceOwned(
            u8,
            allocator,
            ordered,
            "orientation 0 0 90",
            "orientation 30 45 60",
        );
        defer allocator.free(source);
        var skeleton = try parseSkeletonAlloc(allocator, source, null, .{});
        defer skeleton.deinit(allocator);
        var evaluator = try PoseEvaluator.initAlloc(allocator, skeleton.view(), .{});
        defer evaluator.deinit(allocator);
        var output: [4]RigidTransform = undefined;
        const pose = try evaluator.localPoseInto(
            .{
                .number = 1,
                .skeleton = skeleton.view(),
                .values = &@as([9]f64, @splat(0)),
                .angle_unit = .degrees,
            },
            &output,
        );
        try expectMatrix(case.expected, pose[0].rotation);
    }
}

test "ASF radian axes and AMC degree override are independent" {
    const allocator = std.testing.allocator;
    const substitutions = [_][2][]const u8{ .{
        "angle deg", "angle rad",
    }, .{
        "orientation 0 0 90", "orientation 0 0 1.5707963267948966",
    }, .{
        "axis 0 90 0", "axis 0 1.5707963267948966 0",
    }, .{
        "axis 0 0 45", "axis 0 0 0.7853981633974483",
    } };
    var source = try allocator.dupe(u8, fixtures.skeleton);
    defer allocator.free(source);
    for (substitutions) |pair| {
        const next = try std.mem.replaceOwned(u8, allocator, source, pair[0], pair[1]);
        allocator.free(source);
        source = next;
    }
    var skeleton = try parseSkeletonAlloc(allocator, source, null, .{});
    defer skeleton.deinit(allocator);
    var evaluator = try PoseEvaluator.initAlloc(allocator, skeleton.view(), .{});
    defer evaluator.deinit(allocator);
    var motion = try @import(
        "motion.zig",
    ).parseMotionAlloc(
        allocator,
        ":DEGREES\n1\nroot 1 2 3 90 90 0\ntip 0 0\nbase 90\n",
        skeleton.view(),
        null,
        .{},
    );
    defer motion.deinit(allocator);
    var degrees: [4]RigidTransform = undefined;
    _ = try evaluator.globalPoseInto(motion.frame(0).?, &degrees);
    var radian_sample = motion.frame(0).?;
    radian_sample.values = &.{
        1,
        2,
        3,
        std.math.pi / 2.0,
        std.math.pi / 2.0,
        0,
        0,
        0,
        std.math.pi / 2.0,
    };
    radian_sample.angle_unit = .radians;
    var radian_output: [4]RigidTransform = undefined;
    const radians_pose = try evaluator.globalPoseInto(radian_sample, &radian_output);
    for (degrees, radians_pose) |a, b| {
        try expectMatrix(a.rotation, b.rotation);
        try expectVector(a.translation, b.translation);
    }
    try expectMatrix(.{ .{ 0, 0, 1 }, .{ 0, -1, 0 }, .{ 1, 0, 0 } }, degrees[0].rotation);
    try expectVector(.{ 4, 8, 6 }, degrees[1].transformPoint(.{ 0, 0, 3 }));
}

test "pose follows branches without assuming declaration or depth-first order" {
    const allocator = std.testing.allocator;
    const source = try std.mem.replaceOwned(
        u8,
        allocator,
        fixtures.skeleton,
        " root base\n base fixed\n fixed tip",
        " root fixed base\n base tip",
    );
    defer allocator.free(source);
    var skeleton = try parseSkeletonAlloc(allocator, source, null, .{});
    defer skeleton.deinit(allocator);
    var evaluator = try PoseEvaluator.initAlloc(allocator, skeleton.view(), .{});
    defer evaluator.deinit(allocator);
    var output: [4]RigidTransform = undefined;
    const pose = try evaluator.globalPoseInto(
        .{
            .number = 1,
            .skeleton = skeleton.view(),
            .values = &@as([9]f64, @splat(0)),
            .angle_unit = .degrees,
        },
        &output,
    );
    try expectVector(.{ 1, 2, 3 }, pose[3].translation);
    try expectVector(.{ 1, 4, 3 }, pose[1].translation);
}

const PreparationFixture = struct {
    pub fn run(allocator: std.mem.Allocator, skeleton: model.SkeletonView) !void {
        var evaluator = try PoseEvaluator.initAlloc(allocator, skeleton, .{});
        defer evaluator.deinit(allocator);
        var output: [4]RigidTransform = undefined;
        _ = try evaluator.globalPoseInto(
            .{
                .number = 1,
                .skeleton = skeleton,
                .values = &@as([9]f64, @splat(0)),
                .angle_unit = .degrees,
            },
            &output,
        );
    }
};

test "pose preparation releases storage on exhaustion and geometry overflow" {
    const allocator = std.testing.allocator;
    var skeleton = try parseSkeletonAlloc(allocator, fixtures.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    try std.testing.checkAllAllocationFailures(
        allocator,
        PreparationFixture.run,
        .{skeleton.view()},
    );
    try std.testing.expectError(
        error.NonFiniteResult,
        PoseEvaluator.initAlloc(
            allocator,
            skeleton.view(),
            .{ .length_scale = std.math.floatMax(f64) },
        ),
    );
    for ([_]f64{ 0, -1, std.math.inf(f64), std.math.nan(f64) }) |scale| {
        try std.testing.expectError(
            error.InvalidScale,
            PoseEvaluator.initAlloc(allocator, skeleton.view(), .{ .length_scale = scale }),
        );
    }
}

test "unsupported pose channels preserve their raw skeleton identity" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "dof l", "dof tx", "dof ty", "dof tz" }) |dof| {
        const source = try std.mem.replaceOwned(u8, allocator, fixtures.skeleton, "dof rz", dof);
        defer allocator.free(source);
        var skeleton = try parseSkeletonAlloc(allocator, source, null, .{});
        defer skeleton.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 1), skeleton.bones[2].dof_count);
        try std.testing.expectError(
            error.UnsupportedChannel,
            PoseEvaluator.initAlloc(allocator, skeleton.view(), .{}),
        );
    }
}

test "pose preflight rejects foreign samples, bad values, short and overlapping output" {
    const allocator = std.testing.allocator;
    var skeleton = try parseSkeletonAlloc(allocator, fixtures.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    var other = try parseSkeletonAlloc(allocator, fixtures.skeleton, null, .{});
    defer other.deinit(allocator);
    var evaluator = try PoseEvaluator.initAlloc(allocator, skeleton.view(), .{});
    defer evaluator.deinit(allocator);
    var sample: model.Sample = .{
        .number = 1,
        .skeleton = skeleton.view(),
        .values = &@as([9]f64, @splat(0)),
        .angle_unit = .degrees,
    };
    var output: [5]RigidTransform = @splat(RigidTransform.identity);
    try std.testing.expectError(
        error.OutputTooSmall,
        evaluator.globalPoseInto(sample, output[0..3]),
    );
    sample.skeleton = other.view();
    try std.testing.expectError(error.WrongSkeleton, evaluator.localPoseInto(sample, &output));
    sample.skeleton = skeleton.view();
    sample.values = &.{ 0, 0 };
    try std.testing.expectError(error.InvalidSample, evaluator.globalPoseInto(sample, &output));
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |value| {
        sample.values = &.{ 0, 0, 0, 0, 0, 0, 0, 0, value };
        try std.testing.expectError(error.InvalidSample, evaluator.localPoseInto(sample, &output));
    }
    for (output) |value| try std.testing.expectEqual(RigidTransform.identity, value);
    const overlapping: [*]const f64 = @ptrCast(&output);
    sample.values = overlapping[0..9];
    try std.testing.expectError(error.AliasedStorage, evaluator.globalPoseInto(sample, &output));
    sample.values = &@as([9]f64, @splat(0));
    const prepared: [*]RigidTransform = @ptrCast(@constCast(evaluator.prepared.ptr));
    try std.testing.expectError(
        error.AliasedStorage,
        evaluator.localPoseInto(sample, prepared[0..4]),
    );
}

test "global pose rejects finite local inputs whose accumulated positions overflow" {
    const allocator = std.testing.allocator;
    var skeleton = try parseSkeletonAlloc(allocator, fixtures.skeleton, null, .{});
    defer skeleton.deinit(allocator);
    var evaluator = try PoseEvaluator.initAlloc(
        allocator,
        skeleton.view(),
        .{ .length_scale = std.math.floatMax(f64) / 4 },
    );
    defer evaluator.deinit(allocator);
    const sample: model.Sample = .{ .number = 1, .skeleton = skeleton.view(), .values = &.{
        0, 2, 0, -90, 0, 0, 0, 0, 0,
    }, .angle_unit = .degrees };
    var output: [5]RigidTransform = @splat(RigidTransform.identity);
    _ = try evaluator.localPoseInto(sample, &output);
    @memset(&output, RigidTransform.identity);
    try std.testing.expectError(error.NonFiniteResult, evaluator.globalPoseInto(sample, &output));
    try std.testing.expectEqual(RigidTransform.identity, output[4]);
    for (output) |value| try std.testing.expect(finite(value));
}
