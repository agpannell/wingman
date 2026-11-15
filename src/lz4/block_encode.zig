//! Complete raw LZ4 block encoding. Greedy and HC operations use separate reservations but produce
//! the same standard block format. Dictionaries are borrowed only for the complete call.
const greedy = @import("greedy_encode.zig");

pub const into = greedy.into;
pub const bound = greedy.bound;
pub const max_input_bytes = greedy.max_input_bytes;
pub const Options = greedy.Options;
pub const Workspace = @import("BlockEncodeWorkspace.zig");
pub const Error = greedy.Error;
pub const hc = @import("hc.zig");

test {
    _ = greedy;
    _ = hc;
    _ = Workspace;
}
