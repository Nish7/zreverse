io: Io,
allocator: std.mem.Allocator,
session_id: u32,
from: net.IpAddress,
current_line: std.ArrayList(u8),
recived_len: u32 = 0,
sent_len: u32 = 0,
acked_len: u32 = 0,
closed: bool = true,
session_expiry_timeout: Io.Clock.Timestamp,
pending_messages: std.ArrayList(PendingMessage),

pub const PendingMessage = struct { timeout: Io.Clock.Timestamp, message: Message };

const RETRASMISSION_TIMEOUT: Io.Clock.Duration = .{
    .raw = Io.Duration.fromSeconds(3),
    .clock = .boot,
};

const SESSION_EXPIRY_TIMEOUT: Io.Clock.Duration = .{
    .raw = Io.Duration.fromSeconds(60),
    .clock = .boot,
};

pub fn init(io: Io, allocator: Allocator, session_id: u32, from: net.IpAddress) Session {
    return .{ .io = io, .allocator = allocator, .session_id = session_id, .from = from, .current_line = .empty, .session_expiry_timeout = Io.Clock.Timestamp.fromNow(io, SESSION_EXPIRY_TIMEOUT), .pending_messages = .empty };
}

pub fn deinit(s: *Session) void {
    s.current_line.deinit(s.allocator);

    for (s.pending_messages.items) |pm| {
        pm.message.deinit(s.allocator);
    }
    s.pending_messages.deinit(s.allocator);
}

pub fn updateSessionExpiryTimeout(s: *Session) void {
    s.session_expiry_timeout = Io.Clock.Timestamp.fromNow(s.io, SESSION_EXPIRY_TIMEOUT);
}

pub fn takeExpiredPendingMessages(s: *Session, out: *std.ArrayList(Message)) !void {
    const now = Io.Clock.Timestamp.now(s.io, .boot);
    for (s.pending_messages.items) |*pm| {
        if (now.compare(.gte, pm.timeout)) {
            try out.append(s.allocator, pm.message);
            pm.timeout = Io.Clock.Timestamp.fromNow(s.io, RETRASMISSION_TIMEOUT);
        }
    }
}

fn queuePendingMessage(s: *Session, msg: Message) !void {
    s.sent_len += @intCast(msg.data.data.len);
    try s.pending_messages.append(s.allocator, .{
        .message = msg,
        .timeout = Io.Clock.Timestamp.fromNow(s.io, RETRASMISSION_TIMEOUT),
    });
}

fn getData(s: *Session, data_msg: protocol.DataMsg) !Message {
    // @TODO: handle multiple send if necessary
    const dup = try s.allocator.dupe(u8, data_msg.data);
    return .{ .data = .{
        .session = data_msg.session,
        .pos = data_msg.pos,
        .data = dup,
    } };
}

pub fn handleIncoming(session: *Session, message: Message) !Responses {
    session.updateSessionExpiryTimeout();
    sessionLog(session, .debug, "incoming={f}", .{message});
    var res = Responses{};
    switch (message) {
        .connect => |m| try session.handleConnect(m, &res),
        .data => |m| try session.handleData(m, &res),
        .close => |m| try session.handleClose(m, &res),
        .ack => |m| try session.handleAck(m, &res),
    }
    return res;
}

fn dropPendingMessageTillPos(session: *Session, tillPos: u32) void {
    var remove_count: usize = 0;
    for (session.pending_messages.items) |pm| {
        const d = pm.message.data;
        const fully_acked =  d.pos + @as(u32, @intCast(d.data.len)) <= tillPos;
        if (!fully_acked) break;
        remove_count += 1;
    }

    for (session.pending_messages.items[0..remove_count]) |pm| {
        pm.message.deinit(session.allocator);
    }

    if (remove_count > 0) {
        std.mem.copyForwards(
            PendingMessage,
            session.pending_messages.items[0 .. session.pending_messages.items.len - remove_count],
            session.pending_messages.items[remove_count..],
        );
        session.pending_messages.items.len -= remove_count;
    }
}

fn trimFirstPendingMessageToPos(session: *Session, tillPos: u32) !void {
    if (session.pending_messages.items.len == 0) return;

    const first_pending = &session.pending_messages.items[0];
    const d = first_pending.*.message.data;
    if (tillPos <= d.pos) return;

    const end_pos = d.pos + @as(u32, @intCast(d.data.len));
    if (tillPos >= end_pos) return;

    const offset: usize = @intCast(tillPos - d.pos);
    const suffix = try session.allocator.dupe(u8, d.data[offset..]);
    session.allocator.free(d.data);
    first_pending.message = .{ .data = .{
        .session = d.session,
        .pos = tillPos,
        .data = suffix,
    } };
}

