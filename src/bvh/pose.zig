//! BVH motion channels interpreted as local or global joint transforms in caller storage. Intrinsic
//! rotations postmultiply in the declared channel order. Position channels describe coordinates in
//! parent/file axes, independently of their position among rotation channels.
const std = @import("std");
const model = @import("model.zig");
const transforms = @import("../common/rigid_transform.zig");
const RigidTransform = transforms.RigidTransform;
const fixtures = @import("fixtures.zig");
const parseAlloc = @import("parse.zig").parseAlloc;

/// How an encoded position coordinate relates to the corresponding static offset coordinate.
pub const PositionChannels = enum {
    /// Add the sample to the offset, following the historical Biovision description.
    add_offset,
    /// Replace only the offset axes with position channels, as used by several BVH importers.
    replace_offset,
};

/// Explicit interpretation; parsing and stored samples remain unchanged.
pub const PoseOptions = struct {
    /// Positive finite multiplier for every offset and position channel. One keeps file units.
    length_scale: f64 = 1,
    position_channels: PositionChannels = .add_offset,
};

/// Admission failures leave output unchanged. Arithmetic overflow can leave a completed prefix.
pub const PoseError = error{
    InvalidScale,
    InvalidSample,
    OutputTooSmall,
    AliasedStorage,
    NonFiniteResult,
};

/// Writes one parent-relative `wingman.RigidTransform` per joint, including roots and end sites, in
/// source preorder. The origin is the joint's position; an end site is a real unnamed leaf with its
/// own offset and an identity local rotation. Keep the sample's parsed skeleton immutable.
/// Caller-created finite values with the skeleton's exact channel width are also supported; sample
/// index/time are not used for pose interpretation.
///
/// Rotation channels are degrees and compose intrinsically in their listed order: Z, X, Y gives
/// `Rz * Rx * Ry` for column vectors. Position channels add to or replace offsets according to
/// options, in parent axes, independently of intervening rotation channels. The scale affects
/// lengths, not rotations. No bone-alignment rotation or coordinate-system conversion is inferred.
///
/// Allocates/retains nothing. Returns the used prefix and leaves destination's tail unchanged. The
/// entire offered destination must be disjoint from joint records/names and sample values. Scale,
/// channel width, finite values, capacity and alias admission complete before any write.
/// NonFiniteResult may leave a completed prefix; the failing joint and remaining output stay
/// untouched. Binary64 arithmetic can overflow even when all source values are finite.
pub fn localPoseInto(
    sample: model.Sample,
    destination: []RigidTransform,
    options: PoseOptions,
) PoseError![]RigidTransform {
    const output = try admit(sample, destination, options);
    for (sample.skeleton.joints, output) |joint, *out| {
        var value: RigidTransform = undefined;
        localInto(&value, joint, sample.values, options);
        if (!value.isFinite()) return error.NonFiniteResult;
        out.* = value;
    }
    return output;
}

test localPoseInto {
    const allocator = std.testing.allocator;
    const source =
        \\HIERARCHY ROOT Hips { OFFSET 0 0 0 CHANNELS 4 Xposition Yposition Zposition Zrotation
        \\ End Site { OFFSET 0 2 0 }
        \\}
        \\MOTION
        \\Frames: 1
        \\Frame Time: 0.5
        \\1 2 3 90
    ;
    var motion = try parseAlloc(allocator, source, null, .{});
    defer motion.deinit(allocator);
    var storage: [2]RigidTransform = undefined;
    const pose = try localPoseInto(motion.frame(0).?, &storage, .{});
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, &pose[0].translation);
    try std.testing.expectEqualSlices(f64, &.{ 0, 2, 0 }, &pose[1].translation);
}

