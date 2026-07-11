//! Thread-Safe template for a ring buffer with std compatible reader and writer and safety checks

const std = @import("std");
const Io = std.Io;

/// Options for the ring buffer template
pub const RingBufferOptions = struct {
    T: type = u8,
};

/// Ring buffer template
pub fn RingBuffer(comptime options: RingBufferOptions) type {
    const T = options.T;

    return struct {
        mutex: std.Io.Mutex,
        buffer: []T,
        head: usize = 0,
        tail: usize = 0,
        used: usize = 0,

        const Rb = @This();

        /// Creates a new ring buffer from a user provided buffer
        pub fn init(buf: []T) Rb {
            return .{ .mutex = .init, .buffer = buf };
        }

        pub fn clear(self: *Rb) void {
            self.tail = 0;
            self.head = 0;
            self.used = 0;
        }

        pub fn write(self: *Rb, io: Io, src: []const u8) WriteError!usize {
            if (T != u8)
                @compileError("write() is only supported for u8 ring buffers");

            if (src.len == 0)
                return 0;

            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            const free = self.buffer.len -| self.used;
            if (free == 0)
                return error.RingBufferFull;

            const n = @min(src.len, free);

            // First contiguous region
            const first = @min(n, self.buffer.len - self.head);
            std.mem.copyForwards(
                u8,
                self.buffer[self.head .. self.head + first],
                src[0..first],
            );

            // Wrapped region
            const second = n - first;
            if (second != 0) {
                std.mem.copyForwards(
                    u8,
                    self.buffer[0..second],
                    src[first .. first + second],
                );
            }

            self.head = (self.head + n) % self.buffer.len;
            self.used += n;

            return n;
        }

        pub fn writeAll(self: *Rb, io: Io, src: []const u8) WriteError!void {
            var index: usize = 0;

            while (index < src.len) {
                const n = try self.write(io, src[index..]);
                if (n == 0)
                    return error.RingBufferFull;

                index += n;
            }
        }

        pub fn read(self: *Rb, io: Io, dst: []u8) usize {
            if (T != u8)
                @compileError("read() is only supported for u8 ring buffers");

            if (dst.len == 0)
                return 0;

            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            const n = @min(dst.len, self.used);
            if (n == 0)
                return 0;

            const first = @min(n, self.buffer.len - self.tail);
            std.mem.copyForwards(
                u8,
                dst[0..first],
                self.buffer[self.tail .. self.tail + first],
            );

            const second = n - first;
            if (second != 0) {
                std.mem.copyForwards(
                    u8,
                    dst[first .. first + second],
                    self.buffer[0..second],
                );
            }

            self.tail = (self.tail + n) % self.buffer.len;
            self.used -= n;

            return n;
        }

        pub fn readAll(self: *Rb, io: Io, dst: []u8) usize {
            return self.read(io, dst);
        }

        /// Errors that can occur when writing to the buffer
        pub const WriteError = error{RingBufferFull};
        /// STD compatible writer for the ring buffer
        // pub const Writer = std.io.GenericWriter(*Rb, WriteError, writeFn);
        // /// Returns the writer for the ring buffer
        // pub fn writer(self: *Rb) Writer {
        //     return .{ .context = self };
        // }
        // /// Write function for the STD writer
        // fn writeFn(self: *Rb, io: Io, m: []const u8) WriteError!usize {
        //     if (T != u8)
        //         @compileError("Writer and Reader interfaces only support u8");

        //     if (m.len == 0)
        //         return 0;

        //     self.mutex.lockUncancelable(io);
        //     defer self.mutex.unlock(io);

        //     const free_space = self.buffer.len - self.used;
        //     if (free_space == 0)
        //         return error.RingBufferFull;

        //     const writable = @min(m.len, free_space);
        //     // Write as much as we can
        //     if (self.head > self.tail) {
        //         // the available space is not contiguous
        //         const before_wrap = self.buffer.len - self.head;

        //         if (before_wrap >= writable) {
        //             // things fit without wrapping
        //             std.mem.copyForwards(u8, self.buffer[self.head..], m);
        //             self.head += writable;
        //         } else {
        //             // we have to wrap
        //             std.mem.copyForwards(u8, self.buffer[self.head..], m[0..before_wrap]);
        //             std.mem.copyForwards(u8, self.buffer[0..self.tail], m[before_wrap..writable]);
        //             self.head = writable - before_wrap;
        //         }
        //     } else {
        //         if (self.head == self.tail) {
        //             std.debug.assert(self.used == 0);
        //             self.head = 0;
        //             self.tail = 0;
        //         }
        //         // the available space is contiguous
        //         std.mem.copyForwards(u8, self.buffer[self.head..], m[0..writable]); // copy what fits
        //         self.head += writable;
        //     }

        //     self.used += writable;
        //     return writable;
        // }

        /// Pushes a single element to the ring buffer
        pub fn push(self: *Rb, io: Io, value: T) WriteError!void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            if (self.used == self.buffer.len)
                return error.RingBufferFull;

            if (self.head == self.buffer.len)
                self.head = 0;

            self.buffer[self.head] = value;
            self.head += 1;
            self.used += 1;
        }

        /// Errors that can occur when reading from the buffer (won't be the same when using the reader interface)
        pub const ReadError = error{RingBufferEmpty};
        /// STD compatible reader for the ring buffer
        // pub const Reader = std.io.Reader(*Rb, error{}, readFn);
        // /// Returns the reader for the ring buffer
        // pub fn reader(self: *Rb) Reader {
        //     return .{ .context = self };
        // }
        // /// Read function for the STD reader
        // fn readFn(self: *Rb, io: Io, b: []u8) error{}!usize {
        //     if (T != u8)
        //         @compileError("Writer and Reader interfaces only support u8");

        //     if (b.len == 0)
        //         return 0;

        //     self.mutex.lockUncancelable(io);
        //     defer self.mutex.unlock(io);

        //     const used_space = self.used;
        //     if (used_space == 0)
        //         return 0;

        //     const readable = std.math.min(used_space, b.len);
        //     // Read as much as we can
        //     if (self.head > self.tail) {
        //         // the readable data is contiguous
        //         std.mem.copy(u8, b, self.buffer[self.tail..(self.tail + readable)]);
        //         self.tail += readable;
        //     } else {
        //         // the readable data is not contiguous
        //         const before_wrap = self.buffer.len - self.tail;

        //         if (before_wrap >= readable) {
        //             // things can be read without wrapping
        //             std.mem.copy(u8, b, self.buffer[self.tail..(self.tail + readable)]);
        //             self.tail += readable;
        //         } else {
        //             const after_wrap = readable - before_wrap;
        //             std.debug.assert(after_wrap <= self.head);

        //             // the reading has to wrap
        //             std.mem.copy(u8, b[0..before_wrap], self.buffer[self.tail..]);
        //             std.mem.copy(u8, b[before_wrap..readable], self.buffer[0..after_wrap]);
        //             self.tail = readable - before_wrap;
        //         }
        //     }

        //     self.used -= readable;
        //     return readable;
        // }

        /// Pops a single element from the ring buffer
        pub fn pop(self: *Rb, io: Io) ReadError!T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            if (self.used == 0)
                return error.RingBufferEmpty;

            if (self.tail == self.buffer.len)
                self.tail = 0;

            const value = self.buffer[self.tail];
            self.tail += 1;
            self.used -= 1;

            return value;
        }

        /// Returns the number of elements in the buffer
        pub fn getUsedSpace(self: *Rb, io: Io) usize {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            return self.used;
        }
        /// Returns the number of elements that can be written to the buffer
        pub fn getFreeSpace(self: *Rb, io: Io) usize {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            return self.buffer.len - self.used;
        }

        /// Empties the buffer into a writer
        pub fn flushEverythingToWriter(self: *Rb, io: Io, stream: anytype) !void {
            if (T != u8)
                @compileError("Only implemented for u8");

            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            if (self.head > self.tail) {
                // the readable data is contiguous
                try stream.writeAll(self.buffer[self.tail..self.head]);
            } else {
                // the readable data is not contiguous
                try stream.writeAll(self.buffer[self.tail..]);
                try stream.writeAll(self.buffer[0..self.head]);
            }
            self.clear();
        }

        /// Dumps the contents of the ring buffer to `stderr`.
        /// In a formatted way that helps with debugging
        pub fn dump(self: *Rb, io: Io) void {
            var buf: [1024]u8 = undefined;
            self.dumpToStream(
                io,
                std.Io.File.stderr().writer(io, &buf),
            ) catch return;
        }

        /// Dumps the contents of the ring buffer to `stream`
        /// In a formatted way that helps with debugging
        pub fn dumpToStream(self: *Rb, io: Io, stream: anytype) !void {
            if (T != u8)
                @compileError("Only implemented for u8 as of now");

            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            const w = stream;

            try w.writeAll("\n[");
            for (self.buffer) |byte| {
                try w.print("{x:0>2} ", .{byte});
            }
            try w.writeAll("]\n");
            if (self.head < self.tail) {
                var i: usize = 0;
                try w.writeByte(' ');
                while (i < self.head) : (i += 1) {
                    try w.writeAll("---");
                }
                try w.writeAll("-H ");
                i += 1;
                while (i < self.tail) : (i += 1) {
                    try w.writeAll("   ");
                }
                try w.writeAll(" t-");
                i += 1;
                while (i < self.buffer.len) : (i += 1) {
                    try w.writeAll("---");
                }
            } else if (self.head > self.tail) {
                var i: usize = 0;
                try w.writeByte(' ');
                while (i < self.tail) : (i += 1) {
                    try w.writeAll("   ");
                }
                try w.writeAll(" t-");
                i += 1;
                while (i < self.head) : (i += 1) {
                    try w.writeAll("---");
                }
                try w.writeAll("-H ");
            } else if (self.head == self.tail) {
                try w.writeByte(' ');
                for (self.buffer, 0..) |_, i| {
                    if (i == self.head) {
                        try w.writeAll(if (self.used == 0) " ^ " else "-^-");
                    } else {
                        try w.writeAll(if (self.used == 0) "   " else "---");
                    }
                }
            }
            try w.writeByte('\n');
        }
    };
}

