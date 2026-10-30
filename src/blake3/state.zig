//! Streaming tree admission, snapshots, mode initialization and parallel orchestration.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const compression = @import("compression.zig");
const parallel = @import("parallel.zig");
const fixtures = @import("fixtures.zig");
const ChunkState = @import("chunk.zig").ChunkState;
const Output = compression.Output;
const ChainingValue = compression.Cv;
const block_bytes = compression.block_bytes;
const chunk_bytes = compression.chunk_bytes;
const mode_flags = compression.flags;
const Worker = parallel.Worker;
const ParallelOptions = parallel.ParallelOptions;
const vector_key = fixtures.key;
const vector_context = fixtures.context;
const official_vectors = fixtures.vectors;

// A u64 byte count admits at most 2^54 chunks. One extra child defers root compression until more
// input proves that the subtree is interior.
const max_depth = 54;

/// Number of bytes in the default digest.
pub const digest_length = 32;

/// Number of bytes required by keyed hashing.
pub const key_length = 32;

/// Full default digest, with no framing or domain prefix supplied by this library.
pub const Digest = [digest_length]u8;

/// Algorithm-supported input/output range overflow, diagnosed before mutation.
pub const Error = error{SizeOverflow};

/// Parallel hashing also propagates provider cancellation after acquiring every borrowed worker.
/// Reset the hasher before reuse after `Canceled`.
pub const ParallelError = Error || std.Io.Cancelable;

/// Hashing state selected for the compile-time CPU target; construct it at its final address. For
/// one buffer, use [hash](#wingman.blake3.state.State.hash). For a stream, call
/// [reset](#wingman.blake3.state.State.reset), [update](#wingman.blake3.state.State.update) and
/// [final](#wingman.blake3.state.State.final). Start keyed hashing with
/// [resetKeyed](#wingman.blake3.state.State.resetKeyed), or key derivation with
/// [resetDerive](#wingman.blake3.state.State.resetDerive).
/// [finalizeSeek](#wingman.blake3.state.State.finalizeSeek) copies extended output, and
/// [updateParallel](#wingman.blake3.state.State.updateParallel) uses supplied workers.
/// [clear](#wingman.blake3.state.State.clear) erases retained state. All methods allocate nothing
/// and retain no input; `ScalarHasher` provides the same methods. The `update`, `resetKeyed` and
/// `finalizeSeek` pages include executable examples.
pub const Hasher = State(compression.preferred);

/// Portable scalar state with the same methods and ownership contract as `Hasher`. Use it when a
/// scalar implementation is required independently of the selected CPU features.
pub const ScalarHasher = State(.scalar);

