io: Io,
allocator: std.mem.Allocator,
session_id: u32,
from: net.IpAddress,

pub fn init(io: Io, allocator: Allocator, session_id: u32, from: net.IpAddress) Session {
    return .{ .io = io, .allocator = allocator, .session_id = session_id, .from = from };
}

pub fn deinit(_: *Session) void {
    // @TODO
    return;
}

pub fn handleIncoming(_: *Session, message: Message) !?Message {
    switch (message) {
        .connect => |m| {
            std.log.debug("Connection Message Recieved Session Id: {d}", .{m.session});
            return .{ .ack = .{ .session = m.session, .length = 0 } };
        },
        else => @panic("unhandled message types"),
    }
}


pub const Session = @This();
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const IpAddress = net.IpAddress;
const Allocator = std.mem.Allocator;
const log = std.log;

const protocol = @import("protocol.zig");
const Message = protocol.Message;
