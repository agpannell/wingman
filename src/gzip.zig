//! Encode and decode RFC 1952 gzip members. Each member contains an independent DEFLATE stream,
//! optional header metadata, a CRC-32 checksum and the original size modulo 2^32.
//!
//! ## Decoding and metadata
//!
//! `decode` verifies the members selected by `DecodeOptions` and returns named byte/member counts.
//! Defaults select one member and leave following members or application bytes unconsumed. Output
//! extent and trailing-data rejection are independent selections. `MemberIterator` decodes
//! concatenated complete members one at a time. `parseHeader` inspects metadata without decoding
//! the payload; its views borrow the source. Names and comments remain uninterpreted bytes, with no
//! path handling or I/O.
//!
//! `Decoder` accepts fragments and supports single-member, explicit iteration and concatenation
//! policies through `StreamDecodeOptions`. Supply a `DecoderWorkspace`, 32 KiB of history and
//! optional bounded `HeaderBuffers` through `StreamStorage` for metadata capture. Keep streamed
//! output private until the member's checksum and size pass validation. Reset after a streaming
//! failure.
//!
//! ## Encoding
//!
//! Reserve `encodeBound(source.len, options)` output capacity and an `EncoderWorkspace`, then call
//! `encode`. `Encoder` adds fragmented input, flush/finish actions and `nextMember` for
//! concatenation. Each new member starts independent history. Timestamps and metadata are explicit;
//! encoding consults no clock and retains no processed fragment or metadata pointer. Header CRC-16,
//! called FHCRC in the format, is optional; the payload CRC-32 and size trailer are always emitted.
//!
//! ## Storage and failure
//!
//! Construct workspaces directly at their final addresses with `create(allocator)` and release them
//! with `destroy(allocator)` through the same allocator. Decoding and encoding use separate
//! workspace types shared with DEFLATE. Complete-buffer calls allocate nothing, retain no buffers
//! and allow serial workspace reuse after success or failure. Unaligned byte buffers need no
//! padding. Source, output and workspace must be disjoint. Success preserves unused output; errors
//! may change private output and scratch.
//!
//! Format: https://www.rfc-editor.org/rfc/rfc1952

const decoding = @import("gzip/decode.zig");
const encoding = @import("gzip/encode.zig");

pub const Error = decoding.Error;
pub const Input = decoding.Input;
pub const DecodeLimits = decoding.DecodeLimits;
pub const DecodeResult = decoding.DecodeResult;
pub const DecoderWorkspace = decoding.DecoderWorkspace;
pub const DecodeStorage = decoding.DecodeStorage;
pub const OutputSize = decoding.OutputSize;
pub const TrailingData = decoding.TrailingData;
pub const DecodeOptions = decoding.DecodeOptions;
pub const decode = decoding.decode;
pub const HeaderLimits = decoding.HeaderLimits;
pub const Header = decoding.Header;
pub const HeaderError = decoding.HeaderError;
pub const HeaderResult = decoding.HeaderResult;
pub const parseHeader = decoding.parseHeader;
pub const Member = decoding.Member;
pub const MemberIterator = decoding.MemberIterator;
pub const HeaderBuffers = decoding.HeaderBuffers;
pub const MemberPolicy = decoding.MemberPolicy;
pub const StreamStorage = decoding.StreamStorage;
pub const StreamDecodeOptions = decoding.StreamDecodeOptions;
pub const DecodeStatus = decoding.DecodeStatus;
pub const DecodeProgress = decoding.DecodeProgress;
pub const DecodeError = decoding.DecodeError;
pub const Decoder = decoding.Decoder;

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
