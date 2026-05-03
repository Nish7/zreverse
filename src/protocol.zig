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

    pub fn format(
        self: Message,
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            .connect => |m| try writer.print("/connect/{d}/", .{m.session}),
            .data => |m| try writer.print(
                "/data/{d}/{d}/{f}/",
                .{ m.session, m.pos,  std.ascii.hexEscape(m.data, .lower) },
            ),
            .ack => |m| try writer.print("/ack/{d}/{d}/", .{ m.session, m.length }),
            .close => |m| try writer.print("/close/{d}/", .{m.session}),
        }
    }

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
        const type_sep = std.mem.indexOfScalar(u8, body, '/') orelse return error.InvalidMessage;
        const msg_type = body[0..type_sep];
        const rest = body[type_sep + 1 ..];

        // /connect/SESSION/
        if (std.mem.eql(u8, msg_type, "connect")) {
            if (std.mem.indexOfScalar(u8, rest, '/')) |_| return error.InvalidMessage;
            const session_id = try std.fmt.parseInt(u32, rest, 10);
            return Message{ .connect = .{ .session = session_id } };
        }

        // /ack/SESSION/LENGTH/
        if (std.mem.eql(u8, msg_type, "ack")) {
            var it = std.mem.splitScalar(u8, rest, '/');
            const session = it.next() orelse return error.InvalidMessage;
            const length = it.next() orelse return error.InvalidMessage;
            if (it.next() != null) return error.InvalidMessage;
            const session_id = try std.fmt.parseInt(u32, session, 10);
            const ack_len = try std.fmt.parseInt(u32, length, 10);
            return Message{ .ack = .{ .session = session_id, .length = ack_len } };
        }

        // /data/SESSION/POS/DATA/
        if (std.mem.eql(u8, msg_type, "data")) {
            const session_sep = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidMessage;
            const session = rest[0..session_sep];
            const after_session = rest[session_sep + 1 ..];

            const pos_sep = std.mem.indexOfScalar(u8, after_session, '/') orelse return error.InvalidMessage;
            const pos = after_session[0..pos_sep];
            const escaped_data = after_session[pos_sep + 1 ..];

            const session_id = try std.fmt.parseInt(u32, session, 10);
            const data_pos = try std.fmt.parseInt(u32, pos, 10);
            const data = try unescapeData(allocator, escaped_data);
            return Message{ .data = .{ .session = session_id, .pos = data_pos, .data = data } };
        }

        // /close/SESSION/
        if (std.mem.eql(u8, msg_type, "close")) {
            if (std.mem.indexOfScalar(u8, rest, '/')) |_| return error.InvalidMessage;
            const session_id = try std.fmt.parseInt(u32, rest, 10);
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

            if (payload[i] == '/') return error.InvalidMessage;

            try out.append(allocator, payload[i]);
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn escapeData(allocator: std.mem.Allocator, payload: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        for (payload) |c| {
            if (c == '\\' or c == '/') {
                try out.append(allocator, '\\');
            }
            try out.append(allocator, c);
        }

        return out.toOwnedSlice(allocator);
    }

    pub fn getPayload(msg: Message, allocator: std.mem.Allocator) ![]const u8 {
        return switch (msg) {
            .connect => |m| try std.fmt.allocPrint(allocator, "/connect/{d}/", .{m.session}),
            .data => |m| blk: {
                const escaped = try escapeData(allocator, m.data);
                defer allocator.free(escaped);
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "/data/{d}/{d}/{s}/",
                    .{ m.session, m.pos, escaped },
                );
            },
            .ack => |m| try std.fmt.allocPrint(allocator, "/ack/{d}/{d}/", .{ m.session, m.length }),
            .close => |m| try std.fmt.allocPrint(allocator, "/close/{d}/", .{m.session}),
        };
    }
};

test "parse valid message types" {
    const cases = [_]struct {
        input: []const u8,
        want_tag: MessageType,
    }{
        .{ .input = "/connect/42/", .want_tag = .connect },
        .{ .input = "/ack/42/12/", .want_tag = .ack },
        .{ .input = "/close/42/", .want_tag = .close },
        .{ .input = "/data/32/1/hello, world\n/", .want_tag = .data },
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
        .{ .input = "/connect/42/", .sessionId = 42 },
        .{ .input = "/connect/0/", .sessionId = 0 },
        .{ .input = "/connect/10000/", .sessionId = 10000 },
        .{ .input = "/connect/239049929/", .sessionId = 239049929 },
        .{ .input = "/connect/-1/", .sessionId = null },
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
        .{ .input = "/ack/42/2/", .sessionId = 42, .length = 2 },
        .{ .input = "/ack/0/1/", .sessionId = 0, .length = 1 },
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
        .{ .input = "/close/12/", .sessionId = 12 },
        .{ .input = "/close/0/", .sessionId = 0 },
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
        .{ .input = "/data/42/1/Hello, world\n/", .sessionId = 42, .pos = 1, .data = "Hello, world\n" },
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

test "escape data payload" {
    const escaped = try Message.escapeData(testing.allocator, "foo/bar\\baz");
    defer testing.allocator.free(escaped);
    try testing.expectEqualStrings("foo\\/bar\\\\baz", escaped);
}

test "parse valid data message with escaped slash" {
    const msg = try Message.parseMessage(testing.allocator, "/data/42/1/foo\\/bar\\x0a/");
    defer msg.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 42), msg.data.session);
    try testing.expectEqual(@as(u32, 1), msg.data.pos);
    try testing.expectEqualStrings("foo/bar\\x0a", msg.data.data);
}

test "parse invalid message returns error" {
    try testing.expectError(error.InvalidMessage, Message.parseMessage(testing.allocator, ""));
    try testing.expectError(error.InvalidMessage, Message.parseMessage(testing.allocator, "BOGUS"));
    try testing.expectError(error.InvalidMessage, Message.parseMessage(testing.allocator, "CONNECT/42/"));
    try testing.expectError(error.InvalidMessage, Message.parseMessage(testing.allocator, "/connect/42"));
    try testing.expectError(error.InvalidMessage, Message.parseMessage(testing.allocator, "/close/12/extra/"));
    try testing.expectError(error.InvalidMessage, Message.parseMessage(testing.allocator, "/data/1/2/hello/extra/"));
}

const std = @import("std");
const testing = std.testing;
