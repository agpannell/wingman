//! Suspended native zlib inflation and shared PNG pass/row reconstruction.

const png_format = @import("format.zig");
const ImageData = @import("ImageData.zig");
const Header = @import("Header.zig");
const std = @import("std");
const deflate = @import("../deflate.zig");
const zlib = @import("../zlib.zig");
const SourceImage = @import("Source.zig");
const RgbaConverter = @import("RgbaConverter.zig");
const decode_backing = @import("decode_workspace.zig");
const filters = @import("scanline_filters.zig");
const ImageRegion = @import("../common/ImageRegion.zig");

/// Independent LZ history required by the streaming zlib decoder.
pub const history_bytes = 32768;

/// Raster/framing failure, explicit backing shortage or bounded inflation policy exhaustion.
pub const Error = png_format.Error || ImageRegion.Error || error{
    HistoryTooSmall,
    RowsTooSmall,
    ConversionRowTooSmall,
    EncodedBudgetExceeded,
    DestinationTooSmall,
    ReconstructionTooSmall,
};

/// Input suspension, one reconstructed pass row or persistent completion/failure/cancellation.
pub const Status = enum { need_input, row, done, failed, canceled };

/// Generic inflation policy, excluding outer PNG framing/filter/conversion work. Container/region
/// owners charge their own work separately and supply the remaining budget.
pub const Options = struct {
    /// Accepted compressed payload bytes, excluding unused bytes after the first zlib stream.
    maximum_encoded_bytes: usize = std.math.maxInt(usize),
    /// Accepted zlib input plus restored output bytes, charged once each.
    maximum_inflate_work_units: usize = std.math.maxInt(usize),
};

/// Required caller backing for pass-local raster reconstruction, independent of selected output.
pub const Requirements = struct {
    /// Separate generic history backing in bytes.
    history_bytes: usize,
    /// Existing final-address generic DEFLATE workspace bytes.
    workspace_bytes: usize,
    /// Two full-width packed slots, each including its filter-byte position.
    packed_rows_bytes: usize,
    /// Full-width conversion row in Sample elements, four per pixel.
    conversion_row_samples: usize,
    /// Conversion row storage in bytes.
    conversion_row_bytes: usize,
    /// Source pixels visited by all nonempty passes exactly once.
    source_pixels: usize,
    /// Exact complete inflated bytes across all passes, including filter bytes.
    filtered_bytes: usize,
    /// Filtered-byte reconstruction visits plus four conversion sample visits per source pixel.
    /// Generic inflation and selected scatter/delivery work are additional.
    reconstruction_work_units: usize,
};

/// Computes checked backing and format work from copied, immutable admitted geometry.
pub fn requirements(comptime Sample: type, header: Header) Error!Requirements {
    if (Sample != u8 and Sample != u16) @compileError("PNG output samples must be u8 or u16");
    const row_stride = std.math.add(
        usize,
        header.packed_row_bytes,
        1,
    ) catch return error.InvalidPng;
    const row_bytes = std.math.mul(usize, row_stride, 2) catch return error.InvalidPng;
    const conversion_samples = std.math.mul(usize, header.width, 4) catch return error.InvalidPng;
    const conversion_bytes = std.math.mul(
        usize,
        conversion_samples,
        @sizeOf(Sample),
    ) catch return error.InvalidPng;
    const source_pixels = std.math.mul(
        usize,
        header.width,
        header.height,
    ) catch return error.InvalidPng;
    const conversion_work = std.math.mul(
        usize,
        source_pixels,
        4,
    ) catch return error.WorkBudgetExceeded;
    return .{
        .history_bytes = history_bytes,
        .workspace_bytes = @sizeOf(deflate.DecoderWorkspace),
        .packed_rows_bytes = row_bytes,
        .conversion_row_samples = conversion_samples,
        .conversion_row_bytes = conversion_bytes,
        .source_pixels = source_pixels,
        .filtered_bytes = header.filtered_byte_count,
        .reconstruction_work_units = std.math.add(
            usize,
            header.filtered_byte_count,
            conversion_work,
        ) catch return error.WorkBudgetExceeded,
    };
}

