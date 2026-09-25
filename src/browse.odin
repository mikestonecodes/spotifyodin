package spoticyclint

// What the / menu offers, and what happens when you pick from it.
//
// Two lists feed it. Your playlists come from spclient's rootlist, which is
// where Discover Weekly, Release Radar and the daily mixes live too — to
// Spotify they are playlists made for one listener. Anything typed also goes
// to the Web API's search, for artists, songs, albums and playlists you do not
// keep. Picking one resolves it to songs on spclient, the same way the liked
// list is read, and the worker swaps it in as the queue.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

Source_Kind :: enum {
	Liked,
	Playlist,
	Album,
	Artist,
	Track,
}

// A row in the menu: something that can become the queue, or one song to play
// now.
Source :: struct {
	kind:  Source_Kind,
	uri:   string,
	name:  string,
	sub:   string, // what it is, drawn at the right of the row
	art:   string, // a cover url, or "" for none
	track: Track, // .Track only: the search already described it
}

LIKED_URI :: "spotify:collection:tracks"
LIKED_NAME :: "Liked Songs"

// The next queue, from the thread that resolved it to the worker that plays it.
Queue_Ready :: struct {
	uri:     string,
	name:    string,
	tracks:  [dynamic]Track, // empty for the liked list, which the worker has
	liked:   bool,
	shuffle: bool,
	now:     bool, // one song, played next, the queue kept around it
}

source_clone :: proc(s: Source, allocator := context.allocator) -> Source {
	c := s
	c.uri = strings.clone(s.uri, allocator)
	c.name = strings.clone(s.name, allocator)
	c.sub = strings.clone(s.sub, allocator)
	c.art = strings.clone(s.art, allocator)
	c.track = Track {
		uri         = strings.clone(s.track.uri, allocator),
		name        = strings.clone(s.track.name, allocator),
		artist      = strings.clone(s.track.artist, allocator),
		artist_id   = strings.clone(s.track.artist_id, allocator),
		art_url     = strings.clone(s.track.art_url, allocator),
		art_url_big = strings.clone(s.track.art_url_big, allocator),
	}
	return c
}

source_free :: proc(s: Source) {
	delete(s.uri)
	delete(s.name)
	delete(s.sub)
	delete(s.art)
	free_track(s.track)
}

// ------------------------------------------------------------- your playlists

// The playlists in your library, in the order you keep them, except that the
// ones Spotify makes for you each week come first: they are the reason to open
// the menu most weeks, and in the rootlist they sit wherever you first saved
// them.
fetch_playlists :: proc(session_token: string) -> (list: [dynamic]Source, ok: bool) {
	username := load_username()
	defer delete(username)
	if username == "" do return list, false

	endpoint := fmt.tprintf(
		"https://%s/playlist/v2/user/%s/rootlist?decorate=revision,length,attributes,timestamp,owner",
		spclient_host(),
		username,
	)
	headers := []string {
		fmt.tprintf("Authorization: Bearer %s", session_token),
		"Accept: application/json",
	}
	res, req_ok := http_request("GET", endpoint, headers, retries = 2)
	defer delete(res.body)
	if !req_ok || res.status != 200 {
		fmt.eprintfln("rootlist failed (%d)", res.status)
		return list, false
	}

	v, err := json.parse_string(res.body)
	if err != nil do return list, false
	defer json.destroy_value(v)

	Ranked :: struct {
		source: Source,
		rank:   int,
	}
	found := make([dynamic]Ranked, 0, 64, context.temp_allocator)

	// items and metaItems run side by side: the uri in one, what it is called
	// in the other. Folders are markers in the same list and are skipped.
	contents := jpath(v, "contents")
	metas := jarr(contents, "metaItems")
	for item, i in jarr(contents, "items") {
		uri := jstr(item, "uri")
		if !strings.has_prefix(uri, "spotify:playlist:") || i >= len(metas) do continue
		attrs := jpath(metas[i], "attributes")
		name := jstr(attrs, "name")
		if name == "" do continue

		art: string
		for pic in jarr(attrs, "pictureSize") {
			if art == "" || jstr(pic, "targetName") == "default" do art = jstr(pic, "url")
		}

		// An empty playlist has nothing to play; the DJ is one, as far as
		// this can tell, since what it plays is made up as it goes.
		count := jnum(metas[i], "length")
		if count == 0 do continue
		rank := playlist_rank(jstr(attrs, "format"))
		sub := rank < 3 ? "made for you" : count == 1 ? "1 song" : fmt.tprintf("%d songs", count)
		append(
			&found,
			Ranked {
				source = Source {
					kind = .Playlist,
					uri = strings.clone(uri),
					name = strings.clone(strings.trim_space(name)),
					sub = strings.clone(sub),
					art = strings.clone(art),
				},
				rank = rank,
			},
		)
	}

	slice.stable_sort_by(found[:], proc(a, b: Ranked) -> bool {return a.rank < b.rank})
	for r in found do append(&list, r.source)
	return list, true
}

