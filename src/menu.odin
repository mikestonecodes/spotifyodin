package spoticyclint

// The / menu, after aithing's launcher: one card over a darkened grid, what
// you typed in the biggest type in the window, and the rows under it. Arrows
// choose, Enter plays, Escape goes back to the grid.
//
// Nothing about the rows is kept between frames. They are worked out from the
// query and the two lists every time the menu is drawn, so there is no filtered
// copy to fall out of step with what is typed.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

MENU_ROW_H :: 52
MENU_PAGE :: 8

// How long typing has to pause before it is sent as a search. Every letter
// would be a request, and most of them would be answered after the next one.
SEARCH_PAUSE :: 250 * time.Millisecond

// A failure stays in the chip this long, then the chip goes.
CHIP_FAILED_FOR :: 4 * time.Second

menu_show :: proc(app: ^App, open: bool) {
	app.menu_open = open
	app.menu_at, app.menu_top = 0, 0
	clear(&app.query)
	// The playlists may not have come the first time; opening the menu is a
	// good moment to ask again.
	if open do sync.sema_post(&app.shared.browse_wake)
}

menu_keys :: proc(app: ^App) {
	input := &app.win.input
	keys := make([dynamic]u32, 0, 8, context.temp_allocator)
	append(&keys, ..input.keys_pressed[:])
	append(&keys, ..input.keys_repeated[:])

	for k in keys {
		switch k {
		case KEY_ESC:
			menu_show(app, false)
			return
		case KEY_ENTER, KEY_KPENTER:
			view := menu_rows(app)
			if len(view.rows) > 0 do menu_take(app, view.rows[clamp(app.menu_at, 0, len(view.rows) - 1)])
			return
		case KEY_UP:
			app.menu_at -= 1
		case KEY_DOWN:
			app.menu_at += 1
		case KEY_TAB:
			app.menu_at += input.shift ? -1 : 1
		case KEY_PAGEUP:
			app.menu_at -= MENU_PAGE
		case KEY_PAGEDOWN:
			app.menu_at += MENU_PAGE
		case KEY_BACKSPACE:
			if input.ctrl {
				// A word at a time, and the spaces before it.
				for len(app.query) > 0 && app.query[len(app.query) - 1] == ' ' do pop(&app.query)
				for len(app.query) > 0 && app.query[len(app.query) - 1] != ' ' do pop(&app.query)
			} else if len(app.query) > 0 {
				pop(&app.query)
			}
			query_edited(app)
		case:
			if input.ctrl {
				if k == KEY_U {
					clear(&app.query)
					query_edited(app)
				}
				continue
			}
			if ch := window_key_char(k, input.shift); ch != 0 {
				append(&app.query, ch)
				query_edited(app)
			}
		}
	}
	app.menu_at = max(app.menu_at, 0)
}

@(private = "file")
query_edited :: proc(app: ^App) {
	app.query_at = time.now()
	app.menu_at, app.menu_top = 0, 0
}

// Hands the pick to the open thread and goes back to the grid, which is where
// it will turn up.
@(private = "file")
menu_take :: proc(app: ^App, row: Source) {
	s := &app.shared
	sync.lock(&s.mutex)
	if s.open_pending do source_free(s.open_want)
	s.open_want = source_clone(row)
	s.open_pending = true
	// Only a list has to be read before it can play; the liked songs are
	// already here and a song from the search is already described.
	if row.kind != .Liked && row.kind != .Track {
		delete(s.opening)
		s.opening = strings.clone(row.name)
		s.opening_failed = false
		s.opening_done, s.opening_total = 0, 0
		s.opening_at = time.now()
	}
	sync.unlock(&s.mutex)
	sync.sema_post(&s.open_wake)
	menu_show(app, false)
}

Menu_View :: struct {
	rows:      []Source,
	searching: bool, // what is typed has not been answered yet
	failed:    bool, // it was, and the answer was an error
	playing:   string, // the uri the queue is from
}

