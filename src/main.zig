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
/// XLL still loads - the RTD worker re-reads the cached config on every
/// connect attempt, so fixing the config and restarting Excel recovers.
pub fn init() !void {
    const cfg = config.load();
    if (cfg.api_key == null) {
        const msg =
            "Massive API key not configured.\n\n" ++
            "Set MASSIVE_API_KEY in the environment, or add an \"api_key\" " ++
            "field to a config.json file in the same directory as the XLL " ++
            "(or in %APPDATA%\\zigxll-massive\\config.json).";
        showAlert(msg);
    }
}

fn showAlert(text: []const u8) void {
    var msg = xll.XLValue.fromUtf8String(std.heap.c_allocator, text) catch return;
    defer msg.deinit();
    _ = xll.xl.Excel12f(xll.xl.xlcAlert, null, 1, &msg.m_val);
}
