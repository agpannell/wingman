//! Fragmented PNG framing and caller-reserved complete row publication.

const png_format = @import("format.zig");
const Header = @import("Header.zig");
const std = @import("std");
const png = @import("../png.zig");
const png_palette_vectors = @import("testdata/palette.zig");
const png_raster_vectors = @import("testdata/raster.zig");
const deflate = @import("../deflate.zig");
const Chunk = @import("Chunk.zig");
const RgbaConverter = @import("RgbaConverter.zig");
const raster = @import("raster_decoder.zig");
const regions = @import("region_decode.zig");
const ImageRegion = @import("../common/ImageRegion.zig");
const decode_backing = @import("decode_workspace.zig");

const Crc32 = @import("../crc.zig").Crc32IsoHdlc;

/// Source/selection policy plus framing knowledge; omitted region selects the whole source.
const StreamDecodeOptions = struct {
    /// Nonempty top-left source-grid selection, checked after the complete IHDR accepts.
    region: ?ImageRegion = null,
    /// Maximum selected width or height in pixels; defaults to the largest u32.
    maximum_selected_extent: u32 = std.math.maxInt(u32),
    /// Expected complete PNG length in bytes; null admits each declared chunk incrementally.
    total_bytes: ?usize = null,
    /// Independent stored axes, complete encoded size, selected output and work/metadata limits.
    policy: regions.Options = .{},
};

/// Caller-owned backing kept stable and mutually disjoint for the decoder's lifetime. Each input
/// fragment must also be disjoint during its call. Palette storage is required only for actual
/// indexed chunks; advertised maximums permit preflight.
fn StreamStorage(comptime Sample: type) type {
    return struct {
        /// Generic workspace/history and private packed/conversion rows.
        raster: decode_backing.Storage(Sample),
        /// Actual indexed PLTE entries; suggested truecolor palettes require no storage.
        palette: [][3]u8 = &.{},
        /// Actual indexed tRNS entries, with missing entries opaque.
        alpha: []u8 = &.{},
        /// Selected Adam7 reconstruction; zero elements suffice for sequential rows.
        reconstruction: []Sample = &.{},
        /// At least one complete selected RGBA row; unused capacity stays unchanged.
        output_row: []Sample,
    };
}

/// Framing/pixel/policy or explicit caller backing shortage.
pub const Error = raster.Error || error{ PaletteTooSmall, AlphaTooSmall, OutputRowTooSmall };

/// Input suspension, one complete selected row or persistent terminal result.
const InternalStatus = enum { need_input, row, done, failed, canceled };

/// Copied geometry/costs available after IHDR without reserving output or reading pixels.
const StreamRequirements = struct {
    /// Selected geometry/backing and fixed/minimum format work; inflation is data-dependent.
    selected: regions.Requirements,
    /// Movable parser/raster state bytes, excluding every separate backing span.
    state_bytes: usize,
    /// Maximum indexed RGB palette backing permitted by the declared depth, in bytes.
    palette_bytes: usize,
    /// Maximum indexed transparency backing permitted by that depth, in bytes.
    alpha_bytes: usize,
    /// Exactly one selected RGBA row in Sample elements.
    output_row_samples: usize,
    /// Exactly one selected RGBA row in bytes.
    output_row_bytes: usize,
};

/// Plans admitted copied source geometry with the same policy used by the stream. Unknown total
/// lengths report zero encoded bytes; future chunks reserve their framing work.
fn planHeader(
    comptime Sample: type,
    header: Header,
    options: StreamDecodeOptions,
) Error!StreamRequirements {
    if (header.width > options.policy.maximum_source_extent or header.height > options.policy
        .maximum_source_extent) return error.InvalidPng;
    const encoded_bytes = options.total_bytes orelse 0;
    if (encoded_bytes > options.policy.maximum_encoded_bytes) return error.EncodedBudgetExceeded;
    const rectangle = options.region orelse ImageRegion{
        .x = 0,
        .y = 0,
        .width = header.width,
        .height = header.height,
    };
    if (rectangle.width > options.maximum_selected_extent or rectangle.height > options
        .maximum_selected_extent) return error.InvalidPng;
    const selected = (try regions.Plan(
        Sample,
    ).init(header, rectangle, encoded_bytes, options.policy.limits)).requirements;
    const entries: usize = if (header.color_type == 3) @as(
        usize,
        1,
    ) << @as(std.math.Log2Int(usize), @intCast(header.bit_depth)) else 0;
    return .{
        .selected = selected,
        .state_bytes = @sizeOf(StreamDecoder(Sample)),
        .palette_bytes = entries * 3,
        .alpha_bytes = entries,
        .output_row_samples = selected.row_samples,
        .output_row_bytes = selected.row_samples * @sizeOf(Sample),
    };
}

/// Borrowed fragment; final identifies physical EOF immediately after these bytes. A row pause may
/// leave a suffix to resubmit. The end marker remains latched without retaining a fragment pointer.
const InputFragment = struct {
    /// Bytes offered in this call; the decoder retains no fragment pointer.
    bytes: []const u8 = &.{},
    /// True when physical EOF follows this fragment, including an empty final fragment.
    final: bool = false,
};

/// Exact accepted prefix and one suspension, row or terminal event. Rows borrow the reserved output
/// row through the next mutating call. Sequential rows are provisional; Adam7 rows follow full EOF.
fn DecodeProgress(comptime Sample: type) type {
    return struct {
        /// The next input request, completed row, or persistent terminal outcome.
        pub const Event = union(enum) {
            /// Supply more input; the previous fragment's unconsumed suffix remains with the
            /// caller.
            need_input,
            /// A complete selected row borrowing the reserved output row until the next mutating
            /// call.
            row: StreamDecoder(Sample).Row,
            /// The full image and physical end have been validated.
            complete,
            /// A persistent decoding or resource failure; reset before reuse.
            failed: Error,
            /// The caller canceled the decoder; reset before reuse.
            canceled,
        };
        /// Prefix accepted from the current fragment; resubmit any remaining suffix.
        consumed: usize,
        /// One event describing why this call stopped.
        event: Event,
    };
}

