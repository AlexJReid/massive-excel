// Massive WebSocket RTD server.
//
// Connects to one or more Massive WebSocket endpoints (one per asset-class
// market), authenticates with an API key loaded at runtime, and streams JSON
// events into Excel cells.
//
// Massive exposes a separate WebSocket for each market:
//
//   wss://<host>/stocks     wss://<host>/crypto     wss://<host>/forex
//   wss://<host>/options    wss://<host>/indices    wss://<host>/futures
//
// A single WebSocket connection can only talk to one market. If a user
// subscribes to both stocks and crypto channels, we open two connections.
// Each connection is owned by its own worker thread and can only carry
// channels for that market. Connections are created lazily when the first
// cell for a market appears, and kept alive (idle) for the remainder of the
// Excel session.
//
// Your access to any given market depends on the plan attached to the API
// key; unauthorized markets will fail auth (reported via status messages).
//
// Topic format: "<ev>.<sym>[.<field>]"
//   T.AAPL.p      -> last trade price for AAPL
//   T.AAPL.s      -> last trade size
//   Q.MSFT.bp     -> bid price for MSFT (from quotes feed)
//   AM.TSLA.vw    -> VWAP from per-minute aggregate
//
// Market selection: an optional second RTD string picks the market. When
// omitted we use the default market from the build option.
//
//   =RTD("zigxll.connectors.massive", , "T.AAPL.p")            -> stocks
//   =RTD("zigxll.connectors.massive", , "XT.BTC-USD.p", "crypto")
//   =RTD("zigxll.connectors.massive", , "C.EUR/USD.p", "forex")
//
// If the field is omitted, a sensible default per event type is returned
// (see defaultFieldFor).

const std = @import("std");
const xll = @import("xll");
const rtd = xll.rtd;
const ws = @import("ws_client.zig");
const protocol = @import("massive_protocol.zig");
const config = @import("config.zig");

const gpa = std.heap.c_allocator;

/// CA trust bundle. Fetched once from https://curl.se/ca/cacert.pem and
/// checked into the repo for reproducible builds.
const ca_bundle_pem = @embedFile("ca_bundle.pem");

// ============================================================================
// Value state
// ============================================================================

/// Owned RTD value - when .string, the u16 slice is heap-allocated.
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
    /// Field name ("p"), borrowed from `topic` - empty if not specified.
    field: []const u8,
    /// Which MarketConn this topic belongs to. Borrowed from the market's
    /// owned name string in `Handler.markets`.
    market: []const u8,
    /// Last known value for this cell.
    value: OwnedValue = .{ .err = @bitCast(@as(u32, 0x80020004)) }, // #N/A
};

// ============================================================================
// Per-market connection
// ============================================================================

/// One WebSocket connection, one worker thread, one market. Multiple
/// MarketConns live under a single Handler when the workbook subscribes to
/// topics from different markets.
const MarketConn = struct {
    /// Owned market name ("stocks", "crypto", ...). Keys the Handler.markets
    /// map AND is borrowed by every TopicState pointing at this connection.
    name: []const u8,
    /// Backpointer so the worker thread can reach the shared Handler for
    /// dispatch into the topics map and Excel notification.
    handler: *Handler,

    // --- workerMain-only state ---
    worker_thread: ?std.Thread = null,
    /// Did the most recent session reach the read loop? Checked at the top of
    /// the worker loop to decide whether to reset `reconnect_attempts`.
    session_was_authed: bool = false,
    /// Consecutive failed sessions since the last successful auth. Feeds the
    /// reconnect backoff.
    reconnect_attempts: u32 = 0,
    /// PRNG for jittering the reconnect delay. Seeded once in workerMain.
    jitter_rng: std.Random.DefaultPrng = undefined,
    /// Exponentially-weighted moving average of per-frame dispatch time (ms).
    /// Updated inside handleDataMessage on the reader thread.
    dispatch_ewma_ms: u64 = 0,
    /// Unix-ms timestamp of the last "dispatch lagging" warning. Rate-limits
    /// the warning to once per 10s per market.
    last_lag_warn_ms: i64 = 0,
    /// Raw socket handle for the session's TLS connection, or -1.
    /// Published atomically by the reader thread after connect, cleared
    /// before close. onTerminate calls shutdown(SHUT_RDWR) on it to unblock
    /// any in-flight recv so join() returns promptly.
    live_socket: std.atomic.Value(i64) = std.atomic.Value(i64).init(-1),

    // --- Shared between reader and writer threads ---
    /// Serialises all writes to ws.Client (sendText, sendPing, sendClose,
    /// sendPong). The reader thread takes this when it needs to reply to a
    /// server ping; the writer thread takes it for everything else.
    write_mu: std.Thread.Mutex = .{},
    /// Writer thread handle, valid only during an active session.
    writer_thread: ?std.Thread = null,

    // --- Protected by `mu` ---
    mu: std.Thread.Mutex = .{},
    /// Signalled by onConnect/onDisconnect after appending to pending_sub or
    /// pending_unsub, so the writer thread wakes immediately instead of
    /// waiting for its 1s timedWait to expire.
    work_cond: std.Thread.Condition = .{},
    /// Channel -> list of topic_ids subscribed to that channel. The list is
    /// both the dispatch index (read on each frame to route an incoming
    /// "<ev>.<sym>" to the cells that care) and the refcount (number of live
    /// subscriptions for the channel *is* `list.items.len`). When the list
    /// empties we remove the entry and queue an unsubscribe. Keys are owned
    /// by this map.
    channels: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(rtd.LONG)) = .empty,
    /// Queued subscribe/unsubscribe actions for the writer thread to flush.
    /// Strings in these lists are owned - the writer frees them after flushing.
    pending_sub: std.ArrayListUnmanaged([]u8) = .empty,
    pending_unsub: std.ArrayListUnmanaged([]u8) = .empty,

    /// Scratch arena reset once per incoming WS frame - owns the JSON parse
    /// tree and any transient stringification buffers for that frame.
    /// Only touched from the reader thread inside handleDataMessage.
    frame_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.c_allocator),

    fn deinit(self: *MarketConn) void {
        var ch_it = self.channels.iterator();
        while (ch_it.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        self.channels.deinit(gpa);

        for (self.pending_sub.items) |s| gpa.free(s);
        self.pending_sub.deinit(gpa);
        for (self.pending_unsub.items) |s| gpa.free(s);
        self.pending_unsub.deinit(gpa);

        self.frame_arena.deinit();

        gpa.free(self.name);
    }
};

