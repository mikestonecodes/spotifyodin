package spoticyclint

import "core:encoding/json"
import "core:fmt"
import "core:strings"

API :: "https://api.spotify.com/v1"

Track :: struct {
	uri:       string,
	name:      string,
	artist:    string,
	artist_id: string,
	art_url:   string,
}

Device :: struct {
	id:        string,
	name:      string,
	type:      string,
	is_active: bool,
}

Client :: struct {
	token: string,
	// Stored by value: a `[]string{...}` literal is backed by a local array,
	// so a slice of one would dangle the moment client_make returned.
	headers: [2]string,
}

client_make :: proc(token: string) -> Client {
	c := Client {
		token = token,
	}
	c.headers = {
		fmt.aprintf("Authorization: Bearer %s", token),
		"Content-Type: application/json",
	}
	return c
}

api_call :: proc(
	c: Client,
	method: string,
	path: string,
	body: string = "",
	retries := 5,
) -> (
	res: Response,
	ok: bool,
) {
	c := c
	url := fmt.tprintf("%s%s", API, path)
	return http_request(method, url, c.headers[:], body, retries)
}

// Called as pages land, so the UI can show progress.
Progress :: #type proc(done, total: int, user: rawptr)

PAGE :: 50

// Album art is fetched at least this wide, so covers stay sharp on a grid.
ART_MIN_PX :: 300

// Fetches saved tracks into `tracks`, resuming from however many are already
// in there. Returns false if it stopped early — the caller keeps what was
// collected so the next attempt carries on instead of starting over.
//
// This used to run pages in parallel, which was ~8s faster on a 4000-song
// library and reliably got the account rate-limited for minutes. Sequential is
// ~12s once, and the result is cached, so the trade was never worth it.
get_liked_tracks :: proc(
	c: Client,
	tracks: ^[dynamic]Track,
	progress: Progress = nil,
	user: rawptr = nil,
) -> (
	complete: bool,
) {
	total := -1

	for {
		offset := len(tracks)
		page, page_total, page_ok := fetch_page(c, offset)
		defer delete(page)
		if !page_ok do return false

		if total < 0 do total = page_total
		if len(page) == 0 do break

		append(tracks, ..page[:])
		if progress != nil do progress(len(tracks), total, user)
		if total >= 0 && len(tracks) >= total do break
	}
	return true
}

@(private = "file")
fetch_page :: proc(
	c: Client,
	offset: int,
) -> (
	tracks: [dynamic]Track,
	total: int,
	ok: bool,
) {
	res, req_ok := api_call(c, "GET", fmt.tprintf("/me/tracks?limit=%d&offset=%d", PAGE, offset))
	if !req_ok do return tracks, 0, false
	defer delete(res.body)

	if res.status != 200 {
		fmt.eprintfln("GET /me/tracks failed (%d): %s", res.status, res.body)
		return tracks, 0, false
	}

	v, perr := json.parse_string(res.body)
	if perr != nil do return tracks, 0, false
	defer json.destroy_value(v)

	total = jnum(v, "total")
	for item in jarr(v, "items") {
		t := jpath(item, "track")
		if t == nil do continue
		uri := jstr(t, "uri")
		if uri == "" do continue
		// Local files cannot be started via the Web API.
		if strings.has_prefix(uri, "spotify:local") do continue

		artist, artist_id: string
		if artists := jarr(t, "artists"); len(artists) > 0 {
			artist = jstr(artists[0], "name")
			artist_id = jstr(artists[0], "id")
		}

		// Album art comes in three sizes (640/300/64). Take the smallest that
		// is still at least ART_MIN_PX: the 64px one is a blurry mess on
		// anything bigger than a list thumbnail.
		art_url: string
		best_width := 0
		for img in jarr(jpath(t, "album"), "images") {
			url := jstr(img, "url")
			if url == "" do continue
			w := jnum(img, "width")

			take := art_url == ""
			if !take && best_width < ART_MIN_PX do take = w > best_width
			if !take && w >= ART_MIN_PX do take = w < best_width
			if take {
				art_url = url
				best_width = w
			}
		}

		append(
			&tracks,
			Track {
				uri = strings.clone(uri),
				name = strings.clone(jstr(t, "name")),
				artist = strings.clone(artist),
				artist_id = strings.clone(artist_id),
				art_url = strings.clone(art_url),
			},
		)
	}
	return tracks, total, true
}

