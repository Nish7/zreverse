const std = @import("std");
const server_mod = @import("../src/server.zig");
const client_mod = @import("../src/client.zig");
const testing = std.testing;
const Client = client_mod.Client;
const Server = server_mod.ReverseServer;
const Io = std.Io;
const net = Io.net;

test "smoke connect test: expected ack with 0 length" {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{
        .concurrent_limit = .limited(4),
    });
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try net.IpAddress.parse("127.0.0.1", 0);
    var server = server_mod.ReverseServer.init(.{
        .allocator = std.testing.allocator,
        .io = io,
        .listener_addr = addr,
    });
    try server.bind();
    defer server.deinit();

    var client = try Client.init(io);
    defer client.deinit();

    var recv_future = try io.concurrent(Server.recieve, .{&server});

    try client.send(server.udp_socket.?.address, "/CONNECT/42");
    const recieved_message = try client.recieve();
    
    try testing.expectEqual(@as(u32, 0), recieved_message.ack.length);
    try testing.expectEqual(@as(u32, 42), recieved_message.ack.session);
    try recv_future.await(io);
}