fn State(comptime kernel: compression.Kernel) type {
    return struct {
        const Self = @This();
        const batch_capacity = if (kernel == .scalar) 2 else @max(2, compression.max_lanes * 8);

        key: ChainingValue,
        chunk: ChunkState,
        total_bytes: u64,
        mode: u32,
        stack_len: u8,
        stack: [max_depth + 1]ChainingValue,
        batch: [batch_capacity]ChainingValue,
        messages: [if (kernel == .scalar) 0 else 16 * compression.max_lanes]u32 align(64),

        /// Starts unkeyed hashing directly in supplied, possibly uninitialized storage.
        pub fn reset(self: *Self) void {
            self.resetMode(compression.iv, 0);
        }

        /// Starts keyed hashing with an exact 32-byte key, copied into retained state.
        ///
        /// The doctest borrows state exclusively and clears it on every return. The copied digest
        /// survives clearing; the caller owns the original key and its lifetime. Reset the cleared
        /// state before reuse.
        pub fn resetKeyed(self: *Self, key: [key_length]u8) void {
            self.resetMode(keyWords(key), mode_flags.keyed);
        }

        test resetKeyed {
            const allocator = testing.allocator;
            const state = try allocator.create(Self);
            defer allocator.destroy(state);

            const test_key: [key_length]u8 = @splat(0x42);
            const digest = blk: {
                state.resetKeyed(test_key);
                defer state.clear();
                try state.update("authenticated bytes");
                break :blk state.final();
            };

            try testing.expect(std.mem.allEqual(u8, std.mem.asBytes(state), 0));
            const digest_hex = std.fmt.bytesToHex(digest, .lower);
            try testing.expectEqualStrings(
                "e4314d8fa82d5b45b2704d3a8b8c7e50d704213b79cccf42afcaf5ca685c330e",
                &digest_hex,
            );
        }

        /// Derives a context key, then starts a stream for the key material. Choose a fixed,
        /// globally unique application/purpose string for `context`. Append the material with
        /// `update`, then read the result with `final` or `finalizeSeek`. Context is consumed
        /// during this call and never retained.
        pub fn resetDerive(self: *Self, context: []const u8) Error!void {
            self.resetMode(compression.iv, mode_flags.derive_context);
            try self.update(context);
            self.resetMode(keyWords(self.final()), mode_flags.derive_material);
        }

        /// Consumes exact bytes; overflow leaves all previously accepted state unchanged.
        pub fn update(self: *Self, input: []const u8) Error!void {
            const input_byte_count = std.math.cast(u64, input.len) orelse return error.SizeOverflow;
            const new_total_bytes = std.math.add(u64, self.total_bytes, input_byte_count) catch {
                return error.SizeOverflow;
            };

            var bytes = input;
            while (bytes.len != 0) {
                if (self.chunk.length() == chunk_bytes) {
                    self.push(self.chunk.output(self.mode).chaining(kernel), self.chunk.counter);
                    self.chunk.reset(self.key, self.chunk.counter + 1);
                }

                const can_batch = kernel != .scalar and self.chunk.length() == 0;
                if (can_batch and bytes.len >= 2 * chunk_bytes) {
                    const available_chunks = bytes.len / chunk_bytes;
                    const complete_subtree_chunks = std.math.floorPowerOfTwo(
                        usize,
                        available_chunks,
                    );
                    var batch_chunks: usize = @min(batch_capacity, complete_subtree_chunks);
                    while (self.chunk.counter & (batch_chunks - 1) != 0) batch_chunks /= 2;
                    if (batch_chunks >= 2) {
                        const batch_bytes = batch_chunks * chunk_bytes;
                        self.processBatch(bytes.ptr, batch_chunks);
                        self.chunk.counter += batch_chunks;
                        bytes = bytes[batch_bytes..];
                        continue;
                    }
                }

                // Prior roots are now known to be interior because new chunk bytes exist.
                if (self.chunk.length() == 0) self.mergeStack(self.chunk.counter);
                const take = @min(bytes.len, chunk_bytes - self.chunk.length());
                self.chunk.update(kernel, bytes[0..take], self.mode);
                bytes = bytes[take..];
            }

            self.total_bytes = new_total_bytes;
        }

        test update {
            const allocator = testing.allocator;
            const digest = blk: {
                const state = try allocator.create(Self);
                defer allocator.destroy(state);
                state.reset();
                try state.update("hello ");
                try state.update("world");
                break :blk state.final();
            };

            // The copied digest remains valid after the state has been released.
            const digest_hex = std.fmt.bytesToHex(digest, .lower);
            try testing.expectEqualStrings(
                "d74981efa70a0c880b8d8c1985d075dbcbf679b99a5f9914e5aaf96b831a9e24",
                &digest_hex,
            );
        }

        /// Appends bytes using `io` and caller-owned worker scratch. Small/unaligned spans retain
        /// ordinary update behavior. Workers, state and input must be disjoint and remain stable
        /// until return. Each wave submits at most `workers.len - 1` jobs; the caller computes one
        /// partition. The provider may execute jobs inline. All accepted jobs finish before return,
        /// including cancellation, and no borrowed input pointers remain in the workers.
        ///
        /// Length overflow refuses before mutation or scheduling. `Canceled` may leave a partial
        /// update; reset before reuse. The provider owns scheduling resources and allocation
        /// policy; this operation allocates nothing itself.
        pub fn updateParallel(
            self: *Self,
            io: std.Io,
            input: []const u8,
            workers: []Worker,
            options: ParallelOptions,
        ) ParallelError!void {
            const input_byte_count = std.math.cast(u64, input.len) orelse return error.SizeOverflow;
            const new_total_bytes = std.math.add(u64, self.total_bytes, input_byte_count) catch {
                return error.SizeOverflow;
            };
            if (workers.len < 2 or input.len < options.minimum_bytes) return self.update(input);

            var bytes = input;

            // Complete a partial chunk; full pending chunks are pushed only once new input proves
            // they are not the final chunk.
            if (self.chunk.length() != 0 and bytes.len != 0) {
                const take = @min(bytes.len, chunk_bytes - self.chunk.length());
                try self.update(bytes[0..take]);
                bytes = bytes[take..];
                if (bytes.len != 0 and self.chunk.length() == chunk_bytes) {
                    self.push(self.chunk.output(self.mode).chaining(kernel), self.chunk.counter);
                    self.chunk.reset(self.key, self.chunk.counter + 1);
                }
            }

            while (bytes.len >= 4 * chunk_bytes) {
                var chunks = std.math.floorPowerOfTwo(usize, bytes.len / chunk_bytes);
                while (self.chunk.counter & (chunks - 1) != 0) chunks /= 2;
                const whole_job_chunks = options.minimum_job_bytes / chunk_bytes;
                const needs_partial_chunk = options.minimum_job_bytes % chunk_bytes != 0;
                const rounded_job_chunks = whole_job_chunks + @intFromBool(needs_partial_chunk);
                const minimum_chunks = @max(2, rounded_job_chunks);
                const participants = std.math.floorPowerOfTwo(
                    usize,
                    @min(workers.len, chunks / minimum_chunks),
                );
                if (participants < 2) {
                    // Advance past the alignment boundary without scheduling tiny jobs. The next
                    // iteration can admit a larger tree.
                    const take = chunks * chunk_bytes;
                    try self.update(bytes[0..take]);
                    bytes = bytes[take..];
                    if (bytes.len != 0 and self.chunk.length() == chunk_bytes) {
                        self.push(
                            self.chunk.output(self.mode).chaining(kernel),
                            self.chunk.counter,
                        );
                        self.chunk.reset(self.key, self.chunk.counter + 1);
                    }
                    continue;
                }

                const job_chunks = chunks / participants;
                const job_bytes = job_chunks * chunk_bytes;
                var group: std.Io.Group = .init;
                defer {
                    group.cancel(io);
                    for (workers[0..participants]) |*worker| worker.input = &.{};
                }
                for (workers[0..participants], 0..) |*worker, i| {
                    worker.key = self.key;
                    worker.mode = self.mode;
                    const input_offset = i * job_bytes;
                    const chunk_offset = i * job_chunks;
                    worker.input = bytes[input_offset..][0..job_bytes];
                    worker.counter = self.chunk.counter + chunk_offset;
                    if (i != 0) group.async(
                        io,
                        if (kernel == .scalar) parallel.runScalar else parallel.runNative,
                        .{worker},
                    );
                }
                parallel.run(&workers[0], kernel);
                try group.await(io);

                // Completion order is irrelevant: reduce subtrees in their original input order.
                for (workers[0..participants]) |*worker| {
                    self.push(worker.result[0], worker.counter);
                    self.push(worker.result[1], worker.counter + job_chunks / 2);
                }
                self.chunk.counter += chunks;
                bytes = bytes[chunks * chunk_bytes ..];
            }

            try self.update(bytes);
            self.total_bytes = new_total_bytes;
        }

        test updateParallel {
            if (builtin.single_threaded) return error.SkipZigTest;
            const allocator = testing.allocator;
            var provider = std.Io.Threaded.init(allocator, .{ .async_limit = .limited(3) });
            defer provider.deinit();
            const bytes = try allocator.alloc(u8, 262144);
            defer allocator.free(bytes);
            for (bytes, 0..) |*byte, i| byte.* = @truncate(i % 251);
            const workers = try allocator.alloc(Worker, 4);
            defer allocator.free(workers);
            const state = try allocator.create(Self);
            defer allocator.destroy(state);
            state.reset();
            try state.updateParallel(provider.io(), bytes, workers, .{});
            var expected: Digest = undefined;
            std.crypto.hash.Blake3.hash(bytes, &expected, .{});
            try testing.expectEqual(expected, state.final());
            for (workers) |worker| try testing.expectEqual(@as(usize, 0), worker.input.len);
        }

        /// Returns a full 32-byte snapshot without modifying state or consuming input.
        pub fn final(self: *const Self) Digest {
            return self.rootOutput().rootDigest(kernel);
        }

        /// Copies `out.len` bytes of the current stream's extended output, starting at byte
        /// `offset`. Offset zero begins with the ordinary 32-byte digest. This is a snapshot;
        /// repeated calls agree and later updates remain possible. Range overflow leaves output
        /// unchanged. Keep output disjoint from the state.
        ///
        /// Derive a selected output range from caller-supplied key material. Context separates
        /// purposes: choose a fixed globally unique application/purpose string and keep it stable.
        /// The doctest consumes context and material synchronously, writes caller-owned output, and
        /// clears its exclusive state even on error. Keep all input, output and state spans
        /// disjoint; reset the cleared state before reuse.
        pub fn finalizeSeek(self: *const Self, offset: u64, out: []u8) Error!void {
            const output_byte_count = std.math.cast(u64, out.len) orelse return error.SizeOverflow;
            _ = std.math.add(u64, offset, output_byte_count) catch return error.SizeOverflow;
            if (out.len != 0) self.rootOutput().writeRootBytes(kernel, offset, out);
        }

        test finalizeSeek {
            const allocator = testing.allocator;
            const state = try allocator.create(Self);
            defer allocator.destroy(state);

            var output: [32]u8 = undefined;
            {
                defer state.clear();
                try state.resetDerive("zig-wingman doctest derived output");
                try state.update("key material");
                try state.finalizeSeek(64, &output);
            }

            try testing.expect(std.mem.allEqual(u8, std.mem.asBytes(state), 0));
            const output_hex = std.fmt.bytesToHex(output, .lower);
            try testing.expectEqualStrings(
                "66771db1857c89511054b7d527c8289b8bc7eee8dac37b37183d958626574965",
                &output_hex,
            );
        }

        /// Resets to unkeyed mode, hashes all of `bytes` and returns a 32-byte digest. Previous
        /// input and keyed/derivation mode are replaced. The digest is a copy that outlives both
        /// input and state; further `update` calls extend this newly hashed stream.
        pub fn hash(self: *Self, bytes: []const u8) Error!Digest {
            self.reset();
            if (bytes.len <= chunk_bytes) {
                self.total_bytes = @intCast(bytes.len);
                return self.chunk.hashWhole(kernel, bytes);
            }

            try self.update(bytes);
            return self.final();
        }

        /// Explicitly erases all retained state, including key-derived chaining values. Reset
        /// before reuse. Volatile stores prevent ordinary dead-store elimination.
        pub fn clear(self: *Self) void {
            const bytes: [*]volatile u8 = @ptrCast(self);
            for (bytes[0..@sizeOf(Self)]) |*byte| byte.* = 0;
        }

        fn resetMode(self: *Self, key: ChainingValue, mode: u32) void {
            self.key = key;
            self.mode = mode;
            self.stack_len = 0;
            self.total_bytes = 0;
            self.chunk.reset(key, 0);
        }

        fn rootOutput(self: *const Self) Output {
            var count: usize = self.stack_len;
            var output: Output = blk: {
                if (self.chunk.length() != 0 or count < 2) break :blk self.chunk.output(self.mode);

                // A complete batched subtree leaves two children on the stack, with no chunk tail.
                count -= 2;
                break :blk Output.parent(
                    self.key,
                    self.stack[count],
                    self.stack[count + 1],
                    self.mode,
                );
            };
            while (count != 0) {
                count -= 1;
                const right = output.chaining(kernel);
                output = Output.parent(self.key, self.stack[count], right, self.mode);
            }
            return output;
        }

        fn mergeStack(self: *Self, chunks: u64) void {
            const target: usize = @popCount(chunks);
            while (self.stack_len > target) {
                const left = self.stack_len - 2;
                const parent = Output.parent(
                    self.key,
                    self.stack[left],
                    self.stack[left + 1],
                    self.mode,
                );
                self.stack[left] = parent.chaining(kernel);
                self.stack_len -= 1;
            }
        }

        fn push(self: *Self, cv: ChainingValue, position: u64) void {
            self.mergeStack(position);
            self.stack[self.stack_len] = cv;
            self.stack_len += 1;
        }

        fn processBatch(self: *Self, input: [*]const u8, chunk_count: usize) void {
            std.debug.assert(chunk_count >= 2 and chunk_count <= batch_capacity);
            std.debug.assert(std.math.isPowerOfTwo(chunk_count));
            std.debug.assert(self.chunk.counter & (chunk_count - 1) == 0);

            self.compressChunks(input, chunk_count);
            var count = chunk_count;
            while (count > 2) : (count /= 2) self.compressParents(count / 2);

            // Preserve both final children: only finalization knows whether their parent is the
            // root and must receive ROOT compression.
            self.push(self.batch[0], self.chunk.counter);
            self.push(self.batch[1], self.chunk.counter + chunk_count / 2);
        }

        fn compressChunks(self: *Self, input: [*]const u8, count: usize) void {
            inline for (.{ 16, 8, 4 }) |width| {
                if (comptime compression.max_lanes >= width) {
                    if (count >= width) {
                        for (0..count / width) |group| {
                            const offset = group * width;
                            compression.chunks(
                                width,
                                self.key,
                                input + offset * chunk_bytes,
                                self.chunk.counter + offset,
                                self.mode,
                                @ptrCast(&self.messages),
                                self.batch[offset..][0..width],
                            );
                        }
                        return;
                    }
                }
            }
            for (0..count / 2) |group| {
                const offset = group * 2;
                compression.pairChunks(
                    self.key,
                    input + offset * chunk_bytes,
                    self.chunk.counter + offset,
                    self.mode,
                    self.batch[offset..][0..2],
                );
            }
        }

        fn compressParents(self: *Self, count: usize) void {
            inline for (.{ 16, 8, 4 }) |width| {
                if (comptime compression.max_lanes >= width) {
                    if (count >= width) {
                        for (0..count / width) |group| {
                            const offset = group * width;
                            compression.parents(
                                width,
                                self.key,
                                self.batch[offset * 2 ..][0 .. width * 2],
                                self.mode,
                                @ptrCast(&self.messages),
                                self.batch[offset..][0..width],
                            );
                        }
                        return;
                    }
                }
            }
            for (0..count) |i| {
                const left = self.batch[i * 2];
                const right = self.batch[i * 2 + 1];
                self.batch[i] = Output.parent(self.key, left, right, self.mode).chaining(kernel);
            }
        }
    };
}

