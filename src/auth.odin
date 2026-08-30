package spoticyclint

import "core:c/libc"
import "core:crypto"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

REDIRECT_PORT :: 8888
REDIRECT_URI :: "http://127.0.0.1:8888/callback"
SESSION_REDIRECT_URI :: "http://127.0.0.1:8888/login"
SCOPES :: "user-library-read user-read-playback-state user-modify-playback-state"
// The access point only grants metadata and audio keys to a session whose
// token carries these.
SESSION_SCOPES :: "streaming user-read-email user-read-private user-library-read playlist-read-private user-follow-read user-top-read user-read-recently-played"
ACCOUNTS :: "https://accounts.spotify.com"

Tokens :: struct {
	access_token:  string,
	refresh_token: string,
	expires_at:    i64,
}

config_dir :: proc() -> string {
	if xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); xdg != "" {
		return fmt.aprintf("%s/spoticyclint", xdg)
	}
	home := os.get_env("HOME", context.temp_allocator)
	return fmt.aprintf("%s/.config/spoticyclint", home)
}

token_path :: proc(kind := Token_Kind.Web_API) -> string {
	name := kind == .Session ? "session_token.json" : "token.json"
	return fmt.aprintf("%s/%s", config_dir(), name)
}

@(private = "file")
token_settings :: proc(kind: Token_Kind) -> (id, scopes, redirect: string) {
	if kind == .Session {
		return SESSION_CLIENT_ID, SESSION_SCOPES, SESSION_REDIRECT_URI
	}
	app_id, _ := client_id()
	return app_id, SCOPES, REDIRECT_URI
}

// Two client IDs, on purpose — psst does the same thing.
//
// The access point only entitles a session to metadata and audio keys if the
// token came from Spotify's own web-player client, so the native player has to
// present that one. But api.spotify.com quotas are per client ID, and that
// web-player ID is shared by everyone: routing library calls through it gets
// you rate-limited into the ground. So Web API traffic uses our own app ID,
// which has its own clean quota.
//
// Client IDs are not secrets; they travel in every authorise URL.
DEFAULT_CLIENT_ID :: "049f911dd7d7420da7fe29d73320aa94"
SESSION_CLIENT_ID :: "65b708073fc0480ea92a077233ca87bd"

Token_Kind :: enum {
	Web_API, // library, devices, transport
	Session, // the access point: metadata, audio keys, playback
}

client_id :: proc() -> (string, bool) {
	if id := os.get_env("SPOTIFY_CLIENT_ID", context.allocator); id != "" {
		return id, true
	}
	path := fmt.aprintf("%s/client_id", config_dir())
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err == nil {
		if id := strings.trim_space(string(data)); id != "" do return id, true
	}
	return DEFAULT_CLIENT_ID, true
}

b64url :: proc(data: []byte) -> string {
	s := base64.encode(data, base64.ENC_URL_TABLE)
	return strings.trim_right(s, "=")
}

save_tokens :: proc(t: Tokens, kind := Token_Kind.Web_API) {
	dir := config_dir()
	os.make_directory_all(dir)
	data, err := json.marshal(t, {pretty = true})
	if err != nil {
		fmt.eprintln("failed to serialise tokens:", err)
		return
	}
	_ = os.write_entire_file(token_path(kind), data)
}

load_tokens :: proc(kind := Token_Kind.Web_API) -> (t: Tokens, ok: bool) {
	data, err := os.read_entire_file_from_path(token_path(kind), context.allocator)
	if err != nil do return {}, false
	if json.unmarshal(data, &t) != nil do return {}, false
	return t, t.access_token != ""
}

tokens_destroy :: proc(t: Tokens) {
	delete(t.access_token)
	delete(t.refresh_token)
}

// True when the stored token for `kind` is at or near expiry. Spotify tokens
// last about an hour; nothing tells a long-running session that its own has
// run out, the endpoints just start answering 403, so ask before using it.
token_expired :: proc(kind := Token_Kind.Web_API) -> bool {
	t, have := load_tokens(kind)
	if !have do return true
	defer tokens_destroy(t)
	return time.now()._nsec / 1e9 >= t.expires_at - 60
}

// Returns a valid access token, refreshing or running the login flow as needed.
get_access_token :: proc(kind := Token_Kind.Web_API) -> (token: string, ok: bool) {
	id, scopes, redirect := token_settings(kind)
	has_id := id != ""
	if !has_id {
		fmt.eprintln("No Spotify client ID.")
		fmt.eprintln("Create an app at https://developer.spotify.com/dashboard,")
		fmt.eprintfln("add %s as a redirect URI, then either:", REDIRECT_URI)
		fmt.eprintln("  export SPOTIFY_CLIENT_ID=<id>")
		fmt.eprintfln("  or write it to %s/client_id", config_dir())
		return "", false
	}

	t, have := load_tokens(kind)
	if have && time.now()._nsec / 1e9 < t.expires_at - 60 {
		return t.access_token, true
	}
	if have && t.refresh_token != "" {
		if nt, ok := refresh_tokens(id, t.refresh_token); ok {
			save_tokens(nt, kind)
			return nt.access_token, true
		}
	}
	nt, logged_in := login(id, scopes, redirect)
	if !logged_in do return "", false
	save_tokens(nt, kind)
	return nt.access_token, true
}

