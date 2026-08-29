#version 450

// One pipeline draws the whole UI: solid rects, rounded rects, glyphs, album
// art and the shader effects in the transport bar. What a vertex is depends on
// its texture index, radius and effect — not on which pipeline is bound.

layout(push_constant) uniform Push {
	vec2  inv_screen; // 1 / framebuffer size, in logical units
	float time;       // seconds since start, for animated effects
} pc;

layout(location = 0) in vec2  in_pos;
layout(location = 1) in vec2  in_uv;
layout(location = 2) in uint  in_col;    // RGBA8, little endian
layout(location = 3) in uint  in_tex;    // index into the bindless table
layout(location = 4) in vec4  in_rect;   // xy = centre, zw = half extent
layout(location = 5) in float in_radius; // < 0 disables the rounded-box mask
layout(location = 6) in uint  in_effect;
layout(location = 7) in float in_param;  // meaning depends on the effect

layout(location = 0)      out vec2  v_uv;
layout(location = 1)      out vec4  v_col;
layout(location = 2) flat out uint  v_tex;
layout(location = 3)      out vec2  v_pos;
layout(location = 4) flat out vec4  v_rect;
layout(location = 5) flat out float v_radius;
layout(location = 6) flat out uint  v_effect;
layout(location = 7) flat out float v_param;

void main() {
	gl_Position = vec4(in_pos * pc.inv_screen * 2.0 - 1.0, 0.0, 1.0);
	v_uv     = in_uv;
	v_col    = unpackUnorm4x8(in_col);
	v_tex    = in_tex;
	v_pos    = in_pos;
	v_rect   = in_rect;
	v_radius = in_radius;
	v_effect = in_effect;
	v_param  = in_param;
}
