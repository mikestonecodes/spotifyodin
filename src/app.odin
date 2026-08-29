package spoticyclint

import "core:fmt"
import "core:os"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import stbi "vendor:stb/image"

// Alpha here is the window's own transparency: the compositor blends whatever
// is behind it through the background and the panels.
BG :: Color(0xa6121212)
PANEL :: Color(0xb4181818)
PANEL_HI :: Color(0xff242424)
ACCENT :: Color(0xff54b91d) // Spotify green, RGBA8 little endian
TEXT :: Color(0xffffffff)
MUTED :: Color(0xffb3b3b3)
DIM :: Color(0xff535353)
WARN :: Color(0xff4d4dff) // something needs the user's attention

// Ceiling on animation frames. Mailbox present does not block, so without a
// budget the loop would render as fast as the GPU allows for no visible gain.
FRAME_BUDGET :: 8 * time.Millisecond

// One grid. The playing track is a large tile in the top-left corner and
// everything else flows around it. Covers only — the name is written into the
// big tile, so the small ones need no labels.
TILE_MIN :: 150
TILE_GAP :: 12
BAR_H :: 88

Command :: enum {
	None,
	Toggle,
	Next,
	Previous,
	Reshuffle,
}

Art :: struct {
	url:     string,
	pixels:  []byte,
	width:   int,
	height:  int,
	feature: bool, // goes to the dedicated full-size slot
}

Art_Request :: struct {
	url:     string,
	max_px:  int,
	feature: bool,
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

	art_wanted:   [dynamic]Art_Request,
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
	// The control bar stays out of the way until asked for.
	show_bar:     bool,

	last_now_uri: string,
	pulse:        f32, // 1 -> 0 right after a change
	now_index:    int, // where the playing track sits in the queue, or -1

	// The grid holds the queue from the next track onward, so a change slides
	// every tile back by one slot. `shift` runs 1 -> 0 across that slide and
	// `shift_by` is how many slots the queue moved.
	shift:        f32,
	shift_by:     int,

	// The cover growing out of the grid into the feature slot. `grow` runs
	// 1 -> 0 across it.
	grow:         f32,
	grow_from:    Rect,
	grow_slot:    u32,
	grow_has_art: bool,

	// The big cover turns over when the track changes: `flip` runs 1 -> 0 and
	// `flip_dir` decides which way, while `prev_art` is what it turns away
	// from.
	flip:         f32,
	flip_dir:     f32,
	prev_art:     string,
	now_art_url:  string,
	feature_url:   string, // what has been asked for
	feature_shown: string, // what the full-size slot actually holds
	feature_slot:  u32,
	feature_ready: bool,
	last_index:   int,

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
			timeout = 40 // keep the scrub line moving smoothly
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
	bar:          bool,
}

@(private = "file")
frame_state :: proc(app: ^App) -> (fs: Frame_State) {
	s := &app.shared
	sync.lock(&s.mutex)
	fs.now_uri = ui_id(s.now_uri)
	fs.status = ui_id(s.status)
	fs.playing = s.is_playing
	if app.player.ready {
		pos := player_position(&app.player)
		fs.half_second = pos.position_ms / 50
		fs.playing = pos.playing
		fs.duration = pos.duration_ms
	}
	fs.loaded = s.loaded
	fs.half_second = s.progress_ms / 50 // 20 updates a second keeps the bar smooth
	fs.duration = s.duration_ms
	fs.count = len(s.tracks)
	fs.volume = s.volume
	sync.unlock(&s.mutex)

	fs.art_count = len(app.art)
	fs.scroll = app.scroll.target
	fs.bar = app.show_bar
	fs.width = app.win.width
	fs.height = app.win.height
	return
}