// The rows for what is typed. With nothing typed, the liked songs and then
// every playlist; with something typed, the ones whose names match and then
// what Spotify found. Everything is copied to the frame's scratch, so the
// lists can be replaced while the rows are on screen.
menu_rows :: proc(app: ^App) -> (view: Menu_View) {
	s := &app.shared
	q := strings.trim_space(string(app.query[:]))
	rows := make([dynamic]Source, 0, 80, context.temp_allocator)

	sync.guard(&s.mutex)
	view.playing = strings.clone(s.source_uri, context.temp_allocator)

	if q == "" || contains_fold(LIKED_NAME, q) {
		append(&rows, Source{kind = .Liked, uri = LIKED_URI, name = LIKED_NAME, sub = fmt.tprintf("%d songs", s.liked_count)})
	}
	for p in s.playlists {
		if q == "" || contains_fold(p.name, q) do append(&rows, source_clone(p, context.temp_allocator))
	}
	if q != "" {
		// Results for a query that is still part of what is typed are kept up
		// until the new ones come, so the rows do not blink out every letter.
		lq, lf := lower(q), lower(s.found_for)
		if strings.has_prefix(lq, lf) || strings.has_prefix(lf, lq) {
			outer: for f in s.found {
				for r in rows do if r.uri == f.uri do continue outer
				append(&rows, source_clone(f, context.temp_allocator))
			}
		}
		view.searching = s.found_for != q
		view.failed = !view.searching && s.found_failed
	}
	view.rows = rows[:]
	return
}

@(private = "file")
lower :: proc(s: string) -> string {
	return strings.to_lower(s, context.temp_allocator)
}

@(private = "file")
contains_fold :: proc(s, sub: string) -> bool {
	return strings.contains(lower(s), lower(sub))
}

// Asks for a search once typing has paused on something not yet asked for.
@(private = "file")
menu_search :: proc(app: ^App, q: string) {
	if q == "" do return
	s := &app.shared
	sync.lock(&s.mutex)
	asked := s.search_want == q
	sync.unlock(&s.mutex)
	if asked do return

	if time.since(app.query_at) < SEARCH_PAUSE {
		app.ui.animating = true // come back when the pause is up
		return
	}
	sync.lock(&s.mutex)
	delete(s.search_want)
	s.search_want = strings.clone(q)
	sync.unlock(&s.mutex)
	sync.sema_post(&s.browse_wake)
}