/// Suspended byte/word raster owner with movable small state and separate caller backing. Calls are
/// serialized. Keep header, converter and all other decoder fields unchanged except through
/// methods; borrowed palettes and backing remain live for the decoder's use.
pub fn Decoder(comptime Sample: type) type {
    if (Sample != u8 and Sample != u16) @compileError("PNG output samples must be u8 or u16");
    return struct {
        const Self = @This();

        /// A complete converted reduced-image row; texels borrow the conversion backing.
        pub const Row = struct {
            /// First source column visited by this pass.
            first_x: u32,
            /// Full-image source row coordinate.
            y: u32,
            /// Source-grid distance between successive row pixels.
            step_x: u32,
            /// Number of pixels in this reduced row.
            width: u32,
            /// Complete tightly packed RGBA row; copy before the next decoder call.
            texels: []const Sample,
        };

        /// Acknowledged input progress and at most one complete pass row from this call.
        pub const Step = struct {
            /// Accepted payload prefix, excluding the unused first-stream suffix. A failed codec
            /// progress acknowledges only earlier successful steps; its working input is discarded.
            consumed: usize,
            /// One complete provisional pass row, present only with row status.
            row: ?Row = null,
            /// Input suspension, row or persistent terminal result.
            status: Status,
            /// Persistent cause, present only for failed.
            failure: ?Error = null,
        };

        /// Complete source geometry/declarations, copied without input borrows.
        header: Header,
        /// Sample interpretation whose palettes borrow independent caller/source storage.
        converter: RgbaConverter,
        /// Generic dependency state, exposing exact encoded/filtered/work counters.
        inflater: zlib.Decoder,
        /// Internal inflation limits; do not modify while decoding.
        inflation_limits: zlib.DecodeLimits,
        /// Borrowed final-address DEFLATE workspace.
        workspace: *deflate.DecoderWorkspace,
        /// Borrowed 32 KiB history prefix.
        history: *[history_bytes]u8,
        /// Borrowed packed-row scratch prefix.
        rows: []u8,
        /// Borrowed converted-row scratch prefix in Sample elements.
        conversion_row: []Sample,
        /// Byte capacity of one full-width packed row including its selector.
        row_stride: usize,
        /// Internal index of the current sequential or Adam7 pass.
        pass_index: usize = 0,
        /// Internal geometry of the current pass.
        pass: png_format.Pass = undefined,
        /// Current pass width in pixels.
        pass_width: usize = 0,
        /// Current pass height in pixels.
        pass_height: usize = 0,
        /// Current packed row length in bytes, excluding its selector.
        pass_row_bytes: usize = 0,
        /// Current pass-local row index.
        row_index: usize = 0,
        /// Inflated bytes collected for the current row, including its selector.
        row_filled: usize = 0,
        /// Whether zlib has completed.
        zlib_done: bool = false,
        /// Whether the caller has declared payload end.
        eof: bool = false,
        /// Internal decoder phase; change it only through decoder methods.
        phase: enum { rows, trailer, done, failed, canceled } = .rows,
        /// Persistent failure cause, or null until the decoder fails.
        failure: ?Error = null,

        /// Adopts disjoint stable backing without changing it or allocating. The small decoder may
        /// move between calls; no allocator is retained. Keep workspace/history, rows/conversion,
        /// palettes and payload fragments disjoint through each use.
        pub fn init(
            header: Header,
            converter: RgbaConverter,
            storage: decode_backing.Storage(Sample),
            options: Options,
        ) Error!Self {
            const plan = try requirements(Sample, header);
            if (storage.packed_rows.len < plan.packed_rows_bytes) return error.RowsTooSmall;
            if (storage.conversion_row.len < plan.conversion_row_samples)
                return error.ConversionRowTooSmall;
            if (converter.bit_depth != header.bit_depth or converter.color_type != header
                .color_type or converter.channel_count != header.channel_count or converter
                .bits_per_pixel != header.bits_per_pixel)
            {
                return error.InvalidPng;
            }
            if (converter.color_type == 3 and (converter.palette.len == 0 or converter.palette.len >
                @as(
                    usize,
                    1,
                ) << @as(
                    std.math.Log2Int(usize),
                    @intCast(header.bit_depth),
                ) or converter.palette_alpha.len > converter.palette.len))
            {
                return error.InvalidPng;
            }
            if (storage.history.len < history_bytes) return error.HistoryTooSmall;
            var result: Self = .{
                .header = header,
                .converter = converter,
                .inflater = undefined,
                .inflation_limits = .{
                    .input_bytes = options.maximum_encoded_bytes,
                    .output_bytes = header.filtered_byte_count,
                    .work_units = options.maximum_inflate_work_units,
                },
                .workspace = storage.workspace,
                .history = storage.history[0..history_bytes],
                .rows = storage.packed_rows[0..plan.packed_rows_bytes],
                .conversion_row = storage.conversion_row[0..plan.conversion_row_samples],
                .row_stride = header.packed_row_bytes + 1,
            };
            result.inflater.reset(
                .{ .workspace = result.workspace, .history = result.history },
                .{ .limits = result.inflation_limits },
            ) catch |err| return mapFailure(err);
            result.selectPass();
            return result;
        }

        /// Accepts borrowed zlib payload and emits at most one complete pass row. Resubmit unused
        /// input and copy the row before the next call. Failure emits no current row; private
        /// rows/conversion may change, while unused backing stays unchanged.
        pub fn step(self: *Self, input: []const u8) Step {
            var consumed: usize = 0;
            while (true) {
                switch (self.phase) {
                    .done => return .{ .consumed = consumed, .status = .done },
                    .failed => return .{
                        .consumed = consumed,
                        .status = .failed,
                        .failure = self.failure,
                    },
                    .canceled => return .{ .consumed = consumed, .status = .canceled },
                    .trailer => {
                        if (self.zlib_done) {
                            self.phase = .done;
                            continue;
                        }
                        const progress = self.inflate(
                            input[consumed..],
                            &.{},
                        ) catch |err| return self.fail(consumed, err);
                        consumed += progress.consumed;
                        switch (progress.status) {
                            .complete => {
                                if (self.inflater.output_bytes != self.header.filtered_byte_count)
                                    return self.fail(
                                        consumed,
                                        error.InvalidPng,
                                    );
                                self.zlib_done = true;
                            },
                            .need_input => return .{ .consumed = consumed, .status = .need_input },
                            .need_output => return self.fail(consumed, error.InvalidPng),
                            .need_dictionary => return self.fail(consumed, error.InvalidPng),
                        }
                    },
                    .rows => {
                        const offset = (self.row_index & 1) * self.row_stride;
                        const filtered = self.rows[offset..][0 .. self.pass_row_bytes + 1];
                        const progress = self.inflate(
                            input[consumed..],
                            filtered[self.row_filled..],
                        ) catch |err| return self.fail(consumed, err);
                        consumed += progress.consumed;
                        self.row_filled += progress.produced;
                        self.zlib_done = progress.status == .complete;
                        if (self.row_filled != filtered.len) {
                            if (progress.status == .complete) return self.fail(
                                consumed,
                                error.InvalidPng,
                            );
                            if (progress.status != .need_input) return self.fail(
                                consumed,
                                error.InvalidPng,
                            );
                            return .{ .consumed = consumed, .status = .need_input };
                        }
                        if (filtered[0] > 4) return self.fail(consumed, error.InvalidPng);
                        const previous: ?[]const u8 = if (self.row_index == 0) null else blk: {
                            const previous_offset = ((self.row_index - 1) & 1) * self.row_stride;
                            break :blk self.rows[previous_offset + 1 ..][0..self.pass_row_bytes];
                        };
                        const stride = if (self.header.bit_depth < 8 or self.header.color_type == 3)
                            1
                        else
                            self.header.channel_count * (@as(
                                usize,
                                self.header.bit_depth,
                            ) / 8);
                        filters.reconstructRow(
                            filtered[1..],
                            filtered[1..],
                            previous,
                            stride,
                            filtered[0],
                        );
                        self.converter.convertRow(
                            Sample,
                            self.conversion_row,
                            self.pass_width,
                            filtered[1..],
                        ) catch |err| return self.fail(consumed, switch (err) {
                            error.OutputTooSmall => error.InvalidPng,
                            else => |failure| failure,
                        });
                        const row: Row = .{
                            .first_x = @intCast(self.pass.start_x),
                            .y = @intCast(self.pass.start_y + self.row_index * self.pass.step_y),
                            .step_x = @intCast(self.pass.step_x),
                            .width = @intCast(self.pass_width),
                            .texels = self.conversion_row[0 .. self.pass_width * 4],
                        };
                        self.row_filled = 0;
                        self.row_index += 1;
                        if (self.row_index == self.pass_height) {
                            self.pass_index += 1;
                            self.selectPass();
                        }
                        if (self.zlib_done and self.phase != .trailer) return self.fail(
                            consumed,
                            error.InvalidPng,
                        );
                        return .{ .consumed = consumed, .status = .row, .row = row };
                    },
                }
            }
        }

        /// Declares actual payload EOF and drains pending output rows. A row permits another
        /// finish; only done accepts all raster bytes and zlib. PNG framing remains outer work.
        pub fn finish(self: *Self) Step {
            self.eof = true;
            return self.step(&.{});
        }

        /// Stops until reset without changing backing or an already copied row.
        pub fn cancel(self: *Self) void {
            self.phase = .canceled;
        }

        /// Restarts the same admitted geometry/converter/backing/policy without allocation.
        pub fn reset(self: *Self) void {
            self.inflater.reset(
                .{ .workspace = self.workspace, .history = self.history },
                .{ .limits = self.inflation_limits },
            ) catch unreachable;
            self.pass_index = 0;
            self.row_index = 0;
            self.row_filled = 0;
            self.zlib_done = false;
            self.eof = false;
            self.phase = .rows;
            self.failure = null;
            self.selectPass();
        }

        fn selectPass(self: *Self) void {
            const count: usize = if (self.header.interlace_method == 0) 1 else png_format
                .adam7_passes.len;
            while (self.pass_index < count) : (self.pass_index += 1) {
                const pass = if (self.header.interlace_method == 0) png_format
                    .sequential_pass else png_format.adam7_passes[self.pass_index];
                const width = png_format.passExtent(self.header.width, pass.start_x, pass.step_x);
                const height = png_format.passExtent(self.header.height, pass.start_y, pass.step_y);
                if (width == 0 or height == 0) continue;
                self.pass = pass;
                self.pass_width = width;
                self.pass_height = height;
                // Copied admitted geometry bounds each reduced row by the full-width row.
                self.pass_row_bytes = png_format.packedRowBytes(
                    width,
                    self.header.bits_per_pixel,
                ) catch unreachable;
                self.row_index = 0;
                return;
            }
            self.phase = .trailer;
        }

        /// Accepted zlib input plus restored bytes, charged once across successful steps.
        pub fn inflationWork(self: *const Self) usize {
            return @intCast(self.inflater.input_bytes + self.inflater.output_bytes);
        }

        /// Updates the remaining byte-work budget after outer PNG framing reserves more work.
        pub fn limitInflationWork(self: *Self, maximum: usize) Error!void {
            const used = self.inflationWork();
            if (maximum < used) return error.WorkBudgetExceeded;
            self.inflation_limits.work_units = maximum;
            self.inflater.limits.work_units = maximum;
            self.inflater.work_left = maximum - used;
        }

        fn inflate(self: *Self, input: []const u8, output: []u8) Error!zlib.DecodeProgress {
            const input_left: usize = @intCast(
                self.inflation_limits.input_bytes - self.inflater.input_bytes,
            );
            const output_left: usize = @intCast(
                self.inflation_limits.output_bytes - self.inflater.output_bytes,
            );
            const admitted_input = input[0..@min(input.len, input_left)];
            const admitted_output = output[0..@min(output.len, output_left)];
            const progress = self.inflater.step(
                .{ .bytes = admitted_input, .final = self.eof and admitted_input.len == input.len },
                admitted_output,
            ) catch |err| return mapFailure(err);
            if (progress.status == .need_dictionary) return error.InvalidPng;
            if (progress.status == .need_input and admitted_input.len < input.len)
                return error.EncodedBudgetExceeded;
            if (progress.status == .need_output and admitted_output.len == 0)
                return error.InvalidPng;
            return progress;
        }

        fn fail(self: *Self, consumed: usize, failure: Error) Step {
            self.phase = .failed;
            self.failure = failure;
            return .{ .consumed = consumed, .status = .failed, .failure = failure };
        }
    };
}

