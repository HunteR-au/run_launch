const std = @import("std");
const utils = @import("utils");
const vaxis = @import("vaxis");
const OptionPicker = @import("option_picker.zig");
const ConstraintBox = @import("generic/constraint_box.zig");
const AppModel = @import("../AppModel.zig");
const ProcessViewMgr = @import("../processviewmgr.zig");

const EntityViewer = @This();

const vxfw = vaxis.vxfw;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const UUID = utils.uuid.UUID;

pub const Objects = struct {
    pub const View = struct {
        id: usize,
        name: []const u8,
        guid: UUID,
        parent: ?UUID = null,

        /// `~N`: the notation `merge`/`stop` accept for a view
        pub fn to_string(self: *const View, alloc: Allocator) ![]u8 {
            return try std.fmt.allocPrint(alloc, "~{d}: {s}", .{ self.id, self.name });
        }
    };

    pub const Buffer = struct {
        id: usize,
        name: []const u8,
        guid: UUID,

        /// `!N`: the notation `merge`/`stop` accept for a buffer
        pub fn to_string(self: *const Buffer, alloc: Allocator) ![]u8 {
            return try std.fmt.allocPrint(alloc, "!{d}: {s}", .{ self.id, self.name });
        }
    };

    views: []View,
    buffers: []Buffer,
    arena: std.heap.ArenaAllocator,
    alloc: Allocator,

    pub fn deinit(self: *Objects) void {
        self.arena.deinit();
    }
};

pub fn create_objects(alloc: Allocator, app_model: *AppModel, io: Io) !*Objects {
    var objects = try alloc.create(Objects);

    objects.* = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .alloc = undefined,
        .views = &.{},
        .buffers = &.{},
    };
    objects.alloc = objects.arena.allocator();

    // Parse all OutputWidgets to construct the view data
    var view_list = try std.ArrayList(Objects.View).initCapacity(objects.alloc, 5);
    var view_iter = ProcessViewMgr.get_view_list_iterator(app_model);
    while (view_iter.next()) |view| {
        try view_list.append(objects.alloc, .{
            .id = view.strid,
            .name = try objects.alloc.dupe(u8, view.process_name),
            .guid = view.id,
            // parents are a todo
        });
    }
    objects.views = try view_list.toOwnedSlice(objects.alloc);

    // The UI mirror of the pump-owned buffers
    _ = io;
    var buf_list = try std.ArrayList(Objects.Buffer).initCapacity(objects.alloc, 5);
    for (app_model.buffer_infos.items) |info| {
        try buf_list.append(objects.alloc, .{
            .id = info.strid,
            .name = try objects.alloc.dupe(u8, info.name),
            .guid = info.id,
        });
    }
    objects.buffers = try buf_list.toOwnedSlice(objects.alloc);

    return objects;
}

inner_widget: *OptionPicker,
title: []const u8 = "Views(~n) and Buffers(!n)",
objects: ?*Objects = null,

/// Objects is expected to be allocated and owned by the EntityViewer
pub fn init(alloc: Allocator, objects: ?*Objects) Allocator.Error!*EntityViewer {
    const self = try alloc.create(@This());

    var items_array = try std.ArrayList([]u8).initCapacity(alloc, 10);
    defer items_array.deinit(alloc);

    if (objects) |obj| {
        for (obj.views) |view| {
            try items_array.append(alloc, try view.to_string(alloc));
        }
        for (obj.buffers) |buf| {
            try items_array.append(alloc, try buf.to_string(alloc));
        }
    }

    self.* = .{
        .inner_widget = undefined,
        .objects = if (objects) |obj| obj else null,
    };
    self.inner_widget = try .init(
        alloc,
        self.title,
        try items_array.toOwnedSlice(alloc),
    );

    return self;
}

pub fn deinit(self: *EntityViewer, alloc: Allocator) void {
    if (self.objects) |objects| {
        objects.deinit();
        alloc.destroy(objects);
    }
    self.inner_widget.deinit();
    alloc.destroy(self);
}

pub fn update_objects(self: *EntityViewer, alloc: Allocator, objects: ?*Objects) Allocator.Error!void {
    if (self.objects) |obj| {
        // clean up the objects struct
        obj.deinit();
        alloc.destroy(obj);
        self.objects = null;
        self.inner_widget.deinit(alloc);
    }

    self.objects = objects;

    var items_array = try std.ArrayList([]u8).initCapacity(alloc, 10);
    defer items_array.deinit(alloc);

    if (self.objects) |obj| {
        for (obj.views) |view| {
            try items_array.append(alloc, try view.to_string(alloc));
        }
        for (obj.buffers) |buf| {
            try items_array.append(alloc, try buf.to_string(alloc));
        }
    }
    // TODO: probably should be just a update items...
    self.inner_widget = try .init(
        alloc,
        self.title,
        try items_array.toOwnedSlice(alloc),
    );
}

pub fn widget(self: *@This()) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *@This() = @ptrCast(@alignCast(ptr));
    return self.handleEvent(ctx, event);
}

pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    var self: *@This() = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn handleEvent(self: *@This(), ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    return self.inner_widget.handleEvent(ctx, event);
}

pub fn draw(self: *@This(), ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const max_size = ctx.max.size();

    const sized_box: ConstraintBox = .{
        .child = self.inner_widget.widget(),
        .max_constraint = .{
            .width = @divFloor(max_size.width, 2),
            .height = @divFloor(max_size.height, 2),
        },
    };
    const center: vxfw.Center = .{ .child = sized_box.widget() };

    const child: vxfw.SubSurface = .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = try center.draw(ctx),
    };

    const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
    children[0] = child;

    return .{
        .size = max_size,
        .widget = self.widget(),
        .buffer = &.{},
        .children = children,
    };
}
