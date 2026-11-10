//! PNG scanline filter selection and inverse reconstruction.

const std = @import("std");
const builtin = @import("builtin");
const png_format = @import("format.zig");
const RgbaConverter = @import("RgbaConverter.zig");
const Error = png_format.Error;
const expandRgb8InPlace = RgbaConverter.expandRgb8InPlace;

/// Scanline filter choice, independent of DEFLATE compression.
pub const Filter = union(enum) {
    /// One PNG byte predictor; its integer is the emitted scanline selector.
    pub const Type = enum(u8) {
        /// Preserve every byte.
        none = 0,
        /// Subtract the preceding pixel's corresponding byte.
        sub = 1,
        /// Subtract the preceding row's corresponding byte.
        up = 2,
        /// Subtract the floor average of left and up.
        average = 3,
        /// Subtract PNG's nearest left/up/upper-left predictor with specified tie order.
        paeth = 4,
    };

    /// Apply one predictor to every scanline, including each pass's first row.
    fixed: Type,
    /// Try all five predictors and minimize signed-byte absolute sums; lower selector wins ties.
    adaptive,
};

const filter_vector_lanes = std.simd.suggestVectorLength(u8) orelse 1;

const sub_filter_vector_lanes = 4;

/// Reconstructs one admitted row using PNG filter 0 through 4 and its pixel-byte stride. Slices
/// have equal lengths; `previous_row`, when present, is disjoint from destination. Filtered input
/// may equal destination, be disjoint, or overlap ahead of destination. The caller validates the
/// filter and retains the preceding reconstructed row. The byte stride is nonzero and matches the
/// packed format. Invalid filter codes violate a precondition; this allocation-free kernel does not
/// return validation errors.
pub fn reconstructRow(
    destination: []u8,
    filtered: []const u8,
    previous_row: ?[]const u8,
    filter_bytes_per_pixel: usize,
    filter: u8,
) void {
    const row_bytes = destination.len;
    switch (filter) {
        0 => {
            copyFilteredRow(destination, filtered);
        },
        2 => {
            const previous = previous_row orelse {
                copyFilteredRow(destination, filtered);
                return;
            };
            var column: usize = 0;
            while (column + filter_vector_lanes <= row_bytes) : (column += filter_vector_lanes) {
                const current: @Vector(
                    filter_vector_lanes,
                    u8,
                ) = filtered[column..][0..filter_vector_lanes].*;
                const up: @Vector(
                    filter_vector_lanes,
                    u8,
                ) = previous[column..][0..filter_vector_lanes].*;
                destination[column..][0..filter_vector_lanes].* = current +% up;
            }
            while (column < row_bytes) : (column += 1) destination[column] = filtered[column] +%
                previous[column];
        },
        1 => {
            var column: usize = 0;
            if (filter_bytes_per_pixel == 1) {
                // Four prefix steps reconstruct sixteen packed bytes in registers. Load the exact
                // batch before any overlapping destination store.
                var carry: @Vector(16, u8) = @splat(0);
                const zero: @Vector(16, u8) = @splat(0);
                while (row_bytes - column >= 16) : (column += 16) {
                    const current: @Vector(16, u8) = filtered[column..][0..16].*;
                    const pairs = current +% @shuffle(
                        u8,
                        current,
                        zero,
                        @as(
                            @Vector(16, i32),
                            .{ -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 },
                        ),
                    );
                    const fours = pairs +% @shuffle(
                        u8,
                        pairs,
                        zero,
                        @as(
                            @Vector(16, i32),
                            .{ -1, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 },
                        ),
                    );
                    const eights = fours +% @shuffle(
                        u8,
                        fours,
                        zero,
                        @as(
                            @Vector(16, i32),
                            .{ -1, -1, -1, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
                        ),
                    );
                    const prefix = eights +% @shuffle(
                        u8,
                        eights,
                        zero,
                        @as(
                            @Vector(16, i32),
                            .{ -1, -1, -1, -1, -1, -1, -1, -1, 0, 1, 2, 3, 4, 5, 6, 7 },
                        ),
                    );
                    const reconstructed = prefix +% carry;
                    destination[column..][0..16].* = reconstructed;
                    carry = @splat(reconstructed[15]);
                }
                var left = carry[0];
                while (column < row_bytes) : (column += 1) {
                    left +%= filtered[column];
                    destination[column] = left;
                }
            } else if (filter_bytes_per_pixel == sub_filter_vector_lanes) {
                const zero: @Vector(16, u8) = @splat(0);
                var carry = zero;
                while (row_bytes - column >= 16) : (column += 16) {
                    // Two prefix steps sum four pixels independently by channel. Carry the
                    // preceding reconstructed pixel in registers. Load every input byte before
                    // storing so forward compaction needs no padding.
                    const current: @Vector(16, u8) = filtered[column..][0..16].*;
                    const pairs = current +% @shuffle(
                        u8,
                        current,
                        zero,
                        @as(
                            @Vector(16, i32),
                            .{ -1, -1, -1, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
                        ),
                    );
                    const prefix = pairs +% @shuffle(
                        u8,
                        pairs,
                        zero,
                        @as(
                            @Vector(16, i32),
                            .{ -1, -1, -1, -1, -1, -1, -1, -1, 0, 1, 2, 3, 4, 5, 6, 7 },
                        ),
                    );
                    const reconstructed = prefix +% carry;
                    destination[column..][0..16].* = reconstructed;
                    carry = @shuffle(
                        u8,
                        reconstructed,
                        undefined,
                        @as(
                            @Vector(16, i32),
                            .{ 12, 13, 14, 15, 12, 13, 14, 15, 12, 13, 14, 15, 12, 13, 14, 15 },
                        ),
                    );
                }
                while (row_bytes - column >= sub_filter_vector_lanes) : (column +=
                    sub_filter_vector_lanes)
                {
                    const current: @Vector(
                        sub_filter_vector_lanes,
                        u8,
                    ) = filtered[column..][0..sub_filter_vector_lanes].*;
                    const left: @Vector(
                        sub_filter_vector_lanes,
                        u8,
                    ) = if (column >= sub_filter_vector_lanes) destination[column -
                        sub_filter_vector_lanes ..][0..sub_filter_vector_lanes].* else @splat(
                        0,
                    );
                    destination[column..][0..sub_filter_vector_lanes].* = current +% left;
                }
            }
            if (filter_bytes_per_pixel == 2) {
                column = reconstructSubByteChannels(2, destination, filtered);
            } else if (filter_bytes_per_pixel == 6) {
                column = reconstructSubByteChannels(6, destination, filtered);
            }
            while (column < row_bytes) : (column += 1) {
                const left = if (column >= filter_bytes_per_pixel) destination[
                    column -
                        filter_bytes_per_pixel
                ] else 0;
                destination[column] = filtered[column] +% left;
            }
        },
        inline 3, 4 => |selected_filter| {
            var column: usize = 0;
            if (filter_bytes_per_pixel == 1) {
                // Packed samples share one byte channel. Retain both neighbors in registers rather
                // than depending on the preceding output store.
                var left: u8 = 0;
                var upper_left: u8 = 0;
                while (column < row_bytes) : (column += 1) {
                    const current = filtered[column];
                    const up = if (previous_row) |previous| previous[column] else 0;
                    const predictor: u8 = if (selected_filter == 3) @intCast(
                        (@as(u16, left) + up) / 2,
                    ) else paethThreshold(left, up, upper_left);
                    left = current +% predictor;
                    destination[column] = left;
                    upper_left = up;
                }
            } else if (filter_bytes_per_pixel == 3) {
                // Keep RGB's packed-word loop separate from RGBA's exact-word loop.
                column = @call(
                    .never_inline,
                    reconstructRgb8Pixels,
                    .{ selected_filter, destination, filtered, previous_row },
                );
            } else {
                inline for (.{ 2, 4, 6, 8 }) |lanes| {
                    if (filter_bytes_per_pixel == lanes) {
                        var left: @Vector(lanes, if (selected_filter == 3) u8 else i16) = @splat(0);
                        var upper_left: @Vector(lanes, i16) = @splat(0);
                        while (row_bytes - column >= lanes) : (column += lanes) {
                            const current: @Vector(lanes, u8) = filtered[column..][0..lanes].*;
                            const ByteVector = @Vector(lanes, u8);
                            const zero: ByteVector = @splat(0);
                            const up: ByteVector = if (previous_row) |previous|
                                previous[column..][0..lanes].*
                            else
                                zero;
                            left = reconstructChannels(
                                selected_filter,
                                lanes,
                                current,
                                up,
                                left,
                                upper_left,
                            );
                            const reconstructed = reconstructedBytes(left);
                            destination[column..][0..lanes].* = reconstructed;
                            upper_left = up;
                        }
                    }
                }
            }
            // Only an incomplete admitted byte group remains for scalar reconstruction.
            while (column < row_bytes) : (column += 1) {
                const has_left = column >= filter_bytes_per_pixel;
                const left = if (has_left) destination[column - filter_bytes_per_pixel] else 0;
                const up = if (previous_row) |previous| previous[column] else 0;
                var upper_left: u8 = 0;
                if (previous_row) |previous| {
                    if (has_left) upper_left = previous[column - filter_bytes_per_pixel];
                }
                const predictor: u8 = if (selected_filter == 3) @intCast(
                    (@as(u16, left) + up) / 2,
                ) else paethThreshold(left, up, upper_left);
                destination[column] = filtered[column] +% predictor;
            }
        },
        else => unreachable,
    }
}

fn reconstructSubByteChannels(
    comptime stride: usize,
    destination: []u8,
    filtered: []const u8,
) usize {
    // Prefix sums follow each channel, even when six-byte pixels cross a batch edge. Replicate the
    // final stride bytes as carry; load all input before an overlap store.
    const zero: @Vector(16, u8) = @splat(0);
    var carry = zero;
    const carry_indices: @Vector(16, i32) = comptime blk: {
        var mask: [16]i32 = undefined;
        for (&mask, 0..) |*lane, index| lane.* = @intCast(16 - stride + index % stride);
        break :blk mask;
    };
    var column: usize = 0;
    while (destination.len - column >= 16) : (column += 16) {
        var prefix: @Vector(16, u8) = filtered[column..][0..16].*;
        inline for (.{ 1, 2, 4, 8 }) |multiple| {
            const shift = stride * multiple;
            if (shift < 16) {
                const indices: @Vector(16, i32) = comptime blk: {
                    var mask: [16]i32 = undefined;
                    for (&mask, 0..) |*lane, index| {
                        lane.* = if (index < shift) -1 else @intCast(index - shift);
                    }
                    break :blk mask;
                };
                prefix +%= @shuffle(u8, prefix, zero, indices);
            }
        }
        const reconstructed = prefix +% carry;
        destination[column..][0..16].* = reconstructed;
        carry = @shuffle(u8, reconstructed, undefined, carry_indices);
    }
    return column;
}

// Reconstruct complete RGB8 pixels with four independent lanes, discarding the spare. Return the
// consumed prefix so the ordinary row kernel handles a partial pixel tail.
fn reconstructRgb8Pixels(
    comptime filter: u8,
    destination: []u8,
    filtered: []const u8,
    previous_row: ?[]const u8,
) usize {
    var left: @Vector(4, if (filter == 3) u8 else i16) = @splat(0);
    var upper_left: @Vector(4, i16) = @splat(0);
    var column: usize = 0;
    while (destination.len - column >= 3) : (column += 3) {
        const current: @Vector(4, u8) = @bitCast(loadFilterWord(3, filtered, column));
        const up: @Vector(
            4,
            u8,
        ) = if (previous_row) |previous| @bitCast(
            loadFilterWord(3, previous, column),
        ) else @splat(0);
        left = reconstructChannels(filter, 4, current, up, left, upper_left);
        const reconstructed = reconstructedBytes(left);
        storeFilterWord(3, destination, column, @bitCast(reconstructed));
        upper_left = up;
    }
    return column;
}

/// Reconstructs admitted noninterlaced RGBA8 rows and removes their filter bytes. Geometry is
/// caller-validated: each of `height` rows has a filter byte followed by `row_bytes` sample bytes,
/// and the slice contains exactly these rows. On success, the first `height * row_bytes` bytes hold
/// pixels; the remaining tail is scratch. Invalid selectors may modify scratch before returning
/// InvalidPng. This function allocates no storage and never publishes an image; the decoder owns
/// publication.
pub fn reconstructRgba8Rows(filtered: []u8, row_bytes: usize, height: usize) Error!void {
    return reconstructRows(4, true, filtered, row_bytes, height);
}

/// Reconstructs admitted noninterlaced RGB8 rows and removes their filter bytes. The slice contains
/// exactly height rows of a selector followed by row_bytes samples. On success, its first height *
/// row_bytes bytes hold packed RGB; the tail is scratch. Invalid selectors may change scratch
/// before returning InvalidPng.
pub fn reconstructRgb8Rows(filtered: []u8, row_bytes: usize, height: usize) Error!void {
    return reconstructRows(3, true, filtered, row_bytes, height);
}

/// Reconstructs one admitted packed pass in place, retaining its filter selectors. Each row has one
/// selector and exactly `row_bytes` bytes; `filtered` contains exactly `height` rows. Supply the
/// format's filter byte stride (1, 2, 3, 4, 6 or 8) and whole stride groups. Packed sub-byte
/// formats use stride one. Pass history resets at the first row. Invalid selectors may modify
/// samples before returning InvalidPng. This operation allocates nothing and never publishes an
/// image.
pub fn reconstructPackedRows(
    filtered: []u8,
    row_bytes: usize,
    height: usize,
    filter_bytes_per_pixel: usize,
) Error!void {
    switch (filter_bytes_per_pixel) {
        inline 1, 2, 3, 4, 6, 8 => |stride| {
            return reconstructRows(stride, false, filtered, row_bytes, height);
        },
        else => unreachable,
    }
}

// Keep conversion next to reconstruction when a pass has no diagonal group. A selector scan avoids
// a separate reconstruction pass when no same-filter run can batch. It is an optimization gate, not
// validation: the selected pixel path still admits every selector before the decoder publishes
// output.
/// Reports whether a packed pass contains four adjacent equal Average/Paeth selectors at the same
/// width cutoffs used by reconstruction. This is an optimization query; neither result validates
/// all selectors. The input is unchanged. Supply exactly `height * (row_bytes + 1)` bytes and the
/// admitted pixel-byte stride 1, 2, 3, 4, 6 or 8; row bytes contain complete stride groups.
pub fn packedPassHasGroups(
    filtered: []const u8,
    row_bytes: usize,
    height: usize,
    pixel_bytes: usize,
) bool {
    if (height < 4 or row_bytes < 8 * pixel_bytes) return false;
    const stride = row_bytes + 1;
    var previous: u8 = 0;
    var run: usize = 0;
    for (0..height) |row| {
        const filter = filtered[row * stride];
        if (groupableFilterWidth(row_bytes, pixel_bytes, filter)) {
            run = if (filter == previous) run + 1 else 1;
            if (run == 4) return true;
        } else run = 0;
        previous = filter;
    }
    return false;
}

fn groupableFilterWidth(row_bytes: usize, pixel_bytes: usize, filter: u8) bool {
    return switch (filter) {
        3 => row_bytes >= 32 * pixel_bytes,
        4 => row_bytes >= 8 * pixel_bytes,
        else => false,
    };
}

fn reconstructRows(
    comptime pixel_bytes: usize,
    comptime compact: bool,
    filtered: []u8,
    row_bytes: usize,
    height: usize,
) Error!void {
    std.debug.assert(row_bytes % pixel_bytes == 0 and filtered.len == height * (row_bytes + 1));
    const group = 4;
    var row: usize = 0;
    while (row < height) {
        const stride = row_bytes + 1;
        const filter = filtered[row * stride];
        if (filter > 4) return error.InvalidPng;
        const previous: ?[]const u8 = if (row == 0) null else if (compact) filtered[(row - 1) *
            row_bytes ..][0..row_bytes] else filtered[(row - 1) * stride + 1 ..][0..row_bytes];
        // Vector setup and optional compaction must repay their cost. Stride-specific minimum
        // widths leave short rows on the ordinary row loop.
        const batch_width = groupableFilterWidth(row_bytes, pixel_bytes, filter);
        // Zig 0.17 LLVM big-endian grouped edges lose channel history, so use ordinary row
        // reconstruction on big-endian targets.
        var grouped = batch_width and height - row >= group and builtin.cpu.arch.endian() != .big;
        if (grouped) {
            for (1..group) |index| {
                if (filtered[(row + index) * stride] != filter) {
                    grouped = false;
                    break;
                }
            }
        }
        if (grouped) {
            var rows: [group][]u8 = undefined;
            inline for (
                0..group,
            ) |index| rows[index] = filtered[(row + index) * stride + 1 ..][0..row_bytes];
            // Keep each filter's grouped reconstruction together so the compiler can optimize its
            // row dependencies across the four rows.
            if (filter == 3) {
                @call(.always_inline, reconstructGroup, .{ pixel_bytes, 3, rows, previous });
            } else {
                @call(.always_inline, reconstructGroup, .{ pixel_bytes, 4, rows, previous });
            }
            // Reconstruct in place before compaction. Earlier compacted output can overlap a
            // preceding row's unread tail during diagonal traversal.
            if (compact) {
                inline for (
                    0..group,
                ) |index| @memmove(
                    filtered[(row + index) * row_bytes ..][0..row_bytes],
                    rows[index],
                );
            }
            row += group;
        } else {
            if (compact and (filter == 0 or (filter == 2 and previous == null))) {
                @memmove(
                    filtered[row * row_bytes ..][0..row_bytes],
                    filtered[row * stride + 1 ..][0..row_bytes],
                );
            } else {
                reconstructRow(
                    if (compact) filtered[row * row_bytes ..][0..row_bytes] else filtered[row *
                        stride + 1 ..][0..row_bytes],
                    filtered[row * stride + 1 ..][0..row_bytes],
                    previous,
                    pixel_bytes,
                    filter,
                );
            }
            row += 1;
        }
    }
}

/// Reconstructs opaque Average RGB8 samples directly into their final RGBA8 slots. The exact RGBA
/// slice initially contains height filtered RGB rows at its start. Each selector is already
/// admitted as Average; row_bytes is a positive whole RGB width, height is positive, all size
/// products fit usize, and rgba.len is width * height * 4. The filtered frame moves to the
/// allocation's tail before writing. No padding or extra allocation is required. All returned alpha
/// bytes are 255.
pub fn reconstructAverageRgb8Rgba8(rgba: []u8, row_bytes: usize, height: usize) void {
    const width = row_bytes / 3;
    const stride = row_bytes + 1;
    const filtered_length = stride * height;
    std.debug.assert(row_bytes > 0 and row_bytes % 3 == 0 and height > 0);
    std.debug.assert(rgba.len == width * height * 4);
    const filtered = rgba[rgba.len - filtered_length ..];
    @memmove(filtered, rgba[0..filtered_length]);

    const wide_batches = if (filter_vector_lanes >= 64) 4 else if (filter_vector_lanes >= 32)
        2
    else
        1;
    const wide_group = wide_batches * 4;
    const group = 4;
    var row: usize = 0;
    if (wide_batches > 1 and width >= 128 and height >= 4 * wide_group - 3) {
        // Keep the larger slice/register frame out of the small-image path. One call processes all
        // wide groups; a call for each group loses the gain.
        row = @call(
            .never_inline,
            reconstructAverageRgbWideRows,
            .{ wide_batches, rgba, filtered, row_bytes, height },
        );
    }
    // A diagonal writes the final row ahead of the first row's remaining input. At least 4*group-3
    // remaining rows keep every store below every unread input byte even at the last column. Close
    // the final region one row at a time.
    while (width >= 32 and height - row >= 4 * group - 3) : (row += group) {
        var input: [group][]const u8 = undefined;
        var output: [group][]u8 = undefined;
        inline for (0..group) |index| {
            input[index] = filtered[(row + index) * stride + 1 ..][0..row_bytes];
            output[index] = rgba[(row + index) * width * 4 ..][0 .. width * 4];
        }
        reconstructAverageRgbGroup(
            1,
            input,
            output,
            if (row == 0) null else rgba[(row - 1) * width * 4 ..][0 .. width * 4],
        );
    }
    while (row < height) : (row += 1) {
        reconstructAverageRgbRange(
            filtered[row * stride + 1 ..][0..row_bytes],
            rgba[row * width * 4 ..][0 .. width * 4],
            if (row == 0) null else rgba[(row - 1) * width * 4 ..][0 .. width * 4],
            0,
            width,
        );
    }
}

fn reconstructAverageRgbWideRows(
    comptime batches: usize,
    rgba: []u8,
    filtered: []const u8,
    row_bytes: usize,
    height: usize,
) usize {
    const width = row_bytes / 3;
    const stride = row_bytes + 1;
    const group = batches * 4;
    var row: usize = 0;
    while (height - row >= 4 * group - 3) : (row += group) {
        var input: [group][]const u8 = undefined;
        var output: [group][]u8 = undefined;
        inline for (0..group) |index| {
            input[index] = filtered[(row + index) * stride + 1 ..][0..row_bytes];
            output[index] = rgba[(row + index) * width * 4 ..][0 .. width * 4];
        }
        reconstructAverageRgbGroup(
            batches,
            input,
            output,
            if (row == 0) null else rgba[(row - 1) * width * 4 ..][0 .. width * 4],
        );
    }
    return row;
}

fn reconstructAverageRgbRange(
    input: []const u8,
    output: []u8,
    previous: ?[]const u8,
    begin: usize,
    count: usize,
) void {
    var left: @Vector(4, u8) = if (begin == 0) @splat(0) else output[(begin - 1) * 4 ..][0..4].*;
    var pixel = begin;
    while (pixel < begin + count) : (pixel += 1) {
        const current: @Vector(4, u8) = @bitCast(loadFilterWord(3, input, pixel * 3));
        const up: @Vector(4, u8) = if (previous) |bytes| bytes[pixel * 4 ..][0..4].* else @splat(0);
        left = reconstructChannels(3, 4, current, up, left, @splat(0));
        var samples: [4]u8 = left;
        samples[3] = 255;
        output[pixel * 4 ..][0..4].* = samples;
    }
}

fn reconstructAverageRgbGroup(
    comptime batches: usize,
    input: [batches * 4][]const u8,
    output: [batches * 4][]u8,
    previous: ?[]const u8,
) void {
    const group = batches * 4;
    // Four rows fit one sixteen-byte recurrence. Interleave several independent recurrences instead
    // of widening a single chain of dependent averages.
    const channels = 16;
    const width = input[0].len / 3;
    inline for (0..group - 1) |index| {
        reconstructAverageRgbRange(
            input[index],
            output[index],
            if (index == 0) previous else output[index - 1],
            0,
            group - index - 1,
        );
    }

    var left_words: [group]u32 = undefined;
    inline for (0..group) |index| {
        left_words[index] = if (index < group - 1) @bitCast(
            output[index][(group - index - 2) * 4 ..][0..4].*,
        ) else 0;
    }
    var left: [batches]@Vector(channels, u8) = undefined;
    inline for (0..batches) |batch| {
        left[batch] = @bitCast(left_words[batch * 4 ..][0..4].*);
    }
    const up_mask = comptime blk: {
        var mask: [channels]i32 = undefined;
        for (0..4) |index| mask[index] = @intCast(index);
        for (4..channels) |index| mask[index] = ~@as(i32, @intCast(index - 4));
        break :blk mask;
    };
    var pixel: usize = group - 1;
    // Four complete diagonals amortize scalar word insertion/extraction. RGB packets need sixteen
    // readable bytes, so leave at least six pixels. Extra bytes occupy independent discarded lanes;
    // the exact tail follows.
    while (width - pixel >= 6) : (pixel += 4) {
        var source_rows: [group]@Vector(4, u32) = undefined;
        const unpack = @as(
            @Vector(16, i32),
            .{ 0, 1, 2, 3, 3, 4, 5, 6, 6, 7, 8, 9, 9, 10, 11, 12 },
        );
        inline for (0..group) |index| {
            const bytes: @Vector(16, u8) = input[index][(pixel - index) * 3 ..][0..16].*;
            source_rows[index] = @bitCast(@shuffle(u8, bytes, undefined, unpack));
        }
        var columns: [batches][4]@Vector(4, u32) = undefined;
        inline for (0..batches) |batch| {
            columns[batch] = transposeRgbFilterWords(source_rows[batch * 4 ..][0..4].*);
        }
        const top: @Vector(
            4,
            u32,
        ) = if (previous) |bytes| @bitCast(bytes[pixel * 4 ..][0..16].*) else @splat(0);
        var diagonals: [batches][4]@Vector(4, u32) = undefined;
        inline for (0..4) |step| {
            // Every upper neighbor belongs to the preceding diagonal, even when it crosses from one
            // four-row group to the next.
            const old_left = left;
            inline for (0..batches) |batch| {
                const words: @Vector(4, u32) = @bitCast(old_left[batch]);
                const up: @Vector(
                    16,
                    u8,
                ) = if (batch == 0) @bitCast(
                    @shuffle(u32, top, words, @as(@Vector(4, i32), .{ step, -1, -2, -3 })),
                ) else @bitCast(
                    @shuffle(
                        u32,
                        @as(@Vector(4, u32), @bitCast(old_left[batch - 1])),
                        words,
                        @as(@Vector(4, i32), .{ 3, -1, -2, -3 }),
                    ),
                );
                left[batch] = reconstructChannels(
                    3,
                    16,
                    @bitCast(columns[batch][step]),
                    up,
                    old_left[batch],
                    @splat(0),
                );
                diagonals[batch][step] = @bitCast(left[batch]);
            }
        }
        var results: [batches][4]@Vector(4, u32) = undefined;
        inline for (0..batches) |batch| {
            results[batch] = transposeRgbFilterWords(diagonals[batch]);
        }
        const alpha: u32 = @bitCast([4]u8{ 0, 0, 0, 255 });
        inline for (0..group) |index| {
            const words = results[index / 4][index % 4] | @as(@Vector(4, u32), @splat(alpha));
            output[index][(pixel - index) * 4 ..][0..16].* = @bitCast(words);
        }
    }
    inline for (0..2) |phase| {
        const end = if (phase == 0) width - 1 else width;
        while (pixel < end) : (pixel += 1) {
            var words: @Vector(group, u32) = undefined;
            inline for (0..group) |index| {
                const column = (pixel - index) * 3;
                words[index] = if (phase == 0) @bitCast(
                    input[index][column..][0..4].*,
                ) else loadFilterWord(3, input[index], column);
            }
            const old_left = left;
            const packet: [group]u32 = words;
            inline for (0..batches) |batch| {
                const current: @Vector(16, u8) = @bitCast(packet[batch * 4 ..][0..4].*);
                const first_up: @Vector(4, u8) = if (batch == 0) blk: {
                    break :blk if (previous) |bytes| bytes[pixel * 4 ..][0..4].* else @splat(0);
                } else blk: {
                    const previous_batch: @Vector(4, u32) = @bitCast(old_left[batch - 1]);
                    break :blk @bitCast(previous_batch[3]);
                };
                const up = @shuffle(u8, first_up, old_left[batch], up_mask);
                left[batch] = reconstructChannels(
                    3,
                    channels,
                    current,
                    up,
                    old_left[batch],
                    @splat(0),
                );
                const result_words: @Vector(4, u32) = @bitCast(left[batch]);
                inline for (0..4) |index| {
                    const row_index = batch * 4 + index;
                    var samples: [4]u8 = @bitCast(result_words[index]);
                    samples[3] = 255;
                    output[row_index][(pixel - row_index) * 4 ..][0..4].* = samples;
                }
            }
        }
    }
    inline for (1..group) |index| {
        reconstructAverageRgbRange(
            input[index],
            output[index],
            output[index - 1],
            width - index,
            index,
        );
    }
}

inline fn transposeRgbFilterWords(rows: [4]@Vector(4, u32)) [4]@Vector(4, u32) {
    // The same transpose maps row packets to diagonals and reconstructed diagonals back to rows.
    // Each word retains byte order, including on big-endian targets.
    const low_a = @shuffle(u32, rows[0], rows[1], @as(@Vector(4, i32), .{ 0, -1, 1, -2 }));
    const high_a = @shuffle(u32, rows[0], rows[1], @as(@Vector(4, i32), .{ 2, -3, 3, -4 }));
    const low_b = @shuffle(u32, rows[2], rows[3], @as(@Vector(4, i32), .{ 0, -1, 1, -2 }));
    const high_b = @shuffle(u32, rows[2], rows[3], @as(@Vector(4, i32), .{ 2, -3, 3, -4 }));
    return .{
        @shuffle(u32, low_a, low_b, @as(@Vector(4, i32), .{ 0, 1, -1, -2 })),
        @shuffle(u32, low_a, low_b, @as(@Vector(4, i32), .{ 2, 3, -3, -4 })),
        @shuffle(u32, high_a, high_b, @as(@Vector(4, i32), .{ 0, 1, -1, -2 })),
        @shuffle(u32, high_a, high_b, @as(@Vector(4, i32), .{ 2, 3, -3, -4 })),
    };
}

fn reconstructGroup(
    comptime pixel_bytes: usize,
    comptime filter: u8,
    rows: [4][]u8,
    previous: ?[]const u8,
) void {
    const group = 4;
    const word_bytes = comptime filterWordBytes(pixel_bytes);
    const Word = @Int(.unsigned, word_bytes * 8);
    const channels = group * word_bytes;
    const Lane = if (filter == 3) u8 else i16;
    const row_bytes = rows[0].len;
    // The leading triangle leaves the first complete diagonal at pixel positions 3/2/1/0. Its left
    // and upper-left neighbors are already reconstructed.
    inline for (0..group - 1) |index| {
        reconstructRange(
            pixel_bytes,
            filter,
            group - index - 1,
            rows[index],
            if (index == 0) previous else rows[index - 1],
            0,
        );
    }

    var left_words: @Vector(group, Word) = undefined;
    var corner_words: @Vector(group, Word) = undefined;
    inline for (0..group) |index| {
        left_words[index] = if (index < group - 1) loadFilterWord(
            pixel_bytes,
            rows[index],
            (group - index - 2) * pixel_bytes,
        ) else 0;
        corner_words[index] = if (index == 0) if (previous) |up| loadFilterWord(
            pixel_bytes,
            up,
            (group - 2) * pixel_bytes,
        ) else 0 else if (index < group - 1) loadFilterWord(
            pixel_bytes,
            rows[index - 1],
            (group - index - 2) * pixel_bytes,
        ) else 0;
    }
    var left: @Vector(channels, Lane) = @as(@Vector(channels, u8), @bitCast(left_words));
    var upper_left: @Vector(channels, i16) = @as(@Vector(channels, u8), @bitCast(corner_words));
    // The top pixel comes from the preceding complete row; other up pixels are the preceding
    // diagonal's left pixels shifted down by one row.
    const up_mask = comptime blk: {
        var mask: [channels]i32 = undefined;
        for (0..word_bytes) |index| mask[index] = @intCast(index);
        for (word_bytes..channels) |index| mask[index] = ~@as(i32, @intCast(index - word_bytes));
        break :blk mask;
    };

    var column: usize = (group - 1) * pixel_bytes;
    // Three/six-byte strides have a full-word body and one exact partial-word tail. Keeping aligned
    // strides in one loop avoids a second traversal/code layout.
    const phases = if (pixel_bytes == word_bytes) 1 else 2;
    inline for (0..phases) |phase| {
        const end = if (phases == 2 and phase == 0) row_bytes - pixel_bytes else row_bytes;
        while (column < end) : (column += pixel_bytes) {
            var words: @Vector(group, Word) = undefined;
            inline for (
                0..group,
            ) |index| words[index] = if (phase == 0) @bitCast(
                rows[index][column - index * pixel_bytes ..][0..word_bytes].*,
            ) else loadFilterWord(pixel_bytes, rows[index], column - index * pixel_bytes);
            const current: @Vector(channels, u8) = @bitCast(words);
            const first_up: @Vector(
                word_bytes,
                Lane,
            ) = if (previous) |up| @as(
                @Vector(word_bytes, u8),
                @bitCast(
                    if (phase == 0) @as(
                        Word,
                        @bitCast(up[column..][0..word_bytes].*),
                    ) else loadFilterWord(pixel_bytes, up, column),
                ),
            ) else @splat(0);
            const up = @shuffle(Lane, first_up, left, up_mask);
            left = reconstructChannels(filter, channels, current, up, left, upper_left);
            const reconstructed = reconstructedBytes(left);
            const result_words: @Vector(group, Word) = @bitCast(reconstructed);
            inline for (
                0..group,
            ) |index| storeFilterWord(
                pixel_bytes,
                rows[index],
                column - index * pixel_bytes,
                result_words[index],
            );
            upper_left = up;
        }
    }

    // Finish rows in order, so each trailing triangle has complete up history.
    inline for (1..group) |index| {
        reconstructRange(
            pixel_bytes,
            filter,
            index,
            rows[index],
            rows[index - 1],
            row_bytes - index * pixel_bytes,
        );
    }
}

fn reconstructRange(
    comptime pixel_bytes: usize,
    comptime filter: u8,
    comptime count: usize,
    row: []u8,
    previous: ?[]const u8,
    begin: usize,
) void {
    const word_bytes = comptime filterWordBytes(pixel_bytes);
    const Lane = if (filter == 3) u8 else i16;
    var left: @Vector(
        word_bytes,
        Lane,
    ) = if (begin >= pixel_bytes) @as(
        @Vector(word_bytes, u8),
        @bitCast(loadFilterWord(pixel_bytes, row, begin - pixel_bytes)),
    ) else @splat(0);
    var upper_left: @Vector(
        word_bytes,
        i16,
    ) = if (previous) |up| if (begin >= pixel_bytes) @as(
        @Vector(word_bytes, u8),
        @bitCast(loadFilterWord(pixel_bytes, up, begin - pixel_bytes)),
    ) else @splat(0) else @splat(0);
    inline for (0..count) |pixel| {
        const column = begin + pixel * pixel_bytes;
        const current: @Vector(word_bytes, u8) = @bitCast(loadFilterWord(pixel_bytes, row, column));
        const up: @Vector(
            word_bytes,
            u8,
        ) = if (previous) |source| @bitCast(
            loadFilterWord(pixel_bytes, source, column),
        ) else @splat(0);
        left = reconstructChannels(filter, word_bytes, current, up, left, upper_left);
        const reconstructed = reconstructedBytes(left);
        storeFilterWord(pixel_bytes, row, column, @bitCast(reconstructed));
        upper_left = up;
    }
}

// Round RGB's three/six channels up to a word; spare channels stay independent and are discarded.
// Full word reads stay in the row. Its final pixel reads only actual sample bytes. Stores never
// touch the next pixel or a filter selector.
fn filterWordBytes(comptime pixel_bytes: usize) usize {
    return switch (pixel_bytes) {
        1, 2, 4, 8 => pixel_bytes,
        3 => 4,
        6 => 8,
        else => unreachable,
    };
}

fn loadFilterWord(
    comptime pixel_bytes: usize,
    row: []const u8,
    column: usize,
) @Int(.unsigned, filterWordBytes(pixel_bytes) * 8) {
    const word_bytes = comptime filterWordBytes(pixel_bytes);
    if (pixel_bytes == word_bytes or row.len - column >= word_bytes) return @bitCast(
        row[column..][0..word_bytes].*,
    );
    var bytes: [word_bytes]u8 = @splat(0);
    bytes[0..pixel_bytes].* = row[column..][0..pixel_bytes].*;
    return @bitCast(bytes);
}

fn storeFilterWord(
    comptime pixel_bytes: usize,
    row: []u8,
    column: usize,
    word: @Int(.unsigned, filterWordBytes(pixel_bytes) * 8),
) void {
    const bytes: [filterWordBytes(pixel_bytes)]u8 = @bitCast(word);
    row[column..][0..pixel_bytes].* = bytes[0..pixel_bytes].*;
}

// The recurrence keeps widened Paeth channels in registers; byte addition wraps only samples and
// preserves their zero high bytes. All channels are independent.
fn reconstructChannels(
    comptime filter: u8,
    comptime channels: usize,
    current: @Vector(channels, u8),
    up: @Vector(channels, if (filter == 3) u8 else i16),
    left: @Vector(channels, if (filter == 3) u8 else i16),
    upper_left: @Vector(channels, i16),
) @TypeOf(left) {
    if (filter == 3) {
        // Byte averaging rounds up; PNG requires the floor of the sum.
        const sum = @as(@Vector(channels, u16), left) + up + @as(@Vector(channels, u16), @splat(1));
        const rounded: @Vector(channels, u8) = @intCast(sum >> @splat(1));
        const predictor = rounded -% ((left ^ up) & @as(@Vector(channels, u8), @splat(1)));
        return current +% predictor;
    }
    // Paeth selects the neighbor closest to left + up - upper_left. Ordering left and up lets the
    // equivalent threshold select that neighbor without computing three absolute distances.
    const low = @min(left, up);
    const high = @max(left, up);
    const threshold = upper_left * @as(@Vector(channels, i16), @splat(3)) - (left + up);
    // Inclusive thresholds preserve the required left/up precedence at ties.
    const predictor = @select(
        i16,
        threshold <= low,
        high,
        @select(i16, threshold >= high, low, upper_left),
    );
    const widened: @Vector(channels, i16) = current;
    if (builtin.cpu.arch.endian() == .big) {
        // Keep wrapping inside each widened lane on big-endian targets instead of passing the
        // recurrence through two different byte-vector layouts.
        return (widened + predictor) & @as(@Vector(channels, i16), @splat(255));
    }
    const samples: @Vector(channels * 2, u8) = @bitCast(widened);
    const prediction: @Vector(channels * 2, u8) = @bitCast(predictor);
    return @bitCast(samples +% prediction);
}

// Paeth produces nonnegative i16 lanes in 0..255. Zig 0.17's LLVM x86 backend narrows signed
// vectors with signed saturation, clamping these valid bytes to 127. An unsigned bit view retains
// the complete byte range and its checked cast.
fn reconstructedBytes(values: anytype) @Vector(@typeInfo(@TypeOf(values)).vector.len, u8) {
    const info = @typeInfo(@TypeOf(values)).vector;
    if (info.child == u8) return values;
    comptime std.debug.assert(info.child == i16);
    return @intCast(@as(@Vector(info.len, u16), @bitCast(values)));
}

// Rows are either already in destination, disjoint, or compacted toward the start of filtered
// storage. Loading a complete vector before storing it preserves unread input even when destination
// precedes source by only one byte.
fn copyFilteredRow(destination: []u8, source: []const u8) void {
    if (destination.ptr == source.ptr) return;
    var offset: usize = 0;
    while (source.len - offset >= 16) : (offset += 16) {
        const bytes: @Vector(16, u8) = source[offset..][0..16].*;
        destination[offset..][0..16].* = bytes;
    }
    while (offset < source.len) : (offset += 1) destination[offset] = source[offset];
}

// PNG specification's literal scalar predictor, independent of channel selection.
// https://www.libpng.org/pub/png/spec/1.2/PNG-Filters.html
fn referenceReconstructRow(row: []u8, previous: ?[]const u8, stride: usize, filter: u8) void {
    for (row, 0..) |*byte, column| {
        const a: i32 = if (column >= stride) row[column - stride] else 0;
        const b: i32 = if (previous) |up| up[column] else 0;
        const c: i32 = if (previous) |up| if (column >= stride) up[column - stride] else 0 else 0;
        const prediction: i32 = if (filter == 0) 0 else if (filter == 1) a else if (filter == 2)
            b
        else if (filter == 3) @divFloor(
            a + b,
            2,
        ) else blk: {
            const p = a + b - c;
            const pa = @abs(p - a);
            const pb = @abs(p - b);
            const pc = @abs(p - c);
            break :blk if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
        };
        byte.* +%= @intCast(prediction);
    }
}

/// Selects the neighboring byte closest to PNG's linear Paeth estimate.
// Inclusive thresholds retain left/up tie precedence. Keep the independent distance formulation
// below as the exhaustive reference for every neighbor triple.
fn paethThreshold(left: u8, up: u8, upper_left: u8) u8 {
    const low = @min(left, up);
    const high = @max(left, up);
    const threshold = @as(i16, upper_left) * 3 - (@as(i16, left) + up);
    if (threshold <= low) return high;
    if (threshold >= high) return low;
    return upper_left;
}

/// PNG's exact byte predictor, with left then up winning equal-distance ties. Shared by encoding
/// and the scalar decoding/reference path; all byte triples are valid.
pub fn paethPredictor(left: u8, up: u8, upper_left: u8) u8 {
    const left_wide: i16 = left;
    const up_wide: i16 = up;
    const upper_left_wide: i16 = upper_left;
    const prediction = left_wide + up_wide - upper_left_wide;
    const left_distance = @abs(prediction - left_wide);
    const up_distance = @abs(prediction - up_wide);
    const upper_left_distance = @abs(prediction - upper_left_wide);
    if (left_distance <= up_distance and left_distance <= upper_left_distance) return left;
    if (up_distance <= upper_left_distance) return up;
    return upper_left;
}

// Independently encode known samples with the scalar PNG floor-average rule. The reconstruction
// under test cannot supply its own expected pixels or history.
fn writeAverageRgbFixture(rgba: []u8, expected: []u8, width: usize, height: usize) void {
    for (0..height) |y| {
        for (0..width) |x| {
            for (0..3) |channel| {
                expected[(y * width + x) * 4 + channel] = @truncate(
                    x * 137 + y * 211 + channel * 73 + x * y * 19,
                );
            }
            expected[(y * width + x) * 4 + 3] = 255;
        }
    }
    for (0..height) |y| {
        const row = rgba[y * (width * 3 + 1) ..][0 .. width * 3 + 1];
        row[0] = 3;
        for (0..width) |x| {
            for (0..3) |channel| {
                const index = (y * width + x) * 4 + channel;
                const left: u16 = if (x == 0) 0 else expected[index - 4];
                const up: u16 = if (y == 0) 0 else expected[index - width * 4];
                row[1 + x * 3 + channel] = expected[index] -% @as(u8, @intCast((left + up) / 2));
            }
        }
    }
}

test "filtered row compaction preserves forward overlap and exact slice bounds" {
    const allocator = std.testing.allocator;
    const actual = try allocator.alloc(u8, 128);
    defer allocator.free(actual);
    const expected = try allocator.alloc(u8, actual.len);
    defer allocator.free(expected);
    for (0..17) |prefix| {
        for (0..33) |distance| {
            for (0..66) |length| {
                for (actual, 0..) |*byte, index| byte.* = @truncate(index * 31 + 7);
                @memcpy(expected, actual);
                std.mem.copyForwards(
                    u8,
                    expected[prefix..][0..length],
                    expected[prefix + distance ..][0..length],
                );
                copyFilteredRow(
                    actual[prefix..][0..length],
                    actual[prefix + distance ..][0..length],
                );
                try std.testing.expectEqualSlices(u8, expected, actual);
            }
        }
    }
}

test "Sub prefixes preserve byte strides, overlap and exact row bounds" {
    const allocator = std.testing.allocator;
    const actual = try allocator.alloc(u8, 512);
    defer allocator.free(actual);
    const expected = try allocator.alloc(u8, actual.len);
    defer allocator.free(expected);
    for ([_]usize{ 1, 2, 4, 6 }) |stride| {
        for (0..17) |prefix| {
            for (0..65) |distance| {
                for (0..130) |length| {
                    for (actual, 0..) |*byte, index| byte.* = @truncate(index * 31 + 7);
                    @memcpy(expected, actual);
                    const expected_row = expected[prefix..][0..length];
                    std.mem.copyForwards(
                        u8,
                        expected_row,
                        expected[prefix + distance ..][0..length],
                    );
                    for (expected_row, 0..) |*byte, column| {
                        const left = if (column >= stride) expected_row[column - stride] else 0;
                        byte.* +%= left;
                    }
                    reconstructRow(
                        actual[prefix..][0..length],
                        actual[prefix + distance ..][0..length],
                        null,
                        stride,
                        1,
                    );
                    try std.testing.expectEqualSlices(u8, expected, actual);
                }
            }
        }
    }
}

test "Average and Paeth channels preserve history, overlap and exact slice bounds" {
    const allocator = std.testing.allocator;
    const original = try allocator.alloc(u8, 512);
    defer allocator.free(original);
    const actual = try allocator.alloc(u8, original.len);
    defer allocator.free(actual);
    const expected = try allocator.alloc(u8, original.len);
    defer allocator.free(expected);
    const previous = try allocator.alloc(u8, original.len);
    defer allocator.free(previous);
    var random: std.Random.DefaultPrng = .init(0x706e675f726f7773);
    random.random().bytes(original);
    random.random().bytes(previous);
    for ([_]u8{ 3, 4 }) |filter| {
        for ([_]bool{ false, true }) |has_previous| {
            for (0..17) |prefix| {
                for (0..33) |distance| {
                    for (0..130) |length| {
                        @memcpy(actual, original);
                        @memcpy(expected, original);
                        const expected_row = expected[prefix..][0..length];
                        std.mem.copyForwards(
                            u8,
                            expected_row,
                            expected[prefix + distance ..][0..length],
                        );
                        const preceding: ?[]const u8 = if (has_previous)
                            previous[prefix..][0..length]
                        else
                            null;
                        referenceReconstructRow(expected_row, preceding, 4, filter);
                        reconstructRow(
                            actual[prefix..][0..length],
                            actual[prefix + distance ..][0..length],
                            preceding,
                            4,
                            filter,
                        );
                        try std.testing.expectEqualSlices(u8, expected, actual);
                    }
                }
            }
        }
    }
}

test "Paeth channels preserve all 16777216 neighbor triples and ties" {
    var filtered: [8]u8 = undefined;
    var previous: [8]u8 = undefined;
    var actual: [8]u8 = undefined;
    var expected: [8]u8 = undefined;
    for (0..256) |a| {
        for (0..256) |b| {
            var corner: usize = 0;
            while (corner < 256) : (corner += 4) {
                // Four independent lanes cover adjacent corner values. The first pixel establishes
                // the selected left neighbor via Up.
                for (0..4) |channel| {
                    const c: u8 = @intCast(corner + channel);
                    try std.testing.expectEqual(
                        paethPredictor(@intCast(a), @intCast(b), c),
                        paethThreshold(@intCast(a), @intCast(b), c),
                    );
                    previous[channel] = c;
                    previous[4 + channel] = @intCast(b);
                    filtered[channel] = @as(u8, @intCast(a)) -% c;
                    filtered[4 + channel] = 0;
                }
                expected = filtered;
                referenceReconstructRow(&expected, &previous, 4, 4);
                reconstructRow(&actual, &filtered, &previous, 4, 4);
                try std.testing.expectEqualSlices(u8, &expected, &actual);
            }
        }
    }
}

test "Average channels floor all 65536 neighboring byte sums" {
    var filtered: [8]u8 = undefined;
    var previous: [8]u8 = @splat(0);
    var actual: [8]u8 = undefined;
    var expected: [8]u8 = undefined;
    for (0..256) |a| {
        for (0..256) |b| {
            @memset(filtered[0..4], @intCast(a));
            @memset(filtered[4..8], 0);
            @memset(previous[4..8], @intCast(b));
            @memset(expected[0..4], @intCast(a));
            @memset(expected[4..8], @intCast((a + b) / 2));
            reconstructRow(&actual, &filtered, &previous, 4, 3);
            try std.testing.expectEqualSlices(u8, &expected, &actual);
        }
    }
}

test "Sub, Average and Paeth preserve each byte stride and disjoint short output" {
    var filtered: [69]u8 = undefined;
    var previous: [69]u8 = undefined;
    var actual: [69]u8 = undefined;
    var expected: [69]u8 = undefined;
    var random: std.Random.DefaultPrng = .init(0x706e675f73747264);
    random.random().bytes(&filtered);
    random.random().bytes(&previous);
    for ([_]u8{ 1, 3, 4 }) |filter| {
        for ([_]usize{ 1, 2, 3, 4, 6, 8 }) |stride| {
            for (0..filtered.len + 1) |length| {
                for ([_]bool{ false, true }) |has_previous| {
                    @memset(&actual, 0xa5);
                    expected = actual;
                    @memcpy(expected[0..length], filtered[0..length]);
                    const preceding: ?[]const u8 = if (has_previous) previous[0..length] else null;
                    referenceReconstructRow(expected[0..length], preceding, stride, filter);
                    reconstructRow(
                        actual[0..length],
                        filtered[0..length],
                        preceding,
                        stride,
                        filter,
                    );
                    try std.testing.expectEqualSlices(u8, &expected, &actual);
                }
            }
        }
    }
}

test "Sub, Average and Paeth rows stay between inaccessible pages" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const posix = std.posix;
    const page_size = std.heap.pageSize();
    const memory = try posix.mmap(
        null,
        9 * page_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer posix.munmap(memory);
    for ([_]usize{ 0, 2, 3, 5, 6, 8 }) |page| {
        try std.testing.expectEqual(
            .SUCCESS,
            posix.errno(std.os.linux.mprotect(memory.ptr + page * page_size, page_size, .{})),
        );
    }
    const source = memory[page_size .. 2 * page_size];
    const preceding = memory[4 * page_size .. 5 * page_size];
    const destination = memory[7 * page_size .. 8 * page_size];
    const expected = try std.testing.allocator.alloc(u8, page_size);
    defer std.testing.allocator.free(expected);
    var random: std.Random.DefaultPrng = .init(0x706e675f67756172);
    random.random().bytes(source);
    random.random().bytes(preceding);
    for ([_]u8{ 1, 3, 4 }) |filter| {
        for ([_]usize{ 1, 2, 3, 4, 6, 8 }) |stride| {
            for ([_]bool{ false, true }) |has_previous| {
                for (0..130) |length| {
                    for ([_]usize{ 0, page_size - length }) |offset| {
                        @memset(destination, 0xa5);
                        @memcpy(expected, destination);
                        @memcpy(expected[offset..][0..length], source[offset..][0..length]);
                        const previous: ?[]const u8 = if (has_previous)
                            preceding[offset..][0..length]
                        else
                            null;
                        referenceReconstructRow(
                            expected[offset..][0..length],
                            previous,
                            stride,
                            filter,
                        );
                        reconstructRow(
                            destination[offset..][0..length],
                            source[offset..][0..length],
                            previous,
                            stride,
                            filter,
                        );
                        try std.testing.expectEqualSlices(u8, expected, destination);
                    }
                }
            }
        }
    }

    // Packed diagonal groups retain selectors and stop at exact frame boundaries.
    for ([_]usize{ 1, 2, 3, 4, 6, 8 }) |stride| {
        for ([_]usize{ 7, 8, 31, 32, 33, 127 }) |width| {
            for ([_]usize{ 1, 3, 4, 5, 8 }) |height| {
                const row_bytes = width * stride;
                const length = (row_bytes + 1) * height;
                if (length > page_size) continue;
                for ([_]u8{ 3, 4 }) |filter| {
                    for ([_]usize{ 0, page_size - length }) |offset| {
                        @memset(destination, 0xa5);
                        @memset(expected, 0xa5);
                        const filtered = destination[offset..][0..length];
                        const reference = expected[offset..][0..length];
                        for (0..height) |row| {
                            const begin = row * (row_bytes + 1);
                            filtered[begin] = filter;
                            reference[begin] = filter;
                            const current = filtered[begin + 1 ..][0..row_bytes];
                            @memcpy(current, source[begin + 1 ..][0..row_bytes]);
                            @memcpy(reference[begin + 1 ..][0..row_bytes], current);
                            referenceReconstructRow(
                                reference[begin + 1 ..][0..row_bytes],
                                if (row == 0) null else reference[begin - (row_bytes + 1) +
                                    1 ..][0..row_bytes],
                                stride,
                                filter,
                            );
                        }
                        try reconstructPackedRows(filtered, row_bytes, height, stride);
                        try std.testing.expectEqualSlices(u8, expected, destination);
                    }
                }
            }
        }
    }

    // Complete RGB groups also finish at the protected row/frame boundary.
    for ([_]usize{ 7, 8, 31, 32, 33, 127 }) |width| {
        for ([_]usize{ 1, 3, 4, 5, 8 }) |height| {
            const row_bytes = width * 3;
            const length = (row_bytes + 1) * height;
            for ([_]u8{ 3, 4 }) |filter| {
                for ([_]usize{ 0, page_size - length }) |offset| {
                    @memset(destination, 0xa5);
                    const filtered = destination[offset..][0..length];
                    @memset(filtered, 0);
                    for (0..height) |row| filtered[row * (row_bytes + 1)] = filter;
                    try reconstructRgb8Rows(filtered, row_bytes, height);
                    for (
                        filtered[0 .. row_bytes * height],
                    ) |byte| try std.testing.expectEqual(0, byte);
                    for (destination[0..offset]) |byte| try std.testing.expectEqual(0xa5, byte);
                    for (
                        destination[offset + length ..],
                    ) |byte| try std.testing.expectEqual(0xa5, byte);
                }
            }
        }
    }
    // Fused Average reconstruction must stop at both ends of its exact RGBA owner.
    for ([_]usize{ 1, 7, 31, 32, 33, 63 }) |width| {
        for ([_]usize{ 1, 12, 13, 16, 17, 28, 29, 31 }) |height| {
            const length = width * height * 4;
            if (length > page_size) continue;
            for ([_]usize{ 0, page_size - length }) |offset| {
                @memset(destination, 0xa5);
                @memset(expected, 0xa5);
                const rgba = destination[offset..][0..length];
                writeAverageRgbFixture(rgba, expected[offset..][0..length], width, height);
                reconstructAverageRgb8Rgba8(rgba, width * 3, height);
                try std.testing.expectEqualSlices(u8, expected, destination);
            }
        }
    }

    // Backward RGB expansion must also stop at the exact returned RGBA boundary.
    for (0..130) |count| {
        const length = count * 4;
        for ([_]usize{ 0, page_size - length }) |offset| {
            for ([_]?[3]u16{ null, .{ 17, 34, 51 }, .{ 273, 34, 51 } }) |transparent| {
                @memset(destination, 0xa5);
                @memset(expected, 0xa5);
                const rgba = destination[offset..][0..length];
                const expected_alpha: u8 = if (transparent != null and transparent.?[0] == 17)
                    0
                else
                    255;
                for (0..count) |pixel| {
                    rgba[pixel * 3 ..][0..3].* = .{ 17, 34, 51 };
                    expected[offset + pixel * 4 ..][0..4].* = .{ 17, 34, 51, expected_alpha };
                }
                expandRgb8InPlace(rgba, transparent);
                try std.testing.expectEqualSlices(u8, expected, destination);
            }
        }
    }
}

test "grouped RGBA rows preserve mixed filters, diagonal edges and byte bounds" {
    const widths = [_]usize{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 31, 32, 33, 64, 127 };
    const heights = [_]usize{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 33 };
    const offsets = [_]usize{ 0, 1, 3, 7, 15, 31 };
    const allocator = std.testing.allocator;
    const maximum_pixels = widths[widths.len - 1] * heights[heights.len - 1] * 4;
    const backing = try allocator.alloc(u8, maximum_pixels + heights[heights.len - 1] + 96);
    defer allocator.free(backing);
    const original = try allocator.alloc(u8, backing.len);
    defer allocator.free(original);
    const expected = try allocator.alloc(u8, maximum_pixels);
    defer allocator.free(expected);
    for (widths) |width| {
        const row_bytes = width * 4;
        for (heights) |height| {
            const pixel_count = row_bytes * height;
            const filtered_count = (row_bytes + 1) * height;
            for (0..7) |pattern| {
                var seed: u32 = 0x12345678;
                for (expected[0..pixel_count]) |*byte| {
                    seed ^= seed << 13;
                    seed ^= seed >> 17;
                    seed ^= seed << 5;
                    byte.* = @truncate(seed);
                }
                for (offsets) |offset| {
                    @memset(backing, 0xa7);
                    const begin = 32 + offset;
                    const filtered = backing[begin..][0..filtered_count];
                    for (0..height) |row| {
                        const filter: u8 = @intCast(
                            if (pattern < 5) pattern else if (pattern == 5) 3 + (row / 5) %
                                2 else row % 5,
                        );
                        filtered[row * (row_bytes + 1)] = filter;
                        for (0..row_bytes) |column| {
                            const index = row * row_bytes + column;
                            const left = if (column >= 4) expected[index - 4] else 0;
                            const up = if (row > 0) expected[index - row_bytes] else 0;
                            const corner = if (row > 0 and column >= 4) expected[
                                index - row_bytes -
                                    4
                            ] else 0;
                            const predictor: u8 = switch (filter) {
                                0 => 0,
                                1 => left,
                                2 => up,
                                3 => @intCast((@as(u16, left) + up) / 2),
                                4 => blk: {
                                    // Classical RFC predictor, independent of the production
                                    // min/max threshold and vector math.
                                    const prediction = @as(i32, left) + up - corner;
                                    const a = @abs(prediction - left);
                                    const b = @abs(prediction - up);
                                    const c = @abs(prediction - corner);
                                    break :blk if (a <= b and a <= c) left else if (b <= c)
                                        up
                                    else
                                        corner;
                                },
                                else => unreachable,
                            };
                            filtered[row * (row_bytes + 1) + column + 1] = expected[index] -%
                                predictor;
                        }
                    }
                    @memcpy(original, backing);
                    try reconstructRgba8Rows(filtered, row_bytes, height);
                    try std.testing.expectEqualSlices(
                        u8,
                        expected[0..pixel_count],
                        filtered[0..pixel_count],
                    );
                    try std.testing.expectEqualSlices(u8, original[0..begin], backing[0..begin]);
                    try std.testing.expectEqualSlices(
                        u8,
                        original[begin + filtered_count ..],
                        backing[begin + filtered_count ..],
                    );
                }
            }
        }
    }
}

test "invalid selectors remain errors at every row of a potential group" {
    const allocator = std.testing.allocator;
    const row_bytes = 128;
    const height = 9;
    const filtered_count = (row_bytes + 1) * height;
    const backing = try allocator.alloc(u8, filtered_count + 64);
    defer allocator.free(backing);
    for (0..height) |bad_row| {
        for ([_]u8{ 3, 4 }) |filter| {
            @memset(backing, 0xd5);
            const filtered = backing[32..][0..filtered_count];
            @memset(filtered, 0);
            for (0..height) |row| filtered[row * (row_bytes + 1)] = filter;
            filtered[bad_row * (row_bytes + 1)] = 5;
            try std.testing.expectError(
                error.InvalidPng,
                reconstructRgba8Rows(filtered, row_bytes, height),
            );
            for (backing[0..32]) |byte| try std.testing.expectEqual(0xd5, byte);
            for (backing[32 + filtered_count ..]) |byte| try std.testing.expectEqual(0xd5, byte);
        }
    }
}

test "fused Average RGB preserves diagonal edges, overlap and exact RGBA bounds" {
    const allocator = std.testing.allocator;
    const widths = [_]usize{ 1, 2, 3, 4, 7, 8, 15, 31, 32, 33, 63, 64, 65, 127, 128, 129 };
    const heights = [_]usize{
        1, 3, 4, 7, 8, 12, 13, 16, 28, 29, 30, 32, 33, 60, 61, 62, 76, 77, 78, 85, 128, 129,
    };
    const maximum_length = widths[widths.len - 1] * heights[heights.len - 1] * 4;
    const expected = try allocator.alloc(u8, maximum_length);
    defer allocator.free(expected);
    const storage = try allocator.alloc(u8, maximum_length + 32);
    defer allocator.free(storage);
    for (widths) |width| {
        for (heights) |height| {
            const length = width * height * 4;
            for ([_]usize{ 0, 1, 3, 7, 15 }) |prefix| {
                @memset(storage, 0xa5);
                const rgba = storage[prefix..][0..length];
                writeAverageRgbFixture(rgba, expected[0..length], width, height);
                reconstructAverageRgb8Rgba8(rgba, width * 3, height);
                try std.testing.expectEqualSlices(u8, expected[0..length], rgba);
                for (storage[0..prefix]) |byte| try std.testing.expectEqual(0xa5, byte);
                for (storage[prefix + length ..]) |byte| try std.testing.expectEqual(0xa5, byte);
            }
        }
    }
}

test "fused Average RGB wide groups stay between inaccessible pages" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const page_size = std.heap.pageSize();
    const capacity = std.mem.alignForward(usize, 129 * 129 * 4, page_size);
    const memory = try std.posix.mmap(
        null,
        capacity + 2 * page_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(memory);
    for ([_]usize{ 0, page_size + capacity }) |offset| {
        try std.testing.expectEqual(
            .SUCCESS,
            std.posix.errno(std.os.linux.mprotect(memory.ptr + offset, page_size, .{})),
        );
    }
    const destination = memory[page_size .. page_size + capacity];
    const expected = try std.testing.allocator.alloc(u8, capacity);
    defer std.testing.allocator.free(expected);
    for ([_]usize{ 127, 128, 129 }) |width| {
        for ([_]usize{ 28, 29, 30, 60, 61, 62, 76, 77, 78, 128, 129 }) |height| {
            const length = width * height * 4;
            for ([_]usize{ 0, capacity - length }) |offset| {
                @memset(destination, 0xa5);
                @memset(expected, 0xa5);
                const rgba = destination[offset..][0..length];
                writeAverageRgbFixture(rgba, expected[offset..][0..length], width, height);
                reconstructAverageRgb8Rgba8(rgba, width * 3, height);
                try std.testing.expectEqualSlices(u8, expected, destination);
            }
        }
    }
}

test "RGB rows compact and expand backward with transparency and exact byte bounds" {
    const widths = [_]usize{ 1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 31, 32, 33, 64, 127 };
    const heights = [_]usize{ 1, 2, 3, 4, 5, 9, 17 };
    const offsets = [_]usize{ 0, 1, 3, 7, 15, 31 };
    const allocator = std.testing.allocator;
    const maximum_pixels = widths[widths.len - 1] * heights[heights.len - 1];
    const backing = try allocator.alloc(u8, maximum_pixels * 4 + 96);
    defer allocator.free(backing);
    const rgb = try allocator.alloc(u8, maximum_pixels * 3);
    defer allocator.free(rgb);
    const expected = try allocator.alloc(u8, maximum_pixels * 4);
    defer allocator.free(expected);
    for (widths) |width| {
        const row_bytes = width * 3;
        for (heights) |height| {
            const pixel_count = width * height;
            const filtered_count = (row_bytes + 1) * height;
            var seed: u32 = 0x12345678;
            for (rgb[0 .. pixel_count * 3]) |*byte| {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                byte.* = @truncate(seed);
            }
            for (0..pixel_count) |pixel| {
                if (pixel % 7 == 0) rgb[pixel * 3 ..][0..3].* = .{ 17, 34, 51 };
            }
            for ([_]?[3]u16{ null, .{ 17, 34, 51 } }) |transparent| {
                for (0..pixel_count) |pixel| {
                    const sample = rgb[pixel * 3 ..][0..3].*;
                    expected[pixel * 4 ..][0..4].* = .{
                        sample[0],
                        sample[1],
                        sample[2],
                        if (transparent != null and std.mem.eql(
                            u8,
                            &sample,
                            &.{ 17, 34, 51 },
                        )) 0 else 255,
                    };
                }
                for (0..6) |pattern| {
                    for (offsets) |offset| {
                        @memset(backing, 0xd5);
                        const begin = 32 + offset;
                        const rgba = backing[begin..][0 .. pixel_count * 4];
                        const filtered = rgba[0..filtered_count];
                        for (0..height) |row| {
                            const filter: u8 = @intCast(if (pattern < 5) pattern else row % 5);
                            filtered[row * (row_bytes + 1)] = filter;
                            for (0..row_bytes) |column| {
                                const index = row * row_bytes + column;
                                const left = if (column >= 3) rgb[index - 3] else 0;
                                const up = if (row > 0) rgb[index - row_bytes] else 0;
                                const corner = if (row > 0 and column >= 3) rgb[
                                    index - row_bytes -
                                        3
                                ] else 0;
                                const predictor: u8 = switch (filter) {
                                    0 => 0,
                                    1 => left,
                                    2 => up,
                                    3 => @intCast((@as(u16, left) + up) / 2),
                                    4 => blk: {
                                        const prediction = @as(i32, left) + up - corner;
                                        const a = @abs(prediction - left);
                                        const b = @abs(prediction - up);
                                        const c = @abs(prediction - corner);
                                        break :blk if (a <= b and a <= c) left else if (b <= c)
                                            up
                                        else
                                            corner;
                                    },
                                    else => unreachable,
                                };
                                const sample_offset = row * (row_bytes + 1) + column + 1;
                                filtered[sample_offset] = rgb[index] -% predictor;
                            }
                        }
                        try reconstructRgb8Rows(filtered, row_bytes, height);
                        try std.testing.expectEqualSlices(
                            u8,
                            rgb[0 .. pixel_count * 3],
                            filtered[0 .. pixel_count * 3],
                        );
                        for (rgba[filtered_count..]) |byte| try std.testing.expectEqual(0xd5, byte);
                        expandRgb8InPlace(rgba, transparent);
                        try std.testing.expectEqualSlices(u8, expected[0 .. pixel_count * 4], rgba);
                        for (backing[0..begin]) |byte| try std.testing.expectEqual(0xd5, byte);
                        for (
                            backing[begin + rgba.len ..],
                        ) |byte| try std.testing.expectEqual(0xd5, byte);
                    }
                }
            }
        }
    }
}

test "RGB invalid selectors retain exact scratch bounds" {
    const allocator = std.testing.allocator;
    const row_bytes = 99;
    const height = 9;
    const filtered_count = (row_bytes + 1) * height;
    const backing = try allocator.alloc(u8, filtered_count + 64);
    defer allocator.free(backing);
    for (0..height) |bad_row| {
        for ([_]u8{ 3, 4 }) |filter| {
            @memset(backing, 0xd5);
            const filtered = backing[32..][0..filtered_count];
            @memset(filtered, 0);
            for (0..height) |row| filtered[row * (row_bytes + 1)] = filter;
            filtered[bad_row * (row_bytes + 1)] = 5;
            try std.testing.expectError(
                error.InvalidPng,
                reconstructRgb8Rows(filtered, row_bytes, height),
            );
            for (backing[0..32]) |byte| try std.testing.expectEqual(0xd5, byte);
            for (backing[32 + filtered_count ..]) |byte| try std.testing.expectEqual(0xd5, byte);
        }
    }
}

test "packed group queries preserve selector boundaries without validating a pass" {
    const Case = struct {
        row_bytes: usize,
        pixel_bytes: usize,
        selectors: []const u8,
        grouped: bool,
    };
    const cases = [_]Case{
        .{ .row_bytes = 7, .pixel_bytes = 1, .selectors = &.{ 4, 4, 4, 4 }, .grouped = false },
        .{ .row_bytes = 8, .pixel_bytes = 1, .selectors = &.{ 4, 4, 4, 4 }, .grouped = true },
        .{ .row_bytes = 31, .pixel_bytes = 1, .selectors = &.{ 3, 3, 3, 3 }, .grouped = false },
        .{ .row_bytes = 32, .pixel_bytes = 1, .selectors = &.{ 3, 3, 3, 3 }, .grouped = true },
        .{ .row_bytes = 14, .pixel_bytes = 2, .selectors = &.{ 4, 4, 4, 4 }, .grouped = false },
        .{ .row_bytes = 16, .pixel_bytes = 2, .selectors = &.{ 4, 4, 4, 4 }, .grouped = true },
        .{ .row_bytes = 62, .pixel_bytes = 2, .selectors = &.{ 3, 3, 3, 3 }, .grouped = false },
        .{ .row_bytes = 64, .pixel_bytes = 2, .selectors = &.{ 3, 3, 3, 3 }, .grouped = true },
        .{ .row_bytes = 64, .pixel_bytes = 1, .selectors = &.{ 4, 4, 4 }, .grouped = false },
        .{
            .row_bytes = 32,
            .pixel_bytes = 1,
            .selectors = &.{ 3, 4, 3, 4, 4, 4 },
            .grouped = false,
        },
        .{
            .row_bytes = 32,
            .pixel_bytes = 1,
            .selectors = &.{ 4, 4, 0, 4, 4, 4 },
            .grouped = false,
        },
        .{
            .row_bytes = 32,
            .pixel_bytes = 1,
            .selectors = &.{ 255, 0, 3, 3, 3, 3, 255 },
            .grouped = true,
        },
    };
    var storage: [455]u8 = @splat(0xa5);
    for (cases) |case| {
        const filtered = storage[0 .. case.selectors.len * (case.row_bytes + 1)];
        for (case.selectors, 0..) |filter, row| filtered[row * (case.row_bytes + 1)] = filter;
        try std.testing.expectEqual(
            case.grouped,
            packedPassHasGroups(filtered, case.row_bytes, case.selectors.len, case.pixel_bytes),
        );
    }
}

test "packed pass diagonals preserve filters, histories, mixed rows and exact bounds" {
    const allocator = std.testing.allocator;
    const capacity = (97 * 8 + 1) * 13 + 16;
    const source = try allocator.alloc(u8, capacity);
    defer allocator.free(source);
    const actual = try allocator.alloc(u8, capacity);
    defer allocator.free(actual);
    const expected = try allocator.alloc(u8, capacity);
    defer allocator.free(expected);
    var random: std.Random.DefaultPrng = .init(0x646961676f6e616c);
    random.random().bytes(source);
    for ([_]usize{ 1, 2, 3, 4, 6, 8 }) |stride| {
        for (0..98) |width| {
            for ([_]usize{ 0, 1, 3, 4, 5, 7, 8, 13 }) |height| {
                const row_bytes = width * stride;
                const length = height * (row_bytes + 1);
                for (0..8) |pattern| {
                    for ([_]usize{ 0, 1, 7 }) |offset| {
                        @memset(actual, 0xa5);
                        @memset(expected, 0xa5);
                        const filtered = actual[offset..][0..length];
                        const reference = expected[offset..][0..length];
                        for (0..height) |row| {
                            const filter: u8 = if (pattern < 5) @intCast(
                                pattern,
                            ) else if (pattern == 5) @intCast(
                                row % 5,
                            ) else if (pattern == 6) @intCast(
                                3 + (row / 4) % 2,
                            ) else if (row % 5 == 4) 0 else 4;
                            const begin = row * (row_bytes + 1);
                            filtered[begin] = filter;
                            reference[begin] = filter;
                            @memcpy(
                                filtered[begin + 1 ..][0..row_bytes],
                                source[begin..][0..row_bytes],
                            );
                            @memcpy(
                                reference[begin + 1 ..][0..row_bytes],
                                filtered[begin + 1 ..][0..row_bytes],
                            );
                            referenceReconstructRow(
                                reference[begin + 1 ..][0..row_bytes],
                                if (row == 0) null else reference[begin - (row_bytes + 1) +
                                    1 ..][0..row_bytes],
                                stride,
                                filter,
                            );
                        }
                        try reconstructPackedRows(filtered, row_bytes, height, stride);
                        try std.testing.expectEqualSlices(u8, expected, actual);
                    }
                }
            }
        }
    }
    // Reject a bad selector anywhere in a pass, including each diagonal/tail row.
    const width = 97;
    const height = 13;
    for ([_]usize{ 1, 2, 3, 4, 6, 8 }) |stride| {
        const row_bytes = width * stride;
        const length = height * (row_bytes + 1);
        for (0..height) |bad_row| {
            for ([_]u8{ 5, 255 }) |invalid| {
                @memset(actual, 0xa5);
                const filtered = actual[7..][0..length];
                @memcpy(filtered, source[0..length]);
                for (0..height) |row| filtered[row * (row_bytes + 1)] = 4;
                filtered[bad_row * (row_bytes + 1)] = invalid;
                try std.testing.expectError(
                    error.InvalidPng,
                    reconstructPackedRows(filtered, row_bytes, height, stride),
                );
                for (actual[0..7]) |byte| try std.testing.expectEqual(0xa5, byte);
                for (actual[7 + length ..]) |byte| try std.testing.expectEqual(0xa5, byte);
            }
        }
    }
}

fn filteredByte(
    current: []const u8,
    previous: ?[]const u8,
    bytes_per_pixel: usize,
    x: usize,
    kind: Filter.Type,
) u8 {
    const left: u8 = if (x >= bytes_per_pixel) current[x - bytes_per_pixel] else 0;
    const up: u8 = if (previous) |row| row[x] else 0;
    const upper_left: u8 = if (previous != null and x >= bytes_per_pixel) previous.?[
        x -
            bytes_per_pixel
    ] else 0;
    return current[x] -% predictedByte(kind, left, up, upper_left);
}

fn predictedByte(kind: Filter.Type, left: u8, up: u8, upper_left: u8) u8 {
    return switch (kind) {
        .none => 0,
        .sub => left,
        .up => up,
        .average => @as(u8, @intCast((@as(u16, left) + up) / 2)),
        .paeth => paethPredictor(left, up, upper_left),
    };
}

pub fn chooseFilter(
    current: []const u8,
    previous: ?[]const u8,
    bytes_per_pixel: usize,
) Filter.Type {
    const scores = filterScores(current, previous, bytes_per_pixel);
    var selected: Filter.Type = .none;
    for (scores[1..], 1..) |score, selector| if (score < scores[@backingInt(selected)]) {
        selected = @fromBackingInt(@intCast(selector));
    };
    return selected;
}

fn filterScores(current: []const u8, previous: ?[]const u8, bytes_per_pixel: usize) [5]u64 {
    // Batch independent bytes after the left-edge prefix. Accumulate each small vector into u64
    // scores so even the widest admitted row cannot overflow a lane.
    const lanes = 16;
    const Bytes = @Vector(lanes, u8);
    const Words = @Vector(lanes, u16);
    const Signed = @Vector(lanes, i16);
    var scores: [5]u64 = @splat(0);
    var x: usize = 0;
    const prefix = @min(bytes_per_pixel, current.len);
    while (x < prefix) : (x += 1) scoreFilterByte(&scores, current, previous, bytes_per_pixel, x);
    while (current.len - x >= lanes) : (x += lanes) {
        const values: Bytes = current[x..][0..lanes].*;
        const left: Bytes = current[x - bytes_per_pixel ..][0..lanes].*;
        const up: Bytes = if (previous) |row| row[x..][0..lanes].* else @splat(0);
        const upper_left: Bytes = if (previous) |row| row[x -
            bytes_per_pixel ..][0..lanes].* else @splat(
            0,
        );
        const average: Bytes = @intCast(
            (@as(Words, left) + @as(Words, up)) / @as(Words, @splat(2)),
        );
        const left_wide: Signed = @intCast(left);
        const up_wide: Signed = @intCast(up);
        const upper_left_wide: Signed = @intCast(upper_left);
        const prediction = left_wide + up_wide - upper_left_wide;
        const left_distance = @abs(prediction - left_wide);
        const up_distance = @abs(prediction - up_wide);
        const upper_left_distance = @abs(prediction - upper_left_wide);
        const paeth = @select(
            u8,
            (left_distance <= up_distance) & (left_distance <= upper_left_distance),
            left,
            @select(u8, up_distance <= upper_left_distance, up, upper_left),
        );
        const predictors = [_]Bytes{ @splat(0), left, up, average, paeth };
        inline for (predictors, &scores) |predictor, *score| {
            const delta: Bytes = values -% predictor;
            const wide: Words = delta;
            const magnitude = @min(wide, @as(Words, @splat(256)) - wide);
            score.* += @reduce(.Add, magnitude);
        }
    }
    while (x < current.len) : (x += 1) scoreFilterByte(
        &scores,
        current,
        previous,
        bytes_per_pixel,
        x,
    );
    return scores;
}

fn scoreFilterByte(
    scores: *[5]u64,
    current: []const u8,
    previous: ?[]const u8,
    bytes_per_pixel: usize,
    x: usize,
) void {
    const left: u8 = if (x >= bytes_per_pixel) current[x - bytes_per_pixel] else 0;
    const up: u8 = if (previous) |row| row[x] else 0;
    const upper_left: u8 = if (previous != null and x >= bytes_per_pixel) previous.?[
        x -
            bytes_per_pixel
    ] else 0;
    inline for ([_]Filter.Type{ .none, .sub, .up, .average, .paeth }, scores) |kind, *score| {
        const difference: u16 = current[x] -% predictedByte(kind, left, up, upper_left);
        score.* += @min(difference, 256 - difference);
    }
}

pub fn filterRow(
    destination: []u8,
    current: []const u8,
    previous: ?[]const u8,
    bytes_per_pixel: usize,
    kind: Filter.Type,
) void {
    destination[0] = @backingInt(kind);
    // Keep one predictor throughout this traversal, including the optional first-row history.
    switch (kind) {
        .up => {
            if (current.len < up_vector_threshold) {
                for (
                    0..current.len,
                ) |x| destination[x + 1] = filteredByte(current, previous, bytes_per_pixel, x, .up);
            } else {
                filterUp(destination[1..], current, previous);
            }
        },
        inline .none, .sub, .average, .paeth => |selected| {
            for (
                0..current.len,
            ) |x| destination[x + 1] = filteredByte(
                current,
                previous,
                bytes_per_pixel,
                x,
                selected,
            );
        },
    }
}

const up_vector_threshold = 16;

pub noinline fn filterUp(destination: []u8, current: []const u8, previous: ?[]const u8) void {
    if (previous) |above| {
        var x: usize = 0;
        while (current.len - x >= 32) : (x += 32) {
            const row: @Vector(32, u8) = current[x..][0..32].*;
            const prior: @Vector(32, u8) = above[x..][0..32].*;
            destination[x..][0..32].* = row -% prior;
        }
        if (current.len - x >= 16) {
            const row: @Vector(16, u8) = current[x..][0..16].*;
            const prior: @Vector(16, u8) = above[x..][0..16].*;
            destination[x..][0..16].* = row -% prior;
            x += 16;
        }
        while (x < current.len) : (x += 1) destination[x] = current[x] -% above[x];
    } else {
        @memcpy(destination[0..current.len], current);
    }
}

test "PNG encoding writes independent predictor bytes and adaptive scores" {
    const current = [_]u8{ 10, 20, 30, 40, 4, 1, 255, 128 };
    const previous = [_]u8{ 8, 19, 29, 50, 5, 255, 240, 129 };
    // Frozen byte predictions, independently calculated from PNG 9.2–9.4 with stride two.
    const expected = [_][9]u8{
        .{ 0, 10, 20, 30, 40, 4, 1, 255, 128 },
        .{ 1, 10, 20, 20, 20, 230, 217, 251, 127 },
        .{ 2, 2, 1, 1, 246, 255, 2, 15, 255 },
        .{ 3, 6, 11, 11, 5, 243, 110, 133, 63 },
        .{ 4, 2, 1, 1, 246, 255, 2, 15, 127 },
    };
    var guarded: [13]u8 = @splat(0xa5);
    for (expected, 0..) |row, selector| {
        filterRow(guarded[2..11], &current, &previous, 2, @fromBackingInt(@intCast(selector)));
        try std.testing.expectEqualSlices(u8, &row, guarded[2..11]);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, guarded[0..2]);
        try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, guarded[11..]);
    }
    // Independent signed scores 234/267/33/342/159 select Up. Empty/zero ties select None.
    try std.testing.expectEqual(Filter.Type.up, chooseFilter(&current, &previous, 2));
    try std.testing.expectEqual(Filter.Type.none, chooseFilter(&.{ 0, 0, 0 }, null, 1));
}

