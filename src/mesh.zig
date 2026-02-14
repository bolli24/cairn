const std = @import("std");

const za = @import("zalgebra");
const Vec3 = za.Vec3;
const Quat = za.Quat;

const sokol = @import("sokol");
const sg = sokol.gfx;

pub const Transform = struct {
    position: Vec3 = .zero(),
    rotation: Quat = .identity(),
    scale: Vec3 = .one(),
};

pub const Vertex = struct { pos: Vec3, normal: Vec3 };

pub const Mesh = struct {
    const Self = @This();
    vertices: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u16) = .empty,
    wireframe_indices: std.ArrayList(u16) = .empty,
    vbuf: sg.Buffer = .{},
    ibuf: sg.Buffer = .{},
    wireframe_ibuf: sg.Buffer = .{},
    transform: Transform = .{},
    color: Vec3 = Vec3.one().scale(0.5),

    fn init(vertices: []const Vec3, indices: []const u16, allocator: std.mem.Allocator) !Self {
        var self: Self = .{ .allocator = allocator };

        try self.vertices.appendSlice(allocator, vertices);
        try self.indices.appendSlice(allocator, indices);

        return self;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.indices.deinit(allocator);
        self.wireframe_indices.deinit(allocator);
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
};
