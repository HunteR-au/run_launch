//! The launch configuration module: reads the YAML launch file (CONFIG.md describes the
//! format) into a validated `Configuration` the runner and the UI work from.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const expand = @import("expand.zig");
pub const cmdline = @import("cmdline.zig");
const model = @import("configuration.zig");
const parse_ = @import("parse.zig");

pub const Configuration = model.Configuration;
pub const Process = model.Process;
pub const Group = model.Group;
pub const Target = model.Target;
pub const RunnerType = model.RunnerType;
pub const ColorRule = model.ColorRule;
pub const EnvTuple = model.EnvTuple;
pub const Diagnostics = parse_.Diagnostics;
pub const ParseError = parse_.Error;
pub const parse = parse_.parse;

pub const max_config_bytes = 1024 * 1024;

/// Reads and parses `filepath`. When this fails `diag` says what is wrong, in the user's
/// terms. `${...}` tokens resolve against the map given to `expand.init_expand`.
pub fn parseFile(io: Io, alloc: Allocator, filepath: []const u8, diag: *Diagnostics) !Configuration {
    const data = std.Io.Dir.cwd().readFileAlloc(io, filepath, alloc, .limited(max_config_bytes)) catch |err| {
        diag.set("cannot read \"{s}\": {t}", .{ filepath, err });
        return err;
    };
    defer alloc.free(data);
    return parse_.parse(io, alloc, data, diag);
}

test {
    _ = expand;
    _ = cmdline;
    _ = model;
    _ = parse_;
}
