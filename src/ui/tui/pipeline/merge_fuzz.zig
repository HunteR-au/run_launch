//! Model-based fuzzing of the merge machinery in the ingest store.
//!
//! A random script of operations (announce buffers, write chunks, create merges over random
//! parents, remove buffers, end processes, and the invalid variants of each) runs against a
//! real `IngestStore`, driven directly without a pump thread, and against a small reference
//! model. After every step each live buffer's complete lines, sequence numbers, tail, name
//! and merge links must match the model, and the UI must have been told about exactly the
//! buffers that appeared, disappeared or failed. The model is the specification:
//!
//! - a process buffer holds its bytes with every CRLF turned into LF, split into complete
//!   lines; each line is numbered by a store-wide counter when it completes;
//! - a merge starts as the union of its parents' lines in sequence order, each line once, and
//!   from then on receives every new line of every buffer it descends from, once;
//! - removing a buffer unlinks it; merges built on it keep the lines they already have.
//!
//! `zig build test` runs a hundred seeded scripts. `zig build test --fuzz=100K
//! -Doptimize=ReleaseSafe` hands the same script to the coverage-guided fuzzer through
//! `std.testing.fuzz` (Linux; ReleaseSafe because only the LLVM backend instruments for
//! coverage). Zig 0.16.0's own test runner does not compile in fuzz mode: in
//! lib/compiler/test_runner.zig, `std.debug.writeStackTrace(trace, stderr)` in `fuzz` must
//! read `std.debug.writeErrorReturnTrace(trace, stderr)`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ingeststore = @import("ingeststore.zig");

const IngestStore = ingeststore.IngestStore;
const UiInbox = ingeststore.UiInbox;
const UUID = ingeststore.UUID;
const Term = ingeststore.Term;
const Stream = ingeststore.Stream;

const testing = std.testing;

/// Seeded scripts per `zig build test` run, and the length of each.
const seeded_runs = 100;
const seeded_ops = 120;
/// Upper bound on one fuzzer-driven script.
const fuzz_ops = 200;

// ------------------------------------------------------------------
// Input: a seeded PRNG for `zig build test`, the fuzzer's Smith under `--fuzz`
// ------------------------------------------------------------------

const Input = struct {
    source: union(enum) { prng: std.Random, smith: *testing.Smith },
    ops_left: usize,

    /// A value in [lo, hi]. `hash` names the decision for the fuzzer.
    fn int(self: *Input, comptime hash: u32, lo: u32, hi: u32) u32 {
        return switch (self.source) {
            .prng => |r| r.intRangeAtMost(u32, lo, hi),
            .smith => |s| s.valueRangeAtMostWithHash(u32, lo, hi, hash),
        };
    }

    fn chance(self: *Input, comptime hash: u32, percent: u32) bool {
        return self.int(hash, 0, 99) < percent;
    }

    fn more(self: *Input) bool {
        if (self.ops_left == 0) return false;
        self.ops_left -= 1;
        return switch (self.source) {
            .prng => true,
            .smith => |s| !s.eosWithHash(0x0e05_0001),
        };
    }
};

// ------------------------------------------------------------------
// The reference model
// ------------------------------------------------------------------

const Line = struct {
    seq: u64,
    /// including the trailing '\n'
    text: []const u8,
};

const Buf = struct {
    id: UUID,
    name: []const u8,
    merge: bool,
    alive: bool = true,
    /// process buffers: every byte written, in order
    stream: std.ArrayList(u8) = .empty,
    /// `stream` with every CRLF turned into LF, refreshed on each write
    norm: []const u8 = "",
    lines: std.ArrayList(Line) = .empty,
    /// live links, as model indices
    parents: std.ArrayList(usize) = .empty,
    children: std.ArrayList(usize) = .empty,
    eof: [2]bool = .{ false, false },
    exited: bool = false,
    term: ?Term = null,
    ended: bool = false,
    /// lines already compared with the store
    verified: usize = 0,
};

