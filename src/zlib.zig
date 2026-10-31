//! Encode and decode RFC 1950 zlib streams: a header, DEFLATE blocks and an Adler-32 checksum.
//! Decoding checks the declared history window and verifies the checksum before returning success.
//!
//! ## Decoding
//!
//! `decode` receives `DecodeStorage` and `DecodeOptions`, returns consumed/produced counts and
//! preserves unused output. Select `.output_size = .exact` for the destination's full extent and
//! `.trailing_data = .reject` for complete source consumption. `options.dictionary` supplies preset
//! history identified by its full Adler-32 checksum; it requires extra caller history storage.
//!
//! `Decoder` supports fragmented input/output and dictionary requests. Supply a decoding
//! `DecoderWorkspace` and 32 KiB of history, then call `reset` before stepping. `decodeReader`
//! drives the same decoder from a `std.Io.Reader`, preserving buffered lookahead.
//! `decodeStoredReader` is a separate workspace-free Reader operation supporting stored blocks
//! only; its documentation explains how to handle an unsupported compressed block.
//!
//! ## Encoding
//!
//! Reserve `encodeBound(source.len, options)` output capacity and an `EncoderWorkspace`, then call
//! `encode`. `Encoder` adds fragmented input and process/flush/finish operations. Both use
//! deterministic headers and incremental Adler-32. Dictionary history is copied at reset; no
//! dictionary pointer is retained.
//!
//! ## Storage and failure
//!
//! Workspaces and decoding results are shared with DEFLATE. Construct large workspaces at their
//! final addresses with `create(allocator)` and release them through the same allocator with
//! `destroy`. Decoding and encoding use separate workspace types. Complete-buffer calls allocate
//! nothing and retain no input/output pointer or allocator. Reuse a workspace serially after
//! success or failure. Streaming owners borrow their reservations until reset or end of use; reset
//! after an error.
//!
//! Source, output and workspace must be disjoint. Unaligned byte buffers need no padding. Success
//! preserves unused output; failure may change private output and scratch. Streamed output becomes
//! verified only after the Adler-32 trailer succeeds.
//!
//! Format: https://www.rfc-editor.org/rfc/rfc1950

const decoding = @import("zlib/decode.zig");
const encoding = @import("zlib/encode.zig");

pub const Error = decoding.Error;
pub const DecodeResult = decoding.DecodeResult;
pub const DecoderWorkspace = decoding.DecoderWorkspace;
pub const Input = decoding.Input;
pub const DecodeLimits = decoding.DecodeLimits;
pub const DecodeStorage = decoding.DecodeStorage;
pub const StreamStorage = decoding.StreamStorage;
pub const OutputSize = decoding.OutputSize;
pub const TrailingData = decoding.TrailingData;
pub const DecodeOptions = decoding.DecodeOptions;
pub const StreamDecodeOptions = decoding.StreamDecodeOptions;
pub const DecodeStatus = decoding.DecodeStatus;
pub const DecodeProgress = decoding.DecodeProgress;
pub const DecodeError = decoding.DecodeError;
pub const validateHeader = decoding.validateHeader;
pub const decode = decoding.decode;
pub const Decoder = decoding.Decoder;
pub const decodeReader = decoding.decodeReader;
pub const decodeStoredReader = decoding.decodeStoredReader;

pub const EncoderWorkspace = encoding.EncoderWorkspace;
pub const EncodeProfile = encoding.EncodeProfile;
pub const EncodeAction = encoding.EncodeAction;
pub const EncodeStatus = encoding.EncodeStatus;
pub const EncodeProgress = encoding.EncodeProgress;
pub const EncodeStats = encoding.EncodeStats;
pub const EncodeError = encoding.EncodeError;
pub const EncodeOptions = encoding.EncodeOptions;
pub const encodeBound = encoding.encodeBound;
pub const encode = encoding.encode;
pub const Encoder = encoding.Encoder;

test {
    _ = decoding;
    _ = encoding;
}
