const std = @import("std");
const vector = @import("vector.zig");

const print = std.debug.print;

pub const NormalizationConstants = struct {
    max_amount: f32,
    max_installments: f32,
    amount_vs_avg_ratio: f32,
    max_minutes: f32,
    max_km: f32,
    max_tx_count_24h: f32,
    max_merchant_avg_amount: f32,

    pub fn init(a: std.mem.Allocator, io: std.Io, file_path: []const u8) !std.json.Parsed(NormalizationConstants) {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, file_path, a, .limited(1_000_000_000));
        defer a.free(data);

        const constants = try std.json.parseFromSlice(NormalizationConstants, a, data, .{});
        return constants;
    }
};

pub const RequestParser = struct {
    allocator: std.mem.Allocator,

    normalization: NormalizationConstants,

    mmcs: [10000]i16,

    pub fn init(allocator: std.mem.Allocator, normalization: NormalizationConstants) RequestParser {
        var mmcs: [10000]i16 = undefined;
        @memset(&mmcs, 5000);

        return .{
            .allocator = allocator,
            .normalization = normalization,
            .mmcs = mmcs,
        };
    }

    inline fn encode01(v: f32) i16 {
        const n = @max(0.0, @min(1.0, v));
        return @intFromFloat(n * vector.SCALE);
    }

    inline fn after(buf: []const u8, comptime key: []const u8) ?[]const u8 {
        const pos =
            std.mem.indexOf(u8, buf, key) orelse return null;

        const start = pos + key.len;
        return buf[start..];
    }

    inline fn parseInt(buf: []const u8) u32 {
        var pos: u32 = 0;
        while (buf[pos] == ' ') pos += 1;
        var value: u32 = 0;

        for (buf[pos..]) |c| {
            if (c < '0' or c > '9')
                break;

            value = value * 10 + (c - '0');
        }

        return value;
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

    inline fn parseString(buf: []const u8) ?[]const u8 {
        var pos: u32 = 0;
        while (buf[pos] == ' ') pos += 1;

        if (buf.len == 0 or buf[pos] != '"')
            return null;

        pos += 1;

        const end = pos + (std.mem.indexOfScalarPos(u8, buf[pos..], 1, '"') orelse return null);

        return buf[pos..end];
    }

    inline fn weekday(year: i32, month: u8, day: u8) u8 {
        const t = [_]u8{
            0, 3, 2, 5, 0, 3,
            5, 1, 4, 6, 2, 4,
        };

        var y = year;

        if (month < 3)
            y -= 1;

        const dow = @mod(
            y +
                @divFloor(y, 4) -
                @divFloor(y, 100) +
                @divFloor(y, 400) +
                t[month - 1] +
                day,
            7,
        );

        return switch (dow) {
            1 => 0,
            2 => 1,
            3 => 2,
            4 => 3,
            5 => 4,
            6 => 5,
            0 => 6,
            else => unreachable,
        };
    }

    inline fn getMcc(self: *const RequestParser, mcc: u16) i16 {
        if (mcc >= self.mmcs.len)
            return 5000;

        return self.mmcs[mcc];
    }

    inline fn parse2(a: u8, b: u8) u8 {
        return (a - '0') * 10 +
            (b - '0');
    }

    inline fn parse4(a: u8, b: u8, c: u8, d: u8) u16 {
        return @as(u16, a - '0') * 1000 +
            @as(u16, b - '0') * 100 +
            @as(u16, c - '0') * 10 +
            @as(u16, d - '0');
    }

    inline fn daysSinceUnixEpoch(year: i32, month: u8, day: u8) i32 {
        var y = year;
        const m: i32 = month;

        y -= if (m <= 2) 1 else 0;
        const mm: i32 = if (m > 2) -3 else 9;

        const era = @divFloor(y, 400);
        const yoe = y - era * 400;
        const doy = @divFloor(153 * (m + mm) + 2, 5) + day - 1;

        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;

        return era * 146097 + doe - 719468;
    }

    inline fn parseEpochMinutes(ts: []const u8) u64 {
        const year = parse4(ts[0], ts[1], ts[2], ts[3]);
        const month = parse2(ts[5], ts[6]);
        const day = parse2(ts[8], ts[9]);
        const hour: i64 = @intCast(parse2(ts[11], ts[12]));
        const minute: i64 = @intCast(parse2(ts[14], ts[15]));

        const days: i64 = @intCast(daysSinceUnixEpoch(year, month, day));

        return @intCast(days * 1440 + hour * 60 + minute);
    }

    pub fn parse(self: *const RequestParser, request: []const u8, out: *vector.Vec) !void {
        var vec: vector.Vec = @splat(0);

        const amount =
            parseFloat(
                after(request, "\"amount\":") orelse return error.InvalidRequest,
            );

        const installments =
            parseInt(
                after(request, "\"installments\":") orelse return error.InvalidRequest,
            );

        const requested_at =
            parseString(
                after(request, "\"requested_at\":") orelse return error.InvalidRequest,
            ) orelse return error.InvalidRequest;

        const hour = parse2(requested_at[11], requested_at[12]);
        const year = parseInt(requested_at[1..]);
        const month: u8 = @intCast(parseInt(requested_at[5..]));
        const day: u8 = @intCast(parseInt(requested_at[8..]));

        const dow =
            weekday(
                @intCast(year),
                month,
                day,
            );

        const customer_section = after(request, "\"customer\":") orelse return error.InvalidRequest;

        const avg_amount =
            if (after(customer_section, "\"avg_amount\":")) |s|
                parseFloat(s)
            else
                0;

        const tx_count_24h =
            if (after(request, "\"tx_count_24h\":")) |s|
                parseInt(s)
            else
                0;

        const km_from_home =
            if (after(request, "\"km_from_home\":")) |s|
                parseFloat(s)
            else
                0;

        const merchant_section =
            after(request, "\"merchant\":") orelse return error.InvalidRequest;

        const merchant_avg =
            if (after(merchant_section, "\"avg_amount\":")) |s|
                parseFloat(s)
            else
                0;

        const online =
            std.mem.indexOf(
                u8,
                request,
                "\"is_online\":true",
            ) != null;

        const card_present =
            std.mem.indexOf(
                u8,
                request,
                "\"card_present\":true",
            ) != null;

        const mcc: u16 = @intCast(
            parseInt(parseString(
                after(request, "\"mcc\":") orelse return error.InvalidRequest,
            ) orelse return error.InvalidRequest),
        );

        vec[0] = encode01(amount / self.normalization.max_amount);
        vec[1] = encode01(@as(f32, @floatFromInt(installments)) / self.normalization.max_installments);

        vec[2] =
            if (avg_amount == 0)
                vector.SCALE
            else
                encode01(amount / (avg_amount * self.normalization.amount_vs_avg_ratio));

        vec[3] = encode01(@as(f32, @floatFromInt(hour)) / 23.0);
        vec[4] = encode01(@as(f32, @floatFromInt(dow)) / 6.0);

        const last_tran_section = after(request, "\"last_transaction\":") orelse return error.InvalidRequest;
        const last_tran_is_null =
            std.mem.eql(u8, last_tran_section[1..5], "null") or
            std.mem.eql(u8, last_tran_section[0..4], "null");

        if (last_tran_is_null) {
            vec[5] = -10000;
            vec[6] = -10000;
        } else {
            const ts = after(last_tran_section, "timestamp\":") orelse return error.InvalidRequest;
            const prev_ts = parseString(ts) orelse return error.InvalidRequest;
            const minutes_since_last_tx: f32 = @floatFromInt(parseEpochMinutes(requested_at) - parseEpochMinutes(prev_ts));
            vec[5] = encode01(minutes_since_last_tx / self.normalization.max_minutes);

            const km_from_last_tx = parseFloat(
                after(last_tran_section, "km_from_current\":") orelse return error.InvalidRequest,
            );
            vec[6] = encode01(km_from_last_tx / self.normalization.max_km);
        }

        vec[7] = encode01(
            km_from_home /
                self.normalization.max_km,
        );

        vec[8] = encode01(
            @as(f32, @floatFromInt(tx_count_24h)) /
                self.normalization.max_tx_count_24h,
        );

        vec[9] =
            if (online)
                vector.SCALE
            else
                0;

        vec[10] =
            if (card_present)
                vector.SCALE
            else
                0;

        vec[11] = vector.SCALE;

        if (after(request, "\"merchant_id\":")) |merchant_start| {
            if (parseString(merchant_start)) |merchant_id| {
                if (after(request, "\"known_merchants\":")) |known| {
                    if (std.mem.indexOfScalar(u8, known, ']')) |end| {
                        var tmp: [128]u8 = undefined;

                        const needle =
                            try std.fmt.bufPrint(
                                &tmp,
                                "\"{s}\"",
                                .{merchant_id},
                            );

                        const found =
                            std.mem.indexOf(
                                u8,
                                known[0..end],
                                needle,
                            ) != null;

                        vec[11] =
                            if (found)
                                0
                            else
                                vector.SCALE;
                    }
                }
            }
        }

        vec[12] = getMcc(self, mcc);

        vec[13] = encode01(merchant_avg / self.normalization.max_merchant_avg_amount);

        vec[14] = 0;
        vec[15] = 0;

        out.* = vec;
    }
};