// ============================================================================
// Handler
// ============================================================================

const Handler = struct {
    ctx: ?*rtd.RtdContext = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set by onTerminate BEFORE running=false. Workers re-check this after
    /// acquiring handler.mu and before touching handler.topics or calling
    /// ctx.notifyExcel, so a dispatch in flight when teardown starts can't
    /// race the main thread freeing state from under it.
    terminating: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Protects `topics`, `markets`, and `last_notify_ms`. Per-market state
    /// has its own mutex inside MarketConn.
    mu: std.Thread.Mutex = .{},
    topics: std.AutoHashMapUnmanaged(rtd.LONG, TopicState) = .empty,
    /// Unix-ms timestamp of the last `notifyExcel()` call. Used to throttle
    /// COM notifications so we don't overwhelm Excel's STA message pump
    /// under high-speed replay or firehose conditions. Protected by `mu`.
    last_notify_ms: i64 = 0,
    /// Active connections keyed by market name. Values are heap-allocated and
    /// owned by this map.
    markets: std.StringHashMapUnmanaged(*MarketConn) = .empty,
    /// Scratch buffer for the most recent string returned by onRefreshValue.
    /// The framework calls SysAllocStringLen on the returned pointer AFTER
    /// we release self.mu, so a bare borrow into TopicState.value would race
    /// the worker thread freeing and replacing that buffer. This scratch
    /// copy is safe because onRefreshValue is only called from the main
    /// Excel thread (inside RefreshData) and is never re-entered.
    refresh_str_scratch: [4096]u16 = undefined,

    pub fn onStart(self: *Handler, ctx: *rtd.RtdContext) void {
        const cfg = config.load();
        rtd.debugLog("massive_rtd: onStart host={s} port={d} insecure={} default_market={s}", .{
            cfg.host, cfg.port, cfg.insecure, cfg.defaultMarket(),
        });
        if (cfg.insecure) rtd.debugLog("massive_rtd: WARNING - TLS verification disabled for ALL connections", .{});
        self.ctx = ctx;
        self.running.store(true, .release);
        // Workers are spawned lazily when the first topic for a given market
        // arrives (see onConnect -> getOrCreateMarket).
    }

    pub fn onConnect(self: *Handler, ctx: *rtd.RtdContext, topic_id: rtd.LONG, _: usize) void {
        // Register the topic immediately so that incoming WS messages arriving
        // before the next RefreshData tick will still update this cell.
        const entry = ctx.topics.get(topic_id) orelse return;
        if (entry.strings.len == 0) return;
        const topic_str = entry.strings[0];
        const market_str = if (entry.strings.len >= 2 and entry.strings[1].len > 0)
            entry.strings[1]
        else
            config.load().defaultMarket();

        _ = protocol.parseTopic(topic_str) catch |err| {
            rtd.debugLog("massive_rtd: bad topic '{s}': {s}", .{ topic_str, @errorName(err) });
            return;
        };
        if (!isKnownMarket(market_str)) {
            rtd.debugLog("massive_rtd: unknown market '{s}' for topic '{s}'", .{ market_str, topic_str });
            return;
        }

        const owned_topic = gpa.dupe(u8, topic_str) catch return;
        errdefer gpa.free(owned_topic);
        // Re-parse against the owned copy so the borrowed slices are stable.
        const owned = protocol.parseTopic(owned_topic) catch unreachable;

        self.mu.lock();
        defer self.mu.unlock();

        const mc = self.getOrCreateMarketLocked(market_str) orelse {
            gpa.free(owned_topic);
            return;
        };

        self.topics.put(gpa, topic_id, .{
            .topic = owned_topic,
            .channel_len = owned.channel_len,
            .ev = owned.ev,
            .sym = owned.sym,
            .field = owned.field,
            .market = mc.name,
        }) catch {
            gpa.free(owned_topic);
            return;
        };

        // Append this topic_id to the channel's subscriber list. The list
        // doubles as the refcount (len == refcount) and as the dispatch index.
        // When a channel appears for the first time we also queue a subscribe.
        const channel = owned_topic[0..owned.channel_len];
        mc.mu.lock();
        defer mc.mu.unlock();

        if (mc.channels.getEntry(channel)) |existing| {
            existing.value_ptr.append(gpa, topic_id) catch {};
            return;
        }

        const owned_channel = gpa.dupe(u8, channel) catch return;
        var list: std.ArrayListUnmanaged(rtd.LONG) = .empty;
        list.append(gpa, topic_id) catch {
            gpa.free(owned_channel);
            return;
        };
        mc.channels.put(gpa, owned_channel, list) catch {
            list.deinit(gpa);
            gpa.free(owned_channel);
            return;
        };
        const queued = gpa.dupe(u8, channel) catch return;
        mc.pending_sub.append(gpa, queued) catch gpa.free(queued);
        mc.work_cond.signal();
    }

    pub fn onConnectBatch(_: *Handler, _: *rtd.RtdContext, _: []const rtd.LONG) void {
        // No-op: registration already happened per-topic in onConnect.
    }

    pub fn onDisconnect(self: *Handler, _: *rtd.RtdContext, topic_id: rtd.LONG, _: usize) void {
        self.mu.lock();
        defer self.mu.unlock();

        const removed = self.topics.fetchRemove(topic_id) orelse return;
        const market = removed.value.market;
        const channel = removed.value.topic[0..removed.value.channel_len];

        if (self.markets.get(market)) |mc| {
            mc.mu.lock();
            defer mc.mu.unlock();

            // Remove this topic_id from the channel's subscriber list. Linear
            // scan is fine: a single channel rarely has more than a handful of
            // cells pointing at it (typically one per field suffix: .p, .s).
            // When the list empties, the channel has no live subscriptions -
            // drop it and queue an unsubscribe. The owned key is handed off
            // to pending_unsub so we don't double-free.
            if (mc.channels.getEntry(channel)) |entry| {
                const list = entry.value_ptr;
                var i: usize = 0;
                while (i < list.items.len) : (i += 1) {
                    if (list.items[i] == topic_id) {
                        _ = list.swapRemove(i);
                        break;
                    }
                }
                if (list.items.len == 0) {
                    const owned_key = @constCast(entry.key_ptr.*);
                    list.deinit(gpa);
                    _ = mc.channels.remove(channel);
                    mc.pending_unsub.append(gpa, owned_key) catch gpa.free(owned_key);
                    mc.work_cond.signal();
                }
            }
        }

        gpa.free(removed.value.topic);
        removed.value.value.deinit(gpa);
    }

    pub fn onRefreshValue(self: *Handler, _: *rtd.RtdContext, topic_id: rtd.LONG) rtd.RtdValue {
        self.mu.lock();
        defer self.mu.unlock();

        const state = self.topics.getPtr(topic_id) orelse return rtd.RtdValue.na;
        return switch (state.value) {
            .string => |s| blk: {
                // Copy into scratch so the pointer survives after mu is released.
                const len = @min(s.len, self.refresh_str_scratch.len);
                @memcpy(self.refresh_str_scratch[0..len], s[0..len]);
                break :blk .{ .string = self.refresh_str_scratch[0..len] };
            },
            else => state.value.toRtdValue(),
        };
    }

    pub fn onTerminate(self: *Handler, _: *rtd.RtdContext) void {
        rtd.debugLog("massive_rtd: onTerminate", .{});
        // Order matters: set `terminating` BEFORE `running=false` so any
        // worker that observes running still true will already see the
        // notify-suppression flag on its next dispatch.
        self.terminating.store(true, .release);
        self.running.store(false, .release);

        // Snapshot the market list so we can iterate without holding the
        // handler mutex (join may block, and a worker that's currently
        // dispatching needs `self.mu` to finish and release).
        self.mu.lock();
        var market_list: std.ArrayListUnmanaged(*MarketConn) = .empty;
        defer market_list.deinit(gpa);
        var mit = self.markets.iterator();
        while (mit.next()) |e| market_list.append(gpa, e.value_ptr.*) catch {};
        self.mu.unlock();

        // Kick each reader's socket so any in-flight recv returns immediately.
        // The reader thread still owns the close (via defer in workerSession);
        // shutdown just unblocks the syscall so join() returns promptly.
        // We do NOT closesocket() from here: on Windows, closing a socket
        // while another thread is inside a recv on it is undefined behavior
        // and was observed to crash Excel during teardown.
        //
        // The writer thread wakes from its timedWait within ≤1s and exits
        // when it observes running=false; no extra signal needed.
        for (market_list.items) |mc| {
            kickLiveSocket(mc);
        }

        // Only join the supervisor (worker_thread). It joins writer_thread
        // itself inside workerSession's defer before returning, so touching
        // writer_thread here would be a double-join.
        for (market_list.items) |mc| {
            if (mc.worker_thread) |t| {
                t.join();
                mc.worker_thread = null;
            }
        }

        // Workers are gone. Hold self.mu across the free purely for symmetry
        // with onDisconnect's locking discipline - nothing else should be
        // touching these maps now.
        self.mu.lock();
        defer self.mu.unlock();

        var it = self.topics.iterator();
        while (it.next()) |e| {
            gpa.free(e.value_ptr.topic);
            e.value_ptr.value.deinit(gpa);
        }
        self.topics.deinit(gpa);

        var mit2 = self.markets.iterator();
        while (mit2.next()) |e| {
            const mc = e.value_ptr.*;
            mc.deinit();
            gpa.destroy(mc);
        }
        self.markets.deinit(gpa);
    }

    /// Caller must hold self.mu.
    fn getOrCreateMarketLocked(self: *Handler, market: []const u8) ?*MarketConn {
        if (self.markets.get(market)) |mc| return mc;

        const owned_name = gpa.dupe(u8, market) catch return null;
        errdefer gpa.free(owned_name);

        const mc = gpa.create(MarketConn) catch {
            gpa.free(owned_name);
            return null;
        };
        mc.* = .{ .name = owned_name, .handler = self };

        self.markets.put(gpa, owned_name, mc) catch {
            gpa.destroy(mc);
            gpa.free(owned_name);
            return null;
        };

        // Spawn the supervisor thread. It captures the MarketConn pointer
        // directly; it's stable for the remainder of the Excel session.
        mc.worker_thread = std.Thread.spawn(.{}, workerMain, .{mc}) catch |err| {
            rtd.debugLog("massive_rtd: failed to spawn worker for {s}: {s}", .{ market, @errorName(err) });
            // Leave mc in place but without a thread - onTerminate will clean
            // it up. Don't unwind the map insert because the topic refcount is
            // about to be added to it.
            return mc;
        };

        rtd.debugLog("massive_rtd: opened market connection for '{s}'", .{market});
        return mc;
    }
};

