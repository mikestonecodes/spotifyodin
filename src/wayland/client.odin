// Minimal hand-written bindings to libwayland-client. Everything protocol
// specific lives in protocol.odin, which is generated from the XML.
package wayland

import "core:c"

foreign import wl "system:wayland-client"

Proxy :: struct {}

Message :: struct {
	name:      cstring,
	signature: cstring,
	types:     [^]^Interface,
}

Interface :: struct {
	name:         cstring,
	version:      c.int,
	method_count: c.int,
	methods:      [^]Message,
	event_count:  c.int,
	events:       [^]Message,
}

Array :: struct {
	size:  c.size_t,
	alloc: c.size_t,
	data:  rawptr,
}

// 24.8 fixed point.
Fixed :: distinct i32

fixed_to_f64 :: proc "contextless" (f: Fixed) -> f64 {
	return f64(i32(f)) / 256.0
}

fixed_from_f64 :: proc "contextless" (v: f64) -> Fixed {
	return Fixed(i32(v * 256.0))
}

MARSHAL_FLAG_DESTROY :: 1

@(default_calling_convention = "c", link_prefix = "wl_")
foreign wl {
	display_connect         :: proc(name: cstring) -> ^wl_display ---
	display_disconnect      :: proc(display: ^wl_display) ---
	display_get_fd          :: proc(display: ^wl_display) -> c.int ---
	display_dispatch        :: proc(display: ^wl_display) -> c.int ---
	display_dispatch_pending :: proc(display: ^wl_display) -> c.int ---
	display_roundtrip       :: proc(display: ^wl_display) -> c.int ---
	display_flush           :: proc(display: ^wl_display) -> c.int ---
	display_get_error       :: proc(display: ^wl_display) -> c.int ---
	display_prepare_read    :: proc(display: ^wl_display) -> c.int ---
	display_read_events     :: proc(display: ^wl_display) -> c.int ---
	display_cancel_read     :: proc(display: ^wl_display) ---

	proxy_marshal_flags :: proc(proxy: ^Proxy, opcode: u32, interface: ^Interface, version: u32, flags: u32, #c_vararg args: ..any) -> ^Proxy ---
	proxy_add_listener  :: proc(proxy: ^Proxy, implementation: [^]rawptr, data: rawptr) -> c.int ---
	proxy_destroy       :: proc(proxy: ^Proxy) ---
	proxy_get_version   :: proc(proxy: ^Proxy) -> u32 ---
	proxy_get_id        :: proc(proxy: ^Proxy) -> u32 ---
	proxy_set_user_data :: proc(proxy: ^Proxy, data: rawptr) ---
	proxy_get_user_data :: proc(proxy: ^Proxy) -> rawptr ---
}
