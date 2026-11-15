//! Compress or restore RFC 1952 gzip members, each with an optional metadata header, DEFLATE body,
//! CRC-32 checksum and original-size trailer. Concatenated members have independent histories.
//!
//! `encode.into` writes one member using flat `encode.Options` for compression, window, limits and
//! metadata. `encode.bound(source.len, options)` reserves sufficient output capacity. Timestamps
//! are explicit; encoding reads no clock and copies metadata during reset. Gzip has no preset
//! dictionary facility.
//!
//! `decode.into` verifies one member by default, or all supplied members with concatenate
//! selection. Bounded/exact output and trailing-data rejection are independent choices.
//! `Header.parse` checks metadata without verifying a body or trailer; its views borrow encoded
//! source. `Member.Iterator` verifies and returns complete members one at a time. Names/comments
//! are uninterpreted bytes; callers own text decoding, path handling and filename policy.
//!
//! `encode.StreamEncoder` supports fragments, flush/finish and `nextMember`. Supplied metadata can
//! retire after reset; accepted input and returned output fragments can retire after each step.
//! `counts()` reports the last successfully checked aggregate across members; a failed call
//! publishes neither progress nor new counts.
//!
//! `decode.StreamDecoder` supports single, iterate and concatenate member selection. Its storage
//! includes decoding tables, 32 KiB history and optional `Header.CaptureBuffers`. Captured views
//! borrow those buffers; uncaptured fields still report lengths/flags. Keep streamed output private
//! until its member's checksum and size pass verification.
//!
//! Encoding and decoding have separate caller-owned workspaces shared with DEFLATE. Construct them
//! at stable addresses, use independent source/output/reservations, and destroy allocated storage
//! through its original allocator after all borrows. Codec calls allocate nothing; complete calls
//! retain no buffers. Errors can change output and scratch; streaming errors require reset.
//!
//! Format: https://www.rfc-editor.org/rfc/rfc1952

pub const encode = @import("gzip/encode.zig");
pub const decode = @import("gzip/decode.zig");
pub const Header = @import("gzip/Header.zig");
pub const Member = @import("gzip/Member.zig");

test {
    _ = decode;
    _ = encode;
}
