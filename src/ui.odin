package spoticyclint

import "core:math"

// Immediate mode: there is no widget tree and nothing is retained between
// frames except two ids (what the mouse is over, and what it grabbed). Every
// frame rebuilds one vertex buffer; the bindless table means the whole thing
// usually leaves as a single draw call.

Rect :: struct {
	x, y, w, h: f32,
}

Color :: distinct u32

rgba :: proc "contextless" (r, g, b, a: u8) -> Color {
	return Color(u32(r) | u32(g) << 8 | u32(b) << 16 | u32(a) << 24)
}

rgb :: proc "contextless" (r, g, b: u8) -> Color {
	return rgba(r, g, b, 255)
}

color_alpha :: proc "contextless" (c: Color, a: f32) -> Color {
	v := u32(c)
	old := f32((v >> 24) & 0xff)
	return Color((v & 0x00ff_ffff) | u32(clamp(old * a, 0, 255)) << 24)
}

color_mix :: proc "contextless" (a, b: Color, t: f32) -> Color {
	out: u32
	for shift in ([4]u32{0, 8, 16, 24}) {
		ca := f32((u32(a) >> shift) & 0xff)
		cb := f32((u32(b) >> shift) & 0xff)
		out |= u32(clamp(ca + (cb - ca) * t, 0, 255)) << shift
	}
	return Color(out)
}

// Which shader path this vertex takes. Matches the EFFECT_* constants in
// src/shaders/ui.frag.
Effect :: enum u32 {
	None  = 0,
	Glow  = 1, // soft radial falloff
	Sheen = 2, // travelling highlight
	Ring   = 3, // fading annulus
	Wobble = 4, // artwork rippling like it is under water
}

Vertex :: struct {
	pos:    [2]f32,
	uv:     [2]f32,
	col:    Color,
	tex:    u32,
	rect:   [4]f32, // centre + half extent, for the rounded-corner mask
	radius: f32,
	effect: Effect,
	param:  f32, // what it means depends on the effect
}

DrawCmd :: struct {
	clip:         Rect,
	index_offset: u32,
	index_count:  u32,
}

UI :: struct {
	verts:      [dynamic]Vertex,
	indices:    [dynamic]u32,
	cmds:       [dynamic]DrawCmd,
	clip:       Rect,
	clip_stack: [dynamic]Rect,

	regular:    Font,
	bold:       Font,

	size:       [2]f32,
	mouse:      [2]f32,
	has_mouse:  bool,
	down:       bool,
	pressed:    bool,
	released:   bool,
	scroll:     f32,

	hot:        u64,
	active:     u64,

	// Animation state is the one thing that survives between frames, keyed by
	// widget id. Values chase a target so nothing in the UI snaps.
	dt:         f32,
	time:       f32, // seconds since start, for the animated shader effects
	anim:       map[u64]f32,
	animating:  bool, // set while any value is still chasing its target
	// Set when something on screen is driven by the shader clock, which only
	// advances on a redraw. Kept separate so it can be paced more loosely.
	time_effects: bool,
}

// Eases `id`'s stored value toward `target`. `speed` is roughly "how much of
// the remaining distance per second".
ui_anim :: proc(ui: ^UI, id: u64, target: f32, speed: f32 = 14) -> f32 {
	current := ui.anim[id]
	t := clamp(ui.dt * speed, 0, 1)
	next := current + (target - current) * t
	if abs(next - target) < 0.001 do next = target
	else do ui.animating = true
	ui.anim[id] = next
	return next
}

NO_ROUND :: f32(-1)

rect_contains :: proc "contextless" (r: Rect, p: [2]f32) -> bool {
	return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
}

rect_intersect :: proc "contextless" (a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	return Rect{x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}

rect_inset :: proc "contextless" (r: Rect, dx, dy: f32) -> Rect {
	return Rect{r.x + dx, r.y + dy, r.w - dx * 2, r.h - dy * 2}
}

// FNV-1a over the label, so widget identity survives layout changes.
ui_id :: proc "contextless" (label: string, index: int = 0) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i in 0 ..< len(label) {
		h = (h ~ u64(label[i])) * 0x100000001b3
	}
	h = (h ~ u64(index)) * 0x100000001b3
	return h
}

