const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;

pub const Method = enum {
    GET,
    POST,
    UNKNOWN,
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    body: []const u8,
};

pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json",
    body: []const u8,
};

pub fn linux_sysret(rc: usize) linux.E {
    const s: isize = @bitCast(rc);
    if (s >= -4095 and s <= -1) return @enumFromInt(@as(u16, @intCast(-s)));
    return .SUCCESS;
}

pub fn printAddress(ip: u32, port: u16) void {
    std.debug.print("{d}.{d}.{d}.{d}:{d}\n", .{
        (ip >> 24) & 0xff,
        (ip >> 16) & 0xff,
        (ip >> 8) & 0xff,
        ip & 0xff,
        port,
    });
}

pub fn Server(comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const Handler = fn (
            buf: []u8,
            ctx: *const Context,
            req: Request,
        ) Response;

        const MAX_REQUEST_SIZE = 64 * 1024;

        port: u16,
        ctx: *const Context,
        handler: *const Handler,

        pub fn init(port: u16, ctx: *const Context, handler: *const Handler) Self {
            return .{
                .port = port,
                .ctx = ctx,
                .handler = handler,
            };
        }

        pub fn listen(self: *const Self) !void {
            const fd: i32 = @intCast(linux.socket(
                posix.AF.INET,
                posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
                0,
            ));
            defer _ = linux.close(fd);

            {
                const yes: c_int = 1;

                try posix.setsockopt(
                    fd,
                    posix.SOL.SOCKET,
                    posix.SO.REUSEADDR,
                    std.mem.asBytes(&yes),
                );

                try posix.setsockopt(
                    fd,
                    posix.SOL.SOCKET,
                    posix.SO.REUSEPORT,
                    std.mem.asBytes(&yes),
                );
            }

            const addr = linux.sockaddr.in{
                .family = linux.AF.INET,
                .port = std.mem.nativeToBig(u16, self.port),
                .addr = 0,
                .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
            };

            printAddress(addr.addr, self.port);

            const bind = linux_sysret(linux.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))));

            if (bind != .SUCCESS)
                return error.CannotBindSocket;

            const accquire_fd = linux_sysret(linux.listen(fd, 4096));

            if (accquire_fd != .SUCCESS)
                return error.CannotStartListener;

            const epfd = @as(i32, @intCast(@as(isize, @bitCast(linux.epoll_create1(0)))));
            if (epfd < 0)
                return error.CannotCreateEpoll;

            defer _ = linux.close(epfd);

            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN,
                .data = .{ .fd = fd },
            };

            const listener = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev);
            if (listener < 0)
                return error.CannotRegisterListener;

            var events: [256]linux.epoll_event = undefined;

            while (true) {
                const ready = linux.epoll_wait(epfd, events[0..].ptr, events.len, 1000);
                if (ready <= 0) continue;

                var i: usize = 0;

                while (i < @as(usize, @intCast(ready))) : (i += 1) {
                    const event_fd = events[i].data.fd;

                    if (event_fd == fd) {
                        while (true) {
                            const rc = linux.accept4(
                                fd,
                                null,
                                null,
                                linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
                            );

                            const err = linux_sysret(rc);

                            if (err == .AGAIN)
                                break;

                            if (err != .SUCCESS)
                                break;

                            const conn: i32 =
                                @intCast(@as(isize, @bitCast(rc)));

                            var conn_ev = linux.epoll_event{
                                .events = linux.EPOLL.IN |
                                    linux.EPOLL.RDHUP |
                                    linux.EPOLL.HUP,
                                .data = .{ .fd = conn },
                            };

                            _ = linux.epoll_ctl(
                                epfd,
                                linux.EPOLL.CTL_ADD,
                                conn,
                                &conn_ev,
                            );
                        }
                    } else {
                        self.handleConnection(event_fd);

                        _ = linux.epoll_ctl(
                            epfd,
                            linux.EPOLL.CTL_DEL,
                            event_fd,
                            null,
                        );

                        _ = linux.close(event_fd);
                    }
                }
            }
        }

        fn handleConnection(self: *const Self, fd: posix.socket_t) void {
            var buffer: [MAX_REQUEST_SIZE]u8 = undefined;
            const n = linux.read(fd, &buffer, 16384);

            if (linux_sysret(n) != .SUCCESS or n == 0) return;
            const raw = buffer[0..n];

            const req = parseRequest(raw) catch {
                writeSimple(fd, 400, "Bad Request");
                return;
            };

            var responseBuffer: [1024]u8 = undefined;
            const resp = self.handler(&responseBuffer, self.ctx, req);

            writeResponse(fd, resp);
        }
    };
}

fn parseRequest(raw: []const u8) !Request {
    const line_end =
        std.mem.indexOf(u8, raw, "\r\n") orelse
        return error.BadRequest;

    const first_line = raw[0..line_end];

    const sp1 =
        std.mem.indexOfScalar(u8, first_line, ' ') orelse
        return error.BadRequest;

    const sp2 =
        std.mem.lastIndexOfScalar(u8, first_line, ' ') orelse
        return error.BadRequest;

    const method_str = first_line[0..sp1];
    const path = first_line[sp1 + 1 .. sp2];

    const method: Method =
        if (std.mem.eql(u8, method_str, "GET"))
            .GET
        else if (std.mem.eql(u8, method_str, "POST"))
            .POST
        else
            .UNKNOWN;

    if (method == .GET) {
        return .{
            .method = .GET,
            .path = path,
            .body = "",
        };
    }

    const body_start =
        std.mem.indexOf(u8, raw, "\r\n\r\n") orelse
        return error.BadRequest;

    const body = raw[body_start + 4 ..];

    return .{
        .method = method,
        .path = path,
        .body = body,
    };
}

fn writeSimple(fd: posix.socket_t, status: u16, body: []const u8) void {
    writeResponse(fd, .{
        .status = status,
        .content_type = "text/plain",
        .body = body,
    });
}

fn fullWrite(data: []const u8, fd: i32) void {
    var sent: usize = 0;

    while (sent < data.len) {
        const rc = linux.write(fd, data.ptr + sent, data.len - sent);

        const written: usize = @intCast(@as(isize, @bitCast(rc)));

        if (linux_sysret(rc) != .SUCCESS)
            return;

        sent += written;
    }
}

fn writeResponse(fd: posix.socket_t, resp: Response) void {
    var buf: [1024]u8 = undefined;

    const reason =
        switch (resp.status) {
            200 => "OK",
            400 => "Bad Request",
            404 => "Not Found",
            503 => "Bad Gateway",
            500 => "Internal Server Error",
            else => "OK",
        };

    const head: []const u8 = std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{
            resp.status,
            reason,
            resp.content_type,
            resp.body.len,
        },
    ) catch return;

    fullWrite(head, fd);
    fullWrite(resp.body, fd);
}