/// Writes joint transforms into file space, composing each parent with its child. Every root starts
/// an independent hierarchy. Output indices include end sites and follow source preorder, so
/// parents are available before children. Shares `localPoseInto`'s interpretation, admission,
/// ownership, tail and numeric-failure contracts; a numeric failure can leave a preorder prefix.
pub fn globalPoseInto(
    sample: model.Sample,
    destination: []RigidTransform,
    options: PoseOptions,
) PoseError![]RigidTransform {
    const output = try admit(sample, destination, options);
    for (sample.skeleton.joints, output) |joint, *out| {
        var value: RigidTransform = undefined;
        localInto(&value, joint, sample.values, options);
        var result: RigidTransform = undefined;
        if (joint.parent) |parent| {
            if (joint.channel_count == 0) {
                result.translation = output[parent].transformPoint(value.translation);
                for (output[parent].rotation, &result.rotation) |row, *rotation| {
                    // The admitted parent is finite. Multiplication by an identity matrix keeps
                    // each nonzero component and turns either zero sign into positive zero.
                    const components: @Vector(3, f64) = row;
                    rotation.* = components + @as(@Vector(3, f64), @splat(0));
                }
            } else transforms.composeInto(&result, &output[parent], &value);
        } else result = value;
        if (!result.isFinite()) return error.NonFiniteResult;
        out.* = result;
    }
    return output;
}

test globalPoseInto {
    var motion = try parseAlloc(std.testing.allocator, fixtures.simple, null, .{});
    defer motion.deinit(std.testing.allocator);
    var storage: [3]RigidTransform = undefined;
    const pose = try globalPoseInto(motion.frame(0).?, &storage, .{});
    // The root's quarter turn carries the knee and its end site to the left.
    for ([_][3]f64{ .{ 2, 4, 6 }, .{ -2, 4, 6 }, .{ -4, 4, 6 } }, pose) |expected, actual| {
        for (expected, actual.translation) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-14);
    }
}

test "BVH static children preserve identity-composition zero signs" {
    const source =
        \\HIERARCHY ROOT root { OFFSET 0 0 0 CHANNELS 3 Xrotation Yrotation Zrotation
        \\End Site { OFFSET 1 2 3 } }
        \\MOTION Frames: 1 Frame Time: .25
        \\0 0 0
    ;
    var motion = try parseAlloc(std.testing.allocator, source, null, .{});
    defer motion.deinit(std.testing.allocator);
    var storage: [2]RigidTransform = undefined;
    const sample = motion.frame(0).?;
    const local_pose = try localPoseInto(sample, &storage, .{});
    const negative_zero_bits: u64 = 1 << 63;
    try std.testing.expectEqual(
        negative_zero_bits,
        @as(u64, @bitCast(local_pose[0].rotation[0][1])),
    );
    const global_pose = try globalPoseInto(sample, &storage, .{});
    const identity = RigidTransform.identity.rotation;
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&identity),
        std.mem.asBytes(&global_pose[1].rotation),
    );
}

fn admit(
    sample: model.Sample,
    destination: []RigidTransform,
    options: PoseOptions,
) PoseError![]RigidTransform {
    if (!std.math.isFinite(
        options.length_scale,
    ) or options.length_scale <= 0) return error.InvalidScale;
    if (sample.values.len != sample.skeleton.channel_count) return error.InvalidSample;
    if (destination.len < sample.skeleton.joints.len) return error.OutputTooSmall;
    const bytes = std.mem.sliceAsBytes(destination);
    if (overlaps(
        bytes,
        std.mem.sliceAsBytes(sample.skeleton.joints),
    ) or overlaps(bytes, std.mem.sliceAsBytes(sample.values))) return error.AliasedStorage;
    for (sample.skeleton.joints) |joint| {
        if (joint.name) |name| if (overlaps(bytes, name)) return error.AliasedStorage;
    }
    for (sample.values) |value| if (!std.math.isFinite(value)) return error.InvalidSample;
    return destination[0..sample.skeleton.joints.len];
}