ui_begin :: proc(ui: ^UI, width, height: int, input: ^Input, dt: f32 = 1.0 / 60) {
	ui.dt = clamp(dt, 0, 0.1)
	ui.time += ui.dt
	clear(&ui.verts)
	clear(&ui.indices)
	clear(&ui.cmds)
	clear(&ui.clip_stack)

	ui.size = {f32(width), f32(height)}
	ui.clip = {0, 0, ui.size.x, ui.size.y}

	ui.mouse = input.mouse
	ui.has_mouse = input.has_mouse
	ui.down = input.down[0]
	ui.pressed = input.pressed[0]
	ui.released = input.released[0]
	ui.scroll = input.scroll
	ui.hot = 0
	ui.animating = false
	ui.time_effects = false
}

ui_end :: proc(ui: ^UI) {
	if !ui.down do ui.active = 0
}

ui_push_clip :: proc(ui: ^UI, r: Rect) {
	append(&ui.clip_stack, ui.clip)
	ui.clip = rect_intersect(ui.clip, r)
}

ui_pop_clip :: proc(ui: ^UI) {
	ui.clip = pop(&ui.clip_stack)
}

@(private = "file")
current_cmd :: proc(ui: ^UI) -> ^DrawCmd {
	if len(ui.cmds) > 0 {
		last := &ui.cmds[len(ui.cmds) - 1]
		if last.clip == ui.clip do return last
		if last.index_count == 0 {
			last.clip = ui.clip
			return last
		}
	}
	append(&ui.cmds, DrawCmd{clip = ui.clip, index_offset = u32(len(ui.indices))})
	return &ui.cmds[len(ui.cmds) - 1]
}

ui_quad :: proc(
	ui: ^UI,
	r: Rect,
	uv0, uv1: [2]f32,
	col: Color,
	tex: u32,
	radius: f32,
	effect: Effect = .None,
	param: f32 = 0,
) {
	if r.w <= 0 || r.h <= 0 do return
	if rect_intersect(r, ui.clip).w <= 0 do return

	cmd := current_cmd(ui)
	base := u32(len(ui.verts))
	shape := [4]f32{r.x + r.w / 2, r.y + r.h / 2, r.w / 2, r.h / 2}

	append(&ui.verts, Vertex{{r.x, r.y}, uv0, col, tex, shape, radius, effect, param})
	append(&ui.verts, Vertex{{r.x + r.w, r.y}, {uv1.x, uv0.y}, col, tex, shape, radius, effect, param})
	append(&ui.verts, Vertex{{r.x + r.w, r.y + r.h}, uv1, col, tex, shape, radius, effect, param})
	append(&ui.verts, Vertex{{r.x, r.y + r.h}, {uv0.x, uv1.y}, col, tex, shape, radius, effect, param})

	append(&ui.indices, base, base + 1, base + 2, base, base + 2, base + 3)
	cmd.index_count += 6
}

// The general case: four corners, each with its own position, texture
// coordinate and colour. Everything else here is a special case of it.
ui_quad_corners :: proc(
	ui: ^UI,
	p: [4][2]f32,
	uv: [4][2]f32,
	col: [4]Color,
	tex: u32,
	effect: Effect = .None,
) {
	cmd := current_cmd(ui)
	base := u32(len(ui.verts))
	shape := [4]f32{0, 0, 0, 0}

	for i in 0 ..< 4 {
		append(&ui.verts, Vertex{p[i], uv[i], col[i], tex, shape, NO_ROUND, effect, 0})
	}
	append(&ui.indices, base, base + 1, base + 2, base, base + 2, base + 3)
	cmd.index_count += 6
}

// A vertical fade, for laying text over artwork without it getting lost.
ui_gradient_v :: proc(ui: ^UI, r: Rect, top, bottom: Color) {
	if r.w <= 0 || r.h <= 0 do return
	if rect_intersect(r, ui.clip).w <= 0 do return
	ui_quad_corners(
		ui,
		{{r.x, r.y}, {r.x + r.w, r.y}, {r.x + r.w, r.y + r.h}, {r.x, r.y + r.h}},
		{{0, 0}, {1, 0}, {1, 1}, {0, 1}},
		{top, top, bottom, bottom},
		WHITE_TEX,
	)
}

