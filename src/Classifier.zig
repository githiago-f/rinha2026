const std = @import("std");

const print = std.debug.print;
const vector = @import("vector.zig");
const dm = @import("data-model.zig");

pub const Classifier = @This();

decline_threshold: f32 = 0.6,
database: *dm.Database,

const Classification = struct {
    fraud_score: f32,
    approved: bool,
};

pub fn bruteforce(self: Classifier, query: vector.Vec) Classification {
    const nearest = vector.fullseach(self.database, query);

    var frauds: i32 = 0;
    inline for (0..5) |ni| {
        frauds += if (self.database.labels[nearest[ni].index]) 0 else 1;
    }

    const score: f32 = @as(f32, @floatFromInt(frauds)) / 5.0;
    const approved = score < self.decline_threshold;

    return .{
        .approved = approved,
        .fraud_score = score,
    };
}

pub fn classify(self: Classifier, query: vector.Vec) Classification {
    const nearest = vector.nearest5(self.database, query);

    var frauds: i32 = 0;
    inline for (0..5) |ni| {
        frauds += if (self.database.labels[nearest[ni].index]) 0 else 1;
    }

    const score: f32 = @as(f32, @floatFromInt(frauds)) / 5.0;
    const approved = score < self.decline_threshold;

    return .{
        .approved = approved,
        .fraud_score = score,
    };
}
