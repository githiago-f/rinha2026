const std = @import("std");
const dm = @import("data-model.zig");
const vector = @import("vector.zig");
const req = @import("request.zig");

const math = std.math;
const print = std.debug.print;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    const allocator = arena.allocator();

    var db = try dm.parseDatabase("rinha.vec", allocator, init.io);
    defer db.deinit();

    // const risk_data = try std.Io.Dir.cwd().readFileAlloc(init.io, "mcc_risk.json", allocator, .limited(1_000_000));

    const normalization = try req.NormalizationConstants.init(allocator, init.io, "normalization.json");
    defer normalization.deinit();

    const requestParser: req.RequestParser = .init(allocator, normalization.value);
    const req2 =
        \\{
        \\"id": "tx-3576980410",
        \\"transaction": {
        \\  "amount": 384.88,
        \\  "installments": 3,
        \\  "requested_at": "2026-03-11T20:23:35Z"
        \\},
        \\"customer": {
        \\  "avg_amount": 769.76,
        \\  "tx_count_24h": 3,
        \\  "known_merchants": [
        \\    "MERC-009",
        \\    "MERC-009",
        \\    "MERC-001",
        \\    "MERC-001"
        \\  ]
        \\},
        \\"merchant": {
        \\ "id": "MERC-001",
        \\  "mcc": "5912",
        \\  "avg_amount": 298.95
        \\},
        \\"terminal": {
        \\  "is_online": false,
        \\  "card_present": true,
        \\  "km_from_home": 13.7090520965
        \\},
        \\"last_transaction": {
        \\  "timestamp": "2026-03-11T14:58:35Z",
        \\  "km_from_current": 18.8626479774
        \\}
        \\} 
    ;
    const request =
        \\{
        \\"id": "tx-1329056812",
        \\"transaction": {
        \\  "amount": 41.12,
        \\  "installments": 2,
        \\  "requested_at": "2026-03-11T18:45:53Z"
        \\},
        \\ "customer": {
        \\  "avg_amount": 82.24,
        \\  "tx_count_24h": 3,
        \\  "known_merchants": [
        \\    "MERC-003",
        \\    "MERC-016"
        \\  ]
        \\},
        \\"merchant": {
        \\  "id": "MERC-016",
        \\  "mcc": "5411",
        \\  "avg_amount": 60.25
        \\},
        \\"terminal": {
        \\  "is_online": false,
        \\  "card_present": true,
        \\  "km_from_home": 29.2331036248
        \\},
        \\"last_transaction": null
        \\}
    ;

    var out: vector.Vec = @splat(@as(i16, 0));
    try requestParser.parse(request, &out);

    print("request : {any}\n", .{out});

    const nearest = vector.nearest5(&db, out);

    try requestParser.parse(req2, &out);

    print("\n\nrequest : {any}\n\n\n", .{out});
    const nearest2 = vector.nearest5(&db, out);

    for (nearest) |n| {
        print("nearest: {any},\nvec: {any},\nlabel: {}\n", .{ n, db.vectors[n.index], db.labels[n.index] });
    }

    for (nearest2) |n| {
        print("nearest: {any},\nvec: {any},\nlabel: {}\n", .{ n, db.vectors[n.index], db.labels[n.index] });
    }
}
