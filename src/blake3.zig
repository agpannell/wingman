//! Computes BLAKE3 digests over exact caller bytes. The default digest is 32 raw bytes. Keyed
//! hashing and context-based key derivation use distinct modes; extended output supplies more bytes
//! from the same final state.
//!
//! ## Hash a buffer or a stream
//!
//! Use `Hasher.hash` for one complete buffer. For incremental input, call
//! [reset](#wingman.blake3.state.State.reset), [update](#wingman.blake3.state.State.update) for
//! each fragment, then [final](#wingman.blake3.state.State.final) to obtain the digest.
//!
//! `Hasher` incrementally consumes a byte stream. Each update continues that stream; call
//! boundaries are not encoded. Hashing "ab" then "c" therefore hashes the same bytes as "a" then
//! "bc". Frame fields and domains in the caller when hashing structured values. The hasher performs
//! no allocation and retains no allocator or input/output pointer. Parallel updates use the
//! supplied `std.Io` provider for scheduling. Give each mutating caller its own state or serialize
//! its calls.
//!
//! ## Storage and lifetime
//!
//! Construct the large state directly at its final address. Each update consumes its borrowed input
//! before returning, and the copied digest outlives both the input and the state. The
//! [incremental example](#wingman.blake3.state.State.update) demonstrates those lifetimes.
//!
//! Reuse a reservation through its pointer. The reset methods begin a new stream in possibly
//! uninitialized storage; `hash` resets, hashes one complete unkeyed buffer and finalizes. No
//! deinit is needed. State size and alignment depend on the compile-time CPU target; use
//! `@sizeOf(Hasher)` and the type's alignment when reserving storage. Keep inputs, outputs and
//! state disjoint.
//!
//! `final` snapshots the current stream without consuming it. Repeated finalization agrees; later
//! updates extend the accepted bytes. `finalizeSeek` copies any admitted range of the same extended
//! output: offset zero begins with the ordinary digest. Update length overflow leaves accepted
//! state unchanged; seek-range overflow leaves output unchanged. A new reset/hash intentionally
//! replaces the previous stream.
//!
//! The clear method erases the entire reservation, including retained key-derived values. Reset
//! before reuse. Resetting or destroying state does not clear it, and caller keys, material and
//! copied output retain their separate lifetimes. The
//! [keyed](#wingman.blake3.state.State.resetKeyed) and
//! [derived-output](#wingman.blake3.state.State.finalizeSeek) doctests show explicit clearing.
//!
//! ## Parallel and low-level operations
//!
//! CPU features follow the compile-time build target. The compression namespace exposes scalar, row
//! SIMD and batched chunk/parent primitives. `ScalarHasher` provides portable scalar hashing with
//! the same byte and lifetime contract. Parallel updates explicitly borrow a `std.Io` provider and
//! caller-owned worker scratch; ordinary updates never start workers. Algorithm and modes:
//! https://github.com/BLAKE3-team/BLAKE3/blob/f55849f89cd85083c1c9daa2c5de20766f309c00/README.md

const state = @import("blake3/state.zig");
const parallel = @import("blake3/parallel.zig");
const compression_impl = @import("blake3/compression.zig");

pub const digest_length = state.digest_length;
pub const key_length = state.key_length;
pub const Digest = state.Digest;
pub const Error = state.Error;
pub const ParallelError = state.ParallelError;
pub const Hasher = state.Hasher;
pub const ScalarHasher = state.ScalarHasher;

pub const ParallelOptions = parallel.ParallelOptions;
pub const Worker = parallel.Worker;

/// Low-level BLAKE3 block and tree compression. Most callers use `Hasher`; these primitives serve
/// applications that manage chunk counters, mode flags and tree/root construction themselves. A
/// chaining value (`Cv`) is an internal tree value, rather than a finalized digest. Input chunks
/// contain 1024 bytes; message blocks contain 64 bytes. Kernel selection follows the compile-time
/// target. Scalar and vector kernels produce identical algorithm words and never allocate.
pub const compression = struct {
    pub const Cv = compression_impl.Cv;
    pub const Block = compression_impl.Block;
    pub const iv = compression_impl.iv;
    pub const flags = compression_impl.flags;
    pub const Kernel = compression_impl.Kernel;
    pub const preferred = compression_impl.preferred;
    pub const max_lanes = compression_impl.max_lanes;
    pub const loadBlock = compression_impl.loadBlock;
    pub const storeCv = compression_impl.storeCv;
    pub const compress = compression_impl.compress;
    pub const chaining = compression_impl.chaining;
    pub const MessageWorkspace = compression_impl.MessageWorkspace;
    pub const chunks = compression_impl.chunks;
    pub const parents = compression_impl.parents;
    pub const pairChunks = compression_impl.pairChunks;
    pub const batchChunks = compression_impl.batchChunks;
    pub const batchParents = compression_impl.batchParents;
};

test {
    _ = state;
    _ = parallel;
    _ = compression_impl;
}