@(private = "file")
handle_keys :: proc(app: ^App) {
	if window_key_pressed(&app.win, KEY_ESC) || window_key_pressed(&app.win, KEY_Q) {
		app.win.should_close = true
	}
	// j / k / l for previous, pause, next; ';' shows and hides the controls.
	if window_key_pressed(&app.win, KEY_SPACE) do toggle_playback(app)
	if window_key_pressed(&app.win, KEY_K) do toggle_playback(app)
	if window_key_pressed(&app.win, KEY_RIGHT) do push_command(app, .Next)
	if window_key_pressed(&app.win, KEY_L) do push_command(app, .Next)
	if window_key_pressed(&app.win, KEY_LEFT) do push_command(app, .Previous)
	if window_key_pressed(&app.win, KEY_J) do push_command(app, .Previous)
	if window_key_pressed(&app.win, KEY_SEMICOLON) do app.show_bar = !app.show_bar
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

	// Straight from the audio device: the worker's copy is only as fresh as
	// its tick, which made the bar visibly step.
	if app.player.ready {
		pos := player_position(&app.player)
		if pos.duration_ms > 0 {
			progress, duration = pos.position_ms, pos.duration_ms
			is_playing = pos.playing
		}
	}
	_ = since

	// The bar slides up out of the bottom edge, and the grid takes the space
	// back as it goes.
	shown := ui_anim(ui, ui_id("bar"), app.show_bar ? 1 : 0, 16)

	list := Rect{0, 0, w, h - BAR_H * shown}
	if loaded && count > 0 {
		draw_queue(app, list, now_uri, now_name, now_artist, progress, duration)
	} else {
		ui_text_centred(ui, &ui.regular, status, list, 18, status_error ? WARN : MUTED)
	}

	if shown > 0.001 {
		draw_controls(
			app,
			Rect{0, h - BAR_H * shown, w, BAR_H},
			is_playing,
			progress,
			duration,
			status,
			status_error,
		)
	}
}

@(private = "file")
Grid :: struct {
	cols:    int,
	feature: int, // the playing tile spans this many cells each way
	cell:    f32,
	head:    int, // cells beside the feature, in the rows it occupies
	rows:    int,
}

@(private = "file")
grid_for :: proc(width: f32, count: int) -> (g: Grid) {
	usable := width - TILE_GAP
	g.cols = max(int(usable / (TILE_MIN + TILE_GAP)), 3)
	g.cell = usable / f32(g.cols)
	g.feature = g.cols >= 6 ? 3 : 2
	g.head = g.feature * (g.cols - g.feature)

	remaining := max(count - g.head, 0)
	g.rows = g.feature + (remaining + g.cols - 1) / g.cols
	return
}

// The rectangle a slot occupies on screen.
@(private = "file")
grid_slot_rect :: proc(g: Grid, area: Rect, scroll: f32, slot: int) -> Rect {
	row, col := grid_cell(g, slot)
	return Rect {
		area.x + TILE_GAP + f32(col) * g.cell,
		area.y - scroll + TILE_GAP + f32(row) * g.cell,
		g.cell - TILE_GAP,
		g.cell - TILE_GAP,
	}
}

// Where the n-th track sits, with the feature block filling the top-left.
@(private = "file")
grid_cell :: proc(g: Grid, n: int) -> (row, col: int) {
	side := g.cols - g.feature
	if n < g.head do return n / side, g.feature + n % side
	j := n - g.head
	return g.feature + j / g.cols, j % g.cols
}

// The index range that lands on a given row.
@(private = "file")
grid_row_range :: proc(g: Grid, row: int) -> (first, last: int) {
	side := g.cols - g.feature
	if row < g.feature do return row * side, (row + 1) * side
	j := row - g.feature
	return g.head + j * g.cols, g.head + (j + 1) * g.cols
}

