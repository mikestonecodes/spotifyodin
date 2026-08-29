package spoticyclint

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import stbi "vendor:stb/image"

BG :: Color(0xff121212)
PANEL :: Color(0xff181818)
PANEL_HI :: Color(0xff242424)
ACCENT :: Color(0xff54b91d) // Spotify green, RGBA8 little endian
TEXT :: Color(0xffffffff)
MUTED :: Color(0xffb3b3b3)
DIM :: Color(0xff535353)
WARN :: Color(0xff4d4dff) // something needs the user's attention

// Ceiling on animation frames. Mailbox present does not block, so without a
// budget the loop would render as fast as the GPU allows for no visible gain.
FRAME_BUDGET :: 8 * time.Millisecond

BAR_H :: 92

// Grid of covers rather than a list: at this window width a row used maybe a
// third of it and left the rest empty.
TILE_MIN :: 150 // smallest a cover is allowed to get before dropping a column
TILE_GAP :: 14
TILE_LABEL :: 46 // title and artist under each cover

Command :: enum {
	None,
	Toggle,
	Next,
	Previous,
	Reshuffle,
}

Art :: struct {
	url:    string,
	pixels: []byte,
	width:  int,
	height: int,
}

// Everything the worker thread and the UI thread share. The UI never makes a
// network call, so a slow API response can't drop a frame.
Shared :: struct {
	mutex:        sync.Mutex,
	status:       string,
	status_error: bool,
	device:       string,
	tracks:       [dynamic]Track,
	loaded:       bool,
	quit:         bool,

	now_uri:      string,
	now_name:     string,
	now_artist:   string,
	now_art:      string,
	progress_ms:  int,
	duration_ms:  int,
	volume:       f32,
	volume_set:   f32, // >= 0 when the UI has moved the slider
	is_playing:   bool,
	last_poll:    time.Time,

	wake:         sync.Sema,
	commands:     [dynamic]Command,
	play_index:   int, // >= 0 means "start the queue here"
	seek_ms:      int, // >= 0 means "seek the current track here"

	art_wanted:   [dynamic]string,
	art_ready:    [dynamic]Art,
	art_inflight: map[string]bool,
}

App :: struct {
	win:     Window,
	gpu:     Gpu,
	ui:      UI,
	client:  Client,
	shared:  Shared,
	scroll:  Scroll,
	art:     map[string]u32,
	worker:  ^thread.Thread,
	art_thread: ^thread.Thread,

	saved_volume: f32,

	// Set when the playing track changes, so the grid can react to it.
	last_now_uri: string,
	pulse:        f32, // 1 -> 0 right after a change
	pulse_index:  int,

	// Owned by the worker, but the UI thread calls the audio-only operations
	// on it directly: those touch nothing but a mutex-guarded buffer, and
	// routing them through the worker queue added a 100ms delay to every
	// pause, seek and volume change.
	player:  Player,
}