/// Movable suspended parser; serialized calls retain only copied facts and caller backing. Inspect
/// documented progress fields but modify decoder state only through its methods. Reset restarts the
/// same options/storage; persistent failure or cancellation consumes nothing.
pub fn StreamDecoder(comptime Sample: type) type {
    if (Sample != u8 and Sample != u16) @compileError("PNG output samples must be u8 or u16");
    return struct {
        const Self = @This();

        /// Framing and selected-output policy; copied at initialization.
        pub const Options = StreamDecodeOptions;
        /// Caller backing retained at stable, disjoint addresses.
        pub const Storage = StreamStorage(Sample);
        /// Copied header-only capacity and work facts.
        pub const Requirements = StreamRequirements;
        /// One borrowed fragment and its physical end-of-input marker.
        pub const Input = InputFragment;
        /// Accepted prefix and one suspension, row or terminal event.
        pub const Progress = DecodeProgress(Sample);

        /// Plans copied admitted header geometry without allocating or constructing a decoder.
        pub fn plan(source_header: Header, options: Options) Error!Requirements {
            return planHeader(Sample, source_header, options);
        }

        /// Complete crop row and explicitly bounded metadata observations.
        pub const Row = struct {
            /// Ascending crop-relative top-left row coordinate.
            row_index: u32,
            /// Copied source facts plus exact row samples borrowing reserved output row storage.
            image: regions.View(Sample),
            /// False for provisional sequential rows; true after Adam7 accepts complete EOF.
            metadata_presence_complete: bool,
        };

        /// Exact accepted prefix and at most one complete row, with persistent terminal cause.
        const InternalStep = struct {
            /// Bytes accepted from this call; resubmit its unused suffix.
            consumed: usize,
            /// Complete row, present only with row status; copy before the next call.
            image: ?Row = null,
            /// Suspension, row or terminal result.
            status: InternalStatus,
            /// Cause, present only for failed.
            failure: ?Error = null,
        };

        /// Accepted PNG bytes so far, including ignored chunks and unused compressed tails; inspect
        /// but do not modify.
        input_bytes: usize = 0,
        /// Complete selected rows delivered so far; inspect but do not modify.
        produced_rows: u32 = 0,
        /// Copied geometry/backing/work facts after checked IHDR; inspect but do not modify.
        cached_requirements: ?Requirements = null,
        /// Internal copied policy; do not modify while using the decoder.
        options: Options,
        /// Internal borrows of caller backing; do not replace while using the decoder.
        storage: Storage,
        /// Internal chunk-order and structural admission state.
        validator: Chunk.Validator,
        /// Internal admitted geometry and selection.
        region_plan: ?regions.Plan(Sample) = null,
        /// Internal raster decoder, initialized after geometry admission.
        decoder: ?raster.Decoder(Sample) = null,
        /// Internal buffer for a signature, header or selected payload prefix.
        inline_data: [13]u8 = undefined,
        /// Bytes currently held in inline_data.
        inline_filled: usize = 0,
        /// Declared current chunk payload length in bytes.
        payload_length: usize = 0,
        /// Current chunk payload bytes still to accept.
        payload_remaining: usize = 0,
        /// Internal current chunk classification.
        kind: Chunk.Validator.Kind = .other,
        /// Internal running CRC of the current chunk type and payload.
        crc: Crc32 = Crc32.init(),
        /// Internal encoded CRC assembled from the current chunk.
        stored_crc: u32 = 0,
        /// Complete declared chunk bytes, including framing and payload, reserved so far.
        declared_bytes: usize = png_format.signature.len,
        /// Fixed raster work reserved under the current policy.
        fixed_raster_work: usize = 0,
        /// Whether the zlib raster has completed.
        raster_done: bool = false,
        /// Whether the image-data chunk sequence has ended.
        raster_closed: bool = false,
        /// Whether the final offered input has been fully consumed.
        eof: bool = false,
        /// Unconsumed bytes in the final offered fragment, or null before final input.
        final_input_remaining: ?usize = null,
        /// Internal parser phase; change it only through decoder methods.
        phase: enum {
            signature,
            chunk_header,
            payload,
            crc,
            after_end,
            delivery,
            done,
            failed,
            canceled,
        } = .signature,
        /// Persistent failure cause, or null until the decoder fails.
        failure: ?Error = null,

        /// Adopts unchanged stable disjoint backing without allocation or an allocator borrow.
        /// Geometry-dependent shortages are checked after IHDR, before the first output row write.
        pub fn init(storage: Storage, options: Options) Error!Self {
            const encoded_bytes = options.total_bytes orelse png_format.signature.len;
            if (encoded_bytes < png_format.signature.len) return error.InvalidPng;
            if (encoded_bytes > options.policy.maximum_encoded_bytes)
                return error.EncodedBudgetExceeded;
            try png_format.admitWork(options.policy.limits, encoded_bytes);
            if (storage.raster.history.len < raster.history_bytes) return error.HistoryTooSmall;
            return .{
                .storage = storage,
                .options = options,
                .validator = Chunk.Validator.init(
                    .{
                        .maximum_source_extent = options.policy.maximum_source_extent,
                        .maximum_records = options.policy.limits.maximum_records,
                        .maximum_metadata_bytes = options.policy.limits.maximum_metadata_bytes,
                    },
                ),
            };
        }

        /// Accepts retired fragments and one latched physical end. Final fragments can contain
        /// bytes; resubmit each unconsumed suffix after a row pause, then drain empty input through
        /// complete. The final flag need not be repeated. No fragment pointer is retained. Current
        /// failure preserves the complete output row and reports exactly the accepted input prefix.
        pub fn step(self: *Self, input: Input) Progress {
            if (self.phase == .done or self.phase == .failed or self.phase == .canceled)
                return toProgress(
                    self.process(input.bytes),
                );
            if (self.final_input_remaining) |remaining| {
                if (input.bytes.len > remaining or (input.final and input.bytes.len != remaining))
                    return toProgress(
                        self.fail(0, error.InvalidPng),
                    );
            } else if (input.final) self.final_input_remaining = input.bytes.len;

            var result = self.process(input.bytes);
            if (self.final_input_remaining) |remaining| {
                self.final_input_remaining = remaining - result.consumed;
                if (self.final_input_remaining.? == 0) {
                    self.eof = true;
                    if (result.status == .need_input) {
                        const accepted = result.consumed;
                        result = self.process(&.{});
                        result.consumed = accepted;
                    }
                }
            }
            return toProgress(result);
        }

        fn toProgress(result: InternalStep) Progress {
            return .{ .consumed = result.consumed, .event = switch (result.status) {
                .need_input => .need_input,
                .row => .{ .row = result.image.? },
                .done => .complete,
                .failed => .{ .failed = result.failure.? },
                .canceled => .canceled,
            } };
        }

        /// Accepts fragments that may retire after this call; no fragment pointer is retained. Rows
        /// remain provisional until done; every current failure preserves the entire output row.
        /// Keep calling after each row with unused input. IEND awaits actual finish/EOF.
        fn process(self: *Self, input: []const u8) InternalStep {
            if (self.eof and input.len != 0 and self.phase != .done and self.phase != .failed and
                self.phase != .canceled) return self.fail(
                0,
                error.InvalidPng,
            );
            var consumed: usize = 0;
            while (true) switch (self.phase) {
                .done => return .{ .consumed = consumed, .status = .done },
                .failed => return .{
                    .consumed = consumed,
                    .status = .failed,
                    .failure = self.failure,
                },
                .canceled => return .{ .consumed = consumed, .status = .canceled },
                .signature => {
                    if (!(self.copyInline(
                        input,
                        &consumed,
                        8,
                    ) catch |err| return self.fail(
                        consumed,
                        err,
                    ))) return self.suspension(consumed);
                    if (!std.mem.eql(
                        u8,
                        self.inline_data[0..8],
                        png_format.signature,
                    )) return self.fail(consumed, error.InvalidPng);
                    self.inline_filled = 0;
                    self.phase = .chunk_header;
                },
                .chunk_header => {
                    if (!(self.copyInline(
                        input,
                        &consumed,
                        8,
                    ) catch |err| return self.fail(
                        consumed,
                        err,
                    ))) return self.suspension(consumed);
                    const length: usize = std.mem.readInt(u32, self.inline_data[0..4], .big);
                    self.kind = self.validator.start(
                        self.inline_data[4..8],
                        length,
                    ) catch |err| return self.fail(consumed, err);
                    self.validator.validateChunkHeader() catch |err| return self.fail(
                        consumed,
                        err,
                    );
                    const with_payload = std.math.add(
                        usize,
                        self.declared_bytes,
                        length,
                    ) catch return self.fail(consumed, error.EncodedBudgetExceeded);
                    const declared = std.math.add(
                        usize,
                        with_payload,
                        12,
                    ) catch return self.fail(consumed, error.EncodedBudgetExceeded);
                    if (declared > self.options.policy.maximum_encoded_bytes) return self.fail(
                        consumed,
                        error.EncodedBudgetExceeded,
                    );
                    if (self.options.total_bytes) |total| {
                        if (declared > total) return self.fail(consumed, error.InvalidPng);
                    }
                    const budget = self.inflationBudget(
                        declared,
                        self.fixed_raster_work,
                    ) catch |err| return self.fail(consumed, err);
                    self.declared_bytes = declared;
                    if (self.decoder) |*decoder| decoder.limitInflationWork(
                        budget,
                    ) catch |err| return self.fail(consumed, err);
                    self.prepareBacking(length) catch |err| return self.fail(consumed, err);
                    self.payload_length = length;
                    self.payload_remaining = length;
                    self.crc = Crc32.init();
                    self.crc.update(self.inline_data[4..8]);
                    self.inline_filled = 0;
                    self.phase = .payload;
                },
                .payload => {
                    // Closing the IDAT group declares compressed EOF separately from PNG EOF.
                    if (self.kind != .idat and self.decoder != null and !self.raster_closed) {
                        const progress = self.decoder.?.finish();
                        switch (progress.status) {
                            .row => if (self.acceptRow(
                                progress.row.?,
                            )) |row| return .{ .consumed = consumed, .status = .row, .image = row },
                            .done => self.raster_closed = true,
                            .failed => return self.fail(consumed, progress.failure.?),
                            .need_input => return self.fail(consumed, error.InvalidPng),
                            .canceled => unreachable,
                        }
                        continue;
                    }
                    const count = @min(input.len - consumed, self.payload_remaining);
                    const fragment = input[consumed..][0..count];
                    if (self.kind == .idat and !self.raster_done) {
                        const progress = self.decoder.?.step(fragment);
                        self.crc.update(fragment[0..progress.consumed]);
                        self.consume(&consumed, progress.consumed);
                        self.payload_remaining -= progress.consumed;
                        switch (progress.status) {
                            .row => if (self.acceptRow(
                                progress.row.?,
                            )) |row| return .{ .consumed = consumed, .status = .row, .image = row },
                            .done => self.raster_done = true,
                            .failed => return self.fail(consumed, progress.failure.?),
                            .need_input => {
                                if (self.payload_remaining == 0) {
                                    self.phase = .crc;
                                } else return self.suspension(consumed);
                            },
                            .canceled => unreachable,
                        }
                        continue;
                    }
                    const offset = self.payload_length - self.payload_remaining;
                    self.capture(fragment, offset);
                    self.crc.update(fragment);
                    self.consume(&consumed, count);
                    self.payload_remaining -= count;
                    if (self.payload_remaining != 0) return self.suspension(consumed);
                    self.inline_filled = 0;
                    self.phase = .crc;
                },
                .crc => {
                    // IHDR/tRNS capture remains separate from the four-byte stored checksum.
                    if (!self.copyCrc(input, &consumed)) return self.suspension(consumed);
                    if (self.crc.final() != self.stored_crc) return self.fail(
                        consumed,
                        error.InvalidPng,
                    );
                    const captured = self.capturedPayload();
                    self.validator.complete(captured) catch |err| return self.fail(consumed, err);
                    if (self.kind == .ihdr) self.prepareGeometry() catch |err| return self.fail(
                        consumed,
                        err,
                    );
                    self.inline_filled = 0;
                    self.phase = if (self.kind == .iend) .after_end else .chunk_header;
                },
                .after_end => {
                    if (input.len != consumed) return self.fail(consumed, error.InvalidPng);
                    if (!self.eof) return .{ .consumed = consumed, .status = .need_input };
                    if (self.options.total_bytes) |total| {
                        if (self.input_bytes != total) return self.fail(consumed, error.InvalidPng);
                    }
                    _ = self.validator.finish() catch |err| return self.fail(consumed, err);
                    self.phase = if (self.validator.header.?.interlace_method == 0)
                        .done
                    else
                        .delivery;
                },
                .delivery => {
                    const selected = self.region_plan.?;
                    if (self.produced_rows == selected.rectangle.height) {
                        self.phase = .done;
                        continue;
                    }
                    const first = self.produced_rows;
                    const count = selected.requirements.row_samples;
                    const offset = @as(usize, first) * count;
                    @memcpy(
                        self.storage.output_row[0..count],
                        self.storage.reconstruction[offset..][0..count],
                    );
                    self.produced_rows += 1;
                    return .{
                        .consumed = consumed,
                        .status = .row,
                        .image = self.rowEvent(first, true),
                    };
                },
            };
        }

        /// Copies checked declarations observed so far; only done establishes completeness.
        pub fn header(self: *const Self) ?Header {
            return self.validator.header;
        }

        /// Copies admitted geometry and backing requirements without source/decoder borrows. Null
        /// before admission; use workUnits for current data-dependent inflation charges.
        pub fn requirements(self: *const Self) ?Requirements {
            return self.cached_requirements;
        }

        /// Fixed geometry, reserved complete framing and actual generic inflation charges.
        /// Unknown-length framing reserves complete declared chunks before processing payloads.
        pub fn workUnits(self: *const Self) usize {
            return self.fixed_raster_work + self.framingWork() + (if (self.decoder) |decoder|
                decoder.inflationWork()
            else
                0);
        }

        /// Stops input until reset without changing any caller backing or copied row.
        pub fn cancel(self: *Self) void {
            self.phase = .canceled;
        }

        /// Restarts identical options/storage without allocating or clearing reserved backing.
        pub fn reset(self: *Self) void {
            const storage = self.storage;
            const options = self.options;
            self.* = init(storage, options) catch unreachable;
        }

        fn prepareGeometry(self: *Self) Error!void {
            const source_header = self.validator.header.?;
            const report = try planHeader(Sample, source_header, self.options);
            const selected: regions.Plan(
                Sample,
            ) = .{
                .header = source_header,
                .rectangle = self.options.region orelse .{
                    .x = 0,
                    .y = 0,
                    .width = source_header.width,
                    .height = source_header.height,
                },
                .requirements = report.selected,
            };
            if (self.storage.raster.packed_rows.len < report.selected.raster.packed_rows_bytes)
                return error.RowsTooSmall;
            if (self.storage.raster.conversion_row.len < report.selected.raster
                .conversion_row_samples) return error.ConversionRowTooSmall;
            if (self.storage.reconstruction.len < report.selected.reconstruction_samples)
                return error.ReconstructionTooSmall;
            if (self.storage.output_row.len < report.output_row_samples)
                return error.OutputRowTooSmall;
            const fixed = report.selected.row_fixed_work_units - report.selected.encoded_bytes;
            const budget = try self.inflationBudget(self.declared_bytes, fixed);
            if (budget < report.selected.raster.filtered_bytes) return error.WorkBudgetExceeded;
            self.cached_requirements = report;
            self.region_plan = selected;
            self.fixed_raster_work = fixed;
        }

        fn prepareBacking(self: *Self, length: usize) Error!void {
            switch (self.kind) {
                .plte,
                => if (self.validator.header.?.color_type == 3 and self.storage.palette.len <
                    length / 3) return error.PaletteTooSmall,
                .trns,
                => if (self.validator.header.?.color_type == 3 and self.storage.alpha.len < length)
                    return error.AlphaTooSmall,
                .idat => if (self.decoder == null) {
                    const source_header = self.validator.header.?;
                    const indexed = source_header.color_type == 3;
                    const converter: RgbaConverter = .{
                        .palette_index_policy = self.options.policy.palette_index_policy,
                        .bit_depth = source_header.bit_depth,
                        .color_type = source_header.color_type,
                        .channel_count = source_header.channel_count,
                        .bits_per_pixel = source_header.bits_per_pixel,
                        .palette = if (indexed) self.storage.palette[0..self.validator
                            .palette_entries] else &.{},
                        .palette_alpha = if (indexed) self.storage.alpha[0..self.validator
                            .alpha_entries] else &.{},
                        .transparent_gray = self.validator.transparent_gray,
                        .transparent_rgb = self.validator.transparent_rgb,
                    };
                    self.decoder = try raster.Decoder(
                        Sample,
                    ).init(
                        source_header,
                        converter,
                        self.storage.raster,
                        .{
                            .maximum_encoded_bytes = self.options.policy.maximum_encoded_bytes,
                            .maximum_inflate_work_units = try self.inflationBudget(
                                self.declared_bytes,
                                self.fixed_raster_work,
                            ),
                        },
                    );
                },
                else => {},
            }
        }

        fn inflationBudget(self: *const Self, declared: usize, raster_work: usize) Error!usize {
            const framed = self.options.total_bytes orelse @max(declared, self.input_bytes);
            const fixed = std.math.add(
                usize,
                raster_work,
                framed,
            ) catch return error.WorkBudgetExceeded;
            const inflation = if (self.decoder) |decoder| decoder.inflationWork() else 0;
            const total = std.math.add(
                usize,
                fixed,
                inflation,
            ) catch return error.WorkBudgetExceeded;
            try png_format.admitWork(self.options.policy.limits, total);
            return self.options.policy.limits.maximum_work_units - fixed;
        }

        fn framingWork(self: *const Self) usize {
            return self.options.total_bytes orelse @max(self.declared_bytes, self.input_bytes);
        }

        fn capture(self: *Self, fragment: []const u8, offset: usize) void {
            switch (self.kind) {
                .ihdr => @memcpy(self.inline_data[offset..][0..fragment.len], fragment),
                .plte => if (self.validator.header.?.color_type == 3) {
                    const palette_bytes = std.mem.sliceAsBytes(self.storage.palette);
                    @memcpy(palette_bytes[offset..][0..fragment.len], fragment);
                },
                .trns => {
                    const destination = if (self.validator.header.?.color_type == 3) self.storage
                        .alpha else self.inline_data[0..6];
                    @memcpy(destination[offset..][0..fragment.len], fragment);
                },
                else => {},
            }
        }

        fn capturedPayload(self: *const Self) []const u8 {
            return switch (self.kind) {
                .ihdr => self.inline_data[0..13],
                .trns,
                => if (self.validator.header.?.color_type == 3) self.storage.alpha[0..self
                    .payload_length] else self.inline_data[0..self.payload_length],
                else => &.{},
            };
        }

        fn acceptRow(self: *Self, source_row: raster.Decoder(Sample).Row) ?Row {
            const selected = self.region_plan.?;
            if (selected.header.interlace_method != 0) {
                selected.scatter(
                    source_row,
                    self.storage.reconstruction[0..selected.requirements.samples],
                );
                return null;
            }
            const rectangle = selected.rectangle;
            if (source_row.y < rectangle.y or source_row.y - rectangle.y >= rectangle.height)
                return null;
            const first = source_row.y - rectangle.y;
            const begin = @as(usize, rectangle.x) * 4;
            @memcpy(
                self.storage.output_row[0..selected.requirements.row_samples],
                source_row.texels[begin..][0..selected.requirements.row_samples],
            );
            self.produced_rows += 1;
            return self.rowEvent(first, false);
        }

        fn rowEvent(self: *Self, first: u32, metadata_presence_complete: bool) Row {
            const selected = self.region_plan.?;
            return .{
                .row_index = first,
                .image = .{
                    .width = selected.rectangle.width,
                    .height = 1,
                    .source_header = self.validator.header.?,
                    .texels = self.storage.output_row[0..selected.requirements.row_samples],
                },
                .metadata_presence_complete = metadata_presence_complete,
            };
        }

        fn copyInline(self: *Self, input: []const u8, consumed: *usize, length: usize) Error!bool {
            const count = @min(input.len - consumed.*, length - self.inline_filled);
            const after = std.math.add(
                usize,
                self.input_bytes,
                count,
            ) catch return error.EncodedBudgetExceeded;
            if (after > self.options.policy.maximum_encoded_bytes)
                return error.EncodedBudgetExceeded;
            if (self.options.total_bytes) |total| {
                if (after > total) return error.InvalidPng;
            } else {
                _ = try self.inflationBudget(
                    @max(self.declared_bytes, after),
                    self.fixed_raster_work,
                );
            }
            @memcpy(
                self.inline_data[self.inline_filled..][0..count],
                input[consumed.*..][0..count],
            );
            self.inline_filled += count;
            self.consume(consumed, count);
            return self.inline_filled == length;
        }

        // Four CRC bytes stay outside the thirteen IHDR bytes, preserving capture until validator
        // completion. Stored CRC accumulates numerically, so this owner has no self-bound slice.
        fn copyCrc(self: *Self, input: []const u8, consumed: *usize) bool {
            if (self.inline_filled == 0) self.stored_crc = 0;
            while (consumed.* < input.len and self.inline_filled < 4) {
                self.stored_crc = (self.stored_crc << 8) | input[consumed.*];
                self.inline_filled += 1;
                self.consume(consumed, 1);
            }
            return self.inline_filled == 4;
        }

        fn consume(self: *Self, consumed: *usize, count: usize) void {
            consumed.* += count;
            self.input_bytes += count;
        }

        fn suspension(self: *Self, consumed: usize) InternalStep {
            if (self.eof) return self.fail(consumed, error.InvalidPng);
            return .{ .consumed = consumed, .status = .need_input };
        }

        fn fail(self: *Self, consumed: usize, failure: Error) InternalStep {
            self.phase = .failed;
            self.failure = failure;
            return .{ .consumed = consumed, .status = .failed, .failure = failure };
        }
    };
}

