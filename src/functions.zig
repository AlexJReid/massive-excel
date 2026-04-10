const std = @import("std");
const xll = @import("xll");
const ExcelFunction = xll.ExcelFunction;
const ParamMeta = xll.ParamMeta;

// Convenience wrapper so users can write =MASSIVE("T.AAPL.p") instead of
// =RTD("zigxll-connectors-massive",,"T.AAPL.p").
pub const massive = ExcelFunction(.{
    .name = "MASSIVE",
    .description = "Subscribe to a Massive WebSocket topic (e.g. T.AAPL.p)",
    .category = "Massive",
    .thread_safe = false,
    .params = &[_]ParamMeta{
        .{ .name = "topic", .description = "Topic string, e.g. T.AAPL.p or Q.MSFT.bp" },
    },
    .func = massiveFunc,
});

fn massiveFunc(topic: []const u8) !*xll.xl.XLOPER12 {
    return xll.rtd_call.subscribeDynamic("zigxll-connectors-massive", &.{topic});
}