run_ui :: proc(client: Client, device: string) {
	app := new(App)
	defer free(app)
	app.client = client
	app.shared.play_index = -1
	app.shared.seek_ms = -1
	app.shared.volume = load_settings().volume
	app.shared.volume_set = -1
	app.shared.status = strings.clone("connecting...")
	app.shared.device = strings.clone(device)

	if !window_open(&app.win, "spoticyclint", 1000, 720) do return
	defer window_close(&app.win)

	if !gpu_init(&app.gpu, &app.win) do return
	defer gpu_destroy(&app.gpu)

	// Slot 0 and 1 of the bindless table are fixed by convention.
	// Bake the atlas at the display's pixel density so text stays crisp.
	atlas_px := 34 * f32(app.win.scale)
	regular, r_ok := font_load(&app.gpu, "/usr/share/fonts/noto/NotoSans-Regular.ttf", atlas_px)
	white := [4]byte{255, 255, 255, 255}
	white_slot := texture_upload(&app.gpu, white[:], 1, 1, 4)
	bold, b_ok := font_load(&app.gpu, "/usr/share/fonts/noto/NotoSans-Bold.ttf", atlas_px)
	if !r_ok || !b_ok || white_slot != WHITE_TEX {
		fmt.eprintln("could not set up fonts")
		return
	}
	app.ui.regular = regular
	app.ui.bold = bold
	defer ui_destroy(&app.ui)

	app.worker = thread.create_and_start_with_poly_data(app, worker_main)
	app.art_thread = thread.create_and_start_with_poly_data(&app.shared, art_worker)

	last_frame := time.now()
	last_draw := time.now()
	last_state: Frame_State
	needs_draw := true

	// SPOTICYCLINT_PROFILE=1 prints where the frame time actually goes.
	profile := os.get_env("SPOTICYCLINT_PROFILE", context.temp_allocator) != ""
	prof_window := time.now()
	prof_frames, prof_draws := 0, 0
	prof_draw_ns, prof_art_ns, prof_build_ns: f64
	prof_worst: f64

	for !app.win.should_close {
		// Nothing to draw means nothing to burn: wait on the compositor rather
		// than spinning. Mid-animation the wait is only as long as the frame
		// budget, so animation stays smooth without running flat out; input
		// cuts any of these waits short, so clicks are still handled at once.
		timeout: i32 = 500
		if needs_draw {
			left := FRAME_BUDGET - time.since(last_draw)
			timeout = left > 0 ? i32(time.duration_milliseconds(left)) : 0
		} else if last_state.playing {
			timeout = 200
		}
		window_poll(&app.win, timeout)

		now := time.now()
		dt := f32(time.duration_seconds(time.diff(last_frame, now)))
		last_frame = now

		if app.win.resized {
			app.gpu.ui_scale = f32(app.win.scale)
			gpu_resize(&app.gpu, window_pixel_size(&app.win))
			needs_draw = true
		}
		art_start := time.now()
		if upload_pending_art(app) do needs_draw = true
		prof_art_ns += time.duration_milliseconds(time.since(art_start))
		if window_has_input(&app.win) do needs_draw = true
		handle_keys(app)

		state := frame_state(app)
		if state != last_state {
			last_state = state
			needs_draw = true
		}
		// Hold to the frame budget even when the compositor is handing us a
		// stream of pointer motion: the poll timeout alone does not cap this,
		// because poll returns the moment an event arrives.
		if needs_draw {
			ahead := FRAME_BUDGET - time.since(last_draw)
			if ahead > 0 do time.sleep(ahead)
		}

		prof_frames += 1
		if !needs_draw {
			if profile do report_profile(&prof_window, &prof_frames, &prof_draws, &prof_draw_ns, &prof_art_ns, &prof_build_ns, &prof_worst)
			continue
		}

		last_draw = time.now()
		build_start := time.now()
		ui_begin(&app.ui, app.win.width, app.win.height, &app.win.input, dt)
		draw_app(app)
		ui_end(&app.ui)
		build_ms := time.duration_milliseconds(time.since(build_start))
		prof_build_ns += build_ms

		draw_start := time.now()
		if !gpu_draw(&app.gpu, &app.ui, BG) {
			gpu_resize(&app.gpu, window_pixel_size(&app.win))
		}
		draw_ms := time.duration_milliseconds(time.since(draw_start))
		prof_draw_ns += draw_ms
		prof_draws += 1
		prof_worst = max(prof_worst, build_ms + draw_ms)

		if profile do report_profile(&prof_window, &prof_frames, &prof_draws, &prof_draw_ns, &prof_art_ns, &prof_build_ns, &prof_worst)

		// Keep drawing while something is still moving. Shader-clock effects
		// also need frames, but they are slow enough to pace loosely.
		needs_draw = app.ui.animating
		if !needs_draw && app.ui.time_effects {
			needs_draw = time.since(last_draw) >= 24 * time.Millisecond
		}

		// Everything the frame scratched goes back. Without this the UI grows
		// its temp arena every frame until the whole app crawls.
		free_all(context.temp_allocator)
	}

	sync.guard(&app.shared.mutex)
	app.shared.quit = true
}

// Everything the window shows, boiled down to something comparable. If this
// hasn't changed and nothing is animating, the last frame is still correct and
// there is no reason to draw another one.
@(private = "file")
report_profile :: proc(window: ^time.Time, frames, draws: ^int, draw, art, build, worst: ^f64) {
	if time.duration_seconds(time.since(window^)) < 1 do return
	fmt.eprintfln(
		"%3d frames, %3d drawn | build %5.2fms  gpu %5.2fms  art %5.2fms | worst %5.2fms",
		frames^,
		draws^,
		build^ / f64(max(draws^, 1)),
		draw^ / f64(max(draws^, 1)),
		art^,
		worst^,
	)
	window^ = time.now()
	frames^, draws^ = 0, 0
	draw^, art^, build^, worst^ = 0, 0, 0, 0
}

@(private = "file")
Frame_State :: struct {
	now_uri:      u64,
	status:       u64,
	playing:      bool,
	loaded:       bool,
	half_second:  int,
	duration:     int,
	count:        int,
	art_count:    int,
	volume:       f32,
	scroll:       f32,
	width:        int,
	height:       int,
}

@(private = "file")
frame_state :: proc(app: ^App) -> (fs: Frame_State) {
	s := &app.shared
	sync.lock(&s.mutex)
	fs.now_uri = ui_id(s.now_uri)
	fs.status = ui_id(s.status)
	fs.playing = s.is_playing
	fs.loaded = s.loaded
	fs.half_second = s.progress_ms / 500
	fs.duration = s.duration_ms
	fs.count = len(s.tracks)
	fs.volume = s.volume
	sync.unlock(&s.mutex)

	fs.art_count = len(app.art)
	fs.scroll = app.scroll.target
	fs.width = app.win.width
	fs.height = app.win.height
	return
}

