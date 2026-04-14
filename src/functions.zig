const std = @import("std");
const xll = @import("xll");
const ExcelFunction = xll.ExcelFunction;
const ParamMeta = xll.ParamMeta;

// Excel UDFs exposed by this XLL.
//
// There are 25 per-market wrappers plus the generic escape hatch
// =MASSIVE(topic, [market]). Each per-market wrapper names the Massive feed
// in its own identifier, so =MASSIVE.STOCKS.TRADE("AAPL") and
// =MASSIVE.CRYPTO.TRADE("BTC-USD") are unambiguous - no second string arg,
// no chance of sending a stocks-shaped channel into a crypto socket.
//
// The wrappers are declared via the `wrapper(meta)` helper further down.
// It's a comptime function that returns an ExcelFunction type, with the
// description, field help, and func body generated from a single
// WrapperMeta value per call site. The ZigXLL framework discovers UDFs by
// walking top-level pub decls of this module (see `function_discovery.zig`
// in the framework), so each wrapper has to be its own named pub const -
// but the repetition stops at the name.
//
// Field tables per event prefix live in constants at the bottom of the
// file; multiple wrappers can share a table when the shape is identical.

// === Generic escape hatch ============================================

pub const massive = ExcelFunction(.{ .name = "MASSIVE", .description = "Raw Massive topic subscription. Use when no per-market wrapper fits. See massive.com/docs/websocket/quickstart", .category = "Massive", .thread_safe = false, .params = &[_]ParamMeta{
    .{ .name = "topic", .description = "<ev>.<sym>[.<field>] e.g. T.AAPL.p, XT.BTC-USD.p, C.EUR-USD.a" },
    .{ .name = "market", .description = "stocks, options, forex, crypto, indices, or futures (default from build)" },
}, .func = massiveFunc });

fn massiveFunc(topic: []const u8, market: ?[]const u8) !*xll.xl.XLOPER12 {
    return subscribe(topic, market);
}

// === Per-market wrappers =============================================
// 25 wrappers, one per (market, event) that we can currently dispatch
// reliably. Two known gaps, both intentional:
//   1. Options & futures per-second aggregates are omitted. Docs show the
//      payload carries ev:"AM" on both /A and /AM paths, which would
//      collide with per-minute aggregates on our dispatch (keyed by
//      "<ev>.<sym>"). Revisit when this is confirmed against a live feed.
//   2. Stocks NOI (net order imbalance) - doc URL not located when these
//      wrappers were written. Add once the prefix and field list are
//      confirmed.

// --- Stocks ---

pub const massive_stocks_trade = wrapper("MASSIVE.STOCKS.TRADE", .{
    .market = "stocks",
    .ev = "T",
    .default_field = "p",
    .sym_label = "Stock ticker, e.g. AAPL",
    .fields = &stock_trade_fields,
    .summary = "Stocks trade tick",
});

pub const massive_stocks_quote = wrapper("MASSIVE.STOCKS.QUOTE", .{
    .market = "stocks",
    .ev = "Q",
    .default_field = "ap",
    .sym_label = "Stock ticker, e.g. AAPL",
    .fields = &stock_quote_fields,
    .summary = "Stocks NBBO quote",
});

pub const massive_stocks_agg_minute = wrapper("MASSIVE.STOCKS.AGG_MINUTE", .{
    .market = "stocks",
    .ev = "AM",
    .default_field = "c",
    .sym_label = "Stock ticker, e.g. AAPL",
    .fields = &stock_agg_fields,
    .summary = "Stocks minute OHLCV bar",
});

pub const massive_stocks_agg_second = wrapper("MASSIVE.STOCKS.AGG_SECOND", .{
    .market = "stocks",
    .ev = "A",
    .default_field = "c",
    .sym_label = "Stock ticker, e.g. AAPL",
    .fields = &stock_agg_fields,
    .summary = "Stocks second OHLCV bar",
});

pub const massive_stocks_fmv = wrapper("MASSIVE.STOCKS.FMV", .{
    .market = "stocks",
    .ev = "FMV",
    .default_field = "fmv",
    .sym_label = "Stock ticker, e.g. AAPL",
    .fields = &fmv_fields,
    .summary = "Stocks fair market value (Business plan)",
});

pub const massive_stocks_luld = wrapper("MASSIVE.STOCKS.LULD", .{
    .market = "stocks",
    .ev = "LULD",
    .default_field = "h",
    .sym_label = "Stock ticker, e.g. AAPL",
    .fields = &luld_fields,
    .summary = "Stocks limit-up/limit-down price bands",
});

// --- Options ---

