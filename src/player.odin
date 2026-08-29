package spoticyclint

// The native player: an access-point session, a queue, and an audio device.
// No Spotify Connect device is involved — this is the thing that plays.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

@(private = "file")
track_load_profile: bool

@(private = "file")
init_track_profile :: proc() {
	track_load_profile = os.get_env("SPOTICYCLINT_PROFILE", context.temp_allocator) != ""
}

Player :: struct {
	session:       ^AP_Session,
	client:        Client,
	session_token: string,
	out:           Audio_Out,
	ready:         bool,
	// Guards the access-point socket: one connection, shared by the worker and
	// the preloader.
	ap_mutex:      sync.Mutex,
	pre:           Preloader,

	// What is playing, and the track before it. Keeping the previous buffer
	// makes going back instant, which matters because nothing preloads
	// backwards.
	current_uri:   string,
	prev_uri:      string,
	prev_samples:  []i16,
}

// Decodes the next track while the current one plays, so skipping forward is a
// buffer swap instead of a download. It shares the player's single access-point
// session: opening a second one under the same device id got every audio key
// request refused. Only the metadata and key exchanges need the session, and
// they are short — the download and decode, which are the slow part, run
// outside the lock.
Preloader :: struct {
	session:   ^AP_Session,
	ap_mutex:  ^sync.Mutex,
	token:     string,
	client:    Client,
	mutex:     sync.Mutex,
	want:      string, // uri the worker would like next
	ready_uri: string, // uri currently sitting in `samples`
	samples:   []i16,
	quit:      bool,
	worker:    ^thread.Thread,
}

player_init :: proc(p: ^Player, c: Client) -> bool {
	init_track_profile()
	p.client = c

	// The access point wants a token from Spotify's own client, which is a
	// different login from the Web API one.
	session_token, have_token := get_access_token(.Session)
	if !have_token {
		fmt.eprintln("could not get a session token for the access point")
		return false
	}
	p.session_token = session_token

	session, ok := ap_connect(session_token, device_id())
	if !ok do return false
	p.session = session

	if !audio_out_init(&p.out) {
		ap_close(session)
		p.session = nil
		return false
	}
	p.ready = true

	p.pre.client = c
	p.pre.token = strings.clone(session_token)
	p.pre.session = session
	p.pre.ap_mutex = &p.ap_mutex
	p.pre.worker = thread.create_and_start_with_poly_data(&p.pre, preload_worker)
	return true
}

// Asks the preloader to have `uri` ready. Cheap and non-blocking.
player_preload :: proc(p: ^Player, uri: string) {
	if p.pre.session == nil do return
	sync.guard(&p.pre.mutex)
	if p.pre.want == uri || p.pre.ready_uri == uri do return
	delete(p.pre.want)
	p.pre.want = strings.clone(uri)
}

@(private = "file")
preload_worker :: proc(pre: ^Preloader) {
	for {
		sync.lock(&pre.mutex)
		if pre.quit {
			sync.unlock(&pre.mutex)
			return
		}
		uri := strings.clone(pre.want, context.temp_allocator)
		already := pre.ready_uri
		sync.unlock(&pre.mutex)

		if uri == "" || uri == already {
			time.sleep(100 * time.Millisecond)
			free_all(context.temp_allocator)
			continue
		}

		audio, ok := load_track_audio(pre.session, pre.ap_mutex, pre.token, uri)

		sync.lock(&pre.mutex)
		if ok && pre.want == uri {
			delete(pre.samples)
			delete(pre.ready_uri)
			pre.samples = audio.samples
			pre.ready_uri = strings.clone(uri)
		} else if ok {
			delete(audio.samples) // the worker moved on while we were loading
		} else {
			// Do not spin on a track that will not load.
			delete(pre.want)
			pre.want = ""
		}
		sync.unlock(&pre.mutex)
		free_all(context.temp_allocator)
	}
}

player_destroy :: proc(p: ^Player) {
	delete(p.current_uri)
	delete(p.prev_uri)
	delete(p.prev_samples)

	sync.lock(&p.pre.mutex)
	p.pre.quit = true
	sync.unlock(&p.pre.mutex)
	if p.pre.worker != nil do thread.join(p.pre.worker)
	delete(p.pre.samples)
	delete(p.pre.want)
	delete(p.pre.ready_uri)
	delete(p.pre.token)

	delete(p.session_token)
	audio_out_destroy(&p.out)
	if p.session != nil do ap_close(p.session)
	p.ready = false
}