test "RingBuffer: writing" {
    // Note: this is NOT how you use a ring buffer
    const tst = std.testing;

    var buf: [10]u8 = undefined;
    var rb = RingBuffer(.{}).init(&buf);
    const w = rb.writer();

    _ = try w.write("0123456789");

    try tst.expectEqualStrings("0123456789", &buf);
    try tst.expectEqual(@as(usize, 10), rb.used);
    try tst.expectEqual(@as(usize, 0), rb.getFreeSpace());

    rb = RingBuffer(.{}){ .buffer = &buf, .head = 4, .tail = 3, .used = 1, .mutex = .{} };

    _ = try w.write("abcdefgh");
    _ = try w.write("ijklmnopq");
    try tst.expectError(error.RingBufferFull, w.write("stuvwxyz"));

    try tst.expectEqualStrings("ghi3abcdef", &buf);

    rb = RingBuffer(.{}){ .buffer = &buf, .head = 2, .tail = 3, .used = 9, .mutex = .{} };

    try w.writeByte('_');

    try tst.expectEqualStrings("gh_3abcdef", &buf);
}

test "RingBuffer: full buffer read" {
    // Note: this is NOT how you use a ring buffer
    const tst = std.testing;

    var buf: [10]u8 = undefined;
    var rb = RingBuffer(.{}).init(&buf);
    const w = rb.writer();
    const r = rb.reader();

    // test the scenario where the tail is at the start

    _ = try w.write("0123456789");

    try tst.expectEqualStrings("0123456789", &buf);
    try tst.expectEqual(@as(usize, 10), rb.used);
    try tst.expectEqual(@as(usize, 0), rb.getFreeSpace());

    {
        var rd_buf: [10]u8 = undefined;
        const len = try r.readAll(&rd_buf);
        try tst.expectEqual(len, 10);
        try tst.expectEqualStrings("0123456789", &rd_buf);
    }

    // Now, for something more tricky, a scenario where the head and tail are the same and are not at the beginning of the array

    _ = try w.write("0123456");
    _ = try r.read(buf[0..5]);
    _ = try w.write("01234567");

    {
        var rd_buf: [10]u8 = undefined;
        const len = try r.readAll(rd_buf[0..9]);
        try tst.expectEqual(len, 9);
        rd_buf[9] = 'a'; // fill
        try tst.expectEqualStrings("560123456a", &rd_buf);
    }

    {
        var rd_buf: [10]u8 = undefined;
        const len = try r.readAll(rd_buf[0..1]);
        try tst.expectEqual(len, 1);
        try tst.expectEqual(rd_buf[0], '7');
    }
}

