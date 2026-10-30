//! Raw LZ4 blocks and standard LZ4 frames, with dictionaries and streaming support. Raw blocks rely
//! on an enclosing record for their boundaries, decoded size and integrity. Frames carry their own
//! descriptors, block boundaries and optional checksums.
//!
//! ## Raw blocks
//!
//! Use `encodeBlock` for greedy encoding and `decodeBlock` when the decoded size is known exactly.
//! Select `.output_size = .bounded` to accept spare output capacity and return its used length.
//! `encodeBlockHc` performs high-compression (HC) search using separate `HcEncoderWorkspace`
//! scratch. All produce the same standard raw block format.
//!
//! Reserve `blockEncodeBound(source.len)` bytes before raw encoding, including for empty input.
//! Each encode call starts fresh history unless an explicit dictionary is supplied. Raw blocks do
//! not record dictionary identities. `HistoryView` permits external dictionary/linked-block
//! history; `Decoder` handles fragments using a caller-owned 64 KiB history ring.
//!
//! ## Frames
//!
//! Use `encodeFrame` with `FrameEncoderWorkspace` and `frameEncodeBound` output capacity.
//! `decodeFrame` decodes directly into bounded output without a workspace. `FrameEncoder` and
//! `FrameDecoder` support fragments, dictionaries, independent/linked blocks and checksums.
//! `FramePolicy` selects one frame, explicit iteration or concatenation. `FrameDecoderWorkspace`
//! has a fixed 128 KiB history/dictionary reservation, regardless of the advertised block size.
//!
//! ## Storage and results
//!
//! Encoding returns a borrowed used prefix of output. Save or transmit that prefix; free allocated
//! backing through its original full slice after all borrowers finish. Decoding into bounded output
//! preserves the unused suffix. The `encodeBlock` and `decodeBlock` doctests demonstrate buffer
//! ownership and cleanup.
//!
//! Construct workspaces at their final addresses using `create(allocator)` or retained typed
//! storage; release factory allocations with `destroy(allocator)` through the same allocator. One
//! call or streaming owner uses each workspace at a time. Codec calls allocate nothing and retain
//! no allocator. Source and output must be disjoint; each operation documents its additional
//! history/scratch requirements. Unaligned byte buffers need no padding. Failure may change private
//! output; verify the complete operation and any enclosing integrity requirement before using
//! decoded bytes.
//!
//! Format:
//! https://github.com/lz4/lz4/blob/ebb370ca83af193212df4dcbadcc5d87bc0de2f0/doc/lz4_Block_format.md

const block = @import("lz4/block.zig");
const frame = @import("lz4/frame.zig");
const hc = @import("lz4/hc.zig");

// Complete raw blocks and explicit history.
pub const maximum_input_bytes = block.maximum_input_bytes;
pub const maximum_distance = block.maximum_distance;
pub const Error = block.Error;
pub const EncoderWorkspace = block.EncoderWorkspace;
pub const blockEncodeBound = block.blockEncodeBound;
pub const BlockEncodeOptions = block.BlockEncodeOptions;
pub const encodeBlock = block.encodeBlock;
pub const HistoryView = block.HistoryView;
pub const OutputSize = block.OutputSize;
pub const BlockDecodeOptions = block.BlockDecodeOptions;
pub const BlockDecodeError = block.BlockDecodeError;
pub const DecodeResult = block.DecodeResult;
pub const decodeBlock = block.decodeBlock;

// Resumable block decoding.
pub const Input = block.Input;
pub const DecodeStatus = block.DecodeStatus;
pub const DecodeProgress = block.DecodeProgress;
pub const DecodeLimits = block.DecodeLimits;
pub const StreamDecodeOptions = block.StreamDecodeOptions;
pub const DecodeError = block.DecodeError;
pub const Decoder = block.Decoder;

// Bounded high-compression block encoding.
pub const HcEncoderWorkspace = hc.HcEncoderWorkspace;
pub const HcEncodeOptions = hc.HcEncodeOptions;
pub const HcEncodeLimits = hc.HcEncodeLimits;
pub const HcProfile = hc.HcProfile;
pub const HcDecoderCost = hc.HcDecoderCost;
pub const HcStats = hc.HcStats;
pub const HcError = hc.HcError;
pub const encodeBlockHc = hc.encodeBlockHc;

// Complete and resumable standard frames.
pub const FrameDecoder = frame.FrameDecoder;
pub const FrameEncoder = frame.FrameEncoder;
pub const FrameDecoderWorkspace = frame.FrameDecoderWorkspace;
pub const FrameEncoderWorkspace = frame.FrameEncoderWorkspace;
pub const FrameEncodeStorage = frame.FrameEncodeStorage;
pub const FrameCompression = frame.FrameCompression;
pub const FrameDecodeOptions = frame.FrameDecodeOptions;
pub const FrameStreamDecodeOptions = frame.FrameStreamDecodeOptions;
pub const FrameEncodeOptions = frame.FrameEncodeOptions;
pub const FrameInfo = frame.FrameInfo;
pub const FramePolicy = frame.FramePolicy;
pub const FrameBlockSize = frame.FrameBlockSize;
pub const FrameDictionary = frame.FrameDictionary;
pub const FrameDecodeLimits = frame.FrameDecodeLimits;
pub const FrameEncodeLimits = frame.FrameEncodeLimits;
pub const FrameError = frame.FrameError;
pub const FrameDecodeProgress = frame.FrameDecodeProgress;
pub const FrameDecodeStatus = frame.FrameDecodeStatus;
pub const FrameEncodeProgress = frame.FrameEncodeProgress;
pub const FrameEncodeStatus = frame.FrameEncodeStatus;
pub const FrameEncodeAction = frame.FrameEncodeAction;
pub const FrameDecodeResult = frame.FrameDecodeResult;
pub const FrameDecodeCounts = frame.FrameDecodeCounts;
pub const TrailingData = frame.TrailingData;
pub const decodeFrame = frame.decodeFrame;
pub const encodeFrame = frame.encodeFrame;
pub const frameEncodeBound = frame.frameEncodeBound;
pub const encodeSkippableFrame = frame.encodeSkippableFrame;
pub const skippableFrameHeader = frame.skippableFrameHeader;

test {
    _ = block;
    _ = frame;
    _ = hc;
}
