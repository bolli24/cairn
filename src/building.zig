const std = @import("std");

const za = @import("zalgebra");
const Vec2 = za.Vec2;
const Vec3 = za.Vec3;
const Vec3_i32 = za.Vec3_i32;
const Vec4 = za.Vec4;

const sokol = @import("sokol");
const sapp = sokol.app;

const InputState = @import("input.zig").InputState;
const Camera = @import("camera.zig").Camera;
const Terrain = @import("terrain.zig");
const Block = Terrain.Block;
const Shapes = @import("shapes.zig").Shapes;
const Mesh = @import("mesh.zig");
const Vertex = Mesh.Vertex;
const Transform = Mesh.Transform;

const MARKER_COLOR = Vec4.new(1, 1, 0, 1);
const LINE_COLOR = Vec4.new(0, 1, 1, 1);
const CONFIRM_COLOR = Vec4.new(0, 1, 0, 1);
const LINE_THICKNESS: f32 = 0.15;
const RAYCAST_RANGE: f32 = 500.0;

const SEGMENT_LENGTH: f32 = 5.0;
const WIDTH: f32 = 0.5;
const HEIGHT: f32 = 0.8;
const VERTEX_OFFSETS = [_]Vec3{
    .new(-WIDTH / 2.0, 0.0, 0.0), //      a
    .new(WIDTH / 2.0, 0.0, 0.0), //       b
    .new(WIDTH / 2.0, 0.0, 0.0), //       b
    .new(WIDTH / 2.0, HEIGHT, 0.0), //    c
    .new(WIDTH / 2.0, HEIGHT, 0.0), //    c
    .new(-WIDTH / 2.0, HEIGHT, 0.0), //   d
    .new(-WIDTH / 2.0, HEIGHT, 0.0), //   d
    .new(-WIDTH / 2.0, 0.0, 0.0), //      a
};
const VERTS_PER_SEGMENT: usize = VERTEX_OFFSETS.len;
const FACES_PER_SEGMENT: usize = 2 * 4; // 2 faces per side
const CAP_VERTS_PER_END: usize = 4;
const CAP_VERTEX_COUNT: usize = CAP_VERTS_PER_END * 2;
const CAP_INDEX_COUNT: usize = 2 * 3 * 2; // 2 triangles per cap, 2 caps