/// `net.Stream.Handle` is `i32` on posix and `*SOCKET__opaque` on Windows;
/// both round-trip through i64 losslessly. -1 is the "no socket" sentinel.
fn socketHandleToI64(h: std.net.Stream.Handle) i64 {
    return if (@import("builtin").os.tag == .windows)
        @as(i64, @bitCast(@as(u64, @intFromPtr(h))))
    else
        @as(i64, h);
}

fn i64ToSocketHandle(v: i64) std.net.Stream.Handle {
    return if (@import("builtin").os.tag == .windows)
        @as(std.net.Stream.Handle, @ptrFromInt(@as(usize, @bitCast(@as(isize, @intCast(v))))))
    else
        @as(std.net.Stream.Handle, @intCast(v));
}

/// Shutdown both directions of the socket to unblock any in-flight recv on
/// the reader thread so join() returns promptly. The reader thread still
/// owns the close via client.deinit.
fn kickSocket(h: std.net.Stream.Handle) void {
    std.posix.shutdown(h, .both) catch {};
}

/// Read live_socket atomically and kick it only if a session is active.
/// Safe to call from any thread at any point; guards against the -1 sentinel
/// that means "no session" (i64ToSocketHandle(-1) is undefined on Windows).
fn kickLiveSocket(mc: *MarketConn) void {
    const v = mc.live_socket.load(.acquire);
    if (v != -1) kickSocket(i64ToSocketHandle(v));
}