test "PNG adaptive vector scoring agrees with scalar predictors across row boundaries" {
    var random: std.Random.DefaultPrng = .init(0x24e5b1);
    var current: [1025]u8 = undefined;
    var above: [1025]u8 = undefined;
    for ([_]usize{ 1, 2, 3, 4, 6, 8 }) |stride| {
        for (0..105) |length_index| {
            const length = if (length_index < 100) length_index else 1020 + length_index - 100;
            for (0..3) |_| {
                random.random().bytes(&current);
                random.random().bytes(&above);
                for ([_]bool{ false, true }) |has_previous| {
                    const row = current[0..length];
                    const previous: ?[]const u8 = if (has_previous) above[0..length] else null;
                    var expected: [5]u64 = @splat(0);
                    inline for (
                        [_]Filter.Type{ .none, .sub, .up, .average, .paeth },
                        &expected,
                    ) |kind, *score| {
                        for (0..length) |x| {
                            const delta: u16 = filteredByte(row, previous, stride, x, kind);
                            score.* += @min(delta, 256 - delta);
                        }
                    }
                    try std.testing.expectEqualSlices(
                        u64,
                        &expected,
                        &filterScores(row, previous, stride),
                    );
                }
            }
        }
    }
}

test "PNG adaptive selection keeps byte-stride boundaries and lowest-selector ties" {
    // Independent integer PNG predictors and signed-byte magnitude scores freeze these
    // seventeen-byte rows. Strides cover every byte/word channel layout and clipped tails.
    const controls = [_]struct {
        stride: usize,
        current: [17]u8,
        previous: [17]u8,
        selected: Filter.Type,
    }{
        .{
            .stride = 1,
            .current = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .previous = .{
                180, 63, 127, 88, 55, 164, 88, 165, 124, 140, 90, 187, 132, 150, 117, 34, 14,
            },
            .selected = .none,
        },
        .{
            .stride = 1,
            .current = .{ 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 },
            .previous = .{
                98, 101, 170, 121, 142, 71, 75, 178, 137, 157, 217, 115, 246, 73, 143, 35, 74,
            },
            .selected = .sub,
        },
        .{
            .stride = 1,
            .current = .{
                185, 43, 108, 224, 182, 25, 129, 10, 149, 34, 109, 24, 140, 96, 159, 91, 35,
            },
            .previous = .{
                185, 43, 108, 224, 182, 25, 129, 10, 149, 34, 109, 24, 140, 96, 159, 91, 35,
            },
            .selected = .up,
        },
        .{
            .stride = 1,
            .current = .{
                18, 99, 141, 102, 89, 121, 84, 122, 131, 185, 167, 150, 172, 193, 190, 128, 159,
            },
            .previous = .{
                37, 181, 183, 64, 76, 153, 48, 160, 141, 240, 150, 133, 194, 214, 188, 66, 190,
            },
            .selected = .average,
        },
        .{
            .stride = 1,
            .current = .{
                250, 151, 151, 19, 29, 25, 16, 9, 69, 28, 211, 81, 146, 224, 159, 204, 174,
            },
            .previous = .{
                252, 153, 153, 19, 27, 23, 15, 11, 68, 28, 213, 79, 145, 222, 161, 204, 173,
            },
            .selected = .paeth,
        },
        .{
            .stride = 2,
            .current = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .previous = .{ 121, 227, 92, 3, 178, 10, 5, 15, 164, 94, 33, 61, 118, 234, 8, 23, 114 },
            .selected = .none,
        },
        .{
            .stride = 2,
            .current = .{ 12, 7, 12, 7, 12, 7, 12, 7, 12, 7, 12, 7, 12, 7, 12, 7, 12 },
            .previous = .{
                191, 85, 239, 188, 63, 134, 41, 89, 118, 108, 201, 36, 200, 11, 53, 118, 95,
            },
            .selected = .sub,
        },
        .{
            .stride = 2,
            .current = .{
                127, 52, 191, 67, 9, 7, 158, 86, 235, 181, 10, 22, 251, 215, 71, 62, 227,
            },
            .previous = .{
                127, 52, 191, 67, 9, 7, 158, 86, 235, 181, 10, 22, 251, 215, 71, 62, 227,
            },
            .selected = .up,
        },
        .{
            .stride = 2,
            .current = .{
                82, 68, 120, 123, 84, 173, 96, 133, 148, 72, 191, 50, 214, 76, 217, 106, 200,
            },
            .previous = .{
                164, 136, 158, 179, 49, 223, 109, 93, 200, 11, 235, 29, 237, 103, 220, 136, 183,
            },
            .selected = .average,
        },
        .{
            .stride = 2,
            .current = .{
                92, 140, 94, 54, 187, 103, 146, 171, 212, 145, 96, 197, 158, 110, 217, 115, 116,
            },
            .previous = .{
                94, 142, 97, 55, 188, 102, 147, 171, 213, 145, 97, 199, 159, 112, 215, 117, 115,
            },
            .selected = .paeth,
        },
        .{
            .stride = 3,
            .current = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .previous = .{
                94, 219, 92, 148, 136, 51, 215, 181, 34, 60, 112, 20, 157, 160, 202, 43, 164,
            },
            .selected = .none,
        },
        .{
            .stride = 3,
            .current = .{ 11, 9, 8, 11, 9, 8, 11, 9, 8, 11, 9, 8, 11, 9, 8, 11, 9 },
            .previous = .{
                187, 26, 215, 132, 84, 5, 83, 238, 245, 129, 104, 164, 201, 248, 236, 72, 230,
            },
            .selected = .sub,
        },
        .{
            .stride = 3,
            .current = .{
                27, 122, 74, 193, 208, 85, 181, 166, 171, 171, 10, 38, 255, 97, 38, 124, 143,
            },
            .previous = .{
                27, 122, 74, 193, 208, 85, 181, 166, 171, 171, 10, 38, 255, 97, 38, 124, 143,
            },
            .selected = .up,
        },
        .{
            .stride = 3,
            .current = .{
                92, 100, 37, 72, 162, 27, 72, 142, 24, 83, 157, 19, 109, 119, 125, 101, 74,
            },
            .previous = .{
                185, 200, 75, 52, 225, 17, 72, 122, 21, 94, 172, 15, 136, 82, 231, 93, 30,
            },
            .selected = .average,
        },
        .{
            .stride = 3,
            .current = .{
                18, 188, 23, 189, 223, 21, 115, 191, 165, 219, 134, 89, 108, 167, 153, 229, 95,
            },
            .previous = .{
                20, 189, 25, 189, 221, 26, 113, 193, 166, 221, 135, 87, 106, 165, 151, 228, 95,
            },
            .selected = .paeth,
        },
        .{
            .stride = 4,
            .current = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .previous = .{
                34, 177, 180, 124, 170, 147, 105, 178, 251, 99, 129, 127, 36, 37, 62, 236, 73,
            },
            .selected = .none,
        },
        .{
            .stride = 4,
            .current = .{ 2, 3, 14, 7, 2, 3, 14, 7, 2, 3, 14, 7, 2, 3, 14, 7, 2 },
            .previous = .{
                75, 237, 222, 170, 178, 236, 78, 237, 84, 207, 194, 224, 145, 113, 132, 91, 105,
            },
            .selected = .sub,
        },
        .{
            .stride = 4,
            .current = .{
                33, 207, 255, 25, 208, 33, 151, 40, 150, 91, 33, 130, 83, 104, 185, 93, 52,
            },
            .previous = .{
                33, 207, 255, 25, 208, 33, 151, 40, 150, 91, 33, 130, 83, 104, 185, 93, 52,
            },
            .selected = .up,
        },
        .{
            .stride = 4,
            .current = .{
                117, 97, 86, 44, 174, 125, 163, 66, 128, 136, 208, 35, 92, 195, 157, 137, 120,
            },
            .previous = .{
                235, 195, 173, 89, 231, 153, 240, 89, 83, 147, 253, 4, 56, 254, 106, 239, 148,
            },
            .selected = .average,
        },
        .{
            .stride = 4,
            .current = .{
                19, 87, 193, 103, 23, 68, 207, 47, 170, 230, 204, 50, 249, 231, 89, 59, 120,
            },
            .previous = .{
                21, 88, 191, 102, 25, 68, 208, 48, 169, 228, 203, 50, 248, 228, 91, 60, 122,
            },
            .selected = .paeth,
        },
        .{
            .stride = 6,
            .current = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .previous = .{
                212, 58, 34, 136, 71, 68, 102, 18, 71, 69, 79, 100, 242, 158, 243, 119, 30,
            },
            .selected = .none,
        },
        .{
            .stride = 6,
            .current = .{ 12, 9, 15, 5, 7, 1, 12, 9, 15, 5, 7, 1, 12, 9, 15, 5, 7 },
            .previous = .{
                53, 150, 196, 31, 180, 44, 208, 11, 246, 175, 48, 22, 71, 132, 57, 92, 214,
            },
            .selected = .sub,
        },
        .{
            .stride = 6,
            .current = .{
                100, 67, 21, 33, 254, 230, 221, 100, 122, 37, 33, 138, 30, 162, 31, 101, 77,
            },
            .previous = .{
                100, 67, 21, 33, 254, 230, 221, 100, 122, 37, 33, 138, 30, 162, 31, 101, 77,
            },
            .selected = .up,
        },
        .{
            .stride = 6,
            .current = .{
                74, 45, 56, 124, 49, 70, 69, 88, 116, 162, 122, 135, 103, 97, 102, 112, 147,
            },
            .previous = .{
                148, 90, 113, 248, 98, 140, 64, 131, 177, 201, 196, 201, 138, 106, 88, 63, 173,
            },
            .selected = .average,
        },
        .{
            .stride = 6,
            .current = .{
                247, 116, 94, 19, 33, 56, 184, 191, 110, 249, 244, 57, 138, 254, 13, 230, 207,
            },
            .previous = .{
                245, 115, 93, 18, 33, 58, 183, 191, 108, 249, 244, 61, 137, 252, 13, 229, 209,
            },
            .selected = .paeth,
        },
        .{
            .stride = 8,
            .current = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .previous = .{
                10, 84, 50, 162, 146, 104, 245, 199, 64, 3, 253, 32, 46, 180, 192, 186, 139,
            },
            .selected = .none,
        },
        .{
            .stride = 8,
            .current = .{ 4, 11, 1, 5, 11, 10, 11, 14, 4, 11, 1, 5, 11, 10, 11, 14, 4 },
            .previous = .{
                237, 245, 13, 31, 174, 125, 223, 241, 155, 40, 209, 41, 195, 213, 251, 150, 251,
            },
            .selected = .sub,
        },
        .{
            .stride = 8,
            .current = .{
                146, 223, 146, 89, 44, 177, 1, 8, 40, 28, 196, 70, 243, 74, 115, 177, 65,
            },
            .previous = .{
                146, 223, 146, 89, 44, 177, 1, 8, 40, 28, 196, 70, 243, 74, 115, 177, 65,
            },
            .selected = .up,
        },
        .{
            .stride = 8,
            .current = .{ 55, 9, 83, 22, 83, 99, 21, 38, 110, 12, 112, 26, 107, 127, 42, 79, 90 },
            .previous = .{
                111, 18, 167, 45, 167, 198, 42, 76, 165, 15, 141, 30, 131, 155, 64, 121, 70,
            },
            .selected = .average,
        },
        .{
            .stride = 8,
            .current = .{
                31, 148, 159, 170, 191, 191, 185, 1, 195, 177, 177, 170, 247, 36, 51, 200, 39,
            },
            .previous = .{
                29, 150, 158, 168, 189, 192, 185, 1, 194, 179, 177, 168, 246, 34, 51, 200, 38,
            },
            .selected = .paeth,
        },
    };
    for (controls) |control| {
        try std.testing.expectEqual(
            control.selected,
            chooseFilter(&control.current, &control.previous, control.stride),
        );
    }

    // All predictors tie on zeros; Up duplicates None without a previous row. Paeth duplicates Sub
    // on that first row, so its larger selector cannot win.
    try std.testing.expectEqual(Filter.Type.none, chooseFilter(&.{}, null, 8));
    try std.testing.expectEqual(Filter.Type.none, chooseFilter(&.{ 128, 0, 255 }, null, 8));
    try std.testing.expectEqual(Filter.Type.sub, chooseFilter(&.{ 128, 128, 128 }, null, 1));
}

