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

    const all_examples = b.step("examples", "Run all library examples");
    const examples = [_]struct {
        step: []const u8,
        source: []const u8,
        executable: []const u8,
        description: []const u8,
    }{
        .{
            .step = "example",
            .source = "examples/adler32.zig",
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
        .{
            .step = "blake3-example",
            .source = "examples/blake3.zig",
            .executable = "blake3sum",
            .description = "Hash complete and streamed text and verify seekable BLAKE3 output",
        },
        .{
            .step = "lz4-example",
            .source = "examples/lz4.zig",
            .executable = "lz4-roundtrip",
            .description = "Encode and recover raw LZ4 blocks and checksummed frames",
        },
        .{
            .step = "wav-example",
            .source = "examples/wav.zig",
            .executable = "wave-audio",
            .description = "Write, inspect and decode WAVE with owned and caller storage",
        },
        .{
            .step = "riff-example",
            .source = "examples/riff.zig",
            .executable = "riff-inspect",
            .description = "Write and inspect a RIFF container with nested typed chunks",
        },
        .{
            .step = "pcm-example",
            .source = "examples/pcm.zig",
            .executable = "pcm-convert",
            .description = "Encode PCM16 and inspect normalized sample quantization",
        },
        .{
            .step = "g711-example",
            .source = "examples/g711.zig",
            .executable = "g711-decode",
            .description = "Expand A-law and mu-law bytes and write their PCM16 values",
        },
        .{
            .step = "adpcm-example",
            .source = "examples/adpcm.zig",
            .executable = "adpcm-decode",
            .description = "Decode Microsoft and IMA blocks and validate prefix output",
        },
        .{
            .step = "acclaim-example",
            .source = "examples/acclaim.zig",
            .executable = "acclaim-motion",
            .description = "Read paired ASF/AMC motion and evaluate prepared bone poses",
        },
        .{
            .step = "bvh-example",
            .source = "examples/bvh.zig",
            .executable = "bvh-motion",
            .description = "Read owned BVH motion and evaluate local and global joint poses",
        },
        .{
            .step = "dfont-example",
            .source = "examples/dfont.zig",
            .executable = "dfont-inspect",
            .description = "Select borrowed SFNT resources from a Macintosh data-fork container",
        },
        .{
            .step = "sfnt-example",
            .source = "examples/sfnt.zig",
            .executable = "sfnt-inspect",
            .description = "Inspect borrowed font tables, collection members and checksums",
        },
        .{
            .step = "icc-example",
            .source = "examples/icc.zig",
            .executable = "icc-inspect",
            .description = "Inspect borrowed ICC profile headers and shared tag bodies",
        },
        .{
            .step = "exif-example",
            .source = "examples/exif.zig",
            .executable = "exif-inspect",
            .description = "Inspect Exif attributes and sample an uncompressed thumbnail",
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
        all_examples.dependOn(&run.step);
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
