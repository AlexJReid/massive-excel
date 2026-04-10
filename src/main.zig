// Welcome to ZigXLL :) Add your function modules here.

const std = @import("std");
const xll = @import("xll");
const config = @import("config.zig");

pub const function_modules = .{
    @import("functions.zig"),
};

pub const rtd_servers = .{
    @import("massive_rtd.zig"),
};

/// Called by the framework during xlAutoOpen, after function/RTD registration.
/// We use it to pre-validate the Massive API key and, on failure, surface a
/// dialog so users immediately see what's wrong. Returning success means the
/// XLL still loads — the RTD worker will keep retrying on every reconnect, so
/// dropping `massive_api_key.txt` in place (or setting `$MASSIVE_API_KEY`)
/// recovers without an Excel restart.
pub fn init() !void {
    const key = config.loadApiKey(std.heap.c_allocator) catch |err| {
        const msg = std.fmt.allocPrint(
            std.heap.c_allocator,
            "Massive API key not found ({s}).\n\n" ++
                "Place a file named 'massive_api_key.txt' containing your key " ++
                "in the same directory as standalone.xll, or set the " ++
                "MASSIVE_API_KEY environment variable.\n\n" ++
                "The XLL will keep retrying — no restart needed once the key is in place.",
            .{@errorName(err)},
        ) catch return;
        defer std.heap.c_allocator.free(msg);
        showAlert(msg);
        return;
    };
    std.heap.c_allocator.free(key);
}

fn showAlert(text: []const u8) void {
    var msg = xll.XLValue.fromUtf8String(std.heap.c_allocator, text) catch return;
    defer msg.deinit();
    _ = xll.xl.Excel12f(xll.xl.xlcAlert, null, 1, &msg.m_val);
}
