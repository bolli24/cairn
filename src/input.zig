const za = @import("zalgebra");
const Vec2 = za.Vec2;

const sokol = @import("sokol");
const sapp = sokol.app;

pub const KeyState = enum { pressed, released, down, up };

const KEY_COUNT = @typeInfo(sapp.Keycode).@"enum".field_names.len;
const MAX_KEY = @typeInfo(sapp.Keycode).@"enum".field_values[KEY_COUNT - 1];

pub const InputState = struct {
    const Self = @This();
    keys: [MAX_KEY]KeyState = @splat(.up),
    mouse_buttons: [3]KeyState = @splat(.up),
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
        return self.keys[@intCast(@backingInt(key))];
    }

    fn getMouse(self: *const Self, btn: sapp.Mousebutton) KeyState {
        const idx: usize = @intCast(@backingInt(btn));
        if (idx >= 3) return .up;
        return self.mouse_buttons[idx];
    }

    pub fn setKey(self: *Self, key: sapp.Keycode, s: KeyState) void {
        self.keys[@intCast(@backingInt(key))] = s;
    }

    pub fn setMouse(self: *Self, btn: sapp.Mousebutton, s: KeyState) void {
        const idx: usize = @intCast(@backingInt(btn));
        if (idx >= 3) return;
        self.mouse_buttons[idx] = s;
    }

    pub fn handle_event(self: *Self, event: sapp.Event) void {
        switch (event.type) {
            .KEY_DOWN => if (!event.key_repeat) self.setKey(event.key_code, .pressed),
            .KEY_UP => self.setKey(event.key_code, .released),
            .MOUSE_DOWN => self.setMouse(event.mouse_button, .pressed),
            .MOUSE_UP => self.setMouse(event.mouse_button, .released),
            .MOUSE_MOVE => {
                self.mouse_pos = Vec2.new(event.mouse_x, event.mouse_y);
                self.mouse_delta = self.mouse_delta.add(Vec2.new(event.mouse_dx, event.mouse_dy));
            },
            .MOUSE_SCROLL => {
                self.scroll_delta = self.scroll_delta.add(Vec2.new(event.scroll_x, event.scroll_y));
            },
            .UNFOCUSED, .SUSPENDED => self.reset(),
            else => {},
        }
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

    pub fn reset(self: *Self) void {
        self.keys = @splat(.up);
        self.mouse_buttons = @splat(.up);
        self.mouse_delta = Vec2.zero();
        self.scroll_delta = Vec2.zero();
    }
};
