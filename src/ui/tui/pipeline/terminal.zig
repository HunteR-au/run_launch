//! Terminal interpretation stage of the ingest pipeline (pump thread only).
//!
//! Turns one raw output line into the text a terminal would have shown for it, plus the
//! colour marks the program's own SGR sequences asked for. The raw bytes stay untouched in
//! `ProcessBuffer.buffer`; this stage only feeds the filtered buffer, so filters, colour
//! rules and search all match what the user sees in the default view.
//!
//! Interpreted: SGR (`CSI … m`), `\r` (back to column 0, later text overwrites), `\b`,
//! `\t` (8-column stops), `CSI n C/D/G` (cursor movement within the line) and `CSI n K`
//! (erase in line). Every other escape sequence (OSC, DCS, other CSI, charset selection…)
//! is consumed and dropped, as are the remaining C0 controls, DEL and the C1 range. Invalid
//! UTF-8 bytes become U+FFFD. Only single-line cursor movement is modelled: CUU/CUD, ED,
//! scroll regions and modes are dropped, and an unterminated OSC eats the rest of its line.
//! SGR attributes carry across lines like a terminal; `reset` forgets them on reprocess.
const std = @import("std");
const vaxis = @import("vaxis");
const Allocator = std.mem.Allocator;

/// A styled range of the presentation text, line-relative.
pub const Mark = struct { lo: usize, hi: usize, style: vaxis.Style };

/// One interpreted line: presentation text (no control bytes, valid UTF-8) and its marks.
pub const Line = struct { text: []const u8, marks: []const Mark };

pub const replacement = "\u{FFFD}";
const tab_width = 8;
/// A cursor placed more than this many blank columns past the written text is pulled back,
/// so a hostile `CSI 2000000000 G` (or a million tabs) cannot allocate without bound.
const max_padding = 4096;

pub const Interpreter = struct {
    /// SGR attributes in force at the start of the next line.
    sgr: ?vaxis.Style = null,

    pub fn reset(self: *Interpreter) void {
        self.sgr = null;
    }

    /// `raw` is one complete line without its '\n'. Everything returned is allocated from
    /// `arena`, except that a line needing no interpretation is returned as-is (no copy).
    pub fn interpretLine(self: *Interpreter, arena: Allocator, raw: []const u8) Allocator.Error!Line {
        var plain = true;
        for (raw) |c| {
            if (c < 0x20 or c >= 0x7f) {
                plain = false;
                break;
            }
        }
        if (plain) {
            const style = self.sgr orelse return .{ .text = raw, .marks = &.{} };
            if (raw.len == 0) return .{ .text = raw, .marks = &.{} };
            const marks = try arena.alloc(Mark, 1);
            marks[0] = .{ .lo = 0, .hi = raw.len, .style = style };
            return .{ .text = raw, .marks = marks };
        }

        var builder: LineBuilder = .{ .arena = arena, .style = self.sgr };
        try builder.run(raw);
        self.sgr = builder.style;
        return try builder.finish();
    }
};

/// One screen column. A width-2 grapheme occupies a head cell followed by a `tail` cell.
const Cell = struct {
    bytes: []const u8,
    width: u8,
    style: ?vaxis.Style,
    tail: bool = false,
};
const blank: Cell = .{ .bytes = " ", .width = 1, .style = null };

