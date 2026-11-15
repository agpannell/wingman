//! LZ4 compression replaces repeated bytes with backward references, favoring fast recovery over
//! the smallest encoding. The block chapter reads and writes raw LZ4 sequences; the frame chapter
//! adds descriptors, boundaries, dictionary IDs and optional XXH32 checksums.
//!
//! Use block.encode.into and block.decode.into when an enclosing record supplies the encoded
//! boundary, decoded extent and integrity policy. block.encode.hc uses bounded high-compression
//! search with a separate workspace. All block encoders produce the same standard wire format.
//! Complete block decoding requires exact output by default; bounded output returns its used size.
//!
//! Use frame.encode.into and frame.decode.into for standard version-1 frames. Frame decoding uses
//! bounded output by default and stops after one frame. Select concatenation to verify a sequence,
//! or use frame.decode.StreamDecoder for fragments and explicit frame-boundary events. Skippable
//! frames carry application metadata and produce no decoded bytes. Legacy frames are unsupported.
//!
//! Reserve encoding capacity with the operation's bound function. Its Workspace.create/destroy
//! methods are the only allocation points; codec calls retain no allocator. Encoding returns a
//! borrowed prefix of output, so release allocated backing through its original full slice.
//! Streaming workers borrow explicit storage at stable addresses and retire fragments by copied
//! progress counts. Each operation documents its dictionary/history lifetime and disjointness.
//!
//! Byte buffers require no alignment or padding. Failure may change private output; publish it only
//! after the complete operation and any enclosing integrity checks succeed. Frame checksums detect
//! accidental corruption, not malicious substitution.

pub const block = @import("lz4/block.zig");
pub const frame = @import("lz4/frame.zig");

/// An encoded fragment and its actual end-of-input condition. Both raw and frame decoders retire
/// accepted bytes on return; resubmit an unconsumed suffix with the same final flag.
pub const InputFragment = struct {
    /// Encoded bytes available during this call; no caller fragment is retained.
    bytes: []const u8,
    /// These bytes reach the raw block's end or the selected frame sequence's EOF.
    final: bool = false,
};

/// Required decoded extent for a complete operation. The complete encoded selection is validated in
/// either case. Raw blocks default to exact; frames default to bounded.
pub const OutputSize = enum {
    /// Accept spare destination capacity and return the number of bytes produced.
    bounded,
    /// Require the produced byte count to equal the destination length.
    exact,
};

test {
    _ = block;
    _ = frame;
}