fn mapFailure(failure: zlib.DecodeError) Error {
    return switch (failure) {
        error.LimitExceeded, error.CounterOverflow => error.WorkBudgetExceeded,
        else => error.InvalidPng,
    };
}

test "suspended PNG raster retires every stored-stream split and preserves backing suffixes" {
    const allocator = std.testing.allocator;
    const workspace = try deflate.DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.alloc(u8, history_bytes + 3);
    defer allocator.free(history);
    const header = try Header.fromIhdr(&.{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0 }, 1);
    const converter: RgbaConverter = .{
        .bit_depth = 8,
        .color_type = 6,
        .channel_count = 4,
        .bits_per_pixel = 32,
        .palette = &.{},
        .palette_alpha = &.{},
        .transparent_gray = null,
        .transparent_rgb = null,
    };
    // Independently framed RFC 1950/1951 stored row; Adler sums s1=11, s2=25.
    const source = [_]u8{ 0x78, 1, 1, 5, 0, 250, 255, 0, 1, 2, 3, 4, 0, 25, 0, 11 };
    inline for (.{ u8, u16 }) |Sample| {
        const guard: Sample = if (Sample == u8) 0xa5 else 0xa5a5;
        var rows: [13]u8 = undefined;
        var conversion: [7]Sample = undefined;
        for (0..source.len + 1) |split| {
            @memset(history, 0xa5);
            @memset(&rows, 0xa5);
            @memset(&conversion, guard);
            var decoder = try Decoder(
                Sample,
            ).init(
                header,
                converter,
                .{
                    .workspace = workspace,
                    .history = history,
                    .packed_rows = &rows,
                    .conversion_row = &conversion,
                },
                .{},
            );
            var produced: usize = 0;
            for ([_][]const u8{ source[0..split], source[split..] }) |part| {
                const fragment = try allocator.dupe(u8, part);
                var offset: usize = 0;
                while (true) {
                    const progress = decoder.step(fragment[offset..]);
                    offset += progress.consumed;
                    if (progress.row) |row| {
                        try std.testing.expectEqual(0, row.first_x);
                        try std.testing.expectEqual(0, row.y);
                        try std.testing.expectEqual(1, row.step_x);
                        try std.testing.expectEqual(1, row.width);
                        const expected: [4]Sample = if (Sample == u8) .{
                            1, 2, 3, 4,
                        } else .{ 257, 514, 771, 1028 };
                        try std.testing.expectEqualSlices(Sample, &expected, row.texels);
                        produced += 1;
                    }
                    if (progress.status == .row) continue;
                    try std.testing.expect(
                        progress.status == .need_input or progress.status == .done,
                    );
                    break;
                }
                try std.testing.expectEqual(fragment.len, offset);
                @memset(fragment, 0xe7);
                allocator.free(fragment);
            }
            try std.testing.expectEqual(Status.done, decoder.finish().status);
            try std.testing.expectEqual(1, produced);
            try std.testing.expectEqual(source.len, decoder.inflater.input_bytes);
            try std.testing.expectEqual(5, decoder.inflater.output_bytes);
            for (rows[10..]) |value| try std.testing.expectEqual(0xa5, value);
            for (conversion[4..]) |value| try std.testing.expectEqual(guard, value);
            for (history[history_bytes..]) |value| try std.testing.expectEqual(0xa5, value);
            decoder.cancel();
            try std.testing.expectEqual(Status.canceled, decoder.step(&source).status);
            decoder.reset();
            try std.testing.expectEqual(Status.failed, decoder.finish().status);
            try std.testing.expectEqual(error.InvalidPng, decoder.failure.?);
            try std.testing.expectEqual(0, decoder.step(&source).consumed);
        }
    }
}