inline fn localInto(
    result: *RigidTransform,
    joint: model.Joint,
    values: []const f64,
    options: PoseOptions,
) void {
    for (joint.offset, &result.translation) |offset, *out| out.* = offset * options.length_scale;
    const channels = values[joint.channel_offset..][0..joint.channel_count];
    var axes: [3]u2 = undefined;
    var angles: [3]f64 = undefined;
    var rotations: usize = 0;
    for (joint.channelOrder(), channels) |channel, value| {
        switch (channel) {
            .tx, .ty, .tz => {
                const axis: usize = @backingInt(channel);
                const position = value * options.length_scale;
                switch (options.position_channels) {
                    .add_offset => result.translation[axis] += position,
                    .replace_offset => result.translation[axis] = position,
                }
            },
            .rx, .ry, .rz => {
                axes[rotations] = @intCast(@backingInt(channel) - @backingInt(model.Channel.rx));
                angles[rotations] = value;
                rotations += 1;
            },
        }
    }
    if (rotations == 3) {
        var sine: [3]f64 = undefined;
        var cosine: [3]f64 = undefined;
        for (angles, &sine, &cosine) |degrees, *sine_value, *cosine_value| {
            const angle = degrees * (std.math.pi / 180.0);
            sine_value.* = @sin(angle);
            cosine_value.* = @cos(angle);
        }
        // Parsed channels have distinct axes. Specializing the six orders removes products by the
        // axis matrices' known zeros and ones without changing the declared intrinsic order.
        switch (axes[0]) {
            0 => if (axes[1] == 1) euler(&result.rotation, .{
                0, 1, 2,
            }, sine, cosine) else euler(&result.rotation, .{
                0, 2, 1,
            }, sine, cosine),
            1 => if (axes[1] == 0) euler(&result.rotation, .{
                1, 0, 2,
            }, sine, cosine) else euler(&result.rotation, .{
                1, 2, 0,
            }, sine, cosine),
            2 => if (axes[1] == 0) euler(&result.rotation, .{
                2, 0, 1,
            }, sine, cosine) else euler(&result.rotation, .{
                2, 1, 0,
            }, sine, cosine),
            else => unreachable,
        }
    } else {
        result.rotation = RigidTransform.identity.rotation;
        for (axes[0..rotations], angles[0..rotations]) |axis, degrees| {
            rotate(&result.rotation, axis, degrees);
        }
    }
}

inline fn euler(matrix: *[3][3]f64, comptime axes: [3]u2, sine: [3]f64, cosine: [3]f64) void {
    const first_axis, const second_axis, const third_axis = axes;
    const first_sine, const second_sine, const third_sine = sine;
    const first_cosine, const second_cosine, const third_cosine = cosine;
    // The familiar Rx * Ry * Rz formula works in each permuted basis. Odd permutations reverse
    // handedness, hence the sign on terms with an odd number of sine factors.
    const handedness: f64 = if ((first_axis + 1) % 3 == second_axis) 1 else -1;
    matrix[first_axis][first_axis] = second_cosine * third_cosine;
    matrix[first_axis][second_axis] = -handedness * second_cosine * third_sine;
    matrix[first_axis][third_axis] = handedness * second_sine;
    matrix[second_axis][first_axis] = handedness * first_cosine * third_sine + first_sine *
        second_sine * third_cosine;
    matrix[second_axis][second_axis] = first_cosine * third_cosine - handedness * first_sine *
        second_sine * third_sine;
    matrix[second_axis][third_axis] = -handedness * first_sine * second_cosine;
    matrix[third_axis][first_axis] = first_sine * third_sine - handedness * first_cosine *
        second_sine * third_cosine;
    matrix[third_axis][second_axis] = handedness * first_sine * third_cosine + first_cosine *
        second_sine * third_sine;
    matrix[third_axis][third_axis] = first_cosine * second_cosine;
}

fn rotate(matrix: *[3][3]f64, axis: u2, degrees: f64) void {
    if (degrees == 0) return;
    const angle = degrees * (std.math.pi / 180.0);
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
    // Postmultiplication updates columns. Premultiplication would silently impose Acclaim's
    // fixed-axis convention and reverse BVH's intrinsic rotation order.
    for (matrix) |*row| {
        const first_column = row[first];
        const second_column = row[second];
        row[first] = cosine * first_column + sine * second_column;
        row[second] = -sine * first_column + cosine * second_column;
    }
}

fn expectVector(expected: [3]f64, actual: [3]f64) !void {
    for (expected, actual) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-13);
}

fn expectMatrix(expected: [3][3]f64, actual: [3][3]f64) !void {
    for (expected, actual) |a, b| try expectVector(a, b);
}