@(private = "file")
draw_queue :: proc(
	app: ^App,
	r: Rect,
	now_uri, now_name, now_artist: string,
	progress, duration: int,
) {
	ui := &app.ui
	s := &app.shared

	sync.lock(&s.mutex)
	count := len(s.tracks)
	sync.unlock(&s.mutex)

	// The layout as it stood before this frame's change: the cover that is
	// about to become the feature was sitting somewhere in it, and that is
	// where its flight starts.
	// The layout as it stood before this change, which is where the incoming
	// cover was sitting.
	previous_start := app.now_index >= 0 ? app.now_index + 1 : 0
	previous_grid := grid_for(r.w, app.now_index >= 0 ? count - 1 : count)
	_ = previous_start
	track_change_pulse(app, now_uri, previous_grid, r, count)

	// The grid is the queue from the next track onward, wrapping round, so the
	// tile beside the feature really is what plays next.
	start := app.now_index >= 0 ? app.now_index + 1 : 0
	flow_count := app.now_index >= 0 ? count - 1 : count

	g := grid_for(r.w, flow_count)
	ui_begin_scroll(ui, r, &app.scroll, f32(g.rows) * g.cell + TILE_GAP)

	first_row := max(int(app.scroll.offset / g.cell) - 1, 0)
	last_row := min(first_row + int(r.h / g.cell) + 3, g.rows)

	// The playing track, large, in the corner.
	feature := Rect {
		r.x + TILE_GAP,
		r.y - app.scroll.offset + TILE_GAP,
		g.cell * f32(g.feature) - TILE_GAP,
		g.cell * f32(g.feature) - TILE_GAP,
	}
	if feature.y + feature.h > r.y && feature.y < r.y + r.h {
		draw_feature(app, feature, now_name, now_artist, progress, duration)
	}

	first, _ := grid_row_range(g, first_row)
	_, last := grid_row_range(g, max(last_row - 1, first_row))
	first = clamp(first, 0, flow_count)
	last = clamp(last, 0, flow_count)

	// Slot k holds the k-th track after the one playing, wrapping round, so
	// the tile beside the feature really is what plays next.
	visible := make([]Track, max(last - first, 0), context.temp_allocator)
	indices := make([]int, len(visible), context.temp_allocator)
	sync.lock(&s.mutex)
	for slot in first ..< last {
		i := (start + slot) %% count
		visible[slot - first] = s.tracks[i]
		indices[slot - first] = i
	}
	sync.unlock(&s.mutex)

	// A step along the queue slides every tile back one slot, so the whole
	// grid moves instead of one tile changing underneath the pointer.
	ease := 1 - app.shift
	ease = 1 - (1 - ease) * (1 - ease) * (1 - ease)

	for track, vi in visible {
		slot := first + vi
		to := grid_slot_rect(g, r, app.scroll.offset, slot)
		cell := to
		fade: f32 = 1

		if app.shift > 0.001 {
			from_slot := slot + app.shift_by
			if from_slot >= 0 && from_slot < flow_count {
				from := grid_slot_rect(g, r, app.scroll.offset, from_slot)
				if abs(from.y - to.y) < g.cell * 0.5 {
					cell.x = from.x + (to.x - from.x) * ease
					cell.y = from.y + (to.y - from.y) * ease
				} else {
					// Coming from another row would fly across the window;
					// those fade in place instead.
					fade = ease
				}
			} else {
				fade = ease
			}
		}

		if cell.y > r.y + r.h || cell.y + cell.h < r.y do continue
		draw_tile(app, cell, track, indices[vi], fade)
	}

	// Drawn last, over the tiles, on its way to the corner.
	if app.grow > 0.001 && app.grow_has_art {
		t := clamp(1 - app.grow, 0, 1)

		// Ease out with a touch of overshoot, so it settles into the corner
		// instead of coasting to a stop.
		back :: 0.9
		u := t - 1
		e := 1 + (back + 1) * u * u * u + back * u * u

		from := app.grow_from
		box := Rect {
			from.x + (feature.x - from.x) * e,
			from.y + (feature.y - from.y) * e,
			from.w + (feature.w - from.w) * e,
			from.h + (feature.h - from.h) * e,
		}
		radius := (from.w * 0.055) + (feature.w * 0.035 - from.w * 0.055) * e

		// Dissolve into the feature over the last of the travel, so there is
		// no visible swap at the end.
		alpha := u8(255 * clamp((1 - t) / 0.25, 0, 1))
		ui_glow(
			ui,
			{box.x + box.w / 2, box.y + box.h / 2},
			box.w * 0.75,
			color_alpha(ACCENT, 0.45 * app.grow),
		)
		ui_image(ui, box, app.grow_slot, radius, rgba(255, 255, 255, alpha))
	}

	ui_end_scroll(ui, r, &app.scroll)
}