pub fn checkSessionExpiry(session: *Session, now: Io.Clock.Timestamp) bool {
    return now.compare(.gte, session.session_expiry_timeout);
}

fn handleAck(session: *Session, msg: protocol.AckMsg, res: *Responses) !void {
    // If the SESSION is not open: send /CLOSE/SESSION/ and stop.
    if (session.closed) {
        sessionLog(session, .debug, "ack on closed; replying close", .{});
        try res.push(.{ .close = .{ .session = msg.session } });
        return;
    }

    // Duplicate/delayed ACK.
    if (msg.length <= session.acked_len) {
        sessionLog(session, .debug, "duplicate ack={d} last={d}", .{ msg.length, session.acked_len });
        return;
    }

    // Peer ACKed beyond total payload sent.
    if (msg.length > session.sent_len) {
        sessionLog(session, .debug, "invalid ack={d} pending={d}; closing", .{ msg.length, session.sent_len });
        session.closed = true;
        try res.push(.{ .close = .{ .session = msg.session } });
        return;
    }

    session.acked_len = msg.length;

    session.dropPendingMessageTillPos(msg.length);

    // Fully ACKed: no reply.
    if (msg.length == session.sent_len) {
        sessionLog(session, .debug, "fully acked at {d}", .{msg.length});
        return;
    }

    // Partial Ack-ing: pending_messages now contain only unacked payload.
    try session.trimFirstPendingMessageToPos(msg.length);
    for (session.pending_messages.items) |pm| {
        const d = pm.message.data;
        const retransmit = try getData(session, .{
            .session = d.session,
            .pos = d.pos,
            .data = d.data,
        });
        sessionLog(session, .debug, "retransmit pos={d} bytes={d}", .{ d.pos, retransmit.data.data.len });
        try res.push(retransmit);
    }
}

fn sessionLog(session: *const Session, comptime level: std.log.Level, comptime fmt: []const u8, args: anytype) void {
    switch (level) {
        .debug => log.debug("[sid={d}] " ++ fmt, .{session.session_id} ++ args),
        .info => log.info("[sid={d}] " ++ fmt, .{session.session_id} ++ args),
        .warn => log.warn("[sid={d}] " ++ fmt, .{session.session_id} ++ args),
        .err => log.err("[sid={d}] " ++ fmt, .{session.session_id} ++ args),
    }
}

fn handleConnect(session: *Session, msg: protocol.ConnectMsg, res: *Responses) !void {
    try res.push(.{ .ack = .{ .session = msg.session, .length = 0 } });
    session.closed = false;
}

fn handleData(session: *Session, msg: protocol.DataMsg, res: *Responses) !void {
    if (msg.pos > session.recived_len) {
        sessionLog(session, .debug, "missing inbound bytes have={d} got_pos={d}; sending duplicate ack", .{ session.recived_len, msg.pos });
        try res.push(.{ .ack = .{ .session = msg.session, .length = session.recived_len } });
        return;
    }

    if (msg.pos < session.recived_len) {
        sessionLog(session, .debug, "duplicate/overlapping data pos={d} have={d}; sending duplicate ack", .{ msg.pos, session.recived_len });
        try res.push(.{ .ack = .{ .session = msg.session, .length = session.recived_len } });
        return;
    }

    try session.current_line.appendSlice(session.allocator, msg.data);
    session.recived_len += @intCast(msg.data.len);

    var out_pos = session.sent_len;
    while (std.mem.findScalar(u8, session.current_line.items, '\n')) |idx| {
        const reversed = try session.allocator.dupe(u8, session.current_line.items[0 .. idx + 1]);
        std.mem.reverse(u8, reversed[0..idx]);
        session.current_line.replaceRangeAssumeCapacity(0, idx + 1, "");

        const message_payload: Message = .{
            .data = .{
                .session = msg.session,
                .pos = out_pos,
                .data = reversed,
            },
        };

        out_pos += @intCast(reversed.len);
        try session.queuePendingMessage(message_payload);
        try res.push(try getData(session, message_payload.data));
    }

    try res.push(.{ .ack = .{ .session = msg.session, .length = session.recived_len } });
}

fn handleClose(session: *Session, msg: protocol.CloseMsg, res: *Responses) !void {
    session.closed = true;
    try res.push(.{ .close = .{ .session = msg.session } });
}

// @TODO: Find a better way to handle multiple responses
const Responses = struct {
    items: [10]Message = undefined,
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
const log = std.log.scoped(.session);

const protocol = @import("protocol.zig");
const Message = protocol.Message;
const DataMsg = protocol.DataMsg;
