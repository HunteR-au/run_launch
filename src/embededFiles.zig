pub const EmbededTuple = struct { name: []const u8, ptr: [:0]const u8 };
pub const EmbededFiles = .{
    EmbededTuple{ .name = "index.html", .ptr = @ptrCast(@embedFile("webui/index.html")) },
    EmbededTuple{ .name = "/js/color.js", .ptr = @ptrCast(@embedFile("webui/js/color.js")) },
    EmbededTuple{ .name = "/js/script.js", .ptr = @ptrCast(@embedFile("webui/js/script.js")) },
    EmbededTuple{ .name = "/js/viewgroup-divider.js", .ptr = @ptrCast(@embedFile("webui/js/viewgroup-divider.js")) },
    EmbededTuple{ .name = "/js/sidebar.js", .ptr = @ptrCast(@embedFile("webui/js/sidebar.js")) },
    EmbededTuple{ .name = "/sidebar.css", .ptr = @ptrCast(@embedFile("webui/sidebar.css")) },
};
