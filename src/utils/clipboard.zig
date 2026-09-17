//! System clipboard access that bypasses the terminal.
//!
//! Terminals implement clipboard writes through OSC 52, which Windows Terminal serves on its
//! UI thread by way of the WinRT clipboard; on some machines that blocks the terminal (and so
//! all of our input and output) for seconds per write. On Windows we therefore talk to the
//! Win32 clipboard directly. Other platforms report `error.Unsupported` so callers fall back
//! to OSC 52.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const Error = error{ Unsupported, OutOfMemory, ClipboardBusy };

const CF_UNICODETEXT: windows.UINT = 13;
const GMEM_MOVEABLE: windows.UINT = 0x0002;

extern "user32" fn OpenClipboard(hWndNewOwner: ?windows.HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn SetClipboardData(uFormat: windows.UINT, hMem: ?windows.HANDLE) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GlobalAlloc(uFlags: windows.UINT, dwBytes: usize) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn GlobalLock(hMem: windows.HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GlobalFree(hMem: windows.HANDLE) callconv(.winapi) ?windows.HANDLE;

/// Puts `text` on the system clipboard as Unicode text. Windows only.
pub fn setText(alloc: std.mem.Allocator, text: []const u8) Error!void {
    if (builtin.os.tag != .windows) return error.Unsupported;

    const wide = try toClipboardUtf16(alloc, text);
    defer alloc.free(wide);
    const bytes = std.mem.sliceAsBytes(wide[0 .. wide.len + 1]); // include the terminator

    // The clipboard takes ownership of a movable global block.
    const hmem = GlobalAlloc(GMEM_MOVEABLE, bytes.len) orelse return error.OutOfMemory;
    const dst = GlobalLock(hmem) orelse {
        _ = GlobalFree(hmem);
        return error.OutOfMemory;
    };
    @memcpy(@as([*]u8, @ptrCast(dst))[0..bytes.len], bytes);
    _ = GlobalUnlock(hmem);

    // The clipboard is shared: another process may hold it open for a moment.
    var attempt: usize = 0;
    while (OpenClipboard(null) == .FALSE) : (attempt += 1) {
        if (attempt >= 20) {
            _ = GlobalFree(hmem);
            return error.ClipboardBusy;
        }
        std.atomic.spinLoopHint();
    }
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
    if (SetClipboardData(CF_UNICODETEXT, hmem) == null) {
        _ = GlobalFree(hmem);
        return error.ClipboardBusy;
    }
    // success: hmem now belongs to the system
}

/// UTF-8 to NUL-terminated UTF-16LE for CF_UNICODETEXT: invalid sequences become U+FFFD
/// rather than failing (process output is not guaranteed to be valid UTF-8), and line feeds
/// become CRLF, which is what Windows applications expect when pasting.
pub fn toClipboardUtf16(alloc: std.mem.Allocator, text: []const u8) error{OutOfMemory}![:0]u16 {
    var out = try std.ArrayList(u16).initCapacity(alloc, text.len + 1);
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == '\n') {
            try out.appendSlice(alloc, &.{ '\r', '\n' });
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            try out.append(alloc, 0xFFFD);
            i += 1;
            continue;
        };
        if (i + n > text.len) {
            try out.append(alloc, 0xFFFD);
            break;
        }
        const cp = std.unicode.utf8Decode(text[i .. i + n]) catch {
            try out.append(alloc, 0xFFFD);
            i += 1;
            continue;
        };
        i += n;
        if (cp < 0x10000) {
            try out.append(alloc, @intCast(cp));
        } else {
            const c = cp - 0x10000;
            try out.appendSlice(alloc, &.{
                @intCast(0xD800 + (c >> 10)),
                @intCast(0xDC00 + (c & 0x3FF)),
            });
        }
    }
    return try out.toOwnedSliceSentinel(alloc, 0);
}

const testing = std.testing;

test "toClipboardUtf16 converts, terminates, and turns LF into CRLF" {
    const wide = try toClipboardUtf16(testing.allocator, "a\nb");
    defer testing.allocator.free(wide);
    try testing.expectEqualSlices(u16, &.{ 'a', '\r', '\n', 'b' }, wide);
    try testing.expectEqual(0, wide[wide.len]);
}

test "toClipboardUtf16 encodes multi-byte and astral code points" {
    // é (2 bytes), 漢 (3 bytes), 😀 (4 bytes, a surrogate pair)
    const wide = try toClipboardUtf16(testing.allocator, "é漢😀");
    defer testing.allocator.free(wide);
    try testing.expectEqualSlices(u16, &.{ 0x00E9, 0x6F22, 0xD83D, 0xDE00 }, wide);
}

test "toClipboardUtf16 replaces invalid bytes instead of failing" {
    const wide = try toClipboardUtf16(testing.allocator, "a\xffb\xe6\x97");
    defer testing.allocator.free(wide);
    // \xff is invalid; \xe6\x97 is a truncated 3-byte sequence at the end
    try testing.expectEqualSlices(u16, &.{ 'a', 0xFFFD, 'b', 0xFFFD }, wide);
}
