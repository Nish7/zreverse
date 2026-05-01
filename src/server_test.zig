test "smoke connect test: expected ack with 0 length" {
    var env = try TestEnv.init();
    defer env.deinit();

    const io = env.threaded.io();

    var client = try Client.init(io, testing.allocator);
    defer client.deinit();

    var recv_future = try io.concurrent(Server.serve, .{&env.server});
    defer recv_future.await(io) catch {};
    defer recv_future.cancel(io) catch {};

    try client.send(env.server.udp_socket.?.address, "/CONNECT/42/");
    const recieved_message = try client.recieve();

    try testing.expectEqual(@as(u32, 0), recieved_message.ack.length);
    try testing.expectEqual(@as(u32, 42), recieved_message.ack.session);
}

test "basic session management test" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client_a = try Client.init(io, testing.allocator);
    var client_b = try Client.init(io, testing.allocator);
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

test "data message: ack and reverse reply" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client = try Client.init(io, testing.allocator);
    defer client.deinit();

    var serv_future = try env.startServer();
    defer env.stopServer(&serv_future);

    try testutils.expectConnectMessage(&client, &env.server, 12345);
    try testutils.expectDataRecieve(&client, &env.server, "hello\n", 12345, 0, 6, "olleh\n");
    try testutils.expectDataRecieve(&client, &env.server, "Hello, world!\n", 12345, 6, 20, "!dlrow ,olleH\n");
    try testutils.expectCloseMessage(&client, &env.server, 12345);
}

test "single line - mulitple data payload" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client = try Client.init(io, testing.allocator);
    defer client.deinit();

    var serv_future = try env.startServer();
    defer env.stopServer(&serv_future);

    try testutils.expectConnectMessage(&client, &env.server, 12345);
    try testutils.expectDataRecieve(&client, &env.server, "hello", 12345, 0, 5, null);
    try testutils.expectDataRecieve(&client, &env.server, "world!\n", 12345, 5, 12, "!dlrowolleh\n");
    try testutils.expectCloseMessage(&client, &env.server, 12345);
}

test "ack length beyond sent payload closes session" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client = try Client.init(io, testing.allocator);
    defer client.deinit();

    var serv_future = try env.startServer();
    defer env.stopServer(&serv_future);

    const session_id: u32 = 555;
    try testutils.expectConnectMessage(&client, &env.server, session_id);

    // pending_len starts at 0, so ACK length 1 is invalid and should close the session.
    try client.sendMessage(env.server.udp_socket.?.address, .{
        .ack = .{
            .session = session_id,
            .length = 1,
        },
    });

    const reply = try client.recieve();
    defer reply.deinit(testing.allocator);
    try testing.expectEqual(.close, std.meta.activeTag(reply));
    try testing.expectEqual(session_id, reply.close.session);
}

test "ack on closed session replies with close" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client = try Client.init(io, testing.allocator);
    defer client.deinit();

    var serv_future = try env.startServer();
    defer env.stopServer(&serv_future);

    const session_id: u32 = 556;
    try testutils.expectConnectMessage(&client, &env.server, session_id);
    try testutils.expectCloseMessage(&client, &env.server, session_id);

    try client.sendMessage(env.server.udp_socket.?.address, .{
        .ack = .{
            .session = session_id,
            .length = 0,
        },
    });

    const reply = try client.recieve();
    defer reply.deinit(testing.allocator);
    try testing.expectEqual(.close, std.meta.activeTag(reply));
    try testing.expectEqual(session_id, reply.close.session);
}

