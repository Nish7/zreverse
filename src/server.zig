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
    while (true) try server.recieve();
}

pub fn recieve(server: *ReverseServer) !void {
    const io = server.io;
    var buf: [1024]u8 = undefined;
    const msg = try server.udp_socket.?.receive(io, &buf);
    const parsed_message = Message.parseMessage(msg.data) catch |err| {
        log.err("failed to parse message: {t}", .{err});
        return err;
    };

    var s: *Session = try server.getOrCreateSession(parsed_message.getSessionId(), msg.from);

    const res = s.handleIncoming(parsed_message) catch |err| {
        log.err("Error in handling message {t}", .{err});
        return err;
    };
    
    if (res) |reply| server.send(&s.from, reply) catch |err| {
        log.err("Error in reply message {t}", .{err});
        return err;
    };
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
const session = @import("session.zig");
const Session = session.Session;

pub const ReverseServer = @This();
