//! Compare classic and XXH3 digests, incremental input and a caller-provided secret.
const std = @import("std");
const xxhash = @import("wingman").xxhash;

/// The optional argument is the exact text to hash; the default is `abc`.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const input = if (args.len > 1) args[1] else "abc";
    const split = input.len / 2;

    var stream: xxhash.Xxh3_64 = undefined;
    stream.init(42);
    stream.update(input[0..split]);
    const prefix = stream.final();
    stream.update(input[split..]);
    const seeded = xxhash.Xxh3_64.hashSeeded(42, input);
    if (stream.final() != seeded) return error.HashMismatch;

    // A custom secret changes the mapping; it does not turn xxHash into authentication. Keep these
    // bytes alive and unchanged while the streaming state borrows them.
    var secret: [136]u8 = undefined;
    for (&secret, 0..) |*byte, index| byte.* = @truncate(index * 71 + 13);
    const options: xxhash.Xxh3Options = .{ .mode = .{ .secret = &secret } };
    var secret_stream: xxhash.Xxh3_128 = undefined;
    try secret_stream.initWithOptions(options);
    secret_stream.update(input);
    const custom = try xxhash.Xxh3_128.hashWithOptions(options, input);
    if (secret_stream.final() != custom) return error.HashMismatch;

    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print("XXH32:      {x:0>8}\n", .{xxhash.Xxh32.hash(input)});
    try output.interface.print("XXH64:      {x:0>16}\n", .{xxhash.Xxh64.hash(input)});
    try output.interface.print("XXH3-64:    {x:0>16}\n", .{xxhash.Xxh3_64.hash(input)});
    try output.interface.print("XXH3-128:   {x:0>32}\n", .{xxhash.Xxh3_128.hash(input)});
    try output.interface.print("seed 42 prefix: {x:0>16}; complete: {x:0>16}\n", .{
        prefix, seeded,
    });
    try output.interface.print("custom-secret XXH3-128: {x:0>32}\n", .{custom});
    try output.interface.flush();
}
