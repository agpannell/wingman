//! LZ4 version-1 descriptor admission and fixed-order frame header serialization. Format:
//! https://github.com/lz4/lz4/blob/v1.10.0/doc/lz4_Frame_format.md Reference API:
//! https://github.com/lz4/lz4/blob/v1.10.0/lib/lz4frame.h

const std = @import("std");
const Xxh32 = @import("../xxhash.zig").Xxh32;
const framing = @import("frame.zig");
const blocks = @import("block.zig");

pub const magic: u32 = 0x184d2204;
pub const skip_magic: u32 = 0x184d2a50;
pub const Error = error{ InvalidFrame, ChecksumMismatch };

pub fn dictionarySuffix(bytes: []const u8) []const u8 {
    return bytes[bytes.len - @min(bytes.len, blocks.maximum_distance) ..];
}

pub fn descriptorSize(prefix: []const u8) error{InvalidFrame}!usize {
    // Validate the fixed descriptor bits before trusting the optional-field flags to size a read.
    const flags = prefix[0];
    const block_descriptor = prefix[1];
    const version = flags >> 6;
    const reserved_flags = flags & 2;
    const reserved_block_bits = block_descriptor & 0x8f;
    const block_size_id = block_descriptor >> 4;
    if (version != 1 or reserved_flags != 0) return error.InvalidFrame;
    if (reserved_block_bits != 0 or block_size_id < 4) return error.InvalidFrame;
    const content_bytes: usize = if (flags & 8 != 0) 8 else 0;
    const dictionary_bytes: usize = if (flags & 1 != 0) 4 else 0;
    return 3 + content_bytes + dictionary_bytes;
}

pub fn parseDescriptor(bytes: []const u8) Error!framing.Descriptor {
    const size = try descriptorSize(bytes[0..2]);
    std.debug.assert(bytes.len == size);
    const checksum: u8 = @truncate(Xxh32.hash(bytes[0 .. size - 1]) >> 8);
    if (checksum != bytes[size - 1]) return error.ChecksumMismatch;

    // Optional content size precedes dictionary ID in the wire descriptor. Preserve each as an
    // optional value so a present zero remains distinguishable from an absent field.
    const flags = bytes[0];
    var cursor: usize = 2;
    const content_size: ?u64 = blk: {
        if (flags & 8 == 0) break :blk null;
        const value = std.mem.readInt(u64, bytes[cursor..][0..8], .little);
        cursor += 8;
        break :blk value;
    };
    const dictionary_id: ?u32 = blk: {
        if (flags & 1 == 0) break :blk null;
        break :blk std.mem.readInt(u32, bytes[cursor..][0..4], .little);
    };
    return .{
        .block_size = @fromBackingInt(@as(u3, @intCast(bytes[1] >> 4))),
        .independent = flags & 32 != 0,
        .block_checksum = flags & 16 != 0,
        .content_checksum = flags & 4 != 0,
        .content_size = content_size,
        .dictionary_id = dictionary_id,
    };
}

// Serialize FLG, BD and optional values in the format's fixed order, then checksum the descriptor
// bytes. All metadata is supplied before writing, so this header is never patched later.
pub fn writeHeader(output: *[19]u8, descriptor: framing.Descriptor) usize {
    std.mem.writeInt(u32, output[0..4], magic, .little);
    var flags: u8 = 0x40;
    flags |= if (descriptor.independent) @as(u8, 32) else 0;
    flags |= if (descriptor.block_checksum) @as(u8, 16) else 0;
    flags |= if (descriptor.content_size != null) @as(u8, 8) else 0;
    flags |= if (descriptor.content_checksum) @as(u8, 4) else 0;
    flags |= if (descriptor.dictionary_id != null) @as(u8, 1) else 0;
    output[4] = flags;
    output[5] = @as(u8, @backingInt(descriptor.block_size)) << 4;
    var size: usize = 6;
    if (descriptor.content_size) |value| {
        std.mem.writeInt(u64, output[size..][0..8], value, .little);
        size += 8;
    }
    if (descriptor.dictionary_id) |value| {
        std.mem.writeInt(u32, output[size..][0..4], value, .little);
        size += 4;
    }
    output[size] = @truncate(Xxh32.hash(output[4..size]) >> 8);
    return size + 1;
}
