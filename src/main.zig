const std = @import("std");

const math = std.math;
const print = std.debug.print;

const rinhavec = @import("rinhavec");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // var allocator = arena.allocator();
}
