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

const MOUSE_ROTATE_SPEED = 0.2;

pub const Camera = struct {
    const Self = @This();
    transform: Transform = .{ .position = Vec3.new(0, 10, 4.0) },
    fov: f32 = 60.0,
    near: f32 = 0.1,
    far: f32 = 1000.0,
    pitch: f32 = 0.0,
    yaw: f32 = 0.0,
    _mouse_start_pos: Vec2 = Vec2.zero(),

    pub fn rotate(self: *Self, dx: f32, dy: f32) void {
        self.yaw += dx;
        self.pitch = math.clamp(self.pitch + dy, -89.0, 89.0);
        const yaw_q = Quat.fromAxis(self.yaw, Vec3.up());
        const pitch_q = Quat.fromAxis(self.pitch, Vec3.right());
        self.transform.rotation = yaw_q.mul(pitch_q);
    }

    pub fn update(self: *Self, t: f32, input: *InputState) void {
        const forward = self.transform.rotation.rotateVec(Vec3.new(0, 0, -1));
        const right = self.transform.rotation.rotateVec(Vec3.new(1, 0, 0));

        var move = Vec3.zero();
        if (input.key_down(.W)) move = move.add(forward);
        if (input.key_down(.S)) move = move.sub(forward);
        if (input.key_down(.D)) move = move.add(right);
        if (input.key_down(.A)) move = move.sub(right);
        if (input.key_down(.SPACE)) move = move.add(Vec3.up());
        if (input.key_down(.C)) move = move.sub(Vec3.up());

        if (move.x() != 0 or move.y() != 0 or move.z() != 0) {
            const base_speed: f32 = 20.0;
            const speed = if (input.key_down(.LEFT_SHIFT)) base_speed * 3.0 else base_speed;
            self.transform.position = self.transform.position.add(move.norm().scale(speed * t));
        }

        if (input.mouse_down(.RIGHT)) {
            self.rotate(
                -input.mouse_delta.x() * MOUSE_ROTATE_SPEED,
                -input.mouse_delta.y() * MOUSE_ROTATE_SPEED,
            );
        }

        if (input.mouse_pressed(.RIGHT)) {
            sapp.lockMouse(true);
        } else if (input.mouse_released(.RIGHT)) {
            sapp.lockMouse(false);
        }
    }

    pub fn viewMatrix(self: *const Self) Mat4 {
        return self.transform.rotation.inv().toMat4()
            .mul(Mat4.fromTranslate(self.transform.position.negate()));
    }

    pub fn projectionMatrix(self: *const Self) Mat4 {
        return za.perspective(self.fov, sapp.widthf() / sapp.heightf(), self.near, self.far);
    }
};