test "RingBuffer: random writing and reading" {
    const seed: u64 = @intCast(std.time.timestamp());

    var prng = std.rand.DefaultPrng.init(seed);
    var rand = prng.random();

    const BUF_SIZE = 25;

    var buf: [BUF_SIZE]u8 = undefined;
    var rb = RingBuffer(.{}).init(&buf);
    const w = rb.writer();
    const r = rb.reader();

    var temp: [BUF_SIZE]u8 = undefined;

    var feeder_array: [2048]u8 = undefined;
    rand.bytes(&feeder_array);

    var feeder_write_idx: usize = 0;
    var feeder_read_idx: usize = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const free = rb.getFreeSpace();
        const to_write = rand.uintAtMost(usize, free);
        _ = try w.writeAll(feeder_array[feeder_write_idx .. to_write + feeder_write_idx]);

        const used = rb.used;
        const to_read = rand.uintAtMost(usize, used);
        const len = try r.readAll(temp[0..to_read]);

        try std.testing.expectEqual(to_read, len);
        try expectEqualSlicesPrint(temp[0..to_read], feeder_array[feeder_read_idx .. to_read + feeder_read_idx]);

        feeder_write_idx += to_write;
        feeder_read_idx += to_read;
    }
}

test "RingBuffer: push and pop" {
    const tst = std.testing;

    var buf: [10]i9 = undefined;
    var rb = RingBuffer(.{ .T = i9 }).init(&buf);

    try rb.push(255);
    try tst.expectEqual(@as(usize, 1), rb.used);
    try tst.expectEqual(@as(usize, 9), rb.getFreeSpace());
    try tst.expectEqual(@as(i9, 255), try rb.pop());
    try tst.expectError(error.RingBufferEmpty, rb.pop());

    var i: i9 = 0;
    while (i < 10) : (i += 1) {
        try rb.push(i);
    }
    try tst.expectError(error.RingBufferFull, rb.push(11));

    i = 0;
    while (i < 10) : (i += 1) {
        try tst.expectEqual(i, try rb.pop());
    }
    try tst.expectError(error.RingBufferEmpty, rb.pop());
}

test "RingBuffer: flush everything to writer" {
    var buf: [10]u8 = undefined;
    var rb = RingBuffer(.{}).init(&buf);

    var dest = try std.BoundedArray(u8, 20).init(0);

    try rb.writer().writeAll("Hello,");
    try rb.flushEverythingToWriter(dest.writer());
    try rb.writer().writeAll(" woooorld");
    try rb.flushEverythingToWriter(dest.writer());

    try expectEqualSlicesPrint("Hello, woooorld", dest.slice());
}

fn expectEqualSlicesPrint(expected: []const u8, actual: []const u8) !void {
    if (expected.len != actual.len) {
        std.log.debug("slice lengths differ. expected {d}, found {d}\n", .{ expected.len, actual.len });
        return error.TestExpectedEqual;
    }

    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        if (expected[i] != actual[i]) {
            std.log.debug("Actual: \n", .{});
            for (actual) |c| {
                std.log.debug("{x:0>2} ", .{c});
            }
            std.log.debug("\nExpected: \n", .{});
            for (expected) |c| {
                std.log.debug("{x:0>2} ", .{c});
            }
            std.log.debug("\n", .{});
            return error.TestExpectedEqual;
        }
    }
}
