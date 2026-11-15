//! Finite caller-selected encoding bounds, cumulative across suspensions and flushes.

const std = @import("std");

/// Accepted source bytes; dictionary bytes are excluded.
input_bytes: u64 = std.math.maxInt(u64),
/// Returned wire bytes, including enclosing framing when used by a wrapper.
output_bytes: u64 = std.math.maxInt(u64),
/// Match probes/comparisons, parser edges and book/header work units. This is an algorithmic bound,
/// not an instruction or time count. Offline search charges prior candidates and eight-byte
/// comparisons, including dictionary preparation and replayed history. Offline pricing charges the
/// full logical length range even when a pricing choice skips lengths. Bounded table
/// initialization, tree checkpoints, byte tails, cached-match scans, price-run discovery, state
/// comparisons, the bounded small-block cost proof, and ordinary-tree attempts before a
/// package-merge fallback are uncharged. A proven fixed/stored block skips Huffman book and
/// dynamic-header work and therefore does not charge that work. Also set input_bytes to bound
/// source-dependent scan effort; dictionary and wrapper metadata may require separate bounds.
/// Callers must also bound repeated steps or flushes when bounding aggregate fixed setup work.
/// Four-byte runs charge 256 work units atomically for sampling blocks of at least 4,096 bytes, one
/// per compared run byte, and four or 32 per attempted grouped-literal probe, according to its
/// span. Each grouped probe is admitted atomically. From 8,192 bytes, book selection also charges
/// up to 32 sampled run extensions and 32 units per literal window, plus at most four seeding
/// bytes. A stored preflight may perform a second scan. Prebuilt-book initialization is uncharged.
work_units: u64 = std.math.maxInt(u64),