/// Known Massive market names. Matches the documented set of per-market WS
/// paths: stocks, options, forex, crypto, indices, futures.
fn isKnownMarket(name: []const u8) bool {
    const known = [_][]const u8{ "stocks", "options", "forex", "crypto", "indices", "futures" };
    for (known) |k| if (std.mem.eql(u8, name, k)) return true;
    return false;
}

// ============================================================================
// Worker thread (one per MarketConn)
// ============================================================================

fn workerMain(mc: *MarketConn) void {
    rtd.debugLog("massive_rtd: [{s}] worker starting", .{mc.name});

    // Seed the jitter RNG once. `milliTimestamp` as seed is fine - we only
    // need the different workers / processes to diverge slightly to avoid
    // synchronized reconnects.
    mc.jitter_rng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));

    while (mc.handler.running.load(.acquire)) {
        // If the *previous* session reached the read loop, the error that
        // ended it was a mid-stream drop - not a systemic auth/plan/key
        // problem. Reset the backoff so the user sees a fast recovery.
        if (mc.session_was_authed) {
            mc.reconnect_attempts = 0;
            mc.session_was_authed = false;
        }

        var terminal = false;
        workerSession(mc) catch |err| {
            rtd.debugLog("massive_rtd: [{s}] session error: {s}", .{ mc.name, @errorName(err) });
            // Terminal errors: no point retrying. Missing key won't appear,
            // bad key won't become good, and a plan that doesn't cover this
            // market won't start covering it mid-session. Exit the worker so
            // we don't hammer the endpoint with a doomed reconnect loop.
            // Cells for this market stay #N/A; the user sees the cause in
            // the debug log (and, for missing key at startup, in the dialog
            // popped by init() in main.zig).
            terminal = switch (err) {
                error.NoApiKey, error.AuthFailed => true,
                else => false,
            };
        };
        if (terminal) {
            rtd.debugLog("massive_rtd: [{s}] terminal auth error - worker exiting, cells will stay #N/A until Excel restart", .{mc.name});
            return;
        }

        if (!mc.handler.running.load(.acquire)) break;

        mc.reconnect_attempts += 1;
        const delay_ms = nextBackoffMs(mc);
        rtd.debugLog("massive_rtd: [{s}] reconnecting in {d}ms (attempt {d})", .{ mc.name, delay_ms, mc.reconnect_attempts });

        // Sleep in 100ms slices so teardown still wakes us within ~100ms.
        var slept_ms: u64 = 0;
        while (slept_ms < delay_ms and mc.handler.running.load(.acquire)) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            slept_ms += 100;
        }
    }
    rtd.debugLog("massive_rtd: [{s}] worker stopped", .{mc.name});
}