@(private = "file")
handle_keys :: proc(app: ^App) {
	if window_key_pressed(&app.win, KEY_ESC) || window_key_pressed(&app.win, KEY_Q) {
		app.win.should_close = true
	}
	if window_key_pressed(&app.win, KEY_SPACE) do toggle_playback(app)
	if window_key_pressed(&app.win, KEY_RIGHT) do push_command(app, .Next)
	if window_key_pressed(&app.win, KEY_LEFT) do push_command(app, .Previous)
	if window_key_pressed(&app.win, KEY_R) do push_command(app, .Reshuffle)

	step: f32 = 0
	if window_key_pressed(&app.win, KEY_UP) do step = 0.05
	if window_key_pressed(&app.win, KEY_DOWN) do step = -0.05
	if step != 0 {
		sync.lock(&app.shared.mutex)
		app.shared.volume = clamp(app.shared.volume + step, 0, 1)
		volume := app.shared.volume
		sync.unlock(&app.shared.mutex)
		player_set_volume(&app.player, volume)
	}
}

@(private = "file")
push_command :: proc(app: ^App, cmd: Command) {
	sync.lock(&app.shared.mutex)
	append(&app.shared.commands, cmd)
	sync.unlock(&app.shared.mutex)
	sync.sema_post(&app.shared.wake)
}

// ---------------------------------------------------------------- rendering

@(private = "file")
draw_app :: proc(app: ^App) {
	ui := &app.ui
	s := &app.shared
	w, h := ui.size.x, ui.size.y

	sync.lock(&s.mutex)
	status := strings.clone(s.status, context.temp_allocator)
	status_error := s.status_error
	device := strings.clone(s.device, context.temp_allocator)
	loaded := s.loaded
	count := len(s.tracks)
	now_uri := strings.clone(s.now_uri, context.temp_allocator)
	now_name := strings.clone(s.now_name, context.temp_allocator)
	now_artist := strings.clone(s.now_artist, context.temp_allocator)
	is_playing := s.is_playing
	duration := s.duration_ms
	progress := s.progress_ms
	since := time.duration_milliseconds(time.since(s.last_poll))
	sync.unlock(&s.mutex)

	// The player only tells us where it is once a second; run the bar forward
	// in between so it doesn't visibly tick.
	if is_playing do progress = min(progress + int(since), duration)

	list := Rect{0, 0, w, h - BAR_H}
	if loaded && count > 0 {
		draw_queue(app, list, now_uri, progress, duration)
	} else {
		ui_text_centred(ui, &ui.regular, status, list, 18, status_error ? WARN : MUTED)
	}

	draw_now_playing(
		app,
		Rect{0, h - BAR_H, w, BAR_H},
		now_name,
		now_artist,
		is_playing,
		progress,
		duration,
		status,
		status_error,
	)
}

@(private = "file")
Grid :: struct {
	cols:   int,
	tile:   f32, // cover edge, square
	cell_w: f32,
	cell_h: f32,
}

@(private = "file")
grid_for :: proc(width: f32) -> (g: Grid) {
	usable := width - TILE_GAP
	g.cols = max(int(usable / (TILE_MIN + TILE_GAP)), 2)
	g.cell_w = usable / f32(g.cols)
	g.tile = g.cell_w - TILE_GAP
	g.cell_h = g.tile + TILE_LABEL
	return
}