fn keyWords(key: Digest) ChainingValue {
    var words: ChainingValue = undefined;
    for (&words, 0..) |*word, i| {
        const word_offset = i * @sizeOf(u32);
        word.* = std.mem.readInt(u32, key[word_offset..][0..4], .little);
    }
    return words;
}

test "all official modes and extended output match independent vectors across kernels" {
    const allocator = testing.allocator;
    const max_input_len = official_vectors[official_vectors.len - 1].input_len;
    const source = try allocator.alloc(u8, max_input_len + 64);
    defer allocator.free(source);

    inline for (.{ compression.Kernel.scalar, compression.Kernel.row }) |kernel| {
        const hasher = try allocator.create(State(kernel));
        defer allocator.destroy(hasher);
        for (official_vectors) |case| {
            const size = case.input_len;
            for ([_]usize{ 0, 1, 3, 7, 15, 31, 63 }) |offset| {
                const input = source[offset..][0..size];
                for (input, 0..) |*byte, i| byte.* = @intCast(i % 251);
                inline for (0..3) |mode| {
                    var expected: [131]u8 = undefined;
                    _ = try std.fmt.hexToBytes(&expected, case.outputs[mode]);
                    if (mode == 0) {
                        const digest = try hasher.hash(input);
                        try testing.expectEqualSlices(u8, expected[0..32], &digest);
                    }

                    switch (mode) {
                        0 => hasher.reset(),
                        1 => hasher.resetKeyed(vector_key),
                        2 => try hasher.resetDerive(vector_context),
                        else => unreachable,
                    }
                    try hasher.update(input);
                    try testing.expectEqualSlices(u8, expected[0..32], &hasher.final());

                    var actual: [131]u8 = undefined;
                    try hasher.finalizeSeek(0, &actual);
                    try testing.expectEqualSlices(u8, &expected, &actual);
                    try hasher.finalizeSeek(31, actual[0..100]);
                    try testing.expectEqualSlices(u8, expected[31..], actual[0..100]);
                }
            }
        }
    }
}

