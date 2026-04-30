io: Io,
allocator: std.mem.Allocator,
session_id: u32,
from: net.IpAddress,
current_line: std.ArrayList(u8),
recived_len: u32 = 0,
closed: bool = false,
session_expiry_timeout: Io.Clock.Timestamp,

const SESSION_EXPIRY_TIMEOUT: Io.Clock.Duration = .{
    .raw = Io.Duration.fromSeconds(60),
    .clock = .boot,
};

pub fn init(io: Io, allocator: Allocator, session_id: u32, from: net.IpAddress) Session {
    return .{ .io = io, .allocator = allocator, .session_id = session_id, .from = from, .current_line = .empty, .session_expiry_timeout = Io.Clock.Timestamp.fromNow(io, SESSION_EXPIRY_TIMEOUT) };
}

pub fn deinit(s: *Session) void {
    s.current_line.deinit(s.allocator);
}

pub fn updateSessionExpiryTimeout(s: *Session) void {
    s.session_expiry_timeout = Io.Clock.Timestamp.fromNow(s.io, SESSION_EXPIRY_TIMEOUT);
}

pub fn handleIncoming(session: *Session, message: Message) !Responses {
    session.updateSessionExpiryTimeout();
    var res = Responses{};
    switch (message) {
        .connect => |m| try session.handleConnect(m, &res),
        .data => |m| try session.handleData(m, &res),
        .close => |m| try session.handleClose(m, &res),
        else => @panic("unhandled message types"),
    }
    return res;
}

fn handleConnect(session: *Session, msg: protocol.ConnectMsg, res: *Responses) !void {
    _ = session;
    std.log.debug("Connection Message Recieved Session Id: {d}", .{msg.session});
    try res.push(.{ .ack = .{ .session = msg.session, .length = 0 } });
}

fn handleData(session: *Session, msg: protocol.DataMsg, res: *Responses) !void {
    std.log.debug("Data Message Recieved Session Id: {d}", .{msg.session});
    if (msg.pos != session.recived_len) return error.NotRecieved;

    try session.current_line.appendSlice(session.allocator, msg.data);
    session.recived_len += @intCast(msg.data.len);

    if (std.mem.findScalar(u8, session.current_line.items, '\n')) |idx| {
        const reversed = try session.allocator.dupe(u8, session.current_line.items[0 .. idx + 1]);
        std.mem.reverse(u8, reversed[0..idx]);
        session.current_line.replaceRangeAssumeCapacity(0, idx + 1, "");

        try res.push(.{ .data = .{ .session = msg.session, .pos = msg.pos, .data = reversed } });
    }

    try res.push(.{ .ack = .{ .session = msg.session, .length = session.recived_len } });
}

fn handleClose(session: *Session, msg: protocol.CloseMsg, res: *Responses) !void {
    session.closed = true;
    try res.push(.{ .close = .{ .session = msg.session } });
}

// @TODO: Find a better way to handle multiple responses
const Responses = struct {
    items: [4]Message = undefined,
    len: usize = 0,

    pub fn push(self: *Responses, msg: Message) !void {
        if (self.len >= self.items.len) return error.TooManyResponses;
        self.items[self.len] = msg;
        self.len += 1;
    }

    pub fn slice(self: *const Responses) []const Message {
        return self.items[0..self.len];
    }
};

pub const Session = @This();
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const IpAddress = net.IpAddress;
const Allocator = std.mem.Allocator;
const log = std.log;

const protocol = @import("protocol.zig");
const Message = protocol.Message;
