package spoticyclint

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import wl "./wayland"

BTN_LEFT :: 0x110
BTN_RIGHT :: 0x111
BTN_MIDDLE :: 0x112

// evdev keycodes (the compositor sends these raw; no xkb translation here).
KEY_SPACE :: 57
KEY_ESC :: 1
KEY_Q :: 16
KEY_R :: 19
KEY_N :: 49
KEY_LEFT :: 105
KEY_RIGHT :: 106
KEY_UP :: 103
KEY_DOWN :: 108
KEY_PAGEUP :: 104
KEY_PAGEDOWN :: 109

Input :: struct {
	mouse:          [2]f32,
	has_mouse:      bool,
	down:           [3]bool,
	pressed:        [3]bool,
	released:       [3]bool,
	scroll:         f32,
	keys_pressed:   [dynamic]u32,
}

Window :: struct {
	display:      ^wl.wl_display,
	registry:     ^wl.wl_registry,
	compositor:   ^wl.wl_compositor,
	wm_base:      ^wl.xdg_wm_base,
	seat:         ^wl.wl_seat,
	deco_manager: ^wl.zxdg_decoration_manager_v1,

	surface:      ^wl.wl_surface,
	xdg_surface:  ^wl.xdg_surface,
	toplevel:     ^wl.xdg_toplevel,
	decoration:   ^wl.zxdg_toplevel_decoration_v1,
	pointer:      ^wl.wl_pointer,
	keyboard:     ^wl.wl_keyboard,

	// Sizes are logical (what xdg-shell configures); multiply by scale for the
	// pixel size the swapchain and the UI actually work in.
	width:        int,
	height:       int,
	new_width:    int,
	new_height:   int,
	scale:        int,
	configured:   bool,
	resized:      bool,
	should_close: bool,
	input:        Input,
	last_mouse:   [2]f32,
}

@(private = "file")
g_win_ctx: runtime.Context

@(private = "file")
registry_listener: wl.wl_registry_listener
@(private = "file")
wm_base_listener: wl.xdg_wm_base_listener
@(private = "file")
xdg_surface_listener: wl.xdg_surface_listener
@(private = "file")
toplevel_listener: wl.xdg_toplevel_listener
@(private = "file")
surface_listener: wl.wl_surface_listener
@(private = "file")
seat_listener: wl.wl_seat_listener
@(private = "file")
pointer_listener: wl.wl_pointer_listener
@(private = "file")
keyboard_listener: wl.wl_keyboard_listener

window_open :: proc(w: ^Window, title: string, width, height: int) -> bool {
	g_win_ctx = context
	w.width, w.height = width, height
	w.scale = 1

	w.display = wl.display_connect(nil)
	if w.display == nil {
		fmt.eprintln("cannot connect to a Wayland compositor (is WAYLAND_DISPLAY set?)")
		return false
	}

	registry_listener = {
		global        = on_global,
		global_remove = proc "c" (data: rawptr, self: ^wl.wl_registry, name: u32) {},
	}
	w.registry = wl.wl_display_get_registry(w.display)
	wl.wl_registry_add_listener(w.registry, &registry_listener, w)
	wl.display_roundtrip(w.display)

	if w.compositor == nil || w.wm_base == nil {
		fmt.eprintln("compositor is missing wl_compositor or xdg_wm_base")
		return false
	}

	wm_base_listener = {
		ping = proc "c" (data: rawptr, self: ^wl.xdg_wm_base, serial: u32) {
			wl.xdg_wm_base_pong(self, serial)
		},
	}
	wl.xdg_wm_base_add_listener(w.wm_base, &wm_base_listener, w)

	w.surface = wl.wl_compositor_create_surface(w.compositor)
	surface_listener = {
		enter = proc "c" (data: rawptr, self: ^wl.wl_surface, output: ^wl.wl_output) {},
		leave = proc "c" (data: rawptr, self: ^wl.wl_surface, output: ^wl.wl_output) {},
		preferred_buffer_scale = proc "c" (data: rawptr, self: ^wl.wl_surface, factor: i32) {
			win := cast(^Window)data
			if factor < 1 || int(factor) == win.scale do return
			win.scale = int(factor)
			wl.wl_surface_set_buffer_scale(self, factor)
			win.resized = true
		},
		preferred_buffer_transform = proc "c" (data: rawptr, self: ^wl.wl_surface, transform: u32) {},
	}
	wl.wl_surface_add_listener(w.surface, &surface_listener, w)
	w.xdg_surface = wl.xdg_wm_base_get_xdg_surface(w.wm_base, w.surface)

	xdg_surface_listener = {
		configure = proc "c" (data: rawptr, self: ^wl.xdg_surface, serial: u32) {
			win := cast(^Window)data
			wl.xdg_surface_ack_configure(self, serial)
			if win.new_width > 0 && win.new_height > 0 {
				if win.new_width != win.width || win.new_height != win.height {
					win.width, win.height = win.new_width, win.new_height
					win.resized = true
				}
			}
			win.configured = true
		},
	}
	wl.xdg_surface_add_listener(w.xdg_surface, &xdg_surface_listener, w)

	w.toplevel = wl.xdg_surface_get_toplevel(w.xdg_surface)
	toplevel_listener = {
		configure = proc "c" (data: rawptr, self: ^wl.xdg_toplevel, width, height: i32, states: ^wl.Array) {
			win := cast(^Window)data
			win.new_width, win.new_height = int(width), int(height)
		},
		close = proc "c" (data: rawptr, self: ^wl.xdg_toplevel) {
			(cast(^Window)data).should_close = true
		},
		configure_bounds = proc "c" (data: rawptr, self: ^wl.xdg_toplevel, width, height: i32) {},
		wm_capabilities = proc "c" (data: rawptr, self: ^wl.xdg_toplevel, capabilities: ^wl.Array) {},
	}
	wl.xdg_toplevel_add_listener(w.toplevel, &toplevel_listener, w)

	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	wl.xdg_toplevel_set_title(w.toplevel, ctitle)
	wl.xdg_toplevel_set_app_id(w.toplevel, "spoticyclint")

	// Ask for server-side decorations so we don't have to draw a title bar.
	if w.deco_manager != nil {
		w.decoration = wl.zxdg_decoration_manager_v1_get_toplevel_decoration(
			w.deco_manager,
			w.toplevel,
		)
		wl.zxdg_toplevel_decoration_v1_set_mode(
			w.decoration,
			wl.zxdg_toplevel_decoration_v1_mode_server_side,
		)
	}

	// The surface must be committed without a buffer, then configured, before
	// anything (including the Vulkan swapchain) can attach to it.
	wl.wl_surface_commit(w.surface)
	for !w.configured {
		if wl.display_dispatch(w.display) < 0 do return false
	}
	return true
}

