// Massive WebSocket RTD server.
//
// Connects to wss://delayed.massive.com/stocks, authenticates with an API key
// embedded at build time, and streams JSON events into Excel cells.
//
// Topic format: "<ev>.<sym>[.<field>]"
//   T.AAPL.p      -> last trade price for AAPL
//   T.AAPL.s      -> last trade size
//   Q.MSFT.bp     -> bid price for MSFT (from quotes feed)
//   AM.TSLA.vw    -> VWAP from per-minute aggregate
//
// If the field is omitted, a sensible default per event type is returned
// (see defaultFieldFor).
//
// Usage in Excel:
//   =RTD("zigxll.connectors.massive", , "T.AAPL.p")

const std = @import("std");
const xll = @import("xll");
const rtd = xll.rtd;
const ws = @import("ws_client.zig");
const protocol = @import("massive_protocol.zig");
const opts = @import("massive_options");

const gpa = std.heap.c_allocator;

// ============================================================================
// Configuration (from build options — see build.zig)
// ============================================================================

const ws_host = opts.massive_host;
const ws_port: u16 = opts.massive_port;
const ws_path = opts.massive_path;
const insecure_tls = opts.massive_insecure;

/// CA trust bundle. Fetched once from https://curl.se/ca/cacert.pem and
/// checked into the repo for reproducible builds.
const ca_bundle_pem = @embedFile("ca_bundle.pem");

const config = @import("config.zig");

// ============================================================================
// Value state
// ============================================================================

/// Owned RTD value — when .string, the u16 slice is heap-allocated.
const OwnedValue = union(enum) {
    int: i32,
    double: f64,
    string: []u16,
    boolean: bool,
    err: i32,
    empty,

    fn deinit(self: OwnedValue, alloc: std.mem.Allocator) void {
        switch (self) {
            .string => |s| alloc.free(s),
            else => {},
        }
    }

    fn toRtdValue(self: OwnedValue) rtd.RtdValue {
        return switch (self) {
            .int => |v| .{ .int = v },
            .double => |v| .{ .double = v },
            .string => |v| .{ .string = v },
            .boolean => |v| .{ .boolean = v },
            .err => |v| .{ .err = v },
            .empty => .empty,
        };
    }
};

const TopicState = struct {
    /// Original topic string (e.g. "T.AAPL.p"), owned by this struct.
    topic: []const u8,
    /// Length of the "<ev>.<sym>" channel prefix within `topic`.
    /// The channel slice is `topic[0..channel_len]`.
    channel_len: usize,
    /// Event type string ("T", "Q", "AM", ...), borrowed from `topic`.
    ev: []const u8,
    /// Symbol ("AAPL"), borrowed from `topic`.
    sym: []const u8,
    /// Field name ("p"), borrowed from `topic` — empty if not specified.
    field: []const u8,
    /// Last known value for this cell.
    value: OwnedValue = .{ .err = @bitCast(@as(u32, 0x80020004)) }, // #N/A

    fn channel(self: *const TopicState) []const u8 {
        return self.topic[0..self.channel_len];
    }
};

// ============================================================================
// Handler
// ============================================================================

