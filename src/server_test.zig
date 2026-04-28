test "smoke connect test: expected ack with 0 length" {
    var env = try TestEnv.init();
    defer env.deinit();

    const io = env.threaded.io();
    
    var client = try Client.init(io);
    defer client.deinit();

    var recv_future = try io.concurrent(Server.serve, .{&env.server});
    defer recv_future.await(io) catch {};
    defer recv_future.cancel(io) catch {};

    try client.send(env.server.udp_socket.?.address, "/CONNECT/42");
    const recieved_message = try client.recieve();

    try testing.expectEqual(@as(u32, 0), recieved_message.ack.length);
    try testing.expectEqual(@as(u32, 42), recieved_message.ack.session);
}

test "basic session management test" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client_a = try Client.init(io);
    var client_b = try Client.init(io);
    defer client_a.deinit();
    defer client_b.deinit();

    var serv_future = try env.startServer();
    defer env.stopServer(&serv_future);

    var a_connect_fut = try io.concurrent(Client.send, .{ &client_a, env.server.udp_socket.?.address, "/CONNECT/1/" });
    var b_connect_fut = try io.concurrent(Client.send, .{ &client_b, env.server.udp_socket.?.address, "/CONNECT/2/" });
    var a_ack_fut = try io.concurrent(Client.recieve, .{&client_a});
    var b_ack_fut = try io.concurrent(Client.recieve, .{&client_b});

    try a_connect_fut.await(io);
    try b_connect_fut.await(io);

    const a_ack = try a_ack_fut.await(io);
    const b_ack = try b_ack_fut.await(io);

    try testing.expectEqual(@as(u32, 0), a_ack.ack.length);
    try testing.expectEqual(@as(u32, 1), a_ack.ack.session);
    try testing.expectEqual(@as(u32, 0), b_ack.ack.length);
    try testing.expectEqual(@as(u32, 2), b_ack.ack.session);
}


const std = @import("std");
const server_mod = @import("../src/server.zig");
const client_mod = @import("../src/client.zig");
const testing = std.testing;
const Client = client_mod.Client;
const Server = server_mod.ReverseServer;
const Io = std.Io;
const net = Io.net;

const TestEnv = @import("testEnv.zig");