@(private = "file")
on_global :: proc "c" (
	data: rawptr,
	registry: ^wl.wl_registry,
	name: u32,
	interface: cstring,
	version: u32,
) {
	context = g_win_ctx
	w := cast(^Window)data
	switch string(interface) {
	case "wl_compositor":
		w.compositor = cast(^wl.wl_compositor)wl.wl_registry_bind(
			registry,
			name,
			&wl.wl_compositor_interface,
			min(version, 6), // v6 tells us the scale the output wants
		)
	case "xdg_wm_base":
		w.wm_base = cast(^wl.xdg_wm_base)wl.wl_registry_bind(
			registry,
			name,
			&wl.xdg_wm_base_interface,
			min(version, 3),
		)
	case "wl_seat":
		w.seat = cast(^wl.wl_seat)wl.wl_registry_bind(
			registry,
			name,
			&wl.wl_seat_interface,
			min(version, 5),
		)
		seat_listener = {
			capabilities = on_seat_capabilities,
			name         = proc "c" (data: rawptr, self: ^wl.wl_seat, name: cstring) {},
		}
		wl.wl_seat_add_listener(w.seat, &seat_listener, w)
	case "zxdg_decoration_manager_v1":
		w.deco_manager = cast(^wl.zxdg_decoration_manager_v1)wl.wl_registry_bind(
			registry,
			name,
			&wl.zxdg_decoration_manager_v1_interface,
			1,
		)
	}
}

