const std = @import("std");

const print = std.debug.print;
const dm = @import("data-model.zig");
const vector = @import("vector.zig");
const Classifier = @import("Classifier.zig").Classifier;
const rp = @import("request.zig");

fn getArgs(init: std.process.Init) !*const [3][]const u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) {
        print("[Bench] usage: {d} <database.bin> <validation.ndjson>\n", .{args.len});
        return error.InvalidArgsNumber;
    }
    return args[0..3];
}

inline fn after(buf: []const u8, comptime key: []const u8) ?[]const u8 {
    const pos =
        std.mem.indexOf(u8, buf, key) orelse return null;

    const start = pos + key.len;
    return buf[start..];
}

inline fn parseFloat(buf: []const u8) f32 {
    var i: usize = 0;
    while (buf[i] == ' ') i += 1;

    var integer: u32 = 0;

    while (i < buf.len) : (i += 1) {
        const c = buf[i];

        if (c == '.')
            break;

        if (c < '0' or c > '9')
            break;

        integer = integer * 10 + (c - '0');
    }

    const value: f32 = @floatFromInt(integer);

    if (i >= buf.len or buf[i] != '.')
        return value;

    i += 1;

    var frac: f32 = 0;
    var div: f32 = 10;

    while (i < buf.len) : (i += 1) {
        const c = buf[i];

        if (c < '0' or c > '9')
            break;

        frac += @as(f32, @floatFromInt(c - '0')) / div;
        div *= 10;
    }

    return value + frac;
}

inline fn skipSpaces(buf: []const u8) []const u8 {
    var i: usize = 0;
    while (buf[i] == ' ') i += 1;
    return buf[i..];
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try getArgs(init);

    const risk_data = try std.Io.Dir.cwd().readFileAlloc(init.io, "mcc_risk.json", allocator, .limited(1_000_000));
    defer allocator.free(risk_data);

    const normalization = try rp.NormalizationConstants.init(allocator, init.io, "normalization.json");
    defer normalization.deinit();

    var db = try dm.parseDatabase(args[1], allocator, init.io);
    defer db.deinit();

    var classifier = Classifier{ .database = &db };

    const file = try std.Io.Dir.cwd().openFile(init.io, args[2], .{});
    defer file.close(init.io);

    var buf: [4096]u8 = undefined;
    var fr = file.reader(init.io, &buf);
    var reader: *std.Io.Reader = &fr.interface;

    var tp: usize = 0;
    var tn: usize = 0;
    var fp: usize = 0;
    var fn_: usize = 0;

    var bf_tp: usize = 0;
    var bf_tn: usize = 0;
    var bf_fp: usize = 0;
    var bf_fn_: usize = 0;

    var total: usize = 0;

    var parser: rp.RequestParser = .init(allocator, risk_data, normalization.value);

    while (try reader.takeDelimiter('\n')) |line| {
        reader.toss(1);
        if (total > 10) break;
        if (line.len == 0) continue;

        var vec: vector.Vec = @splat(@as(i16, 0));
        const request_section = after(line, "\"request\":") orelse unreachable;
        const approved_section = skipSpaces(after(line, "\"approved\":") orelse unreachable);
        const expected_approved = std.mem.eql(u8, approved_section[0..4], "true");

        try parser.parse(request_section, &vec);

        const clas = classifier.classify(vec);
        const clas2 = classifier.bruteforce(vec);
        const predicted_fraud = !clas.approved;
        const predicted_fraud2 = !clas2.approved;

        if (clas.approved != clas2.approved) {
            std.debug.print(
                "DIFF expected={} bucket={} brute={}\n",
                .{
                    expected_approved,
                    clas.approved,
                    clas2.approved,
                },
            );
        }

        if (predicted_fraud and !expected_approved) {
            tp += 1;
        } else if (!predicted_fraud and expected_approved) {
            tn += 1;
        } else if (predicted_fraud and expected_approved) {
            fp += 1;
        } else {
            fn_ += 1;
        }

        if (predicted_fraud2 and !expected_approved) {
            bf_tp += 1;
        } else if (!predicted_fraud2 and expected_approved) {
            bf_tn += 1;
        } else if (predicted_fraud2 and expected_approved) {
            bf_fp += 1;
        } else {
            bf_fn_ += 1;
        }

        total += 1;
    }

    const precision: f64 =
        if (tp + fp == 0)
            0
        else
            @as(f64, @floatFromInt(tp)) / @as(f64, @floatFromInt(tp + fp));

    const recall: f64 =
        if (tp + fn_ == 0)
            0
        else
            @as(f64, @floatFromInt(tp)) / @as(f64, @floatFromInt(tp + fn_));

    const f1: f64 =
        if (precision + recall == 0)
            0
        else
            (2.0 * precision * recall) /
                (precision + recall);

    std.debug.print(
        \\ bucket 
        \\Total: {}
        \\TP: {}
        \\TN: {}
        \\FP: {}
        \\FN: {}
        \\Precision: {d:.6}
        \\Recall: {d:.6}
        \\F1: {d:.6}
        \\
    ,
        .{ total, tp, tn, fp, fn_, precision, recall, f1 },
    );

    const bf_precision: f64 =
        if (bf_tp + bf_fp == 0)
            0
        else
            @as(f64, @floatFromInt(bf_tp)) / @as(f64, @floatFromInt(bf_tp + bf_fp));

    const bf_recall: f64 =
        if (bf_tp + bf_fn_ == 0)
            0
        else
            @as(f64, @floatFromInt(bf_tp)) / @as(f64, @floatFromInt(bf_tp + bf_fn_));

    const bf_f1: f64 =
        if (bf_precision + bf_recall == 0)
            0
        else
            (2.0 * bf_precision * bf_recall) /
                (bf_precision + bf_recall);

    std.debug.print(
        \\ bruteforce
        \\Total: {}
        \\TP: {}
        \\TN: {}
        \\FP: {}
        \\FN: {}
        \\Precision: {d:.6}
        \\Recall: {d:.6}
        \\F1: {d:.6}
        \\
    ,
        .{ total, bf_tp, bf_tn, bf_fp, bf_fn_, bf_precision, bf_recall, bf_f1 },
    );
}
