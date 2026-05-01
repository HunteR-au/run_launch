const std = @import("std");

const common = @import("iterator_common.zig");

fn commonPeek(self: anytype, alloc: std.mem.Allocator) !?IteratorResult_ {
    if (self._invalid.load(.seq_cst)) return error.IteratorInvalid;
    self.buffer.m.lock();
    defer self.buffer.m.unlock();
    const result = self._peek() orelse return null;
    return .{
        .line = try alloc.dupe(u8, result.line),
        .offset = result.offset,
    };
}

fn commonReset(self: anytype, index: IteratorIndex_) void {
    if (self._invalid.load(.seq_cst)) return error.IteratorInvalid;
    self.buffer.m.lock();
    defer self.buffer.m.unlock();
    self.line_index = index;
}

fn commonInvalidate(self: anytype) void {
    self._invalid.store(true, .seq_cst);
}

// requires pBuffer to contain
//  - nonowned_iterators: ArrayList
//  - m: mutex
//  - alloc: Allocator
fn commonInit(
    comptime T: type,
    comptime iterator_array_fieldname: []const u8,
    direction: common.IteratorKind,
    alloc: std.mem.Allocator,
    pBuffer: anytype,
) !*T {
    pBuffer.m.lock();
    defer pBuffer.m.unlock();

    //const inital_index: IteratorIndex = if (T == @This())
    //    pBuffer.filtered_newlines.len + 1
    //else
    //    0;
    const inital_index: IteratorIndex_ = .start;

    const self = try alloc.create(T);
    self.* = .{
        .alloc = alloc,
        .buffer = pBuffer,
        .line_index = inital_index,
    };

    var buf_backing = @field(self.buffer, iterator_array_fieldname);

    if (direction == .reverseLineIterator) {
        try buf_backing.append(
            self.buffer.alloc,
            .{ .kind = .reverseLineIterator, .ptr = self },
        );
    } else if (direction == .lineIterator) {
        try buf_backing.append(
            self.buffer.alloc,
            .{ .kind = .lineIterator, .ptr = self },
        );
    }

    return self;
}

fn commonDeinit(
    comptime T: type,
    comptime iterator_array_fieldname: []const u8,
    self: *T,
    comptime kind: common.IteratorKind,
) void {
    if (self._invalid.load(.seq_cst)) {
        // we can't touch buffer if invalid
        self.alloc.destroy(self);
    } else {
        self.buffer.m.lock();
        defer self.buffer.m.unlock();

        var buf_backing = @field(self.buffer, iterator_array_fieldname);

        for (buf_backing.items, 0..) |record, i| {
            switch (kind) {
                .lineIterator => {
                    // TODO: test this equalality test
                    const pIter: *T = @ptrCast(@alignCast(record.ptr));
                    if (kind == record.kind and pIter == self)
                        _ = buf_backing.swapRemove(i);
                },
                .reverseLineIterator => {
                    const pIter: *T = @ptrCast(@alignCast(record.ptr));
                    if (kind == record.kind and pIter == self)
                        _ = buf_backing.swapRemove(i);
                },
            }
        }
        self.alloc.destroy(self);
    }
}

fn commonNext(comptime T: type, comptime direction: common.IteratorKind, self: *T, alloc: std.mem.Allocator) !?IteratorResult_ {
    if (self._invalid.load(.seq_cst)) return error.IteratorInvalid;
    self.buffer.m.lock();
    defer self.buffer.m.unlock();

    if (direction == .lineIterator) {
        const next_index: IteratorIndex_ = switch (self.line_index) {
            .start => .{ .index = 0 },
            .index => |i| .{ .index = i +| 1 },
            .end => unreachable,
        };
        if (!self._checkBounds(next_index.index)) return null;
        self.line_index = next_index;
    } else if (direction == .reverseLineIterator) {
        const next_index: IteratorIndex_ = switch (self.line_index) {
            .start => .{ .index = self.buffer.filtered_buffer.countLines() - 1 },
            .index => |i| if (i == 0) .end else .{ .index = i -| 1 },
            .end => return null,
        };

        if (next_index == .end) {
            self.line_index = next_index;
            return null;
        } else if (self._checkBounds(next_index.index)) {
            return null;
        } else {
            self.line_index = next_index;
        }
    }

    const result = try self._peek() orelse return null;

    return .{
        .line = try alloc.dupe(u8, result.line),
        .buffer_offset = result.buffer_offset,
    };
}

