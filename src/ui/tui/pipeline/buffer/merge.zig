//! k-way merge of several parents' lines by ingest sequence number.
//!
//! Every line in every buffer carries the global sequence number the pump assigned when the
//! line was completed, so merging by that number reproduces arrival order exactly. Because
//! the pump is the only writer, everything up to each parent's current line count is in the
//! result and any later propagation carries strictly newer numbers: no watermarks needed.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ProcessBuffer = @import("../processbuffer.zig").ProcessBuffer;
const LineBuffer = @import("../linebuffer.zig").LineBuffer;

pub fn mergeBySeq(
    alloc: Allocator,
    parents: []const *ProcessBuffer,
    out_buf: *LineBuffer,
    out_seqs: *std.ArrayList(u64),
) Allocator.Error!void {
    const cursors = try alloc.alloc(usize, parents.len);
    defer alloc.free(cursors);
    @memset(cursors, 0);

    while (true) {
        var best: ?usize = null;
        var best_seq: u64 = std.math.maxInt(u64);
        for (parents, 0..) |p, i| {
            if (cursors[i] >= p.line_seqs.items.len) continue;
            const seq = p.line_seqs.items[cursors[i]];
            if (seq < best_seq) {
                best_seq = seq;
                best = i;
            }
        }
        const i = best orelse break;
        const parent = parents[i];
        try out_buf.append(parent.buffer.getLineWithSep(cursors[i]).?);
        try out_seqs.append(alloc, best_seq);
        cursors[i] += 1;
    }
}

const testing = std.testing;

test "mergeBySeq interleaves parents by sequence number" {
    const alloc = testing.allocator;
    const io = testing.io;

    const a = try ProcessBuffer.init(io, alloc);
    defer a.deinit();
    const b = try ProcessBuffer.init(io, alloc);
    defer b.deinit();

    var seq: u64 = 0;
    _ = try a.appendChunk("a1\na2\n", &seq);
    _ = try b.appendChunk("b3\n", &seq);
    _ = try a.appendChunk("a4\n", &seq);

    var out = try LineBuffer.init(alloc);
    defer out.deinit();
    var seqs: std.ArrayList(u64) = .empty;
    defer seqs.deinit(alloc);

    try mergeBySeq(alloc, &.{ a, b }, &out, &seqs);
    try testing.expectEqualStrings("a1\na2\nb3\na4\n", out.buf.items);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4 }, seqs.items);
}
