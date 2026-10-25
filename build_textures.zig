const std = @import("std");
const TextureKind = @import("src/texture.zig").TextureKind;

const TextureRequests = std.StringArrayHashMapUnmanaged(TextureRequest);

pub const TextureRequest = struct {
    path: []const u8,
    kind: TextureKind,
};

pub fn collectAll(src_dir: []const u8, io: std.Io, allocator: std.mem.Allocator) !TextureRequests {
    var dir = try std.Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var unique_requests: TextureRequests = .empty;
    errdefer unique_requests.deinit(allocator);

    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".zig")) {
            const full_path = try std.fs.path.join(allocator, &.{ src_dir, entry.path });
            try collectTextures(full_path, &unique_requests, io, allocator);
        }
    }

    return unique_requests;
}

pub fn addTextureBuildSteps(
    b: *std.Build,
    compressor: *std.Build.Step.Compile,
    src_dir: []const u8,
    res_dir: []const u8,
    generated: *std.Build.Step.WriteFile,
) !void {
    const requests = try collectAll(src_dir, b.graph.io, b.allocator);

    for (requests.keys(), requests.values()) |path, request| {
        const compressor_cmd = b.addRunArtifact(compressor);
        compressor_cmd.addArgs(getCompressionArgs(request.kind));

        const input_path = try std.fs.path.join(b.allocator, &.{ res_dir, path });
        compressor_cmd.addFileArg(b.path(input_path));

        const output_rel_path = try replaceExtension(path, ".dds", b.allocator);
        const output = compressor_cmd.addOutputFileArg(output_rel_path);

        const installed_path = b.fmt("res/{s}", .{output_rel_path});
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(output, .prefix, installed_path).step);
        _ = generated.addCopyFile(output, output_rel_path);
    }
}

fn pathWithoutExtension(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    return path[0 .. path.len - ext.len];
}

fn replaceExtension(path: []const u8, new_ext: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ pathWithoutExtension(path), new_ext });
}

fn getCompressionArgs(kind: TextureKind) []const []const u8 {
    return switch (kind) {
        .albedo, .albedo_alpha => &.{ "-g", "-f" }, //  BC7
        // .normal_map, .roughness_metallic => &.{ "-g", "-f", "-5" }, // BC5
        // .grayscale => &.{ "-g", "-f", "-4" }, // BC4
    };
}

pub fn collectTextures(src_path: []const u8, requests: *TextureRequests, io: std.Io, allocator: std.mem.Allocator) !void {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        src_path,
        allocator,
        std.Io.Limit.limited(1024 * 1024),
        .of(u8),
        0,
    );
    defer allocator.free(source);
    var tree = try std.zig.Ast.parse(allocator, source, .{ .mode = .zig });
    defer tree.deinit(allocator);

    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(i));

        var buffer = [1]std.zig.Ast.Node.Index{undefined};

        if (tag == .call or tag == .call_comma) {
            const full_node = tree.fullCall(&buffer, node).?;
            const func_name = tree.tokenSlice(tree.firstToken(full_node.ast.fn_expr));

            if (std.mem.eql(u8, func_name, "TextureSource") and full_node.ast.params.len >= 2) {
                const path_node = full_node.ast.params[0];
                const kind_node = full_node.ast.params[1];
                const path_index = @backingInt(path_node);
                const kind_index = @backingInt(kind_node);

                if (tree.nodes.items(.tag)[path_index] == .string_literal and
                    tree.nodes.items(.tag)[kind_index] == .enum_literal)
                {
                    const path_lit = tree.tokenSlice(tree.nodes.items(.main_token)[path_index]);
                    const kind_lit = tree.tokenSlice(tree.nodes.items(.main_token)[kind_index]);

                    // Trim quotes from path
                    const path_str = path_lit[1 .. path_lit.len - 1];
                    const enum_str = if (std.mem.startsWith(u8, kind_lit, ".")) kind_lit[1..] else kind_lit;

                    // Convert the string to the actual enum value
                    if (std.meta.stringToEnum(TextureKind, enum_str)) |parsed_kind| {
                        const gop = try requests.getOrPut(allocator, path_str);
                        if (!gop.found_existing) {
                            gop.key_ptr.* = try allocator.dupe(u8, path_str);
                            gop.value_ptr.* = .{
                                .path = gop.key_ptr.*,
                                .kind = parsed_kind,
                            };
                        }
                    } else {
                        std.debug.print("Build Error: Unknown TextureKind '.{s}' found in {s}\n", .{ enum_str, src_path });
                        return error.InvalidTextureKind;
                    }
                }
            }
        }
    }
    return;
}
