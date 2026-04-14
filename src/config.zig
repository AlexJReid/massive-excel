// Runtime config for the Massive XLL + CLI.
//
// Loaded from a JSON file at startup. One binary now serves mock and prod;
// the config file decides which endpoint (and which API key) is used.
//
// API key precedence:
//   1. $MASSIVE_API_KEY environment variable (wins over everything — handy
//      for CI / ephemeral shells where you don't want a file on disk).
//   2. `api_key` field in config.json.
// If neither is set, `load()` returns a Config with `api_key == null` and
// callers (the RTD worker, the CLI, `init()`) will fail at use-time.

const std = @import("std");
const builtin = @import("builtin");
const opts = @import("massive_options");

const ENV_VAR = "MASSIVE_API_KEY";
const FILENAME = "config.json";
const APPDATA_SUBDIR = "massive-excel";
const MAX_FILE_SIZE = 64 * 1024;

/// Runtime configuration. All fields optional in JSON; missing fields fall
/// back to the corresponding `-D` build-time defaults.
pub const Config = struct {
    host: []const u8,
    port: u16,
    /// Default market path ("/stocks"). Used when a topic's market argument
    /// is empty. Always includes the leading slash.
    path: []const u8,
    insecure: bool,
    /// API key. Null if neither the env var nor the JSON file provided one;
    /// callers should treat that as a hard error.
    api_key: ?[]const u8,

    /// Returns the default market name (path with the leading slash stripped).
    pub fn defaultMarket(self: *const Config) []const u8 {
        const p = self.path;
        if (p.len > 0 and p[0] == '/') return p[1..];
        return p;
    }
};

/// JSON shape. Every field optional so partial config files are allowed.
const JsonConfig = struct {
    host: ?[]const u8 = null,
    port: ?u16 = null,
    path: ?[]const u8 = null,
    insecure: ?bool = null,
    api_key: ?[]const u8 = null,
};

/// Process-wide cached config. Populated on first `load()` call and kept
/// for the lifetime of the process — the config file is small and stable,
/// no need to re-read it on every reconnect.
var cached: ?Config = null;
var cache_mu: std.Thread.Mutex = .{};

/// Load config once and return a pointer to the process-wide copy.
///
/// The returned Config (and the strings inside it) live until process exit —
/// callers must NOT free them. Strings are owned by this module.
pub fn load() *const Config {
    cache_mu.lock();
    defer cache_mu.unlock();
    if (cached) |*c| return c;

    cached = buildConfig();
    return &cached.?;
}

fn buildConfig() Config {
    const alloc = std.heap.c_allocator;

    // Start from the build-time defaults. Anything the JSON file doesn't
    // override stays at these values.
    var cfg: Config = .{
        .host = opts.massive_host,
        .port = opts.massive_port,
        .path = opts.massive_path,
        .insecure = opts.massive_insecure,
        .api_key = null,
    };

    // Merge JSON file if one is reachable.
    if (readConfigFile(alloc)) |content| {
        defer alloc.free(content);
        mergeJsonInto(&cfg, alloc, content);
    }

    // Environment variable wins over the JSON file so rotating keys without
    // touching the config file still works (and so CI can inject a key
    // without leaving it on disk).
    if (std.process.getEnvVarOwned(alloc, ENV_VAR)) |env_val| {
        const trimmed = std.mem.trim(u8, env_val, " \t\r\n");
        if (trimmed.len > 0) {
            cfg.api_key = alloc.dupe(u8, trimmed) catch cfg.api_key;
        }
        alloc.free(env_val);
    } else |_| {}

    if (cfg.api_key == null) {
        warnLog(
            "config: no API key set — add \"api_key\" to config.json or export " ++
                ENV_VAR ++ ". connections will fail auth until this is fixed.",
            .{},
        );
    }

    return cfg;
}