/// Capped exponential backoff with ±25% jitter.
///
/// Base 2s, cap 60s. `attempts=1` gives ~2s, `attempts=2` ~4s, `attempts=3`
/// ~8s, … saturating at 60s around attempt 6. The jitter spreads out a herd
/// of XLLs reconnecting after a server-side blip so we don't all hit the
/// endpoint at exactly the same moment.
fn nextBackoffMs(mc: *MarketConn) u64 {
    const base_ms: u64 = 2_000;
    const cap_ms: u64 = 60_000;

    // Shift by (attempts - 1) since attempts is incremented before this call.
    // Clamp to a small exponent so the shift can't overflow - the cap below
    // handles the rest.
    const shift: u6 = @intCast(@min(mc.reconnect_attempts -| 1, 10));
    const raw = base_ms << shift;
    const capped = @min(raw, cap_ms);

    const rng = mc.jitter_rng.random();
    // Uniform in [-0.25, +0.25] of capped, applied symmetrically.
    const quarter = capped / 4;
    const jitter = rng.uintLessThan(u64, quarter * 2 + 1);
    // capped - quarter can underflow if quarter > capped, which only happens
    // when capped < 4. Guard it.
    const lo = if (capped > quarter) capped - quarter else 0;
    return lo + jitter;
}

fn workerSession(mc: *MarketConn) !void {
    // Load CA bundle (once per session - cheap, PEM parse).
    var bundle = try ws.loadCaBundleFromPem(gpa, ca_bundle_pem);
    defer bundle.deinit(gpa);

    // Each market has its own wire path: /stocks, /crypto, ...
    var path_buf: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/{s}", .{mc.name});

    const cfg = config.load();
    rtd.debugLog("massive_rtd: [{s}] connecting to {s}:{d}{s} (insecure={})", .{ mc.name, cfg.host, cfg.port, path, cfg.insecure });
    const client = try ws.Client.connect(gpa, cfg.host, cfg.port, path, bundle, .{
        .insecure_skip_verify = cfg.insecure,
    });
    // Publish the socket so onTerminate can kick it (shutdown SHUT_RDWR) and
    // unblock the reader's recv so join() returns promptly.
    mc.live_socket.store(socketHandleToI64(client.stream.handle), .release);
    defer {
        // If onTerminate kicked the socket, the TLS layer is in an undefined
        // state. Skip the graceful close and go straight to freeing; the server
        // observes the RST and cleans up its end.
        const terminating = mc.handler.terminating.load(.acquire);
        mc.live_socket.store(-1, .release);
        if (!terminating) {
            mc.write_mu.lock();
            client.sendClose(1000) catch {};
            client.tls_client.end() catch {};
            mc.write_mu.unlock();
        }
        client.stream.close();
        client.stream_closed = true;
        client.closed = true;
        client.deinit();
    }

    // Auth handshake.
    const api_key = cfg.api_key orelse {
        rtd.debugLog("massive_rtd: [{s}] no API key configured - set MASSIVE_API_KEY or add api_key to config.json", .{mc.name});
        return error.NoApiKey;
    };
    try protocol.authenticate(client, gpa, api_key);
    rtd.debugLog("massive_rtd: [{s}] authenticated", .{mc.name});
    mc.session_was_authed = true;

    // Re-subscribe any channels we already hold (after a reconnect).
    try flushInitialSubscribes(mc, client);

    // Spawn the writer thread. It owns all outbound sends from this point:
    // flushPending (subs/unsubs), pings, and recv-deadline enforcement.
    // The reader thread below only writes when replying to a server ping
    // (sendPong), taking write_mu for that.
    mc.writer_thread = try std.Thread.spawn(.{}, writerThread, .{ mc, client });
    defer {
        // Signal the writer to wake and check running=false, then join.
        mc.mu.lock();
        mc.work_cond.signal();
        mc.mu.unlock();
        if (mc.writer_thread) |t| t.join();
        mc.writer_thread = null;
    }

    // Reader loop: block on readMessage, dispatch, repeat. No polling, no
    // timeouts, no platform-specific tricks. The writer thread handles
    // everything that needs to run on a schedule.
    while (mc.handler.running.load(.acquire)) {
        const msg = client.readMessage(gpa) catch |err| {
            if (err != error.ConnectionClosed) {
                rtd.debugLog("massive_rtd: [{s}] readMessage err: {s}", .{ mc.name, @errorName(err) });
            }
            return err;
        };
        defer gpa.free(msg.payload);

        // Server pings: reply under write_mu so we don't race the writer.
        if (msg.opcode == .ping) {
            mc.write_mu.lock();
            client.sendFrame(.pong, msg.payload) catch {};
            mc.write_mu.unlock();
            continue;
        }

        handleDataMessage(mc, msg.payload) catch |err| {
            rtd.debugLog("massive_rtd: [{s}] handle error: {s}", .{ mc.name, @errorName(err) });
        };
    }
}

