const std = @import("std");

pub fn createArgsForGenEmbedFilesStruct(alloc: std.mem.Allocator) !std.ArrayList([]u8) {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var argsArray = try std.ArrayList([]u8).initCapacity(alloc, 10);

    var dir = try std.fs.cwd().openDir("src/ui", .{ .iterate = true });
    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // we need to save the path and append with a space to the args
        if (entry.kind == std.fs.Dir.Entry.Kind.file) {
            const size = std.mem.replacementSize(u8, entry.path, "\\", "/");
            const replacedArg = try alloc.alloc(u8, size);

            _ = std.mem.replace(u8, entry.path, "\\", "/", replacedArg);

            try argsArray.append(alloc, try alloc.dupe(u8, replacedArg));
        }
    }
    return argsArray;
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    var arena_state = std.heap.ArenaAllocator.init(b.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const embededArgs = try createArgsForGenEmbedFilesStruct(arena);

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const zig_webui_dep = b.dependency("zig_webui", .{
        .target = target,
        .optimize = optimize,
        .enable_tls = false, // whether enable tls support
        .is_static = true, // whether static link
    });
    const regex_dep = b.dependency("regex", .{});
    const clap_dep = b.dependency("clap", .{});

    // Modules
    const utils = b.createModule(.{ .root_source_file = b.path("src/utils.zig") });
    const runner = b.createModule(.{ .root_source_file = b.path("src/runner/runner.zig") });
    const debug_ui = b.createModule(.{ .root_source_file = b.path("src/debug/debug.zig") });
    const config = b.createModule(.{ .root_source_file = b.path("src/config/config.zig") });
    const uiconfig = b.createModule(.{ .root_source_file = b.path("src/ui/uiconfig.zig") });
    const tui = b.createModule(.{
        .root_source_file = b.path("src/ui/tui.zig"),
    });
    const vaxis = vaxis_dep.module("vaxis");
    const regex = regex_dep.module("regex");
    const clap = clap_dep.module("clap");
    const webui = zig_webui_dep.module("webui");

    // setup debug_ui
    debug_ui.addImport("utils", utils);

    // Setup uiconfig
    uiconfig.addImport("utils", utils);

    // Setup runner
    runner.addImport("utils", utils);
    runner.addImport("config", config);

    // Setup config
    config.addImport("utils", utils);

    // Setup tui
    tui.addImport("vaxis", vaxis);
    tui.addImport("utils", utils);
    tui.addImport("uiconfig", uiconfig);
    tui.addImport("regex", regex);
    tui.addImport("debug_ui", debug_ui);
    tui.addImport("runner", runner);

    // Setup the EXE
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "run_launch",
        .root_module = exe_mod,
    });

    // Add files from ui folder recursively using the embededArgs
    for (embededArgs.items) |item| {
        const prefix = "src/ui/";
        const relPath = b.pathJoin(&.{ prefix, item });
        exe.root_module.addAnonymousImport(item, .{
            .root_source_file = b.path(relPath),
        });
    }

    // Add EXE modules
    exe_mod.addImport("utils", utils);
    exe_mod.addImport("uiconfig", uiconfig);
    exe_mod.addImport("clap", clap);
    exe_mod.addImport("webui", webui);
    exe_mod.addImport("debug_ui", debug_ui);
    exe_mod.addImport("runner", runner);
    exe_mod.addImport("tui", tui);
    exe_mod.addImport("config", config);

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
    //const lib_unit_tests = b.addTest(.{
    //    .root_source_file = b.path("src/root.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});

    //const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    //lib_unit_tests.root_module.addImport("utils", utils);
    //lib_unit_tests.root_module.addImport("tui", tui);
    //lib_unit_tests.root_module.addImport("vaxis", vaxis);
    const output_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    output_unit_tests.root_module.addImport("utils", utils);
    output_unit_tests.root_module.addImport("uiconfig", uiconfig);
    output_unit_tests.root_module.addImport("vaxis", vaxis);
    output_unit_tests.root_module.addImport("tui", tui);
    output_unit_tests.root_module.addImport("regex", regex);
    output_unit_tests.root_module.addImport("debug_ui", debug_ui);
    output_unit_tests.root_module.addImport("runner", runner);
    output_unit_tests.root_module.addImport("config", config);

    //const output_unit_tests = b.addTest(.{
    //    .root_source_file = b.path("src/ui/tui/output.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});
    //output_unit_tests.root_module.addImport("utils", utils);
    //output_unit_tests.root_module.addImport("vaxis", vaxis);
    //output_unit_tests.root_module.addImport("regex", regex);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_unit_tests.root_module.addImport("tui", tui);
    exe_unit_tests.root_module.addImport("utils", utils);
    exe_unit_tests.root_module.addImport("uiconfig", uiconfig);
    exe_unit_tests.root_module.addImport("vaxis", vaxis);
    exe_unit_tests.root_module.addImport("debug_ui", debug_ui);
    exe_unit_tests.root_module.addImport("runner", runner);
    exe_unit_tests.root_module.addImport("config", config);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_tui_unit_tests = b.addRunArtifact(output_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tui_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}
