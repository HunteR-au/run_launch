const utils = @import("utils");
const processbuffer_ = @import("../processbuffer.zig");
const Graph = @import("acyclicgraph.zig");

const uuid = utils.uuid;
pub const ProcessBuffer = processbuffer_.ProcessBuffer;

pub const BufferGraph = Graph.AcyclicGraph(ProcessBuffer);
pub const GraphHandle = Graph.Handle;
