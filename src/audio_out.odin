package spoticyclint

// Audio output straight to ALSA. libasound's interface is blocking, so a
// writer thread owns the device and pulls from whatever track is currently
// loaded; everything else just swaps buffers and moves the cursor.

import "core:c"
import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

// Spotify's Ogg files are all 44.1kHz stereo, so the device is opened once and
// never reconfigured between tracks.
OUT_RATE :: 44100
OUT_CHANNELS :: 2
OUT_PERIOD_FRAMES :: 1024
OUT_LATENCY_US :: 100_000

Audio_Out :: struct {
	pcm:         ^snd_pcm_t,
	writer:      ^thread.Thread,
	mutex:       sync.Mutex,
	samples:     []i16, // interleaved, owned here
	cursor:      int, // in frames
	playing:     bool,
	ended:       bool, // current buffer ran out since last check
	volume:      f32, // 0..1, applied as a square curve
	quit:        bool,
	initialised: bool,
}

audio_out_init :: proc(out: ^Audio_Out) -> bool {
	out.volume = 1
	if err := snd_pcm_open(&out.pcm, "default", SND_PCM_STREAM_PLAYBACK, 0); err < 0 {
		fmt.eprintfln("cannot open ALSA device: %s", snd_strerror(err))
		return false
	}

	err := snd_pcm_set_params(
		out.pcm,
		SND_PCM_FORMAT_S16_LE,
		SND_PCM_ACCESS_RW_INTERLEAVED,
		OUT_CHANNELS,
		OUT_RATE,
		1, // allow libasound to resample if the hardware insists
		OUT_LATENCY_US,
	)
	if err < 0 {
		fmt.eprintfln("cannot configure ALSA device: %s", snd_strerror(err))
		snd_pcm_close(out.pcm)
		out.pcm = nil
		return false
	}

	out.initialised = true
	out.writer = thread.create_and_start_with_poly_data(out, audio_writer)
	return true
}

@(private = "file")
audio_writer :: proc(out: ^Audio_Out) {
	block: [OUT_PERIOD_FRAMES * OUT_CHANNELS]i16

	for {
		sync.lock(&out.mutex)
		if out.quit {
			sync.unlock(&out.mutex)
			return
		}

		frames := 0
		gain := out.volume * out.volume // perceptually closer to linear
		if out.playing && out.samples != nil {
			total := len(out.samples) / OUT_CHANNELS
			frames = min(OUT_PERIOD_FRAMES, max(total - out.cursor, 0))
			if frames > 0 {
				copy(block[:frames * OUT_CHANNELS], out.samples[out.cursor * OUT_CHANNELS:][:frames * OUT_CHANNELS])
				out.cursor += frames
			}
			if out.cursor >= total {
				out.ended = true
				out.playing = false
			}
		}
		sync.unlock(&out.mutex)

		if frames > 0 && gain < 0.999 {
			for i in 0 ..< frames * OUT_CHANNELS {
				block[i] = i16(f32(block[i]) * gain)
			}
		}

		if frames == 0 {
			// Paused or empty: idle rather than feeding the device silence.
			time.sleep(20 * time.Millisecond)
			continue
		}

		written := snd_pcm_writei(out.pcm, &block[0], c.ulong(frames))
		if written < 0 {
			// Underruns are normal after a pause or a seek; recover and carry on.
			if snd_pcm_recover(out.pcm, c.int(written), 1) < 0 {
				fmt.eprintfln("ALSA write failed: %s", snd_strerror(c.int(written)))
				return
			}
		}
	}
}

// Takes ownership of `samples` and starts playing from the beginning.
audio_out_set_track :: proc(out: ^Audio_Out, samples: []i16) {
	sync.lock(&out.mutex)
	old := out.samples
	out.samples = samples
	out.cursor = 0
	out.playing = true
	out.ended = false
	sync.unlock(&out.mutex)

	delete(old)
}

audio_out_set_playing :: proc(out: ^Audio_Out, playing: bool) {
	sync.guard(&out.mutex)
	if out.samples != nil do out.playing = playing
}

audio_out_toggle :: proc(out: ^Audio_Out) -> bool {
	sync.guard(&out.mutex)
	if out.samples == nil do return false
	out.playing = !out.playing
	return out.playing
}

audio_out_seek :: proc(out: ^Audio_Out, ms: int) {
	sync.guard(&out.mutex)
	if out.samples == nil do return
	total := len(out.samples) / OUT_CHANNELS
	out.cursor = clamp(ms * OUT_RATE / 1000, 0, total)
	out.ended = false
}

audio_out_set_volume :: proc(out: ^Audio_Out, v: f32) {
	sync.guard(&out.mutex)
	out.volume = clamp(v, 0, 1)
}

audio_out_volume :: proc(out: ^Audio_Out) -> f32 {
	sync.guard(&out.mutex)
	return out.volume
}

Audio_Position :: struct {
	position_ms: int,
	duration_ms: int,
	playing:     bool,
	ended:       bool,
}

audio_out_position :: proc(out: ^Audio_Out) -> Audio_Position {
	sync.guard(&out.mutex)
	total := out.samples != nil ? len(out.samples) / OUT_CHANNELS : 0
	return Audio_Position {
		position_ms = out.cursor * 1000 / OUT_RATE,
		duration_ms = total * 1000 / OUT_RATE,
		playing = out.playing,
		ended = out.ended,
	}
}

// Clears the "current buffer ran out" edge so the caller only advances once.
audio_out_take_ended :: proc(out: ^Audio_Out) -> bool {
	sync.guard(&out.mutex)
	if !out.ended do return false
	out.ended = false
	return true
}

audio_out_destroy :: proc(out: ^Audio_Out) {
	if !out.initialised do return

	sync.lock(&out.mutex)
	out.quit = true
	sync.unlock(&out.mutex)
	if out.writer != nil do thread.join(out.writer)

	snd_pcm_drop(out.pcm)
	snd_pcm_close(out.pcm)
	out.pcm = nil

	delete(out.samples)
	out.samples = nil
	out.initialised = false
}