pub fn PassRowReader(comptime Sample: type) type {
    return struct {
        const Self = @This();
        data: ImageData,
        payloads: ImageData.Iterator,
        remaining: []const u8 = &.{},
        eof: bool = false,
        decoder: Decoder(Sample),

        pub fn init(
            image: SourceImage,
            storage: decode_backing.Storage(Sample),
            inflate_budget: usize,
            policy: png_format.PaletteIndexPolicy,
        ) Error!Self {
            return .{
                .data = image.image_data,
                .payloads = image.image_data.payloads(),
                .decoder = try Decoder(
                    Sample,
                ).init(
                    image.header(),
                    RgbaConverter.initWithPolicy(image, policy),
                    storage,
                    .{
                        .maximum_encoded_bytes = image.image_data.byte_count,
                        .maximum_inflate_work_units = inflate_budget,
                    },
                ),
            };
        }

        pub fn next(self: *Self) Error!?Decoder(Sample).Row {
            while (true) {
                while (!self.eof and self.remaining.len == 0) {
                    self.remaining = self.payloads.next() orelse blk: {
                        self.eof = true;
                        break :blk &.{};
                    };
                }
                const progress = if (self.eof) self.decoder.finish() else self.decoder.step(
                    self.remaining,
                );
                self.remaining = self.remaining[progress.consumed..];
                switch (progress.status) {
                    .row => return progress.row.?,
                    .need_input => std.debug.assert(self.remaining.len == 0),
                    .done => return null, // Existing profile accepts unused post-zlib IDAT tails.
                    .failed => return progress.failure.?,
                    .canceled => unreachable,
                }
            }
        }

        pub fn reset(self: *Self) void {
            self.decoder.reset();
            self.payloads = self.data.payloads();
            self.remaining = &.{};
            self.eof = false;
        }
    };
}