@(private = "file")
draw_queue :: proc(app: ^App, r: Rect, now_uri: string, progress, duration: int) {
	ui := &app.ui
	s := &app.shared

	sync.lock(&s.mutex)
	count := len(s.tracks)
	sync.unlock(&s.mutex)

	g := grid_for(r.w)
	rows := (count + g.cols - 1) / g.cols
	ui_begin_scroll(ui, r, &app.scroll, f32(rows) * g.cell_h + TILE_GAP)

	first_row := max(int(app.scroll.offset / g.cell_h) - 1, 0)
	last_row := min(first_row + int(r.h / g.cell_h) + 3, rows)
	first := first_row * g.cols
	last := min(last_row * g.cols, count)

	// One lock for everything on screen, rather than one per tile per frame.
	visible := make([]Track, max(last - first, 0), context.temp_allocator)
	sync.lock(&s.mutex)
	for i in first ..< last do visible[i - first] = s.tracks[i]
	sync.unlock(&s.mutex)

	// Notice a track change here rather than in the worker, so the animation
	// starts on the frame the UI first sees it.
	if now_uri != app.last_now_uri {
		delete(app.last_now_uri)
		app.last_now_uri = strings.clone(now_uri)
		app.pulse = 1
		app.pulse_index = -1
		sync.lock(&s.mutex)
		for t, i in s.tracks {
			if t.uri == now_uri {
				app.pulse_index = i
				break
			}
		}
		sync.unlock(&s.mutex)
	}
	if app.pulse > 0 {
		app.pulse = max(app.pulse - ui.dt * 1.6, 0)
		ui.animating = true
	}

	for track, vi in visible {
		i := first + vi
		col := i % g.cols
		row := i / g.cols

		cell := Rect {
			r.x + TILE_GAP + f32(col) * g.cell_w,
			r.y - app.scroll.offset + TILE_GAP + f32(row) * g.cell_h,
			g.tile,
			g.cell_h - TILE_GAP,
		}
		if cell.y > r.y + r.h || cell.y + cell.h < r.y do continue

		is_now := track.uri == now_uri
		id := ui_id("tile", i)
		clicked, hovered := ui_invisible_button(ui, id, cell)
		if clicked do request_play_index(app, i)

		// Covers lift toward the pointer and settle back; the playing one
		// stays lifted.
		lift := ui_anim(ui, id, hovered ? 1 : 0, 16)
		glow := ui_anim(ui, id ~ 1, is_now ? 1 : 0, 10)
		press := ui_anim(ui, id ~ 2, ui.active == id ? 1 : 0, 26)

		// The cover that just started swells and settles.
		pulse := i == app.pulse_index ? app.pulse : 0
		pop := pulse * pulse * 0.14
		scale := 1 + lift * 0.05 + glow * 0.02 - press * 0.05 + pop

		cover := Rect{cell.x, cell.y, g.tile, g.tile}
		grow := g.tile * (scale - 1) / 2
		cover = rect_inset(cover, -grow, -grow)
		radius := g.tile * 0.06

		// Accent ring behind the playing cover, plus a halo that breathes.
		if glow > 0.01 {
			ring := rect_inset(cover, -3 - glow * 2, -3 - glow * 2)
			ui_rect(ui, ring, color_alpha(ACCENT, glow), radius + 4)
			ui_glow(
				ui,
				{cover.x + cover.w / 2, cover.y + cover.h / 2},
				g.tile * (0.85 + pulse * 0.35),
				color_alpha(ACCENT, 0.22 * glow + pulse * 0.35),
			)
		}

		// ... and a ring thrown outward at the moment it starts.
		if pulse > 0.02 {
			ui_ring(
				ui,
				{cover.x + cover.w / 2, cover.y + cover.h / 2},
				g.tile * (0.55 + (1 - pulse) * 0.7),
				color_alpha(ACCENT, pulse * 0.8),
			)
		}

		slot, has_art := app.art[track.art_url]
		if !has_art do want_art(app, track.art_url)

		// Art fades in instead of popping.
		fade := ui_anim(ui, id ~ 3, has_art ? 1 : 0, 8)
		ui_rect(ui, cover, PANEL_HI, radius)
		if has_art && fade > 0.01 {
			ui_image(ui, cover, slot, radius, rgba(255, 255, 255, u8(255 * fade)))
		}

		// Hovering brightens the cover a little.
		if lift > 0.01 {
			ui_rect(ui, cover, rgba(255, 255, 255, u8(18 * lift)), radius)
		}

		// The playing cover carries its own progress along the bottom edge.
		if glow > 0.5 && duration > 0 {
			frac := clamp(f32(progress) / f32(duration), 0, 1)
			bar := Rect{cover.x, cover.y + cover.h - 5, cover.w, 5}
			ui_rect(ui, bar, rgba(0, 0, 0, 130), 2.5)
			ui_rect(ui, {bar.x, bar.y, bar.w * frac, bar.h}, ACCENT, 2.5)
		}

		text_w := g.tile - 4
		title := font_ellipsize(&ui.bold, track.name, 14, text_w)
		artist := font_ellipsize(&ui.regular, track.artist, 12, text_w)
		ui_text(ui, &ui.bold, title, {cell.x + 2, cell.y + g.tile + 8}, 14, is_now ? ACCENT : TEXT)
		ui_text(ui, &ui.regular, artist, {cell.x + 2, cell.y + g.tile + 26}, 12, MUTED)
	}

	ui_end_scroll(ui, r, &app.scroll, DIM)
}