const LineBuilder = struct {
    arena: Allocator,
    style: ?vaxis.Style,
    cols: std.ArrayList(Cell) = .empty,
    cursor: usize = 0,

    fn run(self: *LineBuilder, raw: []const u8) Allocator.Error!void {
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            switch (c) {
                0x1b => {
                    i = try self.escape(raw, i);
                    continue;
                },
                '\r' => self.cursor = 0,
                0x08 => self.cursor -|= 1,
                '\t' => self.cursor = (self.cursor / tab_width + 1) * tab_width,
                else => {
                    if (c < 0x20 or c == 0x7f) {
                        // other C0 controls and DEL are dropped
                    } else if (c < 0x80) {
                        try self.put(raw[i .. i + 1], 1);
                    } else {
                        i += try self.putUtf8(raw[i..]);
                        continue;
                    }
                },
            }
            i += 1;
        }
    }

    /// Decodes one UTF-8 sequence at the start of `rest` and writes it. Returns the number of
    /// bytes consumed (1 for an invalid byte, which is written as U+FFFD).
    fn putUtf8(self: *LineBuilder, rest: []const u8) Allocator.Error!usize {
        const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch {
            try self.put(replacement, 1);
            return 1;
        };
        if (len > rest.len or !std.unicode.utf8ValidateSlice(rest[0..len])) {
            try self.put(replacement, 1);
            return 1;
        }
        const seq = rest[0..len];
        const cp = std.unicode.utf8Decode(seq) catch unreachable;
        if (cp >= 0x80 and cp < 0xa0) return len; // C1 controls are dropped

        const w = vaxis.gwidth.gwidth(seq, .unicode);
        if (w == 0) {
            try self.attach(seq);
        } else {
            try self.put(seq, @intCast(@min(w, 2)));
        }
        return len;
    }

    /// Appends a zero-width codepoint (combining mark, joiner, variation selector) to the
    /// cell before the cursor. With nothing to attach to it is dropped.
    fn attach(self: *LineBuilder, seq: []const u8) Allocator.Error!void {
        if (self.cursor == 0 or self.cursor > self.cols.items.len) return;
        var idx = self.cursor - 1;
        if (self.cols.items[idx].tail) idx -= 1;
        const cell = &self.cols.items[idx];
        if (@intFromPtr(cell.bytes.ptr) + cell.bytes.len == @intFromPtr(seq.ptr)) {
            // contiguous in the source line: just widen the slice
            cell.bytes = cell.bytes.ptr[0 .. cell.bytes.len + seq.len];
            return;
        }
        cell.bytes = try std.mem.concat(self.arena, u8, &.{ cell.bytes, seq });
    }

    /// Writes one grapheme of width `w` at the cursor, padding with blanks up to the cursor
    /// and blanking any wide cell the write cuts in half.
    fn put(self: *LineBuilder, bytes: []const u8, w: u8) Allocator.Error!void {
        const len = self.cols.items.len;
        if (self.cursor > len + max_padding) self.cursor = len + max_padding;
        const end = self.cursor + w;
        while (self.cols.items.len < end) try self.cols.append(self.arena, blank);

        self.breakWide(self.cursor);
        self.breakWide(end);
        self.cols.items[self.cursor] = .{ .bytes = bytes, .width = w, .style = self.style };
        if (w == 2) {
            self.cols.items[self.cursor + 1] = .{ .bytes = "", .width = 0, .style = self.style, .tail = true };
        }
        self.cursor = end;
    }

    /// If column `at` is the tail of a wide cell, blank both halves: one of them is about to
    /// be overwritten and the other would otherwise be an orphan.
    fn breakWide(self: *LineBuilder, at: usize) void {
        const items = self.cols.items;
        if (at < items.len and items[at].tail) {
            items[at] = blank;
            if (at > 0) items[at - 1] = blank;
        }
    }

    /// Returns the index just past the escape sequence starting at `raw[i]` (an ESC).
    fn escape(self: *LineBuilder, raw: []const u8, i: usize) Allocator.Error!usize {
        if (i + 1 >= raw.len) return raw.len;
        switch (raw[i + 1]) {
            '[' => {
                var j = i + 2;
                const params_start = j;
                while (j < raw.len and raw[j] >= 0x30 and raw[j] <= 0x3f) : (j += 1) {}
                const params = raw[params_start..j];
                while (j < raw.len and raw[j] >= 0x20 and raw[j] <= 0x2f) : (j += 1) {}
                if (j >= raw.len) return raw.len;
                const final = raw[j];
                if (final < 0x40 or final > 0x7e) return j; // malformed: resume at this byte
                self.csi(params, final);
                return j + 1;
            },
            ']', 'P', 'X', '^', '_' => {
                // OSC / DCS / SOS / PM / APC: a string terminated by BEL or ST (ESC \)
                var j = i + 2;
                while (j < raw.len) : (j += 1) {
                    if (raw[j] == 0x07) return j + 1;
                    if (raw[j] == 0x1b) {
                        if (j + 1 < raw.len and raw[j + 1] == '\\') return j + 2;
                        return j;
                    }
                }
                return raw.len;
            },
            else => {
                // two/three byte escapes such as charset designation `ESC ( B`
                var j = i + 1;
                while (j < raw.len and raw[j] >= 0x20 and raw[j] <= 0x2f) : (j += 1) {}
                if (j < raw.len and raw[j] >= 0x30 and raw[j] <= 0x7e) return j + 1;
                return j;
            },
        }
    }

    fn csi(self: *LineBuilder, params: []const u8, final: u8) void {
        switch (final) {
            'm' => self.applySgr(params),
            'C' => self.cursor += firstParam(params, 1),
            'D' => self.cursor -|= firstParam(params, 1),
            'G' => self.cursor = @max(firstParam(params, 1), 1) - 1,
            'K' => self.erase(firstParam(params, 0)),
            else => {},
        }
    }

    /// First numeric parameter of a CSI sequence, `default` when absent. Private-mode
    /// sequences (`?`, `>`, …) yield 0 so they never move the cursor.
    fn firstParam(params: []const u8, default: usize) usize {
        if (params.len == 0) return default;
        if (params[0] < '0' or params[0] > '9') return 0;
        var v: usize = 0;
        for (params) |c| {
            if (c < '0' or c > '9') break;
            v = v *| 10 +| (c - '0');
        }
        return v;
    }

    fn erase(self: *LineBuilder, mode: usize) void {
        const items = self.cols.items;
        switch (mode) {
            0 => {
                if (self.cursor >= items.len) return;
                self.breakWide(self.cursor);
                self.cols.shrinkRetainingCapacity(self.cursor);
            },
            1 => {
                if (items.len == 0) return;
                const last = @min(self.cursor, items.len - 1);
                self.breakWide(last + 1);
                @memset(items[0 .. last + 1], blank);
            },
            2 => self.cols.shrinkRetainingCapacity(0),
            else => {},
        }
    }

    fn applySgr(self: *LineBuilder, params: []const u8) void {
        var style: vaxis.Style = self.style orelse .{};
        defer self.style = if (std.meta.eql(style, vaxis.Style{})) null else style;

        if (params.len == 0) {
            style = .{};
            return;
        }

        // Tokenise on ';' and ':'; `sub[k]` records that token k followed a ':'.
        var nums: [64]u16 = undefined;
        var sub: [64]bool = undefined;
        var n: usize = 0;
        var value: u16 = 0;
        var after_colon = false;
        for (params) |c| {
            switch (c) {
                '0'...'9' => value = value *| 10 +| (c - '0'),
                ';', ':' => {
                    if (n == nums.len) return;
                    nums[n] = value;
                    sub[n] = after_colon;
                    n += 1;
                    value = 0;
                    after_colon = c == ':';
                },
                else => return, // private parameter bytes: not an SGR we understand
            }
        }
        if (n == nums.len) return;
        nums[n] = value;
        sub[n] = after_colon;
        n += 1;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = nums[i];
            switch (p) {
                0 => style = .{},
                1 => style.bold = true,
                2 => style.dim = true,
                3 => style.italic = true,
                4 => {
                    style.ul_style = .single;
                    if (i + 1 < n and sub[i + 1]) {
                        i += 1;
                        style.ul_style = switch (nums[i]) {
                            0 => .off,
                            2 => .double,
                            3 => .curly,
                            4 => .dotted,
                            5 => .dashed,
                            else => .single,
                        };
                    }
                },
                5 => style.blink = true,
                7 => style.reverse = true,
                8 => style.invisible = true,
                9 => style.strikethrough = true,
                21 => style.ul_style = .double,
                22 => {
                    style.bold = false;
                    style.dim = false;
                },
                23 => style.italic = false,
                24 => style.ul_style = .off,
                25 => style.blink = false,
                27 => style.reverse = false,
                28 => style.invisible = false,
                29 => style.strikethrough = false,
                30...37 => style.fg = .{ .index = @intCast(p - 30) },
                39 => style.fg = .default,
                40...47 => style.bg = .{ .index = @intCast(p - 40) },
                49 => style.bg = .default,
                59 => style.ul = .default,
                90...97 => style.fg = .{ .index = @intCast(p - 90 + 8) },
                100...107 => style.bg = .{ .index = @intCast(p - 100 + 8) },
                38, 48, 58 => {
                    const color = extendedColor(nums[0..n], sub[0..n], &i) orelse break;
                    switch (p) {
                        38 => style.fg = color,
                        48 => style.bg = color,
                        else => style.ul = color,
                    }
                },
                else => {},
            }
        }
    }

    /// Parses the `5;n` / `2;r;g;b` tail of a 38/48/58 parameter at `i.*`, including the
    /// colon forms `38:2::r:g:b` (with a colour-space id) and `38:5:n`. Advances `i.*` past
    /// the consumed tokens. Returns null when the tail is malformed.
    fn extendedColor(nums: []const u16, sub: []const bool, i: *usize) ?vaxis.Color {
        const start = i.*;
        if (start + 1 >= nums.len) return null;
        switch (nums[start + 1]) {
            5 => {
                if (start + 2 >= nums.len) return null;
                i.* = start + 2;
                return .{ .index = @intCast(@min(nums[start + 2], 255)) };
            },
            2 => {
                // colon form with a colour-space id has five tokens after the 2
                var first = start + 2;
                if (sub[start + 1] and nums.len - first >= 4) first += 1;
                if (first + 2 >= nums.len) return null;
                i.* = first + 2;
                return .{ .rgb = .{
                    @intCast(@min(nums[first], 255)),
                    @intCast(@min(nums[first + 1], 255)),
                    @intCast(@min(nums[first + 2], 255)),
                } };
            },
            else => return null,
        }
    }

    fn finish(self: *LineBuilder) Allocator.Error!Line {
        var total: usize = 0;
        for (self.cols.items) |cell| total += cell.bytes.len;

        const text = try self.arena.alloc(u8, total);
        var marks: std.ArrayList(Mark) = .empty;
        var pos: usize = 0;
        for (self.cols.items) |cell| {
            if (cell.tail) continue;
            const end = pos + cell.bytes.len;
            @memcpy(text[pos..end], cell.bytes);
            if (cell.style) |s| {
                if (marks.items.len > 0) {
                    const last = &marks.items[marks.items.len - 1];
                    if (last.hi == pos and std.meta.eql(last.style, s)) {
                        last.hi = end;
                        pos = end;
                        continue;
                    }
                }
                try marks.append(self.arena, .{ .lo = pos, .hi = end, .style = s });
            }
            pos = end;
        }
        return .{ .text = text, .marks = marks.items };
    }
};

