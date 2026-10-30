//! Hash text as a complete buffer and stream, then select extended-output bytes.
const std = @import("std");
const blake3 = @import("wingman").blake3;

/// The optional argument is the exact text to hash; the default is `abc`.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const input = if (args.len > 1) args[1] else "abc";
    const state = try init.gpa.create(blake3.Hasher);
    defer init.gpa.destroy(state);
    defer state.clear();
    const complete = try state.hash(input);

    state.reset();
    const split = input.len / 2;
    try state.update(input[0..split]);
    try state.update(input[split..]);
    const streamed = state.final();
    if (!std.mem.eql(u8, &streamed, &complete)) return error.HashMismatch;

    var extended: [96]u8 = undefined;
    try state.finalizeSeek(0, &extended);
    var selected: [40]u8 = undefined;
    try state.finalizeSeek(31, &selected);
    if (!std.mem.eql(u8, &complete, extended[0..32])) return error.DigestPrefixMismatch;
    if (!std.mem.eql(u8, &selected, extended[31..71])) return error.OutputRangeMismatch;

    const digest_hex = std.fmt.bytesToHex(complete, .lower);
    const selected_hex = std.fmt.bytesToHex(selected, .lower);
    var buffer: [512]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print("BLAKE3: {s}\n", .{digest_hex});
    try output.interface.print("output bytes 31..71: {s}\n", .{selected_hex});
    try output.interface.print(
        "bytes: {d}; complete, streamed and selected output agree\n",
        .{input.len},
    );
    try output.interface.flush();
}
