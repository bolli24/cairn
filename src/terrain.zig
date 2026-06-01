const std = @import("std");
const assert = std.debug.assert;

const za = @import("zalgebra");
const Vec3_i32 = za.Vec3_i32;
const Vec3 = za.Vec3;

const fastnoise = @import("fastnoise");

const lib = @import("mesh.zig");

pub const CHUNK_SIZE = 16;

pub const Block = enum(u1) { air = 0, ground };

pub const BoxI = struct { min: Vec3_i32, max: Vec3_i32 };

pub const RaycastHit = struct {
    pos: Vec3_i32,
    previous: Vec3_i32,
    block: Block,
};

pub const ChunkBlocks = [CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]Block;
pub const ChunkOverlay = std.AutoHashMap(Vec3_i32, *ChunkBlocks);

pub var remesh_stats: RemeshStats = .{};

pub const Terrain = struct {
    const Self = @This();
    chunks: std.AutoHashMap(Vec3_i32, Chunk),
    allocator: std.mem.Allocator,
    overlay: ?*const ChunkOverlay = null,

    pub fn generate_with_noise(allocator: std.mem.Allocator, noise: fastnoise.Noise(f32), size: za.Vec3_usize) Self {
        var self = Self.init(allocator);

        for (0..size.x()) |x| {
            for (0..size.y()) |y| {
                for (0..size.z()) |z| {
                    const chunk_pos = Vec3_i32.new(@intCast(x), @intCast(y), @intCast(z));
                    const world_pos = Vec3.new(@floatFromInt(x * CHUNK_SIZE), @floatFromInt(y * CHUNK_SIZE), @floatFromInt(z * CHUNK_SIZE));
                    const chunk = Chunk{ .pos = chunk_pos, .mesh = .{ .transform = .{
                        .position = world_pos,
                    } } };

                    self.chunks.put(chunk_pos, chunk) catch continue;
                }
            }
        }

        const total_height: f32 = @floatFromInt(size.y() * CHUNK_SIZE);

        for (0..size.x()) |cx| {
            for (0..size.z()) |cz| {
                for (0..CHUNK_SIZE) |lx| {
                    for (0..CHUNK_SIZE) |lz| {
                        const wx: f32 = @floatFromInt(cx * CHUNK_SIZE + lx);
                        const wz: f32 = @floatFromInt(cz * CHUNK_SIZE + lz);
                        const n = noise.genNoise2D(wx, wz);
                        // Map noise from [-1, 1] to [0, 1], then scale to total height
                        const height: usize = @intFromFloat((n + 1.0) * 0.5 * total_height);

                        for (0..height) |wy| {
                            const cy = wy / CHUNK_SIZE;
                            const ly = wy % CHUNK_SIZE;
                            const chunk_pos = Vec3_i32.new(@intCast(cx), @intCast(cy), @intCast(cz));
                            const chunk = self.chunks.getPtr(chunk_pos) orelse continue;
                            chunk._blocks[lx][ly][lz] = .ground;
                        }
                    }
                }
            }
        }

        // Remesh all chunks after setting blocks
        var it = self.chunks.valueIterator();
        while (it.next()) |chunk_ptr| {
            chunk_ptr.update_mesh_with_overlay(allocator, &self, null);
        }

        return self;
    }

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .chunks = std.AutoHashMap(Vec3_i32, Chunk).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |chunk_ptr| {
            chunk_ptr.deinit(self.allocator);
        }
        self.chunks.deinit();
    }

    pub fn add_chunk(self: *Self, pos: Vec3_i32) !*Chunk {
        var chunk = Chunk{ .pos = pos };
        chunk.mesh.transform.position = Vec3.new(
            @as(f32, @floatFromInt(pos.x())) * CHUNK_SIZE,
            @as(f32, @floatFromInt(pos.y())) * CHUNK_SIZE,
            @as(f32, @floatFromInt(pos.z())) * CHUNK_SIZE,
        );
        try self.chunks.put(pos, chunk);
        return self.chunks.getPtr(pos).?;
    }

    pub fn world_to_chunk_pos(world_pos: Vec3_i32) Vec3_i32 {
        return Vec3_i32.new(
            @divFloor(world_pos.x(), CHUNK_SIZE),
            @divFloor(world_pos.y(), CHUNK_SIZE),
            @divFloor(world_pos.z(), CHUNK_SIZE),
        );
    }

    pub fn world_to_local_pos(world_pos: Vec3_i32) Vec3_i32 {
        return Vec3_i32.new(
            @mod(world_pos.x(), CHUNK_SIZE),
            @mod(world_pos.y(), CHUNK_SIZE),
            @mod(world_pos.z(), CHUNK_SIZE),
        );
    }

    pub fn get_block(self: *const Self, world_pos: Vec3_i32) Block {
        const chunk = self.chunks.get(world_to_chunk_pos(world_pos)) orelse return .air;
        return chunk.get_block(world_to_local_pos(world_pos));
    }

    pub fn set_block(self: *Self, world_pos: Vec3_i32, block: Block, remesh: bool) void {
        const chunk = self.chunks.getPtr(world_to_chunk_pos(world_pos)) orelse return;
        const local = world_to_local_pos(world_pos);
        chunk._blocks[@intCast(local.x())][@intCast(local.y())][@intCast(local.z())] = block;

        if (remesh) {
            chunk.update_mesh_with_overlay(self.allocator, self, null);
        }
    }

    pub fn set_blocks(self: *Self, allocator: std.mem.Allocator, box: BoxI, block: Block, remesh: bool) void {
        const min_chunk = world_to_chunk_pos(box.min);
        const max_chunk = world_to_chunk_pos(Vec3_i32.new(box.max.x() - 1, box.max.y() - 1, box.max.z() - 1));

        var cx = min_chunk.x();
        while (cx <= max_chunk.x()) : (cx += 1) {
            var cy = min_chunk.y();
            while (cy <= max_chunk.y()) : (cy += 1) {
                var cz = min_chunk.z();
                while (cz <= max_chunk.z()) : (cz += 1) {
                    const chunk = self.chunks.getPtr(Vec3_i32.new(cx, cy, cz)) orelse continue;

                    // Clamp box to this chunk's local bounds
                    const chunk_world_x = cx * CHUNK_SIZE;
                    const chunk_world_y = cy * CHUNK_SIZE;
                    const chunk_world_z = cz * CHUNK_SIZE;

                    const lx_min: usize = @intCast(@max(box.min.x() - chunk_world_x, 0));
                    const ly_min: usize = @intCast(@max(box.min.y() - chunk_world_y, 0));
                    const lz_min: usize = @intCast(@max(box.min.z() - chunk_world_z, 0));
                    const lx_max: usize = @intCast(@min(box.max.x() - chunk_world_x, CHUNK_SIZE));
                    const ly_max: usize = @intCast(@min(box.max.y() - chunk_world_y, CHUNK_SIZE));
                    const lz_max: usize = @intCast(@min(box.max.z() - chunk_world_z, CHUNK_SIZE));

                    for (lx_min..lx_max) |lx| {
                        for (ly_min..ly_max) |ly| {
                            for (lz_min..lz_max) |lz| {
                                chunk._blocks[lx][ly][lz] = block;
                            }
                        }
                    }

                    if (remesh) {
                        chunk.update_mesh_with_overlay(allocator, self, null);
                    }
                }
            }
        }
    }

    /// Remesh the chunk that contains the given world position.
    pub fn remesh_at(self: *Self, world_pos: Vec3_i32) void {
        const chunk = self.chunks.getPtr(world_to_chunk_pos(world_pos)) orelse return;
        chunk.update_mesh_with_overlay(self.allocator, self, self.overlay);
    }

    pub fn raycast(self: *const Self, origin: Vec3, direction: Vec3, range: f32) ?RaycastHit {
        const end = origin.add(direction.norm().scale(range));
        // Unnormalized ray from start to end, matching the C++ reference
        const ray = end.sub(origin);

        // Current voxel (floor to block coordinates, bin_size = 1)
        var current = Vec3_i32.new(
            @intFromFloat(@floor(origin.x())),
            @intFromFloat(@floor(origin.y())),
            @intFromFloat(@floor(origin.z())),
        );

        const last = Vec3_i32.new(
            @intFromFloat(@floor(end.x())),
            @intFromFloat(@floor(end.y())),
            @intFromFloat(@floor(end.z())),
        );

        // Step direction per axis (+1 or -1)
        const step_x: i32 = if (ray.x() >= 0) 1 else -1;
        const step_y: i32 = if (ray.y() >= 0) 1 else -1;
        const step_z: i32 = if (ray.z() >= 0) 1 else -1;

        // Distance to next voxel boundary (bin_size = 1)
        const fstep_x: f32 = @floatFromInt(step_x);
        const fstep_y: f32 = @floatFromInt(step_y);
        const fstep_z: f32 = @floatFromInt(step_z);
        const cur_x: f32 = @floatFromInt(current.x());
        const cur_y: f32 = @floatFromInt(current.y());
        const cur_z: f32 = @floatFromInt(current.z());

        const next_boundary_x = (cur_x + fstep_x);
        const next_boundary_y = (cur_y + fstep_y);
        const next_boundary_z = (cur_z + fstep_z);

        // tMax: distance along ray to next voxel boundary per axis
        var t_max_x: f32 = if (ray.x() != 0) (next_boundary_x - origin.x()) / ray.x() else std.math.floatMax(f32);
        var t_max_y: f32 = if (ray.y() != 0) (next_boundary_y - origin.y()) / ray.y() else std.math.floatMax(f32);
        var t_max_z: f32 = if (ray.z() != 0) (next_boundary_z - origin.z()) / ray.z() else std.math.floatMax(f32);

        // tDelta: how far along ray to cross one voxel per axis
        const t_delta_x: f32 = if (ray.x() != 0) 1.0 / ray.x() * fstep_x else std.math.floatMax(f32);
        const t_delta_y: f32 = if (ray.y() != 0) 1.0 / ray.y() * fstep_y else std.math.floatMax(f32);
        const t_delta_z: f32 = if (ray.z() != 0) 1.0 / ray.z() * fstep_z else std.math.floatMax(f32);

        // Negative ray correction
        var diff = Vec3_i32.new(0, 0, 0);
        var neg_ray = false;
        if (current.x() != last.x() and ray.x() < 0) {
            diff = Vec3_i32.new(diff.x() - 1, diff.y(), diff.z());
            neg_ray = true;
        }
        if (current.y() != last.y() and ray.y() < 0) {
            diff = Vec3_i32.new(diff.x(), diff.y() - 1, diff.z());
            neg_ray = true;
        }
        if (current.z() != last.z() and ray.z() < 0) {
            diff = Vec3_i32.new(diff.x(), diff.y(), diff.z() - 1);
            neg_ray = true;
        }

        // Check starting voxel
        var previous = current;
        const start_block = self.get_block(current);
        if (start_block != .air) {
            return .{ .pos = current, .previous = current, .block = start_block };
        }

        if (neg_ray) {
            current = current.add(diff);
            const block = self.get_block(current);
            if (block != .air) {
                return .{ .pos = current, .previous = previous, .block = block };
            }
        }

        while (!std.meta.eql(last, current)) {
            previous = current;
            if (t_max_x < t_max_y) {
                if (t_max_x < t_max_z) {
                    current = Vec3_i32.new(current.x() + step_x, current.y(), current.z());
                    t_max_x += t_delta_x;
                } else {
                    current = Vec3_i32.new(current.x(), current.y(), current.z() + step_z);
                    t_max_z += t_delta_z;
                }
            } else {
                if (t_max_y < t_max_z) {
                    current = Vec3_i32.new(current.x(), current.y() + step_y, current.z());
                    t_max_y += t_delta_y;
                } else {
                    current = Vec3_i32.new(current.x(), current.y(), current.z() + step_z);
                    t_max_z += t_delta_z;
                }
            }

            const block = self.get_block(current);
            if (block != .air) {
                return .{ .pos = current, .previous = previous, .block = block };
            }
        }
        return null;
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

    fn is_solid(blocks: *const ChunkBlocks, terrain: ?*const Terrain, overlay: ?*const ChunkOverlay, chunk_origin: Vec3_i32, x: i32, y: i32, z: i32) bool {
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
        blocks: *const ChunkBlocks,
        terrain: ?*const Terrain,
        overlay: ?*const ChunkOverlay,
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
        blocks: *const ChunkBlocks,
        terrain: ?*const Terrain,
        overlay: ?*const ChunkOverlay,
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
                    if (!is_solid(blocks, terrain, overlay, chunk_origin, bx + dx, by + dy, bz + dz)) continue;

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

    pub fn update_mesh_with_overlay(self: *Self, allocator: std.mem.Allocator, terrain: ?*const Terrain, overlay: ?*const ChunkOverlay) void {
        const remesh_start = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
        defer {
            const remesh_end = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
            remesh_stats.record(@intCast(remesh_start.durationTo(remesh_end).raw.toNanoseconds()));
        }

        self.mesh.vertices.clearRetainingCapacity();
        self.mesh.indices.clearRetainingCapacity();
        self.mesh.wireframe_indices.clearRetainingCapacity();

        const blocks: *const ChunkBlocks = if (overlay) |ov| ov.get(self.pos) orelse &self._blocks else &self._blocks;
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
                        const face_uvs = [4][2]f32{ .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 } };
                        var ao_vals: [4]f32 = undefined;
                        for (face.verts, 0..) |v, vert_i| {
                            ao_vals[vert_i] = vertex_ao(vert_i, x, y, z, face, blocks, terrain, overlay, chunk_origin);
                            self.mesh.vertices.append(allocator, .{
                                .pos = za.Vec3.new(v[0] + fx, v[1] + fy, v[2] + fz),
                                .normal = normal,
                                .uv = za.Vec2.new(face_uvs[vert_i][0], face_uvs[vert_i][1]),
                                .ao = ao_vals[vert_i],
                            }) catch return;
                        }

                        // Flip diagonal to avoid AO interpolation artifacts:
                        // default diagonal is 0-2; flip to 1-3 when it has greater total AO.
                        const flip = ao_vals[0] + ao_vals[2] > ao_vals[1] + ao_vals[3];
                        if (!flip) {
                            self.mesh.indices.appendSlice(allocator, &.{ base + 1, base + 2, base + 3, base + 1, base + 3, base }) catch return;
                            self.mesh.wireframe_indices.appendSlice(allocator, &.{
                                base + 1, base + 2, base + 2, base + 3, base + 3, base + 1,
                                base + 1, base + 3, base + 3, base,     base,     base + 1,
                            }) catch return;
                        } else {
                            self.mesh.indices.appendSlice(allocator, &.{ base, base + 1, base + 2, base, base + 2, base + 3 }) catch return;
                            self.mesh.wireframe_indices.appendSlice(allocator, &.{
                                base, base + 1, base + 1, base + 2, base + 2, base,
                                base, base + 2, base + 2, base + 3, base + 3, base,
                            }) catch return;
                        }
                    }
                }
            }
        }

        if (self.mesh.vertices.items.len > 0) {
            self.mesh.upload();
        }
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

