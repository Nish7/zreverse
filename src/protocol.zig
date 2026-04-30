pub const MessageType = enum { connect, data, ack, close };

pub const ConnectMsg = struct {
    session: u32,
};

pub const DataMsg = struct {
    session: u32,
    pos: u32,
    data: []const u8,
};

pub const AckMsg = struct {
    session: u32,
    length: u32,
};

pub const CloseMsg = struct {
    session: u32,
};

pub const Message = union(MessageType) {
    connect: ConnectMsg,
    data: DataMsg,
    ack: AckMsg,
    close: CloseMsg,

    pub fn getSessionId(msg: Message) u32 {
        return switch (msg) {
            .connect => |m| m.session,
            .data => |m| m.session,
            .ack => |m| m.session,
            .close => |m| m.session,
        };
    }

    pub fn deinit(msg: Message, allocator: std.mem.Allocator) void {
        switch (msg) {
            .data => |m| allocator.free(m.data),
            else => {},
        }
    }

    pub fn parseMessage(allocator: std.mem.Allocator, input: []const u8) !Message {
        if (input.len < 2) return error.InvalidMessage;
        if (input[0] != '/' or input[input.len - 1] != '/') return error.InvalidMessage;

        const body = input[1 .. input.len - 1];
        var it = std.mem.splitScalar(u8, body, '/');
        const msg_type = it.next() orelse return error.InvalidMessage;

        // /CONNECT/SESSION/
        if (std.mem.eql(u8, msg_type, "CONNECT")) {
            const session = it.next() orelse return error.InvalidMessage;
            if (it.next() != null) return error.InvalidMessage;
            const session_id = try std.fmt.parseInt(u32, session, 10);
            return Message{ .connect = .{ .session = session_id } };
        }

        // /ACK/SESSION/LENGTH/
        if (std.mem.eql(u8, msg_type, "ACK")) {
            const session = it.next() orelse return error.InvalidMessage;
            const length = it.next() orelse return error.InvalidMessage;
            if (it.next() != null) return error.InvalidMessage;
            const session_id = try std.fmt.parseInt(u32, session, 10);
            const ack_len = try std.fmt.parseInt(u32, length, 10);
            return Message{ .ack = .{ .session = session_id, .length = ack_len } };
        }

        // /DATA/SESSION/POS/DATA/
        if (std.mem.eql(u8, msg_type, "DATA")) {
            const session = it.next() orelse return error.InvalidMessage;
            const pos = it.next() orelse return error.InvalidMessage;
            const escaped_data = it.next() orelse return error.InvalidMessage;
            if (it.next() != null) return error.InvalidMessage;
            const session_id = try std.fmt.parseInt(u32, session, 10);
            const data_pos = try std.fmt.parseInt(u32, pos, 10);
            const data = try unescapeData(allocator, escaped_data);
            return Message{ .data = .{ .session = session_id, .pos = data_pos, .data = data } };
        }

        // /CLOSE/SESSION/
        if (std.mem.eql(u8, msg_type, "CLOSE")) {
            const session = it.next() orelse return error.InvalidMessage;
            if (it.next() != null) return error.InvalidMessage;
            const session_id = try std.fmt.parseInt(u32, session, 10);
            return Message{ .close = .{ .session = session_id } };
        }

        return error.InvalidMessage;
    }

    pub fn unescapeData(allocator: std.mem.Allocator, payload: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        while (i < payload.len) : (i += 1) {
            if (payload[i] == '\\' and i + 1 < payload.len) {
                const next = payload[i + 1];
                if (next == '\\' or next == '/') {
                    try out.append(allocator, next);
                    i += 1;
                    continue;
                }
            }

            try out.append(allocator, payload[i]);
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn getPayload(msg: Message, allocator: std.mem.Allocator) ![]const u8 {
        // @TODO: i can switch to fixed buffer, instead of heap allocator..
        return switch (msg) {
            .connect => |m| try std.fmt.allocPrint(allocator, "/CONNECT/{d}/", .{m.session}),
            .data => |m| try std.fmt.allocPrint(
                allocator,
                "/DATA/{d}/{d}/{s}/",
                .{ m.session, m.pos, m.data },
            ),
            .ack => |m| try std.fmt.allocPrint(allocator, "/ACK/{d}/{d}/", .{ m.session, m.length }),
            .close => |m| try std.fmt.allocPrint(allocator, "/CLOSE/{d}/", .{m.session}),
        };
    }
};

test "parse valid message types" {
    const cases = [_]struct {
        input: []const u8,
        want_tag: MessageType,
    }{
        .{ .input = "/CONNECT/42/", .want_tag = .connect },
        .{ .input = "/ACK/42/12/", .want_tag = .ack },
        .{ .input = "/CLOSE/42/", .want_tag = .close },
        .{ .input = "/DATA/32/1/hello, world\n/", .want_tag = .data },
    };

    for (cases) |c| {
        const msg = try Message.parseMessage(testing.allocator, c.input);
        defer msg.deinit(testing.allocator);
        try testing.expectEqual(std.meta.activeTag(msg), c.want_tag);
    }
}

test "parse valid connect message" {
    const cases = [_]struct {
        input: []const u8,
        sessionId: ?u32,
    }{
        .{ .input = "/CONNECT/42/", .sessionId = 42 },
        .{ .input = "/CONNECT/0/", .sessionId = 0 },
        .{ .input = "/CONNECT/10000/", .sessionId = 10000 },
        .{ .input = "/CONNECT/239049929/", .sessionId = 239049929 },
        .{ .input = "/CONNECT/-1/", .sessionId = null },
    };

    for (cases) |c| {
        if (c.sessionId) |sid| {
            const msg = try Message.parseMessage(testing.allocator, c.input);
            try testing.expectEqual(sid, msg.connect.session);
        } else {
            try testing.expectError(error.Overflow, Message.parseMessage(testing.allocator, c.input));
        }
    }
}

test "parse valid ack message" {
    const cases = [_]struct {
        input: []const u8,
        sessionId: u32,
        length: u32,
    }{
        .{ .input = "/ACK/42/2/", .sessionId = 42, .length = 2 },
        .{ .input = "/ACK/0/1/", .sessionId = 0, .length = 1 },
    };

    for (cases) |c| {
        const msg = try Message.parseMessage(testing.allocator, c.input);
        defer msg.deinit(testing.allocator);
        try testing.expectEqual(c.sessionId, msg.ack.session);
        try testing.expectEqual(c.length, msg.ack.length);
    }
}

test "parse valid close message" {
    const cases = [_]struct {
        input: []const u8,
        sessionId: u32,
    }{
        .{ .input = "/CLOSE/12/", .sessionId = 12 },
        .{ .input = "/CLOSE/0/", .sessionId = 0 },
    };

    for (cases) |c| {
        const msg = try Message.parseMessage(testing.allocator, c.input);
        try testing.expectEqual(c.sessionId, msg.close.session);
    }
}

test "parse valid data message" {
    const cases = [_]struct {
        input: []const u8,
        sessionId: u32,
        pos: u32,
        data: []const u8,
    }{
        .{ .input = "/DATA/42/1/Hello, world\n/", .sessionId = 42, .pos = 1, .data = "Hello, world\n" },
    };

    for (cases) |c| {
        const msg = try Message.parseMessage(testing.allocator, c.input);
        defer msg.deinit(testing.allocator);
        try testing.expectEqual(c.sessionId, msg.data.session);
        try testing.expectEqual(c.pos, msg.data.pos);
        try testing.expectEqualStrings(c.data, msg.data.data);
    }
}

test "unescape data payload" {
    var payload = [_]u8{ 'f', 'o', 'o', '\\', '/', 'b', 'a', 'r', '\\', '\\', 'b', 'a', 'z' };
    const unescaped = try Message.unescapeData(testing.allocator, payload[0..]);
    defer testing.allocator.free(unescaped);
    try testing.expectEqualStrings("foo/bar\\baz", unescaped);
}

test "parse invalid message returns error" {
    try testing.expectError(error.InvalidMessage, Message.parseMessage(testing.allocator, ""));
    try testing.expectError(error.InvalidMessage, Message.parseMessage(testing.allocator, "BOGUS"));
    try testing.expectError(error.InvalidMessage, Message.parseMessage(testing.allocator, "CONNECT/42/"));
    try testing.expectError(error.InvalidMessage, Message.parseMessage(testing.allocator, "/CONNECT/42"));
    try testing.expectError(error.InvalidMessage, Message.parseMessage(testing.allocator, "/CLOSE/12/extra/"));
    try testing.expectError(error.InvalidMessage, Message.parseMessage(testing.allocator, "/DATA/1/2/hello/extra/"));
}

const std = @import("std");
const testing = std.testing;
