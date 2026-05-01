// This file is required to break circular dependancies in lineiterators.zig
pub const IteratorKind = enum {
    lineIterator,
    reverseLineIterator,
};

pub const IteratorRecord = struct {
    kind: IteratorKind,
    ptr: *anyopaque,
};
