//! Settings for a gzip member. Metadata is copied by reset; its source bytes can retire on return.
//! Compression and resource limits apply independently to each member begun by the stream worker.
const deflate = @import("../deflate.zig");

/// General DEFLATE compression policy; gzip does not support preset dictionaries.
compression: deflate.encode.Compression = .{},
/// Maximum backward distance, a power of two from 256 through 32768 bytes.
window_bytes: usize = 32768,
/// Member-wide source/output/work bounds; output includes header and trailer.
limits: deflate.encode.Limits = .{},
/// Explicit Unix timestamp; zero means no timestamp.
modification_time: u32 = 0,
/// Uninterpreted RFC operating-system byte; 255 means unspecified.
operating_system: u8 = 255,
/// Set FTEXT without interpreting the payload.
text: bool = false,
/// Optional extra bytes, at most 65535; null omits FEXTRA.
extra: ?[]const u8 = null,
/// Optional name without embedded NUL; reset copies the terminator.
name: ?[]const u8 = null,
/// Optional comment without embedded NUL; reset copies the terminator.
comment: ?[]const u8 = null,
/// Include the low 16 bits of the header CRC-32 as FHCRC.
header_crc: bool = false,
