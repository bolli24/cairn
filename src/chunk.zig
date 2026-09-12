const std = @import("std");
const assert = std.debug.assert;

const za = @import("zalgebra");
const Vec3_i32 = za.Vec3_i32;
const Vec3 = za.Vec3;

const Mesh = @import("mesh.zig");
const Terrain = @import("terrain.zig");
const CHUNK_SIZE = Terrain.CHUNK_SIZE;
const Block = Terrain.Block;
const RemeshStats = Terrain.RemeshStats;
const BoxI = Terrain.BoxI;
const MeshJob = Terrain.Chunk.Job;

pub const Blocks = [CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]Block;
pub const Overlay = std.AutoHashMap(Vec3_i32, *Blocks);

const Self = @This();
pos: za.Vec3_i32,
_blocks: [CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]Block = .{.{.{.air} ** CHUNK_SIZE} ** CHUNK_SIZE} ** CHUNK_SIZE,
mesh: Mesh = .{ .color = .one() },

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.mesh.deinit(allocator);
}

pub fn get_block(self: *const Self, local_pos: Vec3_i32) Block {
    const x: usize = @intCast(local_pos.x());
    const y: usize = @intCast(local_pos.y());
    const z: usize = @intCast(local_pos.z());
    return self._blocks[x][y][z];
}

// Each face: 4 vertices (CCW winding from outside), 1 fallback normal
// vert_neighbors: for each vertex, [side1, side2, corner] block offsets for AO sampling.
// All offsets include the face normal so they sample at the correct face plane.
const Face = struct {
    verts: [4][3]f32,
    vert_neighbors: [4][3][3]i32,
    normal: [3]f32,
};

const face_dirs = [6][3]i32{
    .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 },
};

