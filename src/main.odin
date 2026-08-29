package spoticyclint

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

CHUNK :: 100 // Spotify's /me/player/play accepts at most 100 URIs per call.
POLL :: 4 * time.Second
LEAD_MS :: 8000 // queue the next chunk this long before the last track ends

Options :: struct {
	command: string,
	device:  string,
	track:   string,
	repeat:  bool,
	limit:   int,
	dry_run: bool,
	forget_cache: bool,
}

@(private = "file")
cli_progress :: proc(done, total: int, user: rawptr) {
	fmt.printf("\rLoading %d / %d liked songs...", done, total)
}

clock_string :: proc(ms: int) -> string {
	total := ms / 1000
	return fmt.tprintf("%d:%02d", total / 60, total % 60)
}

usage :: proc() {
	fmt.println(
		`spoticyclint — smart-shuffle your liked songs

usage: spoticyclint [command] [options]

commands:
  ap-login    test the native access-point session
  fetch       play one track natively (--dry-run writes track.wav instead)
  ui          the Wayland/Vulkan window (default when a compositor is up)
  play        shuffle all liked songs and play them
  devices     list your available Spotify devices
  login       authorise this machine
  logout      forget the stored tokens (--forget-cache drops the library too)

options:
  --device <name>   play on the device whose name contains <name>
  --repeat          reshuffle and start over when the library runs out
  --limit <n>       only use the n most recently liked songs
  --dry-run         print the shuffled order, do not touch playback

setup:
  Create an app at https://developer.spotify.com/dashboard, add
  http://127.0.0.1:8888/callback as a redirect URI, then export
  SPOTIFY_CLIENT_ID=<id> (or write it to ~/.config/spoticyclint/client_id).
  Playback control requires Spotify Premium.`,
	)
}

parse_args :: proc() -> (opt: Options, ok: bool) {
	// With a compositor available and no command given, show the window.
	opt.command = os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" ? "ui" : "play"
	args := os.args[1:]
	i := 0
	for i < len(args) {
		a := args[i]
		switch a {
		case "play", "devices", "login", "logout", "ui", "ap-login", "fetch":
			opt.command = a
		case "--repeat":
			opt.repeat = true
		case "--dry-run":
			opt.dry_run = true
		case "--forget-cache":
			opt.forget_cache = true
		case "-h", "--help", "help":
			usage()
			return opt, false
		case "--track":
			i += 1
			if i >= len(args) {
				fmt.eprintln("--track needs a value")
				return opt, false
			}
			opt.track = args[i]
		case "--device":
			i += 1
			if i >= len(args) {
				fmt.eprintln("--device needs a value")
				return opt, false
			}
			opt.device = args[i]
		case "--limit":
			i += 1
			if i >= len(args) {
				fmt.eprintln("--limit needs a value")
				return opt, false
			}
			n, n_ok := strconv.parse_int(args[i])
			if !n_ok || n <= 0 {
				fmt.eprintln("--limit needs a positive number")
				return opt, false
			}
			opt.limit = n
		case:
			fmt.eprintfln("unknown argument: %s", a)
			return opt, false
		}
		i += 1
	}
	return opt, true
}

main :: proc() {
	http_init()

	opt, args_ok := parse_args()
	if !args_ok do os.exit(1)

	if opt.command == "logout" {
		logout(opt.forget_cache)
		return
	}

	token, have_token := get_access_token()
	if !have_token do os.exit(1)

	c := client_make(token)

	switch opt.command {
	case "login":
		fmt.println("Logged in.")
	case "devices":
		cmd_devices(c)
	case "play":
		cmd_play(c, opt)
	case "ui":
		run_ui(c, opt.device)
	case "ap-login":
		cmd_ap_login(c)
	case "fetch":
		cmd_fetch(c, opt)
	}
}