const Model = struct {
    /// the run's arena: nothing in the model is freed individually
    alloc: Allocator,
    bufs: std.ArrayList(Buf) = .empty,
    next_seq: u64 = 0,
    next_id: u32 = 1,

    fn newId(self: *Model) UUID {
        var id: UUID = .{ .bytes = [_]u8{0xa5} ** 16 };
        std.mem.writeInt(u32, id.bytes[0..4], self.next_id, .little);
        self.next_id += 1;
        return id;
    }

    fn find(self: *Model, id: UUID) ?usize {
        for (self.bufs.items, 0..) |b, i| {
            if (std.meta.eql(b.id, id)) return i;
        }
        return null;
    }

    fn addSource(self: *Model, id: UUID, name: []const u8) !usize {
        try self.bufs.append(self.alloc, .{ .id = id, .name = try self.alloc.dupe(u8, name), .merge = false });
        return self.bufs.items.len - 1;
    }

    /// The bytes a process wrote, as the store must keep them: every CRLF becomes LF.
    fn normalise(self: *Model, bytes: []const u8) ![]u8 {
        var out = try std.ArrayList(u8).initCapacity(self.alloc, bytes.len);
        for (bytes, 0..) |c, i| {
            if (c == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') continue;
            out.appendAssumeCapacity(c);
        }
        return out.items;
    }

    /// The incomplete last line. A trailing '\r' is held back until the next byte shows
    /// whether it starts a CRLF.
    fn tail(self: *Model, b: usize) []const u8 {
        const norm = self.bufs.items[b].norm;
        const start = if (std.mem.lastIndexOfScalar(u8, norm, '\n')) |i| i + 1 else 0;
        var t = norm[start..];
        if (t.len > 0 and t[t.len - 1] == '\r') t = t[0 .. t.len - 1];
        return t;
    }

    fn write(self: *Model, b: usize, chunk: []const u8) !void {
        const buf = &self.bufs.items[b];
        try buf.stream.appendSlice(self.alloc, chunk);
        buf.norm = try self.normalise(buf.stream.items);
        const fresh_count = std.mem.count(u8, chunk, "\n");
        if (fresh_count == 0) return;

        const norm = buf.norm;
        const total = std.mem.count(u8, norm, "\n");
        var fresh = try std.ArrayList(Line).initCapacity(self.alloc, fresh_count);
        var line_start: usize = 0;
        var n: usize = 0;
        for (norm, 0..) |c, i| {
            if (c != '\n') continue;
            if (n >= total - fresh_count) {
                self.next_seq += 1;
                fresh.appendAssumeCapacity(.{ .seq = self.next_seq, .text = norm[line_start .. i + 1] });
            }
            n += 1;
            line_start = i + 1;
        }
        try self.deliver(b, fresh.items);
    }

    /// The buffer and every buffer descending from it get `fresh`, once each.
    fn deliver(self: *Model, from: usize, fresh: []const Line) !void {
        const seen = try self.alloc.alloc(bool, self.bufs.items.len);
        @memset(seen, false);
        var queue: std.ArrayList(usize) = .empty;
        try queue.append(self.alloc, from);
        seen[from] = true;
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const b = &self.bufs.items[queue.items[qi]];
            try b.lines.appendSlice(self.alloc, fresh);
            for (b.children.items) |c| {
                if (seen[c]) continue;
                seen[c] = true;
                try queue.append(self.alloc, c);
            }
        }
    }

    fn addMerge(self: *Model, id: UUID, name: []const u8, parents: []const usize) !void {
        var all: std.ArrayList(Line) = .empty;
        for (parents) |p| try all.appendSlice(self.alloc, self.bufs.items[p].lines.items);
        std.mem.sort(Line, all.items, {}, struct {
            fn lessThan(_: void, a: Line, b: Line) bool {
                return a.seq < b.seq;
            }
        }.lessThan);
        var lines: std.ArrayList(Line) = .empty;
        for (all.items) |l| {
            if (lines.items.len > 0 and lines.items[lines.items.len - 1].seq == l.seq) continue;
            try lines.append(self.alloc, l);
        }

        const index = self.bufs.items.len;
        var parent_list: std.ArrayList(usize) = .empty;
        try parent_list.appendSlice(self.alloc, parents);
        try self.bufs.append(self.alloc, .{
            .id = id,
            .name = try self.alloc.dupe(u8, name),
            .merge = true,
            .lines = lines,
            .parents = parent_list,
        });
        for (parents) |p| try self.bufs.items[p].children.append(self.alloc, index);
    }

    fn remove(self: *Model, b: usize) void {
        const buf = &self.bufs.items[b];
        buf.alive = false;
        for (buf.parents.items) |p| unlink(&self.bufs.items[p].children, b);
        for (buf.children.items) |c| unlink(&self.bufs.items[c].parents, b);
        buf.parents.clearRetainingCapacity();
        buf.children.clearRetainingCapacity();
    }

    fn unlink(list: *std.ArrayList(usize), b: usize) void {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i] == b) _ = list.orderedRemove(i) else i += 1;
        }
    }

    /// The end-of-process line, once both streams ended and the process was reaped.
    fn maybeEnd(self: *Model, b: usize) !void {
        const buf = &self.bufs.items[b];
        if (buf.ended or !buf.exited or !buf.eof[0] or !buf.eof[1]) return;
        buf.ended = true;
        const line = if (buf.term) |t| switch (t) {
            .exited => |code| try std.fmt.allocPrint(self.alloc, "--- process exited: code {d} ---\n", .{code}),
            else => unreachable, // only exit codes are generated
        } else "--- process ended: wait failed ---\n";
        try self.write(b, line);
    }
};

