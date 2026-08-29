#version 450
#extension GL_EXT_nonuniform_qualifier : require

// The bindless table: every texture the UI can ever draw lives here, so the
// whole frame is one descriptor set bound once and (usually) one draw call.
// Slot 0 is the font atlas, slot 1 is a 1x1 white pixel, the rest is art.
layout(set = 0, binding = 0) uniform sampler2D textures[];

layout(location = 0)      in vec2  v_uv;
layout(location = 1)      in vec4  v_col;
layout(location = 2) flat in uint  v_tex;
layout(location = 3)      in vec2  v_pos;
layout(location = 4) flat in vec4  v_rect;
layout(location = 5) flat in float v_radius;

layout(location = 0) out vec4 out_col;

// Signed distance to a box with rounded corners, in pixels.
float rounded_box(vec2 p, vec2 half_extent, float r) {
	vec2 q = abs(p) - half_extent + r;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
	vec4 c = v_col * texture(textures[nonuniformEXT(v_tex)], v_uv);

	if (v_radius >= 0.0) {
		float d = rounded_box(v_pos - v_rect.xy, v_rect.zw, v_radius);
		c.a *= 1.0 - smoothstep(-0.7, 0.7, d);
	}

	if (c.a <= 0.0) discard;
	out_col = c;
}
