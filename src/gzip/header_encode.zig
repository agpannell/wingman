//! Size/admit and write a gzip metadata header. Admission precedes raw reset; writing receives an
//! already-sized framing-output loan and retains none of the caller's metadata pointers.
const std = @import("std");
const Crc32IsoHdlc = @import("../crc.zig").Crc32IsoHdlc;
const deflate = @import("../deflate.zig");
const Options = @import("EncodeOptions.zig");
const format = @import("format.zig");
const signature = format.signature;
const flag_text = format.flag_text;
const flag_header_crc = format.flag_header_crc;
const flag_extra = format.flag_extra;
const flag_name = format.flag_name;
const flag_comment = format.flag_comment;

pub const Error = error{ HeaderTooLong, CounterOverflow, InvalidOptions };

pub fn size(options: Options) Error!usize {
    var byte_count: usize = if (options.header_crc) 12 else 10;
    if (options.extra) |extra| {
        if (extra.len > 65535) return error.HeaderTooLong;
        byte_count += 2 + extra.len;
    }
    inline for (.{ options.name, options.comment }) |field| {
        if (field) |bytes| {
            byte_count = std.math.add(
                usize,
                byte_count,
                bytes.len,
            ) catch return error.CounterOverflow;
            byte_count = std.math.add(usize, byte_count, 1) catch return error.CounterOverflow;
            if (byte_count > deflate.encode.StreamEncoder.framing_output_capacity)
                return error.HeaderTooLong;
            if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidOptions;
        }
    }
    if (byte_count > deflate.encode.StreamEncoder.framing_output_capacity)
        return error.HeaderTooLong;
    return byte_count;
}

/// Write an admitted header into exactly its sized prefix.
pub fn write(output: []u8, options: Options) void {
    var flags: u8 = if (options.text) flag_text else 0;
    if (options.extra != null) flags |= flag_extra;
    if (options.name != null) flags |= flag_name;
    if (options.comment != null) flags |= flag_comment;
    if (options.header_crc) flags |= flag_header_crc;

    const bytes = output;
    bytes[0..3].* = signature;
    bytes[3] = flags;
    std.mem.writeInt(u32, bytes[4..8], options.modification_time, .little);
    const compression = options.compression;
    // XFL is an informational hint; stored and restricted strategies leave it unspecified.
    bytes[8] = if (compression.level == 0 or compression.strategy != .default)
        0
    else if (compression.level == 1) 4 else if (compression.level == 9) 2 else 0;
    bytes[9] = options.operating_system;
    var position: usize = 10;
    if (options.extra) |extra| {
        std.mem.writeInt(u16, bytes[position..][0..2], @intCast(extra.len), .little);
        position += 2;
        @memcpy(bytes[position..][0..extra.len], extra);
        position += extra.len;
    }
    inline for (.{ options.name, options.comment }) |field| {
        if (field) |text| {
            @memcpy(bytes[position..][0..text.len], text);
            position += text.len;
            bytes[position] = 0;
            position += 1;
        }
    }
    if (options.header_crc) {
        const checksum: u16 = @truncate(Crc32IsoHdlc.hash(bytes[0..position]));
        std.mem.writeInt(u16, bytes[position..][0..2], checksum, .little);
    }
}
