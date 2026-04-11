// Massive WebSocket protocol helpers - pure-Zig, no Excel/RTD dependency.
// Shared between the RTD handler (Windows XLL) and the native CLI smoke-tester.

const std = @import("std");
const ws = @import("ws_client.zig");

/// Send auth, wait for auth_success. Returns error.AuthFailed on any other response.
pub fn authenticate(client: *ws.Client, alloc: std.mem.Allocator, api_key: []const u8) !void {
    // 1) Server greets with [{"ev":"status","status":"connected",...}] - discard.
    {
        const msg = try client.readMessage(alloc);
        defer alloc.free(msg.payload);
        if (std.mem.indexOf(u8, msg.payload, "\"connected\"") == null) {
            return error.UnexpectedGreeting;
        }
    }

    // 2) Send auth frame.
    {
        var buf: [512]u8 = undefined;
        const auth = try std.fmt.bufPrint(&buf, "{{\"action\":\"auth\",\"params\":\"{s}\"}}", .{api_key});
        try client.sendText(auth);
    }

    // 3) Expect auth_success.
    const msg = try client.readMessage(alloc);
    defer alloc.free(msg.payload);
    if (std.mem.indexOf(u8, msg.payload, "\"auth_success\"") == null) {
        return error.AuthFailed;
    }
}

/// Send `{"action":"subscribe","params":"<comma-joined channels>"}`.
pub fn subscribe(
    client: *ws.Client,
    alloc: std.mem.Allocator,
    channels: []const []const u8,
) !void {
    try sendChannelAction(client, alloc, "subscribe", channels);
}

/// Send `{"action":"unsubscribe","params":"..."}`.
pub fn unsubscribe(
    client: *ws.Client,
    alloc: std.mem.Allocator,
    channels: []const []const u8,
) !void {
    try sendChannelAction(client, alloc, "unsubscribe", channels);
}

fn sendChannelAction(
    client: *ws.Client,
    alloc: std.mem.Allocator,
    action: []const u8,
    channels: []const []const u8,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"action\":\"");
    try buf.appendSlice(alloc, action);
    try buf.appendSlice(alloc, "\",\"params\":\"");
    for (channels, 0..) |ch, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.appendSlice(alloc, ch);
    }
    try buf.appendSlice(alloc, "\"}");
    try client.sendText(buf.items);
}

/// Split a topic string "T.AAPL.p" into (ev="T", sym="AAPL", field="p").
/// Field is empty if the topic has only two segments.
/// Returned slices borrow from `topic`.
pub const ParsedTopic = struct {
    ev: []const u8,
    sym: []const u8,
    field: []const u8,
    /// Length of the "<ev>.<sym>" prefix - use `topic[0..channel_len]` to get
    /// the channel name that Massive expects on the wire.
    channel_len: usize,
};

pub fn parseTopic(topic: []const u8) !ParsedTopic {
    const first_dot = std.mem.indexOfScalar(u8, topic, '.') orelse return error.InvalidTopic;
    const rest = topic[first_dot + 1 ..];
    const second_dot_rel = std.mem.indexOfScalar(u8, rest, '.');

    const sym_end = if (second_dot_rel) |d| first_dot + 1 + d else topic.len;
    const field_start = if (second_dot_rel) |d| first_dot + 1 + d + 1 else topic.len;

    if (first_dot == 0 or first_dot + 1 >= sym_end) return error.InvalidTopic;

    return .{
        .ev = topic[0..first_dot],
        .sym = topic[first_dot + 1 .. sym_end],
        .field = if (field_start < topic.len) topic[field_start..] else topic[0..0],
        .channel_len = sym_end,
    };
}

/// Default field to surface when the topic omits one. Covers every event
/// prefix the per-market wrappers in functions.zig can produce.
pub fn defaultFieldFor(ev: []const u8) []const u8 {
    // Trades (stocks/options/futures) & crypto trades.
    if (std.mem.eql(u8, ev, "T") or std.mem.eql(u8, ev, "XT")) return "p";
    // Quotes. Stocks/options/futures use "ap"; crypto quotes also use "ap";
    // forex quotes use "a" (single-letter ask) per the /forex/C docs.
    if (std.mem.eql(u8, ev, "Q") or std.mem.eql(u8, ev, "XQ")) return "ap";
    if (std.mem.eql(u8, ev, "C")) return "a";
    // Aggregates - all variants close on "c".
    if (std.mem.eql(u8, ev, "AM") or std.mem.eql(u8, ev, "A")) return "c";
    if (std.mem.eql(u8, ev, "XA") or std.mem.eql(u8, ev, "XAS")) return "c";
    if (std.mem.eql(u8, ev, "CA") or std.mem.eql(u8, ev, "CAS")) return "c";
    // FMV (stocks/options/forex/crypto, Business plans only).
    if (std.mem.eql(u8, ev, "FMV")) return "fmv";
    // Indices value tick.
    if (std.mem.eql(u8, ev, "V")) return "val";
    // LULD bands have no single obvious default - return upper band.
    if (std.mem.eql(u8, ev, "LULD")) return "h";
    return "";
}

test "parseTopic splits correctly" {
    const t1 = try parseTopic("T.AAPL.p");
    try std.testing.expectEqualStrings("T", t1.ev);
    try std.testing.expectEqualStrings("AAPL", t1.sym);
    try std.testing.expectEqualStrings("p", t1.field);
    try std.testing.expectEqual(@as(usize, 6), t1.channel_len);

    const t2 = try parseTopic("AM.MSFT");
    try std.testing.expectEqualStrings("AM", t2.ev);
    try std.testing.expectEqualStrings("MSFT", t2.sym);
    try std.testing.expectEqualStrings("", t2.field);
    try std.testing.expectEqual(@as(usize, 7), t2.channel_len);
}