/// Apply every field the JSON supplies to `cfg`, dup'ing strings onto `alloc`
/// so they outlive the parser's arena. Fields absent from the JSON, present
/// but empty (for `api_key`), or causing a dup failure are left untouched.
/// Malformed JSON is logged and otherwise swallowed — by design, so a corrupt
/// config file can't prevent the binary from starting.
pub fn mergeJsonInto(cfg: *Config, alloc: std.mem.Allocator, content: []const u8) void {
    const parsed = std.json.parseFromSlice(JsonConfig, alloc, content, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        // Bad JSON isn't fatal — fall back to defaults and let the caller
        // surface the issue (init() will alert if api_key is still null).
        debugLog("config: JSON parse error: {s}", .{@errorName(err)});
        return;
    };
    defer parsed.deinit();
    const j = parsed.value;
    if (j.host) |h| cfg.host = alloc.dupe(u8, h) catch cfg.host;
    if (j.port) |p| cfg.port = p;
    if (j.path) |p| cfg.path = alloc.dupe(u8, p) catch cfg.path;
    if (j.insecure) |i| cfg.insecure = i;
    if (j.api_key) |k| {
        const trimmed = std.mem.trim(u8, k, " \t\r\n");
        if (trimmed.len > 0) {
            cfg.api_key = alloc.dupe(u8, trimmed) catch null;
        }
    }
}

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    // Match the style of the nats repo: plain std.log so output shows up in
    // DbgView under Windows and stderr under the CLI.
    std.log.scoped(.massive_config).info(fmt, args);
}

fn warnLog(comptime fmt: []const u8, args: anytype) void {
    std.log.scoped(.massive_config).warn(fmt, args);
}

// ============================================================================
// File discovery
// ============================================================================

fn readConfigFile(alloc: std.mem.Allocator) ?[]u8 {
    if (builtin.os.tag == .windows) return readFromWindowsSearchPath(alloc);
    return readFromCliSearchPath(alloc);
}

fn readFromCliSearchPath(alloc: std.mem.Allocator) ?[]u8 {
    if (std.fs.cwd().readFileAlloc(alloc, FILENAME, MAX_FILE_SIZE)) |data| {
        debugLog("config: loaded from ./{s}", .{FILENAME});
        return data;
    } else |_| {}
    if (std.fs.cwd().readFileAlloc(alloc, "src/" ++ FILENAME, MAX_FILE_SIZE)) |data| {
        debugLog("config: loaded from ./src/{s}", .{FILENAME});
        return data;
    } else |_| {}
    debugLog("config: no config.json found in cwd or src/", .{});
    return null;
}

// ----- Win32 bindings for xplat (hand-declared to avoid a cImport) --------------------

const win = struct {
    const HMODULE = ?*anyopaque;
    const HANDLE = ?*anyopaque;
    const DWORD = u32;
    const BOOL = i32;
    const MAX_PATH = 260;
    const GENERIC_READ: DWORD = 0x80000000;
    const FILE_SHARE_READ: DWORD = 0x1;
    const OPEN_EXISTING: DWORD = 3;
    const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const INVALID_FILE_SIZE: DWORD = 0xFFFFFFFF;
    const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: DWORD = 0x04;
    const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: DWORD = 0x02;

    extern "kernel32" fn GetModuleHandleExA(
        dwFlags: DWORD,
        lpModuleName: ?*const anyopaque,
        phModule: *HMODULE,
    ) callconv(.c) BOOL;

    extern "kernel32" fn GetModuleFileNameA(
        hModule: HMODULE,
        lpFilename: [*]u8,
        nSize: DWORD,
    ) callconv(.c) DWORD;

    extern "kernel32" fn GetEnvironmentVariableA(
        lpName: [*:0]const u8,
        lpBuffer: [*]u8,
        nSize: DWORD,
    ) callconv(.c) DWORD;

    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: HANDLE,
    ) callconv(.c) HANDLE;

    extern "kernel32" fn GetFileSize(
        hFile: HANDLE,
        lpFileSizeHigh: ?*DWORD,
    ) callconv(.c) DWORD;

    extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: ?*DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.c) BOOL;

    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;
};

