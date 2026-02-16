const za = @import("zalgebra");
const Vec2 = za.Vec2;
const Vec3 = za.Vec3;
const Vec3_i32 = za.Vec3_i32;
const Vec4 = za.Vec4;

const sokol = @import("sokol");
const sapp = sokol.app;

const InputState = @import("input.zig").InputState;
const Camera = @import("camera.zig").Camera;
const Terrain = @import("terrain.zig").Terrain;
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

    pub fn update(self: *Self, input: *InputState, camera: *const Camera, terrain: *const Terrain, shapes: *Shapes) void {
        if (input.key_pressed(.B)) {
            self.active = !self.active;
            if (self.active) {
                self.reset();
            }
            return;
        }

        if (!self.active) return;

        if (input.key_pressed(.ESCAPE)) {
            self.active = false;
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
                    self.prev_hit = h.pos;
                    // TODO: Apply terrain preview edit along path from pos1 to cursor
                }

                if (input.mouse_pressed(.LEFT)) {
                    self.pos2 = h.pos;
                    self.prev_hit = null;
                }
            }
        } else {
            const p1f = self.pos1.?.cast(f32);
            const p2f = self.pos2.?.cast(f32);
            draw_cube_marker(shapes, self.pos1.?, CONFIRM_COLOR);
            draw_cube_marker(shapes, self.pos2.?, CONFIRM_COLOR);
            shapes.line_3d(p1f.add(Vec3.new(0.5, 0.5, 0.5)), p2f.add(Vec3.new(0.5, 0.5, 0.5)), CONFIRM_COLOR, LINE_THICKNESS);

            if (input.key_pressed(.SPACE)) {
                // TODO: Apply final terrain edit along path from pos1 to pos2
                self.reset();
            }
        }
    }

    fn reset(self: *Self) void {
        self.pos1 = null;
        self.pos2 = null;
        self.prev_hit = null;
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
