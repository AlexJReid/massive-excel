const std = @import("std");
const xll = @import("xll");
const ExcelFunction = xll.ExcelFunction;
const ParamMeta = xll.ParamMeta;

const allocator = std.heap.c_allocator;

// Example custom function
pub const double = ExcelFunction(.{
    .name = "dblit",
    .description = "Double a number",
    .category = "Zig Functions",
    .params = &[_]ParamMeta{
        .{ .name = "x", .description = "Number to double" },
    },
    .func = doubleFunc,
});

fn doubleFunc(x: f64) !f64 {
    return x * 2;
}

// RTD wrapper — use =TIMER() instead of =RTD("standalone.timer", , "tick")
pub const timer = ExcelFunction(.{
    .name = "TIMER",
    .description = "Live ticking counter (RTD wrapper)",
    .category = "Zig Functions",
    .thread_safe = false,
    .params = &[_]ParamMeta{},
    .func = timerFunc,
});

fn timerFunc() !*xll.xl.XLOPER12 {
    return xll.rtd_call.subscribe("standalone.timer", &.{"tick"});
}
