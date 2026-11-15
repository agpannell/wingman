//! Compress bytes with backward matches and Huffman codes, or restore a raw RFC 1951 stream. Raw
//! DEFLATE has no checksum, decoded-size field or dictionary identity. Use zlib or gzip when their
//! framing and integrity checks are required.
//!
//! `encode.into` and `decode.into` process complete buffers. Each operation owns its `Options`,
//! `Error`, `Workspace` and storage contract. Reserve `encode.bound(source.len)` output bytes;
//! construct workspaces directly at stable addresses with `create(allocator)` or retained typed
//! storage. Codec calls allocate nothing and perform no I/O.
//!
//! `encode.Compression` selects levels 0..9 and optional strategies. Level 0 stores bytes; levels
//! 1..3 use greedy matching, 4..6 lazy matching and 7..9 priced offline parsing. The default is
//! level 6. `encode.four_byte_runs` provides a smaller streaming reservation and valid run/stored
//! modes; its `short` operation handles bounded complete inputs without a workspace. These run
//! encoders match only at distance four and do not perform image filtering.
//!
//! `decode.into` accepts bounded output and following input by default. Exact extent and trailing
//! rejection are independent options. Ordinary complete decoding needs only `decode.Workspace`; a
//! preset dictionary additionally needs history in `decode.Storage`. Dictionary identity belongs to
//! the enclosing format.
//!
//! `encode.StreamEncoder` and `decode.StreamDecoder` retain exclusive workspace borrows across
//! fragments. Decoding also needs 32 KiB of caller-owned history. Accepted input and returned
//! output can retire after a step; the worker keeps no fragment pointer. A failed step returns no
//! progress and requires reset. Encoding counts can include admitted partial work after error.
//!
//! Source, output and reservations must be disjoint. Complete output needs no padding; short run
//! encoding has its own documented padded capacity. Errors may change output and scratch. Treat
//! decoded bytes as provisional until the raw boundary and any enclosing integrity check pass.
//! Release workspaces through the allocator that created them after all borrows end.
//!
//! Format: https://www.rfc-editor.org/rfc/rfc1951

pub const encode = @import("deflate/encode.zig");
pub const decode = @import("deflate/decode.zig");

test {
    _ = encode;
    _ = decode;
}