const faces = [6]Face{
    // +X face — normal (+1,0,0), face plane at x=bx+1
    .{
        .verts = .{ .{ 1, 0, 1 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 } },
        .vert_neighbors = .{
            .{ .{ 1, -1, 0 }, .{ 1, 0, 1 }, .{ 1, -1, 1 } }, // (1,0,1)
            .{ .{ 1, -1, 0 }, .{ 1, 0, -1 }, .{ 1, -1, -1 } }, // (1,0,0)
            .{ .{ 1, 1, 0 }, .{ 1, 0, -1 }, .{ 1, 1, -1 } }, // (1,1,0)
            .{ .{ 1, 1, 0 }, .{ 1, 0, 1 }, .{ 1, 1, 1 } }, // (1,1,1)
        },
        .normal = .{ 1, 0, 0 },
    },
    // -X face — normal (-1,0,0), face plane at x=bx
    .{
        .verts = .{ .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 0, 1, 0 } },
        .vert_neighbors = .{
            .{ .{ -1, -1, 0 }, .{ -1, 0, -1 }, .{ -1, -1, -1 } }, // (0,0,0)
            .{ .{ -1, -1, 0 }, .{ -1, 0, 1 }, .{ -1, -1, 1 } }, // (0,0,1)
            .{ .{ -1, 1, 0 }, .{ -1, 0, 1 }, .{ -1, 1, 1 } }, // (0,1,1)
            .{ .{ -1, 1, 0 }, .{ -1, 0, -1 }, .{ -1, 1, -1 } }, // (0,1,0)
        },
        .normal = .{ -1, 0, 0 },
    },
    // +Y face — normal (0,+1,0), face plane at y=by+1
    .{
        .verts = .{ .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 }, .{ 0, 1, 0 } },
        .vert_neighbors = .{
            .{ .{ -1, 1, 0 }, .{ 0, 1, 1 }, .{ -1, 1, 1 } }, // (0,1,1)
            .{ .{ 1, 1, 0 }, .{ 0, 1, 1 }, .{ 1, 1, 1 } }, // (1,1,1)
            .{ .{ 1, 1, 0 }, .{ 0, 1, -1 }, .{ 1, 1, -1 } }, // (1,1,0)
            .{ .{ -1, 1, 0 }, .{ 0, 1, -1 }, .{ -1, 1, -1 } }, // (0,1,0)
        },
        .normal = .{ 0, 1, 0 },
    },
    // -Y face — normal (0,-1,0), face plane at y=by
    .{
        .verts = .{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 0, 0, 1 } },
        .vert_neighbors = .{
            .{ .{ -1, -1, 0 }, .{ 0, -1, -1 }, .{ -1, -1, -1 } }, // (0,0,0)
            .{ .{ 1, -1, 0 }, .{ 0, -1, -1 }, .{ 1, -1, -1 } }, // (1,0,0)
            .{ .{ 1, -1, 0 }, .{ 0, -1, 1 }, .{ 1, -1, 1 } }, // (1,0,1)
            .{ .{ -1, -1, 0 }, .{ 0, -1, 1 }, .{ -1, -1, 1 } }, // (0,0,1)
        },
        .normal = .{ 0, -1, 0 },
    },
    // +Z face — normal (0,0,+1), face plane at z=bz+1
    .{
        .verts = .{ .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 } },
        .vert_neighbors = .{
            .{ .{ -1, 0, 1 }, .{ 0, -1, 1 }, .{ -1, -1, 1 } }, // (0,0,1)
            .{ .{ 1, 0, 1 }, .{ 0, -1, 1 }, .{ 1, -1, 1 } }, // (1,0,1)
            .{ .{ 1, 0, 1 }, .{ 0, 1, 1 }, .{ 1, 1, 1 } }, // (1,1,1)
            .{ .{ -1, 0, 1 }, .{ 0, 1, 1 }, .{ -1, 1, 1 } }, // (0,1,1)
        },
        .normal = .{ 0, 0, 1 },
    },
    // -Z face — normal (0,0,-1), face plane at z=bz
    .{
        .verts = .{ .{ 1, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 } },
        .vert_neighbors = .{
            .{ .{ 1, 0, -1 }, .{ 0, -1, -1 }, .{ 1, -1, -1 } }, // (1,0,0)
            .{ .{ -1, 0, -1 }, .{ 0, -1, -1 }, .{ -1, -1, -1 } }, // (0,0,0)
            .{ .{ -1, 0, -1 }, .{ 0, 1, -1 }, .{ -1, 1, -1 } }, // (0,1,0)
            .{ .{ 1, 0, -1 }, .{ 0, 1, -1 }, .{ 1, 1, -1 } }, // (1,1,0)
        },
        .normal = .{ 0, 0, -1 },
    },
};

pub fn update_mesh(self: *Self, allocator: std.mem.Allocator) void {
    self.update_mesh_with_overlay(allocator, null, null);
}

fn is_solid(blocks: *const Blocks, terrain: ?*const Terrain, overlay: ?*const Overlay, chunk_origin: Vec3_i32, x: i32, y: i32, z: i32) bool {
    if (x < 0 or x >= CHUNK_SIZE or y < 0 or y >= CHUNK_SIZE or z < 0 or z >= CHUNK_SIZE) {
        const wx = chunk_origin.x() + x;
        const wy = chunk_origin.y() + y;
        const wz = chunk_origin.z() + z;
        const world_pos = Vec3_i32.new(wx, wy, wz);
        const neighbor_chunk_pos = Terrain.world_to_chunk_pos(world_pos);
        const local_pos = Terrain.world_to_local_pos(world_pos);
        if (overlay) |ov| {
            if (ov.get(neighbor_chunk_pos)) |neighbor_blocks| {
                return neighbor_blocks[@intCast(local_pos.x())][@intCast(local_pos.y())][@intCast(local_pos.z())] != .air;
            }
        }
        if (terrain) |t| {
            return t.get_block(world_pos) != .air;
        }
        return false;
    }
    return blocks[@intCast(x)][@intCast(y)][@intCast(z)] != .air;
}

