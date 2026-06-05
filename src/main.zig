const std = @import("std");

const dm = @import("data-model.zig");
const vector = @import("vector.zig");
const rp = @import("request.zig");
const Classifier = @import("Classifier.zig").Classifier;
const net = @import("net/net.zig");

const math = std.math;
const print = std.debug.print;

const App = struct {
    io: std.Io,
    parser: *const rp.RequestParser,
    classifier: *const Classifier,
};

fn handler(buf: []u8, app: *const App, req: net.Request) net.Response {
    if (req.method == .GET and std.mem.eql(u8, req.path, "/health")) {
        return .{
            .status = 200,
            .content_type = "text/plain",
            .body = "OK",
        };
    }

    if (req.method == .POST and std.mem.eql(u8, req.path, "/fraud-score")) {
        const json = req.body;
        var query: vector.Vec = @splat(@as(i16, 0));

        app.parser.parse(json, &query) catch |e| {
            if (e == error.InvalidRequest) return .{
                .status = 400,
                .content_type = "text/plain",
                .body = "bad request",
            };
        };

        const class = app.classifier.classify(query);

        const body = std.fmt.bufPrint(buf, "{{\"fraud_score\":{d},\"approved\":{}}}", .{
            class.fraud_score,
            class.approved,
        }) catch unreachable;

        return .{ .body = body, .content_type = "application/json", .status = 200 };
    }

    return .{
        .status = 404,
        .content_type = "text/plain",
        .body = "Not Found",
    };
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    const allocator = arena.allocator();

    const port = 8080;

    var db = try dm.parseDatabase("rinha.vec", allocator, init.io);
    defer db.deinit();

    const risk_data = try std.Io.Dir.cwd().readFileAlloc(init.io, "mcc_risk.json", allocator, .limited(1_000_000));
    defer allocator.free(risk_data);

    const normalization = try rp.NormalizationConstants.init(allocator, init.io, "normalization.json");
    defer normalization.deinit();

    const classifier: Classifier = .{ .database = &db };
    const req_parser: rp.RequestParser = .init(allocator, risk_data, normalization.value);

    const app: App = .{
        .io = init.io,
        .classifier = &classifier,
        .parser = &req_parser,
    };

    const server: net.Server(App) = .init(port, &app, handler);
    try server.listen();
}