test "incremental block chunk and tree boundaries preserve snapshot and reset contracts" {
    const allocator = testing.allocator;
    const hasher = try allocator.create(Hasher);
    defer allocator.destroy(hasher);
    const bytes = try allocator.alloc(u8, 32769);
    defer allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i *% 79 +% (i >> 8));

    const sizes = blk: {
        const blocks = [_]usize{ 0, 1, 63, 64, 65, 127, 128, 129 };
        const chunks = [_]usize{ 1023, 1024, 1025, 2048, 2049 };
        const trees = [_]usize{ 4095, 4096, 4097, 8191, 8192, 8193, 16384, 16385, 32768, 32769 };
        break :blk blocks ++ chunks ++ trees;
    };
    const steps = [_]usize{ 1, 3, 63, 64, 65, 1023, 1024, 1025, 2048, 4096 };
    for (sizes) |size| {
        var expected: Digest = undefined;
        std.crypto.hash.Blake3.hash(bytes[0..size], &expected, .{});
        for (steps) |step| {
            hasher.reset();
            var at: usize = 0;
            while (at < size) {
                try hasher.update("");
                const take = @min(step, size - at);
                try hasher.update(bytes[at..][0..take]);
                at += take;
            }
            try testing.expectEqualSlices(u8, &expected, &hasher.final());
            try testing.expectEqualSlices(u8, &expected, &hasher.final());
        }
    }

    for (0..130) |size| for (0..size + 1) |split| {
        hasher.reset();
        try hasher.update(bytes[0..split]);
        var prefix: Digest = undefined;
        std.crypto.hash.Blake3.hash(bytes[0..split], &prefix, .{});
        try testing.expectEqualSlices(u8, &prefix, &hasher.final());
        try hasher.update(bytes[split..size]);
        var expected: Digest = undefined;
        std.crypto.hash.Blake3.hash(bytes[0..size], &expected, .{});
        try testing.expectEqualSlices(u8, &expected, &hasher.final());
    };
}

