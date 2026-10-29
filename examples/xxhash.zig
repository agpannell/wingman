//! Compare complete and fragmented classic xxHash input with zero and nonzero seeds.
const std = @import("std");
const xxhash32 = @import("wingman").xxhash32;
const xxhash64 = @import("wingman").xxhash64;

/// The optional argument is the exact text to hash; the default is `abc`.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const input = if (args.len > 1) args[1] else "abc";
    const split = input.len / 2;
    var state32: xxhash32.Hasher = .init;
    var state64: xxhash64.Hasher = .init;
    state32.reset(42);
    state64.reset(42);
    state32.update(input[0..split]);
    state32.update(input[split..]);
    state64.update(input[0..split]);
    state64.update(input[split..]);
    if (state32.final() != xxhash32.hashSeeded(
        42,
        input,
    ) or state64.final() != xxhash64.hashSeeded(42, input)) return error.HashMismatch;

    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print("XXH32 seed 0:  {x:0>8}\n", .{xxhash32.hash(input)});
    try output.interface.print("XXH64 seed 0:  {x:0>16}\n", .{xxhash64.hash(input)});
    try output.interface.print("XXH32 seed 42: {x:0>8}\n", .{state32.final()});
    try output.interface.print("XXH64 seed 42: {x:0>16}\n", .{state64.final()});
    try output.interface.print(
        "bytes: {d}; seeded streaming and whole input agree\n",
        .{input.len},
    );
    try output.interface.flush();
}