// ----------------------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------------------

const testing = std.testing;

const red: vaxis.Style = .{ .fg = .{ .index = 1 } };
const green: vaxis.Style = .{ .fg = .{ .index = 2 } };

fn interpret(arena: Allocator, interp: *Interpreter, raw: []const u8) !Line {
    return interp.interpretLine(arena, raw);
}

test "plain ASCII is returned without copying" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = .{};

    const raw = "hello world";
    const line = try interpret(arena.allocator(), &interp, raw);
    try testing.expectEqual(@intFromPtr(raw.ptr), @intFromPtr(line.text.ptr));
    try testing.expectEqual(0, line.marks.len);
}

test "SGR colours become marks and are stripped from the text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = .{};

    const line = try interpret(arena.allocator(), &interp, "\x1b[31mred\x1b[0m plain");
    try testing.expectEqualStrings("red plain", line.text);
    try testing.expectEqual(1, line.marks.len);
    try testing.expectEqual(0, line.marks[0].lo);
    try testing.expectEqual(3, line.marks[0].hi);
    try testing.expect(std.meta.eql(red, line.marks[0].style));
    try testing.expectEqual(null, interp.sgr);
}

test "SGR state carries across lines until reset" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = .{};

    _ = try interpret(arena.allocator(), &interp, "\x1b[32mgreen");
    const second = try interpret(arena.allocator(), &interp, "still green");
    try testing.expectEqualStrings("still green", second.text);
    try testing.expectEqual(1, second.marks.len);
    try testing.expectEqual(11, second.marks[0].hi);
    try testing.expect(std.meta.eql(green, second.marks[0].style));

    const third = try interpret(arena.allocator(), &interp, "end\x1b[0m after");
    try testing.expectEqualStrings("end after", third.text);
    try testing.expectEqual(1, third.marks.len);
    try testing.expectEqual(3, third.marks[0].hi);

    const fourth = try interpret(arena.allocator(), &interp, "plain");
    try testing.expectEqual(0, fourth.marks.len);

    _ = try interpret(arena.allocator(), &interp, "\x1b[1;31m");
    interp.reset();
    try testing.expectEqual(null, interp.sgr);
}

