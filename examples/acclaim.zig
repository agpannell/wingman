//! Read paired authored ASF/AMC data and reuse a prepared skeleton for bone poses.
const std = @import("std");
const wingman = @import("wingman");
const acclaim = wingman.acclaim;

pub fn main(init: std.process.Init) !void {
    var skeleton_source = skeleton_text.*;
    var skeleton = try acclaim.Skeleton.parseAlloc(init.gpa, &skeleton_source, null, .{});
    // Defers run in reverse order: evaluator, motion, then their shared skeleton.
    defer skeleton.deinit(init.gpa);
    @memset(&skeleton_source, 0xff);
    var motion_source = motion_text.*;
    var motion = try acclaim.Motion.parseAlloc(
        init.gpa,
        &motion_source,
        skeleton.view(),
        null,
        .{},
    );
    defer motion.deinit(init.gpa);
    @memset(&motion_source, 0xff);
    var evaluator = try acclaim.PoseEvaluator.initAlloc(init.gpa, skeleton.view(), .{});
    defer evaluator.deinit(init.gpa);

    const tip_index = skeleton.view().findBone("tip") orelse return error.MissingBone;
    if (tip_index != 1 or skeleton.bones[tip_index].id != 42) return error.WrongIdentity;
    const first_frame = motion.frame(0) orelse return error.MissingFrame;
    const second_frame = motion.frame(1) orelse return error.MissingFrame;
    if (first_frame.number != 1 or second_frame.number != 5 or motion.frame(
        2,
    ) != null) return error.WrongFrameNumbers;
    if (second_frame.boneValues(2).?[0] != 90) return error.MissingCarriedChannel;

    var local_storage: [3]wingman.RigidTransform = undefined;
    var global_storage: [4]wingman.RigidTransform = @splat(.identity);
    const local = try evaluator.localPoseInto(first_frame, &local_storage);
    const global = try evaluator.globalPoseInto(first_frame, &global_storage);
    const expected = [_][3]f64{ .{ 2, 2, 3 }, .{ 2, 4, 3 }, .{ 2, 2, 3 } };
    for (global, expected) |actual, reference| {
        for (actual.translation, reference) |value, coordinate| {
            if (@abs(value - coordinate) > 1e-13) return error.WrongJointOrigin;
        }
    }
    const tip = skeleton.bones[tip_index];
    const segment_length = tip.length * evaluator.length_scale;
    var segment_vector: [3]f64 = undefined;
    for (tip.direction, &segment_vector) |direction, *value| value.* = direction * segment_length;
    const endpoint = global[tip_index].transformPoint(segment_vector);
    for (endpoint, [_]f64{ 1, 4, 3 }) |value, reference| {
        if (@abs(value - reference) > 1e-13) return error.WrongEndpoint;
    }
    if (!std.meta.eql(
        global_storage[3],
        wingman.RigidTransform.identity,
    )) return error.ChangedUnusedStorage;

    var buffer: [1024]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print(
        "Acclaim: {d} bones, {d} frames, retained frame numbers 1 and 5\n",
        .{ skeleton.bones.len, motion.frame_numbers.len },
    );
    for (skeleton.bones, local, global, 0..) |bone, relative, absolute, index|
        try output.interface.print(
            "  index {d}, ASF ID {d}, {s}: local {any}, global {any}\n",
            .{ index, bone.id, bone.name, relative.translation, absolute.translation },
        );
    try output.interface.print(
        "tip endpoint: {any}; no sample rate or metre conversion inferred\n",
        .{endpoint},
    );
    try output.interface.flush();
}

// Authored controls: declaration order puts tip before its parent; the second frame omits arm.
const skeleton_text =
    \\:version 1.10
    \\:name authored
    \\:units
    \\ length 1
    \\ angle deg
    \\:root
    \\ order TX TY TZ RX RY RZ
    \\ axis XYZ
    \\ position 1 2 3
    \\ orientation 0 0 0
    \\:bonedata
    \\begin
    \\ id 42
    \\ name tip
    \\ direction 0 1 0
    \\ length 1
    \\ axis 0 0 0 XYZ
    \\end
    \\begin
    \\ id 7
    \\ name arm
    \\ direction 1 0 0
    \\ length 2
    \\ axis 0 0 0 XYZ
    \\ dof rz
    \\ limits (-180 180)
    \\end
    \\:hierarchy
    \\begin
    \\ root arm
    \\ arm tip
    \\end
;

const motion_text =
    \\:DEGREES
    \\1
    \\root 1 0 0 0 0 0
    \\arm 90
    \\5
    \\root 2 0 0 0 0 0
;
