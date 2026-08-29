package spoticyclint

import "core:fmt"
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

ROW_H :: 96
BAR_H :: 104
ART :: 72

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
}

run_ui :: proc(client: Client, device: string) {
	app := new(App)
	defer free(app)
	app.client = client
	app.shared.play_index = -1
	app.shared.seek_ms = -1
	app.shared.volume = 1
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

	last_frame := time.now()
	last_state: Frame_State
	needs_draw := true

	for !app.win.should_close {
		// Nothing to draw means nothing to burn: wait on the compositor
		// instead of spinning. Mid-animation we return immediately, while
		// playing we wake often enough to move the progress bar, and when the
		// window is just sitting there we barely wake at all.
		timeout: i32 = 500
		if needs_draw do timeout = 0
		else if last_state.playing do timeout = 200
		window_poll(&app.win, timeout)

		now := time.now()
		dt := f32(time.duration_seconds(time.diff(last_frame, now)))
		last_frame = now

		if app.win.resized {
			app.gpu.ui_scale = f32(app.win.scale)
			gpu_resize(&app.gpu, window_pixel_size(&app.win))
			needs_draw = true
		}
		if upload_pending_art(app) do needs_draw = true
		if window_has_input(&app.win) do needs_draw = true
		handle_keys(app)

		state := frame_state(app)
		if state != last_state {
			last_state = state
			needs_draw = true
		}
		if !needs_draw do continue

		ui_begin(&app.ui, app.win.width, app.win.height, &app.win.input, dt)
		draw_app(app)
		ui_end(&app.ui)

		if !gpu_draw(&app.gpu, &app.ui, BG) {
			gpu_resize(&app.gpu, window_pixel_size(&app.win))
		}

		// Keep drawing only while something is still moving.
		needs_draw = app.ui.animating

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
	if window_key_pressed(&app.win, KEY_SPACE) do push_command(app, .Toggle)
	if window_key_pressed(&app.win, KEY_RIGHT) do push_command(app, .Next)
	if window_key_pressed(&app.win, KEY_LEFT) do push_command(app, .Previous)
	if window_key_pressed(&app.win, KEY_R) do push_command(app, .Reshuffle)

	step: f32 = 0
	if window_key_pressed(&app.win, KEY_UP) do step = 0.05
	if window_key_pressed(&app.win, KEY_DOWN) do step = -0.05
	if step != 0 {
		sync.guard(&app.shared.mutex)
		app.shared.volume = clamp(app.shared.volume + step, 0, 1)
		app.shared.volume_set = app.shared.volume
	}
}

@(private = "file")
push_command :: proc(app: ^App, cmd: Command) {
	sync.guard(&app.shared.mutex)
	append(&app.shared.commands, cmd)
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
		draw_queue(app, list, now_uri)
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
draw_queue :: proc(app: ^App, r: Rect, now_uri: string) {
	ui := &app.ui
	s := &app.shared

	sync.lock(&s.mutex)
	count := len(s.tracks)
	sync.unlock(&s.mutex)

	ui_begin_scroll(ui, r, &app.scroll, f32(count) * ROW_H)

	first := max(int(app.scroll.offset / ROW_H) - 1, 0)
	last := min(first + int(r.h / ROW_H) + 3, count)

	// One lock for every visible row, rather than one per row per frame.
	visible := make([]Track, max(last - first, 0), context.temp_allocator)
	sync.lock(&s.mutex)
	for i in first ..< last do visible[i - first] = s.tracks[i]
	sync.unlock(&s.mutex)

	for track, vi in visible {
		i := first + vi
		row := Rect{r.x, r.y - app.scroll.offset + f32(i) * ROW_H, r.w, ROW_H}
		if row.y > r.y + r.h || row.y + row.h < r.y do continue

		is_now := track.uri == now_uri
		id := ui_id("row", i)
		clicked, hovered := ui_invisible_button(ui, id, row)
		if clicked do request_play_index(app, i)

		// Hover and selection both ease in, and hovering nudges the row over.
		lift := ui_anim(ui, id, hovered ? 1 : 0, 16)
		glow := ui_anim(ui, id ~ 1, is_now ? 1 : 0, 10)

		card := rect_inset(row, 12, 6)
		card.x += lift * 6
		if glow > 0.01 {
			ui_rect(ui, card, color_alpha(PANEL_HI, glow), 14)
			ui_rect(ui, {card.x, card.y + 14, 4, card.h - 28}, color_alpha(ACCENT, glow), 2)
		}
		if lift > 0.01 && glow < 0.99 {
			ui_rect(ui, card, rgba(255, 255, 255, u8(14 * lift)), 14)
		}

        num := fmt.tprintf("%d", i + 1)
		nw := font_width(&ui.regular, num, 15)
		ui_text(ui, &ui.regular, num, {card.x + 52 - nw, row.y + ROW_H / 2 - 10}, 15, is_now ? ACCENT : DIM)

		art := Rect{card.x + 68, row.y + (ROW_H - ART) / 2, ART, ART}
		if slot, has := app.art[track.art_url]; has {
			ui_image(ui, art, slot, 8)
		} else {
			ui_rect(ui, art, PANEL_HI, 8)
			want_art(app, track.art_url)
		}

		text_x := art.x + ART + 20
		text_w := row.w - text_x - 40
		title := font_ellipsize(&ui.bold, track.name, 20, text_w)
		artist := font_ellipsize(&ui.regular, track.artist, 15, text_w)
		ui_text(ui, &ui.bold, title, {text_x, row.y + ROW_H / 2 - 26}, 20, is_now ? ACCENT : TEXT)
		ui_text(ui, &ui.regular, artist, {text_x, row.y + ROW_H / 2 + 2}, 15, MUTED)
	}

	ui_end_scroll(ui, r, &app.scroll, DIM)
}

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
	ui_rect(ui, {r.x, r.y, r.w, 1}, rgba(255, 255, 255, 18))

	art := Rect{r.x + 18, r.y + 16, 72, 72}
	if slot, has := current_art_slot(app); has {
		ui_image(ui, art, slot, 8)
	} else {
		ui_rect(ui, art, PANEL_HI, 8)
	}

	label := name == "" ? "nothing playing" : name
	ui_text(ui, &ui.bold, font_ellipsize(&ui.bold, label, 17, 260), {art.x + 88, r.y + 22}, 17, TEXT)
	ui_text(ui, &ui.regular, font_ellipsize(&ui.regular, artist, 14, 260), {art.x + 88, r.y + 46}, 14, MUTED)
	if status != "" {
		ui_text(ui, &ui.regular, font_ellipsize(&ui.regular, status, 12, 260), {art.x + 88, r.y + 68}, 12, status_error ? WARN : DIM)
	}

	// Transport, drawn as shapes.
	cx := r.w / 2
	cy := r.y + 40
	if transport_button(ui, "prev", Rect{cx - 92, cy - 20, 40, 40}, .Previous_Icon) {
		push_command(app, .Previous)
	}
	if transport_button(ui, "play", Rect{cx - 26, cy - 26, 52, 52}, is_playing ? .Pause_Icon : .Play_Icon) {
		push_command(app, .Toggle)
	}
	if transport_button(ui, "next", Rect{cx + 52, cy - 20, 40, 40}, .Next_Icon) {
		push_command(app, .Next)
	}

	// Progress, click to seek.
	track := Rect{cx - 240, r.y + 78, 480, 5}
	ui_rect(ui, track, DIM, 2.5)
	frac := duration > 0 ? f32(progress) / f32(duration) : 0
	ui_rect(ui, {track.x, track.y, track.w * frac, track.h}, ACCENT, 2.5)

	hit := Rect{track.x, track.y - 10, track.w, 24}
	seek_clicked, seek_hovered := ui_invisible_button(ui, ui_id("seek"), hit)
	knob := ui_anim(ui, ui_id("seekknob"), seek_hovered ? 1 : 0, 16)
	if knob > 0.01 && duration > 0 {
		ui_circle(ui, {track.x + track.w * frac, track.y + 2.5}, 4 + knob * 3, TEXT)
	}
	if seek_clicked && duration > 0 {
		t := clamp((ui.mouse.x - track.x) / track.w, 0, 1)
		request_seek(app, int(t * f32(duration)))
	}

	ui_text(ui, &ui.regular, ms_to_time(progress), {track.x - 52, r.y + 71}, 12, MUTED)
	ui_text(ui, &ui.regular, ms_to_time(duration), {track.x + track.w + 12, r.y + 71}, 12, MUTED)

	// Volume.
	sync.lock(&app.shared.mutex)
	volume := app.shared.volume
	sync.unlock(&app.shared.mutex)

	vol_rect := Rect{r.w - 250, r.y + 34, 110, 22}
	draw_speaker(ui, {vol_rect.x - 26, vol_rect.y + 11}, volume, MUTED)
	new_volume := ui_slider(ui, "volume", vol_rect, volume, DIM, ACCENT, TEXT)
	if new_volume != volume {
		sync.lock(&app.shared.mutex)
		app.shared.volume = new_volume
		app.shared.volume_set = new_volume
		sync.unlock(&app.shared.mutex)
	}

	if shuffle_button(ui, Rect{r.w - 118, r.y + 30, 100, 34}) do push_command(app, .Reshuffle)
}

Icon :: enum {
	Play_Icon,
	Pause_Icon,
	Next_Icon,
	Previous_Icon,
}

// A round button that grows on hover and dips when pressed.
@(private = "file")
transport_button :: proc(ui: ^UI, label: string, r: Rect, icon: Icon) -> bool {
	id := ui_id(label)
	clicked, hovered := ui_invisible_button(ui, id, r)

	press := ui_anim(ui, id ~ 2, ui.active == id ? 1 : 0, 26)
	hover := ui_anim(ui, id, hovered ? 1 : 0, 18)
	scale := 1 + hover * 0.08 - press * 0.12

	c := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
	radius := r.w / 2 * scale
	primary := icon == .Play_Icon || icon == .Pause_Icon

	if primary {
		ui_circle(ui, c, radius, color_mix(TEXT, ACCENT, hover))
	} else if hover > 0.01 {
		ui_circle(ui, c, radius, rgba(255, 255, 255, u8(22 * hover)))
	}

	fg := primary ? BG : color_mix(MUTED, TEXT, hover)
	size := r.w * 0.3 * scale
	draw_icon(ui, c, size, icon, fg)
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

// Two crossing arrows, drawn rather than spelled.
@(private = "file")
shuffle_button :: proc(ui: ^UI, r: Rect) -> bool {
	id := ui_id("shuffle")
	clicked, hovered := ui_invisible_button(ui, id, r)
	hover := ui_anim(ui, id, hovered ? 1 : 0, 18)
	press := ui_anim(ui, id ~ 2, ui.active == id ? 1 : 0, 26)

	ui_rect(ui, r, rgba(255, 255, 255, u8(12 + 26 * hover - 6 * press)), r.h / 2)

	col := color_mix(MUTED, TEXT, hover)
	c := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
	w := f32(11)
	th := f32(2)

	// Two strands that cross in the middle, with arrowheads on the right.
	ui_rect(ui, {c.x - w, c.y - 5, w * 0.8, th}, col, 1)
	ui_rect(ui, {c.x - w, c.y + 3, w * 0.8, th}, col, 1)
	ui_rect(ui, {c.x - w * 0.45, c.y - 5, th, 10}, col, 1)
	ui_rect(ui, {c.x - w * 0.45, c.y - 5, w * 0.9, th}, col, 1)
	ui_rect(ui, {c.x - w * 0.45, c.y + 3, w * 0.9, th}, col, 1)
	ui_tri(ui, {c.x + w * 0.5, c.y - 9}, {c.x + w * 0.5, c.y - 1}, {c.x + w, c.y - 5}, col)
	ui_tri(ui, {c.x + w * 0.5, c.y - 1}, {c.x + w * 0.5, c.y + 7}, {c.x + w, c.y + 3}, col)
	return clicked
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
	append(&app.shared.art_wanted, url)
}

// Each upload waits on the queue, so a scroll that queues fifty covers would
// stall the frame. Take a few per frame; the rest wait their turn.
ART_UPLOADS_PER_FRAME :: 4

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
		stbi.image_free(raw_data(a.pixels))
	}
	return count > 0
}

