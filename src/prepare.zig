/// Preprocessor that injests a file, build buckets
/// and persists bytes to a desntination file
const std = @import("std");
const print = std.debug.print;
const ms = std.Io.Clock;

const vector = @import("vector.zig");
const p = @import("./parser.zig");
const dm = @import("./data-model.zig");

const DEF_LEAF_SIZE = 16;

fn getArgs(init: std.process.Init) !*const [2][]const u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) {
        print("[PREPARE] this command expects 2 arguments but got {d}:\n\tprepare -- <file.json> leaf_size\n", .{args.len});
        return error.InvalidArgsNumber;
    }
    return args[0..2];
}

pub fn main(init: std.process.Init) !void {
    print("[PREPARE] initiated\n", .{});
    const start = ms.now(.awake, init.io).toMilliseconds();

    const allocator = init.gpa;
    const args = try getArgs(init);

    const input_file_path = args[1];
    const leaf_size = if (args.len == 3) std.fmt.parseInt(u16, args[2], 10) else DEF_LEAF_SIZE;
    print("[PREPARE] file path: {s}\n", .{input_file_path});
    print("[PREPARE] leaf size: {d}\n", .{leaf_size});

    print("[PREPARE] reading file {s}\n", .{input_file_path});
    const input_file_data = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        input_file_path,
        allocator,
        .limited(1_000_000_000),
    );
    defer allocator.free(input_file_data);

    var parser: p.Parser = .init(input_file_data);
    print("[PREPARE] entries found {d}\n", .{parser.size});
    if (parser.size == 0) return error.InvalidWeightsFile;

    var entries: []p.Entry = try allocator.alloc(p.Entry, parser.size);
    defer allocator.free(entries);

    var counts: [DEF_LEAF_SIZE]u32 = [_]u32{0} ** DEF_LEAF_SIZE;

    var i: u32 = 0;
    while (parser.next()) |entry| {
        const key = vector.bucketKey(entry.vector);
        counts[key] += 1;

        entries[i] = entry;
        i += 1;
    }
    var end = ms.now(.awake, init.io).toMilliseconds();

    print("[PREPARE] loaded entries and bucket counts in {d}ms\n", .{end - start});

    i = 0;
    var offsets: [DEF_LEAF_SIZE]u32 = [_]u32{0} ** DEF_LEAF_SIZE;
    inline for (&offsets, counts) |*off, count| {
        off.* = i;
        i += count;
    }

    end = ms.now(.awake, init.io).toMilliseconds();
    print("[PREPARE] loaded entries and bucket offsets in {d}ms\n", .{end - start});

    var vectors: []vector.Vec = try allocator.alloc(vector.Vec, parser.size);
    defer allocator.free(vectors);

    var labels: []bool = try allocator.alloc(bool, parser.size);
    defer allocator.free(labels);

    var bucket_cursors: [DEF_LEAF_SIZE]u32 = [_]u32{0} ** DEF_LEAF_SIZE;
    for (entries) |entry| {
        const key = vector.bucketKey(entry.vector);

        const vector_index = bucket_cursors[key];
        bucket_cursors[key] += 1;

        vectors[vector_index] = entry.vector;
        labels[vector_index] = entry.legit;
    }

    end = ms.now(.awake, init.io).toMilliseconds();
    print("[PREPARE] labels and vectors loaded in buckets in {d}ms\n", .{end - start});

    const db: dm.Database = .{
        .buckets_offsets = &offsets,
        .vectors = vectors,
        .buckets_lengths = &counts,
        .labels = labels,
    };

    const file = try std.Io.Dir.cwd().createFile(init.io, "rinha.vec", .{});
    defer file.close(init.io);

    var buf: [1026]u8 = undefined;
    var fw = file.writer(init.io, &buf);
    const writer = &fw.interface;

    try db.writeTo(writer);

    end = ms.now(.awake, init.io).toMilliseconds();
    const stat = try file.stat(init.io);
    print("[PREPARE] wrote {d}M in {d}ms\n", .{ stat.size / 1024 / 1024, end - start });
}
