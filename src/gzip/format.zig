//! gzip member signature and header flag values.

pub const signature = [_]u8{ 31, 139, 8 };
pub const flag_text: u8 = 1;
pub const flag_header_crc: u8 = 2;
pub const flag_extra: u8 = 4;
pub const flag_name: u8 = 8;
pub const flag_comment: u8 = 16;
pub const reserved_flags: u8 = 0xe0;
