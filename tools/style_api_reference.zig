//! Styles the generated API reference's source pane so long lines scroll within the code column.
//! Read the compiler's index.html from stdin and write the styled HTML to stdout. The docs build
//! installs all other reference assets directly from the compiler output.

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
