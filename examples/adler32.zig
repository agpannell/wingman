//! Compute the same checksum from complete, fragmented and separately processed bytes.
const std = @import("std");
const adler32 = @import("wingman").adler32;

/// The optional argument is the exact text to checksum; the default is the standard nine digits.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const input = if (args.len > 1) args[1] else "123456789";
    const split = input.len / 2;

    const complete = adler32.hash(input);
    var stream: adler32.Hasher = .init;
    stream.update(input[0..split]);
    stream.update(input[split..]);
    const combined = adler32.combine(
        adler32.hash(input[0..split]),
        adler32.hash(input[split..]),
        input.len - split,
    );
    if (stream.final() != complete or combined != complete) return error.ChecksumMismatch;

    var footer: [4]u8 = undefined;
    std.mem.writeInt(u32, &footer, complete, .big);
    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print("checksum: {x:0>8}\n", .{complete});
    try output.interface.print("bytes: {d}; streaming and combination agree\n", .{input.len});
    try output.interface.print(
        "zlib footer: {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n",
        .{ footer[0], footer[1], footer[2], footer[3] },
    );
    try output.interface.flush();
}
