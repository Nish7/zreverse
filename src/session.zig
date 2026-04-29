io: Io,
allocator: std.mem.Allocator,
session_id: u32,
from: net.IpAddress,
current_line: std.ArrayList(u8),
recived_len: u32 = 0,

pub fn init(io: Io, allocator: Allocator, session_id: u32, from: net.IpAddress) Session {
    return .{ .io = io, .allocator = allocator, .session_id = session_id, .from = from, .current_line = .empty };
}

pub fn deinit(s: *Session) void {
    s.current_line.deinit(s.allocator);
}

pub fn handleIncoming(session: *Session, message: Message) !Responses {
    var res = Responses{};
    switch (message) {
        .connect => |m| {
            std.log.debug("Connection Message Recieved Session Id: {d}", .{m.session});
            try res.push(.{ .ack = .{ .session = m.session, .length = 0 } });
        },
        .data => |m| {
            std.log.debug("Data Message Recieved Session Id: {d}", .{m.session});
            if (m.pos != session.recived_len) return error.NotRecieved;

            try session.current_line.appendSlice(session.allocator, m.data);
            session.recived_len += @intCast(m.data.len);

            if (std.mem.findScalar(u8, session.current_line.items, '\n')) |idx| {
                const reversed = try session.allocator.dupe(u8, session.current_line.items[0..idx + 1]);
                std.mem.reverse(u8, reversed[0..idx]);
                session.current_line.replaceRangeAssumeCapacity(0, idx + 1, "");

                try res.push(.{ .data = .{ .session = m.session, .pos = m.pos, .data = reversed } });
            }

            try res.push(.{ .ack = .{ .session = m.session, .length = session.recived_len } });
        },
        else => @panic("unhandled message types"),
    }
    return res;
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