// The whole native path in one go: log in, resolve the track to a file,
// get its key, pull it from the CDN, decrypt, decode, write a WAV.
cmd_fetch :: proc(c: Client, opt: Options) {
	uri := opt.track
	if uri == "" {
		tracks, _, have := load_library()
		defer delete(tracks)
		if !have || len(tracks) == 0 {
			fmt.eprintln("pass --track spotify:track:... or build the library cache first")
			os.exit(1)
		}
		uri = strings.clone(tracks[0].uri)
	}

	gid, gid_ok := track_gid(uri)
	if !gid_ok {
		fmt.eprintfln("not a track uri: %s", uri)
		os.exit(1)
	}
	defer delete(gid)

	session_token, have := get_access_token(.Session)
	if !have do os.exit(1)
	defer delete(session_token)

	session, ok := ap_connect(session_token, device_id())
	if !ok do os.exit(1)
	defer ap_close(session)

	files, files_ok := ap_track_files(session, gid)
	if !files_ok || len(files) == 0 {
		fmt.eprintln("no audio files for that track")
		os.exit(1)
	}
	defer {
		for f in files {
			delete(f.file_id)
			delete(f.gid)
		}
		delete(files)
	}

	best: Audio_File
	for f in files {
		if f.format == 2 do best = f
		else if best.file_id == nil && (f.format == 1 || f.format == 0) do best = f
	}
	if best.file_id == nil {
		fmt.eprintln("no Ogg Vorbis file for that track")
		os.exit(1)
	}
	fmt.printfln("file: %s (%s)", to_hex_string(best.file_id, context.temp_allocator), audio_format_name(best.format))

	key, key_ok, _ := ap_audio_key(session, best.gid, best.file_id)
	if !key_ok do os.exit(1)

	url, url_ok := resolve_audio_url(session_token, best.file_id)
	if !url_ok do os.exit(1)
	defer delete(url)
	fmt.printfln("cdn: %s", url[:min(len(url), 60)])

	encrypted, dl_ok := download_audio_file(url)
	if !dl_ok do os.exit(1)
	defer delete(encrypted)
	fmt.printfln("downloaded %d bytes", len(encrypted))

	ogg := decrypt_audio_file(encrypted, key)
	audio, decode_ok := decode_ogg(ogg)
	if !decode_ok do os.exit(1)

	seconds := f64(len(audio.samples) / audio.channels) / f64(audio.sample_rate)
	fmt.printfln("decoded %.1fs, %d Hz, %d channels", seconds, audio.sample_rate, audio.channels)

	if opt.dry_run {
		if write_wav("track.wav", audio) do fmt.println("wrote track.wav")
		return
	}
	fmt.printfln("playing %s", uri)
	out: Audio_Out
	if !audio_out_init(&out) do os.exit(1)
	defer audio_out_destroy(&out)
	audio_out_set_track(&out, audio.samples)

	for {
		pos := audio_out_position(&out)
		fmt.printf("\r  %s / %s", clock_string(pos.position_ms), clock_string(pos.duration_ms))
		if pos.ended do break
		time.sleep(250 * time.Millisecond)
	}
	fmt.println()
}

// Diagnostic for the native access-point client: does the handshake complete
// and does Spotify accept our token as a login?
cmd_ap_login :: proc(c: Client) {
	fmt.println("connecting to a Spotify access point...")
	session_token, have_session := get_access_token(.Session)
	if !have_session do os.exit(1)
	defer delete(session_token)

	session, ok := ap_connect(session_token, device_id())
	if !ok {
		fmt.eprintln("access point session failed")
		os.exit(1)
	}
	defer ap_close(session)
	fmt.printfln("logged in to the access point as %q", session.username)

	// Only needed for the HTTPS spclient endpoints; metadata comes over the
	// authenticated Mercury channel, so a refusal here is not fatal.
	// Resolve a track to the audio files Spotify actually stores. Uses the
	// cached library when there is one, so this works without the Web API.
	uri := "spotify:track:3eQS0faku2vB0dP8WTne9v"
	name, artist := "Bird's Eye", "Lusine"
	tracks, _, have := load_library()
	defer delete(tracks)
	if have && len(tracks) > 0 {
		uri, name, artist = tracks[0].uri, tracks[0].name, tracks[0].artist
	}

	gid, gid_ok := track_gid(uri)
	if !gid_ok {
		fmt.eprintln("could not decode that track id")
		return
	}
	defer delete(gid)

	fmt.printfln("track: %s - %s", artist, name)
	fmt.printfln("  uri: %s", uri)
	fmt.printfln("  gid: %s", to_hex_string(gid, context.temp_allocator))
	files, files_ok := ap_track_files(session, gid)
	if !files_ok do return
	defer delete(files)

	best: Audio_File
	for f in files {
		fmt.printfln("  %-16s %s", audio_format_name(f.format), to_hex_string(f.file_id, context.temp_allocator))
		// Prefer 320kbps Ogg, then 160, then 96.
		if f.format == 2 || (best.file_id == nil && (f.format == 1 || f.format == 0)) {
			best = f
		}
	}
	if best.file_id == nil {
		fmt.println("  no Ogg Vorbis file listed for this track")
		return
	}

	key, key_ok, _ := ap_audio_key(session, gid, best.file_id)
	if !key_ok {
		fmt.println("  could not get an audio key")
		return
	}
	fmt.printfln("audio key for %s: %s", audio_format_name(best.format), to_hex_string(key[:], context.temp_allocator))

	// Several tracks over one session, which is what the player does.
	if have && len(tracks) >= 4 {
		fmt.println("reusing the session for more tracks:")
		for t in tracks[1:4] {
			g, g_ok := track_gid(t.uri)
			if !g_ok do continue
			defer delete(g)

			fs, fs_ok := ap_track_files(session, g)
			if !fs_ok || len(fs) == 0 {
				fmt.printfln("  %-28s metadata failed", t.name)
				continue
			}
			pick: Audio_File
			for f in fs {
				if f.format == 2 do pick = f
				else if pick.file_id == nil && (f.format == 1 || f.format == 0) do pick = f
			}
			if pick.file_id != nil {
				_, ok2, _ := ap_audio_key(session, g, pick.file_id)
				fmt.printfln("  %-28s key %s", t.name, ok2 ? "OK" : "REFUSED")
			}
			for f in fs {
				delete(f.file_id)
				delete(f.gid)
			}
			delete(fs)
		}
	}
}