// Starts `uri`. If the preloader already has it, this is a buffer swap and
// returns immediately; otherwise it fetches and decodes, which blocks — call it
// from the worker thread, never from the UI thread.
player_load :: proc(p: ^Player, uri: string) -> bool {
	if !p.ready do return false

	samples: []i16

	// Going back to the track we just came from.
	if p.prev_uri == uri && p.prev_samples != nil {
		samples = p.prev_samples
		p.prev_samples = nil
		delete(p.prev_uri)
		p.prev_uri = ""
	}

	// Already decoded by the preloader.
	if samples == nil {
		sync.lock(&p.pre.mutex)
		if p.pre.ready_uri == uri && p.pre.samples != nil {
			samples = p.pre.samples
			p.pre.samples = nil
			delete(p.pre.ready_uri)
			p.pre.ready_uri = ""
		}
		sync.unlock(&p.pre.mutex)
	}

	// Nothing ready: fetch and decode, which takes a few seconds.
	if samples == nil {
		audio, ok := load_track_audio(p.session, &p.ap_mutex, p.session_token, uri)
		if !ok do return false
		samples = audio.samples
	}

	outgoing := audio_out_swap_track(&p.out, samples)

	// Whatever was playing becomes the one step back.
	delete(p.prev_samples)
	delete(p.prev_uri)
	p.prev_samples = outgoing
	p.prev_uri = p.current_uri
	p.current_uri = strings.clone(uri)
	return true
}

// Asks for one file's key, retrying a throttled refusal rather than giving up
// on the track. The session paces and backs off on its own, so each retry
// waits longer than the last.
@(private = "file")
request_key :: proc(
	session: ^AP_Session,
	ap_mutex: ^sync.Mutex,
	f: Audio_File,
) -> (
	key: [16]byte,
	ok: bool,
) {
	KEY_RETRIES :: 3
	for attempt in 0 ..< KEY_RETRIES {
		sync.lock(ap_mutex)
		k, got, transient := ap_audio_key(session, f.gid, f.file_id)
		sync.unlock(ap_mutex)

		if got do return k, true
		// A hard refusal means this recording is not available to us; the
		// caller should move on to an alternative.
		if !transient do return key, false
	}
	return key, false
}

// Resolves a track to playable samples over `session`. Tries Ogg files
// best-quality-first, and falls through to the alternatives when Spotify will
// not hand over a key for the original recording.
load_track_audio :: proc(
	session: ^AP_Session,
	ap_mutex: ^sync.Mutex,
	token: string,
	uri: string,
) -> (
	audio: Decoded_Audio,
	ok: bool,
) {
	gid, gid_ok := track_gid(uri)
	if !gid_ok do return {}, false
	defer delete(gid)

	sync.lock(ap_mutex)
	files, files_ok := ap_track_files(session, gid)
	sync.unlock(ap_mutex)
	if !files_ok || len(files) == 0 do return {}, false
	defer {
		for f in files {
			delete(f.file_id)
			delete(f.gid)
		}
		delete(files)
	}

	// One ordered candidate list rather than a sweep of every format across
	// every alternative: each attempt costs an audio key request, and asking
	// for too many in a row gets the whole session throttled.
	candidates: [dynamic]Audio_File
	defer delete(candidates)
	for want in ([3]int{2, 1, 0}) { // 320, 160, 96 kbps
		for f in files {
			if f.format == want do append(&candidates, f)
		}
	}

	MAX_CANDIDATES :: 3
	for f, attempt in candidates {
		if attempt >= MAX_CANDIDATES do break

		t0 := time.now()
		key, key_ok := request_key(session, ap_mutex, f)
		if !key_ok do continue

		url, url_ok := resolve_audio_url(token, f.file_id)
		if !url_ok do continue
		defer delete(url)

		t1 := time.now()
		encrypted, dl_ok := download_audio_file(url)
		if !dl_ok do continue
		defer delete(encrypted)

		t2 := time.now()
		ogg := decrypt_audio_file(encrypted, key)
		decoded, decode_ok := decode_ogg(ogg)
		if !decode_ok do continue
		if track_load_profile {
			fmt.eprintfln(
				"load: key+resolve %.0fms  download %.0fms (%dKB)  decrypt+decode %.0fms",
				time.duration_milliseconds(time.diff(t0, t1)),
				time.duration_milliseconds(time.diff(t1, t2)),
				len(encrypted) / 1024,
				time.duration_milliseconds(time.since(t2)),
			)
		}

		if decoded.channels != OUT_CHANNELS || decoded.sample_rate != OUT_RATE {
			fmt.eprintfln(
				"unexpected audio format: %d Hz, %d channels",
				decoded.sample_rate,
				decoded.channels,
			)
			delete(decoded.samples)
			continue
		}
		return decoded, true
	}

	return {}, false
}

player_toggle :: proc(p: ^Player) -> bool {
	return audio_out_toggle(&p.out)
}

player_seek :: proc(p: ^Player, ms: int) {
	audio_out_seek(&p.out, ms)
}

player_set_volume :: proc(p: ^Player, v: f32) {
	audio_out_set_volume(&p.out, v)
}

player_position :: proc(p: ^Player) -> Audio_Position {
	return audio_out_position(&p.out)
}

player_track_ended :: proc(p: ^Player) -> bool {
	return audio_out_take_ended(&p.out)
}

_ :: strings