pub const BuildingState = struct {
    const Self = @This();

    active: bool = false,
    pos1: ?Vec3_i32 = null,
    pos2: ?Vec3_i32 = null,
    prev_hit: ?Vec3_i32 = null,
    preview: EditPreview = undefined,
    preview_active: bool = false,

    mesh: Mesh,
    mesh_length: f32 = 0.0,
    mesh_segment_count: usize = 0,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .preview = EditPreview.init(allocator),
            .mesh = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.preview.deinit();
        self.mesh.deinit(self.allocator);
    }

    //  a - c   c, d - new vertices         c - at pos
    //  | / |
    //  b - d   a, b - existing vertices    d - offset

    pub fn add_segment(self: *Self) !void {
        _ = try self.mesh.vertices.addManyAsSlice(self.allocator, VERTS_PER_SEGMENT);

        if (self.mesh.vertices.items.len == VERTS_PER_SEGMENT) {
            return;
        }

        const p = @as(u16, @intCast(self.mesh.vertices.items.len - VERTS_PER_SEGMENT * 2)); // first index of previous segment vertices
        const c = @as(u16, @intCast(self.mesh.vertices.items.len - VERTS_PER_SEGMENT)); // first index of new segment vertices

        var indices: [FACES_PER_SEGMENT * 3]u16 = undefined;

        inline for (0..FACES_PER_SEGMENT / 2) |side| {
            const vi: u16 = @intCast(side * 2);
            const ii = side * 6;

            indices[ii..][0..3].* = .{ p + vi, c + vi + 1, c + vi };
            indices[ii + 3 ..][0..3].* = .{ p + vi, p + vi + 1, c + vi + 1 };
        }

        try self.mesh.indices.appendSlice(self.allocator, &indices);
    }

    pub fn update(self: *Self, input: *InputState, camera: *const Camera, terrain: *Terrain, shapes: *Shapes) void {
        if (input.key_pressed(.B)) {
            if (self.active) {
                self.revert_preview(terrain) catch |err| {
                    std.debug.print("ERROR: Could not hide preview: {s}\n", .{@errorName(err)});
                    return;
                };
            }
            self.active = !self.active;
            self.reset();
            return;
        }

        if (!self.active) return;

        if (input.key_pressed(.ESCAPE)) {
            self.revert_preview(terrain) catch |err| {
                std.debug.print("ERROR: Could not hide preview: {s}\n", .{@errorName(err)});
                return;
            };
            self.active = false;
            self.reset();
            return;
        }

        const hit = terrain.raycast(camera.screen_to_ray(input.mouse_pos, 500));

        if (self.pos1 == null) {
            // State: waiting for first point
            if (hit) |h| {
                draw_cube_marker(shapes, h.pos, MARKER_COLOR);
                if (input.mouse_pressed(.LEFT)) {
                    self.pos1 = h.pos;
                    self.mesh.transform.position = self.pos1.?.add(Vec3_i32.new(0, 3, 0)).cast(f32);
                }
            }
        } else if (self.pos2 == null) {
            // State: first point set, waiting for second point
            draw_cube_marker(shapes, self.pos1.?, MARKER_COLOR);

            if (hit) |h| {
                const cursor_f = h.pos.cast(f32);
                shapes.line_3d(
                    self.pos1.?.cast(f32).add(Vec3.new(0.5, 0.5, 0.5)),
                    cursor_f.add(Vec3.new(0.5, 0.5, 0.5)),
                    LINE_COLOR,
                    LINE_THICKNESS,
                );
                draw_cube_marker(shapes, h.pos, LINE_COLOR);

                if (self.prev_hit == null or !self.prev_hit.?.eql(h.pos)) {
                    if (self.preview_active) {
                        self.preview.hide(terrain) catch |err| {
                            std.debug.print("ERROR: Could not hide preview: {s}\n", .{@errorName(err)});
                            return;
                        };
                        self.preview_active = false;
                    }
                    self.preview.clear();
                    self.prev_hit = null;
                    const p1 = self.pos1.?.add(Vec3_i32.new(0, 3, 0));
                    const p2 = h.pos.add(Vec3_i32.new(0, 3, 0));
                    const p1f = p1.cast(f32);
                    const p2f = p2.cast(f32);
                    const dir = p2f.sub(p1f);

                    self.preview.add_block_path(terrain, p1, p2, 3.9, .air, .circle);
                    self.preview.show(terrain) catch |err| {
                        std.debug.print("ERROR: Could not show preview: {s}\n", .{@errorName(err)});
                        return;
                    };
                    self.preview_active = true;
                    self.prev_hit = h.pos;

                    const new_length = dir.length();
                    const segment_count: usize = @as(usize, @trunc(new_length / SEGMENT_LENGTH)) + 1;
                    const side_vertex_count = (segment_count + 1) * VERTS_PER_SEGMENT;
                    const vertex_count = side_vertex_count + CAP_VERTEX_COUNT;
                    const side_index_count = segment_count * FACES_PER_SEGMENT * 3;
                    const index_count = side_index_count + CAP_INDEX_COUNT;

                    if (self.mesh_segment_count > 0) {
                        const current_side_vertex_count = (self.mesh_segment_count + 1) * VERTS_PER_SEGMENT;
                        const current_side_index_count = self.mesh_segment_count * FACES_PER_SEGMENT * 3;
                        self.mesh.vertices.shrinkRetainingCapacity(current_side_vertex_count);
                        self.mesh.indices.shrinkRetainingCapacity(current_side_index_count);
                    }

                    if (self.mesh_segment_count > segment_count) {
                        self.mesh.vertices.shrinkRetainingCapacity(side_vertex_count);
                        self.mesh.indices.shrinkRetainingCapacity(side_index_count);
                    }

                    if (self.mesh_segment_count == 0) {
                        self.add_segment() catch return;
                    }

                    const forward = dir.norm();
                    const right = Vec3.new(0, 1, 0).cross(forward).norm();
                    const up = forward.cross(right).norm();

                    for (0..segment_count + 1) |i| {
                        if (i >= self.mesh_segment_count and i < segment_count) {
                            self.add_segment() catch return;
                        }

                        const pos = dir.scale(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segment_count)));

                        inline for (VERTEX_OFFSETS, 0..) |offset, j| {
                            const oriented_offset = right.scale(offset.x())
                                .add(up.scale(offset.y()))
                                .add(forward.scale(offset.z()));
                            const normal = switch (j / 2) {
                                0 => up.scale(-1),
                                1 => right,
                                2 => up,
                                3 => right.scale(-1),
                                else => unreachable,
                            };

                            self.mesh.vertices.items[i * VERTS_PER_SEGMENT + j] = .{
                                .pos = pos.add(oriented_offset),
                                .normal = normal,
                            };
                        }
                    }

                    const end_side_vertex = segment_count * VERTS_PER_SEGMENT;
                    const cap_side_vertices = [_]usize{ 0, 1, 3, 5 };
                    var start_cap_positions: [CAP_VERTS_PER_END]Vec3 = undefined;
                    var end_cap_positions: [CAP_VERTS_PER_END]Vec3 = undefined;
                    inline for (cap_side_vertices, 0..) |side_vertex, i| {
                        start_cap_positions[i] = self.mesh.vertices.items[side_vertex].pos;
                        end_cap_positions[i] = self.mesh.vertices.items[end_side_vertex + side_vertex].pos;
                    }

                    const cap_vertices = self.mesh.vertices.addManyAsSlice(self.allocator, CAP_VERTEX_COUNT) catch return;
                    inline for (0..CAP_VERTS_PER_END) |i| {
                        cap_vertices[i] = .{
                            .pos = start_cap_positions[i],
                            .normal = forward.scale(-1),
                        };
                        cap_vertices[CAP_VERTS_PER_END + i] = .{
                            .pos = end_cap_positions[i],
                            .normal = forward,
                        };
                    }

                    const start: u16 = @intCast(side_vertex_count);
                    const end: u16 = start + @as(u16, CAP_VERTS_PER_END);
                    const cap_indices = [_]u16{
                        start + 0, start + 2, start + 1,
                        start + 0, start + 3, start + 2,
                        end + 0,   end + 1,   end + 2,
                        end + 0,   end + 2,   end + 3,
                    };
                    self.mesh.indices.appendSlice(self.allocator, &cap_indices) catch return;

                    std.debug.assert(self.mesh.vertices.items.len == vertex_count);
                    std.debug.assert(self.mesh.indices.items.len == index_count);

                    self.mesh.update_wireframe(self.allocator) catch return;
                    self.mesh.upload();
                    self.mesh_segment_count = segment_count;
                    self.mesh_length = new_length;
                }

                if (input.mouse_pressed(.LEFT)) {
                    self.pos2 = h.pos;
                    self.prev_hit = null;
                    // Preview stays applied; it becomes the confirm preview
                }
            }
        } else {
            const p1f = self.pos1.?.cast(f32);
            const p2f = self.pos2.?.cast(f32);
            draw_cube_marker(shapes, self.pos1.?, CONFIRM_COLOR);
            draw_cube_marker(shapes, self.pos2.?, CONFIRM_COLOR);
            shapes.line_3d(p1f.add(Vec3.new(0.5, 0.5, 0.5)), p2f.add(Vec3.new(0.5, 0.5, 0.5)), CONFIRM_COLOR, LINE_THICKNESS);

            if (input.key_pressed(.SPACE)) {
                self.preview.commit(terrain) catch |err| {
                    std.debug.print("ERROR: Could not commit preview: {s}\n", .{@errorName(err)});
                    return;
                };
                self.preview.clear();
                self.preview_active = false;
                self.reset();
            }
        }
    }

    fn reset(self: *Self) void {
        self.pos1 = null;
        self.pos2 = null;
        self.prev_hit = null;
        self.mesh.clear_geometry();
        self.mesh_length = 0;
        self.mesh_segment_count = 0;
    }

    fn revert_preview(self: *Self, terrain: *Terrain) !void {
        if (self.preview_active) {
            try self.preview.hide(terrain);
            self.preview.clear();
            self.preview_active = false;
        }
    }
};