test "BVH local/global joint origins, end sites, scale and unchanged output tails" {
    var motion = try parseAlloc(std.testing.allocator, fixtures.simple, null, .{});
    defer motion.deinit(std.testing.allocator);
    var output: [4]RigidTransform = @splat(RigidTransform.identity);
    const sample = motion.frame(0).?;
    const local_pose = try localPoseInto(sample, &output, .{});
    try std.testing.expectEqual(3, local_pose.len);
    try expectVector(.{ 2, 4, 6 }, local_pose[0].translation);
    try expectVector(.{ 0, 4, 0 }, local_pose[1].translation);
    try expectVector(.{ 0, 2, 0 }, local_pose[2].translation);
    try expectMatrix(.{ .{ 0, -1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 } }, local_pose[0].rotation);
    try expectMatrix(.{ .{ 0, 0, 1 }, .{ 0, 1, 0 }, .{ -1, 0, 0 } }, local_pose[1].rotation);
    try expectMatrix(RigidTransform.identity.rotation, local_pose[2].rotation);
    const global_pose = try globalPoseInto(sample, &output, .{});
    try expectVector(.{ -2, 4, 6 }, global_pose[1].translation);
    try expectVector(.{ -4, 4, 6 }, global_pose[2].translation);
    const distal_rotation = .{ .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ -1, 0, 0 } };
    try expectMatrix(distal_rotation, global_pose[1].rotation);
    try expectMatrix(distal_rotation, global_pose[2].rotation);
    const scaled = try globalPoseInto(sample, &output, .{ .length_scale = 0.5 });
    try expectVector(.{ 1, 2, 3 }, scaled[0].translation);
    try expectVector(.{ -1, 2, 3 }, scaled[1].translation);
    try expectVector(.{ -2, 2, 3 }, scaled[2].translation);
    try std.testing.expectEqualDeep(RigidTransform.identity, output[3]);
}

test "BVH intrinsic quarter-turn compositions cover every order with literal matrices" {
    const Case = struct { order: []const u8, matrix: [3][3]f64 };
    // Hand-composed right-handed quarter turns; these expectations do not call a rotation helper.
    const cases = [_]Case{ .{ .order = "Xrotation Yrotation Zrotation", .matrix = .{ .{
        0, 0, 1,
    }, .{
        0, -1, 0,
    }, .{
        1, 0, 0,
    } } }, .{ .order = "Xrotation Zrotation Yrotation", .matrix = .{ .{
        0, -1, 0,
    }, .{
        1, 0, 0,
    }, .{
        0, 0, 1,
    } } }, .{ .order = "Yrotation Xrotation Zrotation", .matrix = .{ .{
        1, 0, 0,
    }, .{
        0, 0, -1,
    }, .{
        0, 1, 0,
    } } }, .{ .order = "Yrotation Zrotation Xrotation", .matrix = .{ .{
        0, 1, 0,
    }, .{
        1, 0, 0,
    }, .{
        0, 0, -1,
    } } }, .{ .order = "Zrotation Xrotation Yrotation", .matrix = .{ .{
        -1, 0, 0,
    }, .{
        0, 0, 1,
    }, .{
        0, 1, 0,
    } } }, .{ .order = "Zrotation Yrotation Xrotation", .matrix = .{ .{
        0, 0, 1,
    }, .{
        0, 1, 0,
    }, .{
        -1, 0, 0,
    } } } };
    const allocator = std.testing.allocator;
    for (cases) |case| {
        const source = try std.mem.concat(allocator, u8, &.{
            "HIERARCHY ROOT a { OFFSET 0 0 0 CHANNELS 3 ", case.order,
            " } MOTION Frames: 1 Frame Time: 1\n90 90 90",
        });
        defer allocator.free(source);
        var motion = try parseAlloc(allocator, source, null, .{});
        defer motion.deinit(allocator);
        var output: [1]RigidTransform = undefined;
        _ = try localPoseInto(motion.frame(0).?, &output, .{});
        try expectMatrix(case.matrix, output[0].rotation);
    }
}