test "length overflow preserves state and output and clear erases the complete owner" {
    const hasher = try testing.allocator.create(Hasher);
    defer testing.allocator.destroy(hasher);
    hasher.resetKeyed(@splat(0xff));
    try hasher.update("accepted bytes");
    hasher.total_bytes = std.math.maxInt(u64);
    const before = hasher.final();

    try testing.expectError(error.SizeOverflow, hasher.update("x"));
    try testing.expectEqualSlices(u8, &before, &hasher.final());
    try testing.expectEqual(std.math.maxInt(u64), hasher.total_bytes);

    var output: [32]u8 = @splat(0xa7);
    try testing.expectError(
        error.SizeOverflow,
        hasher.finalizeSeek(std.math.maxInt(u64) - 15, &output),
    );
    try testing.expectEqual(@as([32]u8, @splat(0xa7)), output);

    hasher.clear();
    for (std.mem.asBytes(hasher)) |byte| try testing.expectEqual(@as(u8, 0), byte);
    const first = try hasher.hash("reused");
    const second = try hasher.hash("reused");
    try testing.expectEqual(first, second);
}

test "irregular splits high seeks and appending after whole hashing preserve all modes" {
    const allocator = testing.allocator;
    const native = try allocator.create(Hasher);
    defer allocator.destroy(native);
    const reference = try allocator.create(std.crypto.hash.Blake3);
    defer allocator.destroy(reference);
    const input = try allocator.alloc(u8, 1048577);
    defer allocator.free(input);
    var generator = std.Random.DefaultPrng.init(0);
    const random = generator.random();
    random.bytes(input);

    const lengths = blk: {
        const short = [_]usize{ 0, 1, 63, 64, 65, 1023, 1024, 1025 };
        const batches = [_]usize{ 16383, 16384, 16385, 65535, 65536, 65537 };
        const trees = [_]usize{ 131071, 131072, 131073, 262144, 1048577 };
        break :blk short ++ batches ++ trees;
    };
    // The low 32 bits of the output-block counter wrap after 2^38 output bytes.
    const counter_wrap: u64 = (@as(u64, 1) << 32) * block_bytes;
    const seek_offsets = [_]u64{ 0, 31, 32, 63, 64, 65, counter_wrap - 1, counter_wrap + 63 };
    const context = "zig-wingman BLAKE3 seeded split verification";
    for (lengths) |length| {
        for (0..3) |mode| {
            switch (mode) {
                0 => {
                    native.reset();
                    reference.* = std.crypto.hash.Blake3.init(.{});
                },
                1 => {
                    native.resetKeyed(@splat(0xa7));
                    reference.* = std.crypto.hash.Blake3.init(.{ .key = @splat(0xa7) });
                },
                2 => {
                    try native.resetDerive(context);
                    reference.* = std.crypto.hash.Blake3.initKdf(context, .{});
                },
                else => unreachable,
            }
            reference.update(input[0..length]);
            var position: usize = 0;
            while (position < length) {
                const take = @min(length - position, random.intRangeAtMost(usize, 1, 262145));
                try native.update("");
                try native.update(input[position..][0..take]);
                position += take;
            }
            for (seek_offsets) |seek| {
                var expected: [131]u8 = undefined;
                var actual: [131]u8 = undefined;
                reference.finalizeSeek(seek, &expected);
                try native.finalizeSeek(seek, &actual);
                try testing.expectEqualSlices(u8, &expected, &actual);
            }
        }

        _ = try native.hash(input[0..length]);
        reference.* = std.crypto.hash.Blake3.init(.{});
        reference.update(input[0..length]);
        const suffix = "appended after whole hashing";
        try native.update(suffix);
        reference.update(suffix);
        var expected: Digest = undefined;
        reference.final(&expected);
        try testing.expectEqualSlices(u8, &expected, &native.final());
    }
}

