const std = @import("std");
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;

const vxfw = vaxis.vxfw;

const SizedBox = @This();

// TODO: update this to allow for a min constraint
child: vxfw.Widget,
max_constraint: vxfw.Size,

pub fn widget(self: *const SizedBox) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *const SizedBox = @ptrCast(@alignCast(ptr));
    const max: vxfw.MaxSize = .{
        .width = if (ctx.max.width) |max_w| @min(max_w, self.max_constraint.width) else self.max_constraint.width,
        .height = if (ctx.max.height) |max_h| @min(max_h, self.max_constraint.height) else self.max_constraint.height,
    };
    const min: vxfw.Size = .{
        .width = @min(ctx.min.width, self.max_constraint.width),
        .height = @min(ctx.min.height, self.max_constraint.height),
    };

    return self.child.draw(ctx.withConstraints(min, max));
}