fn readFromWindowsSearchPath(alloc: std.mem.Allocator) ?[]u8 {
    // 1. Next to the XLL itself.
    if (getXllDirPath(alloc)) |dir| {
        defer alloc.free(dir);
        const path = std.fmt.allocPrintSentinel(alloc, "{s}\\{s}", .{ dir, FILENAME }, 0) catch return null;
        defer alloc.free(path);
        if (readFileWin32(alloc, path)) |data| {
            debugLog("config: loaded from {s}", .{path});
            return data;
        }
    }

    // 2. %APPDATA%\zigxll-massive\config.json
    if (getAppDataDir(alloc)) |dir| {
        defer alloc.free(dir);
        const path = std.fmt.allocPrintSentinel(alloc, "{s}\\{s}\\{s}", .{ dir, APPDATA_SUBDIR, FILENAME }, 0) catch return null;
        defer alloc.free(path);
        if (readFileWin32(alloc, path)) |data| {
            debugLog("config: loaded from {s}", .{path});
            return data;
        }
    }

    debugLog("config: no config.json found (checked XLL dir and %APPDATA%\\{s})", .{APPDATA_SUBDIR});
    return null;
}

fn readFileWin32(alloc: std.mem.Allocator, pathz: [:0]const u8) ?[]u8 {
    // Win32 file I/O — avoids std.fs quirks in cross-compiled XLL context
    // (documented in ../zigxll-nats/src/config.zig and CLAUDE.md).
    const handle = win.CreateFileA(
        pathz.ptr,
        win.GENERIC_READ,
        win.FILE_SHARE_READ,
        null,
        win.OPEN_EXISTING,
        win.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == win.INVALID_HANDLE_VALUE) return null;
    defer _ = win.CloseHandle(handle);

    const size = win.GetFileSize(handle, null);
    if (size == win.INVALID_FILE_SIZE or size == 0 or size > MAX_FILE_SIZE) return null;

    const buf = alloc.alloc(u8, size) catch return null;
    var bytes_read: win.DWORD = 0;
    const ok = win.ReadFile(handle, buf.ptr, size, &bytes_read, null);
    if (ok == 0 or bytes_read != size) {
        alloc.free(buf);
        return null;
    }
    return buf;
}

fn getXllDirPath(alloc: std.mem.Allocator) ?[]u8 {
    var hmod: win.HMODULE = null;
    const ok = win.GetModuleHandleExA(
        win.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @ptrCast(&getXllDirPath),
        &hmod,
    );
    if (ok == 0) return null;

    var buf: [win.MAX_PATH]u8 = undefined;
    const len = win.GetModuleFileNameA(hmod, &buf, win.MAX_PATH);
    if (len == 0) return null;

    const full = buf[0..len];
    const idx = std.mem.lastIndexOfScalar(u8, full, '\\') orelse return null;
    return alloc.dupe(u8, full[0..idx]) catch null;
}

fn getAppDataDir(alloc: std.mem.Allocator) ?[]u8 {
    var buf: [win.MAX_PATH]u8 = undefined;
    const len = win.GetEnvironmentVariableA("APPDATA", &buf, win.MAX_PATH);
    if (len == 0 or len >= win.MAX_PATH) return null;
    return alloc.dupe(u8, buf[0..len]) catch null;
}

// ============================================================================
// Tests
// ============================================================================
//
// These cover the pure JSON → Config merge. File discovery (Win32 CreateFileA,
// %APPDATA%, cwd search) and env-var handling are tested end-to-end by
// running the CLI against the mock — the bugs there are in path resolution
// and would pass any unit test we could write without a real filesystem.

fn testDefaults() Config {
    return .{
        .host = "default.example.com",
        .port = 443,
        .path = "/stocks",
        .insecure = false,
        .api_key = null,
    };
}

