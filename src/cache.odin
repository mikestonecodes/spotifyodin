package spoticyclint

import "core:encoding/json"
import "core:fmt"
import "core:crypto"
import "core:encoding/hex"
import "core:os"
import "core:strings"

// The library rarely changes but always costs ~80 requests to read, so it goes
// to disk. On the next run one cheap request confirms the count still matches
// before the cache is trusted.
CACHE_VERSION :: 2 // bumped when art_url moved from 64px to 300px

Cached_Library :: struct {
	version:  int,
	complete: bool, // false while a rate-limited fetch is still catching up
	tracks:   []Track,
}

cache_dir :: proc() -> string {
	if xdg := os.get_env("XDG_CACHE_HOME", context.temp_allocator); xdg != "" {
		return fmt.aprintf("%s/spoticyclint", xdg)
	}
	home := os.get_env("HOME", context.temp_allocator)
	return fmt.aprintf("%s/.cache/spoticyclint", home)
}

library_cache_path :: proc() -> string {
	return fmt.aprintf("%s/liked.json", cache_dir())
}

save_library :: proc(tracks: []Track, complete := true) {
	if len(tracks) == 0 do return
	os.make_directory_all(cache_dir())
	data, err := json.marshal(
		Cached_Library{version = CACHE_VERSION, complete = complete, tracks = tracks},
	)
	if err != nil do return
	defer delete(data)
	_ = os.write_entire_file(library_cache_path(), data)
}

load_library :: proc() -> (tracks: [dynamic]Track, complete: bool, ok: bool) {
	data, err := os.read_entire_file_from_path(library_cache_path(), context.allocator)
	if err != nil do return tracks, false, false
	defer delete(data)

	cached: Cached_Library
	if json.unmarshal(data, &cached) != nil do return tracks, false, false
	if cached.version != CACHE_VERSION || len(cached.tracks) == 0 do return tracks, false, false

	append(&tracks, ..cached.tracks)
	delete(cached.tracks)
	return tracks, cached.complete, true
}

// A stable per-install device id, as the access point expects. librespot uses
// 40 hex characters; anything stable of that shape works.
device_id :: proc() -> string {
	path := fmt.aprintf("%s/device_id", cache_dir())
	if data, err := os.read_entire_file_from_path(path, context.allocator); err == nil {
		if id := strings.trim_space(string(data)); len(id) == 40 do return id
	}

	raw: [20]byte
	crypto.rand_bytes(raw[:])
	id := string(hex.encode(raw[:], context.allocator))

	os.make_directory_all(cache_dir())
	_ = os.write_entire_file(path, transmute([]byte)id)
	return id
}

os_write_file :: proc(path: string, data: []byte) -> bool {
	return os.write_entire_file(path, data) == nil
}

// Small persisted preferences. Kept beside the token rather than in the cache,
// since losing these is annoying rather than merely slow.
Settings :: struct {
	volume: f32,
}

settings_path :: proc() -> string {
	return fmt.aprintf("%s/settings.json", config_dir())
}

load_settings :: proc() -> Settings {
	settings := Settings {
		volume = 1,
	}
	data, err := os.read_entire_file_from_path(settings_path(), context.allocator)
	if err != nil do return settings
	defer delete(data)

	if json.unmarshal(data, &settings) != nil do return Settings{volume = 1}
	settings.volume = clamp(settings.volume, 0, 1)
	return settings
}

save_settings :: proc(settings: Settings) {
	os.make_directory_all(config_dir())
	data, err := json.marshal(settings)
	if err != nil do return
	defer delete(data)
	_ = os.write_entire_file(settings_path(), data)
}

// Tracks Spotify will not give us a key for — usually not licensed here. They
// never become playable, so remember them and stop putting them in the queue.
Unplayable :: struct {
	uris: []string,
}

unplayable_path :: proc() -> string {
	return fmt.aprintf("%s/unplayable.json", cache_dir())
}

load_unplayable :: proc() -> (set: map[string]bool) {
	data, err := os.read_entire_file_from_path(unplayable_path(), context.allocator)
	if err != nil do return
	defer delete(data)

	list: Unplayable
	if json.unmarshal(data, &list) != nil do return
	for uri in list.uris do set[uri] = true
	delete(list.uris)
	return
}

save_unplayable :: proc(set: map[string]bool) {
	uris := make([]string, len(set), context.temp_allocator)
	i := 0
	for uri in set {
		uris[i] = uri
		i += 1
	}

	os.make_directory_all(cache_dir())
	data, err := json.marshal(Unplayable{uris = uris})
	if err != nil do return
	defer delete(data)
	_ = os.write_entire_file(unplayable_path(), data)
}

forget_library :: proc() {
	_ = os.remove(library_cache_path())
	_ = os.remove(unplayable_path())
}
