const za = @import("zalgebra");
const Vec2 = za.Vec2;

const sokol = @import("sokol");
const sapp = sokol.app;

pub const KeyState = enum { pressed, released, down, up };

const KEY_COUNT = @typeInfo(sapp.Keycode).@"enum".fields.len;
const MAX_KEY = @typeInfo(sapp.Keycode).@"enum".fields[KEY_COUNT - 1].value;

pub const InputState = struct {
    const Self = @This();
    keys: [MAX_KEY]KeyState = [_]KeyState{.up} ** MAX_KEY,
    mouse_buttons: [3]KeyState = [_]KeyState{.up} ** 3,
    mouse_pos: Vec2 = Vec2.zero(),
    mouse_delta: Vec2 = Vec2.zero(),
    scroll_delta: Vec2 = Vec2.zero(),

    pub fn key_pressed(self: *const Self, key: sapp.Keycode) bool {
        return self.getKey(key) == .pressed;
    }

    pub fn key_released(self: *const Self, key: sapp.Keycode) bool {
        return self.getKey(key) == .released;
    }

    pub fn key_down(self: *const Self, key: sapp.Keycode) bool {
        return self.getKey(key) == .down;
    }

    pub fn key_up(self: *const Self, key: sapp.Keycode) bool {
        return self.getKey(key) == .up;
    }

    pub fn mouse_pressed(self: *const Self, btn: sapp.Mousebutton) bool {
        return self.getMouse(btn) == .pressed;
    }

    pub fn mouse_released(self: *const Self, btn: sapp.Mousebutton) bool {
        return self.getMouse(btn) == .released;
    }

    pub fn mouse_down(self: *const Self, btn: sapp.Mousebutton) bool {
        return self.getMouse(btn) == .down;
    }

    pub fn mouse_up(self: *const Self, btn: sapp.Mousebutton) bool {
        return self.getMouse(btn) == .up;
    }

    pub fn mouseDelta(self: *const Self) Vec2 {
        return self.mouse_delta;
    }

    fn getKey(self: *const Self, key: sapp.Keycode) KeyState {
        return self.keys[@intCast(@intFromEnum(key))];
    }

    fn getMouse(self: *const Self, btn: sapp.Mousebutton) KeyState {
        const idx: usize = @intCast(@intFromEnum(btn));
        if (idx >= 3) return .up;
        return self.mouse_buttons[idx];
    }

    pub fn setKey(self: *Self, key: sapp.Keycode, s: KeyState) void {
        self.keys[@intCast(@intFromEnum(key))] = s;
    }

    pub fn setMouse(self: *Self, btn: sapp.Mousebutton, s: KeyState) void {
        const idx: usize = @intCast(@intFromEnum(btn));
        if (idx >= 3) return;
        self.mouse_buttons[idx] = s;
    }

    pub fn update(self: *Self) void {
        for (&self.keys) |*k| {
            switch (k.*) {
                .pressed => k.* = .down,
                .released => k.* = .up,
                else => {},
            }
        }
        self.mouse_delta = Vec2.zero();
        self.scroll_delta = Vec2.zero();
        for (&self.mouse_buttons) |*b| {
            switch (b.*) {
                .pressed => b.* = .down,
                .released => b.* = .up,
                else => {},
            }
        }
    }
};