/// Writer thread: runs for the lifetime of one session alongside the reader.
/// Owns all outbound sends except pong replies (which the reader sends under
/// write_mu). Sleeps on work_cond so it wakes immediately when onConnect or
/// onDisconnect queues a sub/unsub, rather than spinning or polling.
fn writerThread(mc: *MarketConn, client: *ws.Client) void {
    const ping_interval_ms: i64 = 20_000;
    const recv_deadline_ms: i64 = 45_000;
    var last_ping_ms = std.time.milliTimestamp();

    while (mc.handler.running.load(.acquire)) {
        // Sleep until signalled or 1s elapses - whichever comes first.
        mc.mu.lock();
        mc.work_cond.timedWait(&mc.mu, 1 * std.time.ns_per_s) catch {};
        mc.mu.unlock();

        if (!mc.handler.running.load(.acquire)) break;
        if (mc.handler.terminating.load(.acquire)) break;

        // Flush any pending sub/unsub messages.
        flushPending(mc, client) catch |err| {
            rtd.debugLog("massive_rtd: [{s}] writer flushPending err: {s}", .{ mc.name, @errorName(err) });
            kickLiveSocket(mc);
            return;
        };

        const now_ms = std.time.milliTimestamp();

        // Recv deadline: if the reader hasn't seen a frame in 45s the
        // connection is silently dead. Kick the socket to unblock readMessage.
        if (now_ms - client.last_recv_ms >= recv_deadline_ms) {
            rtd.debugLog("massive_rtd: [{s}] recv deadline ({d}ms) exceeded - forcing reconnect", .{ mc.name, recv_deadline_ms });
            kickLiveSocket(mc);
            return;
        }

        // Periodic ping to keep NAT mappings warm.
        if (now_ms - last_ping_ms >= ping_interval_ms) {
            mc.write_mu.lock();
            client.sendPing("") catch |err| {
                mc.write_mu.unlock();
                rtd.debugLog("massive_rtd: [{s}] ping failed: {s}", .{ mc.name, @errorName(err) });
                kickLiveSocket(mc);
                return;
            };
            mc.write_mu.unlock();
            last_ping_ms = now_ms;
        }
    }
    rtd.debugLog("massive_rtd: [{s}] writer thread exiting", .{mc.name});
}

fn flushInitialSubscribes(mc: *MarketConn, client: *ws.Client) !void {
    // After a reconnect, re-subscribe to every channel we still care about.
    // Drain any queued subscribes first (they're redundant with mc.channels),
    // but keep queued unsubscribes - they still need to be flushed next tick.
    mc.mu.lock();
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(gpa);

    var it = mc.channels.iterator();
    while (it.next()) |e| names.append(gpa, e.key_ptr.*) catch {};

    for (mc.pending_sub.items) |s| gpa.free(s);
    mc.pending_sub.clearRetainingCapacity();
    mc.mu.unlock();

    if (names.items.len == 0) return;
    rtd.debugLog("massive_rtd: [{s}] re-subscribing {d} channels after reconnect", .{ mc.name, names.items.len });
    try protocol.subscribe(client, gpa, names.items);
}

fn flushPending(mc: *MarketConn, client: *ws.Client) !void {
    // If we're terminating, don't bother sending queued sub/unsub - the
    // socket is about to be yanked and the server will notice. Leave the
    // queued strings in place so MarketConn.deinit frees them.
    if (mc.handler.terminating.load(.acquire)) return;

    // Snapshot queued sub/unsub lists under the lock, release, then send.
    // Owns the moved-out strings so we free after sending.
    mc.mu.lock();
    var subs: std.ArrayListUnmanaged([]u8) = .empty;
    var unsubs: std.ArrayListUnmanaged([]u8) = .empty;
    defer subs.deinit(gpa);
    defer unsubs.deinit(gpa);

    for (mc.pending_sub.items) |s| subs.append(gpa, s) catch gpa.free(s);
    mc.pending_sub.clearRetainingCapacity();

    for (mc.pending_unsub.items) |s| unsubs.append(gpa, s) catch gpa.free(s);
    mc.pending_unsub.clearRetainingCapacity();
    mc.mu.unlock();

    defer for (subs.items) |s| gpa.free(s);
    defer for (unsubs.items) |s| gpa.free(s);

    if (subs.items.len > 0) try protocol.subscribe(client, gpa, @ptrCast(subs.items));
    if (unsubs.items.len > 0) try protocol.unsubscribe(client, gpa, @ptrCast(unsubs.items));
}

// ============================================================================
// Incoming message dispatch
// ============================================================================