test "ack smaller than sent retransmits suffix" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client = try Client.init(io, testing.allocator);
    defer client.deinit();

    var serv_future = try env.startServer();
    defer env.stopServer(&serv_future);

    const session_id: u32 = 557;
    try testutils.expectConnectMessage(&client, &env.server, session_id);
    try testutils.expectDataRecieve(&client, &env.server, "hello\n", session_id, 0, 6, "olleh\n");

    try client.sendMessage(env.server.udp_socket.?.address, .{
        .ack = .{
            .session = session_id,
            .length = 3,
        },
    });

    const reply = try client.recieve();
    defer reply.deinit(testing.allocator);
    try testing.expectEqual(.data, std.meta.activeTag(reply));
    try testing.expectEqual(session_id, reply.data.session);
    try testing.expectEqual(@as(u32, 3), reply.data.pos);
    try testing.expectEqualStrings("eh\n", reply.data.data);
}

test "duplicate ack does not close session" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client = try Client.init(io, testing.allocator);
    defer client.deinit();

    var serv_future = try env.startServer();
    defer env.stopServer(&serv_future);

    const session_id: u32 = 558;
    try testutils.expectConnectMessage(&client, &env.server, session_id);
    try testutils.expectDataRecieve(&client, &env.server, "hello\n", session_id, 0, 6, "olleh\n");

    try client.sendMessage(env.server.udp_socket.?.address, .{
        .ack = .{
            .session = session_id,
            .length = 3,
        },
    });
    const retransmit = try client.recieve();
    defer retransmit.deinit(testing.allocator);
    try testing.expectEqual(.data, std.meta.activeTag(retransmit));

    // Duplicate/delayed ACK should be ignored and keep session alive.
    try client.sendMessage(env.server.udp_socket.?.address, .{
        .ack = .{
            .session = session_id,
            .length = 3,
        },
    });
    try std.Io.sleep(io, .fromMilliseconds(60), .boot);
    try testing.expect(env.server.sessions.contains(session_id));
}

test "retransmit pending message after retransmission timeout" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client = try Client.init(io, testing.allocator);
    defer client.deinit();

    var serv_future = try env.startServer();
    defer env.stopServer(&serv_future);

    const session_id: u32 = 559;
    try testutils.expectConnectMessage(&client, &env.server, session_id);
    try testutils.expectDataRecieve(&client, &env.server, "hello\n", session_id, 0, 6, "olleh\n");

    const s = env.server.sessions.getPtr(session_id).?;
    try testing.expect(s.pending_messages.items.len > 0);
    s.pending_messages.items[0].timeout = Io.Clock.Timestamp.now(io, .boot);

    // Let serve() run one receive-timeout tick and retransmit expired pending message.
    try std.Io.sleep(io, .fromMilliseconds(120), .boot);

    const retransmit = try client.recieve();
    defer retransmit.deinit(testing.allocator);
    try testing.expectEqual(.data, std.meta.activeTag(retransmit));
    try testing.expectEqual(session_id, retransmit.data.session);
    try testing.expectEqual(@as(u32, 0), retransmit.data.pos);
    try testing.expectEqualStrings("olleh\n", retransmit.data.data);
}

test "session expiry removes only timed out session" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client_a = try Client.init(io, testing.allocator);
    var client_b = try Client.init(io, testing.allocator);
    defer client_a.deinit();
    defer client_b.deinit();

    var serv_future = try env.startServer();
    defer env.stopServer(&serv_future);

    try testutils.expectConnectMessage(&client_a, &env.server, 101);
    try testutils.expectConnectMessage(&client_b, &env.server, 202);
    try testing.expect(env.server.sessions.contains(101));
    try testing.expect(env.server.sessions.contains(202));

    const expiring = env.server.sessions.getPtr(101).?;
    expiring.session_expiry_timeout = Io.Clock.Timestamp.now(io, .boot);
    try std.Io.sleep(io, .fromMilliseconds(120), .boot);

    try testing.expect(!env.server.sessions.contains(101));
    try testing.expect(env.server.sessions.contains(202));
}


const std = @import("std");
const server_mod = @import("../src/server.zig");
const client_mod = @import("../src/client.zig");
const testing = std.testing;
const Client = client_mod.Client;
const Server = server_mod.ReverseServer;
const Io = std.Io;
const net = Io.net;

const testutils = @import("testEnv.zig");
const TestEnv = testutils.TestEnv;
