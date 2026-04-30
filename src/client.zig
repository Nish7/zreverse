io: Io,
socket: net.Socket,
allocator: std.mem.Allocator,

pub fn init(io: Io, allocator: std.mem.Allocator) !Client {
    const any = try net.IpAddress.parse("127.0.0.1", 0);
    const sock = try any.bind(io, .{ .mode = .dgram, .protocol = .udp });
    return .{ .io = io, .socket = sock, .allocator = allocator };
}

pub fn deinit(self: *Client) void {
    self.socket.close(self.io);
}

pub fn sendMessage(self: *Client, to: net.IpAddress, message: Message) !void {
    const message_payload = try message.getPayload(self.allocator);
    defer self.allocator.free(message_payload);
    try self.send(to, message_payload);
}

pub fn send(self: *Client, to: net.IpAddress, data: []const u8) !void {
    try self.socket.send(self.io, &to, data);
}

pub fn recieve(self: *Client) !Message {
    var buf: [4096]u8 = undefined;
    // TODO: fix the buffer sizes
    const msg = try self.socket.receive(self.io, &buf);
    return try Message.parseMessage(self.allocator, msg.data);
}

pub const Client = @This();

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const Message = @import("protocol.zig").Message;