free_track :: proc(t: Track) {
	delete(t.uri)
	delete(t.name)
	delete(t.artist)
	delete(t.artist_id)
	delete(t.art_url)
}

// How many songs the library holds right now, for validating the cache. Best
// effort and single-shot: if we are rate limited, fall back to the cache
// rather than making the user wait out a Retry-After.
get_liked_total :: proc(c: Client) -> (int, bool) {
	res, ok := api_call(c, "GET", "/me/tracks?limit=1", retries = 1)
	if !ok do return 0, false
	defer delete(res.body)
	if res.status != 200 do return 0, false

	v, perr := json.parse_string(res.body)
	if perr != nil do return 0, false
	defer json.destroy_value(v)
	return jnum(v, "total"), true
}

get_devices :: proc(c: Client) -> (devices: [dynamic]Device, ok: bool) {
	res := api_call(c, "GET", "/me/player/devices") or_return
	defer delete(res.body)
	if res.status != 200 do return devices, false

	v, perr := json.parse_string(res.body)
	if perr != nil do return devices, false
	defer json.destroy_value(v)

	for d in jarr(v, "devices") {
		append(
			&devices,
			Device {
				id = strings.clone(jstr(d, "id")),
				name = strings.clone(jstr(d, "name")),
				type = strings.clone(jstr(d, "type")),
				is_active = jbool(d, "is_active"),
			},
		)
	}
	return devices, true
}

set_shuffle_off :: proc(c: Client, device_id: string) {
	path := device_id == "" \
	? "/me/player/shuffle?state=false" \
	: fmt.tprintf("/me/player/shuffle?state=false&device_id=%s", device_id)
	res, ok := api_call(c, "PUT", path)
	if ok do delete(res.body)
}

// Returns the HTTP status so callers can tell "no device" (404) from
// "not Premium" (403) and say so.
play_uris :: proc(c: Client, uris: []string, device_id: string) -> (int, bool) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"uris\":[")
	for uri, i in uris {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_byte(&b, '"')
		strings.write_string(&b, uri)
		strings.write_byte(&b, '"')
	}
	strings.write_string(&b, "]}")

	path := device_id == "" \
	? "/me/player/play" \
	: fmt.tprintf("/me/player/play?device_id=%s", device_id)

	res, ok := api_call(c, "PUT", path, strings.to_string(b))
	if !ok do return 0, false
	defer delete(res.body)

	if res.status < 200 || res.status >= 300 {
		fmt.eprintfln("PUT %s failed (%d): %s", path, res.status, res.body)
		return res.status, false
	}
	return res.status, true
}

// Turns a player-endpoint status into something worth showing a human.
player_error :: proc(status: int) -> string {
	switch status {
	case 404:
		return "no active Spotify device - open Spotify somewhere"
	case 403:
		return "Spotify refused this (Premium required)"
	case 401:
		return "session expired - log out and back in"
	case 0:
		return "network error"
	}
	return fmt.tprintf("Spotify returned %d", status)
}

Playback :: struct {
	uri:         string,
	name:        string,
	artist:      string,
	progress_ms: int,
	duration_ms: int,
	is_playing:  bool,
	has_item:    bool,
}

playback_destroy :: proc(p: Playback) {
	delete(p.uri)
	delete(p.name)
	delete(p.artist)
}

get_playback :: proc(c: Client) -> (p: Playback, ok: bool) {
	res := api_call(c, "GET", "/me/player") or_return
	defer delete(res.body)
	if res.status == 204 do return {}, true // nothing playing
	if res.status != 200 do return {}, false

	v, perr := json.parse_string(res.body)
	if perr != nil do return {}, false
	defer json.destroy_value(v)

	p.is_playing = jbool(v, "is_playing")
	p.progress_ms = jnum(v, "progress_ms")

	item := jpath(v, "item")
	if item == nil do return p, true
	p.has_item = true
	p.uri = strings.clone(jstr(item, "uri"))
	p.name = strings.clone(jstr(item, "name"))
	p.duration_ms = jnum(item, "duration_ms")
	if artists := jarr(item, "artists"); len(artists) > 0 {
		p.artist = strings.clone(jstr(artists[0], "name"))
	}
	return p, true
}