// Minimal on purpose: the grid already shows what is playing, so the bar is
// only the things you reach for — a scrub line, the transport, and volume.
@(private = "file")
draw_now_playing :: proc(
	app: ^App,
	r: Rect,
	name, artist: string,
	is_playing: bool,
	progress, duration: int,
	status: string,
	status_error: bool,
) {
	ui := &app.ui
	ui_rect(ui, r, PANEL)

	// The scrub line runs the full width along the top edge of the bar, and
	// thickens when you go near it.
	hit := Rect{r.x, r.y - 6, r.w, 20}
	seek_clicked, seek_hovered := ui_invisible_button(ui, ui_id("seek"), hit)
	grow := ui_anim(ui, ui_id("seekgrow"), seek_hovered || ui.active == ui_id("seek") ? 1 : 0, 18)

	line_h := 3 + grow * 5
	line := Rect{r.x, r.y, r.w, line_h}
	ui_rect(ui, line, rgba(255, 255, 255, 20))

	frac := duration > 0 ? clamp(f32(progress) / f32(duration), 0, 1) : 0
	if frac > 0 {
		fill := Rect{line.x, line.y, line.w * frac, line_h}
		if grow > 0.01 do ui_rect_sheen(ui, fill, ACCENT)
		else do ui_rect(ui, fill, ACCENT)
		// A little light spills off the playhead.
		ui_glow(ui, {fill.x + fill.w, line.y + line_h / 2}, 14 + grow * 10, color_alpha(ACCENT, 0.5))
	}
	if grow > 0.01 && duration > 0 {
		ui_circle(ui, {line.x + line.w * frac, line.y + line_h / 2}, 4 + grow * 4, TEXT)
	}
	if seek_clicked && duration > 0 {
		request_seek(app, int(clamp((ui.mouse.x - line.x) / line.w, 0, 1) * f32(duration)))
	}

	cy := r.y + (r.h + line_h) / 2

	// Times sit at the edges, quiet.
	ui_text(ui, &ui.regular, ms_to_time(progress), {r.x + 22, cy - 8}, 13, MUTED)
	total := ms_to_time(duration)
	ui_text(ui, &ui.regular, total, {r.w - 22 - font_width(&ui.regular, total, 13), cy - 8}, 13, MUTED)

	// Transport, centred.
	cx := r.w / 2
	if transport_button(ui, "prev", Rect{cx - 104, cy - 23, 46, 46}, .Previous_Icon, false) {
		push_command(app, .Previous)
	}
	if transport_button(ui, "play", Rect{cx - 31, cy - 31, 62, 62}, is_playing ? .Pause_Icon : .Play_Icon, true) {
		toggle_playback(app)
	}
	if transport_button(ui, "next", Rect{cx + 58, cy - 23, 46, 46}, .Next_Icon, false) {
		push_command(app, .Next)
	}

	// Volume, deliberately large.
	sync.lock(&app.shared.mutex)
	volume := app.shared.volume
	sync.unlock(&app.shared.mutex)

	vol := Rect{r.w - 300, cy - 14, 210, 28}
	draw_speaker(ui, {vol.x - 30, cy}, volume, MUTED)
	new_volume := volume_slider(ui, vol, volume)
	if new_volume != volume {
		player_set_volume(&app.player, new_volume)
		sync.guard(&app.shared.mutex)
		app.shared.volume = new_volume
	}

	// Errors are the only thing worth words down here.
	if status_error {
		ui_text(ui, &ui.regular, font_ellipsize(&ui.regular, status, 12, 300), {r.x + 22, cy + 14}, 12, WARN)
	}
}

// Chunky and glowing: this is the one control that wants to be grabbable.
@(private = "file")
volume_slider :: proc(ui: ^UI, r: Rect, value: f32) -> f32 {
	id := ui_id("volume")
	_, hovered := ui_invisible_button(ui, id, r)
	held := ui.active == id
	feel := ui_anim(ui, id ~ 7, hovered || held ? 1 : 0, 18)

	value := clamp(value, 0, 1)
	if held && r.w > 0 do value = clamp((ui.mouse.x - r.x) / r.w, 0, 1)

	h := 6 + feel * 4
	bar := Rect{r.x, r.y + r.h / 2 - h / 2, r.w, h}
	ui_rect(ui, bar, rgba(255, 255, 255, 24), h / 2)

	if value > 0 {
		fill := Rect{bar.x, bar.y, bar.w * value, h}
		if feel > 0.01 do ui_rect_sheen(ui, fill, ACCENT, h / 2)
		else do ui_rect(ui, fill, ACCENT, h / 2)
		ui_glow(ui, {fill.x + fill.w, bar.y + h / 2}, 16 + feel * 12, color_alpha(ACCENT, 0.45))
	}

	knob := 7 + feel * 4
	ui_circle(ui, {bar.x + bar.w * value, bar.y + h / 2}, knob, TEXT)
	return value
}

Icon :: enum {
	Play_Icon,
	Pause_Icon,
	Next_Icon,
	Previous_Icon,
}

// Grows toward the pointer, dips when pressed, throws a ripple when it fires,
// and the primary button carries a glow that breathes.
@(private = "file")
transport_button :: proc(ui: ^UI, label: string, r: Rect, icon: Icon, primary: bool) -> bool {
	id := ui_id(label)
	clicked, hovered := ui_invisible_button(ui, id, r)

	press := ui_anim(ui, id ~ 2, ui.active == id ? 1 : 0, 30)
	hover := ui_anim(ui, id, hovered ? 1 : 0, 18)
	// Rises to 1 the moment it is clicked, then falls back on its own.
	ripple := ui_anim(ui, id ~ 5, clicked ? 1 : 0, clicked ? 60 : 3)
	scale := 1 + hover * 0.10 - press * 0.14

	c := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
	radius := r.w / 2 * scale

	if ripple > 0.02 {
		ui_ring(ui, c, radius * (1 + (1 - ripple) * 1.5), color_alpha(ACCENT, ripple * 0.7))
	}

	if primary {
		ui_glow(ui, c, radius * (2.1 + hover * 0.5), color_alpha(ACCENT, 0.30 + hover * 0.35))
		ui_circle(ui, c, radius, color_mix(TEXT, ACCENT, hover * 0.85))
	} else if hover > 0.01 {
		ui_circle(ui, c, radius, rgba(255, 255, 255, u8(26 * hover)))
	}

	fg := primary ? BG : color_mix(MUTED, TEXT, hover)
	draw_icon(ui, c, r.w * 0.3 * scale, icon, fg)
	return clicked
}