const Handler = struct {
    // --- Background thread state ---
    worker_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    authed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Socket handle shared with the worker so `onTerminate` can force-close
    /// the in-flight read. 0 = no active socket.
    active_sock: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // --- Protected by `mu` ---
    mu: std.Thread.Mutex = .{},
    topics: std.AutoHashMapUnmanaged(rtd.LONG, TopicState) = .empty,
    /// Channel → refcount. The key is owned by this map (independent alloc).
    channel_refs: std.StringHashMapUnmanaged(u32) = .empty,
    /// Queued subscribe/unsubscribe actions for the worker thread to flush.
    /// Strings in these lists are owned — the worker frees them after flushing.
    pending_sub: std.ArrayListUnmanaged([]u8) = .empty,
    pending_unsub: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn onStart(self: *Handler, ctx: *rtd.RtdContext) void {
        rtd.debugLog("massive_rtd: onStart", .{});
        self.running.store(true, .release);
        self.worker_thread = std.Thread.spawn(.{}, workerMain, .{ self, ctx }) catch |err| {
            rtd.debugLog("massive_rtd: failed to spawn worker: {s}", .{@errorName(err)});
            return;
        };
    }

    pub fn onConnect(self: *Handler, ctx: *rtd.RtdContext, topic_id: rtd.LONG, _: usize) void {
        // Register the topic immediately so that incoming WS messages arriving
        // before the next RefreshData tick will still update this cell.
        const entry = ctx.topics.get(topic_id) orelse return;
        if (entry.strings.len == 0) return;
        const topic_str = entry.strings[0];

        _ = protocol.parseTopic(topic_str) catch |err| {
            rtd.debugLog("massive_rtd: bad topic '{s}': {s}", .{ topic_str, @errorName(err) });
            return;
        };

        const owned_topic = gpa.dupe(u8, topic_str) catch return;
        // Re-parse against the owned copy so the borrowed slices are stable across
        // `topic_str`'s lifetime.
        const owned = protocol.parseTopic(owned_topic) catch unreachable;

        self.mu.lock();
        defer self.mu.unlock();

        self.topics.put(gpa, topic_id, .{
            .topic = owned_topic,
            .channel_len = owned.channel_len,
            .ev = owned.ev,
            .sym = owned.sym,
            .field = owned.field,
        }) catch {
            gpa.free(owned_topic);
            return;
        };

        // Bump channel refcount; queue a subscribe if first time for this channel.
        const channel = owned_topic[0..owned.channel_len];
        if (self.channel_refs.getEntry(channel)) |ref| {
            ref.value_ptr.* += 1;
        } else {
            const owned_channel = gpa.dupe(u8, channel) catch return;
            self.channel_refs.put(gpa, owned_channel, 1) catch {
                gpa.free(owned_channel);
                return;
            };
            // Queue subscribe — dupe so the pending queue owns the string independently.
            const queued = gpa.dupe(u8, channel) catch return;
            self.pending_sub.append(gpa, queued) catch gpa.free(queued);
        }
    }

    pub fn onConnectBatch(_: *Handler, _: *rtd.RtdContext, _: []const rtd.LONG) void {
        // No-op: registration already happened per-topic in onConnect. The
        // worker thread will notice queued subscribes in its next poll.
    }

    pub fn onDisconnect(self: *Handler, _: *rtd.RtdContext, topic_id: rtd.LONG, _: usize) void {
        self.mu.lock();
        defer self.mu.unlock();

        const removed = self.topics.fetchRemove(topic_id) orelse return;
        // Compute channel *before* we free `topic`.
        const channel = removed.value.topic[0..removed.value.channel_len];

        if (self.channel_refs.getEntry(channel)) |ref| {
            if (ref.value_ptr.* > 1) {
                ref.value_ptr.* -= 1;
            } else {
                // Reclaim the map's owned key for the pending-unsub queue.
                const owned_key = @constCast(ref.key_ptr.*);
                _ = self.channel_refs.remove(channel);
                self.pending_unsub.append(gpa, owned_key) catch gpa.free(owned_key);
            }
        }

        gpa.free(removed.value.topic);
        removed.value.value.deinit(gpa);
    }

    pub fn onRefreshValue(self: *Handler, _: *rtd.RtdContext, topic_id: rtd.LONG) rtd.RtdValue {
        self.mu.lock();
        defer self.mu.unlock();

        const state = self.topics.getPtr(topic_id) orelse return rtd.RtdValue.na;
        return state.value.toRtdValue();
    }

    pub fn onTerminate(self: *Handler, _: *rtd.RtdContext) void {
        rtd.debugLog("massive_rtd: onTerminate", .{});
        self.running.store(false, .release);

        // Unblock the worker thread's in-flight socket read by forcing the
        // socket closed. The worker is likely parked inside readMessage.
        const sock = self.active_sock.swap(0, .acq_rel);
        if (sock != 0) {
            const handle: std.net.Stream.Handle = @ptrFromInt(sock);
            _ = handle;
            // On posix, fd is an int. On Windows, SOCKET is a usize-like handle.
            // Either way, closesocket/close() will interrupt a blocking recv.
            closeSocket(sock);
        }

        if (self.worker_thread) |t| {
            t.join();
            self.worker_thread = null;
        }

        // Free owned state.
        self.mu.lock();
        defer self.mu.unlock();
        var it = self.topics.iterator();
        while (it.next()) |e| {
            gpa.free(e.value_ptr.topic);
            e.value_ptr.value.deinit(gpa);
        }
        self.topics.deinit(gpa);

        var cit = self.channel_refs.iterator();
        while (cit.next()) |e| gpa.free(e.key_ptr.*);
        self.channel_refs.deinit(gpa);

        for (self.pending_sub.items) |s| gpa.free(s);
        self.pending_sub.deinit(gpa);
        for (self.pending_unsub.items) |s| gpa.free(s);
        self.pending_unsub.deinit(gpa);
    }
};