@(private = "file")
playlist_rank :: proc(format: string) -> int {
	switch format {
	case "discover-weekly":
		return 0
	case "release-radar":
		return 1
	case "daily-mix":
		return 2
	}
	return 3
}

// ------------------------------------------------------------------- search

// Spotify's catalogue, for what was typed. This is the one call the menu makes
// to api.spotify.com, with the app's own client id: spclient's search is gone,
// and the Web API's limits are generous for a request per pause in typing.
search_spotify :: proc(query: string) -> (hits: [dynamic]Source, ok: bool) {
	token, have := get_access_token()
	if !have do return hits, false
	defer delete(token)
	c := client_make(token)
	defer delete(c.headers[0])

	path := fmt.tprintf(
		"/search?q=%s&type=artist,track,album,playlist&limit=6",
		net.percent_encode(query, context.temp_allocator),
	)
	res, req_ok := api_call(c, "GET", path, retries = 1)
	defer delete(res.body)
	if !req_ok || res.status != 200 {
		fmt.eprintfln("search failed (%d)", res.status)
		return hits, false
	}

	v, err := json.parse_string(res.body)
	if err != nil do return hits, false
	defer json.destroy_value(v)

	// Artists lead: a name typed into a music player is usually someone's.
	for a, i in jarr(jpath(v, "artists"), "items") {
		if i >= 3 do break
		add_hit(&hits, .Artist, a, "artist", pick_image(jarr(a, "images")))
	}
	for t in jarr(jpath(v, "tracks"), "items") {
		album := jpath(t, "album")
		images := jarr(album, "images")
		h := add_hit(&hits, .Track, t, fmt.tprintf("song  %s", first_artist(t)), pick_image(images))
		if h == nil do continue
		biggest, width := "", 0
		for img in images {
			if w := jnum(img, "width"); w > width do biggest, width = jstr(img, "url"), w
		}
		h.track = Track {
			uri         = strings.clone(h.uri),
			name        = strings.clone(h.name),
			artist      = strings.clone(first_artist(t)),
			art_url     = strings.clone(h.art),
			art_url_big = strings.clone(biggest),
		}
	}
	for a, i in jarr(jpath(v, "albums"), "items") {
		if i >= 4 do break
		add_hit(&hits, .Album, a, fmt.tprintf("album  %s", first_artist(a)), pick_image(jarr(a, "images")))
	}
	for p, i in jarr(jpath(v, "playlists"), "items") {
		if i >= 4 do break
		add_hit(&hits, .Playlist, p, fmt.tprintf("playlist  %s", jstr(jpath(p, "owner"), "display_name")), pick_image(jarr(p, "images")))
	}
	return hits, true
}

// The search lists null where an item has been taken down since it was
// indexed, so an entry with no uri is not a row.
@(private = "file")
add_hit :: proc(hits: ^[dynamic]Source, kind: Source_Kind, item: json.Value, sub, art: string) -> ^Source {
	uri, name := jstr(item, "uri"), jstr(item, "name")
	if uri == "" || name == "" do return nil
	append(hits, Source{kind = kind, uri = strings.clone(uri), name = strings.clone(name), sub = strings.clone(sub), art = strings.clone(art)})
	return &hits[len(hits) - 1]
}

@(private = "file")
first_artist :: proc(item: json.Value) -> string {
	if artists := jarr(item, "artists"); len(artists) > 0 do return jstr(artists[0], "name")
	return ""
}

// The smallest picture still at least as wide as a cover is stored, so a row's
// thumbnail and a tile's cover can come from the same download.
@(private = "file")
pick_image :: proc(images: []json.Value) -> string {
	url, best := "", 0
	for img in images {
		w := jnum(img, "width")
		take := url == "" || (best < ART_TEXTURE_PX && w > best) || (w >= ART_TEXTURE_PX && w < best)
		if take do url, best = jstr(img, "url"), w
	}
	return url
}

// ------------------------------------------------------------------ threads

