const std = @import("std");
const math = std.math;

const za = @import("zalgebra");
const Vec2 = za.Vec2;
const Vec3 = za.Vec3;
const Vec4 = za.Vec4;
const Mat4 = za.Mat4;
const Quat = za.Quat;

const sokol = @import("sokol");
const sapp = sokol.app;

const Mesh = @import("mesh.zig");
const Terrain = @import("terrain.zig");
const Ray = Terrain.Ray;
const Transform = Mesh.Transform;
const InputState = @import("input.zig").InputState;
const Mode = @import("main.zig").Mode;

const MAX_PAN_SPEED: f32 = 100.0;
const MOUSE_ROTATION_SPEED: f32 = 0.2; // degrees per pixel
const KEY_ROTATION_SPEED: f32 = 120.0; // degrees per second
const TILT_MULTIPLIER: f32 = 0.8;
const ZOOM_SPEED: f32 = 1.0;
const MOUSE_ZOOM_MULTIPLIER: f32 = 0.06;

pub const Camera = struct {
    const Self = @This();

    target_pos: Vec3 = Vec3.zero(),
    target_distance: f32 = 100.0,
    height_angle: f32 = 30.0, // degrees, clamped [20, 90]
    clock_angle: f32 = 0.0, // degrees
    fov: f32 = 60.0,
    near: f32 = 0.1,
    far: f32 = 1000.0,

    transform: Transform = .{},

    pub fn update(self: *Self, dt: f32, input: *const InputState, terrain: *const Terrain, mode: Mode) void {
        if (input.mouse_pressed(.MIDDLE) or input.key_pressed(.LEFT_ALT)) {
            self.lockOrbitTarget(terrain);
        }

        // Zoom
        const distance_change = getDistanceChange(input, mode);
        self.target_distance += distance_change * ZOOM_SPEED * self.target_distance;
        self.target_distance = @max(self.target_distance, 1.0);

        // Pan
        const pan = getPanVector(input);
        if (pan.x() != 0 or pan.y() != 0) {
            const rotated_pan = pan.norm().rotate(-self.clock_angle);
            self.target_pos = self.target_pos.add(Vec3.new(rotated_pan.x(), 0.0, rotated_pan.y()).scale(MAX_PAN_SPEED * dt));
        }

        // Rotation
        const rot = getRotationVector(dt, input);
        self.clock_angle += rot.x();
        self.height_angle += rot.y();
        self.height_angle = math.clamp(self.height_angle, 20.0, 90.0);

        // Recompute cached transform
        self.transform.rotation = Quat.fromEulerAngles(Vec3.new(-self.height_angle, self.clock_angle, 0));
        self.transform.position = self.target_pos.sub(self.forward().scale(self.target_distance));
    }

    fn lockOrbitTarget(self: *Self, terrain: *const Terrain) void {
        const screen_center = Vec2.new(sapp.widthf() * 0.5, sapp.heightf() * 0.5);
        if (terrain.raycast(self.screen_to_ray(screen_center, self.far))) |hit| {
            self.target_pos = hit.point;
            self.target_distance = @max(self.transform.position.sub(hit.point).length(), 1.0);
        }
    }

    fn getDistanceChange(input: *const InputState, mode: Mode) f32 {
        var change: f32 = 0.0;
        if (input.key_down(.MINUS)) change += 1.0;
        if (input.key_down(.EQUAL)) change -= 1.0;

        if (!(mode == .brush and input.key_down(.LEFT_SHIFT))) {
            change -= input.scroll_delta.y() * MOUSE_ZOOM_MULTIPLIER;
        }
        return change;
    }

    fn getPanVector(input: *const InputState) Vec2 {
        var pan = Vec2.zero();
        if (input.key_down(.W)) pan = pan.add(Vec2.new(0, -1));
        if (input.key_down(.S)) pan = pan.add(Vec2.new(0, 1));
        if (input.key_down(.A)) pan = pan.add(Vec2.new(-1, 0));
        if (input.key_down(.D)) pan = pan.add(Vec2.new(1, 0));
        return pan;
    }

    fn getRotationVector(dt: f32, input: *const InputState) Vec2 {
        var rot = Vec2.zero();

        // Keyboard rotation
        if (input.key_down(.Q)) rot = rot.add(Vec2.new(-KEY_ROTATION_SPEED * dt, 0));
        if (input.key_down(.E)) rot = rot.add(Vec2.new(KEY_ROTATION_SPEED * dt, 0));
        if (input.key_down(.R)) rot = rot.add(Vec2.new(0, KEY_ROTATION_SPEED * TILT_MULTIPLIER * dt));
        if (input.key_down(.F)) rot = rot.add(Vec2.new(0, -KEY_ROTATION_SPEED * TILT_MULTIPLIER * dt));

        // Mouse rotation (middle mouse drag or alt and mouse move)
        if (input.mouse_down(.MIDDLE) or input.key_down(.LEFT_ALT)) {
            rot = rot.add(Vec2.new(
                -input.mouse_delta.x() * MOUSE_ROTATION_SPEED,
                input.mouse_delta.y() * MOUSE_ROTATION_SPEED * TILT_MULTIPLIER,
            ));
        }

        return rot;
    }

    /// Unprojects a screen-space pixel coordinate to a world-space ray direction.
    pub fn screen_to_ray(self: *const Self, screen_pos: Vec2, range: f32) Ray {
        // Convert pixel coords to NDC [-1, 1]
        const ndc_x = (2.0 * screen_pos.x() / sapp.widthf()) - 1.0;
        const ndc_y = 1.0 - (2.0 * screen_pos.y() / sapp.heightf());

        // Clip-space point on the near plane
        const clip = Vec4.new(ndc_x, ndc_y, -1.0, 1.0);

        // Inverse projection -> view space
        const inv_proj = self.projectionMatrix().inv();
        const eye_raw = inv_proj.mulByVec4(clip);
        const eye = Vec4.new(eye_raw.x(), eye_raw.y(), -1.0, 0.0); // direction, not a point

        // Inverse view -> world space
        const inv_view = self.viewMatrix().inv();
        const world = inv_view.mulByVec4(eye);

        return Ray{
            .origin = self.transform.position,
            .direction = Vec3.new(world.x(), world.y(), world.z()).norm(),
            .range = range,
        };
    }

    pub fn forward(self: *const Self) Vec3 {
        return self.transform.rotation.rotateVec(Vec3.new(0, 0, -1));
    }

    pub fn viewMatrix(self: *const Self) Mat4 {
        return self.transform.rotation.inv().toMat4().mul(Mat4.fromTranslate(self.transform.position.negate()));
    }

    pub fn projectionMatrix(self: *const Self) Mat4 {
        return za.perspective(self.fov, sapp.widthf() / sapp.heightf(), self.near, self.far);
    }
};