const raster_fixtures = png_raster_vectors;

test "PNG suspended input retires fragments and delivers complete byte word crop rows" {
    const fixtures = raster_fixtures;
    const allocator = std.testing.allocator;
    const workspace = try deflate.DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.alloc(u8, raster.history_bytes + 3);
    defer allocator.free(history);
    inline for (.{ u8, u16 }) |Sample| {
        const guard: Sample = if (Sample == u8) 0xa5 else 0xa5a5;
        const pictures = [_]struct {
            source: []const u8,
            expected: []const Sample,
            interlaced: bool,
        }{
            .{
                .source = fixtures.sequential_png,
                .expected = if (Sample == u8) &fixtures.sequential_rgba8 else &fixtures
                    .sequential_rgba16,
                .interlaced = false,
            },
            .{
                .source = fixtures.adam7_png,
                .expected = if (Sample == u8) &fixtures.adam7_rgba8 else &fixtures.adam7_rgba16,
                .interlaced = true,
            },
        };
        for (pictures) |picture| {
            for ([_]?usize{ null, picture.source.len }) |total| {
                for ([_]usize{ 1, 2, 5, 31, 4096 }) |fragment_size| {
                    var packed_rows: [11]u8 = @splat(0xa5);
                    var conversion: [15]Sample = @splat(guard);
                    var reconstruction: [19]Sample = @splat(guard);
                    var band: [11]Sample = @splat(guard);
                    var palette: [2][3]u8 = @splat(.{ 0xa5, 0xa5, 0xa5 });
                    var alpha: [2]u8 = @splat(0xa5);
                    @memset(history, 0xa5);
                    var decoder = try StreamDecoder(
                        Sample,
                    ).init(
                        .{
                            .raster = .{
                                .workspace = workspace,
                                .history = history,
                                .packed_rows = &packed_rows,
                                .conversion_row = &conversion,
                            },
                            .palette = &palette,
                            .alpha = &alpha,
                            .reconstruction = &reconstruction,
                            .output_row = &band,
                        },
                        .{
                            .region = .{ .x = 1, .y = 1, .width = 2, .height = 2 },
                            .total_bytes = total,
                            .policy = .{
                                .limits = .{
                                    .maximum_scratch_bytes = 0,
                                    .maximum_pixels = 4,
                                    .maximum_output_bytes = 16 * @sizeOf(Sample),
                                },
                            },
                        },
                    );
                    var produced: usize = 0;
                    var position: usize = 0;
                    while (position < picture.source.len) {
                        const end = @min(picture.source.len, position + fragment_size);
                        const fragment = try allocator.dupe(u8, picture.source[position..end]);
                        var offset: usize = 0;
                        while (true) {
                            const progress = decoder.step(.{ .bytes = fragment[offset..] });
                            offset += progress.consumed;
                            if (progress.event == .failed) return progress.event.failed;
                            if (progress.event == .row) {
                                const row = progress.event.row;
                                try std.testing.expect(!picture.interlaced);
                                try std.testing.expectEqual(produced, row.row_index);
                                try std.testing.expect(!row.metadata_presence_complete);
                                try std.testing.expect(
                                    !row.image.source_header.metadata_presence.text,
                                );
                                const begin = ((produced + 1) * 3 + 1) * 4;
                                try std.testing.expectEqualSlices(
                                    Sample,
                                    picture.expected[begin..][0..8],
                                    row.image.texels,
                                );
                                produced += 1;
                            }
                            if (progress.event != .row) {
                                try std.testing.expect(progress.event == .need_input);
                                break;
                            }
                        }
                        try std.testing.expectEqual(fragment.len, offset);
                        @memset(fragment, 0xe7);
                        allocator.free(fragment);
                        position = end;
                    }
                    while (true) {
                        const progress = decoder.step(.{ .final = true });
                        if (progress.event == .failed) return progress.event.failed;
                        try std.testing.expectEqual(0, progress.consumed);
                        if (progress.event == .row) {
                            const row = progress.event.row;
                            try std.testing.expect(picture.interlaced);
                            try std.testing.expectEqual(produced, row.row_index);
                            try std.testing.expect(row.metadata_presence_complete);
                            try std.testing.expect(row.image.source_header.metadata_presence.text);
                            const begin = ((produced + 1) * 3 + 1) * 4;
                            try std.testing.expectEqualSlices(
                                Sample,
                                picture.expected[begin..][0..8],
                                row.image.texels,
                            );
                            produced += 1;
                        }
                        if (progress.event != .row) {
                            try std.testing.expect(progress.event == .complete);
                            break;
                        }
                    }
                    try std.testing.expectEqual(2, produced);
                    try std.testing.expectEqual(picture.source.len, decoder.input_bytes);
                    const copied_requirements = decoder.requirements().?;
                    try std.testing.expectEqual(16, copied_requirements.selected.samples);
                    try std.testing.expect(decoder.header().?.metadata_presence.text);
                    for (band[8..]) |value| try std.testing.expectEqual(guard, value);
                    for (conversion[12..]) |value| try std.testing.expectEqual(guard, value);
                    for (packed_rows[8..]) |value| try std.testing.expectEqual(0xa5, value);
                    for (
                        reconstruction[if (picture.interlaced) @as(usize, 16) else 0..],
                    ) |value| try std.testing.expectEqual(guard, value);
                    for (
                        history[raster.history_bytes..],
                    ) |value| try std.testing.expectEqual(0xa5, value);
                    for (palette) |rgb| try std.testing.expectEqual([3]u8{ 0xa5, 0xa5, 0xa5 }, rgb);
                    for (alpha) |value| try std.testing.expectEqual(0xa5, value);
                    decoder.cancel();
                    try std.testing.expect(
                        decoder.step(.{ .bytes = picture.source }).event == .canceled,
                    );
                    decoder.reset();
                    try std.testing.expectEqual(0, decoder.input_bytes);
                    try std.testing.expectEqual(null, decoder.requirements());
                    try std.testing.expectEqual(16, copied_requirements.selected.samples);
                    try std.testing.expect(decoder.step(.{ .final = true }).event == .failed);
                    try std.testing.expectEqual(error.InvalidPng, decoder.failure.?);
                    try std.testing.expectEqual(
                        0,
                        decoder.step(.{ .bytes = picture.source }).consumed,
                    );
                }
            }
        }
    }
}

