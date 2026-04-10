// Minimal WebSocket (RFC 6455) client over TLS for Zig 0.15.1.
//
// Only what zigxll-connectors-massive needs:
//   - wss:// connections (no plain ws://)
//   - text frames up to 64 KiB
//   - masked writes (client → server), unmasked reads (server → client)
//   - auto-pong, auto-close handling
//
// Not supported: extensions, fragmentation across frames, large (>64 KiB) messages.

const std = @import("std");
const net = std.net;
const tls = std.crypto.tls;
const sha1 = std.crypto.hash.Sha1;

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

/// Max single-frame payload we'll accept (or emit).
const max_payload = 64 * 1024;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

pub const Message = struct {
    opcode: Opcode,
    /// Heap-allocated, caller owns and must free with `alloc.free(payload)`.
    payload: []u8,
};

pub const ConnectError = error{
    HostnameTooLong,
    HttpUpgradeFailed,
    BadAcceptHeader,
    MissingAcceptHeader,
} || anyerror;

pub const Client = struct {
    allocator: std.mem.Allocator,

    stream: net.Stream,
    stream_reader: net.Stream.Reader,
    stream_writer: net.Stream.Writer,

    tls_client: tls.Client,

    // Owned buffers backing the reader/writer interfaces. All must outlive the client.
    sock_read_buf: []u8,
    sock_write_buf: []u8,
    tls_read_buf: []u8,
    tls_write_buf: []u8,

    closed: bool = false,

    pub const Options = struct {
        /// If true, TLS cert chain is NOT verified. Only enable for local
        /// mock-server testing against a self-signed cert. Never ship this.
        insecure_skip_verify: bool = false,
    };

    /// Establish a TLS connection, perform the HTTP upgrade handshake, and
    /// return a ready-to-use WebSocket client.
    ///
    /// The client is heap-allocated because `tls.Client` and `net.Stream.Reader`
    /// hold internal `*Reader`/`*Writer` pointers into their own struct fields —
    /// moving or copying the parent would invalidate those pointers.
    ///
    /// `host` is the DNS name (used for SNI + cert verification).
    /// `path` is the URL path starting with "/", e.g. "/stocks".
    /// `ca_bundle` must be populated unless `options.insecure_skip_verify` is true.
    pub fn connect(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        path: []const u8,
        ca_bundle: std.crypto.Certificate.Bundle,
        options: Options,
    ) !*Client {
        // Each stream + TLS buffer must be at least `tls.Client.min_buffer_len`
        // (= max_ciphertext_record_len, ~16645 bytes). Round up comfortably.
        const stream_buf_size = tls.Client.min_buffer_len + 1024;
        const sock_read_buf = try allocator.alloc(u8, stream_buf_size);
        errdefer allocator.free(sock_read_buf);
        const sock_write_buf = try allocator.alloc(u8, stream_buf_size);
        errdefer allocator.free(sock_write_buf);
        const tls_read_buf = try allocator.alloc(u8, stream_buf_size);
        errdefer allocator.free(tls_read_buf);
        const tls_write_buf = try allocator.alloc(u8, stream_buf_size);
        errdefer allocator.free(tls_write_buf);

        const stream = try net.tcpConnectToHost(allocator, host, port);
        errdefer stream.close();

        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .stream = stream,
            .stream_reader = stream.reader(sock_read_buf),
            .stream_writer = stream.writer(sock_write_buf),
            .tls_client = undefined,
            .sock_read_buf = sock_read_buf,
            .sock_write_buf = sock_write_buf,
            .tls_read_buf = tls_read_buf,
            .tls_write_buf = tls_write_buf,
        };

        // `self` is now stable on the heap — safe to store pointers into fields.
        self.tls_client = try tls.Client.init(
            self.stream_reader.interface(),
            &self.stream_writer.interface,
            .{
                .host = .{ .explicit = host },
                .ca = if (options.insecure_skip_verify) .no_verification else .{ .bundle = ca_bundle },
                .read_buffer = tls_read_buf,
                .write_buffer = tls_write_buf,
                .allow_truncation_attacks = true,
            },
        );

        try self.performUpgrade(host, path);

        return self;
    }

    pub fn deinit(self: *Client) void {
        if (!self.closed) {
            self.sendClose(1000) catch {};
            self.tls_client.end() catch {};
        }
        self.stream.close();
        const alloc = self.allocator;
        alloc.free(self.sock_read_buf);
        alloc.free(self.sock_write_buf);
        alloc.free(self.tls_read_buf);
        alloc.free(self.tls_write_buf);
        alloc.destroy(self);
    }

    fn tlsReader(self: *Client) *Reader {
        return &self.tls_client.reader;
    }

    fn tlsWriter(self: *Client) *Writer {
        return &self.tls_client.writer;
    }

    /// Flush the full TLS → socket writer chain. TLS `Client.writer.flush()`
    /// only encrypts into the socket writer's buffer; the socket writer itself
    /// must be flushed to push bytes to the kernel.
    fn flushChain(self: *Client) !void {
        try self.tls_client.writer.flush();
        try self.stream_writer.interface.flush();
    }

    // ---- HTTP upgrade ----

    fn performUpgrade(self: *Client, host: []const u8, path: []const u8) !void {
        // Random 16-byte nonce, base64-encoded.
        var key_raw: [16]u8 = undefined;
        std.crypto.random.bytes(&key_raw);
        var key_b64_buf: [24]u8 = undefined;
        const key_b64 = std.base64.standard.Encoder.encode(&key_b64_buf, &key_raw);

        const w = self.tlsWriter();
        try w.print(
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "User-Agent: zigxll-massive/0.1\r\n\r\n",
            .{ path, host, key_b64 },
        );
        try self.flushChain();

        // Parse response line by line until blank line.
        // Note: we can't use takeDelimiterInclusive on the TLS reader because
        // of a Reader.stream() contract mismatch in std 0.15.1 — the TLS client
        // advances `r.end` directly but returns 0, and peekDelimiterInclusive
        // only searches `end_cap[0..n]` instead of the full buffer. Use takeByte
        // instead, which works correctly because it goes through fill/peek.
        const r = self.tlsReader();

        var line_buf: [2048]u8 = undefined;

        // Status line
        const status_line = try readLine(r, &line_buf);
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 101 ") and !std.mem.startsWith(u8, status_line, "HTTP/1.0 101 ")) {
            std.log.err("ws upgrade failed: {s}", .{status_line});
            return error.HttpUpgradeFailed;
        }

        // Expected Sec-WebSocket-Accept value:
        //   base64(SHA1(key_b64 ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
        var sha = sha1.init(.{});
        sha.update(key_b64);
        sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [sha1.digest_length]u8 = undefined;
        sha.final(&digest);
        var expected_accept_buf: [28]u8 = undefined;
        const expected_accept = std.base64.standard.Encoder.encode(&expected_accept_buf, &digest);

        var saw_accept = false;
        while (true) {
            const line = try readLine(r, &line_buf);
            if (line.len == 0) break; // end of headers

            // Case-insensitive compare on header name up to ':'
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
                if (!std.mem.eql(u8, value, expected_accept)) {
                    std.log.err("bad accept header: got '{s}' want '{s}'", .{ value, expected_accept });
                    return error.BadAcceptHeader;
                }
                saw_accept = true;
            }
        }
        if (!saw_accept) return error.MissingAcceptHeader;
    }

    // ---- Frame I/O ----

    /// Send a text message. Masked, unfragmented.
    pub fn sendText(self: *Client, payload: []const u8) !void {
        try self.sendFrame(.text, payload);
    }

    /// Send a close frame with the given status code.
    pub fn sendClose(self: *Client, code: u16) !void {
        if (self.closed) return;
        var body: [2]u8 = undefined;
        std.mem.writeInt(u16, &body, code, .big);
        try self.sendFrame(.close, &body);
        self.closed = true;
    }

    fn sendFrame(self: *Client, opcode: Opcode, payload: []const u8) !void {
        if (payload.len > max_payload) return error.PayloadTooLarge;
        const w = self.tlsWriter();

        // FIN=1, RSV=0, opcode
        const b0: u8 = 0x80 | @as(u8, @intFromEnum(opcode));
        try w.writeByte(b0);

        // MASK=1, payload length (7 / 16 / 64-bit ext)
        const len = payload.len;
        if (len < 126) {
            try w.writeByte(0x80 | @as(u8, @intCast(len)));
        } else if (len <= 0xFFFF) {
            try w.writeByte(0x80 | 126);
            var ext: [2]u8 = undefined;
            std.mem.writeInt(u16, &ext, @intCast(len), .big);
            try w.writeAll(&ext);
        } else {
            try w.writeByte(0x80 | 127);
            var ext: [8]u8 = undefined;
            std.mem.writeInt(u64, &ext, len, .big);
            try w.writeAll(&ext);
        }

        // Random mask key, then masked payload
        var mask: [4]u8 = undefined;
        std.crypto.random.bytes(&mask);
        try w.writeAll(&mask);

        // Mask in-place into a small scratch buffer (stack).
        var scratch: [1024]u8 = undefined;
        var i: usize = 0;
        while (i < payload.len) {
            const chunk_len = @min(scratch.len, payload.len - i);
            for (0..chunk_len) |j| {
                scratch[j] = payload[i + j] ^ mask[(i + j) & 3];
            }
            try w.writeAll(scratch[0..chunk_len]);
            i += chunk_len;
        }
        try self.flushChain();
    }

    /// Read the next **application** message (text/binary) from the server,
    /// transparently handling ping/pong and close frames.
    /// Returns a heap-allocated payload — caller owns.
    pub fn readMessage(self: *Client, alloc: std.mem.Allocator) !Message {
        while (true) {
            const frame = try self.readRawFrame(alloc);
            switch (frame.opcode) {
                .text, .binary => return frame,
                .ping => {
                    // Reply with a pong echoing the payload.
                    try self.sendFrame(.pong, frame.payload);
                    alloc.free(frame.payload);
                },
                .pong => {
                    alloc.free(frame.payload);
                },
                .close => {
                    alloc.free(frame.payload);
                    self.closed = true;
                    return error.ConnectionClosed;
                },
                .continuation => {
                    alloc.free(frame.payload);
                    return error.UnexpectedContinuation;
                },
            }
        }
    }

    fn readRawFrame(self: *Client, alloc: std.mem.Allocator) !Message {
        const r = self.tlsReader();

        const hdr = try r.takeArray(2);
        const b0 = hdr[0];
        const b1 = hdr[1];

        const fin = (b0 & 0x80) != 0;
        const opcode_raw: u4 = @intCast(b0 & 0x0F);
        const masked = (b1 & 0x80) != 0;
        const len7: u7 = @intCast(b1 & 0x7F);

        if (!fin) return error.FragmentedFrameNotSupported;
        if (masked) return error.ServerMaskedFrame;

        const len: usize = switch (len7) {
            126 => try r.takeInt(u16, .big),
            127 => blk: {
                const l = try r.takeInt(u64, .big);
                if (l > max_payload) return error.PayloadTooLarge;
                break :blk @intCast(l);
            },
            else => len7,
        };

        if (len > max_payload) return error.PayloadTooLarge;

        const payload = try alloc.alloc(u8, len);
        errdefer alloc.free(payload);

        var read_so_far: usize = 0;
        while (read_so_far < len) {
            const src = try r.take(len - read_so_far);
            @memcpy(payload[read_so_far..][0..src.len], src);
            read_so_far += src.len;
        }

        const opcode: Opcode = std.meta.intToEnum(Opcode, opcode_raw) catch return error.InvalidOpcode;
        return .{ .opcode = opcode, .payload = payload };
    }
};

