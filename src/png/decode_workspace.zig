//! Caller-owned scattered raster backing and contiguous decoder reservations.

const std = @import("std");
const Header = @import("Header.zig");
const deflate = @import("../deflate.zig");
const raster = @import("raster_decoder.zig");
const png = @import("../png.zig");
const Source = @import("Source.zig");
const png_raster_vectors = @import("testdata/raster.zig");

/// Caller-owned, mutually disjoint stable raster backing. No field supplies allocation authority.
/// Keep the workspace and history at their addresses while decoding. Packed and conversion rows are
/// scratch: used prefixes may change on failure, while unused capacity remains unchanged.
pub fn Storage(comptime Sample: type) type {
    return struct {
        /// Existing DEFLATE workspace constructed at its final address.
        workspace: *deflate.DecoderWorkspace,
        /// At least the generic dependency's 32 KiB history requirement.
        history: []u8,
        /// Two packed full-width filter rows, as reported by requirements.
        packed_rows: []u8,
        /// One converted full-width RGBA row in byte or native-word elements.
        conversion_row: []Sample,
    };
}

/// One contiguous reservation for complete-source decoding, regions or rows. It supplies native
/// DEFLATE state, history, two packed rows and a converted RGBA row. Output and any selected Adam7
/// row reconstruction remain separate. Copies borrow the same backing; serialize its use.
pub fn Workspace(comptime Sample: type) type {
    if (Sample != u8 and Sample != u16) @compileError("PNG output samples must be u8 or u16");
    return struct {
        const Self = @This();

        /// Complete borrowed or owned byte span, including alignment padding.
        allocation: []u8,
        /// Prepared views into allocation. Keep their addresses and lengths unchanged while in use.
        storage: Storage(Sample),

        /// Invalid geometry, capacity overflow, backing shortage or allocation failure.
        pub const Error = raster.Error || std.mem.Allocator.Error || error{
            SizeOverflow,
            WorkspaceTooSmall,
        };

        /// Checked byte-aligned capacity, including worst-case native-state and sample padding. The
        /// header must retain admitted geometry from Source.header or Header.fromIhdr.
        pub fn byteCount(header: Header) Error!usize {
            const required = try raster.requirements(Sample, header);
            var bytes: usize = @sizeOf(
                deflate.DecoderWorkspace,
            ) + @alignOf(deflate.DecoderWorkspace) - 1;
            for (
                [_]usize{
                    required.history_bytes,
                    required.packed_rows_bytes,
                    @alignOf(Sample) - 1,
                    required.conversion_row_bytes,
                },
            ) |part| bytes = std.math.add(usize, bytes, part) catch return error.SizeOverflow;
            return bytes;
        }

        /// Binds caller capacity without allocating or writing it. Backing stays at its final
        /// address and disjoint from encoded input, output and optional reconstruction storage. The
        /// full byteCount capacity is required. Release borrowed backing yourself; deinit applies
        /// only to initCapacity. A descriptor can be reused for any image its storage fits.
        pub fn initBuffer(backing: []u8, header: Header) Error!Self {
            const bytes = try byteCount(header);
            if (backing.len < bytes) return error.WorkspaceTooSmall;
            const required = try raster.requirements(Sample, header);
            const base = @intFromPtr(backing.ptr);
            const state_offset = std.mem.alignForward(
                usize,
                base,
                @alignOf(deflate.DecoderWorkspace),
            ) - base;
            const history_offset = state_offset + @sizeOf(deflate.DecoderWorkspace);
            const rows_offset = history_offset + required.history_bytes;
            const after_rows = rows_offset + required.packed_rows_bytes;
            const conversion_offset = std.mem.alignForward(
                usize,
                base + after_rows,
                @alignOf(Sample),
            ) - base;
            const conversion_bytes = backing[conversion_offset..][0..required.conversion_row_bytes];
            return .{
                .allocation = backing[0..bytes],
                .storage = .{
                    .workspace = @ptrCast(@alignCast(backing[state_offset..].ptr)),
                    .history = backing[history_offset..][0..required.history_bytes],
                    .packed_rows = backing[rows_offset..][0..required.packed_rows_bytes],
                    .conversion_row = std.mem.bytesAsSlice(
                        Sample,
                        @as([]align(@alignOf(Sample)) u8, @alignCast(conversion_bytes)),
                    ),
                },
            };
        }

        /// Allocates one complete reservation without retaining the allocator or initializing
        /// unused scratch. No partial owner escapes failure. Release through deinit.
        pub fn initCapacity(allocator: std.mem.Allocator, header: Header) Error!Self {
            const allocation = try allocator.alloc(u8, try byteCount(header));
            return initBuffer(allocation, header) catch unreachable;
        }

        /// Releases the full reservation created with this allocator after every borrow ends.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.allocation);
            self.* = undefined;
        }

        test initCapacity {
            const allocator = std.testing.allocator;
            const bytes = try png.encode.alloc(
                allocator,
                try png.ImageInput.rgba8(&.{ 255, 0, 0, 128 }, 1, 1),
                .{},
            );
            defer allocator.free(bytes);
            const image = try png.Source.open(bytes, .{});
            var workspace = try initCapacity(allocator, image.header());
            defer workspace.deinit(allocator);
            var output: [4]Sample = undefined;
            const result = try image.decodeRgbaInto(
                Sample,
                &output,
                workspace.storage,
                .{ .publication = .transactional },
            );
            try std.testing.expectEqual(255 * (if (Sample == u8) 1 else 257), result.texels[0]);
            try std.testing.expectEqual(128 * (if (Sample == u8) 1 else 257), result.texels[3]);
        }

        test "PNG decoder reservation covers every alignment residue and preserves guards" {
            const allocator = std.testing.allocator;
            const source = try Source.open(png_raster_vectors.sequential_png, .{});
            const header = source.header();
            const bytes = try byteCount(header);
            const alignment = @alignOf(deflate.DecoderWorkspace);
            const backing = try allocator.alignedAlloc(
                u8,
                .fromByteUnits(alignment),
                bytes + alignment + 2,
            );
            defer allocator.free(backing);
            for (0..alignment) |residue| {
                @memset(backing, 0xa5);
                const start = 1 + residue;
                const workspace = try initBuffer(backing[start..][0..bytes], header);
                for (backing) |byte| try std.testing.expectEqual(0xa5, byte);
                try std.testing.expectEqual(
                    0,
                    @intFromPtr(workspace.storage.workspace) % alignment,
                );
                try std.testing.expectEqual(
                    0,
                    @intFromPtr(workspace.storage.conversion_row.ptr) % @alignOf(Sample),
                );
                @memset(workspace.storage.history, 0x12);
                @memset(workspace.storage.packed_rows, 0x34);
                @memset(workspace.storage.conversion_row, 0x56);
                for (workspace.storage.history) |byte| try std.testing.expectEqual(0x12, byte);
                for (workspace.storage.packed_rows) |byte| try std.testing.expectEqual(0x34, byte);
                for (backing[0..start]) |byte| try std.testing.expectEqual(0xa5, byte);
                for (backing[start + bytes ..]) |byte| try std.testing.expectEqual(0xa5, byte);
                try std.testing.expectError(
                    error.WorkspaceTooSmall,
                    initBuffer(backing[start..][0 .. bytes - 1], header),
                );
            }
            try std.testing.expectError(
                error.OutOfMemory,
                initCapacity(std.testing.failing_allocator, header),
            );
        }
    };
}