fn commonPrev(comptime T: type, comptime direction: common.IteratorKind, self: *T, alloc: std.mem.Allocator) !?IteratorResult_ {
    if (self._invalid.load(.seq_cst)) return error.IteratorInvalid;
    self.buffer.m.lock();
    defer self.buffer.m.unlock();

    if (direction == .lineIterator) {
        const next_index: IteratorIndex_ = switch (self.line_index) {
            .start => return null,
            .index => |i| if (i == 0) .start else .{ .index = i -| 1 },
            .end => unreachable,
        };

        if (next_index == .start) {
            self.line_index = next_index;
            return null;
        } else if (!self._checkBounds(next_index.index)) {
            return null;
        } else {
            self.line_index = next_index;
        }
    } else if (direction == .reverseLineIterator) {
        const next_index: IteratorIndex_ = switch (self.line_index) {
            .start => return null,
            .index => |i| .{ .index = i +| 1 },
            .end => .{ .index = 0 },
        };

        if (!self._checkBounds(next_index.index)) return null;
        self.line_index = next_index;
    }

    const result = try self._peek() orelse return null;

    return .{
        .line = try alloc.dupe(u8, result.line),
        .buffer_offset = result.buffer_offset,
    };
}

pub const IteratorResult_ = struct {
    line: []const u8,
    buffer_offset: usize,
};

pub const IteratorIndex_ = union(enum) {
    start: void,
    end: void,
    index: usize,
};

//  - m: mutex
//  - alloc: Allocator

