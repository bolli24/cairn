const std = @import("std");

const za = @import("zalgebra");
const Vec2 = za.Vec2;
const Vec3 = za.Vec3;
const Vec4 = za.Vec4;
const Quat = za.Quat;

const sokol = @import("sokol");
const sg = sokol.gfx;

pub const Transform = struct {
    position: Vec3 = .zero(),
    rotation: Quat = .identity(),
    scale: Vec3 = .one(),
};

pub const Vertex = struct {
    pos: Vec3 = .zero(),
    normal: Vec3 = .zero(),
    uv: Vec2 = .zero(),
    color: Vec4 = .one(),
    ao: f32 = 1.0,
};

const Self = @This();
vertices: std.ArrayList(Vertex) = .empty,
indices: std.ArrayList(u16) = .empty,
wireframe_indices: std.ArrayList(u16) = .empty,
vbuf: sg.Buffer = .{},
ibuf: sg.Buffer = .{},
wireframe_ibuf: sg.Buffer = .{},
transform: Transform = .{},
color: Vec3 = Vec3.one().scale(0.5),

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.vertices.deinit(allocator);
    self.indices.deinit(allocator);
    self.wireframe_indices.deinit(allocator);
}

pub fn clear_geometry(self: *Self) void {
    self.vertices.clearRetainingCapacity();
    self.indices.clearRetainingCapacity();
    self.wireframe_indices.clearRetainingCapacity();
}

pub fn update_wireframe(self: *Self, allocator: std.mem.Allocator) !void {
    std.debug.assert(self.indices.items.len % 3 == 0);

    self.wireframe_indices.clearRetainingCapacity();
    try self.wireframe_indices.ensureTotalCapacity(allocator, self.indices.items.len * 2);

    var i: usize = 0;
    while (i < self.indices.items.len) : (i += 3) {
        const a = self.indices.items[i];
        const b = self.indices.items[i + 1];
        const c = self.indices.items[i + 2];

        try self.wireframe_indices.appendSlice(allocator, &.{ a, b, b, c, c, a });
    }
}

pub fn upload(self: *Self) void {
    if (self.vbuf.id != 0) sg.destroyBuffer(self.vbuf);
    if (self.ibuf.id != 0) sg.destroyBuffer(self.ibuf);
    if (self.wireframe_ibuf.id != 0) sg.destroyBuffer(self.wireframe_ibuf);

    if (self.vertices.items.len > 0) {
        self.vbuf = sg.makeBuffer(.{ .data = .{
            .ptr = self.vertices.items.ptr,
            .size = self.vertices.items.len * @sizeOf(Vertex),
        } });
    }

    if (self.indices.items.len > 0) {
        self.ibuf = sg.makeBuffer(.{
            .usage = .{ .index_buffer = true },
            .data = sg.asRange(self.indices.items),
        });
    }

    if (self.wireframe_indices.items.len > 0) {
        self.wireframe_ibuf = sg.makeBuffer(.{
            .usage = .{ .index_buffer = true },
            .data = sg.asRange(self.wireframe_indices.items),
        });
    }
}

fn clone(self: *Self, allocator: std.mem.Allocator) !Self {
    const new_mesh = Self{
        .vertices = try self.vertices.clone(allocator),
        .indices = try self.indices.clone(allocator),
    };

    return new_mesh;
}
