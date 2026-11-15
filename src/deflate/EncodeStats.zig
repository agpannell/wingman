//! Cumulative source, wire and algorithmic encoding counters. A stream owns the live record; its
//! counts method returns a copy, and reset starts a new record. Counts may include admitted
//! bytes/work from a failed call, according to its publication contract. Block-kind counters and
//! the total block count advance separately during construction; after failure they need not add
//! up.

/// Source bytes admitted internally, excluding dictionary bytes.
input_bytes: u64 = 0,
/// Wire bytes copied to output; wrappers may include framing bytes.
output_bytes: u64 = 0,
/// Charged algorithmic units, including all attempted parses and splits.
work_units: u64 = 0,
/// Prior match candidates examined by the selected search, including history preparation. For
/// four-byte runs this also counts eligible sample positions and attempted grouped-literal probes.
/// Every eligible sample position is charged even when the sample decision is proven before all
/// positions are read.
match_probes: u64 = 0,
/// Logical match-length edges charged, including lengths skipped by maximum-length pricing.
parse_edges: u64 = 0,
/// Serialized blocks, including synchronization blocks.
blocks: u64 = 0,
/// Selected stored blocks.
stored_blocks: u64 = 0,
/// Selected fixed-Huffman blocks.
fixed_blocks: u64 = 0,
/// Selected dynamic-Huffman blocks.
dynamic_blocks: u64 = 0,