test "PNG suspended indexed tables use actual backing and preserve current bands on late failure" {
    const fixtures = raster_fixtures;
    const allocator = std.testing.allocator;
    const workspace = try deflate.DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.alloc(u8, raster.history_bytes);
    defer allocator.free(history);
    inline for (.{ u8, u16 }) |Sample| {
        const guard: Sample = if (Sample == u8) 0xa5 else 0xa5a5;
        var packed_rows: [8]u8 = undefined;
        var conversion: [12]Sample = undefined;
        var palette: [3][3]u8 = @splat(.{ 0xa5, 0xa5, 0xa5 });
        var alpha: [2]u8 = @splat(0xa5);
        var band: [7]Sample = @splat(guard);
        const storage: StreamStorage(
            Sample,
        ) = .{
            .raster = .{
                .workspace = workspace,
                .history = history,
                .packed_rows = &packed_rows,
                .conversion_row = &conversion,
            },
            .palette = &palette,
            .alpha = &alpha,
            .output_row = &band,
        };
        var decoder = try StreamDecoder(
            Sample,
        ).init(
            storage,
            .{
                .policy = .{ .palette_index_policy = .reject },
                .region = .{ .x = 1, .y = 1, .width = 1, .height = 1 },
            },
        );
        var rows_seen: usize = 0;
        for (fixtures.palette_png) |byte| {
            const fragment = try allocator.dupe(u8, &.{byte});
            var offset: usize = 0;
            while (true) {
                const progress = decoder.step(.{ .bytes = fragment[offset..] });
                offset += progress.consumed;
                if (progress.event == .failed) return progress.event.failed;
                if (progress.event == .row) {
                    const image = progress.event.row;
                    const expected: [4]Sample = if (Sample == u8) .{
                        4, 5, 6, 255,
                    } else .{ 1028, 1285, 1542, 65535 };
                    try std.testing.expectEqualSlices(Sample, &expected, image.image.texels);
                    rows_seen += 1;
                }
                if (progress.event != .row) break;
            }
            try std.testing.expectEqual(1, offset);
            @memset(fragment, 0xe7);
            allocator.free(fragment);
        }
        try std.testing.expect(decoder.step(.{ .final = true }).event == .complete);
        try std.testing.expectEqual(1, rows_seen);
        try std.testing.expectEqual([3]u8{ 0xa5, 0xa5, 0xa5 }, palette[2]);
        try std.testing.expectEqual(0xa5, alpha[1]);
        for (band[4..]) |value| try std.testing.expectEqual(guard, value);
        const variants = [_]struct {
            value: StreamStorage(Sample),
            expected: Error,
        }{
            .{
                .value = .{
                    .raster = storage.raster,
                    .palette = palette[0..1],
                    .alpha = &alpha,
                    .output_row = &band,
                },
                .expected = error.PaletteTooSmall,
            },
            .{
                .value = .{
                    .raster = storage.raster,
                    .palette = &palette,
                    .alpha = &.{},
                    .output_row = &band,
                },
                .expected = error.AlphaTooSmall,
            },
            .{
                .value = .{
                    .raster = storage.raster,
                    .palette = &palette,
                    .alpha = &alpha,
                    .output_row = band[0..3],
                },
                .expected = error.OutputRowTooSmall,
            },
        };
        for (variants) |variant| {
            @memset(&band, guard);
            var short = try StreamDecoder(
                Sample,
            ).init(
                variant.value,
                .{
                    .policy = .{ .palette_index_policy = .reject },
                    .region = .{ .x = 1, .y = 1, .width = 1, .height = 1 },
                },
            );
            try std.testing.expectError(
                variant.expected,
                feedForTest(Sample, &short, fixtures.palette_png),
            );
            try std.testing.expect(short.step(.{ .final = true }).event == .failed);
            try std.testing.expectEqual(0, short.step(.{ .bytes = fixtures.palette_png }).consumed);
            for (band) |value| try std.testing.expectEqual(guard, value);
        }
        @memset(&band, guard);
        var invalid = try StreamDecoder(
            Sample,
        ).init(
            storage,
            .{
                .policy = .{ .palette_index_policy = .reject },
                .region = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            },
        );
        var failed = false;
        for (fixtures.invalid_palette_png) |byte| {
            const previous = band;
            const progress = invalid.step(.{ .bytes = &.{byte} });
            if (progress.event == .failed) {
                const failure = progress.event.failed;
                try std.testing.expectEqual(error.InvalidPng, failure);
                try std.testing.expectEqualSlices(Sample, &previous, &band);
                failed = true;
                break;
            }
            if (progress.event == .row) @memset(&band, guard);
        }
        try std.testing.expect(failed);
        try std.testing.expectEqual(1, invalid.produced_rows);
        for (band) |value| try std.testing.expectEqual(guard, value);
    }
}

