//! Cyclic redundancy checks detect accidental corruption using format-specific polynomials. Select
//! the complete named algorithm required by the format; equal widths or polynomials do not make two
//! CRCs interchangeable. These checksums do not authenticate data.
//!
//! Each type owns its stream state, starts with `init()`, accepts exact unaligned byte slices
//! through `update`, and returns a non-consuming numeric snapshot with `final`. Copies continue
//! independently. `hash` handles complete input. No operation allocates or retains input.
//! Combination accepts finalized checksums and the full u64 second length, without rereading either
//! sequence.
//!
//! Numeric results have no wire byte order. gzip uses IEEE CRC-32 in little-endian fields; its
//! truncated header check is also IEEE, not GENIBUS. CRC-64/XZ supplies a checksum, not an XZ
//! codec.

const portable = @import("crc/portable.zig");

pub const Crc32IsoHdlc = @import("crc/Crc32IsoHdlc.zig");

pub const Crc32Iscsi = @import("crc/Crc32Iscsi.zig");
pub const Crc16Genibus = @import("crc/Crc16Genibus.zig");
pub const Crc64Xz = @import("crc/Crc64Xz.zig");

test "named CRC checks" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u32, 0xcbf43926), Crc32IsoHdlc.hash("123456789"));
    try testing.expectEqual(@as(u32, 0xe3069283), Crc32Iscsi.hash("123456789"));
    try testing.expectEqual(@as(u16, 0xd64e), Crc16Genibus.hash("123456789"));
    try testing.expectEqual(@as(u64, 0x995dc9bbdf1939fa), Crc64Xz.hash("123456789"));
}

test {
    _ = portable;
    _ = @import("crc/castagnoli.zig");
    _ = Crc32IsoHdlc;
    _ = Crc32Iscsi;
    _ = Crc16Genibus;
    _ = Crc64Xz;
}
