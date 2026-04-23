threaded: Io.Threaded,
io: Io,
client: Client,
server: Server,

pub fn deinit(ctx: *TestCtx) void {
    ctx.client.deinit();
    ctx.server.deinit();
    ctx.threaded.deinit();
}

pub fn init() !TestCtx {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{
        .concurrent_limit = .limited(4),
    });
    const io = threaded.io();

    const addr = try net.IpAddress.parse("127.0.0.1", 0);
    var server = server_mod.ReverseServer.init(.{
        .allocator = std.testing.allocator,
        .io = io,
        .listener_addr = addr,
    });
    try server.bind();

    const client = try Client.init(io);

    return .{
        .threaded = threaded,
        .io = io,
        .client = client,
        .server = server,
    };
}

pub const TestCtx = @This();

const std = @import("std");
const server_mod = @import("../src/server.zig");
const client_mod = @import("../src/client.zig");
const testing = std.testing;
const Client = client_mod.Client;
const Server = server_mod.ReverseServer;
const Io = std.Io;
const net = Io.net;