test "PNG suspended finish split reset framing and exact work policies remain bounded" {
    const fixtures = raster_fixtures;
    const allocator = std.testing.allocator;
    const workspace = try deflate.DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.alloc(u8, raster.history_bytes);
    defer allocator.free(history);
    var packed_rows: [8]u8 = undefined;
    var conversion: [12]u8 = undefined;
    var reconstruction: [4]u8 = undefined;
    var band: [7]u8 = @splat(0xa5);
    const storage: StreamStorage(
        u8,
    ) = .{
        .raster = .{
            .workspace = workspace,
            .history = history,
            .packed_rows = &packed_rows,
            .conversion_row = &conversion,
        },
        .reconstruction = &reconstruction,
        .output_row = &band,
    };
    for ([_][]const u8{ fixtures.sequential_png, fixtures.adam7_png }) |source| {
        var options: StreamDecodeOptions = .{
            .region = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        };
        var whole = try StreamDecoder(u8).init(storage, options);
        _ = try feedForTest(u8, &whole, source);
        while (whole.step(.{ .final = true }).event == .row) {}
        try std.testing.expect(whole.step(.{ .final = true }).event == .complete);
        const total_work = whole.workUnits();
        for ([_]?usize{ null, source.len }) |total| {
            options.total_bytes = total;
            options.policy.limits.maximum_work_units = total_work;
            for (0..source.len + 1) |split| {
                var decoder = try StreamDecoder(u8).init(storage, options);
                _ = try feedForTest(u8, &decoder, source[0..split]);
                _ = try feedForTest(u8, &decoder, source[split..]);
                while (decoder.step(.{ .final = true }).event == .row) {}
                try std.testing.expect(decoder.step(.{ .final = true }).event == .complete);
                try std.testing.expectEqual(1, decoder.produced_rows);
                try std.testing.expectEqual(total_work, decoder.workUnits());
                try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 255 }, band[0..4]);
                decoder.reset();
                _ = try feedForTest(u8, &decoder, source[0..split]);
                decoder.cancel();
                try std.testing.expect(decoder.step(.{ .bytes = source }).event == .canceled);
                try std.testing.expectEqual(0, decoder.step(.{ .bytes = source }).consumed);
                decoder.reset();
                _ = try feedForTest(u8, &decoder, source);
                while (decoder.step(.{ .final = true }).event == .row) {}
                try std.testing.expect(decoder.step(.{ .final = true }).event == .complete);
                try std.testing.expectEqual(total_work, decoder.workUnits());
            }
            options.policy.limits.maximum_work_units = total_work - 1;
            var short = try StreamDecoder(u8).init(storage, options);
            _ = feedForTest(u8, &short, source) catch |err| blk: {
                try std.testing.expectEqual(error.WorkBudgetExceeded, err);
                break :blk 0;
            };
            while (short.step(.{ .final = true }).event == .row) {}
            try std.testing.expect(short.step(.{ .final = true }).event == .failed);
            try std.testing.expectEqual(error.WorkBudgetExceeded, short.failure.?);
            options.policy.limits.maximum_work_units = total_work;
            for (0..source.len) |prefix| {
                var truncated = try StreamDecoder(u8).init(storage, options);
                _ = try feedForTest(u8, &truncated, source[0..prefix]);
                while (truncated.step(.{ .final = true }).event == .row) {}
                try std.testing.expect(truncated.step(.{ .final = true }).event == .failed);
                try std.testing.expectEqual(error.InvalidPng, truncated.failure.?);
                try std.testing.expectEqual(0, truncated.step(.{ .bytes = source }).consumed);
            }
        }
        options.total_bytes = null;
        options.policy.maximum_encoded_bytes = source.len - 1;
        var encoded = try StreamDecoder(u8).init(storage, options);
        try std.testing.expectError(error.EncodedBudgetExceeded, feedForTest(u8, &encoded, source));
        options.total_bytes = source.len;
        try std.testing.expectError(
            error.EncodedBudgetExceeded,
            StreamDecoder(u8).init(storage, options),
        );
        options.policy.maximum_encoded_bytes = source.len;
        options.total_bytes = null;
        options.policy.limits.maximum_records = 5;
        var records = try StreamDecoder(u8).init(storage, options);
        try std.testing.expectError(error.MetadataLimitExceeded, feedForTest(u8, &records, source));
        options.policy.limits.maximum_records = 6;
        options.policy.limits.maximum_metadata_bytes = 9;
        var metadata_limit = try StreamDecoder(u8).init(storage, options);
        try std.testing.expectError(
            error.MetadataLimitExceeded,
            feedForTest(u8, &metadata_limit, source),
        );
        options.policy.limits.maximum_metadata_bytes = 10;
        var trailing = try StreamDecoder(u8).init(storage, options);
        _ = try feedForTest(u8, &trailing, source);
        const previous = band;
        try std.testing.expect(trailing.step(.{ .bytes = &.{0xe7} }).event == .failed);
        try std.testing.expectEqual(error.InvalidPng, trailing.failure.?);
        try std.testing.expectEqualSlices(u8, &previous, &band);
    }
}