test "exact input and output ends stay within Linux protected-page boundaries" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const page = std.heap.pageSize();
    const body_size = 128 * 1024;
    const mapping = try std.posix.mmap(
        null,
        body_size + 2 * page,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(mapping);

    const linux = std.os.linux;
    try testing.expectEqual(
        std.posix.E.SUCCESS,
        std.posix.errno(linux.mprotect(mapping.ptr, page, .{})),
    );
    try testing.expectEqual(
        std.posix.E.SUCCESS,
        std.posix.errno(linux.mprotect(mapping.ptr + page + body_size, page, .{})),
    );

    const body = mapping[page..][0..body_size];
    for (body, 0..) |*byte, i| byte.* = @truncate(i *% 193 +% (i >> 8));
    const allocator = testing.allocator;
    const hasher = try allocator.create(Hasher);
    defer allocator.destroy(hasher);
    const reference = try allocator.create(std.crypto.hash.Blake3);
    defer allocator.destroy(reference);

    const input_sizes = [_]usize{
        0, 1, 3, 31, 32, 63, 64, 65, 1023, 1024, 1025, 2048, 4096, 8192, 16384, 32768, 65536,
    };
    for (input_sizes) |size| {
        for ([_][]const u8{ body[0..size], body[body.len - size ..] }) |input| {
            var expected: Digest = undefined;
            std.crypto.hash.Blake3.hash(input, &expected, .{});
            try testing.expectEqualSlices(u8, &expected, &try hasher.hash(input));
        }
    }

    for ([_]usize{ 0, 1, 31, 32, 63, 64, 65, 131 }) |size| {
        const output = body[body.len - size ..];
        hasher.reset();
        try hasher.update("guarded extended output");
        try hasher.finalizeSeek(63, output);
        reference.* = std.crypto.hash.Blake3.init(.{});
        reference.update("guarded extended output");
        var expected: [131]u8 = undefined;
        reference.finalizeSeek(63, expected[0..size]);
        try testing.expectEqualSlices(u8, expected[0..size], output);
    }
}