test "BVH position interpretations keep interleaved nonroot coordinates in parent axes" {
    const source =
        \\HIERARCHY ROOT a { OFFSET 1 2 3 CHANNELS 1 Xrotation
        \\ JOINT b { OFFSET 2 3 4 CHANNELS 3 Zrotation Xposition Yrotation }
        \\} MOTION Frames: 1 Frame Time: 1
        \\90 90 5 90
    ;
    var motion = try parseAlloc(std.testing.allocator, source, null, .{});
    defer motion.deinit(std.testing.allocator);
    const sample = motion.frame(0).?;
    var output: [2]RigidTransform = undefined;
    _ = try localPoseInto(sample, &output, .{});
    try expectVector(.{ 7, 3, 4 }, output[1].translation);
    _ = try globalPoseInto(sample, &output, .{});
    try expectVector(.{ 8, -2, 6 }, output[1].translation);
    try expectMatrix(.{ .{ 0, -1, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 } }, output[1].rotation);
    _ = try localPoseInto(sample, &output, .{ .position_channels = .replace_offset });
    try expectVector(.{ 5, 3, 4 }, output[1].translation);
    _ = try globalPoseInto(sample, &output, .{ .position_channels = .replace_offset });
    try expectVector(.{ 6, -2, 6 }, output[1].translation);
    _ = try globalPoseInto(
        sample,
        &output,
        .{ .position_channels = .replace_offset, .length_scale = 2 },
    );
    try expectVector(.{ 12, -4, 12 }, output[1].translation);
}

test "BVH forests and static end sites evaluate independently with no synthetic bone alignment" {
    var motion = try parseAlloc(std.testing.allocator, fixtures.forest, null, .{});
    defer motion.deinit(std.testing.allocator);
    var output: [6]RigidTransform = undefined;
    _ = try globalPoseInto(motion.frame(0).?, &output, .{});
    try expectVector(.{ 0, 1, 0 }, output[0].translation);
    try expectVector(.{ -1, 1, 0 }, output[3].translation);
    try expectVector(.{ 9, 8, 7 }, output[4].translation);
    try expectVector(.{ 13, 8, 7 }, output[5].translation);
    try expectMatrix(RigidTransform.identity.rotation, output[0].rotation);
    try expectMatrix(RigidTransform.identity.rotation, output[4].rotation);
}

test "BVH caller-created samples need only a parsed skeleton and exact finite channel width" {
    const source =
        "HIERARCHY ROOT a { OFFSET 0 0 0 CHANNELS 1 Xposition } MOTION Frames: 0 Frame Time: 1";
    var motion = try parseAlloc(std.testing.allocator, source, null, .{});
    defer motion.deinit(std.testing.allocator);
    const sample: model.Sample = .{
        .index = 42,
        .time = -5,
        .values = &.{7},
        .skeleton = motion.skeleton.view(),
    };
    var output: [1]RigidTransform = undefined;
    _ = try globalPoseInto(sample, &output, .{});
    try expectVector(.{ 7, 0, 0 }, output[0].translation);
}

test "BVH admission leaves all output unchanged on bad scale, width, values or capacity" {
    var motion = try parseAlloc(std.testing.allocator, fixtures.simple, null, .{});
    defer motion.deinit(std.testing.allocator);
    var output: [4]RigidTransform = @splat(RigidTransform.identity);
    const sample = motion.frame(0).?;
    for ([_]f64{ 0, -1, std.math.nan(f64), std.math.inf(f64) }) |scale| {
        try std.testing.expectError(
            error.InvalidScale,
            globalPoseInto(sample, &output, .{ .length_scale = scale }),
        );
    }
    try std.testing.expectError(error.OutputTooSmall, globalPoseInto(sample, output[0..2], .{}));
    var bad_sample = sample;
    bad_sample.values = sample.values[0..8];
    try std.testing.expectError(error.InvalidSample, localPoseInto(bad_sample, &output, .{}));
    var values: [9]f64 = @splat(0);
    values[8] = std.math.nan(f64);
    bad_sample.values = &values;
    try std.testing.expectError(error.InvalidSample, globalPoseInto(bad_sample, &output, .{}));
    for (output) |value| try std.testing.expectEqualDeep(RigidTransform.identity, value);
}

