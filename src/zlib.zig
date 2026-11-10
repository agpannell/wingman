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
//! drives the same decoder from a `std.Io.Reader`, preserving buffered lookahead. `Reader` adapts
//! it to a pull reader; drain its `reader` field to EndOfStream to verify the trailer.
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
const std = @import("std");
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
/// Standard-I/O pull adapter over a complete zlib stream, with caller-owned history.
pub const Reader = @import("zlib/Reader.zig");

pub const EncoderWorkspace = encoding.EncoderWorkspace;
pub const Compression = encoding.Compression;
pub const EncodeAction = encoding.EncodeAction;
pub const EncodeStatus = encoding.EncodeStatus;
pub const EncodeProgress = encoding.EncodeProgress;
pub const EncodeStats = encoding.EncodeStats;
pub const EncodeError = encoding.EncodeError;
pub const EncodeOptions = encoding.EncodeOptions;
pub const encodeBound = encoding.encodeBound;
pub const encode = encoding.encode;
pub const Encoder = encoding.Encoder;
pub const FourByteRunEncoder = encoding.FourByteRunEncoder;
pub const FourByteRunEncoderWorkspace = encoding.FourByteRunEncoderWorkspace;
pub const short_stored_max_input_bytes = encoding.short_stored_max_input_bytes;
pub const short_stored_output_capacity = encoding.short_stored_output_capacity;
pub const short_four_byte_run_max_input_bytes = encoding.short_four_byte_run_max_input_bytes;
pub const short_four_byte_run_output_capacity = encoding.short_four_byte_run_output_capacity;
pub const encodeShortStored = encoding.encodeShortStored;
pub const encodeShortFourByteRuns = encoding.encodeShortFourByteRuns;

test {
    _ = decoding;
    _ = Reader;
    _ = encoding;
}

test "public short stream buffer refusals preserve destination" {
    var source: [short_four_byte_run_max_input_bytes + 1]u8 = @splat(42);
    var output: [short_four_byte_run_output_capacity]u8 = @splat(0xa5);
    try std.testing.expectError(error.LimitExceeded, encodeShortFourByteRuns(&source, &output));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
    try std.testing.expectError(
        error.OutputTooSmall,
        encodeShortFourByteRuns(source[0..16], output[0 .. output.len - 1]),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
    const before = output;
    try std.testing.expectError(
        error.StorageOverlap,
        encodeShortFourByteRuns(output[0..16], &output),
    );
    try std.testing.expectEqualSlices(u8, &before, &output);
    try std.testing.expectError(
        error.LimitExceeded,
        encodeShortStored(source[0 .. short_stored_max_input_bytes + 1], &output),
    );
    try std.testing.expectError(
        error.OutputTooSmall,
        encodeShortStored(source[0..16], output[0..26]),
    );
    try std.testing.expectError(error.StorageOverlap, encodeShortStored(output[0..16], &output));
    try std.testing.expectEqualSlices(u8, &before, &output);
}