pub const massive_options_trade = wrapper("MASSIVE.OPTIONS.TRADE", .{
    .market = "options",
    .ev = "T",
    .default_field = "p",
    .sym_label = "Option contract, e.g. O:SPY251219C00600000",
    .fields = &option_trade_fields,
    .summary = "Options trade tick",
});

pub const massive_options_quote = wrapper("MASSIVE.OPTIONS.QUOTE", .{
    .market = "options",
    .ev = "Q",
    .default_field = "ap",
    .sym_label = "Option contract, e.g. O:SPY251219C00600000",
    .fields = &option_quote_fields,
    .summary = "Options quote",
});

pub const massive_options_agg_minute = wrapper("MASSIVE.OPTIONS.AGG_MINUTE", .{
    .market = "options",
    .ev = "AM",
    .default_field = "c",
    .sym_label = "Option contract, e.g. O:SPY251219C00600000",
    .fields = &option_agg_fields,
    .summary = "Options minute OHLCV bar",
});

pub const massive_options_fmv = wrapper("MASSIVE.OPTIONS.FMV", .{
    .market = "options",
    .ev = "FMV",
    .default_field = "fmv",
    .sym_label = "Option contract, e.g. O:SPY251219C00600000",
    .fields = &fmv_fields,
    .summary = "Options fair market value (Business plan)",
});

// --- Forex ---

pub const massive_forex_quote = wrapper("MASSIVE.FOREX.QUOTE", .{
    .market = "forex",
    .ev = "C",
    .default_field = "a",
    .sym_label = "Currency pair, e.g. EUR-USD",
    .fields = &forex_quote_fields,
    .summary = "Forex quote (BBO)",
});

pub const massive_forex_agg_minute = wrapper("MASSIVE.FOREX.AGG_MINUTE", .{
    .market = "forex",
    .ev = "CA",
    .default_field = "c",
    .sym_label = "Currency pair, e.g. EUR-USD",
    .fields = &forex_agg_fields,
    .summary = "Forex minute OHLCV bar",
});

pub const massive_forex_agg_second = wrapper("MASSIVE.FOREX.AGG_SECOND", .{
    .market = "forex",
    .ev = "CAS",
    .default_field = "c",
    .sym_label = "Currency pair, e.g. EUR-USD",
    .fields = &forex_agg_fields,
    .summary = "Forex second OHLCV bar",
});

pub const massive_forex_fmv = wrapper("MASSIVE.FOREX.FMV", .{
    .market = "forex",
    .ev = "FMV",
    .default_field = "fmv",
    .sym_label = "Currency pair, e.g. EUR-USD",
    .fields = &fmv_fields,
    .summary = "Forex fair market value (Business plan)",
});

// --- Crypto ---

pub const massive_crypto_trade = wrapper("MASSIVE.CRYPTO.TRADE", .{
    .market = "crypto",
    .ev = "XT",
    .default_field = "p",
    .sym_label = "Crypto pair, e.g. BTC-USD",
    .fields = &crypto_trade_fields,
    .summary = "Crypto trade tick",
});

pub const massive_crypto_quote = wrapper("MASSIVE.CRYPTO.QUOTE", .{
    .market = "crypto",
    .ev = "XQ",
    .default_field = "ap",
    .sym_label = "Crypto pair, e.g. BTC-USD",
    .fields = &crypto_quote_fields,
    .summary = "Crypto quote (BBO)",
});

pub const massive_crypto_agg_minute = wrapper("MASSIVE.CRYPTO.AGG_MINUTE", .{
    .market = "crypto",
    .ev = "XA",
    .default_field = "c",
    .sym_label = "Crypto pair, e.g. BTC-USD",
    .fields = &crypto_agg_fields,
    .summary = "Crypto minute OHLCV bar",
});

pub const massive_crypto_agg_second = wrapper("MASSIVE.CRYPTO.AGG_SECOND", .{
    .market = "crypto",
    .ev = "XAS",
    .default_field = "c",
    .sym_label = "Crypto pair, e.g. BTC-USD",
    .fields = &crypto_agg_fields,
    .summary = "Crypto second OHLCV bar",
});

pub const massive_crypto_fmv = wrapper("MASSIVE.CRYPTO.FMV", .{
    .market = "crypto",
    .ev = "FMV",
    .default_field = "fmv",
    .sym_label = "Crypto pair, e.g. BTC-USD",
    .fields = &fmv_fields,
    .summary = "Crypto fair market value (Business plan)",
});

// --- Indices ---

