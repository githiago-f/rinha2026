const std = @import("std");

const dm = @import("data-model.zig");

pub const DIMENSIONS = 16;
pub const SCALE = 10000;
pub const Vec = @Vector(DIMENSIONS, i16);

const print = std.debug.print;
const math = std.math;

const PartVec = @Vector(8, i32);

pub fn bucketKey(v: Vec) u4 {
    const online = @as(u4, @intFromBool(v[9] > 5000));
    const card_present = @as(u4, @intFromBool(v[10] > 5000));
    const unknown = @as(u4, @intFromBool(v[11] > 5000));
    const has_history = @as(u4, @intFromBool(v[5] >= 0));

    return (online << 3) |
        (card_present << 2) |
        (unknown << 1) |
        has_history;
}

const SearchResult = struct {
    index: u32,
    distance: i64,
};

const TopK = struct {
    items: [5]SearchResult = [_]SearchResult{
        .{ .index = 0, .distance = std.math.maxInt(i32) },
        .{ .index = 0, .distance = std.math.maxInt(i32) },
        .{ .index = 0, .distance = std.math.maxInt(i32) },
        .{ .index = 0, .distance = std.math.maxInt(i32) },
        .{ .index = 0, .distance = std.math.maxInt(i32) },
    },

    pub fn insert(self: *TopK, item: SearchResult) void {
        if (item.distance >= self.items[0].distance)
            return;

        self.items[0] = item;

        inline for (0..4) |i| {
            if (self.items[i].distance < self.items[i + 1].distance) {
                std.mem.swap(SearchResult, &self.items[i], &self.items[i + 1]);
            }
        }
    }
};

pub fn nearest5(db: *dm.Database, query: Vec) [5]SearchResult {
    const key = bucketKey(query);

    const start = db.buckets_offsets[key];
    const end = start + db.buckets_lengths[key];

    var best = TopK{};

    var i = start;

    while (i < end) : (i += 1) {
        const dist = distance(query, db.vectors[i]);
        best.insert(.{ .index = i, .distance = dist });
    }

    return best.items;
}

pub inline fn distance(a: Vec, b: Vec) i64 {
    const av: @Vector(16, i32) = a;
    const bv: @Vector(16, i32) = b;

    const diff = av - bv;
    const sq: @Vector(16, i64) = diff * diff;

    return @reduce(.Add, sq);
}
