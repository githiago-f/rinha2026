/// data-model.zig is a mmap builder.
/// this file is defining a memory model that fits in a .vec file.
const std = @import("std");
const Vec = @import("vector.zig").Vec;

const magic = 0x52494E48;

const Header = extern struct {
    magic: u32,
    version: u16,

    vector_count: u32,
    bucket_count: u32,

    vectors_offset: u64,
    labels_offset: u64,
    bucket_offsets_offset: u64,
    bucket_lengths_offset: u64,
};

pub const Database = struct {
    vectors: []const Vec,
    labels: []const bool,

    buckets_offsets: []const u32,
    buckets_lengths: []const u32,

    pub fn deinit(self: *Database) void {
        self.* = undefined;
    }

    fn seekTo(writer: anytype, current_pos: *usize, target_pos: usize) !void {
        std.debug.assert(target_pos >= current_pos.*);

        const padding = target_pos - current_pos.*;

        var buf: [64]u8 = [_]u8{0} ** 64;

        var remaining = padding;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            try writer.writeAll(buf[0..chunk]);
            remaining -= chunk;
        }

        current_pos.* = target_pos;
    }

    pub fn writeTo(self: Database, writer: *std.Io.Writer) !void {
        const header_size = @sizeOf(Header);

        const vectors_size = self.vectors.len * @sizeOf(Vec);
        const bucket_offsets_size = self.buckets_offsets.len * @sizeOf(u32);
        const bucket_lengths_size = self.buckets_lengths.len * @sizeOf(u32);

        const bucket_offsets_offset = std.mem.alignForward(usize, header_size, @alignOf(u32));
        const bucket_lengths_offset = std.mem.alignForward(usize, bucket_offsets_offset + bucket_offsets_size, @alignOf(u32));
        const vectors_offset = std.mem.alignForward(usize, bucket_lengths_offset + bucket_lengths_size, @alignOf(Vec));
        const labels_offset = std.mem.alignForward(usize, vectors_offset + vectors_size, @alignOf(u8));

        const header = Header{
            .magic = magic,
            .version = 1,

            .vector_count = @intCast(self.vectors.len),
            .bucket_count = @intCast(self.buckets_lengths.len),

            .bucket_offsets_offset = bucket_offsets_offset,
            .bucket_lengths_offset = bucket_lengths_offset,
            .labels_offset = labels_offset,
            .vectors_offset = vectors_offset,
        };

        var pos: usize = 0;

        try writer.writeAll(std.mem.asBytes(&header));
        pos += @sizeOf(Header);

        try seekTo(writer, &pos, bucket_offsets_offset);
        try writer.writeAll(std.mem.sliceAsBytes(self.buckets_offsets));
        pos += bucket_offsets_size;

        try seekTo(writer, &pos, bucket_lengths_offset);
        try writer.writeAll(std.mem.sliceAsBytes(self.buckets_lengths));
        pos += bucket_lengths_size;

        try seekTo(writer, &pos, vectors_offset);
        try writer.writeAll(std.mem.sliceAsBytes(self.vectors));
        pos += vectors_size;

        try seekTo(writer, &pos, labels_offset);

        var frauds: u32 = 0;
        var legits: u32 = 0;
        var total: u32 = 0;
        for (self.labels) |label| {
            const v: u8 = @intFromBool(label);
            try writer.writeAll(&.{v});
            if (label) {
                legits += 1;
            } else {
                frauds += 1;
            }
            total += 1;
        }

        std.debug.print("DM: total={},frauds={d},legits={d}\n", .{ total, frauds, legits });
    }
};

pub fn parseDatabase(file_name: []const u8, allocator: std.mem.Allocator, io: std.Io) !Database {
    const file = try std.Io.Dir.cwd().openFile(io, file_name, .{});
    errdefer file.close(io);

    const stat = try file.stat(io);
    const size = stat.size;

    const memory = try std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{
            .TYPE = .PRIVATE,
        },
        file.handle,
        0,
    );

    const base: [*]const u8 = @ptrCast(memory.ptr);
    const header: *const Header = @ptrCast(@alignCast(base));

    if (header.magic != magic)
        return error.InvalidMagic;

    if (header.version != 1)
        return error.InvalidVersion;

    const bucket_offsets_ptr: [*]const u32 = @ptrCast(@alignCast(base + header.bucket_offsets_offset));
    const bucket_lengths_ptr: [*]const u32 = @ptrCast(@alignCast(base + header.bucket_lengths_offset));
    const vectors_ptr: [*]const Vec = @ptrCast(@alignCast(base + header.vectors_offset));

    const labels_ptr: [*]const u8 = @ptrCast(@alignCast(base + header.labels_offset));

    const labels_bytes = labels_ptr[0..header.vector_count];

    var labels = try allocator.alloc(
        bool,
        header.vector_count,
    );

    var frauds: u32 = 0;
    var legits: u32 = 0;
    for (labels_bytes, 0..) |v, i| {
        labels[i] = v != 0;
        if (v == 0) {
            frauds += 1;
        } else {
            legits += 1;
        }
    }

    std.debug.print("OPEN: legits={d}, frauds={d}\n", .{ legits, frauds });

    return .{
        .buckets_lengths = bucket_lengths_ptr[0..header.bucket_count],
        .buckets_offsets = bucket_offsets_ptr[0..header.bucket_count],
        .vectors = vectors_ptr[0..header.vector_count],
        .labels = labels,
    };
}