fn closeSocket(raw: usize) void {
    // Cross-platform socket close. net.Stream.Handle is SOCKET on Windows
    // (which is a pointer-sized handle) and an int fd on posix.
    if (@import("builtin").os.tag == .windows) {
        const SOCKET = std.os.windows.ws2_32.SOCKET;
        const s: SOCKET = @ptrFromInt(raw);
        _ = std.os.windows.ws2_32.closesocket(s);
    } else {
        std.posix.close(@intCast(raw));
    }
}

fn sockToUsize(h: std.net.Stream.Handle) usize {
    return if (@import("builtin").os.tag == .windows) @intFromPtr(h) else @intCast(h);
}

// ============================================================================
// Worker thread
// ============================================================================

fn workerMain(self: *Handler, ctx: *rtd.RtdContext) void {
    rtd.debugLog("massive_rtd: worker starting", .{});

    while (self.running.load(.acquire)) {
        workerSession(self, ctx) catch |err| {
            rtd.debugLog("massive_rtd: session error: {s}", .{@errorName(err)});
        };
        self.authed.store(false, .release);

        // Backoff before reconnect.
        var slept_ms: u64 = 0;
        while (slept_ms < 2000 and self.running.load(.acquire)) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            slept_ms += 100;
        }
    }
    rtd.debugLog("massive_rtd: worker stopped", .{});
}

fn workerSession(self: *Handler, ctx: *rtd.RtdContext) !void {
    // Load CA bundle (once per session — cheap, PEM parse).
    var bundle = try ws.loadCaBundleFromPem(gpa, ca_bundle_pem);
    defer bundle.deinit(gpa);

    rtd.debugLog("massive_rtd: connecting to {s}:{d}{s} (insecure={})", .{ ws_host, ws_port, ws_path, insecure_tls });
    if (insecure_tls) rtd.debugLog("massive_rtd: WARNING — TLS verification disabled", .{});
    const client = try ws.Client.connect(gpa, ws_host, ws_port, ws_path, bundle, .{
        .insecure_skip_verify = insecure_tls,
    });
    defer client.deinit();

    // Publish the socket handle so onTerminate can interrupt the read.
    self.active_sock.store(sockToUsize(client.stream.handle), .release);
    defer self.active_sock.store(0, .release);

    // Greet / auth handshake. Key is loaded fresh each session so rotating it
    // on disk takes effect on the next reconnect — no XLL rebuild needed.
    const api_key = config.loadApiKey(gpa) catch |err| {
        rtd.debugLog("massive_rtd: could not load API key ({s}) — place massive_api_key.txt next to the XLL", .{@errorName(err)});
        return err;
    };
    defer gpa.free(api_key);
    try protocol.authenticate(client, gpa, api_key);
    rtd.debugLog("massive_rtd: authenticated", .{});
    self.authed.store(true, .release);

    // 4) Replay any channels we already have (after a reconnect).
    try flushInitialSubscribes(self, client);

    // 5) Read loop — poll for incoming messages AND flush pending sub/unsub.
    while (self.running.load(.acquire)) {
        // Flush sub/unsub queues.
        try flushPending(self, client);

        const msg = client.readMessage(gpa) catch |err| switch (err) {
            error.ConnectionClosed => return error.ConnectionClosed,
            else => return err,
        };
        defer gpa.free(msg.payload);

        handleDataMessage(self, ctx, msg.payload) catch |err| {
            rtd.debugLog("massive_rtd: handle error: {s}", .{@errorName(err)});
        };
    }
}

fn flushInitialSubscribes(self: *Handler, client: *ws.Client) !void {
    // After a reconnect, re-subscribe to every channel we still care about.
    // Drain any queued subscribes first (they're redundant with channel_refs),
    // but keep queued unsubscribes — they still need to be flushed next tick.
    self.mu.lock();
    var channels: std.ArrayListUnmanaged([]const u8) = .empty;
    defer channels.deinit(gpa);

    var it = self.channel_refs.iterator();
    while (it.next()) |e| channels.append(gpa, e.key_ptr.*) catch {};

    for (self.pending_sub.items) |s| gpa.free(s);
    self.pending_sub.clearRetainingCapacity();
    self.mu.unlock();

    if (channels.items.len == 0) return;
    rtd.debugLog("massive_rtd: re-subscribing {d} channels after reconnect", .{channels.items.len});
    try protocol.subscribe(client, gpa, channels.items);
}