fn handleDataMessage(mc: *MarketConn, payload: []const u8) !void {
    // If we're tearing down, don't touch handler/ctx at all - onTerminate may
    // be actively freeing the framework's topic map from the main thread.
    if (mc.handler.terminating.load(.acquire)) return;

    // Every data message is a JSON array of event objects. Parse into the
    // per-market frame arena; reset once at the top so we reuse pages.
    _ = mc.frame_arena.reset(.retain_capacity);
    const frame = mc.frame_arena.allocator();

    const root = try std.json.parseFromSliceLeaky(std.json.Value, frame, payload, .{});
    if (root != .array) return error.NotAnArray;

    const handler = mc.handler;
    const ctx = handler.ctx orelse return;

    var any_dirty = false;
    // Lock order throughout the module is Handler -> MarketConn. Dispatch
    // reads both: Handler.topics for the TopicState we mutate, and
    // mc.channels to find which topic_ids care about an incoming (ev, sym).
    // Holding both for the whole frame is fine - onConnect / onDisconnect
    // also take them in this order.
    handler.mu.lock();
    defer handler.mu.unlock();
    mc.mu.lock();
    defer mc.mu.unlock();

    // Re-check after acquiring the mutex: onTerminate may have flipped the
    // flag while we were blocked on the lock, and once it's set the main
    // thread is about to free handler.topics from under us.
    if (handler.terminating.load(.acquire)) return;

    // Scratch buffer for building "<ev>.<sym>" channel keys to look up in the
    // dispatch index. Massive's event prefixes are ≤4 chars and symbols are
    // bounded well under 64; 96 leaves plenty of headroom.
    var channel_buf: [96]u8 = undefined;

    const dispatch_start_ms = std.time.milliTimestamp();

    for (root.array.items) |evt| {
        if (evt != .object) continue;
        const obj = evt.object;

        const ev_val = obj.get("ev") orelse continue;
        if (ev_val != .string) continue;
        const ev = ev_val.string;

        // Status messages ("ev":"status") aren't cell data - log and skip.
        if (std.mem.eql(u8, ev, "status")) {
            if (obj.get("message")) |m| {
                if (m == .string) rtd.debugLog("massive_rtd: [{s}] status: {s}", .{ mc.name, m.string });
            }
            continue;
        }

        // All data events carry a symbol field, but the key name varies:
        // "sym" for stocks/options/FMV, "pair" for forex & crypto trades/quotes/
        // aggs, "T" (capital) for indices value ticks and stocks LULD.
        const sym_val = obj.get("sym") orelse obj.get("pair") orelse obj.get("T") orelse continue;
        if (sym_val != .string) continue;
        const sym = sym_val.string;

        const channel = std.fmt.bufPrint(&channel_buf, "{s}.{s}", .{ ev, sym }) catch continue;
        const subs = mc.channels.get(channel) orelse continue;

        for (subs.items) |topic_id| {
            const state = handler.topics.getPtr(topic_id) orelse continue;

            const field_name = if (state.field.len > 0) state.field else protocol.defaultFieldFor(ev);
            if (field_name.len == 0) {
                // Serialize the whole object as a string (arena-scratch).
                const s = try std.json.Stringify.valueAlloc(frame, evt, .{});
                state.value.deinit(gpa);
                state.value = try makeStringValue(s);
            } else if (obj.get(field_name)) |fv| {
                state.value.deinit(gpa);
                state.value = try valueFromJson(fv, frame);
            } else {
                state.value.deinit(gpa);
                state.value = .{ .err = @bitCast(@as(u32, 0x80020004)) }; // #N/A
            }

            // ctx.topics is owned by the framework and mutated on the main
            // thread by ConnectData/DisconnectData. Access it only under
            // ctx.topics_mu to avoid racing a hashmap rehash.
            ctx.topics_mu.lock();
            if (ctx.topics.getPtr(topic_id)) |tentry| {
                tentry.dirty = true;
                any_dirty = true;
            }
            ctx.topics_mu.unlock();
        }
    }

    // Throttle UpdateNotify to at most once per 100ms. The COM call marshals
    // across threads into Excel's STA; flooding it at firehose rates backs up
    // the message pump and eventually crashes Excel. Excel's own RTD throttle
    // interval (default 2s) means extra notifications are redundant anyway.
    if (any_dirty and !handler.terminating.load(.acquire)) {
        const now_ms = std.time.milliTimestamp();
        if (now_ms - handler.last_notify_ms >= 100) {
            handler.last_notify_ms = now_ms;
            ctx.notifyExcel();
        }
    }

    // Update the dispatch-time EWMA and, if it's trending high, warn the
    // user that they're in danger of being disconnected for slow consumption.
    // The EWMA (alpha=1/8) smooths single-frame blips so we only complain
    // about sustained lag. Warning is rate-limited to once per 10s so a
    // workbook in a genuinely bad state doesn't spam the log.
    const elapsed_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - dispatch_start_ms));
    mc.dispatch_ewma_ms = (mc.dispatch_ewma_ms * 7 + elapsed_ms) / 8;
    if (mc.dispatch_ewma_ms >= 100) {
        const now_ms = std.time.milliTimestamp();
        if (now_ms - mc.last_lag_warn_ms >= 10_000) {
            mc.last_lag_warn_ms = now_ms;
            rtd.debugLog(
                "massive_rtd: [{s}] dispatch lagging (~{d}ms/frame avg) - reduce subscriptions or Massive may drop the connection",
                .{ mc.name, mc.dispatch_ewma_ms },
            );
        }
    }
}

/// Scalar-typed projection of a JSON value into the shape an RTD cell can
/// hold. Strings are returned as UTF-8 slices borrowing from the scratch
/// arena (or, for `.string` inputs, from the original JSON buffer). Kept
/// pure and allocation-light so it's testable without touching the COM/RTD
/// layer — `toOwnedValue` does the UTF-16 conversion for Excel.
const IntermediateValue = union(enum) {
    int: i32,
    double: f64,
    boolean: bool,
    /// UTF-8. Borrowed — caller must copy before the scratch arena resets.
    string_utf8: []const u8,
    /// `#N/A` sentinel. We map JSON null to this so empty payload fields
    /// render as an Excel error rather than a zero.
    na,
};

