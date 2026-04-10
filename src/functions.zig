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

// Per-event convenience wrappers. Each builds "<ev>.<sym>" or "<ev>.<sym>.<field>"
// and delegates to the same RTD server as =MASSIVE(). Field is optional — when
// omitted, the RTD handler applies defaultFieldFor(ev).
//
// subscribeDynamic copies the topic string, so a stack buffer is safe.

pub const massive_trade = ExcelFunction(.{
    .name = "MASSIVE.TRADE",
    .description = "Subscribe to Massive trade events (T.<sym>[.<field>])",
    .category = "Massive",
    .thread_safe = false,
    .params = &[_]ParamMeta{
        .{ .name = "sym", .description = "Ticker, e.g. AAPL" },
        .{ .name = "field", .description = "Optional field (p, s, ...); default p" },
    },
    .func = massiveTradeFunc,
});

fn massiveTradeFunc(sym: []const u8, field: ?[]const u8) !*xll.xl.XLOPER12 {
    return subscribeEvent("T", sym, field);
}

pub const massive_quote = ExcelFunction(.{
    .name = "MASSIVE.QUOTE",
    .description = "Subscribe to Massive quote events (Q.<sym>[.<field>])",
    .category = "Massive",
    .thread_safe = false,
    .params = &[_]ParamMeta{
        .{ .name = "sym", .description = "Ticker, e.g. AAPL" },
        .{ .name = "field", .description = "Optional field (bp, ap, ...); default ap" },
    },
    .func = massiveQuoteFunc,
});

fn massiveQuoteFunc(sym: []const u8, field: ?[]const u8) !*xll.xl.XLOPER12 {
    return subscribeEvent("Q", sym, field);
}

pub const massive_agg_min = ExcelFunction(.{
    .name = "MASSIVE.AGG_MIN",
    .description = "Subscribe to Massive per-minute aggregates (AM.<sym>[.<field>])",
    .category = "Massive",
    .thread_safe = false,
    .params = &[_]ParamMeta{
        .{ .name = "sym", .description = "Ticker, e.g. AAPL" },
        .{ .name = "field", .description = "Optional field (o, h, l, c, v, vw); default c" },
    },
    .func = massiveAggMinFunc,
});

fn massiveAggMinFunc(sym: []const u8, field: ?[]const u8) !*xll.xl.XLOPER12 {
    return subscribeEvent("AM", sym, field);
}

pub const massive_agg_sec = ExcelFunction(.{
    .name = "MASSIVE.AGG_SEC",
    .description = "Subscribe to Massive per-second aggregates (A.<sym>[.<field>])",
    .category = "Massive",
    .thread_safe = false,
    .params = &[_]ParamMeta{
        .{ .name = "sym", .description = "Ticker, e.g. AAPL" },
        .{ .name = "field", .description = "Optional field (o, h, l, c, v, vw); default c" },
    },
    .func = massiveAggSecFunc,
});

fn massiveAggSecFunc(sym: []const u8, field: ?[]const u8) !*xll.xl.XLOPER12 {
    return subscribeEvent("A", sym, field);
}

pub const massive_fmv = ExcelFunction(.{
    .name = "MASSIVE.FMV",
    .description = "Subscribe to Massive fair market value (FMV.<sym>[.<field>])",
    .category = "Massive",
    .thread_safe = false,
    .params = &[_]ParamMeta{
        .{ .name = "sym", .description = "Ticker, e.g. AAPL" },
        .{ .name = "field", .description = "Optional field; default fmv" },
    },
    .func = massiveFmvFunc,
});

fn massiveFmvFunc(sym: []const u8, field: ?[]const u8) !*xll.xl.XLOPER12 {
    return subscribeEvent("FMV", sym, field);
}

pub const massive_index = ExcelFunction(.{
    .name = "MASSIVE.INDEX",
    .description = "Subscribe to Massive index value (V.<sym>[.<field>])",
    .category = "Massive",
    .thread_safe = false,
    .params = &[_]ParamMeta{
        .{ .name = "sym", .description = "Index symbol" },
        .{ .name = "field", .description = "Optional field; default val" },
    },
    .func = massiveIndexFunc,
});

fn massiveIndexFunc(sym: []const u8, field: ?[]const u8) !*xll.xl.XLOPER12 {
    return subscribeEvent("V", sym, field);
}

fn subscribeEvent(ev: []const u8, sym: []const u8, field: ?[]const u8) !*xll.xl.XLOPER12 {
    var buf: [128]u8 = undefined;
    const topic = if (field) |f|
        try std.fmt.bufPrint(&buf, "{s}.{s}.{s}", .{ ev, sym, f })
    else
        try std.fmt.bufPrint(&buf, "{s}.{s}", .{ ev, sym });
    return xll.rtd_call.subscribeDynamic("zigxll-connectors-massive", &.{topic});
}
