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

    // 2) Send auth frame. We hand-build the envelope (fixed shape, trivially
    //    readable on the wire) but escape the API key so a stray " or \ in
    //    the user's key produces a valid-but-rejected frame rather than
    //    corrupt JSON the server can't parse.
    {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(alloc);
        try list.appendSlice(alloc, "{\"action\":\"auth\",\"params\":");
        try appendJsonString(&list, alloc, api_key);
        try list.append(alloc, '}');
        try client.sendText(list.items);
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
    // Build the comma-joined params value first, then emit it as a single
    // properly-escaped JSON string. A symbol containing " or \ would
    // otherwise corrupt the envelope.
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(alloc);
    for (channels, 0..) |ch, i| {
        if (i > 0) try joined.append(alloc, ',');
        try joined.appendSlice(alloc, ch);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "{\"action\":\"");
    try buf.appendSlice(alloc, action); // action is a string literal — never user input.
    try buf.appendSlice(alloc, "\",\"params\":");
    try appendJsonString(&buf, alloc, joined.items);
    try buf.append(alloc, '}');
    try client.sendText(buf.items);
}

/// Append `s` as a JSON string literal (surrounding quotes included) to
/// `list`. Escapes the RFC 8259 mandatory set (`"`, `\`, control chars) —
/// enough for the outbound auth/subscribe frames, which never need to
/// carry non-ASCII. Uses `\uXXXX` for control chars so the output is
/// ASCII-safe regardless of how the WS layer treats the buffer.
fn appendJsonString(
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    s: []const u8,
) !void {
    try list.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            0x08 => try list.appendSlice(alloc, "\\b"),
            0x0C => try list.appendSlice(alloc, "\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                var buf: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try list.appendSlice(alloc, &buf);
            },
            else => try list.append(alloc, c),
        }
    }
    try list.append(alloc, '"');
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

test "parseTopic handles symbols containing a dash" {
    // Crypto/forex pairs like BTC-USD, EUR-USD. Dash isn't a separator.
    const t = try parseTopic("XT.BTC-USD.p");
    try std.testing.expectEqualStrings("XT", t.ev);
    try std.testing.expectEqualStrings("BTC-USD", t.sym);
    try std.testing.expectEqualStrings("p", t.field);
    try std.testing.expectEqualStrings("XT.BTC-USD", "XT.BTC-USD.p"[0..t.channel_len]);
}

test "parseTopic treats only the first two dots as separators" {
    // Options symbols contain colons (O:SPY...), no dots - but if a field
    // ever contained a dot it would belong to the field, not the symbol.
    const t = try parseTopic("Q.O:SPY251219C00600000.ap");
    try std.testing.expectEqualStrings("Q", t.ev);
    try std.testing.expectEqualStrings("O:SPY251219C00600000", t.sym);
    try std.testing.expectEqualStrings("ap", t.field);
}

test "parseTopic rejects malformed inputs" {
    try std.testing.expectError(error.InvalidTopic, parseTopic("noseparator"));
    try std.testing.expectError(error.InvalidTopic, parseTopic(".AAPL"));      // empty ev
    try std.testing.expectError(error.InvalidTopic, parseTopic("T."));         // empty sym
    try std.testing.expectError(error.InvalidTopic, parseTopic(""));
}

test "defaultFieldFor covers every wired event prefix" {
    // Trade events -> price.
    try std.testing.expectEqualStrings("p", defaultFieldFor("T"));
    try std.testing.expectEqualStrings("p", defaultFieldFor("XT"));
    // Quote events -> ask price (single-letter 'a' on forex C, 'ap' elsewhere).
    try std.testing.expectEqualStrings("ap", defaultFieldFor("Q"));
    try std.testing.expectEqualStrings("ap", defaultFieldFor("XQ"));
    try std.testing.expectEqualStrings("a", defaultFieldFor("C"));
    // Aggregate events -> close of the window.
    try std.testing.expectEqualStrings("c", defaultFieldFor("AM"));
    try std.testing.expectEqualStrings("c", defaultFieldFor("A"));
    try std.testing.expectEqualStrings("c", defaultFieldFor("XA"));
    try std.testing.expectEqualStrings("c", defaultFieldFor("XAS"));
    try std.testing.expectEqualStrings("c", defaultFieldFor("CA"));
    try std.testing.expectEqualStrings("c", defaultFieldFor("CAS"));
    // FMV, indices value, LULD band.
    try std.testing.expectEqualStrings("fmv", defaultFieldFor("FMV"));
    try std.testing.expectEqualStrings("val", defaultFieldFor("V"));
    try std.testing.expectEqualStrings("h", defaultFieldFor("LULD"));
    // Unknown prefixes fall through to empty - the handler treats that as
    // "serialize the whole event as a string".
    try std.testing.expectEqualStrings("", defaultFieldFor("ZZZ"));
    try std.testing.expectEqualStrings("", defaultFieldFor(""));
}

test "appendJsonString escapes the RFC 8259 mandatory set" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    // Plain ASCII passes through unchanged, wrapped in quotes.
    try appendJsonString(&buf, alloc, "T.AAPL");
    try std.testing.expectEqualStrings("\"T.AAPL\"", buf.items);
    buf.clearRetainingCapacity();

    // Quote and backslash get escaped — the case the hand-built frame used
    // to corrupt.
    try appendJsonString(&buf, alloc, "a\"b\\c");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\"", buf.items);
    buf.clearRetainingCapacity();

    // Named short-form escapes for common control chars.
    try appendJsonString(&buf, alloc, "line1\nline2\tend");
    try std.testing.expectEqualStrings("\"line1\\nline2\\tend\"", buf.items);
    buf.clearRetainingCapacity();

    // Other control chars go through \u escaping.
    try appendJsonString(&buf, alloc, "\x01\x1f");
    try std.testing.expectEqualStrings("\"\\u0001\\u001f\"", buf.items);
    buf.clearRetainingCapacity();

    // Empty string is still a valid JSON string literal.
    try appendJsonString(&buf, alloc, "");
    try std.testing.expectEqualStrings("\"\"", buf.items);
}

test "appendJsonString output round-trips through std.json parser" {
    // Sanity check: anything we emit must parse as the same input string.
    const alloc = std.testing.allocator;
    const cases: []const []const u8 = &.{
        "T.AAPL",
        "pk_live_abc123",
        "with \"quote\" and \\ backslash",
        "tab\there\nnewline",
        "\x00\x01\x7f",
    };
    for (cases) |input| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        try appendJsonString(&buf, alloc, input);

        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, buf.items, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .string);
        try std.testing.expectEqualStrings(input, parsed.value.string);
    }
}