@(private = "file")
on_seat_capabilities :: proc "c" (data: rawptr, self: ^wl.wl_seat, capabilities: u32) {
	context = g_win_ctx
	w := cast(^Window)data

	if capabilities & wl.wl_seat_capability_pointer != 0 && w.pointer == nil {
		w.pointer = wl.wl_seat_get_pointer(self)
		pointer_listener = {
			enter = proc "c" (data: rawptr, self: ^wl.wl_pointer, serial: u32, surface: ^wl.wl_surface, x, y: wl.Fixed) {
				w := cast(^Window)data
				w.input.has_mouse = true
				w.input.mouse = {f32(wl.fixed_to_f64(x)), f32(wl.fixed_to_f64(y))}
			},
			leave = proc "c" (data: rawptr, self: ^wl.wl_pointer, serial: u32, surface: ^wl.wl_surface) {
				(cast(^Window)data).input.has_mouse = false
			},
			motion = proc "c" (data: rawptr, self: ^wl.wl_pointer, time: u32, x, y: wl.Fixed) {
				w := cast(^Window)data
				w.input.mouse = {f32(wl.fixed_to_f64(x)), f32(wl.fixed_to_f64(y))}
			},
			button = on_pointer_button,
			axis = proc "c" (data: rawptr, self: ^wl.wl_pointer, time: u32, axis: u32, value: wl.Fixed) {
				if axis != wl.wl_pointer_axis_vertical_scroll do return
				w := cast(^Window)data
				w.input.scroll -= f32(wl.fixed_to_f64(value))
			},
			frame = proc "c" (data: rawptr, self: ^wl.wl_pointer) {},
			axis_source = proc "c" (data: rawptr, self: ^wl.wl_pointer, axis_source: u32) {},
			axis_stop = proc "c" (data: rawptr, self: ^wl.wl_pointer, time: u32, axis: u32) {},
			axis_discrete = proc "c" (data: rawptr, self: ^wl.wl_pointer, axis: u32, discrete: i32) {},
			axis_value120 = proc "c" (data: rawptr, self: ^wl.wl_pointer, axis: u32, value120: i32) {},
			axis_relative_direction = proc "c" (data: rawptr, self: ^wl.wl_pointer, axis: u32, direction: u32) {},
		}
		wl.wl_pointer_add_listener(w.pointer, &pointer_listener, w)
	}

	if capabilities & wl.wl_seat_capability_keyboard != 0 && w.keyboard == nil {
		w.keyboard = wl.wl_seat_get_keyboard(self)
		keyboard_listener = {
			keymap = proc "c" (data: rawptr, self: ^wl.wl_keyboard, format: u32, fd: i32, size: u32) {
				context = g_win_ctx
				linux.close(linux.Fd(fd)) // we only use raw keycodes
			},
			enter = proc "c" (data: rawptr, self: ^wl.wl_keyboard, serial: u32, surface: ^wl.wl_surface, keys: ^wl.Array) {},
			leave = proc "c" (data: rawptr, self: ^wl.wl_keyboard, serial: u32, surface: ^wl.wl_surface) {},
			key = on_key,
			modifiers = proc "c" (data: rawptr, self: ^wl.wl_keyboard, serial, depressed, latched, locked, group: u32) {},
			repeat_info = proc "c" (data: rawptr, self: ^wl.wl_keyboard, rate, delay: i32) {},
		}
		wl.wl_keyboard_add_listener(w.keyboard, &keyboard_listener, w)
	}
}

@(private = "file")
on_pointer_button :: proc "c" (
	data: rawptr,
	self: ^wl.wl_pointer,
	serial: u32,
	time: u32,
	button: u32,
	state: u32,
) {
	w := cast(^Window)data
	idx := -1
	switch button {
	case BTN_LEFT:
		idx = 0
	case BTN_RIGHT:
		idx = 1
	case BTN_MIDDLE:
		idx = 2
	}
	if idx < 0 do return

	down := state == wl.wl_pointer_button_state_pressed
	if down && !w.input.down[idx] do w.input.pressed[idx] = true
	if !down && w.input.down[idx] do w.input.released[idx] = true
	w.input.down[idx] = down
}

@(private = "file")
on_key :: proc "c" (
	data: rawptr,
	self: ^wl.wl_keyboard,
	serial: u32,
	time: u32,
	key: u32,
	state: u32,
) {
	context = g_win_ctx
	w := cast(^Window)data
	if state == wl.wl_keyboard_key_state_pressed {
		// evdev keycodes are offset by 8 on the wire.
		append(&w.input.keys_pressed, key)
	}
}

// Drains compositor events and clears the one-frame input. `timeout_ms` is how
// long to wait for something to happen: 0 to return immediately, -1 to block
// until the compositor says something.
window_poll :: proc(w: ^Window, timeout_ms: i32 = 0) {
	w.last_mouse = w.input.mouse
	w.input.pressed = {}
	w.input.released = {}
	w.input.scroll = 0
	clear(&w.input.keys_pressed)
	w.resized = false

	wl.display_flush(w.display)

	if wl.display_prepare_read(w.display) == 0 {
		fds := []linux.Poll_Fd {
			{fd = linux.Fd(wl.display_get_fd(w.display)), events = {.IN}},
		}
		n, _ := linux.poll(fds, timeout_ms)
		if n > 0 {
			wl.display_read_events(w.display)
		} else {
			wl.display_cancel_read(w.display)
		}
	}
	wl.display_dispatch_pending(w.display)
}

window_pixel_size :: proc(w: ^Window) -> (int, int) {
	return w.width * w.scale, w.height * w.scale
}

// True if anything happened this frame that the UI should react to.
window_has_input :: proc(w: ^Window) -> bool {
	return(
		w.input.pressed != {} ||
		w.input.released != {} ||
		w.input.scroll != 0 ||
		len(w.input.keys_pressed) > 0 ||
		w.input.mouse != w.last_mouse \
	)
}

window_key_pressed :: proc(w: ^Window, key: u32) -> bool {
	for k in w.input.keys_pressed do if k == key do return true
	return false
}

window_close :: proc(w: ^Window) {
	delete(w.input.keys_pressed)
	if w.decoration != nil do wl.zxdg_toplevel_decoration_v1_destroy(w.decoration)
	if w.toplevel != nil do wl.xdg_toplevel_destroy(w.toplevel)
	if w.xdg_surface != nil do wl.xdg_surface_destroy(w.xdg_surface)
	if w.surface != nil do wl.wl_surface_destroy(w.surface)
	if w.display != nil do wl.display_disconnect(w.display)
}
