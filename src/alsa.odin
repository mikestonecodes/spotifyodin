package spoticyclint

// Hand-written bindings to libasound. Only the handful of calls a plain
// blocking playback stream needs.

import "core:c"

foreign import asound "system:asound"

snd_pcm_t :: struct {}

SND_PCM_STREAM_PLAYBACK :: 0
SND_PCM_FORMAT_S16_LE :: 2
SND_PCM_ACCESS_RW_INTERLEAVED :: 3

@(default_calling_convention = "c")
foreign asound {
	snd_pcm_open :: proc(pcm: ^^snd_pcm_t, name: cstring, stream: c.int, mode: c.int) -> c.int ---
	snd_pcm_set_params :: proc(pcm: ^snd_pcm_t, format: c.int, access: c.int, channels: c.uint, rate: c.uint, soft_resample: c.int, latency_us: c.uint) -> c.int ---
	snd_pcm_writei :: proc(pcm: ^snd_pcm_t, buffer: rawptr, size: c.ulong) -> c.long ---
	snd_pcm_prepare :: proc(pcm: ^snd_pcm_t) -> c.int ---
	snd_pcm_recover :: proc(pcm: ^snd_pcm_t, err: c.int, silent: c.int) -> c.int ---
	snd_pcm_drop :: proc(pcm: ^snd_pcm_t) -> c.int ---
	snd_pcm_close :: proc(pcm: ^snd_pcm_t) -> c.int ---
	snd_strerror :: proc(errnum: c.int) -> cstring ---
}
