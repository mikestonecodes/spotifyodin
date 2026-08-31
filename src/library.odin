package spoticyclint

// Reading the library without api.spotify.com.
//
// The Web API's /me/tracks is rate limited per user, and hard: a few full
// library reads in a day earns a Retry-After measured in hours, which leaves
// the app with nothing to show. spclient is a different service with its own
// budget, and it can answer both halves of the question — context-resolve
// lists the liked tracks, and the metadata endpoint describes each one.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

// Modest on purpose. The Web API path was rate limited by being greedy, and
// this endpoint is not a licence to repeat that.
METADATA_WORKERS :: 4

@(private = "file")
Meta_Job :: struct {
	token:    string,
	host:     string,
	uris:     []string,
	tracks:   []Track,
	todo:     []int, // indices into uris still needing a metadata call
	mutex:    sync.Mutex,
	next:     int,
	done:     int,
	failed:   bool,
	progress: Progress,
	user:     rawptr,
}

// Lists the user's liked tracks and fills in what each one is.
fetch_library_spclient :: proc(
	session_token: string,
	progress: Progress = nil,
	user: rawptr = nil,
) -> (
	tracks: [dynamic]Track,
	ok: bool,
) {
	host := spclient_host()

	uris, uris_ok := liked_track_uris(session_token, host)
	defer {
		for u in uris do delete(u)
		delete(uris)
	}
	if !uris_ok || len(uris) == 0 do return tracks, false

	todo := make([]int, len(uris), context.temp_allocator)
	for i in 0 ..< len(uris) do todo[i] = i
	return describe_tracks(session_token, host, uris[:], nil, todo, progress, user)
}

// Brings a cached library up to date instead of refetching it. The liked list
// is a single request, and a track already in the cache describes itself, so
// only songs liked since the cache was written cost a metadata call — a day
// old library is usually two requests rather than several thousand.
//
// `cached` stays owned by the caller: every track here is a fresh copy.
refresh_library_spclient :: proc(
	session_token: string,
	cached: []Track,
	progress: Progress = nil,
	user: rawptr = nil,
) -> (
	tracks: [dynamic]Track,
	ok: bool,
) {
	host := spclient_host()

	uris, uris_ok := liked_track_uris(session_token, host)
	defer {
		for u in uris do delete(u)
		delete(uris)
	}
	if !uris_ok || len(uris) == 0 do return tracks, false

	known := make(map[string]Track, len(cached), context.temp_allocator)
	defer delete(known)
	for t in cached do known[t.uri] = t

	todo := make([dynamic]int, 0, len(uris), context.temp_allocator)
	for uri, i in uris {
		if _, have := known[uri]; !have do append(&todo, i)
	}

	return describe_tracks(session_token, host, uris[:], known, todo[:], progress, user)
}