@(private = "file")
draw_icon :: proc(ui: ^UI, c: [2]f32, size: f32, icon: Icon, col: Color) {
	switch icon {
	// A triangle's visual weight sits at its centroid, a third of the way from
	// the base — so centring the bounding box leaves it looking pushed left.
	// These all balance on the centroid instead.
	case .Play_Icon:
		h := size * 1.05
		w := h * 1.45
		x := c.x - w / 3 // centroid lands on c.x
		ui_tri(ui, {x, c.y - h}, {x + w, c.y}, {x, c.y + h}, col)

	case .Pause_Icon:
		bar := size * 0.4
		gap := size * 0.28
		ui_rect(ui, {c.x - gap - bar, c.y - size, bar, size * 2}, col, bar / 3)
		ui_rect(ui, {c.x + gap, c.y - size, bar, size * 2}, col, bar / 3)

	case .Next_Icon:
		// Triangle plus stop bar, balanced as one glyph about c.x.
		w := size * 1.25
		bar := size * 0.3
		left := c.x - (w + bar * 1.5) / 2
		ui_tri(ui, {left, c.y - size}, {left + w, c.y}, {left, c.y + size}, col)
		ui_rect(ui, {left + w + bar * 0.2, c.y - size, bar, size * 2}, col, bar / 3)

	case .Previous_Icon:
		w := size * 1.25
		bar := size * 0.3
		right := c.x + (w + bar * 1.5) / 2
		ui_tri(ui, {right, c.y - size}, {right - w, c.y}, {right, c.y + size}, col)
		ui_rect(ui, {right - w - bar * 1.2, c.y - size, bar, size * 2}, col, bar / 3)
	}
}

// A speaker whose waves come and go with the level.
@(private = "file")
draw_speaker :: proc(ui: ^UI, c: [2]f32, volume: f32, col: Color) {
	ui_rect(ui, {c.x - 7, c.y - 3, 4, 6}, col, 1)
	ui_tri(ui, {c.x - 3, c.y - 7}, {c.x + 2, c.y - 7}, {c.x - 3, c.y}, col)
	ui_tri(ui, {c.x - 3, c.y}, {c.x + 2, c.y + 7}, {c.x - 3, c.y + 7}, col)
	ui_rect(ui, {c.x - 1, c.y - 7, 3, 14}, col, 1)

	if volume > 0.05 do ui_rect(ui, {c.x + 4, c.y - 2, 2, 4}, col, 1)
	if volume > 0.45 do ui_rect(ui, {c.x + 7, c.y - 4, 2, 8}, col, 1)
	if volume > 0.8 do ui_rect(ui, {c.x + 10, c.y - 6, 2, 12}, col, 1)
}

@(private = "file")
ms_to_time :: proc(ms: int) -> string {
	total := ms / 1000
	return fmt.tprintf("%d:%02d", total / 60, total % 60)
}

// The worker publishes the current track's art url when it changes, so this
// never has to walk the library — that scan, once per frame with the mutex
// held, was what made the whole window feel heavy.
@(private = "file")
current_art_slot :: proc(app: ^App) -> (u32, bool) {
	sync.lock(&app.shared.mutex)
	url := strings.clone(app.shared.now_art, context.temp_allocator)
	sync.unlock(&app.shared.mutex)

	if url == "" do return 0, false
	slot, ok := app.art[url]
	if !ok do want_art(app, url)
	return slot, ok
}

// ------------------------------------------------------------------ art I/O

@(private = "file")
want_art :: proc(app: ^App, url: string) {
	if url == "" do return
	if bindless_full(&app.gpu) do return
	if _, have := app.art[url]; have do return

	sync.guard(&app.shared.mutex)
	if app.shared.art_inflight[url] do return
	app.shared.art_inflight[url] = true
	append(&app.shared.art_wanted, strings.clone(url))
}

// Each upload waits on the queue, so a scroll that queues fifty covers would
// stall the frame. Take a few per frame; the rest wait their turn.
ART_UPLOADS_PER_FRAME :: 4

// Covers are stored at this size. A tile is ~170-200 logical pixels, so this
// is sharp, and it keeps a full bindless table down to a sane amount of VRAM.
ART_TEXTURE_PX :: 224

@(private = "file")
upload_pending_art :: proc(app: ^App) -> (uploaded: bool) {
	ready: [ART_UPLOADS_PER_FRAME]Art
	count := 0

	sync.lock(&app.shared.mutex)
	for count < ART_UPLOADS_PER_FRAME && len(app.shared.art_ready) > 0 {
		ready[count] = pop_front(&app.shared.art_ready)
		count += 1
	}
	sync.unlock(&app.shared.mutex)

	// Uploading touches the GPU queue, so it happens here on the render thread.
	for a in ready[:count] {
		app.art[a.url] = texture_upload(&app.gpu, a.pixels, a.width, a.height, 4)
		delete(a.pixels)
	}
	return count > 0
}

