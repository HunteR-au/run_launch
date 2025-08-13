const std = @import("std");
const main = @import("main.zig");
const tui = @import("tui");
const utils = @import("utils");
const testing = std.testing;

test "root" {
    std.testing.refAllDecls(@This());
}