test "mergeJsonInto overlays every field present in the JSON" {
    const alloc = std.testing.allocator;
    // Defaults are static strings so mergeJsonInto's overwrite doesn't leak
    // (mirrors the real call site, where defaults come from build options
    // that are comptime constants, not heap allocations).
    var cfg = testDefaults();

    const json =
        \\{"host":"socket.massive.com","port":8443,"path":"/crypto",
        \\ "insecure":true,"api_key":"pk_live_test"}
    ;
    mergeJsonInto(&cfg, alloc, json);
    defer alloc.free(cfg.host);
    defer alloc.free(cfg.path);
    defer alloc.free(cfg.api_key.?);

    try std.testing.expectEqualStrings("socket.massive.com", cfg.host);
    try std.testing.expectEqual(@as(u16, 8443), cfg.port);
    try std.testing.expectEqualStrings("/crypto", cfg.path);
    try std.testing.expect(cfg.insecure);
    try std.testing.expectEqualStrings("pk_live_test", cfg.api_key.?);
}

test "mergeJsonInto leaves absent fields at their defaults" {
    const alloc = std.testing.allocator;
    var cfg = testDefaults();

    // Only api_key supplied — host/port/path/insecure must survive untouched.
    mergeJsonInto(&cfg, alloc, "{\"api_key\":\"k\"}");
    defer if (cfg.api_key) |k| alloc.free(k);

    try std.testing.expectEqualStrings("default.example.com", cfg.host);
    try std.testing.expectEqual(@as(u16, 443), cfg.port);
    try std.testing.expectEqualStrings("/stocks", cfg.path);
    try std.testing.expect(!cfg.insecure);
    try std.testing.expectEqualStrings("k", cfg.api_key.?);
}

test "mergeJsonInto trims whitespace around api_key and drops empty keys" {
    const alloc = std.testing.allocator;
    var cfg = testDefaults();

    // Leading/trailing whitespace stripped — covers pk pasted from a terminal
    // that picked up a trailing newline.
    mergeJsonInto(&cfg, alloc, "{\"api_key\":\"  pk_trimmed\\n\"}");
    try std.testing.expectEqualStrings("pk_trimmed", cfg.api_key.?);
    alloc.free(cfg.api_key.?);
    cfg.api_key = null;

    // Whitespace-only key is treated as absent, not as an empty string —
    // otherwise the env-var fallback after mergeJsonInto would be shadowed.
    mergeJsonInto(&cfg, alloc, "{\"api_key\":\"   \"}");
    try std.testing.expect(cfg.api_key == null);
}

test "mergeJsonInto swallows malformed JSON and leaves cfg untouched" {
    const alloc = std.testing.allocator;
    var cfg = testDefaults();

    // Deliberately broken — unterminated string.
    mergeJsonInto(&cfg, alloc, "{\"host\":\"oops");
    try std.testing.expectEqualStrings("default.example.com", cfg.host);
    try std.testing.expectEqual(@as(u16, 443), cfg.port);
    try std.testing.expect(cfg.api_key == null);
}

test "mergeJsonInto ignores unknown fields so config schema can evolve" {
    const alloc = std.testing.allocator;
    var cfg = testDefaults();
    defer if (cfg.api_key) |k| alloc.free(k);

    mergeJsonInto(&cfg, alloc,
        \\{"api_key":"k","future_field":"whatever","another":{"nested":true}}
    );
    try std.testing.expectEqualStrings("k", cfg.api_key.?);
    try std.testing.expectEqualStrings("default.example.com", cfg.host);
}

test "Config.defaultMarket strips the leading slash" {
    const c1: Config = .{ .host = "", .port = 0, .path = "/stocks", .insecure = false, .api_key = null };
    try std.testing.expectEqualStrings("stocks", c1.defaultMarket());

    // Defensive: if someone sets path without a slash we still get something
    // usable (the topic router compares against this string verbatim).
    const c2: Config = .{ .host = "", .port = 0, .path = "crypto", .insecure = false, .api_key = null };
    try std.testing.expectEqualStrings("crypto", c2.defaultMarket());

    const c3: Config = .{ .host = "", .port = 0, .path = "", .insecure = false, .api_key = null };
    try std.testing.expectEqualStrings("", c3.defaultMarket());
}