fn vertex_ao(
    vert: usize,
    x: usize,
    y: usize,
    z: usize,
    face: Face,
    blocks: *const Blocks,
    terrain: ?*const Terrain,
    overlay: ?*const Overlay,
    chunk_origin: Vec3_i32,
) f32 {
    const n = face.vert_neighbors[vert];
    const bx: i32 = @intCast(x);
    const by: i32 = @intCast(y);
    const bz: i32 = @intCast(z);

    const side1 = is_solid(blocks, terrain, overlay, chunk_origin, bx + n[0][0], by + n[0][1], bz + n[0][2]);
    const side2 = is_solid(blocks, terrain, overlay, chunk_origin, bx + n[1][0], by + n[1][1], bz + n[1][2]);
    const corner = is_solid(blocks, terrain, overlay, chunk_origin, bx + n[2][0], by + n[2][1], bz + n[2][2]);

    if (side1 and side2) {
        return 0.0;
    }
    const occlusion = @as(f32, @floatFromInt(@intFromBool(side1))) +
        @as(f32, @floatFromInt(@intFromBool(side2))) +
        @as(f32, @floatFromInt(@intFromBool(corner)));
    return (3.0 - occlusion) / 3.0;
}

fn surface_normal_estimate(
    x: usize,
    y: usize,
    z: usize,
    blocks: *const Blocks,
    terrain: ?*const Terrain,
    overlay: ?*const Overlay,
    chunk_origin: Vec3_i32,
) Vec3 {
    const bx: i32 = @intCast(x);
    const by: i32 = @intCast(y);
    const bz: i32 = @intCast(z);

    var solid_x: f32 = 0.0;
    var solid_y: f32 = 0.0;
    var solid_z: f32 = 0.0;

    var dx: i32 = -1;
    while (dx <= 1) : (dx += 1) {
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dz: i32 = -1;
            while (dz <= 1) : (dz += 1) {
                if (dx == 0 and dy == 0 and dz == 0) continue;
                if (!is_solid(
                    blocks,
                    terrain,
                    overlay,
                    chunk_origin,
                    bx + dx,
                    by + dy,
                    bz + dz,
                )) continue;

                solid_x += @floatFromInt(dx);
                solid_y += @floatFromInt(dy);
                solid_z += @floatFromInt(dz);
            }
        }
    }

    return Vec3.new(-solid_x, -solid_y, -solid_z);
}

fn face_surface_normal(estimate: Vec3, face_normal: [3]f32) Vec3 {
    const fallback = Vec3.new(face_normal[0], face_normal[1], face_normal[2]);
    var nx = estimate.x();
    var ny = estimate.y();
    var nz = estimate.z();
    const len_sq = nx * nx + ny * ny + nz * nz;
    if (len_sq <= 0.000001) return fallback;

    const inv_len = 1.0 / @sqrt(len_sq);
    nx *= inv_len;
    ny *= inv_len;
    nz *= inv_len;

    const facing = nx * face_normal[0] + ny * face_normal[1] + nz * face_normal[2];
    if (facing <= 0.0) return fallback;

    return Vec3.new(nx, ny, nz);
}

fn face_rotation(chunk_origin: Vec3_i32, x: usize, y: usize, z: usize) usize {
    const wx = chunk_origin.x() + @as(i32, @intCast(x));
    const wy = chunk_origin.y() + @as(i32, @intCast(y));
    const wz = chunk_origin.z() + @as(i32, @intCast(z));

    var h: u32 = 0;
    h +%= @as(u32, @bitCast(wx)) *% 73856093;
    h +%= @as(u32, @bitCast(wy)) *% 19349663;
    h +%= @as(u32, @bitCast(wz)) *% 83492791;

    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;

    return @intCast(h & 3);
}

