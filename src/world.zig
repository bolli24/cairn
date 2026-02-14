const std = @import("std");
const assert = std.debug.assert;

const za = @import("zalgebra");
const Vec3_i32 = za.Vec3_i32;

const lib = @import("mesh.zig");

pub const CHUNK_SIZE = 16;

pub const Block = enum(u1) { air = 0, ground };

pub const BoxI = struct { min: Vec3_i32, max: Vec3_i32 };

pub const World = struct {
    const Self = @This();
    chunks: std.AutoHashMap(Vec3_i32, *Chunk),

    fn init(allocator: std.mem.Allocator) World {
        return .{ .chunks = .init(allocator) };
    }

    fn deinit(self: *Self) void {
        self.chunks.deinit();
    }

    fn get_block(self: *const World, world_pos: Vec3_i32) Block {
        const chunk_pos = Vec3_i32.new(
            @divFloor(world_pos.x(), CHUNK_SIZE),
            @divFloor(world_pos.y(), CHUNK_SIZE),
            @divFloor(world_pos.z(), CHUNK_SIZE),
        );
        const chunk = self.chunks.get(chunk_pos) orelse return .air;
        const local = Vec3_i32.new(
            @mod(world_pos.x(), CHUNK_SIZE),
            @mod(world_pos.y(), CHUNK_SIZE),
            @mod(world_pos.z(), CHUNK_SIZE),
        );
        return chunk.get_block(local);
    }
};

pub const Chunk = struct {
    const Self = @This();
    pos: za.Vec3_i32,
    _blocks: [CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]Block = .{.{.{.air} ** CHUNK_SIZE} ** CHUNK_SIZE} ** CHUNK_SIZE,
    mesh: lib.Mesh = .{ .color = .one() },

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.mesh.deinit(allocator);
    }

    // Each face: 4 vertices (CCW winding from outside), 1 normal
    const Face = struct {
        verts: [4][3]f32,
        normal: [3]f32,
    };

    const face_dirs = [6][3]i32{
        .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 },
    };

    const faces = [6]Face{
        // +X
        .{ .verts = .{ .{ 1, 0, 1 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 } }, .normal = .{ 1, 0, 0 } },
        // -X
        .{ .verts = .{ .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 0, 1, 0 } }, .normal = .{ -1, 0, 0 } },
        // +Y
        .{ .verts = .{ .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 }, .{ 0, 1, 0 } }, .normal = .{ 0, 1, 0 } },
        // -Y
        .{ .verts = .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 0, 0, 1 } }, .normal = .{ 0, -1, 0 } },
        // +Z
        .{ .verts = .{ .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 } }, .normal = .{ 0, 0, 1 } },
        // -Z
        .{ .verts = .{ .{ 1, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 } }, .normal = .{ 0, 0, -1 } },
    };

    pub fn update_mesh(self: *Self, allocator: std.mem.Allocator) void {
        self.mesh.vertices.clearRetainingCapacity();
        self.mesh.indices.clearRetainingCapacity();
        self.mesh.normals.clearRetainingCapacity();
        self.mesh.wireframe_indices.clearRetainingCapacity();

        for (0..CHUNK_SIZE) |x| {
            for (0..CHUNK_SIZE) |y| {
                for (0..CHUNK_SIZE) |z| {
                    if (self._blocks[x][y][z] == .air) continue;

                    const fx: f32 = @floatFromInt(x);
                    const fy: f32 = @floatFromInt(y);
                    const fz: f32 = @floatFromInt(z);

                    for (faces, 0..) |face, i| {
                        const dir = face_dirs[i];
                        const nx: i32 = @as(i32, @intCast(x)) + dir[0];
                        const ny: i32 = @as(i32, @intCast(y)) + dir[1];
                        const nz: i32 = @as(i32, @intCast(z)) + dir[2];

                        // Skip face if neighbor is within bounds and solid
                        if (nx >= 0 and nx < CHUNK_SIZE and
                            ny >= 0 and ny < CHUNK_SIZE and
                            nz >= 0 and nz < CHUNK_SIZE)
                        {
                            if (self._blocks[@intCast(nx)][@intCast(ny)][@intCast(nz)] != .air) continue;
                        }

                        const base: u16 = @intCast(self.mesh.vertices.items.len);
                        for (face.verts) |v| {
                            self.mesh.vertices.append(allocator, za.Vec3.new(v[0] + fx, v[1] + fy, v[2] + fz)) catch return;
                            self.mesh.normals.append(allocator, za.Vec3.new(face.normal[0], face.normal[1], face.normal[2])) catch return;
                        }
                        // Two triangles: 0-1-2, 0-2-3
                        self.mesh.indices.appendSlice(allocator, &.{ base, base + 1, base + 2, base, base + 2, base + 3 }) catch return;
                        // Wireframe: edges of both triangles (0-1-2, 0-2-3)
                        self.mesh.wireframe_indices.appendSlice(allocator, &.{
                            base, base + 1, base + 1, base + 2, base + 2, base,
                            base, base + 2, base + 2, base + 3, base + 3, base,
                        }) catch return;
                    }
                }
            }
        }

        self.mesh.upload();
    }

    pub fn set_block(self: *Self, allocator: std.mem.Allocator, pos: za.Vec3_usize, block: Block) void {
        assert(pos.x() < CHUNK_SIZE);
        assert(pos.y() < CHUNK_SIZE);
        assert(pos.z() < CHUNK_SIZE);

        self._blocks[pos.x()][pos.y()][pos.z()] = block;

        self.update_mesh(allocator);
    }

    pub fn set_blocks(self: *Self, allocator: std.mem.Allocator, box: BoxI, block: Block) void {
        const min_x: usize = @intCast(@max(box.min.x(), 0));
        const min_y: usize = @intCast(@max(box.min.y(), 0));
        const min_z: usize = @intCast(@max(box.min.z(), 0));
        const max_x: usize = @intCast(@min(box.max.x(), CHUNK_SIZE));
        const max_y: usize = @intCast(@min(box.max.y(), CHUNK_SIZE));
        const max_z: usize = @intCast(@min(box.max.z(), CHUNK_SIZE));

        for (min_x..max_x) |x| {
            for (min_y..max_y) |y| {
                for (min_z..max_z) |z| {
                    self._blocks[x][y][z] = block;
                }
            }
        }

        self.update_mesh(allocator);
    }
};