// Fills in the tracks named by `uris`, reusing anything `known` already
// describes and asking the metadata endpoint for the rest.
@(private = "file")
describe_tracks :: proc(
	session_token, host: string,
	uris: []string,
	known: map[string]Track,
	todo: []int,
	progress: Progress,
	user: rawptr,
) -> (
	tracks: [dynamic]Track,
	ok: bool,
) {
	job := Meta_Job {
		token    = session_token,
		host     = host,
		uris     = uris,
		tracks   = make([]Track, len(uris)),
		todo     = todo,
		progress = progress,
		user     = user,
	}
	defer delete(job.tracks)

	for uri, i in uris {
		if t, have := known[uri]; have do job.tracks[i] = clone_track(t)
	}

	threads: [METADATA_WORKERS]^thread.Thread
	n := min(METADATA_WORKERS, len(todo))
	for i in 0 ..< n do threads[i] = thread.create_and_start_with_poly_data(&job, metadata_worker)
	for i in 0 ..< n {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	// A track we could not describe is dropped rather than shown blank.
	for t in job.tracks {
		if t.uri != "" do append(&tracks, t)
	}
	return tracks, len(tracks) > 0
}

// spotify:user:<id>:collection resolves to the whole liked-songs list in one
// response — no paging.
@(private = "file")
liked_track_uris :: proc(token: string, host: string) -> (uris: [dynamic]string, ok: bool) {
	username := spotify_username(token)
	if username == "" do return uris, false
	defer delete(username)

	endpoint := fmt.tprintf(
		"https://%s/context-resolve/v1/spotify:user:%s:collection",
		host,
		username,
	)
	headers := []string{fmt.tprintf("Authorization: Bearer %s", token)}

	res, req_ok := http_request("GET", endpoint, headers)
	defer delete(res.body)
	if !req_ok || res.status != 200 {
		fmt.eprintfln("context-resolve failed (%d)", res.status)
		return uris, false
	}

	v, err := json.parse_string(res.body)
	if err != nil do return uris, false
	defer json.destroy_value(v)

	for page in jarr(v, "pages") {
		for track in jarr(page, "tracks") {
			uri := jstr(track, "uri")
			if uri != "" do append(&uris, strings.clone(uri))
		}
	}
	return uris, len(uris) > 0
}

@(private = "file")
metadata_worker :: proc(job: ^Meta_Job) {
	for {
		sync.lock(&job.mutex)
		if job.next >= len(job.todo) {
			sync.unlock(&job.mutex)
			return
		}
		index := job.todo[job.next]
		job.next += 1
		sync.unlock(&job.mutex)

		if track, ok := track_metadata(job.token, job.host, job.uris[index]); ok {
			job.tracks[index] = track
		}

		sync.lock(&job.mutex)
		job.done += 1
		done, total, progress, user := job.done, len(job.todo), job.progress, job.user
		sync.unlock(&job.mutex)
		if progress != nil do progress(done, total, user)

		free_all(context.temp_allocator)
	}
}

@(private = "file")
track_metadata :: proc(token, host, uri: string) -> (track: Track, ok: bool) {
	gid, gid_ok := track_gid(uri)
	if !gid_ok do return track, false
	defer delete(gid)

	endpoint := fmt.tprintf(
		"https://%s/metadata/4/track/%s",
		host,
		to_hex_string(gid, context.temp_allocator),
	)
	headers := []string {
		fmt.tprintf("Authorization: Bearer %s", token),
		"Accept: application/json",
	}

	res, req_ok := http_request("GET", endpoint, headers)
	defer delete(res.body)
	if !req_ok || res.status != 200 do return track, false

	v, err := json.parse_string(res.body)
	if err != nil do return track, false
	defer json.destroy_value(v)

	artist, artist_id: string
	if artists := jarr(v, "artist"); len(artists) > 0 {
		artist = jstr(artists[0], "name")
		artist_id = jstr(artists[0], "gid")
	}

	// Covers are listed by width, each as a file id that hangs off the image
	// CDN; pick one for the grid and the largest for the feature tile.
	art_url, art_url_big: string
	best, biggest := 0, 0
	for image in jarr(jpath(v, "album", "cover_group"), "image") {
		file_id := jstr(image, "file_id")
		if file_id == "" do continue
		width := jnum(image, "width")

		take := art_url == ""
		if !take && best < ART_MIN_PX do take = width > best
		if !take && width >= ART_MIN_PX do take = width < best
		if take {
			art_url = fmt.tprintf("https://i.scdn.co/image/%s", file_id)
			best = width
		}
		if width > biggest {
			art_url_big = fmt.tprintf("https://i.scdn.co/image/%s", file_id)
			biggest = width
		}
	}

	return Track {
			uri = strings.clone(uri),
			name = strings.clone(jstr(v, "name")),
			artist = strings.clone(artist),
			artist_id = strings.clone(artist_id),
			art_url = strings.clone(art_url),
			art_url_big = strings.clone(art_url_big),
		},
		true
}

// The account name the collection uri is keyed on. Saved when the access point
// welcomes us, so this never has to ask api.spotify.com — that is the service
// we are routing around.
@(private = "file")
spotify_username :: proc(token: string) -> string {
	return load_username()
}