// ------------------------------------------------------------------- worker

@(private = "file")
request_play_index :: proc(app: ^App, index: int) {
	sync.guard(&app.shared.mutex)
	app.shared.play_index = index
}

@(private = "file")
request_seek :: proc(app: ^App, ms: int) {
	sync.guard(&app.shared.mutex)
	app.shared.seek_ms = ms
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

	player: Player
	for attempt := 0; !player_init(&player, c); attempt += 1 {
		wait := min(5 << uint(min(attempt, 4)), 60)
		set_status(s, fmt.tprintf("player unavailable; retrying in %ds", wait), true)
		if worker_sleep(s, wait) do return
	}
	defer player_destroy(&player)

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
		wanted := make([]string, len(s.art_wanted), context.temp_allocator)
		copy(wanted, s.art_wanted[:])
		clear(&s.art_wanted)
		sync.unlock(&s.mutex)

		if quit do return

		for cmd in cmds {
			switch cmd {
			case .None:
			case .Toggle:
				if index < 0 do load_index = 0
				else do player_toggle(&player)
			case .Next:
				load_index = index + 1
			case .Previous:
				// Restart the track first, like every other player.
				pos := player_position(&player)
				if pos.position_ms > 3000 do player_seek(&player, 0)
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

		if seek_ms >= 0 do player_seek(&player, seek_ms)

		sync.lock(&s.mutex)
		volume_set := s.volume_set
		s.volume_set = -1
		sync.unlock(&s.mutex)
		if volume_set >= 0 do player_set_volume(&player, volume_set)
		if play_index >= 0 do load_index = play_index

		// A track that ran out advances the queue.
		if player_track_ended(&player) && load_index < 0 do load_index = index + 1

		if load_index >= 0 {
			next := load_index
			load_index = -1
			if next >= len(order) do next = 0
			if next < 0 do next = len(order) - 1

			set_status(s, fmt.tprintf("loading %s...", order[next].name))
			if player_load(&player, order[next].uri) {
				index = next
				publish_track(s, order[index])
				set_status(s, fmt.tprintf("%d songs", len(order)))
				// Get the following track ready while this one plays.
				if index + 1 < len(order) do player_preload(&player, order[index + 1].uri)
			} else {
				set_status(s, fmt.tprintf("could not play %s", order[next].name), true)
				// Skip past a track we cannot play rather than wedging.
				index = next
				load_index = next + 1
				if worker_sleep(s, 1) do return
			}
		}

		for url in wanted do fetch_art(s, url)

		pos := player_position(&player)
		sync.lock(&s.mutex)
		s.progress_ms = pos.position_ms
		s.duration_ms = pos.duration_ms
		s.is_playing = pos.playing
		s.last_poll = time.now()
		sync.unlock(&s.mutex)

		free_all(context.temp_allocator)
		time.sleep(100 * time.Millisecond)
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

@(private = "file")
fetch_art :: proc(s: ^Shared, url: string) {
	res, ok := http_request("GET", url, nil)
	if !ok || res.status != 200 {
		delete(res.body)
		return
	}
	defer delete(res.body)

	w, h, ch: i32
	pixels := stbi.load_from_memory(
		raw_data(res.body),
		i32(len(res.body)),
		&w,
		&h,
		&ch,
		4,
	)
	if pixels == nil do return

	sync.guard(&s.mutex)
	append(
		&s.art_ready,
		Art {
			url = strings.clone(url),
			pixels = pixels[:int(w) * int(h) * 4],
			width = int(w),
			height = int(h),
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
