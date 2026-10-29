//! Build the Wingman module, executable examples, tests and API reference.
const std = @import("std");

/// Register the module independently of its example and development targets.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wingman = b.addModule(
        "wingman",
        .{ .root_source_file = b.path("src/wingman.zig"), .target = target, .optimize = optimize },
    );

    const tests = b.addTest(.{ .root_module = wingman, .use_llvm = true });
    b.step(
        "test",
        "Run library tests and executable documentation examples",
    ).dependOn(&b.addRunArtifact(tests).step);

    const example_module = b.createModule(
        .{
            .root_source_file = b.path("examples/checksum.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    example_module.addImport("wingman", wingman);
    const example = b.addExecutable(
        .{ .name = "adler32sum", .root_module = example_module, .use_llvm = true },
    );
    const run_example = b.addRunArtifact(example);
    run_example.addPassthruArgs();
    b.step(
        "example",
        "Checksum text using one-shot, streaming and combined input",
    ).dependOn(&run_example.step);

    const reference = b.addObject(.{ .name = "wingman", .root_module = wingman, .use_llvm = true });
    const install_reference = b.addInstallDirectory(
        .{
            .source_dir = reference.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        },
    );
    b.step("docs", "Generate the browsable API reference").dependOn(&install_reference.step);
}
