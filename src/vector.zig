const std = @import("std");
const KdTree = @import("kdtree").KdTree;

pub const DIMENSIONS = 16;
pub const SCALE = 10000;
pub const Vec = @Vector(DIMENSIONS, i16);

const print = std.debug.print;
const math = std.math;

const PartVec = @Vector(8, i16);

pub fn distance(a: Vec, b: Vec) i32 {
    const diff: Vec = a - b;

    const lo: PartVec = diff[0..8].*;
    const hi: PartVec = diff[8..16].*;

    const lo_sq = lo * lo;
    const hi_sq = hi * hi;

    return @reduce(.Add, lo_sq) +
        @reduce(.Add, hi_sq);
}

pub const SearchResult = packed struct {
    index: u32,
    distance: i32,
};

pub fn nearest(tree: *KdTree, root: u32, query: Vec) SearchResult {
    var best = SearchResult{ .index = 0, .distance = std.math.maxInt(i32) };

    var stack: [128]u32 = undefined;
    var stack_len: usize = 0;

    stack[stack_len] = root;
    stack_len += 1;

    while (stack_len > 0) {
        stack_len -= 1;

        const node_index = stack[stack_len];
        const node = tree.nodes.items[node_index];

        if (node.is_leaf == 1) {
            const start = node.start;
            const end = start + node.count;

            for (tree.indices[start..end]) |vec_index| {
                const vec: Vec = tree.vectors[vec_index..DIMENSIONS].*;

                const dist = distance(query, vec);

                if (dist < best.distance) {
                    best.distance = dist;
                    best.index = vec_index;
                }
            }

            continue;
        }

        const axis = node.axis;

        const query_value = query[axis];

        const diff = @as(i32, query_value) - @as(i32, node.split);
        const diff_sq = diff * diff;

        const left: u32 = @intCast(node.left);

        const right: u32 = @intCast(node.right);

        const first =
            if (query_value < node.split)
                left
            else
                right;

        const second =
            if (query_value < node.split)
                right
            else
                left;

        stack[stack_len] = first;
        stack_len += 1;

        if (diff_sq < best.distance) {
            stack[stack_len] = second;
            stack_len += 1;
        }
    }

    return best;
}
