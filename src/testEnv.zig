threaded: Io.Threaded,
server: Server,

pub fn init() !TestEnv {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{
        .concurrent_limit = .unlimited,
    });

    const addr = try net.IpAddress.parse("127.0.0.1", 0);
    var server = server_mod.ReverseServer.init(.{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
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

pub const TestEnv = @This();

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const server_mod = @import("server.zig");
const Server = server_mod.ReverseServer;
