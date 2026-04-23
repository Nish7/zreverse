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

    pub fn parseMessage(input: []const u8) !Message {
        // TODO: Add more advanced validation; like seperators (/)

        var it = std.mem.tokenizeScalar(u8, input, '/');
        _ = it.next(); // skip message type (connect, data, etc)

        // /CONNECT/SESSION/
        if (std.mem.startsWith(u8, input, "/CONNECT")) {
            const sessionId = try std.fmt.parseInt(u32, it.next().?, 10);
            return Message{ .connect = .{ .session = sessionId } };
        }

        // /ACK/SESSION/LENGTH/
        if (std.mem.startsWith(u8, input, "/ACK")) {
            const sessionId = try std.fmt.parseInt(u32, it.next().?, 10);
            const length = try std.fmt.parseInt(u32, it.next().?, 10);
            return Message{ .ack = .{ .session = sessionId, .length = length } };
        }

        // /DATA/SESSION/POS/DATA/
        if (std.mem.startsWith(u8, input, "/DATA")) {
            const sessionId = try std.fmt.parseInt(u32, it.next().?, 10);
            const pos = try std.fmt.parseInt(u32, it.next().?, 10);
            const data = it.next() orelse return error.InvalidMessage;
            return Message{ .data = .{ .session = sessionId, .pos = pos, .data = data } };
        }

        // /close/SESSION/
        if (std.mem.startsWith(u8, input, "/CLOSE")) {
            const sessionId = try std.fmt.parseInt(u32, it.next().?, 10);
            return Message{ .close = .{ .session = sessionId } };
        }

        return error.InvalidMessage;
    }

    pub fn getPayload(msg: Message, allocator: std.mem.Allocator) ![]const u8 {
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
        .{ .input = "/CONNECT/42", .want_tag = .connect },
        .{ .input = "/ACK/42/12/", .want_tag = .ack },
        .{ .input = "/CLOSE/42", .want_tag = .close },
        .{ .input = "/DATA/32/1/hello, world\n/", .want_tag = .data },
    };

    for (cases) |c| {
        const msg = try Message.parseMessage(c.input);
        try testing.expectEqual(std.meta.activeTag(msg), c.want_tag);
    }
}

test "parse valid connect message" {
    const cases = [_]struct {
        input: []const u8,
        sessionId: ?u32,
    }{
        .{ .input = "/CONNECT/42", .sessionId = 42 },
        .{ .input = "/CONNECT/0", .sessionId = 0 },
        .{ .input = "/CONNECT/10000", .sessionId = 10000 },
        .{ .input = "/CONNECT/239049929", .sessionId = 239049929 },
        .{ .input = "/CONNECT/-1", .sessionId = null },
    };

    for (cases) |c| {
        if (c.sessionId) |sid| {
            const msg = try Message.parseMessage(c.input);
            try testing.expectEqual(sid, msg.connect.session);
        } else {
            try testing.expectError(error.Overflow, Message.parseMessage(c.input));
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
        const msg = try Message.parseMessage(c.input);
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
        const msg = try Message.parseMessage(c.input);
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
        const msg = try Message.parseMessage(c.input);
        try testing.expectEqual(c.sessionId, msg.data.session);
        try testing.expectEqual(c.pos, msg.data.pos);
        try testing.expectEqualStrings(c.data, msg.data.data);
    }
}

test "parse invalid message returns error" {
    try testing.expectError(error.InvalidMessage, Message.parseMessage(""));
    try testing.expectError(error.InvalidMessage, Message.parseMessage("BOGUS"));
}

const std = @import("std");
const testing = std.testing;
