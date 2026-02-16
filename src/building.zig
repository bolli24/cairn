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
const terrai_mod = @import("terrain.zig");
const Terrain = terrai_mod.Terrain;
const Block = terrai_mod.Block;
const Shapes = @import("shapes.zig").Shapes;

const MARKER_COLOR = Vec4.new(1, 1, 0, 1);
const LINE_COLOR = Vec4.new(0, 1, 1, 1);
const CONFIRM_COLOR = Vec4.new(0, 1, 0, 1);
const LINE_THICKNESS: f32 = 0.15;
const RAYCAST_RANGE: f32 = 500.0;

pub const BuildingState = struct {
    const Self = @This();

    active: bool = false,
    pos1: ?Vec3_i32 = null,
    pos2: ?Vec3_i32 = null,
    prev_hit: ?Vec3_i32 = null,
    preview: EditPreview = undefined,
    preview_active: bool = false,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .preview = EditPreview.init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        self.preview.deinit();
    }

    pub fn update(self: *Self, input: *InputState, camera: *const Camera, terrain: *Terrain, shapes: *Shapes) void {
        if (input.key_pressed(.B)) {
            self.active = !self.active;
            if (self.active) {
                self.reset();
            } else {
                self.revert_preview(terrain);
                self.reset();
            }
            return;
        }

        if (!self.active) return;

        if (input.key_pressed(.ESCAPE)) {
            self.active = false;
            self.revert_preview(terrain);
            self.reset();
            return;
        }

        const ray_dir = camera.screen_to_ray(input.mouse_pos);
        const hit = terrain.raycast(camera.transform.position, ray_dir, RAYCAST_RANGE);

        if (self.pos1 == null) {
            // State: waiting for first point
            if (hit) |h| {
                draw_cube_marker(shapes, h.pos, MARKER_COLOR);
                if (input.mouse_pressed(.LEFT)) {
                    self.pos1 = h.pos;
                }
            }
        } else if (self.pos2 == null) {
            // State: first point set, waiting for second point
            const p1f = self.pos1.?.cast(f32);
            draw_cube_marker(shapes, self.pos1.?, MARKER_COLOR);

            if (hit) |h| {
                const cursor_f = h.pos.cast(f32);
                shapes.line_3d(p1f.add(Vec3.new(0.5, 0.5, 0.5)), cursor_f.add(Vec3.new(0.5, 0.5, 0.5)), LINE_COLOR, LINE_THICKNESS);
                draw_cube_marker(shapes, h.pos, LINE_COLOR);

                if (self.prev_hit == null or !self.prev_hit.?.eql(h.pos)) {
                    if (self.preview_active) {
                        self.preview.hide(terrain);
                    }
                    self.preview.clear();
                    self.prev_hit = h.pos;
                    self.preview.add_block_path(terrain, self.pos1.?, h.pos, 4, .air, .circle);
                    self.preview.show(terrain);
                    self.preview_active = true;
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
                self.preview.commit(terrain);
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
    }

    fn revert_preview(self: *Self, terrain: *Terrain) void {
        if (self.preview_active) {
            self.preview.hide(terrain);
            self.preview.clear();
            self.preview_active = false;
        }
    }
};

pub const Shape = enum { circle, square };

pub const EditPreview = struct {
    const CS = terrai_mod.CHUNK_SIZE;
    chunks: terrai_mod.ChunkOverlay,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .chunks = terrai_mod.ChunkOverlay.init(allocator), .allocator = allocator };
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
            const overlay_blocks = self.allocator.create(terrai_mod.ChunkBlocks) catch return;
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
        radius: i32,
        block: Block,
        shape: Shape,
    ) void {
        // Bounding box expanded by radius in all axes
        const min_x = @min(p1.x(), p2.x()) - radius;
        const max_x = @max(p1.x(), p2.x()) + radius;
        const min_y = @min(p1.y(), p2.y()) - radius;
        const max_y = @max(p1.y(), p2.y()) + radius;
        const min_z = @min(p1.z(), p2.z()) - radius;
        const max_z = @max(p1.z(), p2.z()) + radius;

        // Full 3D segment direction
        const dx_seg: f32 = @floatFromInt(p2.x() - p1.x());
        const dy_seg: f32 = @floatFromInt(p2.y() - p1.y());
        const dz_seg: f32 = @floatFromInt(p2.z() - p1.z());
        const len_sq = dx_seg * dx_seg + dy_seg * dy_seg + dz_seg * dz_seg;

        const r_sq: f32 = @floatFromInt(radius * radius);
        const r_f: f32 = @floatFromInt(radius);

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
                        .square => @abs(diff_x) <= r_f and @abs(diff_y) <= r_f and @abs(diff_z) <= r_f,
                    };

                    if (in_shape) {
                        self.add(terrain, Vec3_i32.new(ix, iy, iz), block);
                    }
                }
            }
        }
    }

    /// Set the overlay on terrain and remesh affected chunks.
    pub fn show(self: *@This(), terrain: *Terrain) void {
        terrain.overlay = &self.chunks;
        self.remesh_affected(terrain);
    }

    /// Remove the overlay and remesh to restore original appearance.
    pub fn hide(self: *@This(), terrain: *Terrain) void {
        terrain.overlay = null;
        self.remesh_affected(terrain);
    }

    /// Write edits permanently into terrain data and remesh (no overlay needed after).
    pub fn commit(self: *@This(), terrain: *Terrain) void {
        terrain.overlay = null;
        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            const chunk = terrain.chunks.getPtr(entry.key_ptr.*) orelse continue;
            chunk._blocks = entry.value_ptr.*.*;
        }
        self.remesh_affected(terrain);
    }

    pub fn clear(self: *@This()) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |ptr| self.allocator.destroy(ptr.*);
        self.chunks.clearRetainingCapacity();
    }

    fn remesh_affected(self: *@This(), terrain: *Terrain) void {
        var it = self.chunks.keyIterator();
        while (it.next()) |chunk_pos| {
            terrain.remesh_at(Vec3_i32.new(
                chunk_pos.x() * CS,
                chunk_pos.y() * CS,
                chunk_pos.z() * CS,
            ));
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
