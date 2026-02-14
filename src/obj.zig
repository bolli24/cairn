const std = @import("std");
const za = @import("zalgebra");
const Vec3 = za.Vec3;
const lib = @import("mesh.zig");

const BUF_LEN = 1024;

pub fn load_mesh_from_obj(allocator: std.mem.Allocator, file_path: []const u8) !lib.Mesh {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var read_buf: [BUF_LEN]u8 = undefined;
    var line_buf: [BUF_LEN]u8 = undefined;

    var reader = file.reader(&read_buf);
    var writer = std.io.Writer.fixed(&line_buf);

    var raw_positions: std.ArrayList(Vec3) = .empty;
    defer raw_positions.deinit(allocator);
    var raw_normals: std.ArrayList(Vec3) = .empty;
    defer raw_normals.deinit(allocator);

    var mesh = lib.Mesh{};

    while (true) {
        _ = reader.interface.streamDelimiter(&writer, '\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (writer.end > 0) {
                    processLine(allocator, line_buf[0..writer.end], &raw_positions, &raw_normals, &mesh) catch {};
                }
                break;
            },
            else => return err,
        };

        const line = line_buf[0..writer.end];
        try processLine(allocator, line, &raw_positions, &raw_normals, &mesh);

        reader.interface.toss(1);
        writer.end = 0;
    }

    std.debug.print("Loaded {} vertices, {} indices\n", .{ mesh.vertices.items.len, mesh.indices.items.len });
    return mesh;
}

fn processLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    raw_positions: *std.ArrayList(Vec3),
    raw_normals: *std.ArrayList(Vec3),
    mesh: *lib.Mesh,
) !void {
    if (line.len == 0) return;

    switch (line[0]) {
        'v' => {
            if (line.len > 2 and line[1] == ' ') {
                if (parseVec3(line[2..])) |v| {
                    try raw_positions.append(allocator, v);
                }
            } else if (line.len > 3 and line[1] == 'n' and line[2] == ' ') {
                if (parseVec3(line[3..])) |n| {
                    try raw_normals.append(allocator, n);
                }
            }
        },
        'f' => {
            if (line.len > 2 and line[1] == ' ') {
                try parseFace(allocator, line[2..], raw_positions.items, raw_normals.items, mesh);
            }
        },
        else => {},
    }
}

fn parseVec3(data: []const u8) ?Vec3 {
    var it = std.mem.tokenizeScalar(u8, data, ' ');
    const x = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
    const y = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
    const z = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
    return Vec3.new(x, y, z);
}

fn parseFaceVertex(group: []const u8) ?struct { pos_idx: u32, norm_idx: ?u32 } {
    var it = std.mem.splitScalar(u8, group, '/');

    const pos_str = it.next() orelse return null;
    if (pos_str.len == 0) return null;
    const pos_idx = (std.fmt.parseInt(u32, pos_str, 10) catch return null) - 1;

    _ = it.next(); // skip texcoord index

    var norm_idx: ?u32 = null;
    if (it.next()) |norm_str| {
        if (norm_str.len > 0) {
            norm_idx = (std.fmt.parseInt(u32, norm_str, 10) catch return null) - 1;
        }
    }

    return .{ .pos_idx = pos_idx, .norm_idx = norm_idx };
}

fn parseFace(
    allocator: std.mem.Allocator,
    data: []const u8,
    raw_positions: []const Vec3,
    raw_normals: []const Vec3,
    mesh: *lib.Mesh,
) !void {
    var face: [4]u16 = undefined;
    var count: usize = 0;

    var it = std.mem.tokenizeScalar(u8, data, ' ');
    while (it.next()) |group| {
        if (count >= 4) break;
        const fv = parseFaceVertex(group) orelse return;

        if (fv.pos_idx >= raw_positions.len) return;

        const idx: u16 = @intCast(mesh.vertices.items.len);
        const normal = if (fv.norm_idx) |ni| (if (ni < raw_normals.len) raw_normals[ni] else Vec3.zero()) else Vec3.zero();
        try mesh.vertices.append(allocator, .{
            .pos = raw_positions[fv.pos_idx],
            .normal = normal,
        });

        face[count] = idx;
        count += 1;
    }

    if (count >= 3) {
        try mesh.indices.appendSlice(allocator, &.{ face[0], face[1], face[2] });
    }
    if (count >= 4) {
        try mesh.indices.appendSlice(allocator, &.{ face[0], face[2], face[3] });
    }
}

test "load_mesh_from_obj parses vertices, normals and indices" {
    var data = try load_mesh_from_obj(std.testing.allocator, "res/suzanne.obj");
    defer data.deinit(std.testing.allocator);
    try std.testing.expect(data.vertices.items.len > 0);
    try std.testing.expect(data.indices.items.len > 0);
    try std.testing.expect(data.indices.items.len % 3 == 0);
    std.debug.print("First vertex: ({d}, {d}, {d})\n", .{ data.vertices.items[0].pos.x(), data.vertices.items[0].pos.y(), data.vertices.items[0].pos.z() });
    std.debug.print("First normal: ({d}, {d}, {d})\n", .{ data.vertices.items[0].normal.x(), data.vertices.items[0].normal.y(), data.vertices.items[0].normal.z() });
    std.debug.print("Triangles: {}\n", .{data.indices.items.len / 3});
}