@(private = "file")
draw_tile :: proc(app: ^App, cell: Rect, track: Track, i: int, fade_in: f32 = 1) {
	ui := &app.ui
	id := ui_id("tile", i)
	clicked, hovered := ui_invisible_button(ui, id, cell)
	if clicked do request_play_index(app, i)

	lift := ui_anim(ui, id, hovered ? 1 : 0, 16)
	press := ui_anim(ui, id ~ 2, ui.active == id ? 1 : 0, 26)
	scale := 1 + lift * 0.06 - press * 0.05

	grow := cell.w * (scale - 1) / 2
	cover := rect_inset(cell, -grow, -grow)
	radius := cell.w * 0.055

	slot, has_art := app.art[track.art_url]
	if !has_art do want_art(app, track.art_url)

	appear := clamp(fade_in, 0, 1)
	fade := ui_anim(ui, id ~ 3, has_art ? 1 : 0, 8) * appear
	ui_rect(ui, cover, color_alpha(PANEL_HI, appear), radius)
	if has_art && fade > 0.01 {
		ui_image(ui, cover, slot, radius, rgba(255, 255, 255, u8(255 * fade)))
	}
	if lift > 0.01 {
		ui_rect(ui, cover, rgba(255, 255, 255, u8(22 * lift)), radius)
	}
}

// The playing track: the cover, its name written into the artwork, and how far
// through it is along the bottom edge.
@(private = "file")
draw_feature :: proc(app: ^App, r: Rect, name, artist: string, progress, duration: int) {
	ui := &app.ui
	radius := r.w * 0.035

	// The swell peaks partway through the change rather than at the start, so
	// the cover lands into place instead of decaying out of it.
	swell := math.sin(clamp(app.pulse, 0, 1) * math.PI)
	pop := swell * 0.06
	cover := rect_inset(r, -r.w * pop / 2, -r.w * pop / 2)

	// Light thrown off the artwork as it arrives.
	if swell > 0.01 {
		ui_glow(
			ui,
			{cover.x + cover.w / 2, cover.y + cover.h / 2},
			cover.w * (0.62 + swell * 0.3),
			color_alpha(ACCENT, swell * 0.5),
		)
	}

	ui_rect(ui, cover, PANEL_HI, radius)
	// Use the full-size slot only while it actually holds this track. It takes
	// a moment to download, and showing the previous cover until it lands made
	// clicking feel like nothing had happened.
	big_ready := app.feature_ready && app.feature_shown == app.feature_url
	if big_ready {
		ui_image(ui, cover, app.feature_slot, radius)
	} else if small, has := current_art_slot(app); has {
		// The grid already has this cover at tile size; show it at once.
		ui_image(ui, cover, small, radius)
	}
	if swell > 0.01 {
		ui_rect(ui, cover, rgba(255, 255, 255, u8(55 * swell)), radius)
	}

	if name != "" {
		// The scrim only has to carry two lines now that the times are gone.
		scrim := Rect{cover.x, cover.y + cover.h * 0.58, cover.w, cover.h * 0.42}
		ui_gradient_v(ui, scrim, rgba(0, 0, 0, 0), rgba(0, 0, 0, 225))

		pad := f32(16)
		size := clamp(cover.w * 0.075, 16, 30)
		artist_size := size * 0.6
		title := font_ellipsize(&ui.bold, name, size, cover.w - pad * 2)
		who := font_ellipsize(&ui.regular, artist, artist_size, cover.w - pad * 2)

		// Stacked up from the progress line, tight.
		artist_y := cover.y + cover.h - pad - 5 - 10 - artist_size * 1.2
		title_y := artist_y - size * 1.08
		ui_text(ui, &ui.bold, title, {cover.x + pad, title_y}, size, TEXT)
		ui_text(ui, &ui.regular, who, {cover.x + pad, artist_y}, artist_size, rgba(255, 255, 255, 195))
	}

	// Progress belongs on the artwork: the control bar is hidden by default,
	// so this is usually the only place it is shown.
	if duration > 0 {
		pad := f32(16)
		frac := clamp(f32(progress) / f32(duration), 0, 1)

		bar := Rect{cover.x + pad, cover.y + cover.h - pad - 5, cover.w - pad * 2, 5}
		ui_rect(ui, bar, rgba(255, 255, 255, 45), 2.5)
		if frac > 0 {
			fill := Rect{bar.x, bar.y, bar.w * frac, bar.h}
			ui_rect(ui, fill, ACCENT, 2.5)
			ui_glow(ui, {fill.x + fill.w, bar.y + 2.5}, 12, color_alpha(ACCENT, 0.55))
		}

	}
}

