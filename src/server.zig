listener_addr: net.IpAddress,
udp_socket: ?net.Socket = null,
allocator: std.mem.Allocator,
io: Io,

pub const Options = struct {
    allocator: Allocator,
    io: Io,
    listener_addr: net.IpAddress,
};

pub fn init(opts: Options) ReverseServer {
    return .{ .allocator = opts.allocator, .listener_addr = opts.listener_addr, .io = opts.io };
}

pub fn deinit(server: *ReverseServer) void {
    server.udp_socket.?.close(server.io);
}

pub fn bind(server: *ReverseServer) !void {
    const io = server.io;
    server.udp_socket = server.listener_addr.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch |err| {
        log.err("failed to bind to port: {d}: {t}", .{ server.listener_addr.getPort(), err });
        return error.AlreadyReported;
    };
}

pub fn start(server: *ReverseServer) !void {
    try server.bind();
    try server.serve();
}

pub fn serve(server: *ReverseServer) !void {
    while (true) {
        server.recieve() catch |err| {
            _ = err;
            continue;
        };
    }
}

pub fn recieve(server: *ReverseServer) !void {
    const io = server.io;
    var buf: [2048]u8 = undefined;

    const msg = try server.udp_socket.?.receive(io, &buf);
    const parsed_message = Message.parseMessage(msg.data) catch |err| {
        log.err("failed to parse message: {t}", .{err});
        return err;
    };

    switch (parsed_message) {
        .connect => |message| {
            std.log.debug("Connection Message Recieved Session Id: {d}", .{message.session});
            const ack_message: Message = .{ .ack = .{ .session = message.session, .length = 0 } };
            server.send(&msg.from, ack_message) catch |err| {
                log.err("Failed to send the message {t}", .{err});
                return err;
            };
        },
        else => @panic("unhandled message types"),
    }
}

pub fn send(server: *ReverseServer, to: *const IpAddress, message: Message) !void {
    std.log.debug("Sending the message to {f} the message {any}", .{ to, message });
    const io = server.io;
    const message_payload = try message.getPayload(server.allocator);
    defer server.allocator.free(message_payload);
    std.log.debug("Message Payload: {s}", .{message_payload});
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

pub const ReverseServer = @This();