// A card turning about its vertical axis. `turn` is -1..1, zero facing us.
// Not a real projection: the leading edge is made taller and the trailing edge
// shorter, which is what sells the rotation at this size.
ui_image_turn :: proc(ui: ^UI, r: Rect, tex: u32, turn: f32, tint: Color = 0xffffffff) {
	t := clamp(turn, -1, 1)
	squeeze := math.cos(t * math.PI * 0.5) // 1 face on, 0 edge on
	if abs(squeeze) < 0.002 do return

	cx := r.x + r.w / 2
	half_w := r.w / 2 * abs(squeeze)
	lean := math.sin(t * math.PI * 0.5) * 0.16 // how much perspective to fake

	left_h := r.h * (1 + lean) / 2
	right_h := r.h * (1 - lean) / 2
	cy := r.y + r.h / 2

	ui_quad_corners(
		ui,
		{
			{cx - half_w, cy - left_h},
			{cx + half_w, cy - right_h},
			{cx + half_w, cy + right_h},
			{cx - half_w, cy + left_h},
		},
		{{0, 0}, {1, 0}, {1, 1}, {0, 1}},
		{tint, tint, tint, tint},
		tex,
	)
}

// A flat triangle, used for the play and skip glyphs.
ui_tri :: proc(ui: ^UI, a, b, c: [2]f32, col: Color) {
	cmd := current_cmd(ui)
	base := u32(len(ui.verts))
	shape := [4]f32{0, 0, 0, 0}

	append(&ui.verts, Vertex{a, {0, 0}, col, WHITE_TEX, shape, NO_ROUND, .None, 0})
	append(&ui.verts, Vertex{b, {1, 0}, col, WHITE_TEX, shape, NO_ROUND, .None, 0})
	append(&ui.verts, Vertex{c, {1, 1}, col, WHITE_TEX, shape, NO_ROUND, .None, 0})
	append(&ui.indices, base, base + 1, base + 2)
	cmd.index_count += 3
}

ui_rect :: proc(ui: ^UI, r: Rect, col: Color, radius: f32 = NO_ROUND) {
	ui_quad(ui, r, {0, 0}, {1, 1}, col, WHITE_TEX, radius)
}

// A soft light source. Draw it behind whatever it should be lighting.
ui_glow :: proc(ui: ^UI, centre: [2]f32, radius: f32, col: Color) {
	r := Rect{centre.x - radius, centre.y - radius, radius * 2, radius * 2}
	ui_quad(ui, r, {0, 0}, {1, 1}, col, WHITE_TEX, NO_ROUND, .Glow)
}

// An expanding ring, for the ripple a click leaves behind.
ui_ring :: proc(ui: ^UI, centre: [2]f32, radius: f32, col: Color) {
	r := Rect{centre.x - radius, centre.y - radius, radius * 2, radius * 2}
	ui_quad(ui, r, {0, 0}, {1, 1}, col, WHITE_TEX, NO_ROUND, .Ring)
}

// A filled bar with a highlight travelling along it.
ui_rect_sheen :: proc(ui: ^UI, r: Rect, col: Color, radius: f32 = NO_ROUND) {
	ui.time_effects = true
	ui_quad(ui, r, {0, 0}, {1, 1}, col, WHITE_TEX, radius, .Sheen)
}

ui_circle :: proc(ui: ^UI, centre: [2]f32, radius: f32, col: Color) {
	ui_rect(ui, {centre.x - radius, centre.y - radius, radius * 2, radius * 2}, col, radius)
}

ui_image :: proc(ui: ^UI, r: Rect, tex: u32, radius: f32 = NO_ROUND, tint: Color = 0xffffffff) {
	ui_quad(ui, r, {0, 0}, {1, 1}, tint, tex, radius)
}

// Artwork with a ripple running through it. `amount` is roughly how far the
// surface bends, in texture coordinates; fade it to zero to settle.
ui_image_wobble :: proc(
	ui: ^UI,
	r: Rect,
	tex: u32,
	amount: f32,
	radius: f32 = NO_ROUND,
	tint: Color = 0xffffffff,
) {
	if amount <= 0.0005 {
		ui_image(ui, r, tex, radius, tint)
		return
	}
	ui.time_effects = true
	ui_quad(ui, r, {0, 0}, {1, 1}, tint, tex, radius, .Wobble, amount)
}

