const std = @import("std");
const math = std.math;

const za = @import("zalgebra");
const Vec2 = za.Vec2;
const Vec3 = za.Vec3;
const Quat = za.Quat;

const sokol = @import("sokol");
const sapp = sokol.app;

const mesh_mod = @import("mesh.zig");
const Transform = mesh_mod.Transform;

const input = @import("input.zig");
const InputState = input.InputState;

const MOUSE_ROTATE_SPEED = 0.2;

pub const Camera = struct {
    const Self = @This();
    transform: Transform = .{ .position = Vec3.new(0, 10, 4.0) },
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

    pub fn update(self: *Self, t: f32, inp: *InputState) void {
        const forward = self.transform.rotation.rotateVec(Vec3.new(0, 0, -1));
        const right = self.transform.rotation.rotateVec(Vec3.new(1, 0, 0));
        const speed: f32 = 10.0;
        const pos = &self.transform.position;

        if (inp.key_down(.W)) pos.* = pos.add(forward.scale(speed * t));
        if (inp.key_down(.S)) pos.* = pos.sub(forward.scale(speed * t));
        if (inp.key_down(.D)) pos.* = pos.add(right.scale(speed * t));
        if (inp.key_down(.A)) pos.* = pos.sub(right.scale(speed * t));

        if (inp.mouse_down(.RIGHT)) {
            self.rotate(
                -inp.mouse_delta.x() * MOUSE_ROTATE_SPEED,
                -inp.mouse_delta.y() * MOUSE_ROTATE_SPEED,
            );
        }

        if (inp.mouse_pressed(.RIGHT)) {
            sapp.lockMouse(true);
        } else if (inp.mouse_released(.RIGHT)) {
            sapp.lockMouse(false);
        }
    }
};