cmd_devices :: proc(c: Client) {
	devices, ok := get_devices(c)
	if !ok {
		fmt.eprintln("could not list devices")
		os.exit(1)
	}
	if len(devices) == 0 {
		fmt.println("No devices. Open Spotify on a phone, desktop or speaker first.")
		return
	}
	for d in devices {
		mark := d.is_active ? "*" : " "
		fmt.printfln("%s %-28s %s", mark, d.name, d.type)
	}
}

// Picks the device to play on: the one matching --device, else the active one,
// else whatever Spotify already considers current (empty id).
pick_device :: proc(c: Client, want: string) -> (string, bool) {
	devices, ok := get_devices(c)
	if !ok do return "", false
	defer delete(devices)

	if want != "" {
		for d in devices {
			if strings.contains(strings.to_lower(d.name, context.temp_allocator),
				strings.to_lower(want, context.temp_allocator)) {
				fmt.printfln("Device: %s", d.name)
				return d.id, true
			}
		}
		fmt.eprintfln("no device matching %q", want)
		return "", false
	}

	for d in devices {
		if d.is_active {
			fmt.printfln("Device: %s", d.name)
			return d.id, true
		}
	}
	if len(devices) == 1 {
		fmt.printfln("Device: %s", devices[0].name)
		return devices[0].id, true
	}
	if len(devices) == 0 {
		fmt.eprintln("No Spotify devices are available. Open Spotify somewhere first.")
		return "", false
	}
	fmt.eprintln("No active device; pick one with --device <name>. Available:")
	for d in devices do fmt.eprintfln("  %s (%s)", d.name, d.type)
	return "", false
}

cmd_play :: proc(c: Client, opt: Options) {
	tracks, complete, hit := load_library()
	if hit && complete {
		total, known := get_liked_total(c)
		if known && total != len(tracks) {
			for t in tracks do free_track(t)
			clear(&tracks)
			complete = false
		}
	}
	ok := hit && complete
	if !ok {
		ok = get_liked_tracks(c, &tracks, cli_progress)
		save_library(tracks[:], ok)
		fmt.println()
	}
	if !ok {
		fmt.eprintln("could not load liked songs")
		os.exit(1)
	}
	if len(tracks) == 0 {
		fmt.println("You have no liked songs.")
		return
	}

	pool := tracks[:]
	if opt.limit > 0 && opt.limit < len(pool) {
		pool = pool[:opt.limit]
	}

	if opt.dry_run {
		order := smart_shuffle(pool)
		for t, i in order {
			fmt.printfln("%4d. %s — %s", i + 1, t.artist, t.name)
		}
		return
	}

	device_id, dev_ok := pick_device(c, opt.device)
	if !dev_ok do os.exit(1)

	set_shuffle_off(c, device_id) // our order is the shuffle

	for {
		order := smart_shuffle(pool)
		fmt.printfln("Smart shuffling %d songs.", len(order))

		for start := 0; start < len(order); start += CHUNK {
			end := min(start + CHUNK, len(order))
			chunk := order[start:end]

			uris := make([]string, len(chunk), context.temp_allocator)
			for t, i in chunk do uris[i] = t.uri

			if status, played := play_uris(c, uris, device_id); !played {
				fmt.eprintln(player_error(status))
				os.exit(1)
			}

			if !follow_chunk(c, chunk) {
				fmt.println("Playback stopped.")
				return
			}
			free_all(context.temp_allocator)
		}

		if !opt.repeat do break
	}
	fmt.println("Done.")
}

// Polls playback until the chunk is nearly over, printing each track as it
// starts. Returns false if the user stopped playback or wandered off elsewhere.
follow_chunk :: proc(c: Client, chunk: []Track) -> bool {
	in_chunk: map[string]bool
	defer delete(in_chunk)
	for t in chunk do in_chunk[t.uri] = true
	last_uri := chunk[len(chunk) - 1].uri

	shown: string
	misses := 0

	for {
		p, ok := get_playback(c)
		defer playback_destroy(p)
		if !ok {
			misses += 1
			if misses > 3 do return false
			time.sleep(POLL)
			continue
		}
		misses = 0

		if !p.has_item {
			time.sleep(POLL)
			continue
		}

		if p.uri != shown {
			if p.uri in in_chunk {
				fmt.printfln("  ▸ %s — %s", p.artist, p.name)
			} else {
				// Something else took over the player.
				return false
			}
			if shown != "" do delete(shown)
			shown = strings.clone(p.uri)
		}

		if p.uri == last_uri && p.duration_ms > 0 {
			if p.duration_ms - p.progress_ms <= LEAD_MS {
				if shown != "" do delete(shown)
				return true
			}
		}

		time.sleep(POLL)
	}
}
