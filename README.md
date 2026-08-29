# spoticyclint

A Spotify remote in Odin: loads your liked songs, shuffles them so the same
artist doesn't clump, and plays them on whichever Spotify device you already
have open — from a CLI or from a Wayland window rendered with Vulkan.

It is a *controller*, not a player. Odin can't decode Spotify streams (that
needs their proprietary client), so this drives the Spotify app on your phone,
desktop or speaker through the Web API. Playback control needs **Premium**.

## Build

```sh
./build.sh          # or: odin build src -out:spoticyclint
odin test src       # shuffle tests
```

Links against `libcurl` (TLS), `libwayland-client`, `libvulkan` and Odin's
vendored `stb_truetype`/`stb_image`. Everything else — the Wayland protocol
bindings, the UI, the renderer — is in this repo. No GLFW, no SDL, no Dear
ImGui, no C build step.

`build.sh` regenerates the protocol bindings and recompiles the shaders when
`python3` and `glslc` are present; both outputs are committed, so neither is
needed for a plain build.

## Setup

1. Create an app at <https://developer.spotify.com/dashboard>.
2. Add `http://127.0.0.1:8888/callback` as a redirect URI.
3. Give spoticyclint the client ID:

```sh
export SPOTIFY_CLIENT_ID=<your client id>
# or:  echo <your client id> > ~/.config/spoticyclint/client_id
```

There is no client secret — auth is the PKCE flow, and tokens land in
`~/.config/spoticyclint/token.json`, refreshed automatically.

## Use

```sh
./spoticyclint                    # the window, if a compositor is running
./spoticyclint ui                 # ... explicitly
./spoticyclint play               # headless: shuffle and play in the terminal
./spoticyclint play --repeat      # reshuffle and keep going forever
./spoticyclint --device phone     # pick a device by name
./spoticyclint play --limit 500   # only the 500 most recently liked
./spoticyclint play --dry-run     # print the order, don't touch playback
./spoticyclint devices
./spoticyclint ap-login           # inspect the native session and a track
./spoticyclint logout             # also clears the cached library
```

In the window: the queue is a grid of album covers — click one to play it,
click the bar to seek, scroll with the wheel, drag the volume slider. Space toggles play, left/right skip,
up/down change volume, `r` reshuffles, `q`/Escape quits.

Playback is native — the window decodes and plays audio itself, so no Spotify
client has to be running anywhere.

## What "smart shuffle" means here

Spotify's `/me/player/play` takes a fixed list, and a uniform permutation of a
few thousand liked songs puts the same artist back to back far more often than
it feels like it should.

Instead, each artist's tracks are laid out *evenly* across the whole queue: an
artist with `k` tracks in a library of `n` gets slots roughly `n/k` apart, with
a random offset and jitter so the result differs every run. Within an artist the
order is a plain Fisher–Yates shuffle.

This is not Spotify's own "Smart Shuffle" feature, which injects
recommendations you haven't saved. This only ever plays your own liked songs.

## The window

**Wayland, spoken directly.** `tools/wl_gen.py` turns `wayland.xml`,
`xdg-shell.xml` and `xdg-decoration-unstable-v1.xml` into
`src/wayland/protocol.odin` — the `wl_interface`/`wl_message` dispatch tables,
typed request wrappers and listener structs that libwayland-client needs. It is
the Odin equivalent of what `wayland-scanner` emits for C; all 185 generated
message signatures match `wayland-scanner private-code` byte for byte. The only
hand-written part is `src/wayland/client.odin`, ~60 lines of `wl_proxy_*` and
`wl_display_*` bindings. Server-side decorations are requested, so there's no
client-side title bar to draw. HiDPI comes from `wl_surface.preferred_buffer_scale`:
the UI is laid out in logical units and the scale is folded into the vertex
shader's push constant, so no layout code knows about it.

**Bindless Vulkan.** One descriptor set holds every texture the UI can draw —
the two glyph atlases, a 1×1 white pixel, and album art as it arrives — in a
single `sampler2D textures[]` declared with `runtimeDescriptorArray`,
`descriptorBindingPartiallyBound` and `descriptorBindingSampledImageUpdateAfterBind`.
A glyph, a panel and an album cover differ only by an integer in the vertex
data, so the set is bound once per frame and never rebound; art can be written
into the table while that set is in use. The whole UI is one pipeline and
usually one `vkCmdDrawIndexed` — extra draws only appear where a scissor
changes. Dynamic rendering means there are no render pass or framebuffer objects
to keep in sync with the swapchain, and `VK_KHR_synchronization2` barriers move
each swapchain image between layouts.

**One shader pair.** `ui.vert`/`ui.frag` handle solid fills, rounded panels,
circles, text and images. Rounded corners are a signed-distance mask over the
quad rather than generated geometry, so a pill button and a rectangle cost the
same four vertices. Single-channel glyph textures get a `.rgb = 1, .a = R`
component swizzle on the image view, which is why coverage and colour images can
share one fragment path.

**Immediate mode.** No widget tree and nothing retained between frames except
two `u64` ids: what the pointer is over, and what it grabbed. Every frame
rebuilds the vertex buffer from scratch into persistently mapped host-visible
memory. The whole UI core is `src/ui.odin`.

**Threading.** All Spotify calls happen on one worker thread behind a mutex, so
a slow API response can't drop a frame. Album art is fetched and decoded there
too; only the GPU upload happens on the render thread.

