const std = @import("std");
const Regex = @import("regex").Regex;
const processbuffer = @import("processbuffer.zig");
const helpers = @import("../helpers.zig");

const ProcessBuffer = processbuffer.ProcessBuffer;

const RegexIterator = helpers.RegexIterator;

// how do I want to use this

// FIND
// iter = ProcessBufferSearchIterator.init(alloc, &regex, line_iter)
// result = iter.next
// jump_to(result.lowerBound, result.upperBound)                        <- todo
// highlight(result.lowerBound, result.upperBound)                      <- todo
// deHighlight...                                                       <- todo
// output.save(iter)

// NEXT
// if iter
// result = iter.next()
// jump_to(result.lowerBound, result.upperBound)
// highlight(result.lowerBound, result.upperBound)
// deHighlight...
// output.save(iter)

// PREV
// if iter
// result = iter.prev()
// jump_to(result.lowerBound, result.upperBound)
// highlight(result.lowerBound, result.upperBound)
// deHighlight...
// output.save(iter)

pub fn startSearchFrom(alloc: std.mem.Allocator, process_buffer: *ProcessBuffer, regex: *Regex, line_num: usize) *ProcessBufferSearchIterator {
    var iter = ProcessBufferSearchIterator.init(
        alloc,
        regex,
        .{ .lineIterator = try ProcessBuffer.LineIterator.init(alloc, process_buffer) },
    );
    try iter.line_iter.lineIterator.setLine(line_num);
    return iter;
}

// TODO: I just want this to actually have a next, prev in the same iterator
pub const ProcessBufferSearchIterator = struct {
    alloc: std.mem.Allocator,
    regex: *Regex,
    line_iter: ProcessBuffer.IteratorPtr,
    line_offset: usize = 0,
    match_iter: ?RegexIterator = null,

    const Result = struct {
        str: []const u8,
        lowerBound: usize,
        upperBound: usize,
    };

    pub fn init(
        alloc: std.mem.Allocator,
        re: *Regex,
        line_iter: ProcessBuffer.IteratorPtr,
    ) ProcessBufferSearchIterator {
        return .{
            .alloc = alloc,
            .regex = re,
            .line_iter = line_iter,
        };
    }

    pub fn deinit(self: *ProcessBufferSearchIterator) void {
        // free the allocated line
        if (self.match_iter) |iter| {
            self.alloc.free(iter.input);
        }

        switch (self.line_iter) {
            .lineIterator => |i| {
                i.deinit();
            },
            .reverseLineIterator => |i| {
                i.deinit();
            },
        }
    }

    pub fn next(self: *ProcessBufferSearchIterator) !?Result {
        while (true) {
            if (self.match_iter) |*iter| {
                if (try iter.next()) |match| {
                    return .{
                        .str = match.str,
                        .lowerBound = self.line_offset + match.lowerBound,
                        .upperBound = self.line_offset + match.upperBound,
                    };
                } else {
                    self.match_iter = null; // Exhausted current line
                }
            }

            switch (self.line_iter) {
                .lineIterator => |p| {
                    if (try p.next()) |result| {
                        if (self.match_iter) |m| self.alloc.free(m.input);

                        self.match_iter = RegexIterator{
                            .regex = self.regex,
                            .input = result.line,
                        };
                        self.line_offset = result.buffer_offset;
                        continue;
                    }
                },
                .reverseLineIterator => |p| {
                    // TODO: this one is a bit more complicated - we need to cache all matches in the line
                    if (try p.next()) |result| {
                        if (self.match_iter) |m| self.alloc.free(m.input);

                        self.match_iter = RegexIterator{
                            .regex = self.regex,
                            .input = result.line,
                        };
                        self.line_offset = result.buffer_offset;
                        continue;
                    }
                },
            }
        }
    }

    //pub fn prev(self: *ProcessBufferSearchIterator) !?Result {
    //    // TODO!
    //}
};
