test "smoke connect test: expected ack with 0 length" {
    var ctx = try TestCtx.init();
    defer ctx.deinit();

    const server = &ctx.server;
    var client = &ctx.client;
    
    var recv_future = try ctx.io.concurrent(Server.serve, .{server});
    defer recv_future.cancel(ctx.io) catch {};
    
    try client.send(server.udp_socket.?.address, "/CONNECT/42");
    const recieved_message = try client.recieve();

    try testing.expectEqual(@as(u32, 0), recieved_message.ack.length);
    try testing.expectEqual(@as(u32, 42), recieved_message.ack.session);
}

const std = @import("std");
const testing = std.testing;
const Server = @import("server.zig").ReverseServer;
const Io = std.Io;
const net = Io.net;

const TestCtx = @import("testCtx.zig");