## Native playback

spoticyclint plays audio itself. It speaks Spotify's access-point protocol
directly — the same protocol [librespot](https://github.com/librespot-org/librespot)
and [psst](https://github.com/jpochyla/psst) implement — so no Spotify client
has to be running. It is a port, not a guess: the sources it was translated from
are vendored under `reference/` so the port can be audited line by line.

```sh
./spoticyclint fetch --track spotify:track:3eQS0faku2vB0dP8WTne9v
./spoticyclint fetch --dry-run --track ...   # write track.wav instead of playing
```

The whole chain, in Odin:

1. **Handshake** — 768-bit Diffie-Hellman over `core:math/big`, RSA-2048 PKCS#1
   v1.5 verification of the server's key (hand-written: `core:crypto` has no
   RSA), a five-block HMAC-SHA1 key schedule.
2. **Shannon cipher** (`src/shannon.odin`) — per-packet encryption and MAC.
   Verified against the reference implementation with 36 generated vectors
   (`src/shannon_test.odin`).
3. **Login** — `AUTHENTICATION_SPOTIFY_TOKEN` with an OAuth access token.
4. **Mercury** — `hm://metadata/3/track/<gid>` for the file ids.
5. **Audio key** — one per file, over the authenticated session.
6. **storage-resolve** — spclient hands back CDN mirrors for the file.
7. **Decrypt** — AES-128-CTR (`core:crypto/aes`) with Spotify's fixed IV, then
   skip the 0xa7-byte header to leave a plain Ogg stream.
8. **Decode and play** — `vendor:stb/vorbis` to samples, then straight to ALSA
   (`src/alsa.odin` is a hand-written `libasound` binding; a writer thread does
   blocking `snd_pcm_writei` and recovers from underruns after a pause or seek).

Region-restricted tracks are handled: Spotify refuses an audio key for the
original recording and lists playable `alternative` recordings instead, each
with its own gid, so the player falls through to those rather than skipping the
song.

Two things that cost real time, in case they help someone else:

- **Two client IDs, not one.** The access point only entitles a session to
  metadata and audio keys if the token came from Spotify's own web-player
  client. But api.spotify.com quotas are per client ID and that one is shared
  by everyone, so routing library calls through it gets you rate-limited into
  the ground. Web API traffic uses this app's own ID; the session uses
  Spotify's. psst splits them the same way.
- **Spotify's base62 alphabet is digits, then lowercase, then uppercase.** Get
  the case order backwards and 22 characters still decode into a
  plausible-looking 16-byte gid — and metadata simply answers 404.

Playback needs Premium, and a third-party client is against Spotify's terms of
service.

## Loading the library

Reading 4000 liked songs is 80 API pages. The first page reports the total and
the rest are fetched by a pool of 8 threads, which takes a cold start from about
a minute to **3.9s** here. The result is then cached to
`~/.cache/spoticyclint/liked.json`; on the next run one cheap request confirms
the song count still matches and startup is **0.4s**. If the count has changed
the cache is dropped and refetched, and `logout` clears it.

A library edited to the same size (one song added, one removed) won't be
noticed until the count next changes.

## How playback keeps going

The play endpoint accepts at most 100 URIs, so the queue is sent in chunks of
100. spoticyclint watches the player and pushes the next chunk about 8 seconds
before the last track of the current one ends.

## Layout

| file | what's in it |
| --- | --- |
| `src/main.odin` | CLI, device selection, the headless playback loop |
| `src/app.odin` | the window's screen, and the worker thread behind it |
| `src/ui.odin` | immediate-mode core: draw list, ids, widgets, animation |
| `src/window.odin` | Wayland window, xdg-shell, pointer and keyboard |
| `src/gpu.odin` | Vulkan instance, device, swapchain, per-frame state |
| `src/gpu_bindless.odin` | the descriptor array and texture uploads |
| `src/gpu_ui.odin` | UI pipeline and frame submission |
| `src/font.odin` | stb_truetype glyph atlas |
| `src/shaders/` | `ui.vert`, `ui.frag`, and their compiled SPIR-V |
| `src/wayland/` | `client.odin` (hand-written), `protocol.odin` (generated) |
| `src/auth.odin` | PKCE login, loopback callback listener, token storage |
| `src/api.odin` | Spotify Web API calls, parallel library fetch |
| `src/cache.odin` | on-disk liked-songs cache |
| `src/shuffle.odin` | the artist-spreading shuffle |
| `src/audio_file.odin` | CDN fetch, AES-CTR decrypt, Vorbis decode |
| `src/audio_out.odin` | ALSA output thread, gain, seek |
| `src/alsa.odin` | libasound bindings |
| `src/player.odin` | the native player: session, queue, decode |
| `src/shannon.odin` | Shannon stream cipher (AP packet crypto) |
| `src/spotify_ap.odin` | access-point handshake and login |
| `src/protobuf.odin` | minimal protobuf for the AP schemas |
| `reference/` | the librespot/shannon sources the port came from |
| `src/http.odin` | libcurl wrapper, retries on 429/5xx |
| `tools/wl_gen.py` | Wayland XML → Odin bindings |

## Known limits

- Keyboard input is raw evdev keycodes; there is no xkb translation, so there's
  no text entry (and so no search box yet).
- Fractional scaling is not handled — only integer `preferred_buffer_scale`.
- The glyph atlas covers printable ASCII, so non-Latin track names render as
  `?`.
