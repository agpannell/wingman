//! Cumulative decoding admission for raw DEFLATE and its zlib/gzip containers. Work units count
//! accepted encoded bytes plus restored bytes once each; dictionaries are excluded. Limits never
//! authorize allocation. A failed operation may have changed unpublished output and scratch.

const std = @import("std");

/// Maximum accepted encoded bytes, excluding trailing input.
input_bytes: u64 = std.math.maxInt(u64),
/// Maximum restored bytes, excluding dictionary history.
output_bytes: u64 = std.math.maxInt(u64),
/// Maximum sum of accepted and restored bytes.
work_units: u64 = std.math.maxInt(u64),
