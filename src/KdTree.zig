const std = @import("std");
const Vec = @Vector(16, i16);

pub const Node = extern struct {
    axis: u8,
    leaf: bool,

    split: i16,

    start: u32,
    len: u16,

    left: i32,
    right: i32,
};

const Header = extern struct {
    magic: u32,
    version: u16,

    dimensions: u16,

    node_count: u32,
    vector_count: u32,
    legits_count: u32,

    nodes_offset: u64,
    vectors_offset: u64,
    indices_offset: u64,
    legits_offset: u64,
};

pub const KdTree = @This();

allocator: std.mem.Allocator,

vectors: []i16,
legits: []u1,
indices: []u32,

leaf_size: u32,
capacity: u32,

nodes: std.ArrayList(Node),

pub fn init(allocator: std.mem.Allocator, leaf_size: u32, capacity: u32, vectors: []i16, legits: []u1) !KdTree {
    const indices = try allocator.alloc(u32, capacity);

    for (indices, 0..) |*idx, i| {
        idx.* = @intCast(i);
    }

    const kdtree: KdTree = .{
        .allocator = allocator,
        .capacity = capacity,
        .vectors = vectors,
        .legits = legits,
        .indices = indices,
        .leaf_size = leaf_size,
        .nodes = .empty,
    };

    return kdtree;
}

pub fn build(self: *KdTree) !u32 {
    return try self.buildRecursive(0, self.indices.len, 0);
}

const SortContext = struct {
    vectors: []i16,
    axis: u8,
};

fn sortLessThan(ctx: SortContext, a: u32, b: u32) bool {
    return ctx.vectors[a + ctx.axis] < ctx.vectors[b + ctx.axis];
}

fn buildRecursive(self: *KdTree, start: usize, end: usize, depth: usize) !u32 {
    const count = end - start;

    if (count <= self.leaf_size) {
        const node_index: u32 =
            @intCast(self.nodes.items.len);

        try self.nodes.append(
            self.allocator,
            .{
                .axis = 0,
                .leaf = true,

                .split = 0,

                .left = -1,
                .right = -1,

                .start = @intCast(start),
                .len = @intCast(count),
            },
        );

        return node_index;
    }

    const axis = self.largestVarianceAxis(start, end);

    const ctx = SortContext{ .vectors = self.vectors, .axis = axis };
    std.mem.sort(u32, self.indices[start..end], ctx, sortLessThan);

    const mid = (start + end) / 2;
    const median_index = self.indices[mid];

    const split = self.vectors[median_index + axis];

    const node_index: u32 = @intCast(self.nodes.items.len);

    try self.nodes.append(
        self.allocator,
        .{
            .axis = axis,
            .leaf = false,

            .split = split,

            .left = -1,
            .right = -1,

            .start = 0,
            .len = 0,
        },
    );

    const left = try self.buildRecursive(start, mid, depth + 1);
    const right = try self.buildRecursive(mid, end, depth + 1);

    self.nodes.items[node_index].left = @intCast(left);

    self.nodes.items[node_index].right = @intCast(right);

    return node_index;
}

fn largestVarianceAxis(self: *KdTree, start: usize, end: usize) u8 {
    var best_axis: u8 = 0;
    var best_variance: f64 = -1;

    for (0..16) |axis| {
        var sum: f64 = 0;

        for (self.indices[start..end]) |idx| {
            sum += @floatFromInt(self.vectors[idx + axis]);
        }

        const len_f: f64 = @floatFromInt(end - start);

        const mean = sum / len_f;

        var variance: f64 = 0;

        for (self.indices[start..end]) |idx| {
            const value: f64 = @floatFromInt(self.vectors[idx + axis]);

            const diff = value - mean;

            variance += diff * diff;
        }

        if (variance > best_variance) {
            best_variance = variance;
            best_axis = @intCast(axis);
        }
    }

    return best_axis;
}

const Database = struct {
    header: *const Header,

    nodes: []const Node,
    vectors: []const Vec,
    indices: []const u32,
    legits: []const u1,
};

pub fn toMmap(self: KdTree, writer: anytype) !void {
    const header_size = @sizeOf(Header);

    const nodes_offset = header_size;

    const vectors_offset = nodes_offset + self.nodes.items.len * @sizeOf(Node);
    const indices_offset = vectors_offset + self.vectors.len * @sizeOf(i16);
    const legits_offset = indices_offset + self.legits.len * @sizeOf(u1);

    const header = Header{
        .magic = 0x4B445431,
        .version = 1,

        .dimensions = 16,

        .node_count = @intCast(self.nodes.items.len),
        .vector_count = @intCast(self.vectors.len),
        .legits_count = @intCast(self.legits.len),

        .nodes_offset = nodes_offset,
        .vectors_offset = vectors_offset,
        .indices_offset = indices_offset,
        .legits_offset = legits_offset,
    };

    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(std.mem.sliceAsBytes(self.nodes.items));
    try writer.writeAll(std.mem.sliceAsBytes(self.vectors));
    try writer.writeAll(std.mem.sliceAsBytes(self.indices));
    try writer.writeAll(std.mem.sliceAsBytes(self.legits));
}

pub fn readMmap(file_name: []const u8) !Database {
    const file = try std.Io.Dir.cwd().openFile(file_name, .{});

    const stat = try file.stat();

    const size = stat.size;

    const memory = try std.posix.mmap(
        null,
        size,
        std.posix.PROT.READ,
        .{
            .TYPE = .PRIVATE,
        },
        file.handle,
        0,
    );

    const base: [*]const u8 = @ptrCast(memory.ptr);

    const header: *const Header = @ptrCast(@alignCast(base));

    const nodes_ptr: [*]const Node = @ptrCast(@alignCast(base + header.nodes_offset));
    const vectors_ptr: [*]const i16 = @ptrCast(@alignCast(base + header.vectors_offset));
    const indices_ptr: [*]const u32 = @ptrCast(@alignCast(base + header.indices_offset));
    const legits_ptr: [*]const u1 = @ptrCast(@alignCast(base + header.legits_offset));

    return .{
        .header = header,
        .nodes = nodes_ptr[0..header.node_count],
        .vectors = vectors_ptr[0..header.vector_count],
        .indices = indices_ptr[0..header.legits_count],
        .legits = legits_ptr[0..header.legits_count],
    };
}

pub fn deinit(self: *KdTree) void {
    self.allocator.free(self.indices);
    self.nodes.deinit(self.allocator);
}
