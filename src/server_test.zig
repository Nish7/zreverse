test "smoke connect test: expected ack with 0 length" {
    var env = try TestEnv.init();
    defer env.deinit();

    const io = env.threaded.io();

    var client = try Client.init(io, testing.allocator);
    defer client.deinit();

    var recv_future = try io.concurrent(Server.serve, .{&env.server});
    defer recv_future.await(io) catch {};
    defer recv_future.cancel(io) catch {};

    try client.send(env.server.udp_socket.?.address, "/connect/42/");
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

    var a_connect_fut = try io.concurrent(Client.send, .{ &client_a, env.server.udp_socket.?.address, "/connect/1/" });
    var b_connect_fut = try io.concurrent(Client.send, .{ &client_b, env.server.udp_socket.?.address, "/connect/2/" });
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
    try client.sendMessage(env.server.udp_socket.?.address, .{
        .data = .{
            .session = 12345,
            .pos = 5,
            .data = "world!\n",
        },
    });

    const first_reply = try client.recieve();
    defer first_reply.deinit(testing.allocator);
    const second_reply = try client.recieve();
    defer second_reply.deinit(testing.allocator);

    if (std.meta.activeTag(first_reply) == .ack) {
        try testing.expectEqual(@as(u32, 12345), first_reply.ack.session);
        try testing.expectEqual(@as(u32, 12), first_reply.ack.length);
        try testing.expectEqual(@as(u32, 12345), second_reply.data.session);
        try testing.expectEqual(@as(u32, 0), second_reply.data.pos);
        try testing.expectEqualStrings("!dlrowolleh\n", second_reply.data.data);
    } else {
        try testing.expectEqual(@as(u32, 12345), first_reply.data.session);
        try testing.expectEqual(@as(u32, 0), first_reply.data.pos);
        try testing.expectEqualStrings("!dlrowolleh\n", first_reply.data.data);
        try testing.expectEqual(@as(u32, 12345), second_reply.ack.session);
        try testing.expectEqual(@as(u32, 12), second_reply.ack.length);
    }
    try testutils.expectCloseMessage(&client, &env.server, 12345);
}

test "single data payload with multiple newlines emits multiple reversed data replies" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client = try Client.init(io, testing.allocator);
    defer client.deinit();

    var serv_future = try env.startServer();
    defer env.stopServer(&serv_future);

    const session_id: u32 = 3333;
    const payload = "hello\nworld\n";

    try testutils.expectConnectMessage(&client, &env.server, session_id);
    try client.sendMessage(env.server.udp_socket.?.address, .{
        .data = .{
            .session = session_id,
            .pos = 0,
            .data = payload,
        },
    });

    const first_reply = try client.recieve();
    defer first_reply.deinit(testing.allocator);
    const second_reply = try client.recieve();
    defer second_reply.deinit(testing.allocator);
    const third_reply = try client.recieve();
    defer third_reply.deinit(testing.allocator);

    const replies = [_]Message{ first_reply, second_reply, third_reply };
    var saw_ack = false;
    var saw_pos_0 = false;
    var saw_pos_6 = false;

    for (replies) |reply| {
        switch (reply) {
            .ack => |a| {
                try testing.expectEqual(session_id, a.session);
                try testing.expectEqual(@as(u32, payload.len), a.length);
                saw_ack = true;
            },
            .data => |d| {
                try testing.expectEqual(session_id, d.session);
                if (d.pos == 0) {
                    try testing.expectEqualStrings("olleh\n", d.data);
                    saw_pos_0 = true;
                } else if (d.pos == 6) {
                    try testing.expectEqualStrings("dlrow\n", d.data);
                    saw_pos_6 = true;
                } else {
                    try testing.expect(false);
                }
            },
            else => try testing.expect(false),
        }
    }

    try testing.expect(saw_ack);
    try testing.expect(saw_pos_0);
    try testing.expect(saw_pos_6);

    try client.sendMessage(env.server.udp_socket.?.address, .{
        .ack = .{
            .session = session_id,
            .length = 6,
        },
    });

    try client.sendMessage(env.server.udp_socket.?.address, .{
        .ack = .{
            .session = session_id,
            .length = 12,
        },
    });

    try std.Io.sleep(io, .fromMilliseconds(60), .boot);
    try testing.expectEqual(@as(usize, 0), env.server.sessions.getPtr(session_id).?.pending_messages.items.len);
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

test "long reversed line is split across multiple data messages" {
    var env = try TestEnv.init();
    defer env.deinit();
    const io = env.threaded.io();

    var client = try Client.init(io, testing.allocator);
    defer client.deinit();

    var serv_future = try env.startServer();
    defer env.stopServer(&serv_future);

    const session_id: u32 = 560;
    try testutils.expectConnectMessage(&client, &env.server, session_id);

    var line: [1201]u8 = undefined;
    @memset(line[0..1200], 'a');
    line[1200] = '\n';

    try client.sendMessage(env.server.udp_socket.?.address, .{
        .data = .{
            .session = session_id,
            .pos = 0,
            .data = line[0..800],
        },
    });

    const first_ack = try client.recieve();
    defer first_ack.deinit(testing.allocator);
    try testing.expectEqual(.ack, std.meta.activeTag(first_ack));
    try testing.expectEqual(@as(u32, session_id), first_ack.ack.session);
    try testing.expectEqual(@as(u32, 800), first_ack.ack.length);

    try client.sendMessage(env.server.udp_socket.?.address, .{
        .data = .{
            .session = session_id,
            .pos = 800,
            .data = line[800..],
        },
    });

    const first_reply = try client.recieve();
    defer first_reply.deinit(testing.allocator);
    const second_reply = try client.recieve();
    defer second_reply.deinit(testing.allocator);
    const third_reply = try client.recieve();
    defer third_reply.deinit(testing.allocator);

    const replies = [_]Message{ first_reply, second_reply, third_reply };
    var ack_seen = false;
    var data_total: usize = 0;
    var next_pos: u32 = 0;
    var data_packets: usize = 0;

    for (replies) |reply| {
        switch (reply) {
            .ack => |a| {
                try testing.expectEqual(session_id, a.session);
                try testing.expectEqual(@as(u32, line.len), a.length);
                ack_seen = true;
            },
            .data => |d| {
                try testing.expectEqual(session_id, d.session);
                try testing.expectEqual(next_pos, d.pos);
                try testing.expect(d.data.len < 1000);
                next_pos += @as(u32, @intCast(d.data.len));
                data_total += d.data.len;
                data_packets += 1;
            },
            else => try testing.expect(false),
        }
    }

    try testing.expect(ack_seen);
    try testing.expectEqual(@as(usize, 2), data_packets);
    try testing.expectEqual(line.len, data_total);
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
const protocol = @import("../src/protocol.zig");
const testing = std.testing;
const Client = client_mod.Client;
const Message = protocol.Message;
const Server = server_mod.ReverseServer;
const Io = std.Io;
const net = Io.net;

const testutils = @import("testEnv.zig");
const TestEnv = testutils.TestEnv;
