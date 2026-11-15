//! Complete raw LZ4 recovery with independently selected output extent and borrowed history.
//! Streaming recovery owns a copied history ring and its own lifecycle options/progress.
const recovery = @import("block_recovery.zig");

pub const into = recovery.into;
pub const Options = recovery.Options;
pub const Limits = @import("BlockDecodeLimits.zig");
pub const Result = recovery.Result;
pub const Error = recovery.Error;
pub const History = recovery.History;
pub const StreamDecoder = @import("BlockStreamDecoder.zig");

test {
    _ = recovery;
    _ = StreamDecoder;
}