fn feedForTest(comptime Sample: type, decoder: *StreamDecoder(Sample), input: []const u8) !usize {
    var consumed: usize = 0;
    var rows_seen: usize = 0;
    while (true) {
        const progress = decoder.step(.{ .bytes = input[consumed..] });
        consumed += progress.consumed;
        if (progress.event == .failed) return progress.event.failed;
        if (progress.event == .row) rows_seen += 1;
        if (progress.event != .row) {
            try std.testing.expect(progress.event == .need_input);
            try std.testing.expectEqual(input.len, consumed);
            return rows_seen;
        }
    }
}

const palette_fixtures = png_palette_vectors;

test "PNG palette recovery survives retired fragments and native byte word stream reset" {
    const fixtures = palette_fixtures;
    const allocator = std.testing.allocator;
    const workspace = try deflate.DecoderWorkspace.create(allocator);
    defer workspace.destroy(allocator);
    const history = try allocator.alloc(u8, raster.history_bytes);
    defer allocator.free(history);
    inline for (.{ u8, u16 }) |Sample| {
        const guard: Sample = if (Sample == u8) 0xa5 else 0xa5a5;
        const expected: []const Sample = if (Sample == u8) &fixtures.rgba8 else &fixtures.rgba16;
        var packed_rows: [39]u8 = @splat(0xa5);
        var conversion: [71]Sample = @splat(guard);
        var reconstruction: [207]Sample = @splat(guard);
        var band: [71]Sample = @splat(guard);
        var palette: [2][3]u8 = @splat(.{ 0xa5, 0xa5, 0xa5 });
        var alpha: [2]u8 = @splat(0xa5);
        for ([_][]const u8{ fixtures.sequential_1, fixtures.adam7_8 }) |wire| {
            var owner = try StreamDecoder(
                Sample,
            ).init(
                .{
                    .raster = .{
                        .workspace = workspace,
                        .history = history,
                        .packed_rows = &packed_rows,
                        .conversion_row = &conversion,
                    },
                    .palette = &palette,
                    .alpha = &alpha,
                    .reconstruction = &reconstruction,
                    .output_row = &band,
                },
                .{ .policy = .{ .palette_index_policy = .opaque_black } },
            );
            for (0..2) |_| {
                var position: usize = 0;
                var rows: usize = 0;
                while (position < wire.len) {
                    var fragment = [1]u8{wire[position]};
                    while (true) {
                        const progress = owner.step(.{ .bytes = fragment[0..] });
                        if (progress.event == .failed) return progress.event.failed;
                        if (progress.event == .row) {
                            const row = progress.event.row;
                            try std.testing.expectEqual(rows, row.row_index);
                            try std.testing.expectEqualSlices(
                                Sample,
                                expected[rows * 68 ..][0..68],
                                row.image.texels,
                            );
                            rows += 1;
                        }
                        position += progress.consumed;
                        if (progress.consumed != 0) fragment[0] = 0xe7;
                        if (progress.event != .row) {
                            try std.testing.expect(progress.event == .need_input);
                            try std.testing.expectEqual(1, progress.consumed);
                            break;
                        }
                        if (progress.consumed != 0) break;
                    }
                }
                while (true) {
                    const progress = owner.step(.{ .final = true });
                    if (progress.event == .failed) return progress.event.failed;
                    if (progress.event == .row) {
                        const row = progress.event.row;
                        try std.testing.expectEqual(rows, row.row_index);
                        try std.testing.expectEqualSlices(
                            Sample,
                            expected[rows * 68 ..][0..68],
                            row.image.texels,
                        );
                        rows += 1;
                    }
                    if (progress.event != .row) {
                        try std.testing.expect(progress.event == .complete);
                        break;
                    }
                }
                try std.testing.expectEqual(3, rows);
                for (band[68..]) |value| try std.testing.expectEqual(guard, value);
                for (reconstruction[204..]) |value| try std.testing.expectEqual(guard, value);
                try std.testing.expectEqual([3]u8{ 0xa5, 0xa5, 0xa5 }, palette[1]);
                try std.testing.expectEqual(0xa5, alpha[1]);
                owner.reset();
            }
        }
    }
}

