const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const utils = @import("utils");
const buffer_ = @import("pipeline/buffer/buffer.zig");
const LinesAndMeta = @import("pipeline/linesandmeta.zig").LinesAndMeta;

const uuid = utils.uuid;

const ProcessBuffer = buffer_.ProcessBuffer;
const BufferGraph = buffer_.BufferGraph;

const ProcessBuffersMap = struct {
    m: std.Io.Mutex,
    map: std.AutoHashMapUnmanaged(uuid.UUID, *ProcessBuffer),
};

const StrIdCounter = struct {
    m: std.Io.Mutex = .init,
    counter: usize = 0,

    pub fn new_id(self: *StrIdCounter, io: Io) usize {
        self.m.lockUncancelable(io);
        const id = self.counter;
        self.counter = self.counter + 1;
        self.m.unlock(io);
        return id;
    }
};

pub const PBufferAndId = struct {
    id: uuid.UUID,
    buffer: *ProcessBuffer,
};

pub const BufferMgr = struct {
    process_buffers: ProcessBuffersMap,
    // Virtual buffer don't need a mutex, like process buffers,
    // as they don't have a writer loop from another thread
    virtual_buffers: std.AutoHashMapUnmanaged(uuid.UUID, *ProcessBuffer),
    buffer_graph: BufferGraph,
    strid_counter: StrIdCounter = .{},

    pub fn init(alloc: Allocator) !*BufferMgr {
        const self = try alloc.create(BufferMgr);
        self.* = .{
            .process_buffers = .{ .m = .init, .map = .{} },
            .virtual_buffers = .{},
            .buffer_graph = try .init(alloc),
        };
        return self;
    }

    pub fn deinit(self: *BufferMgr, io: Io, alloc: Allocator) void {
        self.buffer_graph.deinit();
        {
            self.process_buffers.m.lockUncancelable(io);
            {
                var iter = self.process_buffers.map.iterator();
                while (iter.next()) |i| i.value_ptr.*.deinit();
            }
            self.process_buffers.m.unlock(io);
        }
        self.process_buffers.map.deinit(alloc);

        var iter = self.virtual_buffers.iterator();
        while (iter.next()) |i| i.value_ptr.*.deinit();
        alloc.destroy(self);
    }

    pub fn create_process_buffer(self: *BufferMgr, io: Io, alloc: Allocator) !PBufferAndId {
        const id = uuid.newV4(io);
        const buffer = try ProcessBuffer.init(io, alloc);

        buffer.strid = self.strid_counter.new_id(io);
        buffer.id = id;
        buffer.merge_graph = .{
            .handle = try self.buffer_graph.createNode(buffer),
            .ptr = &self.buffer_graph,
        };

        // TODO: create the graph node for a process_buffer
        // needs a buffer to store a handle to a graph

        self.process_buffers.m.lockUncancelable(io);
        try self.process_buffers.map.put(alloc, id, buffer);
        self.process_buffers.m.unlock(io);
        errdefer {
            self.process_buffers.m.lockUncancelable(io);
            const keyvalue = self.process_buffers.map.fetchRemove(id);
            if (keyvalue) |kv| {
                kv.value.deinit();
            }
            self.process_buffers.m.unlock(io);
        }

        return .{ .id = id, .buffer = buffer };
    }

    pub fn remove_buffer(self: *BufferMgr, io: Io, id: uuid.UUID) void {
        // Note: there should be some check if we kill a link in the graph

        {
            // search through process first
            self.process_buffers.m.lockUncancelable(io);
            defer self.process_buffers.m.unlock(io);

            if (self.process_buffers.map.get(id)) |buffer| {
                buffer.deinit();
                _ = self.process_buffers.map.remove(id);
                return;
            }
        }

        // we didn't find a process, look through the virtual buffers
        if (self.virtual_buffers.get(id)) |buffer| {
            buffer.deinit();
            _ = self.process_buffers.map.remove(id);
            return;
        }
    }

    pub fn get_via_uuid(self: *BufferMgr, io: Io, id: uuid.UUID) ?*ProcessBuffer {
        {
            // search through process first
            self.process_buffers.m.lockUncancelable(io);
            defer self.process_buffers.m.unlock(io);

            if (self.process_buffers.map.get(id)) |buffer| {
                return buffer;
            }
        }

        // we didn't find a process, look through the virtual buffers
        if (self.virtual_buffers.get(id)) |buffer| {
            return buffer;
        }

        return null;
    }

    pub fn get_via_strid(self: *BufferMgr, io: Io, strid: []const u8) ?*ProcessBuffer {
        const id = BufferMgr.parse_strid(strid) catch return null;

        // search through process buffers
        {
            // search through process first
            self.process_buffers.m.lockUncancelable(io);
            defer self.process_buffers.m.unlock(io);

            var iter = self.process_buffers.map.valueIterator();
            while (iter.next()) |i| {
                if (i.strid == id) {
                    return i.*;
                }
            }
        }

        // search through virtual buffers
        var iter = self.virtual_buffers.valueIterator();
        while (iter.next()) |i| {
            if (i.strid == id) {
                return i.*;
            }
        }

        return null;
    }

    pub fn parse_strid(strid: []const u8) !usize {
        if (strid.len <= 1) return error.InvalidStrId;
        if (strid[0] != '!') return error.InvalidStrId;

        // parse integer
        return std.fmt.parseInt(usize, strid[1..strid.len], 10) catch error.InvalidStrId;
    }

    // TODO
    pub fn create_virtual_process_buffer(
        self: *BufferMgr,
        io: Io,
        alloc: Allocator,
        parents: []const uuid.UUID,
    ) !PBufferAndId {
        // we need to get all the parents
        var parent_buffers = try std.ArrayList(*ProcessBuffer).initCapacity(alloc, 1);
        defer parent_buffers.deinit(alloc);

        for (parents) |id| {
            const buf_ptr = self.get_via_uuid(io, id) orelse return error.InvalidBufferId;
            try parent_buffers.append(alloc, buf_ptr);
        }

        // create the virtual buffer
        const id = uuid.newV4(io);
        const new_buffer = try ProcessBuffer.init(io, alloc);

        new_buffer.id = id;
        new_buffer.strid = self.strid_counter.new_id(io);
        new_buffer.merge_graph = .{
            .handle = try self.buffer_graph.createNode(new_buffer),
            .ptr = &self.buffer_graph,
        };

        // create a link in the graph
        for (parent_buffers.items) |parent| {
            if (parent.merge_graph == null) {
                // init the merge graph reference
                parent.merge_graph = .{
                    .handle = try self.buffer_graph.createNode(parent),
                    .ptr = &self.buffer_graph,
                };
            }

            try self.buffer_graph.addChild(parent.merge_graph.?.handle, new_buffer.merge_graph.?.handle);
        }

        // TODO: probably need to lock parents from getting buffers
        var lines_and_metas = try std.ArrayList(LinesAndMeta).initCapacity(alloc, parents.len);
        for (parent_buffers.items) |pbuf| {
            try lines_and_metas.append(
                alloc,
                .{
                    .linebuffer = pbuf.buffer,
                    .timestamps = pbuf.line_timestamps,
                },
            );
        }

        const merged_lines_and_meta = try LinesAndMeta.merge_buffers_by_time(alloc, lines_and_metas.items);
        new_buffer.buffer = merged_lines_and_meta.linebuffer;
        new_buffer.line_timestamps = merged_lines_and_meta.timestamps;

        return .{ .id = id, .buffer = new_buffer };
    }
};