pub const massive_indices_value = wrapper("MASSIVE.INDICES.VALUE", .{
    .market = "indices",
    .ev = "V",
    .default_field = "val",
    .sym_label = "Index, e.g. I:SPX",
    .fields = &index_value_fields,
    .summary = "Index value tick",
});

pub const massive_indices_agg_minute = wrapper("MASSIVE.INDICES.AGG_MINUTE", .{
    .market = "indices",
    .ev = "AM",
    .default_field = "c",
    .sym_label = "Index, e.g. I:SPX",
    .fields = &index_agg_fields,
    .summary = "Index minute OHLC bar",
});

pub const massive_indices_agg_second = wrapper("MASSIVE.INDICES.AGG_SECOND", .{
    .market = "indices",
    .ev = "A",
    .default_field = "c",
    .sym_label = "Index, e.g. I:SPX",
    .fields = &index_agg_fields,
    .summary = "Index second OHLC bar",
});

// --- Futures ---

pub const massive_futures_trade = wrapper("MASSIVE.FUTURES.TRADE", .{
    .market = "futures",
    .ev = "T",
    .default_field = "p",
    .sym_label = "Futures contract, e.g. ESZ4",
    .fields = &futures_trade_fields,
    .summary = "Futures trade tick",
});

pub const massive_futures_quote = wrapper("MASSIVE.FUTURES.QUOTE", .{
    .market = "futures",
    .ev = "Q",
    .default_field = "ap",
    .sym_label = "Futures contract, e.g. ESZ4",
    .fields = &futures_quote_fields,
    .summary = "Futures quote",
});

pub const massive_futures_agg_minute = wrapper("MASSIVE.FUTURES.AGG_MINUTE", .{
    .market = "futures",
    .ev = "AM",
    .default_field = "c",
    .sym_label = "Futures contract, e.g. ESZ4",
    .fields = &futures_agg_fields,
    .summary = "Futures minute OHLCV bar",
});

// === Helper: generate an ExcelFunction from a WrapperMeta ============

const FieldDoc = struct {
    code: []const u8,
    meaning: []const u8,
};

const WrapperMeta = struct {
    market: []const u8,
    ev: []const u8,
    default_field: []const u8,
    sym_label: []const u8,
    fields: []const FieldDoc,
    summary: []const u8,
};

// `name` is passed as `anytype` so its compile-time type stays a
// `*const [N:0]u8` string-literal pointer. The framework's
// `sanitizeExportName` uses `name.len` at comptime to stamp out the
// exported symbol and requires that concrete array-pointer shape - a
// `[]const u8` slice doesn't carry the length in its type.
fn wrapper(comptime name: anytype, comptime m: WrapperMeta) type {
    const desc = comptime buildDescription(name, m);
    const field_help = comptime buildFieldHelp(m);
    return ExcelFunction(.{
        .name = name,
        .description = desc,
        .category = "Massive",
        .thread_safe = false,
        .params = &[_]ParamMeta{
            .{ .name = "sym", .description = m.sym_label },
            .{ .name = "field", .description = field_help },
        },
        .func = struct {
            fn f(sym: []const u8, field: ?[]const u8) !*xll.xl.XLOPER12 {
                return subscribeEvent(m.ev, sym, field, m.market);
            }
        }.f,
    });
}

// Build "<summary> (<ev>.<sym> on /<market>). Default field: <default>."
// Stays under Excel's 255-char xlfRegister limit for every wrapper we ship.
fn buildDescription(comptime _: anytype, comptime m: WrapperMeta) []const u8 {
    return std.fmt.comptimePrint(
        "{s} ({s}.<sym> on /{s}). Default field: {s}.",
        .{ m.summary, m.ev, m.market, m.default_field },
    );
}

// Build "Default <d>. Fields: code=meaning, code=meaning, ..."
// - truncation guard keeps the string under 240 chars so Excel's arg tooltip
//   cap (~255) is comfortable. If we go over, trailing fields are dropped
//   with a "..." marker. In practice every event we ship fits cleanly.
fn buildFieldHelp(comptime m: WrapperMeta) []const u8 {
    comptime var buf: []const u8 = std.fmt.comptimePrint("Default {s}. Fields: ", .{m.default_field});
    comptime var first = true;
    comptime var truncated = false;
    inline for (m.fields) |fd| {
        const chunk = if (first)
            std.fmt.comptimePrint("{s}={s}", .{ fd.code, fd.meaning })
        else
            std.fmt.comptimePrint(", {s}={s}", .{ fd.code, fd.meaning });
        if (buf.len + chunk.len > 240) {
            truncated = true;
            break;
        }
        buf = buf ++ chunk;
        first = false;
    }
    if (truncated) buf = buf ++ ", ...";
    return buf;
}

