const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const grapheme = vaxis.grapheme;
const DisplayWidth = @import("DisplayWidth")

Output = struct {

    pub const BufferWriter = struct {
        pub const Error = error{OutOfMemory};
        pub const Writer = std.io.GenericWriter(@This(), Error, write);

        allocator: std.mem.Allocator,
        buffer: *Buffer,
        gd: *const grapheme.GraphemeData,
        wd: *const DisplayWidth.DisplayWidthData,

        pub fn write(self: @This(), bytes: []const u8) Error!usize {
            try self.buffer.append(self.allocator, .{
                .bytes = bytes,
                .gd = self.gd,
                .wd = self.wd,
            });
            return bytes.len;
        }
    };
    
    pub const Buffer = struct {
        const StyleList = std.ArrayListUnmanaged(vaxis.Style);
        const StyleMap = std.HashMapUnmanaged(usize, usize, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage);
        
        pub const Content = struct {
            bytes: []const u8,
            gd: *const grapheme.GraphemeData,
            wd: *const DisplayWidth.DisplayWidthData,
        }
    };
    
    pub fn init(alloc: std.mem.Allocator) !Output {
        
    }  

    pub fn deinit(self: *Output) void {
        
    }

    pub fn widget(self: *Output) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Output.typeErasedEventHandler,
            .drawFn = Output.typeErasedDrawFn,
        };
    }
    
    pub fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Output = @ptrCast(@alignCast(ptr));
        return try self.draw(ctx);
    }
    
    pub fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Output = @ptrCast(@alignCast(ptr));
        return try self.handleEvent(ctx, event);
    }
    
    pub fn handleEvent(self: *Output, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        
    }

    pub fn draw(self: *Output, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        
    }
};
