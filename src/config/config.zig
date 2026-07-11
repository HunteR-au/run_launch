const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Yaml = @import("yaml").Yaml;
const launch_ = @import("launch.zig");
const task_ = @import("task.zig");
const yamlconfig = @import("yamlconfig.zig");
const jsonconfig = @import("jsonconfig.zig");

pub const Launch = launch_.Launch;
pub const LaunchConfiguration = launch_.Configuration;
pub const Compound = launch_.Compound;
pub const Task = task_.Task;
pub const Tasks = task_.Tasks;

pub const Configuration = struct {
    launch: Launch,
    tasks: ?Tasks,
};

const ConfigType = enum { Json, Yaml };

fn getConfigType(filepath: []const u8) !ConfigType {
    const ext = std.Io.Dir.path.extension(filepath);

    if (std.mem.eql(u8, ext, ".yml") or std.mem.eql(u8, ext, ".yaml")) return .Yaml;
    if (std.mem.eql(u8, ext, ".json")) return .Json;
    return error.InvalidExtension;
}

pub fn parseConfig(io: Io, alloc: Allocator, filepath: []const u8) !Configuration {
    const config_type = try getConfigType(filepath);

    const size_limit = Io.Limit.limited64(1024 * 1024);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, filepath, alloc, size_limit);
    std.log.debug("\n{s}\n", .{data});
    defer alloc.free(data);

    switch (config_type) {
        .Yaml => {
            var yaml: Yaml = .{ .source = data };
            defer yaml.deinit(alloc);

            yaml.load(alloc) catch |err| switch (err) {
                error.ParseFailure => {
                    std.debug.assert(yaml.parse_errors.errorMessageCount() > 0);
                    //yaml.parse_errors.renderToStdErr(io, .{}, .auto) catch {};
                    return error.ParseFailure;
                },
                else => return err,
            };

            return .{
                .launch = try yamlconfig.parseLaunch(io, alloc, yaml),
                .tasks = try yamlconfig.parseTasks(io, alloc, yaml),
            };
        },
        .Json => {
            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
            defer parsed.deinit();

            return .{
                .launch = try jsonconfig.parseLaunch(io, alloc, parsed.value),
                .tasks = try jsonconfig.parseTasks(io, alloc, parsed.value),
            };
        },
    }
}
