const std = @import("std");

fn pathFromExeDir(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const exe_dir = try std.process.executableDirPathAlloc(std.Options.debug_io, allocator);
    defer allocator.free(exe_dir);
    return std.fs.path.join(allocator, &.{ exe_dir, path });
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: std.Io.Limit) ![]u8 {
    const asset_path = try pathFromExeDir(allocator, path);
    defer allocator.free(asset_path);

    return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, asset_path, allocator, limit) catch |err| switch (err) {
        error.FileNotFound => std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, allocator, limit),
        else => |e| return e,
    };
}

pub fn openFile(allocator: std.mem.Allocator, path: []const u8, flags: std.Io.Dir.OpenFileOptions) !std.Io.File {
    const asset_path = try pathFromExeDir(allocator, path);
    defer allocator.free(asset_path);

    return std.Io.Dir.cwd().openFile(std.Options.debug_io, asset_path, flags) catch |err| switch (err) {
        error.FileNotFound => std.Io.Dir.cwd().openFile(std.Options.debug_io, path, flags),
        else => |e| return e,
    };
}
