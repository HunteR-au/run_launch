const std = @import("std");
const utils = @import("utils");
const buffer_ = @import("pipeline/buffer/buffer.zig");
const LinesAndMeta = @import("pipeline/linesandmeta.zig").LinesAndMeta;

const uuid = utils.uuid;

const ProcessBuffer = buffer_.ProcessBuffer;
const BufferGraph = buffer_.BufferGraph;

const ProcessBuffersMap = struct {
    m: std.Thread.Mutex,
    map: std.AutoHashMapUnmanaged(uuid.UUID, *ProcessBuffer),
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

    pub fn init(alloc: std.mem.Allocator) !*BufferMgr {
        const self = try alloc.create(BufferMgr);
        self.* = .{
            .process_buffers = .{ .m = .{}, .map = .{} },
            .virtual_buffers = .{},
            .buffer_graph = try .init(alloc),
        };
        return self;
    }

    pub fn deinit(self: *BufferMgr, alloc: std.mem.Allocator) void {
        self.buffer_graph.deinit();
        {
            self.process_buffers.m.lock();
            {
                var iter = self.process_buffers.map.iterator();
                while (iter.next()) |i| i.value_ptr.*.deinit();
            }
            self.process_buffers.m.unlock();
        }
        self.process_buffers.map.deinit(alloc);

        var iter = self.virtual_buffers.iterator();
        while (iter.next()) |i| i.value_ptr.*.deinit();
        alloc.destroy(self);
    }

    pub fn create_process_buffer(self: *BufferMgr, alloc: std.mem.Allocator) !PBufferAndId {
        const id = uuid.newV4();
        const buffer = try ProcessBuffer.init(alloc);
        buffer.merge_graph = .{
            .handle = try self.buffer_graph.createNode(buffer),
            .ptr = &self.buffer_graph,
        };

        // TODO: create the graph node for a process_buffer
        // needs a buffer to store a handle to a graph

        self.process_buffers.m.lock();
        try self.process_buffers.map.put(alloc, id, buffer);
        self.process_buffers.m.unlock();
        errdefer {
            self.process_buffers.m.lock();
            const keyvalue = self.process_buffers.map.fetchRemove(id);
            if (keyvalue) |kv| {
                kv.value.deinit();
            }
            self.process_buffers.m.unlock();
        }

        return .{ .id = id, .buffer = buffer };
    }

    pub fn remove_buffer(self: *BufferMgr, id: uuid.UUID) void {
        // Note: there should be some check if we kill a link in the graph

        {
            // search through process first
            self.process_buffers.m.lock();
            defer self.process_buffers.m.unlock();

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

    pub fn get_buffer(self: *BufferMgr, id: uuid.UUID) ?*ProcessBuffer {
        {
            // search through process first
            self.process_buffers.m.lock();
            defer self.process_buffers.m.unlock();

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

    // TODO
    pub fn create_virtual_process_buffer(
        self: *BufferMgr,
        alloc: std.mem.Allocator,
        parents: []const uuid.UUID,
    ) !PBufferAndId {
        // we need to get all the parents
        var parent_buffers = try std.ArrayList(*ProcessBuffer).initCapacity(alloc, 1);
        defer parent_buffers.deinit(alloc);

        for (parents) |id| {
            const buf_ptr = self.get_buffer(id) orelse return error.InvalidBufferId;
            try parent_buffers.append(alloc, buf_ptr);
        }

        // create the virtual buffer
        const id = uuid.newV4();
        const new_buffer = try ProcessBuffer.init(alloc);
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
