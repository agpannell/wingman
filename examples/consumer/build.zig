//! A separate package consuming Wingman through its named build module.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("wingman", .{ .target = target, .optimize = optimize });
    const consumer = b.createModule(
        .{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize },
    );
    consumer.addImport("wingman", dependency.module("wingman"));
    const tests = b.addTest(.{ .root_module = consumer, .use_llvm = true });
    b.step(
        "test",
        "Exercise the public libraries from a separate package",
    ).dependOn(&b.addRunArtifact(tests).step);
}