// ------------------------------------------------------------------
// The harness: drives the store and the model side by side
// ------------------------------------------------------------------

const Expected = struct { created: usize = 0, removed: usize = 0, failed: usize = 0 };

const Harness = struct {
    store: *IngestStore,
    model: Model,
    /// one line per operation, printed when a check fails
    log: std.ArrayList(u8) = .empty,
    chunk_buf: [1024]u8 = undefined,

    fn note(self: *Harness, comptime fmt: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(self.model.alloc, fmt ++ "\n", args);
        try self.log.appendSlice(self.model.alloc, line);
    }

    fn label(self: *Harness, b: usize) []const u8 {
        return self.model.bufs.items[b].name;
    }

    /// A random live buffer, process or merge as asked (null: either).
    fn pick(self: *Harness, in: *Input, comptime hash: u32, merge: ?bool) ?usize {
        var count: u32 = 0;
        for (self.model.bufs.items) |b| {
            if (b.alive and (merge == null or b.merge == merge.?)) count += 1;
        }
        if (count == 0) return null;
        var k = in.int(hash, 0, count - 1);
        for (self.model.bufs.items, 0..) |b, i| {
            if (!(b.alive and (merge == null or b.merge == merge.?))) continue;
            if (k == 0) return i;
            k -= 1;
        }
        unreachable;
    }

    fn chunk(self: *Harness, in: *Input) []const u8 {
        var len: usize = 0;
        const pieces = in.int(0x0c00_0001, 1, 8);
        for (0..pieces) |_| {
            var word: [8]u8 = undefined;
            const piece: []const u8 = switch (in.int(0x0c00_0002, 0, 13)) {
                0, 1, 2 => blk: {
                    const n = in.int(0x0c00_0003, 1, word.len);
                    for (word[0..n]) |*c| c.* = "abcxyz019 -"[in.int(0x0c00_0004, 0, 10)];
                    break :blk word[0..n];
                },
                3, 4, 5 => "\n",
                6 => "\r\n",
                7 => "\r",
                8 => "\n\n",
                9 => "\x1b[31m",
                10 => "\x1b[0m",
                11 => "\xc3\xa9",
                12 => "\t",
                13 => "long-line-" ** 12,
                else => unreachable,
            };
            if (len + piece.len > self.chunk_buf.len) break;
            @memcpy(self.chunk_buf[len..][0..piece.len], piece);
            len += piece.len;
        }
        return self.chunk_buf[0..len];
    }

    fn step(self: *Harness, in: *Input) !void {
        const s = self.store.sink();
        var expected: Expected = .{};
        switch (in.int(0x0b00_0001, 0, 99)) {
            // a process announces its buffer
            0...11 => {
                const id = self.model.newId();
                const name = try std.fmt.allocPrint(self.model.alloc, "p{d}", .{self.model.next_id - 1});
                try self.note("announce {s}", .{name});
                s.vtable.createBuffer(s.ctx, id, name);
                _ = try self.model.addSource(id, name);
                expected.created = 1;
            },
            // a process writes
            12...54 => {
                const b = self.pick(in, 0x0b00_0002, false) orelse return;
                const bytes = self.chunk(in);
                try self.note("write {s} \"{f}\"", .{ self.label(b), std.zig.fmtString(bytes) });
                s.vtable.bytes(s.ctx, self.model.bufs.items[b].id, .stdout, bytes);
                try self.model.write(b, bytes);
            },
            // merge 1-4 live buffers
            55...69 => {
                var parents: [4]usize = undefined;
                var n: usize = 0;
                const want = in.int(0x0b00_0003, 1, 4);
                for (0..want) |_| {
                    const p = self.pick(in, 0x0b00_0004, null) orelse break;
                    if (std.mem.indexOfScalar(usize, parents[0..n], p) != null) continue;
                    parents[n] = p;
                    n += 1;
                }
                if (n == 0) return;
                const id = self.model.newId();
                const name = try std.fmt.allocPrint(self.model.alloc, "m{d}", .{self.model.next_id - 1});
                try self.note("merge {s} = {f}", .{ name, Names{ .h = self, .list = parents[0..n] } });
                try self.createMerge(id, name, parents[0..n]);
                try self.model.addMerge(id, name, parents[0..n]);
                expected.created = 1;
            },
            // remove a buffer (a stopped process or a closed merged view)
            70...79 => {
                const b = self.pick(in, 0x0b00_0005, null) orelse return;
                try self.note("remove {s}", .{self.label(b)});
                try self.store.execute(.{ .remove_buffer = .{ .id = self.model.bufs.items[b].id } });
                self.model.remove(b);
                expected.removed = 1;
            },
            // a process' streams end and it is reaped, in any order
            80...87 => {
                const b = self.pick(in, 0x0b00_0006, false) orelse return;
                const id = self.model.bufs.items[b].id;
                switch (in.int(0x0b00_0007, 0, 3)) {
                    0, 1 => |which| {
                        const stream: Stream = if (which == 0) .stdout else .stderr;
                        const failed = in.chance(0x0b00_0008, 20);
                        try self.note("eof {s} {t}{s}", .{ self.label(b), stream, if (failed) " (read error)" else "" });
                        s.vtable.streamEof(s.ctx, id, stream, if (failed) error.InputOutput else null);
                        if (failed) {
                            const line = try std.fmt.allocPrint(self.model.alloc, "!!! {t} read error: InputOutput !!!\n", .{stream});
                            try self.model.write(b, line);
                        }
                        self.model.bufs.items[b].eof[which] = true;
                    },
                    else => {
                        const term: ?Term = if (in.chance(0x0b00_0009, 15)) null else .{ .exited = @intCast(in.int(0x0b00_000a, 0, 255)) };
                        try self.note("exit {s}", .{self.label(b)});
                        s.vtable.processExited(s.ctx, id, term);
                        self.model.bufs.items[b].exited = true;
                        self.model.bufs.items[b].term = term;
                    },
                }
                try self.model.maybeEnd(b);
            },
            // output arrives before the announcement: an anonymous buffer, named later
            88...91 => {
                const id = self.model.newId();
                const bytes = self.chunk(in);
                try self.note("early write \"{f}\"", .{std.zig.fmtString(bytes)});
                s.vtable.bytes(s.ctx, id, .stdout, bytes);
                const b = try self.model.addSource(id, "?");
                try self.model.write(b, bytes);
                expected.created = 1;
                if (in.chance(0x0b00_000b, 70)) {
                    const name = try std.fmt.allocPrint(self.model.alloc, "late{d}", .{self.model.next_id});
                    try self.note("announce it as {s}", .{name});
                    s.vtable.createBuffer(s.ctx, id, name);
                    self.model.bufs.items[b].name = name;
                }
            },
            // a removed process still has output or an announcement in flight: ignored
            92...95 => {
                var dead: ?usize = null;
                for (self.model.bufs.items, 0..) |b, i| {
                    if (!b.alive and !b.merge) dead = i;
                }
                const b = dead orelse return;
                const id = self.model.bufs.items[b].id;
                try self.note("late output for removed {s}", .{self.label(b)});
                s.vtable.bytes(s.ctx, id, .stdout, "late\n");
                s.vtable.createBuffer(s.ctx, id, "late");
                s.vtable.streamEof(s.ctx, id, .stdout, null);
            },
            // merges the store must refuse
            96...99 => {
                const id = self.model.newId();
                const name = try std.fmt.allocPrint(self.model.alloc, "bad{d}", .{self.model.next_id - 1});
                switch (in.int(0x0b00_000c, 0, 3)) {
                    0 => {
                        try self.note("merge {s} with an unknown parent", .{name});
                        const live = self.pick(in, 0x0b00_000d, null);
                        var ids: [2]UUID = .{ self.model.newId(), undefined };
                        var n: usize = 1;
                        if (live) |p| {
                            ids[1] = self.model.bufs.items[p].id;
                            n = 2;
                        }
                        try self.createMergeIds(id, name, ids[0..n]);
                    },
                    1 => {
                        const p = self.pick(in, 0x0b00_000e, null) orelse return;
                        try self.note("merge {s} with {s} twice", .{ name, self.label(p) });
                        const pid = self.model.bufs.items[p].id;
                        try self.createMergeIds(id, name, &.{ pid, pid });
                    },
                    2 => {
                        try self.note("merge {s} with no parents", .{name});
                        try self.createMergeIds(id, name, &.{});
                    },
                    else => {
                        const existing = self.pick(in, 0x0b00_000f, null) orelse return;
                        const p = self.pick(in, 0x0b00_0010, null) orelse return;
                        try self.note("merge reusing the id of {s}", .{self.label(existing)});
                        try self.createMergeIds(self.model.bufs.items[existing].id, name, &.{self.model.bufs.items[p].id});
                    },
                }
                expected.failed = 1;
            },
            else => unreachable,
        }
        try self.checkEvents(expected);
    }

    fn createMerge(self: *Harness, id: UUID, name: []const u8, parents: []const usize) !void {
        var ids: [4]UUID = undefined;
        for (parents, 0..) |p, i| ids[i] = self.model.bufs.items[p].id;
        try self.createMergeIds(id, name, ids[0..parents.len]);
    }

    /// The command takes ownership of its payload, allocated the way the merge action does.
    fn createMergeIds(self: *Harness, id: UUID, name: []const u8, parents: []const UUID) !void {
        const alloc = self.store.alloc;
        const name_copy = try alloc.dupe(u8, name);
        const parent_copy = try alloc.dupe(UUID, parents);
        try self.store.execute(.{ .create_merge = .{ .id = id, .name = name_copy, .parents = parent_copy } });
    }

    fn checkEvents(self: *Harness, expected: Expected) !void {
        var events = self.store.inbox.drain();
        defer events.deinit(self.store.alloc);
        defer for (events.items) |ev| UiInbox.freeEvent(self.store.alloc, ev);
        var got: Expected = .{};
        for (events.items) |ev| switch (ev) {
            .buffer_created => got.created += 1,
            .buffer_removed => got.removed += 1,
            .command_failed => got.failed += 1,
        };
        if (!std.meta.eql(got, expected)) {
            return self.fail("UI events: expected {any}, got {any}", .{ expected, got });
        }
    }

    fn fail(self: *Harness, comptime fmt: []const u8, args: anytype) error{TestUnexpectedResult} {
        std.debug.print("\n=== merge fuzz: " ++ fmt ++ "\n--- script ---\n{s}--------------\n", args ++ .{self.log.items});
        return error.TestUnexpectedResult;
    }

    /// Compares the store with the model. Lines only ever get appended, so after each step
    /// only the lines added since the last check are compared; `full` compares them all.
    fn check(self: *Harness, full: bool) !void {
        for (self.model.bufs.items, 0..) |*mb, index| {
            const found = self.store.map.get(mb.id);
            if (!mb.alive) {
                if (found != null) return self.fail("{s} was removed but is still in the store", .{mb.name});
                continue;
            }
            const pb = found orelse return self.fail("{s} is missing from the store", .{mb.name});

            if (!std.mem.eql(u8, pb.displayName(), mb.name)) {
                return self.fail("{s}: store name is \"{s}\"", .{ mb.name, pb.displayName() });
            }
            const lines = pb.buffer.countLines();
            if (pb.line_seqs.items.len != lines) {
                return self.fail("{s}: {d} lines but {d} sequence numbers", .{ mb.name, lines, pb.line_seqs.items.len });
            }
            const from = if (full) 0 else @min(mb.verified, lines);
            for (@min(@max(from, 1), lines)..lines) |i| {
                const seq = pb.line_seqs.items[i];
                if (seq <= pb.line_seqs.items[i - 1]) {
                    return self.fail("{s}: sequence numbers not increasing at line {d}: {d} after {d}", .{ mb.name, i, seq, pb.line_seqs.items[i - 1] });
                }
            }
            const want = mb.lines.items;
            for (from..@min(lines, want.len)) |i| {
                const got_text = pb.buffer.getLineWithSep(i).?;
                if (pb.line_seqs.items[i] != want[i].seq or !std.mem.eql(u8, got_text, want[i].text)) {
                    return self.fail("{s}: line {d} is #{d} \"{f}\", expected #{d} \"{f}\"", .{
                        mb.name,               i,
                        pb.line_seqs.items[i], std.zig.fmtString(got_text),
                        want[i].seq,           std.zig.fmtString(want[i].text),
                    });
                }
            }
            if (lines != want.len) return self.fail("{s}: {d} lines, expected {d}", .{ mb.name, lines, want.len });
            mb.verified = lines;

            const want_tail: []const u8 = if (mb.merge) "" else self.model.tail(index);
            const got_tail = pb.buffer.getTail() orelse "";
            if (!std.mem.eql(u8, got_tail, want_tail)) {
                return self.fail("{s}: tail \"{f}\", expected \"{f}\"", .{ mb.name, std.zig.fmtString(got_tail), std.zig.fmtString(want_tail) });
            }
            if (pb.published.raw_lines.load(.acquire) != lines) return self.fail("{s}: published line count is stale", .{mb.name});
            if (pb.lines_processed != lines) return self.fail("{s}: pipeline processed {d} of {d} lines", .{ mb.name, pb.lines_processed, lines });

            // the store's merge graph links exactly the model's live parents
            const handle = pb.handle orelse return self.fail("{s}: no graph node", .{mb.name});
            var parent_count: usize = 0;
            var it = self.store.graph.parents(handle) orelse return self.fail("{s}: stale graph node", .{mb.name});
            while (it.next()) |ph| {
                parent_count += 1;
                const parent = self.store.graph.getObject(ph).?;
                var listed = false;
                for (mb.parents.items) |p| {
                    if (std.meta.eql(self.model.bufs.items[p].id, parent.id.?)) listed = true;
                }
                if (!listed) return self.fail("{s}: linked to unexpected parent {s}", .{ mb.name, parent.displayName() });
            }
            if (parent_count != mb.parents.items.len) {
                return self.fail("{s}: {d} parent links, expected {d}", .{ mb.name, parent_count, mb.parents.items.len });
            }
        }
    }
};

