//! Compress or restore RFC 1950 zlib streams: a header, DEFLATE blocks and an Adler-32 checksum.
//! Decoding verifies the declared history window and checksum before reporting completion.
//!
//! `encode.into` and `decode.into` handle complete buffers using their operation's `Options` and
//! `Workspace`. Use `encode.bound(source.len, options)` for sufficient destination capacity.
//! Encoding options directly select compression, window, dictionary and resource limits. A supplied
//! dictionary is copied during setup and identified by its full Adler-32 checksum; even an empty
//! attached dictionary has an identity.
//!
//! `encode.StreamEncoder` and `decode.StreamDecoder` accept fragments. Streaming decoding needs
//! caller-owned 32 KiB history and can request a matching dictionary. Its `readInto` method drives
//! an initialized worker from `std.Io.Reader`. `decode.consumeStoredReader` is a workspace-free
//! stored-block operation; null or error can follow consumed input and changed output, so restore
//! the reader and destination before attempting a general decode.
//!
//! `Reader` adapts to a pull reader at a stable final address. Drain its `reader` to EndOfStream to
//! verify the trailer; reading only the expected payload size can leave it unchecked.
//!
//! `encode.four_byte_runs` has a compact streaming workspace and run/stored modes, with runs as its
//! default. Its `short` operation and `encode.short_stored` handle bounded complete inputs without
//! workspaces. Their capacity and padding contracts differ; consult those operations.
//!
//! Workspaces are shared with raw DEFLATE. Construct them at stable addresses and destroy them
//! through the same allocator after all borrows. Codec calls allocate nothing, retain no allocator
//! and require independent source/output/reservations. Complete calls retain no buffers. Streaming
//! errors require reset; encoding counts can include admitted partial work. Streamed decoded output
//! remains provisional until the Adler-32 trailer succeeds.
//!
//! Format: https://www.rfc-editor.org/rfc/rfc1950

pub const encode = @import("zlib/encode.zig");
pub const decode = @import("zlib/decode.zig");
pub const Reader = @import("zlib/Reader.zig");

test {
    _ = decode;
    _ = Reader;
    _ = encode;
}