draw_menu :: proc(app: ^App, full: Rect) {
	ui := &app.ui
	t := ui_anim(ui, ui_id("menu"), app.menu_open ? 1 : 0, 16)
	if t < 0.01 do return

	query := string(app.query[:])
	if app.menu_open do menu_search(app, strings.trim_space(query))
	view := menu_rows(app)
	rows := view.rows

	ui_rect(ui, full, rgba(0, 0, 0, u8(170 * t)))

	w := min(full.w - 80, 760)
	x := full.x + (full.w - w) / 2
	y := full.y + full.h * 0.1 + (1 - t) * 18
	size := f32(36)
	head := size * 1.5 + 20
	foot := f32(46)
	fit := max(int((full.h * 0.86 - head - foot - 56) / MENU_ROW_H), 1)
	shown := min(len(rows), fit)

	card := Rect{x - 28, y - 28, w + 56, head + f32(max(shown, 1)) * MENU_ROW_H + foot + 44}
	ui_rect(ui, {card.x + 3, card.y + 10, card.w, card.h}, rgba(0, 0, 0, u8(110 * t)), 20)
	ui_rect(ui, rect_inset(card, -1, -1), rgba(255, 255, 255, u8(14 * t)), 19)
	ui_rect(ui, card, rgba(17, 20, 22, u8(255 * t)), 18)

	// A click outside the card is a click on the grid, and it shuts the menu
	// rather than reaching the grid.
	if app.menu_open && ui.pressed && !rect_contains(card, ui.mouse) do menu_show(app, false)

	// The query, with the caret after it. The tail is what shows when it is
	// longer than the card: the end is where the typing is.
	caret_x := x
	if query == "" {
		ui_text(ui, &ui.bold, "Search everything", {x + 8, y}, size, color_alpha(DIM, t))
	} else {
		tail := query
		for len(tail) > 1 && font_width(&ui.bold, tail, size) > w - 12 do tail = tail[1:]
		caret_x = x + ui_text(ui, &ui.bold, tail, {x, y}, size, color_alpha(TEXT, t)) + 3
	}
	ui_rect(ui, {caret_x, y + size * 0.2, 2.5, size * 1.1}, color_alpha(ACCENT, t), 1)
	y += size * 1.5
	ui_rect(ui, {x, y, w, 1}, rgba(255, 255, 255, u8(22 * t)))
	y += 20

	list_y := y
	take := -1
	if len(rows) == 0 {
		msg := "nothing by that name"
		if view.searching do msg = "searching..."
		else if view.failed do msg = "Spotify's search did not answer"
		ui_text(ui, &ui.regular, msg, {x, y + 14}, 18, color_alpha(MUTED, t))
		y += MENU_ROW_H
	} else {
		// The wheel moves the window of rows and takes the choice along; the
		// keys move the choice and the window follows it.
		if app.menu_open && ui.scroll != 0 && rect_contains(card, ui.mouse) {
			notches := int(ui.scroll / 10)
			if notches == 0 do notches = ui.scroll > 0 ? 1 : -1
			app.menu_top = clamp(app.menu_top - notches, 0, max(len(rows) - shown, 0))
			app.menu_at = clamp(app.menu_at, app.menu_top, app.menu_top + shown - 1)
		}
		app.menu_at = clamp(app.menu_at, 0, len(rows) - 1)
		if app.menu_at < app.menu_top do app.menu_top = app.menu_at
		if app.menu_at >= app.menu_top + shown do app.menu_top = app.menu_at - shown + 1
		app.menu_top = clamp(app.menu_top, 0, max(len(rows) - shown, 0))

		moved := app.win.input.mouse != app.win.last_mouse
		for i in app.menu_top ..< app.menu_top + shown {
			row := rows[i]
			r := Rect{x - 14, y, w + 28, MENU_ROW_H}
			id := ui_id("menu-row", i)
			clicked, hovered: bool
			if app.menu_open do clicked, hovered = ui_invisible_button(ui, id, r)
			if hovered && moved do app.menu_at = i
			on := i == app.menu_at

			lit := ui_anim(ui, id, on ? 1 : 0, 24)
			if lit > 0.01 {
				ui_rect(ui, r, color_alpha(PANEL_HI, t * lit), 10)
				ui_rect(ui, {r.x, r.y + 12, 3, r.h - 24}, color_alpha(ACCENT, t * lit), 1.5)
			}

			thumb := Rect{x, y + 7, 38, 38}
			draw_row_art(app, thumb, row, t)

			playing := row.uri == view.playing
			sub := playing ? "playing" : row.sub
			sub_size := f32(14)
			sub_w := font_width(&ui.regular, sub, sub_size)
			name_x := thumb.x + thumb.w + 14
			name := font_ellipsize(&ui.bold, drawable(row.name), 19, x + w - name_x - sub_w - 24)
			ui_text(ui, &ui.bold, name, {name_x, y + 12}, 19, color_alpha(on ? TEXT : MUTED, t))
			sub_col := playing ? ACCENT : color_mix(DIM, MUTED, 0.45)
			ui_text(ui, &ui.regular, sub, {x + w - sub_w, y + 17}, sub_size, color_alpha(sub_col, t))

			if clicked do take = i
			y += MENU_ROW_H
		}

		// Where the window is in a list longer than it.
		if len(rows) > shown {
			span := f32(shown) * MENU_ROW_H
			bar_h := max(span * f32(shown) / f32(len(rows)), 24)
			bar_y := list_y + (span - bar_h) * f32(app.menu_top) / f32(len(rows) - shown)
			ui_rect(ui, {card.x + card.w - 9, bar_y, 3, bar_h}, rgba(255, 255, 255, u8(40 * t)), 1.5)
		}
	}

	hint := "enter plays   esc goes back   a song plays next, anything else becomes the queue"
	if view.searching && len(rows) > 0 do hint = "searching Spotify..."
	ui_text(ui, &ui.regular, hint, {x, y + 18}, 13, color_alpha(DIM, 0.9 * t))

	if take >= 0 do menu_take(app, rows[take])
}