test "Up filtering matches scalar subtraction across alignments and row boundaries" {
    var random: std.Random.DefaultPrng = .init(0x51c8);
    var current: [192]u8 = undefined;
    var previous: [192]u8 = undefined;
    for (0..32) |offset| {
        const prior_offset = (offset * 5 + 7) % 32;
        const output_offset = (offset * 13 + 11) % 32;
        for (0..71) |index| {
            const len = if (index < 66) index else 123 + index - 66;
            random.random().bytes(&current);
            random.random().bytes(&previous);
            for ([_]bool{ false, true }) |has_previous| {
                var output: [208]u8 = @splat(0xa5);
                const row = current[offset..][0..len];
                const prior: ?[]const u8 = if (has_previous)
                    previous[prior_offset..][0..len]
                else
                    null;
                filterRow(output[output_offset..][0 .. len + 1], row, prior, 4, .up);
                try std.testing.expectEqual(@as(u8, 2), output[output_offset]);
                for (0..len) |i| {
                    const above = if (prior) |data| data[i] else 0;
                    try std.testing.expectEqual(row[i] -% above, output[output_offset + 1 + i]);
                }
                for (
                    output[0..output_offset],
                ) |value| try std.testing.expectEqual(@as(u8, 0xa5), value);
                for (
                    output[output_offset + len + 1 ..],
                ) |value| try std.testing.expectEqual(@as(u8, 0xa5), value);
            }
        }
    }
}
