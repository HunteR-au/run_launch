const std = @import("std");

pub fn createArgsForGenEmbedFilesStruct(alloc: std.mem.Allocator) !std.ArrayList([]u8) {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var argsArray = std.ArrayList([]u8).init(alloc);

    var dir = try std.fs.cwd().openDir("src/ui", .{ .iterate = true });
    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // we need to save the path and append with a space to the args
        if (entry.kind == std.fs.Dir.Entry.Kind.file) {
            const size = std.mem.replacementSize(u8, entry.path, "\\", "/");
            const replacedArg = try alloc.alloc(u8, size);

            _ = std.mem.replace(u8, entry.path, "\\", "/", replacedArg);

            try argsArray.append(try alloc.dupe(u8, replacedArg));
        }
    }

    return argsArray;
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // const tool = b.addExecutable(.{
    //     .name = "gen_embedFiles_struct",
    //     .root_source_file = b.path("tools/gen_embedFiles_struct.zig"),
    //     .target = b.graph.host,
    // });

    // const tool_step = b.addRunArtifact(tool);
    // tool_step.setCwd(b.path("."));
    // const embedFilesOutput = tool_step.addOutputFileArg("embedFiles.zig");
    // tool_step.addArg("embedFiles.zig");

    var arena_state = std.heap.ArenaAllocator.init(b.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const embededArgs = try createArgsForGenEmbedFilesStruct(arena);
    //tool_step.addArgs(embededArgs.items);

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    _ = b.createModule(.{
        //.name = "run_launch",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    //b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "run_launch",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // exe.root_module.addAnonymousImport("embedFiles", .{
    // .root_source_file = embedFilesOutput,
    // });

    // Add files from ui folder recursively using the embededArgs
    for (embededArgs.items) |item| {
        const prefix = "src/ui/";
        const relPath = try std.mem.concat(arena, u8, &.{ prefix, item });
        exe.root_module.addAnonymousImport(item, .{
            .root_source_file = b.path(relPath),
        });
    }

    const clap = b.dependency("clap", .{});
    exe.root_module.addImport("clap", clap.module("clap"));

    const zig_webui = b.dependency("zig_webui", .{
        .target = target,
        .optimize = optimize,
        .enable_tls = false, // whether enable tls support
        .is_static = true, // whether static link
    });
    exe.root_module.addImport("webui", zig_webui.module("webui"));

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
