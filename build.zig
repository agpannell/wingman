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

    const examples = [_]struct {
        step: []const u8,
        source: []const u8,
        executable: []const u8,
        description: []const u8,
    }{
        .{
            .step = "example",
            .source = "examples/checksum.zig",
            .executable = "adler32sum",
            .description = "Compute Adler-32 from complete, streamed and combined text",
        },
        .{
            .step = "crc32-example",
            .source = "examples/crc32.zig",
            .executable = "crc32sum",
            .description = "Compute IEEE CRC-32 and encode gzip and PNG checksum fields",
        },
        .{
            .step = "xxhash-example",
            .source = "examples/xxhash.zig",
            .executable = "xxhashsum",
            .description = "Compute seeded and seed-zero XXH32 and XXH64 hashes",
        },
    };
    for (examples) |example| {
        const module = b.createModule(
            .{ .root_source_file = b.path(example.source), .target = target, .optimize = optimize },
        );
        module.addImport("wingman", wingman);
        const executable = b.addExecutable(
            .{ .name = example.executable, .root_module = module, .use_llvm = true },
        );
        const run = b.addRunArtifact(executable);
        run.addPassthruArgs();
        b.step(example.step, example.description).dependOn(&run.step);
    }

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