const NA_ERR: i32 = @bitCast(@as(u32, 0x80020004));

fn classify(v: std.json.Value, scratch: std.mem.Allocator) !IntermediateValue {
    return switch (v) {
        // JSON integers that fit i32 stay integers so Excel shows them
        // without a decimal; anything wider falls back to f64 (losing
        // precision past 2^53, but Massive's integer fields are all well
        // under that).
        .integer => |i| if (i >= std.math.minInt(i32) and i <= std.math.maxInt(i32))
            IntermediateValue{ .int = @intCast(i) }
        else
            IntermediateValue{ .double = @floatFromInt(i) },
        .float => |f| .{ .double = f },
        // `number_string` appears when the parser can't fit the number into
        // its own numeric types. Round-trip through parseFloat; on failure
        // surface 0 rather than an error so a single odd field doesn't
        // poison the whole frame.
        .number_string => |s| .{ .double = std.fmt.parseFloat(f64, s) catch 0.0 },
        .bool => |b| .{ .boolean = b },
        .string => |s| .{ .string_utf8 = s },
        .null => .na,
        // Nested arrays/objects get stringified into the frame arena and
        // surfaced as strings. Rare — only hits if a user asks for a field
        // whose value is itself a structure.
        .array, .object => .{ .string_utf8 = try std.json.Stringify.valueAlloc(scratch, v, .{}) },
    };
}

fn toOwnedValue(iv: IntermediateValue) !OwnedValue {
    return switch (iv) {
        .int => |v| .{ .int = v },
        .double => |v| .{ .double = v },
        .boolean => |v| .{ .boolean = v },
        .string_utf8 => |s| .{ .string = try std.unicode.utf8ToUtf16LeAlloc(gpa, s) },
        .na => .{ .err = NA_ERR },
    };
}

fn valueFromJson(v: std.json.Value, scratch: std.mem.Allocator) !OwnedValue {
    return toOwnedValue(try classify(v, scratch));
}

fn makeStringValue(utf8: []const u8) !OwnedValue {
    // Convert UTF-8 to UTF-16 for the RTD layer. Lives beyond the frame arena,
    // so allocate on the long-lived gpa.
    return .{ .string = try std.unicode.utf8ToUtf16LeAlloc(gpa, utf8) };
}

test "classify maps JSON scalars to the right cell type" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();

    // Small integer stays an int.
    {
        const iv = try classify(.{ .integer = 42 }, scratch);
        try std.testing.expectEqual(@as(i32, 42), iv.int);
    }
    // Integer beyond i32 range promotes to f64 (loses exactness past 2^53,
    // but this path is for timestamps-as-ints etc. where the caller already
    // accepted that).
    {
        const big: i64 = @as(i64, std.math.maxInt(i32)) + 1;
        const iv = try classify(.{ .integer = big }, scratch);
        try std.testing.expect(iv == .double);
        try std.testing.expectEqual(@as(f64, @floatFromInt(big)), iv.double);
    }
    // Negative i32 boundary.
    {
        const iv = try classify(.{ .integer = std.math.minInt(i32) }, scratch);
        try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), iv.int);
    }
    // Float, bool, string, null.
    {
        const iv = try classify(.{ .float = 3.14 }, scratch);
        try std.testing.expectEqual(@as(f64, 3.14), iv.double);
    }
    {
        const iv = try classify(.{ .bool = true }, scratch);
        try std.testing.expect(iv.boolean);
    }
    {
        const iv = try classify(.{ .string = "AAPL" }, scratch);
        try std.testing.expectEqualStrings("AAPL", iv.string_utf8);
    }
    {
        const iv = try classify(.null, scratch);
        try std.testing.expect(iv == .na);
    }
    // `number_string` for too-wide numbers — succeeds on valid, falls back to 0.
    {
        const iv = try classify(.{ .number_string = "1.5e10" }, scratch);
        try std.testing.expectEqual(@as(f64, 1.5e10), iv.double);
    }
    {
        const iv = try classify(.{ .number_string = "not-a-number" }, scratch);
        try std.testing.expectEqual(@as(f64, 0.0), iv.double);
    }
}

test "classify stringifies nested arrays and objects into the scratch arena" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();

    // Build a JSON array [1, 2, 3] without a live parser.
    var items: [3]std.json.Value = .{
        .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 },
    };
    const arr_val: std.json.Value = .{ .array = std.json.Array.fromOwnedSlice(scratch, &items) };
    const iv = try classify(arr_val, scratch);
    try std.testing.expectEqualStrings("[1,2,3]", iv.string_utf8);
}

test "toOwnedValue surfaces JSON null as Excel #N/A" {
    const ov = try toOwnedValue(.na);
    try std.testing.expectEqual(NA_ERR, ov.err);
}

// ============================================================================
// Framework plumbing
// ============================================================================

pub const rtd_config: rtd.RtdConfig = .{
    .clsid = rtd.guid("D146815B-1D01-4D0D-904C-292533090438"),
    .prog_id = "zigxll.connectors.massive",
};

pub const RtdServerType = rtd.RtdServer(Handler, rtd_config);