pub const RemeshStats = struct {
    const SAMPLE_COUNT = 10;

    samples: [SAMPLE_COUNT]u64 = [_]u64{0} ** SAMPLE_COUNT,
    next: usize = 0,
    count: usize = 0,
    last_process_nanos: u64 = 0,

    pub fn record(self: *@This(), nanos: u64) void {
        self.samples[self.next] = nanos;
        self.next = (self.next + 1) % SAMPLE_COUNT;
        self.count = @min(self.count + 1, SAMPLE_COUNT);
    }

    pub fn average_ms(self: *const @This()) f64 {
        if (self.count == 0) return 0.0;

        var total: u64 = 0;
        for (self.samples[0..self.count]) |sample| {
            total += sample;
        }

        return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(self.count)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    }

    pub fn record_process(self: *@This(), nanos: u64) void {
        self.last_process_nanos = nanos;
    }

    pub fn last_process_ms(self: *const @This()) f64 {
        return @as(f64, @floatFromInt(self.last_process_nanos)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    }
};

test "set_blocks within single chunk" {
    const allocator = std.testing.allocator;
    var terrain = Terrain.init(allocator);
    defer terrain.deinit();

    // Add a single chunk at origin
    terrain.chunks.put(Vec3_i32.new(0, 0, 0), Chunk{ .pos = Vec3_i32.new(0, 0, 0) }) catch unreachable;

    // Fill a 3x4x5 box
    terrain.set_blocks(allocator, .{
        .min = Vec3_i32.new(2, 3, 4),
        .max = Vec3_i32.new(5, 7, 9),
    }, .ground, false);

    // Blocks inside the box should be ground
    for (2..5) |x| {
        for (3..7) |y| {
            for (4..9) |z| {
                try std.testing.expectEqual(Block.ground, terrain.get_block(Vec3_i32.new(@intCast(x), @intCast(y), @intCast(z))));
            }
        }
    }

    // Blocks outside the box should still be air
    try std.testing.expectEqual(Block.air, terrain.get_block(Vec3_i32.new(1, 3, 4)));
    try std.testing.expectEqual(Block.air, terrain.get_block(Vec3_i32.new(5, 7, 9)));
    try std.testing.expectEqual(Block.air, terrain.get_block(Vec3_i32.new(0, 0, 0)));
}

test "set_blocks spanning multiple chunks" {
    const allocator = std.testing.allocator;
    var terrain = Terrain.init(allocator);
    defer terrain.deinit();

    // Add a 2x2x2 grid of chunks
    for (0..2) |cx| {
        for (0..2) |cy| {
            for (0..2) |cz| {
                const pos = Vec3_i32.new(@intCast(cx), @intCast(cy), @intCast(cz));
                terrain.chunks.put(pos, Chunk{ .pos = pos }) catch unreachable;
            }
        }
    }

    // Fill a box that spans from chunk (0,0,0) into chunk (1,1,1)
    terrain.set_blocks(allocator, .{
        .min = Vec3_i32.new(14, 14, 14),
        .max = Vec3_i32.new(18, 18, 18),
    }, .ground, false);

    // Verify blocks in chunk (0,0,0) — local (14,14,14) to (15,15,15)
    for (14..16) |x| {
        for (14..16) |y| {
            for (14..16) |z| {
                try std.testing.expectEqual(Block.ground, terrain.get_block(Vec3_i32.new(@intCast(x), @intCast(y), @intCast(z))));
            }
        }
    }

    // Verify blocks in chunk (1,1,1) — world (16,16,16) to (17,17,17)
    for (16..18) |x| {
        for (16..18) |y| {
            for (16..18) |z| {
                try std.testing.expectEqual(Block.ground, terrain.get_block(Vec3_i32.new(@intCast(x), @intCast(y), @intCast(z))));
            }
        }
    }

    // Verify a block just outside the box is air
    try std.testing.expectEqual(Block.air, terrain.get_block(Vec3_i32.new(13, 14, 14)));
    try std.testing.expectEqual(Block.air, terrain.get_block(Vec3_i32.new(18, 18, 18)));
}

test "set_blocks skips missing chunks" {
    const allocator = std.testing.allocator;
    var terrain = Terrain.init(allocator);
    defer terrain.deinit();

    // Only add chunk (0,0,0), not chunk (1,0,0)
    terrain.chunks.put(Vec3_i32.new(0, 0, 0), Chunk{ .pos = Vec3_i32.new(0, 0, 0) }) catch unreachable;

    // Box spans into chunk (1,0,0) which doesn't exist
    terrain.set_blocks(allocator, .{
        .min = Vec3_i32.new(14, 0, 0),
        .max = Vec3_i32.new(18, 2, 2),
    }, .ground, false);

    // Blocks in existing chunk should be set
    try std.testing.expectEqual(Block.ground, terrain.get_block(Vec3_i32.new(14, 0, 0)));
    try std.testing.expectEqual(Block.ground, terrain.get_block(Vec3_i32.new(15, 1, 1)));

    // Blocks in missing chunk should return air (default for missing chunk)
    try std.testing.expectEqual(Block.air, terrain.get_block(Vec3_i32.new(16, 0, 0)));
    try std.testing.expectEqual(Block.air, terrain.get_block(Vec3_i32.new(17, 1, 1)));
}