test StreamDecoder {
    const allocator = std.testing.allocator;
    const texels = [_]u8{ 0, 127, 255, 128, 7, 19, 29, 255 };
    inline for (.{ u8, u16 }) |Sample| {
        for ([_]png.Interlace{ .none, .adam7 }) |interlace| {
            const encoded = try png.encode.alloc(
                allocator,
                try png.ImageInput.rgba8(&texels, 1, 2),
                .{ .interlace = interlace, .compression = .{ .level = 0 } },
            );
            defer allocator.free(encoded);
            const header = (try png.Source.open(encoded, .{})).header();
            const required = try png.decode.StreamDecoder(Sample).plan(header, .{});
            var workspace = try png.decode.Workspace(Sample).initCapacity(allocator, header);
            defer workspace.deinit(allocator);
            const reconstruction = try allocator.alloc(
                Sample,
                required.selected.reconstruction_samples,
            );
            defer allocator.free(reconstruction);
            var band: [5]Sample = @splat(0xa5);
            var decoder = try png.decode.StreamDecoder(
                Sample,
            ).init(
                .{
                    .raster = workspace.storage,
                    .output_row = &band,
                    .reconstruction = reconstruction,
                },
                .{},
            );
            var consumed: usize = 0;
            var produced: usize = 0;
            var final = true;
            while (true) {
                const progress = decoder.step(.{ .bytes = encoded[consumed..], .final = final });
                final = false;
                @memset(encoded[consumed..][0..progress.consumed], 0xe5);
                consumed += progress.consumed;
                switch (progress.event) {
                    .row => |row| {
                        try std.testing.expectEqual(produced, row.row_index);
                        try std.testing.expectEqual(
                            interlace == .adam7,
                            row.metadata_presence_complete,
                        );
                        for (
                            row.image.texels,
                            texels[produced * 4 ..][0..4],
                        ) |actual, expected| try std.testing.expectEqual(
                            @as(Sample, expected) * (if (Sample == u8) 1 else 257),
                            actual,
                        );
                        produced += 1;
                    },
                    .complete => break,
                    .failed => |failure| return failure,
                    else => return error.UnexpectedStreamEvent,
                }
            }
            try std.testing.expectEqual(encoded.len, consumed);
            try std.testing.expectEqual(2, produced);
            try std.testing.expectEqual(0xa5, band[4]);
            try std.testing.expect(decoder.step(.{}).event == .complete);
        }
    }
}
