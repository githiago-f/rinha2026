const std = @import("std");
const print = std.debug.print;
const ms = std.Io.Clock;

const p = @import("parser.zig");
const KdTree = @import("kdtree").KdTree;

const DEF_LEAF_SIZE = 16;

fn getArgs(init: std.process.Init) !*const [2][]const u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) {
        print("[PREPARE] this command expects 2 arguments but got {d}:\n\tprepare -- <file.json> leaf_size\n", .{args.len});
        return error.InvalidArgsNumber;
    }
    return args[0..2];
}

/// Prepare data
pub fn main(init: std.process.Init) !void {
    print("[PREPARE] initiated\n", .{});
    const start = ms.now(.awake, init.io).toMilliseconds();

    const allocator = init.gpa;
    const args = try getArgs(init);

    const input_file_path = args[1];
    const leaf_size = if (args.len == 3) std.fmt.parseInt(u16, args[2], 10) else DEF_LEAF_SIZE;
    print("[PREPARE] file path: {s}\n", .{input_file_path});
    print("[PREPARE] leaf size: {d}\n", .{leaf_size});

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

    const legits = try allocator.alloc(u1, parser.size);
    defer allocator.free(legits);
    const vectors = try allocator.alloc(i16, parser.size * 16);
    defer allocator.free(vectors);

    var i: usize = 0;
    while (parser.next()) |entry| {
        inline for (0..16) |j| {
            vectors[i + j] = entry.vector[j];
        }

        legits[i] = if (entry.legit) 1 else 0;
        i += 1;
    }

    var kdt: KdTree = try .init(allocator, leaf_size, parser.size, vectors, legits);
    defer kdt.deinit();

    const root = try kdt.build();

    var end = ms.now(.awake, init.io).toMilliseconds();
    print("[PREPARE] kdtree created and ordered with {d} as root, in {d}ms\n", .{ root, end - start });

    const output_file = try std.Io.Dir.cwd().createFile(init.io, "rinha.vec", .{});
    defer output_file.close(init.io);

    var buf: [4096]u8 = undefined;
    var fw = output_file.writer(init.io, &buf);

    try kdt.toMmap(&fw.interface);

    end = ms.now(.awake, init.io).toMilliseconds();

    print("[PREPARE] took {d}ms to process\n", .{end - start});
}