ui_text :: proc(
	ui: ^UI,
	font: ^Font,
	text: string,
	pos: [2]f32,
	size: f32,
	col: Color,
) -> f32 {
	scale := font_scale(font, size)
	pen := pos
	pen.y += font.ascent * scale // pos is the top-left of the line box

	for ch in text {
		i := int(ch) - FIRST_CHAR
		if i < 0 || i >= NUM_CHARS do i = int('?') - FIRST_CHAR
		b := font.chars[i]

		gw := f32(b.x1 - b.x0) * scale
		gh := f32(b.y1 - b.y0) * scale
		if gw > 0 && gh > 0 {
			r := Rect{pen.x + b.xoff * scale, pen.y + b.yoff * scale, gw, gh}
			uv0 := [2]f32{f32(b.x0) / ATLAS_SIZE, f32(b.y0) / ATLAS_SIZE}
			uv1 := [2]f32{f32(b.x1) / ATLAS_SIZE, f32(b.y1) / ATLAS_SIZE}
			ui_quad(ui, r, uv0, uv1, col, font.tex, NO_ROUND)
		}
		pen.x += b.xadvance * scale
	}
	return pen.x - pos.x
}

ui_text_centred :: proc(ui: ^UI, font: ^Font, text: string, r: Rect, size: f32, col: Color) {
	w := font_width(font, text, size)
	line := font.ascent - font.descent
	y := r.y + (r.h - line * font_scale(font, size)) / 2
	ui_text(ui, font, text, {r.x + (r.w - w) / 2, y}, size, col)
}

// Returns whether the pointer is inside `r`, honouring the current clip.
ui_hovered :: proc(ui: ^UI, r: Rect) -> bool {
	if !ui.has_mouse do return false
	if ui.active != 0 do return false
	return rect_contains(rect_intersect(r, ui.clip), ui.mouse)
}

// The whole button protocol: hot on hover, active while held, fires on release
// inside. No retained state beyond the two ids on UI.
ui_invisible_button :: proc(ui: ^UI, id: u64, r: Rect) -> (clicked: bool, hovered: bool) {
	hovered = ui_hovered(ui, r) || ui.active == id
	if hovered do ui.hot = id

	if ui.pressed && ui_hovered(ui, r) do ui.active = id
	if ui.released && ui.active == id {
		if rect_contains(rect_intersect(r, ui.clip), ui.mouse) do clicked = true
		ui.active = 0
	}
	return
}

// Drag-anywhere slider. Returns the value, changed while the pointer is held.
ui_slider :: proc(
	ui: ^UI,
	label: string,
	r: Rect,
	value: f32,
	track_col, fill_col, knob_col: Color,
) -> f32 {
	id := ui_id(label)
	_, hovered := ui_invisible_button(ui, id, r)

	value := clamp(value, 0, 1)
	if ui.active == id && r.w > 0 {
		value = clamp((ui.mouse.x - r.x) / r.w, 0, 1)
	}

	bar := Rect{r.x, r.y + r.h / 2 - 2, r.w, 4}
	ui_rect(ui, bar, track_col, 2)
	ui_rect(ui, {bar.x, bar.y, bar.w * value, bar.h}, fill_col, 2)
	if hovered || ui.active == id {
		ui_circle(ui, {bar.x + bar.w * value, bar.y + 2}, 5, knob_col)
	}
	return value
}

Scroll :: struct {
	offset:      f32, // eased toward target
	target:      f32,
	content:     f32,
	view_height: f32,
}

// Scrolls with the wheel and clamps to content. Draw items at
// `r.y - scroll.offset + i * row_height`, clipped to `r`.
ui_begin_scroll :: proc(ui: ^UI, r: Rect, s: ^Scroll, content_height: f32) {
	s.content = content_height
	s.view_height = r.h
	if ui_hovered(ui, r) {
		// One wheel notch arrives as ~10 units; this lands it near three rows.
		s.target -= ui.scroll * 28
	}
	s.target = clamp(s.target, 0, max(content_height - r.h, 0))

	// Chase the target so the wheel glides instead of jumping.
	t := clamp(ui.dt * 18, 0, 1)
	s.offset += (s.target - s.offset) * t
	if abs(s.target - s.offset) < 0.5 do s.offset = s.target
	else do ui.animating = true

	ui_push_clip(ui, r)
}

ui_end_scroll :: proc(ui: ^UI, r: Rect, s: ^Scroll, thumb: Color) {
	ui_pop_clip(ui)
	if s.content <= r.h do return

	track := Rect{r.x + r.w - 6, r.y, 3, r.h}
	frac := r.h / s.content
	h := max(track.h * frac, 24)
	y := track.y + (track.h - h) * clamp(s.offset / (s.content - r.h), 0, 1)
	ui_rect(ui, {track.x, y, track.w, h}, thumb, track.w / 2)
}

ui_destroy :: proc(ui: ^UI) {
	delete(ui.anim)
	delete(ui.verts)
	delete(ui.indices)
	delete(ui.cmds)
	delete(ui.clip_stack)
}
