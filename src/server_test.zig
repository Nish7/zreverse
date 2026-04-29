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
    const recieved_message = try client.recieve(testing.allocator);

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
    var a_ack_fut = try io.concurrent(Client.recieve, .{ &client_a, testing.allocator });
    var b_ack_fut = try io.concurrent(Client.recieve, .{ &client_b, testing.allocator });

    try a_connect_fut.await(io);
    try b_connect_fut.await(io);

    const a_ack = try a_ack_fut.await(io);
    const b_ack = try b_ack_fut.await(io);

    try testing.expectEqual(@as(u32, 0), a_ack.ack.length);
    try testing.expectEqual(@as(u32, 1), a_ack.ack.session);
    try testing.expectEqual(@as(u32, 0), b_ack.ack.length);
    try testing.expectEqual(@as(u32, 2), b_ack.ack.session);
}

test "data message: ack and reverse reply" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client = try Client.init(io);
    defer client.deinit();

    var serv_future = try env.startServer();
    defer env.stopServer(&serv_future);

    try expectConnectMessage(&client, &env.server, 12345);
    try expectDataRecieve(&client, &env.server, "hello\n", 12345, 0, 6, "olleh\n");
    try expectDataRecieve(&client, &env.server, "Hello, world!\n", 12345, 6, 20, "!dlrow ,olleH\n");
    try expectCloseMessage(&client, &env.server, 12345);
}

fn expectConnectMessage(client: *Client, server: *Server, session_id: u32) !void {
    const msg = try std.fmt.allocPrint(testing.allocator, "/CONNECT/{d}/", .{session_id});
    defer testing.allocator.free(msg);
    try client.send(server.udp_socket.?.address, msg);
    const connect_ack = try client.recieve(testing.allocator);
    defer connect_ack.deinit(testing.allocator);
    try testing.expectEqual(session_id, connect_ack.ack.session);
    try testing.expectEqual(@as(u32, 0), connect_ack.ack.length);
}

fn expectDataRecieve(
    client: *Client,
    server: *Server,
    message: []const u8,
    session_id: u32,
    first_pos: u32,
    ack_len: u32,
    reversed: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(
        testing.allocator,
        "/DATA/{d}/{d}/{s}/",
        .{ session_id, first_pos, message },
    );
    defer testing.allocator.free(msg);

    try client.send(server.udp_socket.?.address, msg);
    const first_a = try client.recieve(testing.allocator);
    defer first_a.deinit(testing.allocator);
    const first_b = try client.recieve(testing.allocator);
    defer first_b.deinit(testing.allocator);

    if (std.meta.activeTag(first_a) == .ack) {
        try testing.expectEqual(session_id, first_a.ack.session);
        try testing.expectEqual(ack_len, first_a.ack.length);
        try testing.expectEqual(session_id, first_b.data.session);
        try testing.expectEqual(first_pos, first_b.data.pos);
        try testing.expectEqualStrings(reversed, first_b.data.data);
    } else {
        try testing.expectEqual(session_id, first_a.data.session);
        try testing.expectEqual(first_pos, first_a.data.pos);
        try testing.expectEqualStrings(reversed, first_a.data.data);
        try testing.expectEqual(session_id, first_b.ack.session);
        try testing.expectEqual(ack_len, first_b.ack.length);
    }
}

fn expectCloseMessage(client: *Client, server: *Server, session_id: u32) !void {
    const msg = try std.fmt.allocPrint(testing.allocator, "/CLOSE/{d}/", .{session_id});
    defer testing.allocator.free(msg);

    try client.send(server.udp_socket.?.address, msg);
    const close_msg = try client.recieve(testing.allocator);
    defer close_msg.deinit(testing.allocator);
    try testing.expectEqual(session_id, close_msg.close.session);
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
