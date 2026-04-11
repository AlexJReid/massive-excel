// API key loader. The key lives in the `MASSIVE_API_KEY` env var OR in
// `massive_api_key.txt` on disk at runtime - no longer `@embedFile`'d.
// This lets a single XLL binary be shipped and users drop their key file
// next to it (or set the env var, handy for CI / ephemeral shells).
//
// Search order:
//   1. $MASSIVE_API_KEY environment variable
//   2. Windows XLL: <dir containing the XLL>\massive_api_key.txt
//      Native CLI:  ./massive_api_key.txt, then ./src/massive_api_key.txt
//
// The CLI's second path is for dev convenience - lets `zig build run-cli` work
// from the repo root with the existing gitignored file under src/.

const std = @import("std");
const builtin = @import("builtin");

const FILENAME = "massive_api_key.txt";
const ENV_VAR = "MASSIVE_API_KEY";
const MAX_SIZE = 4 * 1024;

/// Returned slice is owned by the caller.
pub fn loadApiKey(alloc: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(alloc, ENV_VAR)) |env_val| {
        defer alloc.free(env_val);
        const trimmed = std.mem.trim(u8, env_val, " \t\r\n");
        if (trimmed.len > 0) return try alloc.dupe(u8, trimmed);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const raw = try loadRaw(alloc);
    defer alloc.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyApiKey;
    return try alloc.dupe(u8, trimmed);
}

fn loadRaw(alloc: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        return loadFromXllDir(alloc);
    }
    // Native CLI: cwd, then src/.
    if (std.fs.cwd().readFileAlloc(alloc, FILENAME, MAX_SIZE)) |data| {
        return data;
    } else |_| {}
    if (std.fs.cwd().readFileAlloc(alloc, "src/" ++ FILENAME, MAX_SIZE)) |data| {
        return data;
    } else |err| {
        return err;
    }
}

fn loadFromXllDir(alloc: std.mem.Allocator) ![]u8 {
    const win = struct {
        const HMODULE = ?*anyopaque;
        const DWORD = u32;
        const BOOL = i32;
        const MAX_PATH = 260;
        const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 0x04;
        const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = 0x02;

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
    };

    var hmod: win.HMODULE = null;
    const ok = win.GetModuleHandleExA(
        win.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | win.GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        @ptrCast(&loadFromXllDir),
        &hmod,
    );
    if (ok == 0) return error.CouldNotFindXllDir;

    var buf: [win.MAX_PATH]u8 = undefined;
    const len = win.GetModuleFileNameA(hmod, &buf, win.MAX_PATH);
    if (len == 0) return error.CouldNotFindXllDir;

    const full = buf[0..len];
    const idx = std.mem.lastIndexOfScalar(u8, full, '\\') orelse return error.CouldNotFindXllDir;
    const dir = full[0..idx];

    const path = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ dir, FILENAME });
    defer alloc.free(path);

    return try std.fs.cwd().readFileAlloc(alloc, path, MAX_SIZE);
}
