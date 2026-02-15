const std = @import("std");
const math = std.math;

const za = @import("zalgebra");
const Vec2 = za.Vec2;
const Vec3 = za.Vec3;
const Mat4 = za.Mat4;
const Quat = za.Quat;

const sokol = @import("sokol");
const sapp = sokol.app;

const mesh_mod = @import("mesh.zig");
const Transform = mesh_mod.Transform;
const InputState = @import("input.zig").InputState;

const MAX_PAN_SPEED: f32 = 100.0;
const MOUSE_ROTATION_SPEED: f32 = 0.2; // degrees per pixel
const KEY_ROTATION_SPEED: f32 = 40.0; // degrees per second
const TILT_MULTIPLIER: f32 = 0.8;
const ZOOM_SPEED: f32 = 1.0;
const MOUSE_ZOOM_MULTIPLIER: f32 = 0.04;

pub const Camera = struct {
    const Self = @This();

    target_pos: Vec2 = Vec2.zero(),
    target_distance: f32 = 100.0,
    height_angle: f32 = 30.0, // degrees, clamped [20, 90]
    clock_angle: f32 = 0.0, // degrees
    fov: f32 = 60.0,
    near: f32 = 0.1,
    far: f32 = 1000.0,

    transform: Transform = .{},

    pub fn update(self: *Self, dt: f32, input: *InputState) void {
        // Zoom
        const distance_change = getDistanceChange(input);
        self.target_distance += distance_change * ZOOM_SPEED * self.target_distance;
        self.target_distance = @max(self.target_distance, 1.0);

        // Pan
        const pan = getPanVector(input);
        if (pan.x() != 0 or pan.y() != 0) {
            const rotated_pan = pan.norm().rotate(-self.clock_angle);
            self.target_pos = self.target_pos.add(rotated_pan.scale(MAX_PAN_SPEED * dt));
        }

        // Rotation
        const rot = getRotationVector(dt, input);
        self.clock_angle += rot.x();
        self.height_angle += rot.y();
        self.height_angle = math.clamp(self.height_angle, 20.0, 90.0);

        // Recompute cached transform
        self.transform.rotation = Quat.fromEulerAngles(Vec3.new(-self.height_angle, self.clock_angle, 0));
        const target3d = Vec3.new(self.target_pos.x(), 0, self.target_pos.y());
        const offset_rot = Quat.fromEulerAngles(Vec3.new(90.0 - self.height_angle, self.clock_angle, 0));
        self.transform.position = target3d.add(offset_rot.rotateVec(Vec3.new(0, self.target_distance, 0)));
    }

    fn getDistanceChange(input: *InputState) f32 {
        var change: f32 = 0.0;
        if (input.key_down(.MINUS)) change += 1.0;
        if (input.key_down(.EQUAL)) change -= 1.0;
        change -= input.scroll_delta.y() * MOUSE_ZOOM_MULTIPLIER;
        return change;
    }

    fn getPanVector(input: *InputState) Vec2 {
        var pan = Vec2.zero();
        if (input.key_down(.W)) pan = pan.add(Vec2.new(0, -1));
        if (input.key_down(.S)) pan = pan.add(Vec2.new(0, 1));
        if (input.key_down(.A)) pan = pan.add(Vec2.new(-1, 0));
        if (input.key_down(.D)) pan = pan.add(Vec2.new(1, 0));
        return pan;
    }

    fn getRotationVector(dt: f32, input: *InputState) Vec2 {
        var rot = Vec2.zero();

        // Keyboard rotation
        if (input.key_down(.Q)) rot = rot.add(Vec2.new(-KEY_ROTATION_SPEED * dt, 0));
        if (input.key_down(.E)) rot = rot.add(Vec2.new(KEY_ROTATION_SPEED * dt, 0));
        if (input.key_down(.R)) rot = rot.add(Vec2.new(0, KEY_ROTATION_SPEED * TILT_MULTIPLIER * dt));
        if (input.key_down(.F)) rot = rot.add(Vec2.new(0, -KEY_ROTATION_SPEED * TILT_MULTIPLIER * dt));

        // Mouse rotation (middle mouse drag)
        if (input.mouse_down(.MIDDLE)) {
            rot = rot.add(Vec2.new(
                -input.mouse_delta.x() * MOUSE_ROTATION_SPEED,
                input.mouse_delta.y() * MOUSE_ROTATION_SPEED * TILT_MULTIPLIER,
            ));
        }

        return rot;
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
