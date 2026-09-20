//! Clipboard key chords shared by the output views and the command bar, so both places use
//! the same keys and the help text has one source of truth.
//!
//! Windows uses Ctrl+C / Ctrl+V. Elsewhere Ctrl+C is the interrupt convention, so the copy
//! and paste chords carry Shift, matching what terminals themselves use. Only terminals with
//! the kitty keyboard protocol can tell Ctrl+Shift+C from Ctrl+C; legacy ones send the same
//! byte for both, and many intercept Ctrl+Shift+C for their own copy.
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");

fn chordMods(os: std.Target.Os.Tag) vaxis.Key.Modifiers {
    return if (os == .windows) .{ .ctrl = true } else .{ .ctrl = true, .shift = true };
}

pub fn isCopyFor(os: std.Target.Os.Tag, key: vaxis.Key) bool {
    return key.matches('c', chordMods(os));
}

pub fn isCopy(key: vaxis.Key) bool {
    return isCopyFor(builtin.os.tag, key);
}

/// The platform chord, or Shift+Insert anywhere.
pub fn isPasteFor(os: std.Target.Os.Tag, key: vaxis.Key) bool {
    return key.matches('v', chordMods(os)) or key.matches(vaxis.Key.insert, .{ .shift = true });
}

pub fn isPaste(key: vaxis.Key) bool {
    return isPasteFor(builtin.os.tag, key);
}

/// Key names for the help screen.
pub const copy_help: []const u8 = if (builtin.os.tag == .windows) "Ctrl+C" else "Ctrl+Shift+C";
pub const paste_help: []const u8 = if (builtin.os.tag == .windows) "Ctrl+V" else "Ctrl+Shift+V";

const testing = std.testing;

test "copy and paste chords differ per platform" {
    const ctrl_c: vaxis.Key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } };
    const ctrl_shift_c: vaxis.Key = .{ .codepoint = 'c', .mods = .{ .ctrl = true, .shift = true } };
    try testing.expect(isCopyFor(.windows, ctrl_c));
    try testing.expect(!isCopyFor(.windows, ctrl_shift_c));
    try testing.expect(isCopyFor(.linux, ctrl_shift_c));
    try testing.expect(!isCopyFor(.linux, ctrl_c));

    const ctrl_v: vaxis.Key = .{ .codepoint = 'v', .mods = .{ .ctrl = true } };
    const ctrl_shift_v: vaxis.Key = .{ .codepoint = 'v', .mods = .{ .ctrl = true, .shift = true } };
    try testing.expect(isPasteFor(.windows, ctrl_v));
    try testing.expect(!isPasteFor(.linux, ctrl_v));
    try testing.expect(isPasteFor(.linux, ctrl_shift_v));

    const shift_insert: vaxis.Key = .{ .codepoint = vaxis.Key.insert, .mods = .{ .shift = true } };
    try testing.expect(isPasteFor(.windows, shift_insert));
    try testing.expect(isPasteFor(.linux, shift_insert));
}

test "a modifier key on its own is neither copy nor paste" {
    // Windows reports the Ctrl of Ctrl+C as its own key press before the 'c' arrives
    const ctrl_only: vaxis.Key = .{ .codepoint = vaxis.Key.left_control, .mods = .{ .ctrl = true } };
    try testing.expect(!isCopyFor(.windows, ctrl_only));
    try testing.expect(!isPasteFor(.windows, ctrl_only));
    try testing.expect(!isCopyFor(.linux, ctrl_only));

    const plain_c: vaxis.Key = .{ .codepoint = 'c', .text = "c" };
    try testing.expect(!isCopyFor(.windows, plain_c));
}
