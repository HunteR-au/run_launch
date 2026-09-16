//! Messages carried by the pump queue from reader tasks, the runner, and the UI to the
//! single pump thread.
const std = @import("std");
const utils = @import("utils");

pub const UUID = utils.uuid.UUID;
pub const Term = std.process.Child.Term;

pub const Stream = enum(u8) { stdout, stderr };

/// Arbitrary work executed on the pump thread. Used by the UI/runner to mutate pump-owned
/// state (install a filter, merge buffers, remove a buffer) without any shared locking.
pub const Command = struct {
    run: *const fn (ctx: *anyopaque, payload: ?*anyopaque) void,
    ctx: *anyopaque,
    payload: ?*anyopaque = null,
    /// When non-null the pump sets it after `run` returns (for synchronous callers).
    done: ?*std.Io.Event = null,
};

pub const Msg = union(enum) {
    /// Raw bytes read from a child's pipe. `data` is owned by the message and freed by the
    /// pump (with the pump's allocator) after the sink has consumed it.
    bytes: struct { id: UUID, stream: Stream, data: []u8 },
    /// Exactly one per (process, stream). `err` is non-null when the stream ended with a
    /// read error rather than EOF.
    stream_eof: struct { id: UUID, stream: Stream, err: ?anyerror },
    /// Posted by the waiter task once the process has been reaped. `term == null` means
    /// `wait` itself failed.
    process_exited: struct { id: UUID, term: ?Term },
    /// Posted by whoever mints a buffer id, always before any `bytes` for that id.
    /// `name` is owned by the message and freed by the pump.
    create_buffer: struct { id: UUID, name: []u8 },
    command: Command,
};
