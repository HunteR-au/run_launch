const std = @import("std");

pub fn StaticRingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity]T = undefined,
        head: usize = 0, // index of logical element 0
        len: usize = 0, // number of valid elements [0..capacity]

        pub fn init() Self {
            return .{};
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len == capacity;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        fn physIndex(self: *const Self, logical_index: usize) usize {
            // logical_index must be < len (caller enforces)
            return (self.head + logical_index) % capacity;
        }

        // ------------------------------------------------------------
        // Forward iterator: 0 → len-1 (oldest → newest)
        // ------------------------------------------------------------
        pub const Iterator = struct {
            rb: *const Self,
            i: usize = 0,

            pub fn next(self: *Iterator) ?T {
                if (self.i >= self.rb.len) return null;
                const idx = self.rb.physIndex(self.i);
                self.i += 1;
                return self.rb.buf[idx];
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return .{ .rb = self };
        }

        // ------------------------------------------------------------
        // Reverse iterator: len-1 → 0 (newest → oldest)
        // ------------------------------------------------------------
        pub const ReverseIterator = struct {
            rb: *const Self,
            i: usize, // starts at len-1

            pub fn next(self: *ReverseIterator) ?T {
                if (self.i == usize.max) return null; // underflow sentinel
                const idx = self.rb.physIndex(self.i);
                const value = self.rb.buf[idx];

                if (self.i == 0) {
                    self.i = usize.max; // mark as finished
                } else {
                    self.i -= 1;
                }

                return value;
            }
        };

        pub fn reverseIterator(self: *const Self) ReverseIterator {
            return .{
                .rb = self,
                .i = if (self.len == 0) usize.max else self.len - 1,
            };
        }

        /// Append at the "end" (after the newest element).
        /// Overwrites oldest when full if `overwrite == true`.
        pub fn push(self: *Self, value: T, overwrite: bool) !void {
            if (self.isFull()) {
                if (!overwrite) return error.Full;
                // overwrite oldest: move head forward
                self.head = (self.head + 1) % capacity;
                self.len = capacity;
            } else {
                self.len += 1;
            }

            const tail_logical = self.len - 1;
            const idx = self.physIndex(tail_logical);
            self.buf[idx] = value;
        }

        /// Pop oldest element.
        pub fn pop(self: *Self) !T {
            if (self.isEmpty()) return error.Empty;

            const value = self.buf[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return value;
        }

        /// Random access read: 0 = oldest, count()-1 = newest.
        pub fn get(self: *const Self, logical_index: usize) !T {
            if (logical_index >= self.len) return error.OutOfRange;
            const idx = self.physIndex(logical_index);
            return self.buf[idx];
        }

        /// Random access write.
        pub fn set(self: *Self, logical_index: usize, value: T) !void {
            if (logical_index >= self.len) return error.OutOfRange;
            const idx = self.physIndex(logical_index);
            self.buf[idx] = value;
        }
    };
}