test "SGR attributes, bright colours and extended colours" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = .{};

    const a = try interpret(arena.allocator(), &interp, "\x1b[1;4;93;48;5;200mx\x1b[m");
    try testing.expectEqualStrings("x", a.text);
    const s = a.marks[0].style;
    try testing.expect(s.bold);
    try testing.expectEqual(vaxis.Style.Underline.single, s.ul_style);
    try testing.expect(std.meta.eql(vaxis.Color{ .index = 11 }, s.fg));
    try testing.expect(std.meta.eql(vaxis.Color{ .index = 200 }, s.bg));
    try testing.expectEqual(null, interp.sgr);

    const b = try interpret(arena.allocator(), &interp, "\x1b[38;2;10;20;30mrgb\x1b[39m\x1b[4:3mc\x1b[0m");
    try testing.expectEqualStrings("rgbc", b.text);
    try testing.expectEqual(2, b.marks.len);
    try testing.expect(std.meta.eql(vaxis.Color{ .rgb = .{ 10, 20, 30 } }, b.marks[0].style.fg));
    try testing.expectEqual(vaxis.Style.Underline.curly, b.marks[1].style.ul_style);

    const c = try interpret(arena.allocator(), &interp, "\x1b[38:2::1:2:3mz\x1b[0m");
    try testing.expect(std.meta.eql(vaxis.Color{ .rgb = .{ 1, 2, 3 } }, c.marks[0].style.fg));
}