// Lists your playlists, then answers searches as the menu asks for them. It
// is its own thread so that typing never waits on a playlist being opened.
browse_main :: proc(s: ^Shared) {
	listed := false
	for {
		if !listed {
			if token, have := get_access_token(.Session); have {
				list, ok := fetch_playlists(token)
				delete(token)
				if ok {
					listed = true
					sync.guard(&s.mutex)
					for p in s.playlists do source_free(p)
					delete(s.playlists)
					s.playlists = list
					s.browse_gen += 1
				}
			}
		}

		// Woken by the menu, or every half minute to try the list again if it
		// did not come the first time.
		sync.sema_wait_with_timeout(&s.browse_wake, 30 * time.Second)

		sync.lock(&s.mutex)
		quit := s.quit
		query := s.search_want != s.found_for ? strings.clone(s.search_want, context.temp_allocator) : ""
		sync.unlock(&s.mutex)
		if quit do return
		if query == "" do continue

		hits, ok := search_spotify(query)
		sync.lock(&s.mutex)
		for h in s.found do source_free(h)
		delete(s.found)
		s.found = hits
		delete(s.found_for)
		s.found_for = strings.clone(query)
		s.found_failed = !ok
		s.browse_gen += 1
		sync.unlock(&s.mutex)
		free_all(context.temp_allocator)
	}
}

// Turns what was picked into songs. Everything described along the way is
// kept, here and on disk, so a song seen once never costs a request again —
// Discover Weekly shares most of its artists with last week's.
open_main :: proc(s: ^Shared) {
	known: map[string]Track
	liked: map[string]bool
	defer {
		for _, t in known do free_track(t)
		delete(known)
		delete(liked)
	}
	if library, _, have := load_library(); have {
		for t in library {
			known[t.uri] = t
			liked[t.uri] = true
		}
		delete(library)
	}
	extra := load_known()
	for t in extra {
		if _, dup := known[t.uri]; dup {
			free_track(t)
			continue
		}
		known[t.uri] = t
	}
	delete(extra)

	for {
		sync.sema_wait(&s.open_wake)

		sync.lock(&s.mutex)
		quit := s.quit
		src, has := s.open_want, s.open_pending
		s.open_want, s.open_pending = {}, false
		sync.unlock(&s.mutex)
		if quit do return
		if !has do continue
		defer source_free(src)

		ready := Queue_Ready {
			uri  = strings.clone(src.uri),
			name = strings.clone(src.name),
		}
		switch src.kind {
		case .Liked:
			ready.liked = true
			ready.shuffle = true
		case .Track:
			ready.now = true
			append(&ready.tracks, clone_track(src.track))
		case .Playlist, .Album, .Artist:
			token, have := get_access_token(.Session)
			tracks: [dynamic]Track
			ok: bool
			if have {
				tracks, ok = fetch_context_tracks(token, src.uri, known, on_open_progress, s)
				delete(token)
			}
			if !ok {
				delete(tracks)
				delete(ready.uri)
				delete(ready.name)
				open_failed(s, fmt.tprintf("could not open %s", src.name))
				continue
			}
			learned := false
			for t in tracks {
				if _, have_it := known[t.uri]; have_it do continue
				known[t.uri] = clone_track(t)
				learned = true
			}
			if learned do save_known_tracks(known, liked)
			ready.tracks = tracks
			// A playlist is shuffled like the liked list is; an album and an
			// artist's top songs are in an order someone meant.
			ready.shuffle = src.kind == .Playlist
		}

		sync.lock(&s.mutex)
		if s.has_ready {
			// Picked again before the worker took the last one: that one never
			// played, so nothing else holds it.
			for t in s.ready.tracks do free_track(t)
			delete(s.ready.tracks)
			delete(s.ready.uri)
			delete(s.ready.name)
		}
		s.ready, s.has_ready = ready, true
		sync.unlock(&s.mutex)
		sync.sema_post(&s.wake)
		free_all(context.temp_allocator)
	}
}

@(private = "file")
save_known_tracks :: proc(known: map[string]Track, liked: map[string]bool) {
	keep := make([dynamic]Track, 0, len(known), context.temp_allocator)
	for uri, t in known {
		if !liked[uri] do append(&keep, t)
	}
	save_known(keep[:])
}

@(private = "file")
on_open_progress :: proc(done, total: int, user: rawptr) {
	s := cast(^Shared)user
	sync.guard(&s.mutex)
	s.opening_done, s.opening_total = done, total
}

// Said in the chip over the grid, which stays up a few seconds for it.
open_failed :: proc(s: ^Shared, why: string) {
	sync.guard(&s.mutex)
	delete(s.opening)
	s.opening = strings.clone(why)
	s.opening_failed = true
	s.opening_at = time.now()
}
