package spoticyclint

// Turning a track into playable samples: resolve the file to a CDN URL, pull
// the bytes, undo Spotify's AES-CTR, then decode the Ogg Vorbis inside.

import "core:c/libc"
import "core:crypto/aes"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import vorbis "vendor:stb/vorbis"

// Every Spotify audio file uses this IV; the key is the per-file one the
// access point hands out. From reference/librespot (audio/src/decrypt.rs).
AUDIO_AES_IV := [16]byte {
	0x72, 0xe0, 0x67, 0xfb, 0xdd, 0xcb, 0xcf, 0x77,
	0xeb, 0xe8, 0xbc, 0x64, 0x3f, 0x63, 0x0d, 0x93,
}

// Spotify prepends a header to the Ogg stream that the decoder must not see.
SPOTIFY_OGG_HEADER_END :: 0xa7

spclient_host :: proc() -> string {
	res, ok := http_request("GET", "https://apresolve.spotify.com/?type=spclient", nil)
	defer delete(res.body)
	if ok && res.status == 200 {
		v, err := json.parse_string(res.body)
		if err == nil {
			defer json.destroy_value(v)
			for entry in jarr(v, "spclient") {
				if s, is_str := entry.(json.String); is_str {
					return strings.clone(string(s))
				}
			}
		}
	}
	return strings.clone("gew1-spclient.spotify.com:443")
}

// storage-resolve hands back a protobuf listing CDN mirrors for the file.
// Wants the session token: spclient rejects a third-party app's token with 403.
resolve_audio_url :: proc(session_token: string, file_id: []byte) -> (url: string, ok: bool) {
	host := spclient_host()
	defer delete(host)

	endpoint := fmt.tprintf(
		"https://%s/storage-resolve/files/audio/interactive/%s",
		host,
		to_hex_string(file_id, context.temp_allocator),
	)
	headers := []string{fmt.tprintf("Authorization: Bearer %s", session_token)}

	res, req_ok := http_request("GET", endpoint, headers)
	defer delete(res.body)
	if !req_ok || res.status != 200 {
		fmt.eprintfln("storage-resolve failed (%d): %s", res.status, res.body)
		return "", false
	}

	// StorageResolveResponse.cdnurl is field 2, repeated.
	cdn, found := pb_find(transmute([]byte)res.body, 2)
	if !found do return "", false
	return strings.clone(string(cdn)), true
}

// Fetches the whole encrypted file. Spotify's files are a few megabytes, so
// this reads it in one go rather than streaming.
download_audio_file :: proc(url: string) -> (data: []byte, ok: bool) {
	res, req_ok := http_request("GET", url, nil)
	if !req_ok || res.status != 200 {
		delete(res.body)
		fmt.eprintfln("CDN fetch failed (%d)", res.status)
		return nil, false
	}
	return transmute([]byte)res.body, true
}

// AES-128-CTR over the whole file, counter starting at zero, then drop the
// Spotify header so what's left is a plain Ogg stream.
decrypt_audio_file :: proc(data: []byte, key: [16]byte) -> []byte {
	ctx: aes.Context_CTR
	key := key
	iv := AUDIO_AES_IV
	aes.init_ctr(&ctx, key[:], iv[:])
	defer aes.reset_ctr(&ctx)

	aes.xor_bytes_ctr(&ctx, data, data)

	if len(data) <= SPOTIFY_OGG_HEADER_END do return data[:0]
	return data[SPOTIFY_OGG_HEADER_END:]
}

Decoded_Audio :: struct {
	samples:     []i16, // interleaved
	channels:    int,
	sample_rate: int,
}

decode_ogg :: proc(ogg: []byte) -> (audio: Decoded_Audio, ok: bool) {
	channels, sample_rate: i32
	output: [^]i16

	count := vorbis.decode_memory(raw_data(ogg), i32(len(ogg)), &channels, &sample_rate, &output)
	if count <= 0 || output == nil {
		fmt.eprintln("Ogg Vorbis decode failed")
		return {}, false
	}
	// stb_vorbis allocates with malloc, so the buffer has to go back to libc,
	// not to Odin's allocator. Copy it out and free it here.
	defer libc.free(output)

	total := int(count) * int(channels)
	audio.channels = int(channels)
	audio.sample_rate = int(sample_rate)
	audio.samples = make([]i16, total)
	copy(audio.samples, output[:total])
	return audio, true
}

// A plain 16-bit PCM WAV, so the result can be checked with any tool.
write_wav :: proc(path: string, audio: Decoded_Audio) -> bool {
	data_bytes := len(audio.samples) * 2
	header: [44]byte
	put_str :: proc(b: []byte, s: string) {copy(b, transmute([]byte)s)}
	put_u32 :: proc(b: []byte, v: u32) {
		b[0] = byte(v);b[1] = byte(v >> 8);b[2] = byte(v >> 16);b[3] = byte(v >> 24)
	}
	put_u16 :: proc(b: []byte, v: u16) {b[0] = byte(v);b[1] = byte(v >> 8)}

	put_str(header[0:], "RIFF")
	put_u32(header[4:], u32(36 + data_bytes))
	put_str(header[8:], "WAVEfmt ")
	put_u32(header[16:], 16)
	put_u16(header[20:], 1) // PCM
	put_u16(header[22:], u16(audio.channels))
	put_u32(header[24:], u32(audio.sample_rate))
	put_u32(header[28:], u32(audio.sample_rate * audio.channels * 2))
	put_u16(header[32:], u16(audio.channels * 2))
	put_u16(header[34:], 16)
	put_str(header[36:], "data")
	put_u32(header[40:], u32(data_bytes))

	out := make([]byte, 44 + data_bytes)
	defer delete(out)
	copy(out, header[:])
	copy(out[44:], (cast([^]byte)raw_data(audio.samples))[:data_bytes])

	return os_write_file(path, out)
}
