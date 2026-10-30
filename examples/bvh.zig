//! Read an authored motion clip and evaluate joint origins without an animation engine.
const std = @import("std");
const wingman = @import("wingman");
const bvh = wingman.bvh;

pub fn main(init: std.process.Init) !void {
    var source = clip.*;
    var motion = try bvh.parseAlloc(init.gpa, &source, null, .{});
    defer motion.deinit(init.gpa);
    @memset(&source, 0xff); // The motion owns its names and every sample.

    const sample = motion.frame(0) orelse return error.MissingFrame;
    var local_storage: [3]wingman.RigidTransform = undefined;
    var global_storage: [4]wingman.RigidTransform = @splat(.identity);
    const local = try bvh.localPoseInto(sample, &local_storage, .{});
    const global = try bvh.globalPoseInto(sample, &global_storage, .{});
    const expected_local = [_][3]f64{ .{ 2, 4, 6 }, .{ 0, 4, 0 }, .{ 0, 2, 0 } };
    const expected_global = [_][3]f64{ .{ 2, 4, 6 }, .{ -2, 4, 6 }, .{ -4, 4, 6 } };
    for (
        local,
        global,
        expected_local,
        expected_global,
    ) |relative, absolute, local_origin, global_origin| {
        for (relative.translation, local_origin) |actual, expected| {
            if (@abs(actual - expected) > 1e-14) return error.WrongLocalOrigin;
        }
        for (absolute.translation, global_origin) |actual, expected| {
            if (@abs(actual - expected) > 1e-14) return error.WrongGlobalOrigin;
        }
    }
    if (!std.meta.eql(
        global_storage[3],
        wingman.RigidTransform.identity,
    )) return error.ChangedUnusedStorage;
    if (motion.frame(1).?.time != 0.125 or motion.frame(2) != null) return error.WrongTiming;

    var buffer: [1024]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print("BVH: {d} joints, {d} channels, {d} frames at {d}s\n", .{
        motion.skeleton.joints.len, motion.skeleton.channel_count, motion.frame_count,
        motion.frame_time,
    });
    for (motion.skeleton.joints, local, global) |joint, relative, absolute| {
        try output.interface.print(
            "  {s}: local {any}, global {any}\n",
            .{ joint.name orelse "end site", relative.translation, absolute.translation },
        );
    }
    try output.interface.writeAll(
        "positions retain file units; rotations follow declared channel order\n",
    );
    try output.interface.flush();
}

// Authored hierarchy with a rotating root, a rotating knee and an unanimated endpoint.
const clip =
    \\HIERARCHY
    \\ROOT Hips {
    \\ OFFSET 1 2 3
    \\ CHANNELS 6 Xposition Yposition Zposition Zrotation Xrotation Yrotation
    \\ JOINT Knee {
    \\  OFFSET 0 4 0
    \\  CHANNELS 3 Xrotation Yrotation Zrotation
    \\  End Site { OFFSET 0 2 0 }
    \\ }
    \\}
    \\MOTION
    \\Frames: 2
    \\Frame Time: 0.125
    \\1 2 3 90 0 0 0 90 0
    \\-1 -2 -3 0 90 0 45 0 -45
;