test "BVH alias admission includes the entire offered destination and copied joint names" {
    var motion = try parseAlloc(std.testing.allocator, fixtures.simple, null, .{});
    defer motion.deinit(std.testing.allocator);
    var output: [4]RigidTransform = @splat(RigidTransform.identity);
    var sample = motion.frame(0).?;
    const values: [*]const f64 = @ptrCast(&output[3]);
    sample.values = values[0..9];
    try std.testing.expectError(error.AliasedStorage, globalPoseInto(sample, &output, .{}));
    for (output) |value| try std.testing.expectEqualDeep(RigidTransform.identity, value);
    _ = try globalPoseInto(sample, output[0..3], .{});
    try std.testing.expectEqualDeep(RigidTransform.identity, output[3]);

    var backing: [4096]u8 align(@alignOf(RigidTransform)) = @splat(0xa5);
    var fixed: std.heap.FixedBufferAllocator = .init(&backing);
    const padding: [512]u8 = @splat(' ');
    const name_source = "HIERARCHY ROOT alias {" ++
        padding ++
        " OFFSET 0 0 0 CHANNELS 0 } MOTION Frames: 1 Frame Time: 1";
    var named = try parseAlloc(fixed.allocator(), name_source, null, .{});
    defer named.deinit(fixed.allocator());
    const original = backing;
    const name_output: [*]RigidTransform = @ptrCast(
        @alignCast(@constCast(named.skeleton.source.ptr)),
    );
    try std.testing.expectError(
        error.AliasedStorage,
        localPoseInto(named.frame(0).?, name_output[0..1], .{}),
    );
    try std.testing.expectEqualSlices(u8, &original, &backing);
    const joint_output: [*]RigidTransform = @ptrCast(@alignCast(&backing));
    try std.testing.expectError(
        error.AliasedStorage,
        globalPoseInto(
            named.frame(0).?,
            joint_output[0 .. backing.len / @sizeOf(RigidTransform)],
            .{},
        ),
    );
    try std.testing.expectEqualSlices(u8, &original, &backing);
}

test "BVH numeric failure publishes only completed joints and preserves unused tails" {
    const allocator = std.testing.allocator;
    const source =
        \\HIERARCHY ROOT a { OFFSET 1 0 0 CHANNELS 0 }
        \\ROOT b { OFFSET 1e308 0 0 CHANNELS 0 }
        \\MOTION Frames: 1 Frame Time: 1
    ;
    var motion = try parseAlloc(allocator, source, null, .{});
    defer motion.deinit(allocator);
    var output: [3]RigidTransform = @splat(RigidTransform.identity);
    try std.testing.expectError(
        error.NonFiniteResult,
        localPoseInto(motion.frame(0).?, &output, .{ .length_scale = 2 }),
    );
    try expectVector(.{ 2, 0, 0 }, output[0].translation);
    try std.testing.expectEqualDeep(RigidTransform.identity, output[1]);
    try std.testing.expectEqualDeep(RigidTransform.identity, output[2]);

    const hierarchy =
        "HIERARCHY ROOT a { OFFSET 1e308 0 0 CHANNELS 0 JOINT b { OFFSET 1e308 0 0 CHANNELS 0 " ++
        "}} MOTION Frames: 1 Frame Time: 1";
    var accumulating = try parseAlloc(allocator, hierarchy, null, .{});
    defer accumulating.deinit(allocator);
    _ = try localPoseInto(accumulating.frame(0).?, &output, .{});
    @memset(&output, RigidTransform.identity);
    try std.testing.expectError(
        error.NonFiniteResult,
        globalPoseInto(accumulating.frame(0).?, &output, .{}),
    );
    try expectVector(.{ 1e308, 0, 0 }, output[0].translation);
    try std.testing.expectEqualDeep(RigidTransform.identity, output[1]);
    try std.testing.expectEqualDeep(RigidTransform.identity, output[2]);
}

// Address-only alias admission; empty spans are disjoint and pointer-end addition is avoided.
fn overlaps(first: []const u8, second: []const u8) bool {
    if (first.len == 0 or second.len == 0) return false;
    const first_address = @intFromPtr(first.ptr);
    const second_address = @intFromPtr(second.ptr);
    return if (first_address <= second_address) second_address - first_address < first
        .len else first_address - second_address < second.len;
}