// === Field documentation tables ======================================
// One table per (event shape), shared between markets where the shape is
// identical. Meanings are short because Excel's arg tooltip is tight; the
// authoritative descriptions live in the per-endpoint docs on massive.com.

const stock_trade_fields = [_]FieldDoc{
    .{ .code = "p", .meaning = "price" },
    .{ .code = "s", .meaning = "size" },
    .{ .code = "t", .meaning = "ts_ms" },
    .{ .code = "x", .meaning = "exch" },
    .{ .code = "i", .meaning = "trade_id" },
    .{ .code = "z", .meaning = "tape" },
    .{ .code = "q", .meaning = "seq" },
};

const stock_quote_fields = [_]FieldDoc{
    .{ .code = "bp", .meaning = "bid_px" },
    .{ .code = "bs", .meaning = "bid_sz" },
    .{ .code = "ap", .meaning = "ask_px" },
    .{ .code = "as", .meaning = "ask_sz" },
    .{ .code = "bx", .meaning = "bid_exch" },
    .{ .code = "ax", .meaning = "ask_exch" },
    .{ .code = "t", .meaning = "ts_ms" },
    .{ .code = "z", .meaning = "tape" },
    .{ .code = "q", .meaning = "seq" },
};

// Stocks AM/A share a shape. Options AM and futures AM reuse a subset and
// are covered by their own trimmed tables below.
const stock_agg_fields = [_]FieldDoc{
    .{ .code = "o", .meaning = "open" },
    .{ .code = "h", .meaning = "high" },
    .{ .code = "l", .meaning = "low" },
    .{ .code = "c", .meaning = "close" },
    .{ .code = "v", .meaning = "volume" },
    .{ .code = "a", .meaning = "vwap_day" },
    .{ .code = "vw", .meaning = "vwap_bar" },
    .{ .code = "op", .meaning = "open_day" },
    .{ .code = "av", .meaning = "cum_vol" },
    .{ .code = "z", .meaning = "avg_trade_sz" },
    .{ .code = "s", .meaning = "start_ms" },
    .{ .code = "e", .meaning = "end_ms" },
};

const fmv_fields = [_]FieldDoc{
    .{ .code = "fmv", .meaning = "fair_value" },
    .{ .code = "t", .meaning = "ts_ns" },
};

const luld_fields = [_]FieldDoc{
    .{ .code = "h", .meaning = "upper_band" },
    .{ .code = "l", .meaning = "lower_band" },
    .{ .code = "z", .meaning = "tape" },
    .{ .code = "t", .meaning = "ts_ms" },
    .{ .code = "q", .meaning = "seq" },
};

const option_trade_fields = [_]FieldDoc{
    .{ .code = "p", .meaning = "price" },
    .{ .code = "s", .meaning = "contracts" },
    .{ .code = "t", .meaning = "ts_ms" },
    .{ .code = "x", .meaning = "exch" },
    .{ .code = "q", .meaning = "seq" },
};

const option_quote_fields = [_]FieldDoc{
    .{ .code = "bp", .meaning = "bid_px" },
    .{ .code = "bs", .meaning = "bid_sz" },
    .{ .code = "ap", .meaning = "ask_px" },
    .{ .code = "as", .meaning = "ask_sz" },
    .{ .code = "bx", .meaning = "bid_exch" },
    .{ .code = "ax", .meaning = "ask_exch" },
    .{ .code = "t", .meaning = "ts_ms" },
    .{ .code = "q", .meaning = "seq" },
};

const option_agg_fields = [_]FieldDoc{
    .{ .code = "o", .meaning = "open" },
    .{ .code = "h", .meaning = "high" },
    .{ .code = "l", .meaning = "low" },
    .{ .code = "c", .meaning = "close" },
    .{ .code = "v", .meaning = "volume" },
    .{ .code = "a", .meaning = "vwap_day" },
    .{ .code = "vw", .meaning = "vwap_bar" },
    .{ .code = "op", .meaning = "open_day" },
    .{ .code = "av", .meaning = "cum_vol" },
    .{ .code = "z", .meaning = "avg_trade_sz" },
    .{ .code = "s", .meaning = "start_ms" },
    .{ .code = "e", .meaning = "end_ms" },
};

const forex_quote_fields = [_]FieldDoc{
    .{ .code = "a", .meaning = "ask_px" },
    .{ .code = "b", .meaning = "bid_px" },
    .{ .code = "x", .meaning = "exch" },
    .{ .code = "t", .meaning = "ts_ms" },
};

