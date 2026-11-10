//! Replayable compressed PNG image data borrowed from an admitted source. The source and its
//! admitted chunk ranges remain live and unchanged while these views are used. `first` is the
//! complete stream payload only when `multiple` is false. Change fields only when constructing an
//! admitted source or frame view.

const std = @import("std");

const ImageData = @This();

/// Admitted payload framing. fdAT sequence words are excluded from every read.
kind: Kind = .idat,
/// Complete admitted PNG source, live and unchanged for every replay.
source: []const u8,
/// First selected payload, without its sequence word; complete input for one chunk.
first: []const u8,
/// Offset of the first selected data chunk header in source.
first_offset: usize,
/// End of the final selected data chunk, including its CRC.
after_last: usize,
/// Whether at least two selected data chunks occur, including empty payloads.
multiple: bool,
/// Total selected payload bytes, excluding sequence words and including unused stream tails.
byte_count: usize,

/// Compressed PNG stream payload framing; frame data omits each fdAT sequence word.
pub const Kind = enum { idat, fdat };

/// Movable iterator over structurally admitted IDAT or fdAT payload borrows. It skips fdAT sequence
/// words and intervening ancillary chunks without joining input. Source/range fields come from an
/// admitted ImageData; keep them unchanged and source live.
pub const Iterator = struct {
    /// Complete immutable admitted PNG source.
    source: []const u8,
    /// IDAT or selected-frame fdAT framing.
    kind: Kind,
    /// Header of the next chunk in the admitted range.
    next_chunk: usize,
    /// End of the final selected data chunk, including its CRC.
    after_last_chunk: usize,

    /// Borrows the next payload, including an empty selected chunk; null ends the range. No
    /// CRC/framing admission is repeated and no pointer into this iterator is retained.
    pub fn next(self: *Iterator) ?[]const u8 {
        while (self.next_chunk != self.after_last_chunk) {
            const chunk = self.next_chunk;
            const start = chunk + 8;
            const end = start + @as(usize, readU32Big(self.source, chunk));
            self.next_chunk = end + 4;
            if (self.kind == .fdat) {
                if (!std.mem.eql(u8, self.source[chunk + 4 ..][0..4], "fdAT")) continue;
                return self.source[start + 4 .. end];
            }
            return self.source[start..end];
        }
        return null;
    }
};

/// Address-stable reader for CRC-admitted IDAT or fdAT ranges. The inline buffer covers inflater
/// lookahead without copying the compressed stream. Source bytes stay live and unchanged while the
/// reader is in use; initialize through ImageData.reader or use that description's admitted chunk
/// offsets.
pub const Reader = struct {
    /// Reader interface bound to this object's inline buffer.
    interface: std.Io.Reader,
    /// Complete admitted PNG source.
    source: []const u8,
    /// Admitted payload framing; fdAT ranges may include ignored ancillary chunks.
    kind: Kind,
    /// Offset of the next data chunk header to visit.
    next_chunk: usize,
    /// End of the final selected data chunk, including its CRC.
    after_last_chunk: usize,
    /// Unconsumed bytes in the current chunk payload.
    remaining: []const u8 = &.{},
    /// Bounded lookahead storage; the initialized object must remain at its address.
    buffer: [64]u8 = undefined,

    /// Initializes at the final address; `first` and `after_last` are admitted chunk offsets.
    pub fn init(
        self: *Reader,
        source: []const u8,
        first: usize,
        after_last: usize,
        kind: Kind,
    ) void {
        self.* = .{
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = &self.buffer,
                .seek = 0,
                .end = 0,
            },
            .source = source,
            .kind = kind,
            .next_chunk = first,
            .after_last_chunk = after_last,
        };
    }

    fn stream(
        input_reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("interface", input_reader));
        while (self.remaining.len == 0) {
            var iterator: Iterator = .{
                .source = self.source,
                .kind = self.kind,
                .next_chunk = self.next_chunk,
                .after_last_chunk = self.after_last_chunk,
            };
            self.remaining = iterator.next() orelse return error.EndOfStream;
            self.next_chunk = iterator.next_chunk;
        }
        const written = try writer.write(self.remaining[0..limit.minInt(self.remaining.len)]);
        self.remaining = self.remaining[written..];
        return written;
    }
};

/// Starts movable, allocation-free payload iteration without an address-stable Reader. Returned
/// slices borrow the same immutable source; all selected chunk CRCs/bounds and fdAT sequence
/// framing must already be admitted. Call again to start another traversal.
pub fn payloads(data: ImageData) Iterator {
    return .{
        .source = data.source,
        .kind = data.kind,
        .next_chunk = data.first_offset,
        .after_last_chunk = data.after_last,
    };
}

/// Initializes a fresh reader over unchanged source. Only the selected reader is initialized or
/// returned. Keep that selected owner at its address while using the interface; calling again
/// restarts input and invalidates its previous buffered views. Separate owner pairs allow
/// independent readers of the same immutable source.
///
/// The returned interface reads compressed bytes only; it does not admit the zlib header or
/// checksum. Buffered slices borrow source or reader storage.
pub fn reader(data: ImageData, fixed: *std.Io.Reader, chunked: *Reader) *std.Io.Reader {
    if (data.multiple) {
        chunked.init(data.source, data.first_offset, data.after_last, data.kind);
        return &chunked.interface;
    }
    fixed.* = .fixed(data.first);
    return fixed;
}

/// Joins admitted data payloads into exactly byte_count bytes of caller storage. Destination is
/// disjoint from source. The original chunk CRCs are already checked; zlib stream validation still
/// belongs to the consumer of the joined bytes.
pub fn copyInto(data: ImageData, destination: []u8) void {
    std.debug.assert(destination.len == data.byte_count);
    var written: usize = 0;
    var iterator = payloads(data);
    while (iterator.next()) |payload| {
        @memcpy(destination[written..][0..payload.len], payload);
        written += payload.len;
    }
    std.debug.assert(written == destination.len);
}

fn readU32Big(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}
