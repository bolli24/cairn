@header const za = @import("zalgebra")
@ctype mat4 za.Mat4
@ctype vec4 za.Vec4

@vs vs
layout(binding=0) uniform vs_params {
    mat4 model;
    mat4 view;
    mat4 proj;
    mat4 normal_mat;
    mat4 light_space;
};

in vec4 position;
in vec4 aUv;
in vec3 aNormal;

out vec3 normal;
out vec4 frag_pos;
out vec4 frag_pos_light_space;

void main() {
    vec4 world_pos = model * position;
    gl_Position = proj * view * world_pos;
    normal = mat3(normal_mat) * aNormal;
    frag_pos = world_pos;
    frag_pos_light_space = light_space * world_pos;
    #if !SOKOL_GLSL
    frag_pos_light_space.y = -frag_pos_light_space.y;
    #endif
}
@end

@fs fs
layout(binding=1) uniform fs_params {
    vec3 base_color;
    vec3 ambient;
    vec3 light_color;
    vec3 light_dir;
};

layout(binding=0) uniform texture2D shadow_map;
layout(binding=0) uniform sampler shadow_smp;

in vec3 normal;
in vec4 frag_pos;
in vec4 frag_pos_light_space;

out vec3 frag_color;

float sample_shadow(vec4 light_space_pos, float bias) {
    vec3 proj = light_space_pos.xyz / light_space_pos.w;
    proj = proj * 0.5 + 0.5;
    if (proj.z > 1.0 || proj.z < 0.0) return 0.0;
    if (proj.x < 0.0 || proj.x > 1.0) return 0.0;
    if (proj.y < 0.0 || proj.y > 1.0) return 0.0;

    ivec2 shadow_size = textureSize(sampler2D(shadow_map, shadow_smp), 0);
    vec2 texel = 1.0 / vec2(shadow_size);
    float shadow = 0.0;

    float closest_depth = texture(sampler2D(shadow_map, shadow_smp), proj.xy + texel * vec2(-1.0, -1.0)).x;
    shadow += (proj.z - bias) > closest_depth ? 1.0 : 0.0;
    closest_depth = texture(sampler2D(shadow_map, shadow_smp), proj.xy + texel * vec2(0.0, -1.0)).x;
    shadow += (proj.z - bias) > closest_depth ? 1.0 : 0.0;
    closest_depth = texture(sampler2D(shadow_map, shadow_smp), proj.xy + texel * vec2(1.0, -1.0)).x;
    shadow += (proj.z - bias) > closest_depth ? 1.0 : 0.0;
    closest_depth = texture(sampler2D(shadow_map, shadow_smp), proj.xy + texel * vec2(-1.0, 0.0)).x;
    shadow += (proj.z - bias) > closest_depth ? 1.0 : 0.0;
    closest_depth = texture(sampler2D(shadow_map, shadow_smp), proj.xy + texel * vec2(0.0, 0.0)).x;
    shadow += (proj.z - bias) > closest_depth ? 1.0 : 0.0;
    closest_depth = texture(sampler2D(shadow_map, shadow_smp), proj.xy + texel * vec2(1.0, 0.0)).x;
    shadow += (proj.z - bias) > closest_depth ? 1.0 : 0.0;
    closest_depth = texture(sampler2D(shadow_map, shadow_smp), proj.xy + texel * vec2(-1.0, 1.0)).x;
    shadow += (proj.z - bias) > closest_depth ? 1.0 : 0.0;
    closest_depth = texture(sampler2D(shadow_map, shadow_smp), proj.xy + texel * vec2(0.0, 1.0)).x;
    shadow += (proj.z - bias) > closest_depth ? 1.0 : 0.0;
    closest_depth = texture(sampler2D(shadow_map, shadow_smp), proj.xy + texel * vec2(1.0, 1.0)).x;
    shadow += (proj.z - bias) > closest_depth ? 1.0 : 0.0;

    return shadow / 9.0;
}

void main() {
    vec3 n = normalize(normal);
    float face_brightness;
    // NOTE: assumes axis-aligned normals; replace with smooth formula when adding non-voxel geometry
    if (n.y > 0.5) {
        face_brightness = 1.0;  // +Y
    } else if (n.y < -0.5) {
        face_brightness = 0.5;  // -Y
    } else if (abs(n.x) > 0.5) {
        face_brightness = 0.8;  // ±X
    } else {
        face_brightness = 0.6;  // ±Z
    }
    float diff = max(dot(n, normalize(light_dir)), 0.0);
    float bias = max(0.0015 * (1.0 - diff), 0.0001);
    float shadow = sample_shadow(frag_pos_light_space, bias);
    vec3 diffuse = diff * light_color;
    vec3 result = (ambient + diffuse * (1.0 - shadow)) * base_color * face_brightness;
    frag_color = result;
}
@end

@program basic vs fs