fn flushPending(self: *Handler, client: *ws.Client) !void {
    // Snapshot queued sub/unsub lists under the lock, release, then send.
    // Owns the moved-out strings so we free after sending.
    self.mu.lock();
    var subs: std.ArrayListUnmanaged([]u8) = .empty;
    var unsubs: std.ArrayListUnmanaged([]u8) = .empty;
    defer subs.deinit(gpa);
    defer unsubs.deinit(gpa);

    for (self.pending_sub.items) |s| subs.append(gpa, s) catch gpa.free(s);
    self.pending_sub.clearRetainingCapacity();

    for (self.pending_unsub.items) |s| unsubs.append(gpa, s) catch gpa.free(s);
    self.pending_unsub.clearRetainingCapacity();
    self.mu.unlock();

    defer for (subs.items) |s| gpa.free(s);
    defer for (unsubs.items) |s| gpa.free(s);

    if (subs.items.len > 0) try protocol.subscribe(client, gpa, @ptrCast(subs.items));
    if (unsubs.items.len > 0) try protocol.unsubscribe(client, gpa, @ptrCast(unsubs.items));
}

// ============================================================================
// Incoming message dispatch
// ============================================================================

fn handleDataMessage(self: *Handler, ctx: *rtd.RtdContext, payload: []const u8) !void {
    // Every data message is a JSON array of event objects.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, payload, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array) return error.NotAnArray;

    var any_dirty = false;
    self.mu.lock();
    defer self.mu.unlock();

    for (root.array.items) |evt| {
        if (evt != .object) continue;
        const obj = evt.object;

        const ev_val = obj.get("ev") orelse continue;
        if (ev_val != .string) continue;
        const ev = ev_val.string;

        // Status messages ("ev":"status") aren't cell data — log and skip.
        if (std.mem.eql(u8, ev, "status")) {
            if (obj.get("message")) |m| {
                if (m == .string) rtd.debugLog("massive_rtd: status: {s}", .{m.string});
            }
            continue;
        }

        // All data events carry a sym field.
        const sym_val = obj.get("sym") orelse obj.get("pair") orelse continue;
        if (sym_val != .string) continue;
        const sym = sym_val.string;

        // Scan all subscribed topics for ev+sym matches and update.
        var it = self.topics.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr;
            if (!std.mem.eql(u8, state.ev, ev)) continue;
            if (!std.mem.eql(u8, state.sym, sym)) continue;

            const field_name = if (state.field.len > 0) state.field else protocol.defaultFieldFor(ev);
            if (field_name.len == 0) {
                // Serialize the whole object as a string.
                const s = try std.json.Stringify.valueAlloc(gpa, evt, .{});
                defer gpa.free(s);
                state.value.deinit(gpa);
                state.value = try makeStringValue(s);
            } else if (obj.get(field_name)) |fv| {
                state.value.deinit(gpa);
                state.value = try valueFromJson(fv);
            } else {
                state.value.deinit(gpa);
                state.value = .{ .err = @bitCast(@as(u32, 0x80020004)) }; // #N/A
            }

            // Mark dirty in the framework's topic map.
            if (ctx.topics.getPtr(entry.key_ptr.*)) |tentry| {
                tentry.dirty = true;
                any_dirty = true;
            }
        }
    }

    if (any_dirty) ctx.notifyExcel();
}

fn valueFromJson(v: std.json.Value) !OwnedValue {
    return switch (v) {
        .integer => |i| if (i >= std.math.minInt(i32) and i <= std.math.maxInt(i32))
            OwnedValue{ .int = @intCast(i) }
        else
            OwnedValue{ .double = @floatFromInt(i) },
        .float => |f| .{ .double = f },
        .number_string => |s| .{ .double = std.fmt.parseFloat(f64, s) catch 0.0 },
        .bool => |b| .{ .boolean = b },
        .string => |s| try makeStringValue(s),
        .null => .{ .err = @bitCast(@as(u32, 0x80020004)) },
        .array, .object => blk: {
            const s = try std.json.Stringify.valueAlloc(gpa, v, .{});
            defer gpa.free(s);
            break :blk try makeStringValue(s);
        },
    };
}

fn makeStringValue(utf8: []const u8) !OwnedValue {
    // Convert UTF-8 to UTF-16 for the RTD layer.
    const u16_buf = try gpa.alloc(u16, utf8.len);
    errdefer gpa.free(u16_buf);
    const written = try std.unicode.utf8ToUtf16Le(u16_buf, utf8);
    return .{ .string = try gpa.realloc(u16_buf, written) };
}

// ============================================================================
// Framework plumbing
// ============================================================================

pub const rtd_config: rtd.RtdConfig = .{
    .clsid = rtd.guid("D146815B-1D01-4D0D-904C-292533090438"),
    .prog_id = "zigxll.connectors.massive",
};

pub const RtdServerType = rtd.RtdServer(Handler, rtd_config);
