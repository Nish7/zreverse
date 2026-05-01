listener_addr: net.IpAddress,
udp_socket: ?net.Socket = null,
allocator: std.mem.Allocator,
io: Io,
sessions: std.AutoHashMap(u32, Session),

pub const Options = struct {
    allocator: Allocator,
    io: Io,
    listener_addr: net.IpAddress,
};

pub fn init(opts: Options) ReverseServer {
    const map = std.AutoHashMap(u32, Session).init(opts.allocator);
    return .{ .allocator = opts.allocator, .listener_addr = opts.listener_addr, .io = opts.io, .sessions = map };
}

pub fn deinit(server: *ReverseServer) void {
    if (server.udp_socket) |socket| socket.close(server.io);
    var it = server.sessions.iterator();

    while (it.next()) |s| {
        s.value_ptr.deinit();
    }

    server.sessions.deinit();
}

pub fn bind(server: *ReverseServer) !void {
    log.debug("Server listening: {f}", .{server.listener_addr});
    const io = server.io;
    server.udp_socket = server.listener_addr.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch |err| {
        log.err("failed to bind to port: {d}: {t}", .{ server.listener_addr.getPort(), err });
        return error.AlreadyReported;
    };
}

pub fn getOrCreateSession(server: *ReverseServer, session_id: u32, from: net.IpAddress) !*Session {
    const entry = try server.sessions.getOrPut(session_id);
    if (!entry.found_existing) entry.value_ptr.* = Session.init(server.io, server.allocator, session_id, from);
    return entry.value_ptr;
}

pub fn start(server: *ReverseServer) !void {
    try server.bind();
    try server.serve();
}

pub fn serve(server: *ReverseServer) !void {
    while (true) {
        server.recieve() catch |err| switch (err) {
            error.Canceled => return,
            error.Timeout => {},
            else => {},
        };

        server.checkTimeout() catch |err| {
            log.err("Error detected: {t}", .{err});
        };
    }
}

pub fn retransmitPendingMsg(server: *ReverseServer, session: *Session, out: *std.ArrayList(Message)) !void {
    try session.takeExpiredPendingMessages(out);
    for (out.items) |m| {
        try server.send(&session.from, m);
    }
}

pub fn checkTimeout(server: *ReverseServer) !void {
    var it = server.sessions.iterator();
    const now = Io.Clock.Timestamp.now(server.io, .boot);
    
    var expired: std.ArrayList(Message) = .empty;
    defer expired.deinit(server.allocator);
    
    var expired_sessions: std.ArrayList(u32) = .empty;
    defer expired_sessions.deinit(server.allocator);

    while (it.next()) |s| {
        if (s.value_ptr.checkSessionExpiry(now)) {
            try expired_sessions.append(server.allocator, s.value_ptr.session_id);
            continue;
        }
        
        try server.retransmitPendingMsg(s.value_ptr, &expired);
        expired.clearRetainingCapacity();
    }

    for (expired_sessions.items) |session_id| {
        if (server.sessions.getPtr(session_id)) |s| {
            log.debug("Session Expired by Timeout [{d}]", .{session_id});
            s.deinit();
            _ = server.sessions.remove(session_id);
        }
    }
}

pub fn recieve(server: *ReverseServer) !void {
    const io = server.io;
    var buf: [1024]u8 = undefined;

    const msg = try server.udp_socket.?.receiveTimeout(io, &buf, .{ .duration = .{
        .raw = Io.Duration.fromMilliseconds(50),
        .clock = .boot,
    } });

    const parsed_message = Message.parseMessage(server.allocator, msg.data) catch |err| {
        log.err("failed to parse message: {t}", .{err});
        return err;
    };

    defer parsed_message.deinit(server.allocator);
    var s: *Session = server.getOrCreateSession(parsed_message.getSessionId(), msg.from) catch |err| {
        log.err("Invalid Session Id {t}", .{err});
        return err;
    };

    const res = s.handleIncoming(parsed_message) catch |err| {
        log.err("Error in handling message {t}", .{err});
        return err;
    };

    for (res.slice()) |reply| {
        server.send(&s.from, reply) catch |err| {
            log.err("Error in reply message {t}", .{err});
            return err;
        };
        reply.deinit(server.allocator);
    }

    if (s.closed) {
        s.deinit();
        _ = server.sessions.remove(s.session_id);
    }
}

pub fn send(server: *ReverseServer, to: *const IpAddress, message: Message) !void {
    std.log.debug("Sending the message to {f} the message {any}", .{ to, message });
    const io = server.io;
    const message_payload = try message.getPayload(server.allocator);
    defer server.allocator.free(message_payload);
    try server.udp_socket.?.send(io, to, message_payload);
}

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const IpAddress = net.IpAddress;
const Allocator = std.mem.Allocator;
const log = std.log;

const protocol = @import("protocol.zig");
const Message = protocol.Message;
const session_mod = @import("session.zig");
const Session = session_mod.Session;

pub const ReverseServer = @This();
