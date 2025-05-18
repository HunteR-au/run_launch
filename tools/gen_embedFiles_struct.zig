const std = @import("std");

// Input Args:
// - Arg[2]     - filename to gen
// - Arg[3..]   - filepath{s} to assets to be emebed into the output binary

// output - a file with a struct named EmbededFiles
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);

    if (args.len <= 2) fatal("wrong number of arguments", .{});

    const output_file_path = args[1];

    const args_WithoutBinaryName = args[3..];
    var structLines = try arena.alloc([]u8, args_WithoutBinaryName.len + 3);
    const zerothLine = "pub const EmbededTuple = struct { name: []const u8, ptr: []const u8 };\n";
    const firstLine = "pub const EmbededFiles = .{\n";
    const lastLine = "};";

    structLines[0] = try arena.dupe(u8, zerothLine);
    structLines[1] = try arena.dupe(u8, firstLine);
    structLines[structLines.len - 1] = try arena.dupe(u8, lastLine);
    for (args_WithoutBinaryName, 2..) |arg, idx| {
        // first make sure any '\' is replaced with "\\"
        const size = std.mem.replacementSize(u8, arg, "\\", "/");

        const replacedArg = try arena.alloc(u8, size);
        _ = std.mem.replace(u8, arg, "\\", "/", replacedArg);
        structLines[idx] = try std.fmt.allocPrint(arena, "EmbededTuple{{ .name = \"{s}\", .ptr = @ptrCast(@embedFile(\"{s}\")) }},\n", .{ replacedArg, replacedArg });
    }

    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close();

    for (structLines) |line| {
        try output_file.writeAll(line);
    }
    return std.process.cleanExit();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