refresh_tokens :: proc(id: string, refresh_token: string) -> (Tokens, bool) {
	body := fmt.tprintf(
		"grant_type=refresh_token&refresh_token=%s&client_id=%s",
		url_encode(refresh_token, context.temp_allocator),
		url_encode(id, context.temp_allocator),
	)
	res, ok := http_request(
		"POST",
		ACCOUNTS + "/api/token",
		{"Content-Type: application/x-www-form-urlencoded"},
		body,
	)
	if !ok || res.status != 200 do return {}, false
	t := parse_token_response(res.body) or_else Tokens{}
	if t.access_token == "" do return {}, false
	if t.refresh_token == "" do t.refresh_token = strings.clone(refresh_token)
	return t, true
}

parse_token_response :: proc(body: string) -> (Tokens, bool) {
	v, err := json.parse_string(body)
	if err != nil do return {}, false
	defer json.destroy_value(v)

	access := jstr(v, "access_token")
	if access == "" do return {}, false
	return Tokens {
			access_token = strings.clone(access),
			refresh_token = strings.clone(jstr(v, "refresh_token")),
			expires_at = time.now()._nsec / 1e9 + i64(jnum(v, "expires_in")),
		},
		true
}

// Runs the PKCE authorisation-code flow with a one-shot loopback listener.
login :: proc(id: string, scopes: string, redirect: string) -> (Tokens, bool) {
	verifier_bytes: [64]byte
	crypto.rand_bytes(verifier_bytes[:])
	verifier := b64url(verifier_bytes[:])

	digest := hash.hash_string(hash.Algorithm.SHA256, verifier)
	challenge := b64url(digest)

	state_bytes: [16]byte
	crypto.rand_bytes(state_bytes[:])
	state := b64url(state_bytes[:])

	auth_url := fmt.tprintf(
		"%s/authorize?response_type=code&client_id=%s&scope=%s&redirect_uri=%s&code_challenge_method=S256&code_challenge=%s&state=%s",
		ACCOUNTS,
		url_encode(id, context.temp_allocator),
		url_encode(scopes, context.temp_allocator),
		url_encode(redirect, context.temp_allocator),
		challenge,
		state,
	)

	sock, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = REDIRECT_PORT})
	if lerr != nil {
		fmt.eprintfln("cannot listen on port %d: %v", REDIRECT_PORT, lerr)
		return {}, false
	}
	defer net.close(sock)

	fmt.println("Opening browser to authorise spoticyclint...")
	fmt.println("If it does not open, visit:\n", auth_url)
	open_browser(auth_url)

	code, got_code := wait_for_code(sock, state)
	if !got_code do return {}, false

	body := fmt.tprintf(
		"grant_type=authorization_code&code=%s&redirect_uri=%s&client_id=%s&code_verifier=%s",
		url_encode(code, context.temp_allocator),
		url_encode(redirect, context.temp_allocator),
		url_encode(id, context.temp_allocator),
		url_encode(verifier, context.temp_allocator),
	)
	res, ok := http_request(
		"POST",
		ACCOUNTS + "/api/token",
		{"Content-Type: application/x-www-form-urlencoded"},
		body,
	)
	if !ok || res.status != 200 {
		fmt.eprintln("token exchange failed:", res.status, res.body)
		return {}, false
	}
	return parse_token_response(res.body)
}

@(private = "file")
open_browser :: proc(url: string) {
	cmd := fmt.ctprintf("xdg-open '%s' >/dev/null 2>&1 &", url)
	libc.system(cmd)
}

@(private = "file")
PAGE :: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><body style=\"font-family:sans-serif;background:#121212;color:#1db954;display:flex;align-items:center;justify-content:center;height:100vh\"><h2>%s</h2></body></html>"

@(private = "file")
wait_for_code :: proc(sock: net.TCP_Socket, want_state: string) -> (string, bool) {
	buf: [8192]byte
	for {
		client, _, aerr := net.accept_tcp(sock)
		if aerr != nil do return "", false
		defer net.close(client)

		n, rerr := net.recv_tcp(client, buf[:])
		if rerr != nil || n == 0 do continue

		req := string(buf[:n])
		line_end := strings.index(req, "\r\n")
		if line_end < 0 do continue
		line := req[:line_end]

		// "GET /callback?code=...&state=... HTTP/1.1"
		parts := strings.split(line, " ", context.temp_allocator)
		if len(parts) < 2 do continue
		q := parts[1]
		qi := strings.index(q, "?")
		if qi < 0 {
			net.send_tcp(client, transmute([]byte)fmt.tprintf(PAGE, "Waiting..."))
			continue
		}

		code, state, err_desc: string
		for pair in strings.split(q[qi + 1:], "&", context.temp_allocator) {
			eq := strings.index(pair, "=")
			if eq < 0 do continue
			k, v := pair[:eq], pair[eq + 1:]
			switch k {
			case "code":
				code = v
			case "state":
				state = v
			case "error":
				err_desc = v
			}
		}

		if err_desc != "" {
			net.send_tcp(client, transmute([]byte)fmt.tprintf(PAGE, "Authorisation denied."))
			fmt.eprintln("authorisation denied:", err_desc)
			return "", false
		}
		if code == "" do continue
		if state != want_state {
			net.send_tcp(client, transmute([]byte)fmt.tprintf(PAGE, "State mismatch."))
			fmt.eprintln("state mismatch; aborting")
			return "", false
		}

		net.send_tcp(
			client,
			transmute([]byte)fmt.tprintf(PAGE, "Logged in. You can close this tab."),
		)
		return strings.clone(code), true
	}
}

// Keeps the cached library by default: it is derived data, not a credential,
// and dropping it turns the next start back into eighty API calls.
logout :: proc(forget_cache := false) {
	if forget_cache do forget_library()
	gone := os.remove(token_path(.Web_API)) == nil
	if os.remove(token_path(.Session)) == nil do gone = true
	fmt.println(gone ? "Logged out." : "Not logged in.")
}
