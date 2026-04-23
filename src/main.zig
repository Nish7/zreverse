const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Server = @import("./server.zig").ReverseServer;

pub fn main(init: std.process.Init) !void {
    var threaded: Io.Threaded = .init(std.heap.smp_allocator, .{
        .concurrent_limit = .limited(4),
    });
    defer threaded.deinit();
    const io = threaded.io();
    
    const allocator = init.gpa;

    const addr = try net.IpAddress.parse("127.0.0.1", 3001);
    var server = Server.init(.{
        .allocator = allocator,
        .io = io,
        .listener_addr = addr,
    });
    defer server.deinit();
    
    try server.start();
}
