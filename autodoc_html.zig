//! Adds the source-pane layout rule used by the generated API reference. Zig's source grid must let
//! its code column shrink so the existing code scrollbar contains long lines on narrow pages. Read
//! the compiler's index.html from stdin and write the styled HTML to stdout; all other assets are
//! installed directly from the compiler output.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var input_buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &input_buffer);
    const html = try input.interface.allocRemaining(init.gpa, .unlimited);
    defer init.gpa.free(html);
    const head_end = std.mem.indexOf(u8, html, "</head>") orelse return error.MissingHead;

    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output.interface.writeAll(html[0..head_end]);
    try output.interface.writeAll(
        "<style>.source-code { grid-template-columns: auto minmax(0, 1fr); }</style>\n",
    );
    try output.interface.writeAll(html[head_end..]);
    try output.interface.flush();
}
