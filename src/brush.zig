const std = @import("std");
const za = @import("zalgebra");
const Vec2 = za.Vec2;
const Vec3 = za.Vec3;
const Vec3_i32 = za.Vec3_i32;

const InputState = @import("input.zig").InputState;
const Camera = @import("camera.zig").Camera;
const Terrain = @import("terrain.zig");
const Block = Terrain.Block;
const Shapes = @import("shapes.zig").Shapes;
const Mesh = @import("mesh.zig");
const Vertex = Mesh.Vertex;
const Transform = Mesh.Transform;

const MAX_BRUSH_SIZE = 25.0;
const MIN_BRUSH_SIZE = 1.0;
const UPDATE_INTERVAL = 1.0 / 30.0;

pub const BrushState = struct {
    const Self = @This();

    size: f32 = 10.0,
    update_timer: f32 = 0.0,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn update(self: *Self, input: *InputState, camera: *const Camera, terrain: *Terrain, shapes: *Shapes, dt: f32) void {
        if (input.key_down(.LEFT_SHIFT)) self.size = @min(@max(self.size + input.scroll_delta.y(), MIN_BRUSH_SIZE), MAX_BRUSH_SIZE);

        const hit = terrain.raycast(camera.screen_to_ray(input.mouse_pos, 500));

        if (hit) |h| {
            shapes.full_circle(h.point, .up(), self.size * 0.5, .new(1, 1, 0, 1), 0.3, 48);
            self.update_timer += dt;

            if (self.update_timer < UPDATE_INTERVAL) return;
            self.update_timer = 0.0;

            if (input.mouse_down(.LEFT)) self.raise(terrain, h.pos);
            if (input.mouse_down(.RIGHT)) self.lower(terrain, h.pos);
        }
    }

    fn raise(self: *const Self, terrain: *Terrain, center: Vec3_i32) void {
        const radius = self.size * 0.5;
        const r: i32 = @intFromFloat(@ceil(radius));

        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            var dz: i32 = -r;
            while (dz <= r) : (dz += 1) {
                const fx: f32 = @floatFromInt(dx);
                const fz: f32 = @floatFromInt(dz);
                if (fx * fx + fz * fz > radius * radius) continue;

                const top = surface_height(terrain, center.x() + dx, center.y(), center.z() + dz) orelse continue;
                terrain.set_block(.new(center.x() + dx, top + 1, center.z() + dz), .ground) catch return;
            }
        }
    }

    fn lower(self: *const Self, terrain: *Terrain, center: Vec3_i32) void {
        const radius = self.size * 0.5;
        const r: i32 = @intFromFloat(@ceil(radius));

        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            var dz: i32 = -r;
            while (dz <= r) : (dz += 1) {
                const fx: f32 = @floatFromInt(dx);
                const fz: f32 = @floatFromInt(dz);
                if (fx * fx + fz * fz > radius * radius) continue;

                const top = surface_height(terrain, center.x() + dx, center.y(), center.z() + dz) orelse continue;
                terrain.set_block(.new(center.x() + dx, top, center.z() + dz), .air) catch return;
            }
        }
    }

    /// Y of the topmost solid block in column (x, z), searching from `start_y`.
    fn surface_height(terrain: *const Terrain, x: i32, start_y: i32, z: i32) ?i32 {
        var y = start_y;
        if (terrain.get_block(.new(x, y, z)) == .ground) {
            // Inside the ground: walk up until the block above is air.
            while (terrain.get_block(.new(x, y + 1, z)) == .ground) y += 1;
            return y;
        }
        // In the air: walk down until we hit ground.
        const MAX_SEARCH = 16;
        var i: i32 = 0;
        while (i < MAX_SEARCH) : (i += 1) {
            y -= 1;
            if (terrain.get_block(.new(x, y, z)) == .ground) return y;
        }
        return null;
    }
};