test "compile-time selection preserves modes snapshots seeks and clearing" {
    const allocator = testing.allocator;
    const state = try allocator.create(Hasher);
    defer allocator.destroy(state);
    const scalar = try allocator.create(ScalarHasher);
    defer allocator.destroy(scalar);
    const bytes = try allocator.alloc(u8, 262145);
    defer allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i % 251);

    const lengths = [_]usize{ 0, 1, 63, 64, 1023, 1024, 1025, 2048, 16384, 131072, 131081 };
    for (0..3) |mode| {
        switch (mode) {
            0 => {
                state.reset();
                scalar.reset();
            },
            1 => {
                state.resetKeyed(@splat(17));
                scalar.resetKeyed(@splat(17));
            },
            2 => {
                try state.resetDerive("test context");
                try scalar.resetDerive("test context");
            },
            else => unreachable,
        }
        for (lengths) |length| {
            try state.update(bytes[1..][0..length]);
            try scalar.update(bytes[1..][0..length]);
            try testing.expectEqual(scalar.final(), state.final());
            var expected: [131]u8 = undefined;
            var actual: [131]u8 = undefined;
            try scalar.finalizeSeek(0x100000003f, &expected);
            try state.finalizeSeek(0x100000003f, &actual);
            try testing.expectEqual(expected, actual);
        }
    }

    var output: [3]u8 = @splat(0xa7);
    try testing.expectError(error.SizeOverflow, state.finalizeSeek(std.math.maxInt(u64), &output));
    try testing.expectEqual([3]u8{ 0xa7, 0xa7, 0xa7 }, output);
    state.clear();
    try testing.expect(std.mem.allEqual(u8, std.mem.asBytes(state), 0));
    state.reset();
    try testing.expectEqual(try scalar.hash("reuse"), try state.hash("reuse"));
}

// Defer a wave and complete it in reverse order to qualify result ordering independently of a
// thread pool. This fixture is used only by the serialized calls below.
const TestIo = struct {
    const Pending = struct {
        context: [@sizeOf(*Worker)]u8 align(@alignOf(*Worker)),
        start: *const fn (*const anyopaque) void,
    };
    pending: [7]Pending = undefined,
    count: usize = 0,
    submitted: usize = 0,
    joined: usize = 0,
    canceled: bool = false,

    const vtable: std.Io.VTable = blk: {
        var table = std.Io.failing.vtable.*;
        table.groupAsync = groupAsync;
        table.groupAwait = groupAwait;
        table.groupCancel = groupCancel;
        break :blk table;
    };

    fn groupAsync(
        pointer: ?*anyopaque,
        group: *std.Io.Group,
        context: []const u8,
        alignment: std.mem.Alignment,
        start: *const fn (*const anyopaque) void,
    ) void {
        const self: *TestIo = @ptrCast(@alignCast(pointer.?));
        std.debug.assert(context.len == @sizeOf(*Worker));
        std.debug.assert(alignment == std.mem.Alignment.of(*Worker));
        std.debug.assert(self.count < self.pending.len);
        const task = &self.pending[self.count];
        @memcpy(&task.context, context);
        task.start = start;
        self.count += 1;
        self.submitted += 1;
        group.token.store(self, .release);
    }

    fn drain(self: *TestIo, group: *std.Io.Group) void {
        while (self.count != 0) {
            self.count -= 1;
            const task = &self.pending[self.count];
            task.start(&task.context);
        }
        group.token.store(null, .release);
        self.joined += 1;
    }

    fn groupAwait(
        pointer: ?*anyopaque,
        group: *std.Io.Group,
        _: *anyopaque,
    ) std.Io.Cancelable!void {
        const self: *TestIo = @ptrCast(@alignCast(pointer.?));
        self.drain(group);
        if (self.canceled) return error.Canceled;
    }

    fn groupCancel(pointer: ?*anyopaque, group: *std.Io.Group, _: *anyopaque) void {
        const self: *TestIo = @ptrCast(@alignCast(pointer.?));
        self.drain(group);
    }

    fn io(self: *TestIo) std.Io {
        return .{ .userdata = self, .vtable = &vtable };
    }
};