/// Read a CRLF-terminated line into `buf`, returning the line without the CRLF.
/// Reads byte-by-byte through `takeByte`, which is safe on the std 0.15.1 TLS
/// reader (unlike `takeDelimiterInclusive`).
fn readLine(r: *Reader, buf: []u8) ![]const u8 {
    var i: usize = 0;
    while (i < buf.len) {
        const b = try r.takeByte();
        if (b == '\r') {
            // Expect LF next.
            const lf = try r.takeByte();
            if (lf != '\n') return error.MalformedHttpLine;
            return buf[0..i];
        }
        if (b == '\n') {
            // Bare LF — tolerate.
            return buf[0..i];
        }
        buf[i] = b;
        i += 1;
    }
    return error.HttpLineTooLong;
}

// ============================================================================
// CA bundle from embedded PEM
// ============================================================================

/// Populate a Certificate.Bundle from a single PEM blob containing multiple
/// "-----BEGIN CERTIFICATE-----" blocks. Copies `pem` into the bundle's
/// scratch space — `pem` can be `@embedFile`'d read-only memory.
pub fn loadCaBundleFromPem(
    allocator: std.mem.Allocator,
    pem: []const u8,
) !std.crypto.Certificate.Bundle {
    const Certificate = std.crypto.Certificate;
    var bundle: Certificate.Bundle = .{};
    errdefer bundle.deinit(allocator);

    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";

    // Reserve enough room: decoded bytes are at most 3/4 of encoded.
    const upper: u32 = @intCast(pem.len);
    try bundle.bytes.ensureUnusedCapacity(allocator, upper);

    const now_sec = std.time.timestamp();
    const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");

    var start_index: usize = 0;
    while (std.mem.indexOfPos(u8, pem, start_index, begin)) |bm_start| {
        const cert_start = bm_start + begin.len;
        const cert_end = std.mem.indexOfPos(u8, pem, cert_start, end) orelse
            return error.MissingEndCertificateMarker;
        start_index = cert_end + end.len;
        const encoded = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");

        // Ensure capacity for the decoded cert.
        const max_decoded = encoded.len; // base64: decoded <= encoded
        try bundle.bytes.ensureUnusedCapacity(allocator, max_decoded);

        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        const dest_buf = bundle.bytes.allocatedSlice()[decoded_start..];
        const decoded_len = base64.decode(dest_buf, encoded) catch continue;
        bundle.bytes.items.len += decoded_len;

        bundle.parseCert(allocator, decoded_start, now_sec) catch |err| switch (err) {
            error.CertificateHasUnrecognizedObjectId => {
                bundle.bytes.items.len = decoded_start;
            },
            else => |e| return e,
        };
    }

    return bundle;
}
