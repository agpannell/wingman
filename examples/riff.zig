//! Write and inspect a small RIFF form without interpreting a media payload.
const std = @import("std");
const riff = @import("wingman").riff;

/// The optional argument becomes the exact bytes of the `note` chunk; default `hello`.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const text = if (args.len > 1) args[1] else "hello";
    const child_size = try riff.chunkSize(text.len);
    const list_size = try std.math.add(usize, 4, child_size);
    const body_size = try riff.chunkSize(list_size);
    const bytes = try init.arena.allocator().alloc(u8, try std.math.add(usize, 12, body_size));
    var writer: std.Io.Writer = .fixed(bytes);
    try riff.writeHeader("DEMO".*, body_size, &writer);
    try riff.writeChunkHeader("LIST".*, list_size, &writer);
    try writer.writeAll("INFO");
    try riff.writeChunk("note".*, text, &writer);

    const container = try riff.parse(writer.buffered());
    var chunks = container.iterator();
    const parent = (try chunks.next()).?;
    const list = try parent.list();
    var children = list.iterator();
    const note = (try children.next()).?;
    if (!std.mem.eql(u8, text, note.data)) return error.PayloadMismatch;
    if (try children.next() != null or try chunks.next() != null) return error.UnexpectedChunk;

    var buffer: [256]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    try output.interface.print("RIFF {s}: {d} bytes\n", .{
        container.form_type, container.source.len,
    });
    try output.interface.print("LIST {s}: {d} payload bytes\n", .{
        list.list_type, parent.data.len,
    });
    try output.interface.print("{s}: {d} bytes, padding {any}\n", .{
        note.id, note.data.len, note.padding,
    });
    try output.interface.print("payload: {s}\n", .{note.data});
    try output.interface.flush();
}