test "carriage return overwrites from column 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = .{};
    const a = arena.allocator();

    try testing.expectEqualStrings("XYcdef", (try interpret(a, &interp, "abcdef\rXY")).text);
    try testing.expectEqualStrings("downloading 46%", (try interpret(a, &interp, "downloading 45%\r\x1b[Kdownloading 46%")).text);
    try testing.expectEqualStrings("progress 100%", (try interpret(a, &interp, "progress 10%\rprogress 100%")).text);
    try testing.expectEqualStrings("abc", (try interpret(a, &interp, "abc\r")).text);
}

test "backspace and single-line cursor movement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = .{};
    const a = arena.allocator();

    try testing.expectEqualStrings("abX", (try interpret(a, &interp, "abc\x08X")).text);
    try testing.expectEqualStrings("X", (try interpret(a, &interp, "\x08X")).text);
    try testing.expectEqualStrings("axy", (try interpret(a, &interp, "abc\x1b[2Dxy")).text);
    try testing.expectEqualStrings("ab  c", (try interpret(a, &interp, "ab\x1b[5Gc")).text);
    try testing.expectEqualStrings("ab   c", (try interpret(a, &interp, "ab\x1b[3Cc")).text);
    try testing.expectEqualStrings("ab", (try interpret(a, &interp, "abcdef\x1b[3G\x1b[K")).text);
    try testing.expectEqualStrings("   def", (try interpret(a, &interp, "abcdef\x1b[3G\x1b[1K")).text);
    try testing.expectEqualStrings("", (try interpret(a, &interp, "abcdef\x1b[2K")).text);
}