pub fn update_mesh_with_overlay(
    self: *Self,
    allocator: std.mem.Allocator,
    terrain: ?*const Terrain,
    overlay: ?*const Overlay,
) void {
    const remesh_start = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
    defer {
        const remesh_end = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
        Terrain.remesh_stats.record(@intCast(remesh_start.durationTo(remesh_end).raw.toNanoseconds()));
    }

    self.build_mesh(allocator, terrain, overlay) catch return;
    self.mesh.upload();
}

// TODO: maybe make terrain not an optional pointer
pub fn build_mesh(self: *Self, allocator: std.mem.Allocator, terrain: ?*const Terrain, overlay: ?*const Overlay) std.mem.Allocator.Error!void {
    self.mesh.vertices.clearRetainingCapacity();
    self.mesh.indices.clearRetainingCapacity();
    self.mesh.wireframe_indices.clearRetainingCapacity();

    const blocks: *const Blocks = if (overlay) |ov| ov.get(self.pos) orelse &self._blocks else &self._blocks;
    const chunk_origin = Vec3_i32.new(
        self.pos.x() * CHUNK_SIZE,
        self.pos.y() * CHUNK_SIZE,
        self.pos.z() * CHUNK_SIZE,
    );

    for (0..CHUNK_SIZE) |x| {
        for (0..CHUNK_SIZE) |y| {
            for (0..CHUNK_SIZE) |z| {
                if (blocks[x][y][z] == .air) continue;

                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                const fz: f32 = @floatFromInt(z);
                var normal_estimate: ?Vec3 = null;

                for (faces, 0..) |face, i| {
                    const dir = face_dirs[i];
                    const nx: i32 = @as(i32, @intCast(x)) + dir[0];
                    const ny: i32 = @as(i32, @intCast(y)) + dir[1];
                    const nz: i32 = @as(i32, @intCast(z)) + dir[2];

                    if (is_solid(blocks, terrain, overlay, chunk_origin, nx, ny, nz)) continue;

                    const base: u16 = @intCast(self.mesh.vertices.items.len);
                    const estimate = normal_estimate orelse estimate: {
                        const computed = surface_normal_estimate(x, y, z, blocks, terrain, overlay, chunk_origin);
                        normal_estimate = computed;
                        break :estimate computed;
                    };
                    const normal = face_surface_normal(estimate, face.normal);
                    // const face_uvs = [4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
                    const face_uvs_v = [4][4][2]f32{
                        .{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } },
                        .{ .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 } },
                        .{ .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 } },
                        .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } },
                    };
                    // @as(usize, @intCast(self.pos.x())) * @as(usize, @intCast(self.pos.y())) * @as(usize, @intCast(self.pos.z()))
                    const variant = face_rotation(chunk_origin, x, y, z);
                    const face_uvs = face_uvs_v[variant];

                    var ao_vals: [4]f32 = undefined;
                    for (face.verts, 0..) |v, vert_i| {
                        ao_vals[vert_i] = vertex_ao(vert_i, x, y, z, face, blocks, terrain, overlay, chunk_origin);
                        try self.mesh.vertices.append(allocator, .{
                            .pos = za.Vec3.new(v[0] + fx, v[1] + fy, v[2] + fz),
                            .normal = normal,
                            .uv = za.Vec2.new(face_uvs[vert_i][0], face_uvs[vert_i][1]),
                            .ao = ao_vals[vert_i],
                        });
                    }

                    // Flip diagonal to avoid AO interpolation artifacts:
                    // default diagonal is 0-2; flip to 1-3 when it has greater total AO.
                    const flip = ao_vals[0] + ao_vals[2] > ao_vals[1] + ao_vals[3];
                    if (!flip) {
                        try self.mesh.indices.appendSlice(allocator, &.{ base + 1, base + 2, base + 3, base + 1, base + 3, base });
                    } else {
                        try self.mesh.indices.appendSlice(allocator, &.{ base, base + 1, base + 2, base, base + 2, base + 3 });
                    }
                }
            }
        }
    }

    if (self.mesh.vertices.items.len > 0) {
        try self.mesh.update_wireframe(allocator);
    }
}