// This is a generic iterator class that creates iterators over a LineBuffer
// And expects there to be an ArrayList(IteratorRecord) backing the ownership of all iterators
pub fn LineIteratorsClass(
    comptime T: type,
    comptime linebuffer_fieldname: []const u8,
    comptime ownership_array_fieldname: []const u8,
) type {
    // assert type info for ProcesBuffer
    if (!@hasField(T, linebuffer_fieldname))
        @compileError(@typeName(T) ++ "Must contain a LineBuffer as " ++ linebuffer_fieldname);

    if (!@hasField(T, "alloc"))
        @compileError(@typeName(T) ++ "Must contain an Allocator called alloc");

    if (!@hasField(T, "m"))
        @compileError(@typeName(T) ++ "Must contain a mutex field called m");

    if (!@hasField(T, ownership_array_fieldname))
        @compileError(@typeName(T) ++ "Must contain an array of IteratorRecords called " ++ ownership_array_fieldname);

    return struct {
        pub const IteratorIndex = IteratorIndex_;
        pub const IteratorResult = IteratorResult_;
        pub const IteratorKind = common.IteratorKind;

        pub const IteratorPtr = union(IteratorKind) {
            lineIterator: *LineIterator,
            reverseLineIterator: *ReverseLineIterator,
        };

        pub const LineIterator = struct {
            alloc: std.mem.Allocator,
            buffer: *T,
            line_index: IteratorIndex,
            _invalid: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

            pub fn init(alloc: std.mem.Allocator, pProcessBuffer: *T) !*@This() {
                return commonInit(
                    @This(),
                    ownership_array_fieldname,
                    .lineIterator,
                    alloc,
                    pProcessBuffer,
                );
            }

            pub fn deinit(self: *@This()) void {
                commonDeinit(
                    @This(),
                    ownership_array_fieldname,
                    self,
                    .lineIterator,
                );
            }

            pub fn next(self: *@This(), alloc: std.mem.Allocator) !?IteratorResult {
                return commonNext(@This(), .lineIterator, self, alloc);
            }

            pub fn prev(self: *@This(), alloc: std.mem.Allocator) !?IteratorResult {
                return try commonPrev(@This(), .lineIterator, self, alloc);
            }

            pub fn peek(self: *@This(), alloc: std.mem.Allocator) !?IteratorResult {
                return commonPeek(self, alloc);
            }

            pub fn _checkBounds(self: *@This(), line_index: usize) bool {
                var buf_backing = @field(self.buffer, linebuffer_fieldname);
                return if (line_index >= buf_backing.countLines()) false else true;
            }

            fn _peek(self: *@This()) !?IteratorResult {
                var buf_backing = @field(self.buffer, linebuffer_fieldname);

                if (self._invalid.load(.seq_cst)) return error.IteratorInvalid;
                if (self.line_index == .start) return null;
                if (self.line_index == .end) return null;
                if (self.line_index.index >= buf_backing.countLines()) return null;

                std.log.debug("peek: index = {d} filter_buffer_num_lines = {d}", .{ self.line_index.index, self.buffer.filtered_buffer.countLines() });

                return .{
                    .line = buf_backing.getLine(self.line_index.index).?,
                    .buffer_offset = buf_backing.getIndexOfLine(self.line_index.index).?,
                };
            }

            pub fn setLine(self: *@This(), line_num: usize) !void {
                var buf_backing = @field(self.buffer, linebuffer_fieldname);

                self.buffer.m.lock();
                defer self.buffer.m.unlock();
                // validate that the line number is within bounds
                if (line_num >= buf_backing.countLines()) return error.OutOfRange;
                self.line_index = .{ .index = line_num };
            }

            pub fn reset(self: *@This()) void {
                commonReset(self, 0);
            }

            pub fn invalidate(self: *@This()) void {
                commonInvalidate(self);
            }
        };

        pub const ReverseLineIterator = struct {
            alloc: std.mem.Allocator,
            buffer: *T,
            line_index: IteratorIndex_,
            _invalid: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

            pub fn init(alloc: std.mem.Allocator, pProcessBuffer: *T) !*@This() {
                return commonInit(
                    @This(),
                    ownership_array_fieldname,
                    .lineIterator,
                    alloc,
                    pProcessBuffer,
                );
            }

            pub fn deinit(self: *@This()) void {
                commonDeinit(
                    @This(),
                    ownership_array_fieldname,
                    self,
                    .lineIterator,
                );
            }

            pub fn next(self: *@This(), alloc: std.mem.Allocator) !?IteratorResult {
                return commonNext(@This(), .lineIterator, self, alloc);
            }

            pub fn prev(self: *@This(), alloc: std.mem.Allocator) !?IteratorResult {
                return try commonPrev(@This(), .lineIterator, self, alloc);
            }

            pub fn peek(self: *@This(), alloc: std.mem.Allocator) !?IteratorResult {
                return commonPeek(self, alloc);
            }

            fn _checkBounds(self: *@This(), line_index: usize) bool {
                var buf_backing = @field(self.buffer, linebuffer_fieldname);

                return if (line_index >= buf_backing.countLines()) false else true;
            }

            fn _peek(self: *@This()) !?IteratorResult {
                var buf_backing = @field(self.buffer, linebuffer_fieldname);

                if (self._invalid.load(.seq_cst)) return error.IteratorInvalid;
                //if (self.line_index == 0) return null;
                if (self.line_index.index >= buf_backing.countLines()) return null;

                return .{
                    .line = buf_backing.getLine(self.line_index.index).?,
                    .buffer_offset = buf_backing.getIndexOfLine(self.line_index.index).?,
                };
            }

            pub fn reset(self: *@This()) void {
                commonReset(self, 0);
            }

            pub fn setLine(self: *@This(), line_num: usize) !void {
                const buf_backing = @field(self.buffer, linebuffer_fieldname);

                self.buffer.m.lock();
                defer self.buffer.m.unlock();
                const internal_index = line_num + 1;
                // validate that the line number is within bounds
                if (internal_index >= buf_backing.countLines()) return error.OutOfRange;
                self.line_index = .{ .index = line_num };
            }

            pub fn invalidate(self: *@This()) void {
                commonInvalidate(self);
            }
        };
    };
}