@(private = "file")
track_change_pulse :: proc(app: ^App, now_uri: string, layout: Grid, area: Rect, count: int) {
	ui := &app.ui
	if now_uri != app.last_now_uri {
		delete(app.last_now_uri)
		app.last_now_uri = strings.clone(now_uri)
		app.pulse = 1

		// Remember where it sits so the grid can leave it out — it is already
		// on screen as the feature tile.
		previous_index := app.now_index
		app.now_index = -1
		big, small: string
		sync.lock(&app.shared.mutex)
		for t, i in app.shared.tracks {
			if t.uri == now_uri {
				app.now_index = i
				small = strings.clone(t.art_url, context.temp_allocator)
				big = strings.clone(
					big_art_url(t.art_url_big, t.art_url),
					context.temp_allocator,
				)
				break
			}
		}
		sync.unlock(&app.shared.mutex)
		want_feature_art(app, big)

		// Slide the grid only for a step along the queue. Jumping somewhere
		// else entirely has no sensible direction to slide in.
		app.shift = 0
		app.shift_by = 0
		if previous_index >= 0 && app.now_index >= 0 {
			step := app.now_index - previous_index
			if step == 1 || step == -1 {
				app.shift_by = step
				app.shift = 1
			}
		}

		// The new track was a tile in the grid a moment ago. Grow it out of
		// exactly that cell, so the cover you clicked is the one that arrives.
		app.grow = 0
		if previous_index >= 0 && app.now_index >= 0 && count > 0 && layout.cell > 0 {
			slot := app.now_index - previous_index - 1
			if slot < 0 do slot += count
			if slot >= 0 && slot < count {
				app.grow_from = grid_slot_rect(layout, area, app.scroll.offset, slot)
				app.grow_slot, app.grow_has_art = app.art[small]
				if app.grow_has_art do app.grow = 1
			}
		}
	}
	if app.pulse > 0 {
		app.pulse = max(app.pulse - ui.dt * 2.2, 0)
		ui.animating = true
	}
	if app.shift > 0 {
		app.shift = max(app.shift - ui.dt * 4.5, 0)
		ui.animating = true
	}
	if app.grow > 0 {
		app.grow = max(app.grow - ui.dt * 3.4, 0)
		ui.animating = true
	}
}

// Just the controls: the feature tile already shows what is playing.
@(private = "file")
draw_controls :: proc(
	app: ^App,
	r: Rect,
	is_playing: bool,
	progress, duration: int,
	status: string,
	status_error: bool,
) {
	ui := &app.ui
	ui_rect(ui, r, PANEL)

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
		ui_glow(ui, {fill.x + fill.w, line.y + line_h / 2}, 14 + grow * 10, color_alpha(ACCENT, 0.5))
	}
	if grow > 0.01 && duration > 0 {
		ui_circle(ui, {line.x + line.w * frac, line.y + line_h / 2}, 4 + grow * 4, TEXT)
	}
	if seek_clicked && duration > 0 {
		request_seek(app, int(clamp((ui.mouse.x - line.x) / line.w, 0, 1) * f32(duration)))
	}

	cy := r.y + (r.h + line_h) / 2
	cx := r.w / 2
	if transport_button(ui, "prev", Rect{cx - 100, cy - 22, 44, 44}, .Previous_Icon, false) {
		push_command(app, .Previous)
	}
	if transport_button(ui, "play", Rect{cx - 29, cy - 29, 58, 58}, is_playing ? .Pause_Icon : .Play_Icon, true) {
		toggle_playback(app)
	}
	if transport_button(ui, "next", Rect{cx + 56, cy - 22, 44, 44}, .Next_Icon, false) {
		push_command(app, .Next)
	}

	sync.lock(&app.shared.mutex)
	volume := app.shared.volume
	sync.unlock(&app.shared.mutex)

	vol := Rect{r.w - 360, cy - 18, 330, 36}
	new_volume := volume_slider(ui, vol, volume)
	if new_volume != volume {
		player_set_volume(&app.player, new_volume)
		sync.guard(&app.shared.mutex)
		app.shared.volume = new_volume
	}

	if status_error {
		ui_text(ui, &ui.regular, font_ellipsize(&ui.regular, status, 12, 320), {r.x + 20, cy - 7}, 12, WARN)
	}
}