test "parallel ordered subtrees preserve modes prefixes snapshots and seeked XOF" {
    const allocator = testing.allocator;
    const bytes = try allocator.alloc(u8, 1048577);
    defer allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i % 251);
    const workers = try allocator.alloc(Worker, 8);
    defer allocator.free(workers);
    const state = try allocator.create(Hasher);
    defer allocator.destroy(state);
    const serial = try allocator.create(ScalarHasher);
    defer allocator.destroy(serial);

    const prefixes = [_]usize{ 0, 1, 1023, 1024, 1025, 3072 };
    const lengths = [_]usize{ 0, 1, 1024, 4095, 4096, 4097, 65535, 65536, 262144, 1048577 };
    for (0..3) |mode| {
        for (prefixes) |prefix| {
            for (lengths) |length| {
                switch (mode) {
                    0 => {
                        state.reset();
                        serial.reset();
                    },
                    1 => {
                        state.resetKeyed(@splat(0xa7));
                        serial.resetKeyed(@splat(0xa7));
                    },
                    2 => {
                        try state.resetDerive("parallel test context");
                        try serial.resetDerive("parallel test context");
                    },
                    else => unreachable,
                }

                try state.update(bytes[0..prefix]);
                try serial.update(bytes[0..prefix]);
                var scheduler: TestIo = .{};
                const worker_budget = 2 + (prefix % 7);
                try state.updateParallel(
                    scheduler.io(),
                    bytes[0..length],
                    workers[0..worker_budget],
                    .{ .minimum_bytes = 0, .minimum_job_bytes = 2048 },
                );
                try serial.update(bytes[0..length]);
                try testing.expectEqual(serial.final(), state.final());
                try testing.expectEqual(serial.final(), state.final());

                var expected: [131]u8 = undefined;
                var actual: [131]u8 = undefined;
                try serial.finalizeSeek(0x100000003f, &expected);
                try state.finalizeSeek(0x100000003f, &actual);
                try testing.expectEqual(expected, actual);

                try state.update("after snapshot");
                try serial.update("after snapshot");
                try testing.expectEqual(serial.final(), state.final());
                try testing.expectEqual(@as(usize, 0), scheduler.count);
                if (prefix == 0 and length >= 4096) try testing.expect(scheduler.joined > 0);
            }
        }
    }

    for (workers) |*worker| {
        worker.clear();
        try testing.expect(std.mem.allEqual(u8, std.mem.asBytes(worker), 0));
    }
}

test "parallel admission skips small work and rejects overflow before submission" {
    const allocator = testing.allocator;
    const state = try allocator.create(Hasher);
    defer allocator.destroy(state);
    const workers = try allocator.alloc(Worker, 2);
    defer allocator.free(workers);
    var scheduler: TestIo = .{};
    state.reset();
    try state.updateParallel(scheduler.io(), "small record", workers, .{});
    try testing.expectEqual(@as(usize, 0), scheduler.submitted);
    var expected: Digest = undefined;
    std.crypto.hash.Blake3.hash("small record", &expected, .{});
    try testing.expectEqual(expected, state.final());

    state.total_bytes = std.math.maxInt(u64);
    try testing.expectError(
        error.SizeOverflow,
        state.updateParallel(
            scheduler.io(),
            "x",
            workers,
            .{ .minimum_bytes = 0, .minimum_job_bytes = 0 },
        ),
    );
    try testing.expectEqual(expected, state.final());
    try testing.expectEqual(@as(usize, 0), scheduler.submitted);
    try testing.expectEqual(@as(usize, 0), scheduler.joined);
}

test "compile-time native and scalar parallel owners retain their kernel choice" {
    const allocator = testing.allocator;
    const bytes = try allocator.alloc(u8, 1048576);
    defer allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i % 251);
    const workers = try allocator.alloc(Worker, 2);
    defer allocator.free(workers);
    var expected: Digest = undefined;
    std.crypto.hash.Blake3.hash(bytes, &expected, .{});

    inline for (.{ Hasher, ScalarHasher }) |Owner| {
        const state = try allocator.create(Owner);
        defer allocator.destroy(state);
        var scheduler: TestIo = .{};
        state.reset();
        try state.updateParallel(scheduler.io(), bytes, workers, .{});
        try testing.expectEqual(expected, state.final());
        try testing.expectEqual(@as(usize, 1), scheduler.submitted);
        try testing.expectEqual(@as(usize, 1), scheduler.joined);
    }
}

test "parallel cancellation acquires workers and reset permits reuse" {
    const allocator = testing.allocator;
    const bytes = try allocator.alloc(u8, 262144);
    defer allocator.free(bytes);
    @memset(bytes, 0x5a);
    const workers = try allocator.alloc(Worker, 4);
    defer allocator.free(workers);
    const state = try allocator.create(Hasher);
    defer allocator.destroy(state);
    var provider: TestIo = .{ .canceled = true };
    state.reset();
    try testing.expectError(
        error.Canceled,
        state.updateParallel(provider.io(), bytes, workers, .{}),
    );
    try testing.expectEqual(@as(usize, 0), provider.count);
    try testing.expectEqual(@as(usize, 1), provider.joined);
    for (workers) |worker| try testing.expectEqual(@as(usize, 0), worker.input.len);

    // The inline provider needs no scheduler reservation; reset is the recovery contract.
    state.reset();
    try state.updateParallel(std.Io.failing, bytes, workers, .{});
    var expected: Digest = undefined;
    std.crypto.hash.Blake3.hash(bytes, &expected, .{});
    try testing.expectEqual(expected, state.final());
    for (workers) |worker| try testing.expectEqual(@as(usize, 0), worker.input.len);
}

test {
    _ = compression;
    // Instantiate both public state types even when only declaration-linked examples are selected.
    testing.refAllDecls(Hasher);
    testing.refAllDecls(ScalarHasher);
}