pub const Shape = enum { circle, square };

pub const EditPreview = struct {
    const CS = Terrain.CHUNK_SIZE;
    chunks: Terrain.Chunk.Overlay,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .chunks = Terrain.Chunk.Overlay.init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *@This()) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |ptr| self.allocator.destroy(ptr.*);
        self.chunks.deinit();
    }

    pub fn add(self: *@This(), terrain: *Terrain, pos: Vec3_i32, block: Block) void {
        const chunk_pos = Vec3_i32.new(
            @divFloor(pos.x(), CS),
            @divFloor(pos.y(), CS),
            @divFloor(pos.z(), CS),
        );
        const gop = self.chunks.getOrPut(chunk_pos) catch return;
        if (!gop.found_existing) {
            // Copy original chunk blocks
            const chunk = terrain.chunks.getPtr(chunk_pos) orelse {
                _ = self.chunks.remove(chunk_pos);
                return;
            };
            const overlay_blocks = self.allocator.create(Terrain.Chunk.Blocks) catch return;
            overlay_blocks.* = chunk._blocks;
            gop.value_ptr.* = overlay_blocks;
        }
        const lx: usize = @intCast(@mod(pos.x(), CS));
        const ly: usize = @intCast(@mod(pos.y(), CS));
        const lz: usize = @intCast(@mod(pos.z(), CS));
        gop.value_ptr.*[lx][ly][lz] = block;
    }

    pub fn add_block_path(
        self: *@This(),
        terrain: *Terrain,
        p1: Vec3_i32,
        p2: Vec3_i32,
        radius: f32,
        block: Block,
        shape: Shape,
    ) void {
        // Bounding box expanded by radius in all axes
        const radius_i = @as(i32, @intFromFloat(@ceil(radius)));
        const min_x = @min(p1.x(), p2.x()) - radius_i;
        const max_x = @max(p1.x(), p2.x()) + radius_i;
        const min_y = @min(p1.y(), p2.y()) - radius_i;
        const max_y = @max(p1.y(), p2.y()) + radius_i;
        const min_z = @min(p1.z(), p2.z()) - radius_i;
        const max_z = @max(p1.z(), p2.z()) + radius_i;

        // Full 3D segment direction
        const dx_seg: f32 = @floatFromInt(p2.x() - p1.x());
        const dy_seg: f32 = @floatFromInt(p2.y() - p1.y());
        const dz_seg: f32 = @floatFromInt(p2.z() - p1.z());
        const len_sq = dx_seg * dx_seg + dy_seg * dy_seg + dz_seg * dz_seg;

        const r_sq: f32 = radius * radius;

        var ix = min_x;
        while (ix <= max_x) : (ix += 1) {
            var iy = min_y;
            while (iy <= max_y) : (iy += 1) {
                var iz = min_z;
                while (iz <= max_z) : (iz += 1) {
                    // Vector from p1 to this point
                    const px: f32 = @floatFromInt(ix - p1.x());
                    const py: f32 = @floatFromInt(iy - p1.y());
                    const pz: f32 = @floatFromInt(iz - p1.z());

                    // Closest point on 3D segment, t clamped to [0,1]
                    var t: f32 = if (len_sq > 0.0) (px * dx_seg + py * dy_seg + pz * dz_seg) / len_sq else 0.0;
                    t = @max(0.0, @min(1.0, t));

                    // 3D difference from closest point on segment
                    const diff_x = px - dx_seg * t;
                    const diff_y = py - dy_seg * t;
                    const diff_z = pz - dz_seg * t;

                    const in_shape = switch (shape) {
                        .circle => diff_x * diff_x + diff_y * diff_y + diff_z * diff_z <= r_sq,
                        .square => @abs(diff_x) <= radius and @abs(diff_y) <= radius and @abs(diff_z) <= radius,
                    };

                    if (in_shape) {
                        self.add(terrain, Vec3_i32.new(ix, iy, iz), block);
                    }
                }
            }
        }
    }

    /// Set the overlay on terrain and remesh affected chunks.
    pub fn show(self: *@This(), terrain: *Terrain) !void {
        try self.dirty_affected(terrain);
        terrain.overlay = &self.chunks;
    }

    /// Remove the overlay and remesh to restore original appearance.
    pub fn hide(self: *@This(), terrain: *Terrain) !void {
        try self.dirty_affected(terrain);
        terrain.overlay = null;
    }

    /// Write edits permanently into terrain data and remesh (no overlay needed after).
    pub fn commit(self: *@This(), terrain: *Terrain) !void {
        try self.dirty_affected(terrain);

        terrain.overlay = null;
        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            const chunk = terrain.chunks.getPtr(entry.key_ptr.*) orelse continue;
            chunk._blocks = entry.value_ptr.*.*;
        }
    }

    pub fn clear(self: *@This()) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |ptr| self.allocator.destroy(ptr.*);
        self.chunks.clearRetainingCapacity();
    }

    fn dirty_affected(self: *@This(), terrain: *Terrain) !void {
        try terrain.dirty_chunks.ensureUnusedCapacity(self.chunks.count());

        var it = self.chunks.keyIterator();
        while (it.next()) |chunk_pos| {
            terrain.dirty_chunks.putAssumeCapacity(chunk_pos.*, {});
        }
    }
};

/// Draws 12 edges of a unit cube at the given voxel position.
fn draw_cube_marker(shapes: *Shapes, pos: Vec3_i32, color: Vec4) void {
    const base = pos.cast(f32);
    const s = Vec3.new(1, 1, 1); // unit cube size

    // 8 corners
    const corners = [8]Vec3{
        base,
        base.add(Vec3.new(s.x(), 0, 0)),
        base.add(Vec3.new(s.x(), 0, s.z())),
        base.add(Vec3.new(0, 0, s.z())),
        base.add(Vec3.new(0, s.y(), 0)),
        base.add(Vec3.new(s.x(), s.y(), 0)),
        base.add(Vec3.new(s.x(), s.y(), s.z())),
        base.add(Vec3.new(0, s.y(), s.z())),
    };

    // 12 edges (pairs of corner indices)
    const edges = [12][2]u8{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 }, // bottom
        .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 }, // top
        .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, // verticals
    };

    const t: f32 = 0.1;
    for (edges) |e| {
        shapes.line_3d(corners[e[0]], corners[e[1]], color, t);
    }
}