// ------------------------------------------------------------------- worker

@(private = "file")
request_play_index :: proc(app: ^App, index: int) {
	sync.lock(&app.shared.mutex)
	app.shared.play_index = index
	sync.unlock(&app.shared.mutex)
	sync.sema_post(&app.shared.wake)
}

@(private = "file")
// Applied straight away on the UI thread; the shared copy is updated too so
// the next frame draws the new position without waiting for the worker.
request_seek :: proc(app: ^App, ms: int) {
	player_seek(&app.player, ms)
	sync.guard(&app.shared.mutex)
	app.shared.progress_ms = ms
}

toggle_playback :: proc(app: ^App) {
	playing := player_toggle(&app.player)
	sync.guard(&app.shared.mutex)
	app.shared.is_playing = playing
}

// Uses the cached library when the song count still matches, so a restart is
// one request instead of eighty.
@(private = "file")
load_or_fetch_library :: proc(c: Client, s: ^Shared) -> ([dynamic]Track, bool) {
	tracks, complete, hit := load_library()

	if hit && complete {
		set_status(s, fmt.tprintf("%d songs (cached)", len(tracks)))
		total, known := get_liked_total(c)
		if !known || total == len(tracks) do return tracks, true

		set_status(s, "library changed, reloading...")
		for t in tracks do free_track(t)
		clear(&tracks)
	} else if hit {
		set_status(s, fmt.tprintf("resuming from %d songs...", len(tracks)))
	} else {
		set_status(s, "loading liked songs...")
	}

	done := get_liked_tracks(c, &tracks, on_load_progress, s)
	// Save either way: a partial library is a head start, not a failure.
	save_library(tracks[:], done)
	return tracks, done
}

@(private = "file")
on_load_progress :: proc(done, total: int, user: rawptr) {
	set_status(cast(^Shared)user, fmt.tprintf("loading %d / %d songs...", done, total))
}

// The worker owns the library, the shuffle and the player. It never touches
// the GPU and the UI thread never makes a network call, so neither can stall
// the other.
@(private = "file")
worker_main :: proc(app: ^App) {
	s := &app.shared
	c := app.client

	// A failed load must not kill the session: Spotify rate-limits this
	// endpoint, and the window should recover on its own rather than needing a
	// restart.
	tracks: [dynamic]Track
	for attempt := 0; ; attempt += 1 {
		loaded: bool
		tracks, loaded = load_or_fetch_library(c, s)
		if loaded do break

		wait := min(30 << uint(min(attempt, 3)), 240)
		set_status(s, fmt.tprintf("Spotify is rate limiting; retrying in %ds", wait), true)
		if worker_sleep(s, wait) do return
	}

	pool := tracks[:]
	order := smart_shuffle(pool)

	sync.lock(&s.mutex)
	append(&s.tracks, ..order)
	s.loaded = true
	sync.unlock(&s.mutex)
	set_status(s, fmt.tprintf("%d songs", len(order)))

	player := &app.player
	for attempt := 0; !player_init(player, c); attempt += 1 {
		wait := min(5 << uint(min(attempt, 4)), 60)
		set_status(s, fmt.tprintf("player unavailable; retrying in %ds", wait), true)
		if worker_sleep(s, wait) do return
	}
	defer player_destroy(player)

	sync.lock(&s.mutex)
	volume := s.volume
	sync.unlock(&s.mutex)
	player_set_volume(player, volume)
	app.saved_volume = volume

	sync.lock(&s.mutex)
	delete(s.device)
	s.device = strings.clone("native")
	sync.unlock(&s.mutex)

	index := -1
	load_index := 0 // < 0 means "nothing to load"

	for {
		sync.lock(&s.mutex)
		quit := s.quit
		cmds := make([]Command, len(s.commands), context.temp_allocator)
		copy(cmds, s.commands[:])
		clear(&s.commands)
		play_index := s.play_index
		s.play_index = -1
		seek_ms := s.seek_ms
		s.seek_ms = -1
		sync.unlock(&s.mutex)

		if quit do return

		for cmd in cmds {
			switch cmd {
			case .None:
			case .Toggle:
				if index < 0 do load_index = 0
				else do player_toggle(player)
			case .Next:
				load_index = index + 1
			case .Previous:
				// Restart the track first, like every other player.
				pos := player_position(player)
				if pos.position_ms > 3000 do player_seek(player, 0)
				else do load_index = index - 1
			case .Reshuffle:
				new_order := smart_shuffle(pool)
				sync.lock(&s.mutex)
				clear(&s.tracks)
				append(&s.tracks, ..new_order)
				sync.unlock(&s.mutex)
				delete(order)
				order = new_order
				load_index = 0
			}
		}

		if seek_ms >= 0 do player_seek(player, seek_ms)

		if play_index >= 0 do load_index = play_index

		// A track that ran out advances the queue.
		if player_track_ended(player) && load_index < 0 do load_index = index + 1

		if load_index >= 0 {
			next := load_index
			load_index = -1
			if next >= len(order) do next = 0
			if next < 0 do next = len(order) - 1

			set_status(s, fmt.tprintf("loading %s...", order[next].name))
			if player_load(player, order[next].uri) {
				index = next
				publish_track(s, order[index])
				sync.lock(&s.mutex)
				s.is_playing = true
				sync.unlock(&s.mutex)
				set_status(s, fmt.tprintf("%d songs", len(order)))
				// Get the following track ready while this one plays.
				if index + 1 < len(order) do player_preload(player, order[index + 1].uri)
			} else {
				set_status(s, fmt.tprintf("could not play %s", order[next].name), true)
				// Skip past a track we cannot play rather than wedging.
				index = next
				load_index = next + 1
				if worker_sleep(s, 1) do return
			}
		}

		// Persist the volume once it stops moving, not on every drag frame.
		sync.lock(&s.mutex)
		current_volume := s.volume
		sync.unlock(&s.mutex)
		if abs(current_volume - app.saved_volume) > 0.001 {
			app.saved_volume = current_volume
			save_settings(Settings{volume = current_volume})
		}

		pos := player_position(player)
		sync.lock(&s.mutex)
		s.progress_ms = pos.position_ms
		s.duration_ms = pos.duration_ms
		s.is_playing = pos.playing
		s.last_poll = time.now()
		sync.unlock(&s.mutex)

		free_all(context.temp_allocator)

		// Wake instantly when the UI queues something; otherwise tick often
		// enough to notice a track ending.
		sync.sema_wait_with_timeout(&s.wake, 100 * time.Millisecond)
	}
}