@(private = "file")
volume_slider :: proc(ui: ^UI, r: Rect, value: f32) -> f32 {
	id := ui_id("volume")
	_, hovered := ui_invisible_button(ui, id, r)
	held := ui.active == id
	feel := ui_anim(ui, id ~ 7, hovered || held ? 1 : 0, 18)

	value := clamp(value, 0, 1)
	if held && r.w > 0 do value = clamp((ui.mouse.x - r.x) / r.w, 0, 1)

	h := 9 + feel * 5
	bar := Rect{r.x, r.y + r.h / 2 - h / 2, r.w, h}
	ui_rect(ui, bar, rgba(255, 255, 255, 24), h / 2)

	if value > 0 {
		fill := Rect{bar.x, bar.y, bar.w * value, h}
		if feel > 0.01 do ui_rect_sheen(ui, fill, ACCENT, h / 2)
		else do ui_rect(ui, fill, ACCENT, h / 2)
		ui_glow(ui, {fill.x + fill.w, bar.y + h / 2}, 16 + feel * 12, color_alpha(ACCENT, 0.45))
	}

	knob := 10 + feel * 5
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
	scale := 1 + hover * 0.10 - press * 0.14

	c := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
	radius := r.w / 2 * scale

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
	append(&app.shared.art_wanted, Art_Request{strings.clone(url), ART_TEXTURE_PX, false})
}

// Spotify's image URLs encode the size in a fixed prefix, so the full-size
// cover can be derived from the one we already cached. That avoids refetching
// the whole library just to learn a second URL for each track.
@(private = "file")
ART_PREFIX_300 :: "ab67616d00001e02"
@(private = "file")
ART_PREFIX_640 :: "ab67616d0000b273"

@(private = "file")
big_art_url :: proc(track_big, track_small: string) -> string {
	if track_big != "" do return track_big
	if i := strings.index(track_small, ART_PREFIX_300); i >= 0 {
		return fmt.tprintf(
			"%s%s%s",
			track_small[:i],
			ART_PREFIX_640,
			track_small[i + len(ART_PREFIX_300):],
		)
	}
	return track_small
}

// The playing cover, at full size, into the slot reserved for it.
@(private = "file")
want_feature_art :: proc(app: ^App, url: string) {
	if url == "" || url == app.feature_url do return
	delete(app.feature_url)
	app.feature_url = strings.clone(url)

	sync.guard(&app.shared.mutex)
	append(&app.shared.art_wanted, Art_Request{strings.clone(url), ART_FEATURE_PX, true})
}

// Each upload waits on the queue, so a scroll that queues fifty covers would
// stall the frame. Take a few per frame; the rest wait their turn.
ART_UPLOADS_PER_FRAME :: 4

// Covers are stored at this size. A tile is ~170-200 logical pixels, so this
// is sharp, and it keeps a full bindless table down to a sane amount of VRAM.
ART_TEXTURE_PX :: 224

// The feature cover is drawn several hundred pixels across, so it gets its own
// slot at full size, replaced in place each track rather than adding an entry
// per song.
ART_FEATURE_PX :: 640

