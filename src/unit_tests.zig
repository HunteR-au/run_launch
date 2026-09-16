comptime {
    //_ = @import("ui/uiconfig.zig");

    _ = @import("ui/tui/output.zig");
    _ = @import("ui/tui/pipeline/processbuffer.zig");
    _ = @import("ui/tui/pipeline/styleindex.zig");
    _ = @import("ui/tui/pipeline/linebuffer.zig");
    _ = @import("ui/tui/pipeline/search.zig");
    _ = @import("ui/tui/pipeline/ingeststore.zig");
    _ = @import("ui/tui/pipeline/buffer/merge.zig");
    _ = @import("ui/tui/pipeline/buffer/acyclicgraph.zig");
    _ = @import("ui/tui/widgets/option_picker.zig");
    _ = @import("ui/tui/widgets/mutistyletext.zig");
    _ = @import("ui/tui/widgets/linenumbers.zig");
    _ = @import("ui/tui/outputwidget.zig");
    // the pump module has its own test compilation in build.zig (tests are only collected
    // from a compilation's root module)
}