@(private = "file")
publish_track :: proc(s: ^Shared, t: Track) {
	sync.guard(&s.mutex)
	delete(s.now_uri)
	delete(s.now_name)
	delete(s.now_artist)
	s.now_uri = strings.clone(t.uri)
	s.now_name = strings.clone(t.name)
	s.now_artist = strings.clone(t.artist)
	s.now_art = strings.clone(t.art_url)
}

// Sleeps in one-second steps so a quit is noticed promptly. Returns true if the
// worker should stop.
@(private = "file")
worker_sleep :: proc(s: ^Shared, seconds: int) -> bool {
	for _ in 0 ..< seconds {
		sync.lock(&s.mutex)
		quit := s.quit
		sync.unlock(&s.mutex)
		if quit do return true
		time.sleep(time.Second)
	}
	return false
}

// Covers are fetched on their own thread. They used to be fetched inline in
// the worker loop, which meant a screenful of new rows could hold up the next
// playback-state publish for seconds — the play button stayed a play button
// while the music was already going.
@(private = "file")
art_worker :: proc(s: ^Shared) {
	for {
		sync.lock(&s.mutex)
		quit := s.quit
		url: string
		if len(s.art_wanted) > 0 do url = pop_front(&s.art_wanted)
		sync.unlock(&s.mutex)

		if quit do return
		if url == "" {
			time.sleep(30 * time.Millisecond)
			continue
		}

		fetch_art(s, url)
		delete(url)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
fetch_art :: proc(s: ^Shared, url: string) {
	res, ok := http_request("GET", url, nil)
	if !ok || res.status != 200 {
		delete(res.body)
		return
	}
	defer delete(res.body)

	w, h, ch: i32
	pixels := stbi.load_from_memory(raw_data(res.body), i32(len(res.body)), &w, &h, &ch, 4)
	if pixels == nil do return

	// Covers arrive at 300px but a tile is nowhere near that on screen, and
	// every slot in the bindless table costs VRAM for as long as it lives.
	// Downscaling here keeps the whole table affordable.
	out_w, out_h := int(w), int(h)
	data := pixels[:out_w * out_h * 4]
	if max(out_w, out_h) > ART_TEXTURE_PX {
		scale := f32(ART_TEXTURE_PX) / f32(max(out_w, out_h))
		nw := max(int(f32(out_w) * scale), 1)
		nh := max(int(f32(out_h) * scale), 1)
		small := make([]byte, nw * nh * 4)
		ok := stbi.resize_uint8_srgb(
			pixels,
			w,
			h,
			0,
			raw_data(small),
			i32(nw),
			i32(nh),
			0,
			4,
			3, // alpha channel index
			0,
		)
		stbi.image_free(pixels)
		if ok == 0 {
			delete(small)
			return
		}
		data = small
		out_w, out_h = nw, nh
	}

	sync.guard(&s.mutex)
	append(
		&s.art_ready,
		Art{url = strings.clone(url), pixels = data, width = out_w, height = out_h},
	)
}

// Takes a copy: `text` is usually a temp-allocated format result, and the
// value it replaces is freed here, so everything on Shared stays owned.
@(private = "file")
set_status :: proc(s: ^Shared, text: string, is_error := false) {
	sync.guard(&s.mutex)
	delete(s.status)
	s.status = strings.clone(text)
	s.status_error = is_error
}
