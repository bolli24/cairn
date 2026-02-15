@header const za = @import("zalgebra")
@ctype mat4 za.Mat4
@ctype vec4 za.Vec4

@vs vs
layout(binding=0) uniform vs_params {
    mat4 model;
    mat4 view;
    mat4 proj;
    mat4 normal_mat; // mat3(transpose(inverse(model)))
};

in vec4 position;
in vec4 aUv;
in vec4 aNormal;
in vec4 color0;

out vec4 normal;
out vec4 frag_pos;

void main() {
    gl_Position = proj * view * model * position;
    normal = normal_mat * aNormal;
    frag_pos = model * position;
}
@end

@fs fs
layout(binding=1) uniform fs_params {
    vec3 base_color;
    vec3 ambient;
    vec3 light_color;
    vec3 light_dir;
};

in vec3 normal;
in vec3 frag_pos;

out vec3 frag_color;

void main() {
    float diff = max(dot(normalize(normal), normalize(light_dir)), 0.0);
    vec3 diffuse = diff * light_color;
    vec3 result = (ambient + diffuse) * base_color;

    frag_color = result;
}
@end

@program basic vs fs