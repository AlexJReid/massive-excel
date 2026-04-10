// Native CLI smoke-tester for the Massive WebSocket client.
//
// Builds on mac/linux/windows as a plain executable — no Excel, no COM, no XLL.
// Connects to the configured Massive endpoint (or a local mock via build options),
// authenticates, subscribes to the channels given on the command line, and prints
// every event it receives.
//
// Usage:
//   zig build run-cli -- T.AAPL T.MSFT
//   zig build run-cli -Dmassive_host=localhost -Dmassive_port=8443 -Dmassive_insecure=true -- T.AAPL
//
// The API key is read from src/massive_api_key.txt (same file the XLL embeds).

const std = @import("std");
const ws = @import("ws_client.zig");
const protocol = @import("massive_protocol.zig");
const opts = @import("massive_options");

const api_key_raw = @embedFile("massive_api_key.txt");
const ca_bundle_pem = @embedFile("ca_bundle.pem");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        const stderr = std.debug.lockStderrWriter(&.{});
        defer std.debug.unlockStderrWriter();
        stderr.writeAll("usage: massive-cli <channel1> [channel2] ...\n") catch {};
        stderr.writeAll("example: massive-cli T.AAPL T.MSFT AM.TSLA\n") catch {};
        std.process.exit(2);
    }

    const channels = args[1..];

    const log = std.log.scoped(.massive_cli);
    log.info("host={s} port={d} path={s} insecure={}", .{
        opts.massive_host,
        opts.massive_port,
        opts.massive_path,
        opts.massive_insecure,
    });
    if (opts.massive_insecure) log.warn("TLS verification disabled", .{});

    var bundle = try ws.loadCaBundleFromPem(alloc, ca_bundle_pem);
    defer bundle.deinit(alloc);

    log.info("connecting...", .{});
    const client = try ws.Client.connect(
        alloc,
        opts.massive_host,
        opts.massive_port,
        opts.massive_path,
        bundle,
        .{ .insecure_skip_verify = opts.massive_insecure },
    );
    defer client.deinit();
    log.info("connected", .{});

    const api_key = std.mem.trim(u8, api_key_raw, " \t\r\n");
    try protocol.authenticate(client, alloc, api_key);
    log.info("authenticated", .{});

    try protocol.subscribe(client, alloc, channels);
    log.info("subscribed to {d} channel(s)", .{channels.len});

    // Read loop — print every event forever.
    while (true) {
        const msg = client.readMessage(alloc) catch |err| {
            log.err("read failed: {s}", .{@errorName(err)});
            return err;
        };
        defer alloc.free(msg.payload);

        // Try to pretty-print as JSON array; fall back to raw.
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, msg.payload, .{}) catch {
            std.debug.print("< {s}\n", .{msg.payload});
            continue;
        };
        defer parsed.deinit();

        if (parsed.value == .array) {
            for (parsed.value.array.items) |evt| {
                const summary = summarize(alloc, evt) catch {
                    std.debug.print("< <event>\n", .{});
                    continue;
                };
                defer alloc.free(summary);
                std.debug.print("< {s}\n", .{summary});
            }
        } else {
            std.debug.print("< {s}\n", .{msg.payload});
        }
    }
}

fn summarize(alloc: std.mem.Allocator, evt: std.json.Value) ![]u8 {
    if (evt != .object) return try alloc.dupe(u8, "<non-object>");
    const obj = evt.object;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    var w = std.Io.Writer.Allocating.init(alloc);
    defer w.deinit();

    // Print ev, sym (or status/message), and all scalar fields.
    if (obj.get("ev")) |ev| if (ev == .string) try w.writer.print("ev={s}", .{ev.string});
    if (obj.get("sym")) |sym| if (sym == .string) try w.writer.print(" sym={s}", .{sym.string});
    if (obj.get("status")) |st| if (st == .string) try w.writer.print(" status={s}", .{st.string});
    if (obj.get("message")) |m| if (m == .string) try w.writer.print(" message={s}", .{m.string});

    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "ev") or std.mem.eql(u8, key, "sym") or
            std.mem.eql(u8, key, "status") or std.mem.eql(u8, key, "message")) continue;
        try w.writer.writeByte(' ');
        try w.writer.writeAll(key);
        try w.writer.writeByte('=');
        switch (entry.value_ptr.*) {
            .integer => |i| try w.writer.print("{d}", .{i}),
            .float => |f| try w.writer.print("{d}", .{f}),
            .number_string => |s| try w.writer.writeAll(s),
            .bool => |b| try w.writer.writeAll(if (b) "true" else "false"),
            .string => |s| try w.writer.print("\"{s}\"", .{s}),
            .null => try w.writer.writeAll("null"),
            .array, .object => try w.writer.writeAll("<...>"),
        }
    }

    return try w.toOwnedSlice();
}