@(private = "file")
upload_pending_art :: proc(app: ^App) -> (uploaded: bool) {
	needs_redraw: bool
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
		if a.feature {
			// One slot, reused: allocate it the first time, overwrite after.
			if !app.feature_ready {
				app.feature_slot = texture_upload(&app.gpu, a.pixels, a.width, a.height, 4)
				app.feature_ready = true
			} else {
				texture_replace(&app.gpu, app.feature_slot, a.pixels, a.width, a.height, 4)
			}
			delete(app.feature_shown)
			app.feature_shown = a.url // taking ownership
			needs_redraw = true
		} else {
			app.art[a.url] = texture_upload(&app.gpu, a.pixels, a.width, a.height, 4)
		}
		delete(a.pixels)
	}
	return count > 0 || needs_redraw
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
	tracks, fresh, hit := load_library()

	// A cache saved in the last day is taken as current, so a normal start
	// makes no network call at all.
	if hit && fresh {
		set_status(s, fmt.tprintf("%d songs", len(tracks)))
		return tracks, true
	}
	if hit {
		for t in tracks do free_track(t)
		clear(&tracks)
	}

	set_status(s, "loading liked songs...")

	// Prefer spclient. The Web API's /me/tracks is rate limited per user and
	// hands out multi-hour lockouts, which leaves the app with nothing; the
	// access point's own services have a separate budget.
	if session_token, have := get_access_token(.Session); have {
		defer delete(session_token)
		spc_tracks, spc_ok := fetch_library_spclient(session_token, on_load_progress, s)
		if spc_ok {
			delete(tracks)
			save_library(spc_tracks[:], true)
			return spc_tracks, true
		}
		delete(spc_tracks)
	}

	// Fall back to the Web API if spclient would not answer.
	done := get_liked_tracks(c, &tracks, on_load_progress, s)
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

		// Say how long the limit actually is. Spotify hands out multi-hour
		// ones, and "loading..." for three hours looks like a hang.
		wait := min(30 << uint(min(attempt, 3)), 240)
		if g_rate_limit_wait > 300 {
			set_status(
				s,
				fmt.tprintf("Spotify rate limit - about %dh left", (g_rate_limit_wait + 1800) / 3600),
				true,
			)
			wait = min(g_rate_limit_wait, 900)
		} else {
			set_status(s, fmt.tprintf("Spotify is rate limiting; retrying in %ds", wait), true)
		}
		if worker_sleep(s, wait) do return
	}

	// Drop what we already know cannot be played, so it never reaches the
	// queue or the grid.
	unplayable := load_unplayable()
	defer {
		for uri in unplayable do delete(uri)
		delete(unplayable)
	}

	playable: [dynamic]Track
	defer delete(playable)
	for t in tracks {
		if !unplayable[t.uri] do append(&playable, t)
	}
	if len(unplayable) > 0 {
		fmt.eprintfln("skipping %d tracks known to be unavailable", len(unplayable))
	}

	pool := playable[:]
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

			// Show the selection straight away. A preloaded track is ready in
			// a moment, and an un-preloaded one takes a second or so — either
			// way the grid should answer the click immediately.
			publish_track(s, order[next])
			set_status(s, fmt.tprintf("loading %s...", order[next].name))

			loaded, permanent := player_load(player, order[next].uri)
			if loaded {
				index = next
				sync.lock(&s.mutex)
				s.is_playing = true
				sync.unlock(&s.mutex)
				set_status(s, fmt.tprintf("%d songs", len(order)))
				// Get the following track ready while this one plays.
				if index + 1 < len(order) do player_preload(player, order[index + 1].uri)
			} else {
				// Remember the ones that will never work, so they are not
				// offered again on this or any later run.
				if permanent {
					unplayable[strings.clone(order[next].uri)] = true
					save_unplayable(unplayable)
					set_status(s, fmt.tprintf("%s is not available here", order[next].name), true)
					fmt.eprintfln("not available here: %s - %s", order[next].artist, order[next].name)
				} else {
					set_status(s, fmt.tprintf("could not play %s", order[next].name), true)
					fmt.eprintfln("could not play %s - %s", order[next].artist, order[next].name)
				}

				// Skip past it, but slowly: a non-permanent failure is usually
				// Spotify throttling key requests, and racing ahead just asks
				// for more of them.
				index = next
				load_index = next + 1
				if worker_sleep(s, permanent ? 0 : 2) do return
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
		req: Art_Request
		if len(s.art_wanted) > 0 do req = pop_front(&s.art_wanted)
		sync.unlock(&s.mutex)

		if quit do return
		if req.url == "" {
			time.sleep(30 * time.Millisecond)
			continue
		}

		fetch_art(s, req)
		delete(req.url)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
fetch_art :: proc(s: ^Shared, req: Art_Request) {
	url := req.url
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
	// Whatever leaves here must be Odin-allocated: the caller frees it with
	// delete, and stb_image's buffer came from malloc. The feature cover is
	// requested at exactly its source size, so the resize path below does not
	// always run.
	out_w, out_h := int(w), int(h)
	data: []byte
	if max(out_w, out_h) <= req.max_px {
		data = make([]byte, out_w * out_h * 4)
		copy(data, pixels[:out_w * out_h * 4])
		stbi.image_free(pixels)
	}
	if data == nil {
		scale := f32(req.max_px) / f32(max(out_w, out_h))
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
		Art {
			url = strings.clone(url),
			pixels = data,
			width = out_w,
			height = out_h,
			feature = req.feature,
		},
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
