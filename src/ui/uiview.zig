const std = @import("std");
const webui = @import("webui");
const embedFiles = @import("../embededFiles.zig");
const uiconfig = @import("uiconfig.zig");

var windowInst: ?webui = null;

pub fn getEmbedContent(path: []const u8) ?[:0]const u8 {
    inline for (embedFiles.EmbededFiles) |t| {
        if (std.mem.eql(u8, t.name, path)) {
            //std.debug.print("{s}\n", .{t.name});
            return t.ptr;
        }
    }
    return null;
}

var fileHandleArena: ?std.heap.ArenaAllocator = null;
fn fileHandler(filename: []const u8) ?[]const u8 {
    const alloc = fileHandleArena.?.allocator();
    const httpHeader =
        \\HTTP/1.1 200 OK
        \\Content-Length:{d}
    ++ "\r\n\r\n";

    const embedContent = getEmbedContent(filename);
    if (embedContent) |content| {
        const httpHeaderWithLength = std.fmt.allocPrint(alloc, httpHeader, .{content.len}) catch {
            @panic("FileHandlerFailed");
        };
        const httpResponse = std.fmt.allocPrint(alloc, "{s}{s}", .{ httpHeaderWithLength, content }) catch {
            @panic("FileHandlerFailed");
        };
        return httpResponse;
    }

    return null;
}

pub fn setupWebUI(alloc: std.mem.Allocator) !void {
    // create a new window
    windowInst = webui.newWindow();
    errdefer windowInst.?.close();

    // set the filehandler
    fileHandleArena = std.heap.ArenaAllocator.init(alloc);
    errdefer fileHandleArena.?.deinit();

    windowInst.?.setFileHandler(fileHandler);

    // Set the root folder for the UI
    //_ = windowInst.?.setRootFolder("src/ui");
    _ = windowInst.?.show(@as([:0]const u8, comptime getEmbedContent("index.html").?));

    var config = try uiconfig.parseConfigs(alloc);
    defer config.deinit();
    const configJsonStr = try config.dumps(alloc);
    defer alloc.free(configJsonStr);
    try setUIConfig(alloc, configJsonStr);

    // wait the window exit
    //webui.wait();

    // Free all memory resources (Optional)
    //webui.clean();
}

pub fn closeWebUI() void {
    if (windowInst) |w| {
        w.close();
    }
    if (fileHandleArena) |a| {
        a.deinit();
        fileHandleArena = null;
    }

    webui.clean();
}

pub fn createProcessView(processname: []const u8) void {
    if (windowInst) |w| {
        const buf_size = 1024 * 2;
        var js: [buf_size]u8 = std.mem.zeroes([buf_size]u8);
        const buf = std.fmt.bufPrint(&js, "createView('{s}');", .{processname}) catch unreachable;
        const content: [:0]const u8 = js[0..buf.len :0];
        w.run(content);
    }
}
pub fn killProcessView(processname: []const u8) void {
    if (windowInst) |w| {
        const buf_size = 1024 * 2;
        var js: [buf_size]u8 = std.mem.zeroes([buf_size]u8);
        const buf = std.fmt.bufPrint(&js, "removeView('{s}');", .{processname}) catch unreachable;
        const content: [:0]const u8 = js[0..buf.len :0];
        w.run(content);
    }
}

pub fn setUIConfig(alloc: std.mem.Allocator, jsonStr: []const u8) std.mem.Allocator.Error!void {
    if (windowInst) |w| {
        const encoder = std.base64.Base64Encoder.init(std.base64.url_safe.alphabet_chars, std.base64.url_safe.pad_char);

        const size = encoder.calcSize(jsonStr.len);
        const encodedBuf = try alloc.alloc(u8, size);
        _ = encoder.encode(encodedBuf, jsonStr);

        const buf_size = 1024 * 1024;
        var js: [buf_size]u8 = std.mem.zeroes([buf_size]u8);
        const buf = std.fmt.bufPrint(&js, "setUIConfig(atob('{s}'));", .{encodedBuf}) catch unreachable;
        const content: [:0]const u8 = js[0..buf.len :0];

        w.run(content);
    }
}

pub fn pushLogging(alloc: std.mem.Allocator, processname: []const u8, buffer: []const u8) std.mem.Allocator.Error!void {
    if (windowInst) |w| {
        const prefix = "addToBufferAndRender(\"";
        const postfix = "\");";
        const result = try std.mem.concat(alloc, u8, &.{ prefix, buffer, postfix });
        defer alloc.free(result);

        const encoder = std.base64.Base64Encoder.init(std.base64.url_safe.alphabet_chars, std.base64.url_safe.pad_char);

        const size = encoder.calcSize(buffer.len);
        const encodedBuf = try alloc.alloc(u8, size);
        _ = encoder.encode(encodedBuf, buffer);

        const buf_size = 1024 + 500; // TODO: 500 for process name should be done better!
        var js: [buf_size]u8 = std.mem.zeroes([buf_size]u8);
        const buf = std.fmt.bufPrint(&js, "addToBufferAndRender('{s}', atob('{s}'));", .{ processname, encodedBuf }) catch unreachable;
        const content: [:0]const u8 = js[0..buf.len :0];

        w.run(content);
    }
}