// A row's cover: the playlist's picture, the album's, the artist's face in a
// circle. The liked songs have no picture, so they get the heart.
@(private = "file")
draw_row_art :: proc(app: ^App, r: Rect, row: Source, t: f32) {
	ui := &app.ui
	radius := row.kind == .Artist ? r.w / 2 : 6

	if row.kind == .Liked {
		ui_rect(ui, r, color_alpha(ACCENT, t), radius)
		c := [2]f32{r.x + r.w / 2, r.y + r.h / 2}
		heart := color_alpha(TEXT, t)
		ui_circle(ui, {c.x - 4, c.y - 2.5}, 4.6, heart)
		ui_circle(ui, {c.x + 4, c.y - 2.5}, 4.6, heart)
		ui_tri(ui, {c.x - 8.4, c.y - 1}, {c.x + 8.4, c.y - 1}, {c.x, c.y + 8.5}, heart)
		return
	}

	ui_rect(ui, r, color_alpha(PANEL_HI, t), radius)
	if row.art == "" {
		name := drawable(row.name)
		initial := name[:1] if len(name) > 0 else "?"
		ui_text_centred(ui, &ui.bold, initial, r, 17, color_alpha(DIM, t))
		return
	}
	slot, have := app.art[row.art]
	if !have {
		want_art(app, row.art)
		return
	}
	ui_image(ui, r, slot, radius, rgba(255, 255, 255, u8(255 * t)))
}

// A name as the font can draw it. The atlas is ASCII, so anything else comes
// out as a question mark; for a letter that still reads (H?rger), but a name
// dressed in emoji or stacked accents turns into a row of them. Those go,
// and a letter stays.
@(private = "file")
drawable :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	space := false
	for ch in name {
		if ch >= 0x2000 || (ch >= 0x300 && ch < 0x370) || ch == 0xfe0f do continue
		if ch == ' ' {
			space = strings.builder_len(b) > 0
			continue
		}
		if space do strings.write_byte(&b, ' ')
		space = false
		strings.write_rune(&b, ch)
	}
	out := strings.to_string(b)
	return out != "" ? out : name
}

// Whether the chip over the grid has anything to say. Read with the lock held.
chip_shown :: proc(s: ^Shared) -> bool {
	if s.opening == "" do return false
	return !s.opening_failed || time.since(s.opening_at) < CHIP_FAILED_FOR
}

// What is being opened, and how far along, at the foot of the grid: a big
// playlist is a request per song it has never seen, and that takes a while.
draw_chip :: proc(app: ^App, area: Rect) {
	ui := &app.ui
	s := &app.shared

	sync.lock(&s.mutex)
	shown := chip_shown(s)
	text: string
	if s.opening_failed {
		text = strings.clone(s.opening, context.temp_allocator)
	} else if s.opening_total > 0 {
		text = fmt.tprintf("opening %s   %d / %d", s.opening, s.opening_done, s.opening_total)
	} else {
		text = fmt.tprintf("opening %s", s.opening)
	}
	failed := s.opening_failed
	sync.unlock(&s.mutex)

	t := ui_anim(ui, ui_id("chip"), shown ? 1 : 0, 14)
	if t < 0.01 do return
	if !shown do return // the text is gone with it; the fade is only on the way in

	size := f32(15)
	text = font_ellipsize(&ui.regular, text, size, area.w - 120)
	tw := font_width(&ui.regular, text, size)
	pill := Rect{area.x + (area.w - tw - 52) / 2, area.y + area.h - 60 + (1 - t) * 12, tw + 52, 38}
	ui_rect(ui, pill, rgba(28, 32, 35, u8(235 * t)), 19)
	ui_circle(ui, {pill.x + 20, pill.y + 19}, 4, color_alpha(failed ? WARN : ACCENT, t))
	ui_text(ui, &ui.regular, text, {pill.x + 34, pill.y + 9}, size, color_alpha(failed ? WARN : MUTED, t))
}