const forex_agg_fields = [_]FieldDoc{
    .{ .code = "o", .meaning = "open" },
    .{ .code = "h", .meaning = "high" },
    .{ .code = "l", .meaning = "low" },
    .{ .code = "c", .meaning = "close" },
    .{ .code = "v", .meaning = "tick_count" },
    .{ .code = "s", .meaning = "start_ms" },
    .{ .code = "e", .meaning = "end_ms" },
};

const crypto_trade_fields = [_]FieldDoc{
    .{ .code = "p", .meaning = "price" },
    .{ .code = "s", .meaning = "size" },
    .{ .code = "t", .meaning = "ts_ms" },
    .{ .code = "x", .meaning = "exch" },
    .{ .code = "i", .meaning = "trade_id" },
    .{ .code = "c", .meaning = "cond" },
    .{ .code = "r", .meaning = "recv_ms" },
};

const crypto_quote_fields = [_]FieldDoc{
    .{ .code = "bp", .meaning = "bid_px" },
    .{ .code = "bs", .meaning = "bid_sz" },
    .{ .code = "ap", .meaning = "ask_px" },
    .{ .code = "as", .meaning = "ask_sz" },
    .{ .code = "x", .meaning = "exch" },
    .{ .code = "t", .meaning = "ts_ms" },
    .{ .code = "r", .meaning = "recv_ms" },
};

const crypto_agg_fields = [_]FieldDoc{
    .{ .code = "o", .meaning = "open" },
    .{ .code = "h", .meaning = "high" },
    .{ .code = "l", .meaning = "low" },
    .{ .code = "c", .meaning = "close" },
    .{ .code = "v", .meaning = "volume" },
    .{ .code = "vw", .meaning = "vwap" },
    .{ .code = "z", .meaning = "avg_tx_sz" },
    .{ .code = "s", .meaning = "start_ms" },
    .{ .code = "e", .meaning = "end_ms" },
};

const index_value_fields = [_]FieldDoc{
    .{ .code = "val", .meaning = "index_val" },
    .{ .code = "t", .meaning = "ts_ms" },
};

const index_agg_fields = [_]FieldDoc{
    .{ .code = "o", .meaning = "open" },
    .{ .code = "h", .meaning = "high" },
    .{ .code = "l", .meaning = "low" },
    .{ .code = "c", .meaning = "close" },
    .{ .code = "op", .meaning = "open_day" },
    .{ .code = "s", .meaning = "start_ms" },
    .{ .code = "e", .meaning = "end_ms" },
};

const futures_trade_fields = [_]FieldDoc{
    .{ .code = "p", .meaning = "price" },
    .{ .code = "s", .meaning = "contracts" },
    .{ .code = "t", .meaning = "ts_ms" },
    .{ .code = "q", .meaning = "seq" },
};

const futures_quote_fields = [_]FieldDoc{
    .{ .code = "bp", .meaning = "bid_px" },
    .{ .code = "bs", .meaning = "bid_sz" },
    .{ .code = "ap", .meaning = "ask_px" },
    .{ .code = "as", .meaning = "ask_sz" },
    .{ .code = "bt", .meaning = "bid_ts_ms" },
    .{ .code = "at", .meaning = "ask_ts_ms" },
    .{ .code = "t", .meaning = "ts_ms" },
};

const futures_agg_fields = [_]FieldDoc{
    .{ .code = "o", .meaning = "open" },
    .{ .code = "h", .meaning = "high" },
    .{ .code = "l", .meaning = "low" },
    .{ .code = "c", .meaning = "close" },
    .{ .code = "v", .meaning = "volume" },
    .{ .code = "dv", .meaning = "dollar_vol" },
    .{ .code = "n", .meaning = "tx_count" },
    .{ .code = "s", .meaning = "start_ms" },
    .{ .code = "e", .meaning = "end_ms" },
};

// === Subscribe plumbing ==============================================

fn subscribeEvent(ev: []const u8, sym: []const u8, field: ?[]const u8, market: ?[]const u8) !*xll.xl.XLOPER12 {
    var buf: [128]u8 = undefined;
    const topic = if (field) |f|
        try std.fmt.bufPrint(&buf, "{s}.{s}.{s}", .{ ev, sym, f })
    else
        try std.fmt.bufPrint(&buf, "{s}.{s}", .{ ev, sym });
    return subscribe(topic, market);
}

fn subscribe(topic: []const u8, market: ?[]const u8) !*xll.xl.XLOPER12 {
    if (market) |m| {
        return xll.rtd_call.subscribeDynamic("zigxll.connectors.massive", &.{ topic, m });
    }
    return xll.rtd_call.subscribeDynamic("zigxll.connectors.massive", &.{topic});
}
