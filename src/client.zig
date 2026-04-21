io: Io,
socket: net.Socket,

pub fn init(io: Io) !Client {
    const any = try net.IpAddress.parse("127.0.0.1", 0);
    const sock = try any.bind(io, .{ .mode = .dgram, .protocol = .udp });
    return .{ .io = io, .socket = sock };
}

pub fn deinit(self: *Client) void {
    self.socket.close(self.io);
}

pub fn send(self: *Client, to: net.IpAddress, data: []const u8) !void {
    _ = try self.socket.send(self.io, &to, data);
}

pub fn recieve(self: *Client) !Message {
    var buf: [4096]u8 = undefined;
    const msg = try self.socket.receive(self.io, &buf);
    return try Message.parseMessage(msg.data);
}

pub const Client = @This();

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const Message = @import("protocol.zig").Message;
