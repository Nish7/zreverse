threaded: Io.Threaded,
server: Server,

pub fn init() !TestEnv {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{
        .concurrent_limit = .unlimited,
    });

    const addr = try net.IpAddress.parse("127.0.0.1", 0);
    var server = server_mod.ReverseServer.init(.{
        .allocator = std.testing.allocator,
        .io = threaded.io(), // @TODO: This may be problem with the lifetime of io.
        .listener_addr = addr,
    });
    try server.bind();

    return .{
        .threaded = threaded,
        .server = server,
    };
}

pub fn deinit(env: *TestEnv) void {
    env.server.deinit();
    env.threaded.deinit();
}

pub fn startServer(env: *TestEnv) !Io.Future(@typeInfo(@TypeOf(Server.serve)).@"fn".return_type.?) {
    return try env.threaded.io().concurrent(Server.serve, .{&env.server});
}

pub fn stopServer(env: *TestEnv, future: *Io.Future(@typeInfo(@TypeOf(Server.serve)).@"fn".return_type.?)) void {
    future.cancel(env.threaded.io()) catch {};
    future.await(env.threaded.io()) catch |err| switch (err) {
        error.Canceled => {},
        else => @panic(@errorName(err)),
    };
}

pub fn expectConnectMessage(client: *Client, server: *Server, session_id: u32) !void {
    const msg = try std.fmt.allocPrint(testing.allocator, "/CONNECT/{d}/", .{session_id});
    defer testing.allocator.free(msg);
    try client.send(server.udp_socket.?.address, msg);
    const connect_ack = try client.recieve();
    defer connect_ack.deinit(testing.allocator);
    try testing.expectEqual(session_id, connect_ack.ack.session);
    try testing.expectEqual(@as(u32, 0), connect_ack.ack.length);
}

pub fn expectDataRecieve(
    client: *Client,
    server: *Server,
    message: []const u8,
    session_id: u32,
    first_pos: u32,
    ack_len: u32,
    reversed: ?[]const u8,
) !void {
    try client.sendMessage(server.udp_socket.?.address, .{ .data = .{
        .session = session_id,
        .pos = first_pos,
        .data = message,
    } });

    const first_a = try client.recieve();
    defer first_a.deinit(testing.allocator);

    if (reversed == null) {
        try testing.expectEqual(.ack, std.meta.activeTag(first_a));
        try testing.expectEqual(session_id, first_a.ack.session);
        try testing.expectEqual(ack_len, first_a.ack.length);
        return;
    }

    const first_b = try client.recieve();
    defer first_b.deinit(testing.allocator);

    const expected_data = reversed.?;
    if (std.meta.activeTag(first_a) == .ack) {
        try testing.expectEqual(session_id, first_a.ack.session);
        try testing.expectEqual(ack_len, first_a.ack.length);
        try testing.expectEqual(session_id, first_b.data.session);
        try testing.expectEqual(first_pos, first_b.data.pos);
        try testing.expectEqualStrings(expected_data, first_b.data.data);
    } else {
        try testing.expectEqual(session_id, first_a.data.session);
        try testing.expectEqual(first_pos, first_a.data.pos);
        try testing.expectEqualStrings(expected_data, first_a.data.data);
        try testing.expectEqual(session_id, first_b.ack.session);
        try testing.expectEqual(ack_len, first_b.ack.length);
    }
}

pub fn expectCloseMessage(client: *Client, server: *Server, session_id: u32) !void {
    try client.sendMessage(server.udp_socket.?.address, .{ .close = .{ .session = session_id } });
    const close_msg = try client.recieve();
    defer close_msg.deinit(testing.allocator);
    try testing.expectEqual(session_id, close_msg.close.session);
}

pub const TestEnv = @This();

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const net = std.Io.net;
const server_mod = @import("server.zig");
const Server = server_mod.ReverseServer;
const Client = @import("client.zig").Client;