const Names = struct {
    h: *Harness,
    list: []const usize,

    pub fn format(self: Names, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.list, 0..) |b, i| {
            if (i > 0) try w.writeAll(" + ");
            try w.writeAll(self.h.label(b));
        }
    }
};

fn runScript(alloc: Allocator, io: Io, input: Input) !void {
    // The refused merges are expected; keep their warnings out of the test output (the
    // build runner shows a test's stderr under a misleading "failed command" line).
    testing.log_level = .err;
    defer testing.log_level = .warn;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const store = try IngestStore.init(alloc, io);
    defer store.deinit();

    var h: Harness = .{ .store = store, .model = .{ .alloc = arena_state.allocator() } };
    var in = input;
    while (in.more()) {
        try h.step(&in);
        try h.check(false);
    }
    try h.check(true);
}

test "merge fuzz: seeded scripts agree with the reference model" {
    for (0..seeded_runs) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        runScript(testing.allocator, testing.io, .{ .source = .{ .prng = prng.random() }, .ops_left = seeded_ops }) catch |err| {
            std.debug.print("(seed {d})\n", .{seed});
            return err;
        };
    }
}

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    try runScript(testing.allocator, testing.io, .{ .source = .{ .smith = smith }, .ops_left = fuzz_ops });
}

test "merge fuzz: coverage-guided (zig build test --fuzz)" {
    try testing.fuzz({}, fuzzOne, .{});
}