test "tabs expand to 8-column stops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = .{};
    const a = arena.allocator();

    try testing.expectEqualStrings("        x", (try interpret(a, &interp, "\tx")).text);
    try testing.expectEqualStrings("ab      c", (try interpret(a, &interp, "ab\tc")).text);
    try testing.expectEqualStrings("ab", (try interpret(a, &interp, "ab\t")).text);
}

test "unknown escapes and stray controls are dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = .{};
    const a = arena.allocator();

    try testing.expectEqualStrings("abc", (try interpret(a, &interp, "abc\x1b[2J\x1b[?25l")).text);
    try testing.expectEqualStrings("ab", (try interpret(a, &interp, "a\x1b]0;title\x07b")).text);
    try testing.expectEqualStrings("ab", (try interpret(a, &interp, "a\x1b]0;title\x1b\\b")).text);
    try testing.expectEqualStrings("a", (try interpret(a, &interp, "a\x1b]0;unterminated")).text);
    try testing.expectEqualStrings("abc", (try interpret(a, &interp, "abc\x1b")).text);
    try testing.expectEqualStrings("abc", (try interpret(a, &interp, "abc\x1b[")).text);
    try testing.expectEqualStrings("ab", (try interpret(a, &interp, "a\x1b(Bb")).text);
    try testing.expectEqualStrings("done", (try interpret(a, &interp, "done\x07")).text);
    try testing.expectEqualStrings("ab", (try interpret(a, &interp, "a\x00\x7f\x01b")).text);
}

test "invalid UTF-8 becomes U+FFFD and wide graphemes overwrite cleanly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = .{};
    const a = arena.allocator();

    try testing.expectEqualStrings("a\u{FFFD}b", (try interpret(a, &interp, "a\xffb")).text);
    try testing.expectEqualStrings("\u{FFFD}\u{FFFD}", (try interpret(a, &interp, "\xe6\xbc")).text);
    try testing.expectEqualStrings("漢字", (try interpret(a, &interp, "漢\x07字")).text);
    try testing.expectEqualStrings("x ", (try interpret(a, &interp, "漢\rx")).text);
    try testing.expectEqualStrings("e\u{301}", (try interpret(a, &interp, "e\u{301}")).text);
    try testing.expectEqualStrings("a", (try interpret(a, &interp, "\u{200B}a")).text);
    // combining mark separated from its base by an escape is still attached
    try testing.expectEqualStrings("e\u{301}", (try interpret(a, &interp, "e\x1b[0m\u{301}")).text);
}

test "a coloured region survives an overwrite and marks coalesce" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = .{};

    const line = try interpret(arena.allocator(), &interp, "\x1b[31mab\x1b[0mcd\r\x1b[31mX\x1b[0m");
    try testing.expectEqualStrings("Xbcd", line.text);
    try testing.expectEqual(1, line.marks.len);
    try testing.expectEqual(0, line.marks[0].lo);
    try testing.expectEqual(2, line.marks[0].hi);
}

test "runaway cursor moves are bounded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var interp: Interpreter = .{};

    const line = try interpret(arena.allocator(), &interp, "a\x1b[2000000000Gb");
    try testing.expectEqual(1 + max_padding + 1, line.text.len);
    try testing.expectEqual('b', line.text[line.text.len - 1]);
}
