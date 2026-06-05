const std = @import("std");
const vector = @import("./vector.zig");

pub const Entry = struct {
    vector: vector.Vec,
    legit: bool,
};

pub const Parser = struct {
    data: []const u8,
    size: u32 = 0,
    pos: usize = 0,

    legits: u32 = 0,
    frauds: u32 = 0,

    pub fn init(data: []const u8) Parser {
        const size = countReferences(data);
        return .{ .data = data, .size = size };
    }

    inline fn countReferences(data: []const u8) u32 {
        var count: u32 = 0;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, data, pos, "\"vector\"")) |idx| {
            count += 1;
            pos = idx + 8;
        }
        return count;
    }

    pub inline fn next(self: *Parser) ?Entry {
        while (self.pos < self.data.len) : (self.pos += 1) {
            if (self.data[self.pos] == '{')
                break;
        }

        if (self.pos >= self.data.len)
            return null;

        self.pos += 1;

        var vec: vector.Vec = undefined;
        self.seekVector();

        inline for (0..vector.DIMENSIONS) |i| {
            vec[i] = if (i >= 14) 0 else self.parseFixed4();
            self.pos += 1;
        }

        self.seekLabel();

        const legit = self.data[self.pos] == 'l';

        if (legit) {
            self.legits += 1;
        } else {
            self.frauds += 1;
        }

        return .{
            .vector = vec,
            .legit = legit,
        };
    }

    inline fn seekVector(self: *Parser) void {
        while (self.data[self.pos] != '[')
            self.pos += 1;

        self.pos += 1;
    }

    inline fn seekLabel(self: *Parser) void {
        while (true) : (self.pos += 1) {
            if (self.data[self.pos] == '"') {
                self.pos += 1;

                const c = self.data[self.pos];

                if (c == 'l' or c == 'f')
                    return;
            }
        }
    }

    inline fn parseFixed4(self: *Parser) i16 {
        @setRuntimeSafety(false);

        var negative = false;

        if (self.data[self.pos] == '-') {
            negative = true;
            self.pos += 1;
        }

        var int: i32 = 0;

        while (true) {
            const c = self.data[self.pos];

            if (c < '0' or c > '9')
                break;

            int = int * 10 + (c - '0');

            self.pos += 1;
        }

        var frac: i32 = 0;
        var digits: u8 = 0;

        if (self.data[self.pos] == '.') {
            self.pos += 1;

            while (true) {
                const c = self.data[self.pos];

                if (c < '0' or c > '9')
                    break;

                if (digits < 4) {
                    frac = frac * 10 + (c - '0');
                    digits += 1;
                }

                self.pos += 1;
            }
        }

        inline for (0..4) |i| {
            if (i >= digits)
                frac *= 10;
        }

        var value: i32 = int * vector.SCALE + frac;

        if (negative)
            value = -value;

        return @intCast(value);
    }
};
