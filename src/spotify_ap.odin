package spoticyclint

// The Spotify access-point session: the handshake that gets us an encrypted,
// authenticated channel, and the login that turns an OAuth access token into a
// logged-in session. Ported from reference/librespot/handshake.rs, codec.rs,
// mod.rs and diffie_hellman.rs — see reference/NOTICE.md.

import "core:bytes"
import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:math/big"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

SPOTIFY_VERSION :: 124200290

// Packet types, from reference/librespot/mod.rs and core/src/packet.rs.
PACKET_LOGIN :: 0xab
PACKET_AP_WELCOME :: 0xac
PACKET_AUTH_FAILURE :: 0xad
PACKET_PING :: 0x04
PACKET_PONG :: 0x49

// Spotify's RSA-2048 public key. The access point signs its DH public key with
// it, which is what stops anyone sitting in the middle of the handshake.
AP_SERVER_KEY := [256]byte{
	0xac, 0xe0, 0x46, 0x0b, 0xff, 0xc2, 0x30, 0xaf, 0xf4, 0x6b, 0xfe, 0xc3,
	0xbf, 0xbf, 0x86, 0x3d, 0xa1, 0x91, 0xc6, 0xcc, 0x33, 0x6c, 0x93, 0xa1,
	0x4f, 0xb3, 0xb0, 0x16, 0x12, 0xac, 0xac, 0x6a, 0xf1, 0x80, 0xe7, 0xf6,
	0x14, 0xd9, 0x42, 0x9d, 0xbe, 0x2e, 0x34, 0x66, 0x43, 0xe3, 0x62, 0xd2,
	0x32, 0x7a, 0x1a, 0x0d, 0x92, 0x3b, 0xae, 0xdd, 0x14, 0x02, 0xb1, 0x81,
	0x55, 0x05, 0x61, 0x04, 0xd5, 0x2c, 0x96, 0xa4, 0x4c, 0x1e, 0xcc, 0x02,
	0x4a, 0xd4, 0xb2, 0x0c, 0x00, 0x1f, 0x17, 0xed, 0xc2, 0x2f, 0xc4, 0x35,
	0x21, 0xc8, 0xf0, 0xcb, 0xae, 0xd2, 0xad, 0xd7, 0x2b, 0x0f, 0x9d, 0xb3,
	0xc5, 0x32, 0x1a, 0x2a, 0xfe, 0x59, 0xf3, 0x5a, 0x0d, 0xac, 0x68, 0xf1,
	0xfa, 0x62, 0x1e, 0xfb, 0x2c, 0x8d, 0x0c, 0xb7, 0x39, 0x2d, 0x92, 0x47,
	0xe3, 0xd7, 0x35, 0x1a, 0x6d, 0xbd, 0x24, 0xc2, 0xae, 0x25, 0x5b, 0x88,
	0xff, 0xab, 0x73, 0x29, 0x8a, 0x0b, 0xcc, 0xcd, 0x0c, 0x58, 0x67, 0x31,
	0x89, 0xe8, 0xbd, 0x34, 0x80, 0x78, 0x4a, 0x5f, 0xc9, 0x6b, 0x89, 0x9d,
	0x95, 0x6b, 0xfc, 0x86, 0xd7, 0x4f, 0x33, 0xa6, 0x78, 0x17, 0x96, 0xc9,
	0xc3, 0x2d, 0x0d, 0x32, 0xa5, 0xab, 0xcd, 0x05, 0x27, 0xe2, 0xf7, 0x10,
	0xa3, 0x96, 0x13, 0xc4, 0x2f, 0x99, 0xc0, 0x27, 0xbf, 0xed, 0x04, 0x9c,
	0x3c, 0x27, 0x58, 0x04, 0xb6, 0xb2, 0x19, 0xf9, 0xc1, 0x2f, 0x02, 0xe9,
	0x48, 0x63, 0xec, 0xa1, 0xb6, 0x42, 0xa0, 0x9d, 0x48, 0x25, 0xf8, 0xb3,
	0x9d, 0xd0, 0xe8, 0x6a, 0xf9, 0x48, 0x4d, 0xa1, 0xc2, 0xba, 0x86, 0x30,
	0x42, 0xea, 0x9d, 0xb3, 0x08, 0x6c, 0x19, 0x0e, 0x48, 0xb3, 0x9d, 0x66,
	0xeb, 0x00, 0x06, 0xa2, 0x5a, 0xee, 0xa1, 0x1b, 0x13, 0x87, 0x3c, 0xd7,
	0x19, 0xe6, 0x55, 0xbd,
}

DH_PRIME := [96]byte{
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xc9, 0x0f, 0xda, 0xa2,
	0x21, 0x68, 0xc2, 0x34, 0xc4, 0xc6, 0x62, 0x8b, 0x80, 0xdc, 0x1c, 0xd1,
	0x29, 0x02, 0x4e, 0x08, 0x8a, 0x67, 0xcc, 0x74, 0x02, 0x0b, 0xbe, 0xa6,
	0x3b, 0x13, 0x9b, 0x22, 0x51, 0x4a, 0x08, 0x79, 0x8e, 0x34, 0x04, 0xdd,
	0xef, 0x95, 0x19, 0xb3, 0xcd, 0x3a, 0x43, 0x1b, 0x30, 0x2b, 0x0a, 0x6d,
	0xf2, 0x5f, 0x14, 0x37, 0x4f, 0xe1, 0x35, 0x6d, 0x6d, 0x51, 0xc2, 0x45,
	0xe4, 0x85, 0xb5, 0x76, 0x62, 0x5e, 0x7e, 0xc6, 0xf4, 0x4c, 0x42, 0xe9,
	0xa6, 0x3a, 0x36, 0x20, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
}

DH_GENERATOR :: 2

AP_Session :: struct {
	socket:      net.TCP_Socket,
	send_cipher: Shannon,
	recv_cipher: Shannon,
	send_nonce:  u32,
	recv_nonce:  u32,
	username:    string,
	mercury_seq: u64,
	key_seq:     u32,

	// Spotify throttles audio key requests per session. Cache what we get,
	// pace what we ask for, and back off when refused.
	key_cache:   map[string][16]byte,
	last_key:    time.Time,
	refusals:    int,
	connected:   bool,
}

Access_Point :: struct {
	host: string,
	port: int,
}

// Asks Spotify which access points to use. It returns several, and individual
// ones do refuse connections, so keep the whole list and work down it.
ap_resolve :: proc() -> (points: [dynamic]Access_Point) {
	res, ok := http_request("GET", "https://apresolve.spotify.com/?type=accesspoint", nil)
	defer delete(res.body)

	if ok && res.status == 200 {
		v, err := json.parse_string(res.body)
		if err == nil {
			defer json.destroy_value(v)
			for entry in jarr(v, "accesspoint") {
				text, is_str := entry.(json.String)
				if !is_str do continue
				colon := strings.last_index(string(text), ":")
				if colon < 0 do continue
				port, port_ok := strconv.parse_int(string(text)[colon + 1:])
				if !port_ok do continue
				append(&points, Access_Point{strings.clone(string(text)[:colon]), port})
			}
		}
	}
	if len(points) == 0 {
		append(&points, Access_Point{strings.clone("ap-gew1.spotify.com"), 4070})
		append(&points, Access_Point{strings.clone("ap-gew4.spotify.com"), 443})
	}
	return points
}

ap_connect :: proc(access_token: string, device_id: string) -> (s: ^AP_Session, ok: bool) {
	points := ap_resolve()
	defer {
		for p in points do delete(p.host)
		delete(points)
	}

	last_error: string
	for point in points {
		endpoint, resolve_err := net.resolve_ip4(fmt.tprintf("%s:%d", point.host, point.port))
		if resolve_err != nil {
			last_error = fmt.tprintf("%s: %v", point.host, resolve_err)
			continue
		}

		socket, dial_err := net.dial_tcp_from_endpoint(endpoint)
		if dial_err != nil {
			last_error = fmt.tprintf("%s:%d: %v", point.host, point.port, dial_err)
			continue
		}

		// Without a timeout, an access point that stops talking without
		// closing the connection parks the worker inside recv() for ever,
		// holding the socket lock — every skip and every preload queues up
		// behind it and the app is simply dead until it is restarted.
		io_timeout := AP_IO_TIMEOUT
		_ = net.set_option(socket, .Receive_Timeout, io_timeout)
		_ = net.set_option(socket, .Send_Timeout, io_timeout)

		session := new(AP_Session)
		session.socket = socket
		if !ap_handshake(session) {
			net.close(socket)
			free(session)
			last_error = fmt.tprintf("%s: handshake failed", point.host)
			continue
		}
		if !ap_login(session, access_token, device_id) {
			net.close(socket)
			free(session)
			// A rejected login will be rejected everywhere, so stop here.
			return nil, false
		}
		session.connected = true
		return session, true
	}

	fmt.eprintfln("no access point would take the connection (last: %s)", last_error)
	return nil, false
}

ap_close :: proc(s: ^AP_Session) {
	if s == nil do return
	net.close(s.socket)
	delete(s.username)
	for k in s.key_cache do delete(k)
	delete(s.key_cache)
	free(s)
}

// Rebuilds a dropped session in the same allocation. In place matters: the
// preloader holds this very pointer, so handing back a new session would leave
// it talking to a closed socket.
ap_reconnect :: proc(s: ^AP_Session, access_token: string, device_id: string) -> bool {
	if s == nil do return false
	net.close(s.socket)
	s.connected = false

	fresh, ok := ap_connect(access_token, device_id)
	if !ok do return false

	// Keep the audio keys. They do not belong to the connection, and every one
	// of them is a request we do not have to make again on a session that has
	// already shown it can be throttled.
	keys := s.key_cache
	s.key_cache = nil
	delete(s.username)

	s^ = fresh^
	delete(s.key_cache)
	s.key_cache = keys
	free(fresh)
	return true
}

// ---------------------------------------------------------------- handshake

@(private = "file")
ap_handshake :: proc(s: ^AP_Session) -> bool {
	// Our Diffie-Hellman keypair. The private exponent is 95 random bytes read
	// little-endian, matching librespot so the key sizes line up.
	private_bytes: [95]byte
	crypto.rand_bytes(private_bytes[:])

	priv, pub, prime: big.Int
	defer big.destroy(&priv, &pub, &prime)

	reverse_bytes(private_bytes[:])
	if big.int_from_bytes_big(&priv, private_bytes[:]) != nil do return false
	if big.int_from_bytes_big(&prime, DH_PRIME[:]) != nil do return false

	gen: big.Int
	defer big.destroy(&gen)
	if big.set(&gen, DH_GENERATOR) != nil do return false
	if big.internal_int_power_modulo(&pub, &gen, &priv, &prime) != nil do return false

	gc := int_to_bytes(&pub) or_return
	defer delete(gc)

	// The accumulator is every handshake byte, in order, both directions: it is
	// what the session keys are derived over.
	accumulator: [dynamic]byte
	defer delete(accumulator)

	hello := build_client_hello(gc)
	defer delete(hello)
	append(&accumulator, ..hello)
	if !send_all(s.socket, hello) do return false

	// Response: 4-byte big-endian length covering the length field itself.
	size_buf: [4]byte
	if ok, _ := recv_exact(s.socket, size_buf[:]); !ok do return false
	append(&accumulator, ..size_buf[:])

	size, _ := endian.get_u32(size_buf[:], .Big)
	if size < 4 || size > 1 << 20 do return false

	response := make([]byte, int(size) - 4)
	defer delete(response)
	if ok, _ := recv_exact(s.socket, response); !ok do return false
	append(&accumulator, ..response)

	// APResponseMessage.challenge.login_crypto_challenge.diffie_hellman
	dh_challenge, found := pb_path(response, 10, 10, 10)
	if !found {
		fmt.eprintln("access point did not offer a Diffie-Hellman challenge")
		return false
	}
	gs := pb_find(dh_challenge, 10) or_return
	gs_signature := pb_find(dh_challenge, 30) or_return

	if !verify_server_key(gs, gs_signature) {
		fmt.eprintln("access point signature did not verify - refusing to continue")
		return false
	}

	remote, shared: big.Int
	defer big.destroy(&remote, &shared)
	if big.int_from_bytes_big(&remote, gs) != nil do return false
	if big.internal_int_power_modulo(&shared, &remote, &priv, &prime) != nil do return false

	shared_secret := int_to_bytes(&shared) or_return
	defer delete(shared_secret)

	challenge, send_key, recv_key := compute_keys(shared_secret, accumulator[:])
	defer delete(challenge)

	shannon_init(&s.send_cipher, send_key[:])
	shannon_init(&s.recv_cipher, recv_key[:])

	client_response := build_client_response(challenge)
	defer delete(client_response)
	return send_all(s.socket, client_response)
}

// Five HMAC-SHA1 blocks over the handshake transcript: the first becomes the
// key for the challenge, the next two are the send and receive keys.
@(private = "file")
compute_keys :: proc(
	shared_secret: []byte,
	packets: []byte,
) -> (
	challenge: []byte,
	send_key: [32]byte,
	recv_key: [32]byte,
) {
	data: [100]byte

	msg := make([]byte, len(packets) + 1, context.temp_allocator)
	copy(msg, packets)

	for i in 1 ..= 5 {
		msg[len(packets)] = byte(i)
		hmac.sum(.Insecure_SHA1, data[(i - 1) * 20:i * 20], msg, shared_secret)
	}

	challenge = make([]byte, 20)
	hmac.sum(.Insecure_SHA1, challenge, packets, data[:20])

	copy(send_key[:], data[0x14:0x34])
	copy(recv_key[:], data[0x34:0x54])
	return
}

// RSASSA-PKCS1-v1_5 with SHA-1, verified by hand: core:crypto has no RSA, but
// with a big-int modexp the check is just s^e mod n and an unpad.
@(private = "file")
verify_server_key :: proc(message, signature: []byte) -> bool {
	if len(signature) != 256 do return false

	n, sig, e, m: big.Int
	defer big.destroy(&n, &sig, &e, &m)
	if big.int_from_bytes_big(&n, AP_SERVER_KEY[:]) != nil do return false
	if big.int_from_bytes_big(&sig, signature) != nil do return false
	if big.set(&e, 65537) != nil do return false
	if big.internal_int_power_modulo(&m, &sig, &e, &n) != nil do return false

	raw, raw_ok := int_to_bytes(&m)
	if !raw_ok do return false
	defer delete(raw)

	// Left-pad back to the modulus width; int_to_bytes drops leading zeroes.
	em: [256]byte
	if len(raw) > 256 do return false
	copy(em[256 - len(raw):], raw)

	// EM = 0x00 || 0x01 || 0xFF... || 0x00 || DigestInfo(SHA-1) || hash
	SHA1_DIGEST_INFO := [?]byte {
		0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e,
		0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
	}
	if em[0] != 0x00 || em[1] != 0x01 do return false

	i := 2
	for i < len(em) && em[i] == 0xff do i += 1
	if i < 10 || i >= len(em) || em[i] != 0x00 do return false
	i += 1

	tail := em[i:]
	if len(tail) != len(SHA1_DIGEST_INFO) + 20 do return false
	if !bytes.equal(tail[:len(SHA1_DIGEST_INFO)], SHA1_DIGEST_INFO[:]) do return false

	digest: [20]byte
	hash.hash_bytes_to_buffer(.Insecure_SHA1, message, digest[:])
	return bytes.equal(tail[len(SHA1_DIGEST_INFO):], digest[:])
}

@(private = "file")
build_client_hello :: proc(gc: []byte) -> []byte {
	build_info: Pb
	defer pb_destroy(&build_info)
	pb_varint(&build_info, 10, 0) // product = PRODUCT_CLIENT
	pb_varint(&build_info, 20, 0) // product_flags = PRODUCT_FLAG_NONE
	pb_varint(&build_info, 30, 8) // platform = PLATFORM_LINUX_X86_64
	pb_varint(&build_info, 40, SPOTIFY_VERSION)

	dh: Pb
	defer pb_destroy(&dh)
	pb_blob(&dh, 10, gc)
	pb_varint(&dh, 20, 1) // server_keys_known

	crypto_hello: Pb
	defer pb_destroy(&crypto_hello)
	pb_sub(&crypto_hello, 10, &dh)

	nonce: [16]byte
	crypto.rand_bytes(nonce[:])

	hello: Pb
	defer pb_destroy(&hello)
	pb_sub(&hello, 10, &build_info)
	pb_varint(&hello, 30, 0) // cryptosuites_supported = CRYPTO_SUITE_SHANNON
	pb_sub(&hello, 50, &crypto_hello)
	pb_blob(&hello, 60, nonce[:])
	pb_blob(&hello, 70, {0x1e}) // padding

	body := pb_bytes(&hello)
	out := make([]byte, 6 + len(body))
	out[0] = 0x00
	out[1] = 0x04
	endian.put_u32(out[2:6], .Big, u32(6 + len(body)))
	copy(out[6:], body)
	return out
}

@(private = "file")
build_client_response :: proc(challenge: []byte) -> []byte {
	dh: Pb
	defer pb_destroy(&dh)
	pb_blob(&dh, 10, challenge)

	crypto_response: Pb
	defer pb_destroy(&crypto_response)
	pb_sub(&crypto_response, 10, &dh)

	empty: Pb
	defer pb_destroy(&empty)

	packet: Pb
	defer pb_destroy(&packet)
	pb_sub(&packet, 10, &crypto_response)
	pb_sub(&packet, 20, &empty) // pow_response
	pb_sub(&packet, 30, &empty) // crypto_response

	body := pb_bytes(&packet)
	out := make([]byte, 4 + len(body))
	endian.put_u32(out[0:4], .Big, u32(4 + len(body)))
	copy(out[4:], body)
	return out
}

// -------------------------------------------------------------------- login

@(private = "file")
ap_login :: proc(s: ^AP_Session, access_token: string, device_id: string) -> bool {
	credentials: Pb
	defer pb_destroy(&credentials)
	pb_varint(&credentials, 20, 3) // AUTHENTICATION_SPOTIFY_TOKEN
	pb_str(&credentials, 30, access_token)

	system_info: Pb
	defer pb_destroy(&system_info)
	pb_varint(&system_info, 10, 8) // cpu_family = CPU_X86_64
	pb_varint(&system_info, 60, 0) // os = OS_LINUX
	pb_str(&system_info, 90, "spoticyclint")
	pb_str(&system_info, 100, device_id)

	packet: Pb
	defer pb_destroy(&packet)
	pb_sub(&packet, 10, &credentials)
	pb_sub(&packet, 50, &system_info)
	pb_str(&packet, 70, "spoticyclint 0.1")

	if !ap_send(s, PACKET_LOGIN, pb_bytes(&packet)) do return false

	for {
		cmd, payload, ok := ap_recv(s)
		if !ok do return false
		defer delete(payload)

		switch cmd {
		case PACKET_AP_WELCOME:
			if name, found := pb_find(payload, 10); found {
				s.username = strings.clone(string(name))
				save_username(s.username)
			}
			return true
		case PACKET_AUTH_FAILURE:
			code, _ := pb_find_varint(payload, 10)
			fmt.eprintfln("access point rejected login: %s", ap_login_error(int(code)))
			return false
		case PACKET_PING:
			ap_send(s, PACKET_PONG, payload)
		case:
		// Anything else before the welcome is noise; keep reading.
		}
	}
}

ap_login_error :: proc(code: int) -> string {
	switch code {
	case 0:
		return "protocol error"
	case 2:
		return "try another access point"
	case 5:
		return "bad connection id"
	case 9:
		return "travel restriction"
	case 11:
		return "Premium account required"
	case 12:
		return "bad credentials"
	case 13:
		return "could not validate credentials"
	case 14:
		return "account exists"
	case 15:
		return "extra verification required"
	case 16:
		return "invalid app key"
	case 17:
		return "application banned"
	}
	return fmt.tprintf("error code %d", code)
}

// -------------------------------------------------------------------- codec

// Each packet is [cmd][u16 length][payload] encrypted under a per-packet nonce
// that is simply the packet counter, followed by a 4-byte MAC.
// How long a single packet may take before the connection counts as gone, and
// how long the keepalive poll waits to find out that nothing is pending.
AP_IO_TIMEOUT: time.Duration : 15 * time.Second
AP_POLL_TIMEOUT: time.Duration : 20 * time.Millisecond

ap_send :: proc(s: ^AP_Session, cmd: byte, payload: []byte) -> bool {
	frame := make([]byte, 3 + len(payload) + 4, context.temp_allocator)
	frame[0] = cmd
	endian.put_u16(frame[1:3], .Big, u16(len(payload)))
	copy(frame[3:], payload)

	shannon_nonce_u32(&s.send_cipher, s.send_nonce)
	s.send_nonce += 1

	shannon_encrypt(&s.send_cipher, frame[:3 + len(payload)])
	shannon_finish(&s.send_cipher, frame[3 + len(payload):])
	if !send_all(s.socket, frame) {
		s.connected = false
		return false
	}
	return true
}

ap_recv :: proc(s: ^AP_Session) -> (cmd: byte, payload: []byte, ok: bool) {
	c, data, state := ap_recv_packet(s, wait = true)
	return c, data, state == .Packet
}

Recv_State :: enum {
	Packet, // one decoded packet
	Idle, // nothing pending; only possible when not waiting
	Dead, // the connection is gone
}

// The one place packets are decoded. `wait` false makes it a poll: it looks
// for a packet already on the wire and reports .Idle rather than blocking.
@(private = "file")
ap_recv_packet :: proc(s: ^AP_Session, wait: bool) -> (cmd: byte, payload: []byte, state: Recv_State) {
	header: [3]byte

	// Peek before touching the cipher. Setting the nonce is destructive, and a
	// poll that finds nothing must leave the stream exactly as it was so the
	// next real read still decodes.
	if !wait {
		poll := AP_POLL_TIMEOUT
		_ = net.set_option(s.socket, .Receive_Timeout, poll)
	}
	got, idle := recv_exact(s.socket, header[:])
	if !wait {
		io_timeout := AP_IO_TIMEOUT
		_ = net.set_option(s.socket, .Receive_Timeout, io_timeout)
	}
	if !got {
		if idle && !wait do return 0, nil, .Idle
		s.connected = false
		return 0, nil, .Dead
	}

	shannon_nonce_u32(&s.recv_cipher, s.recv_nonce)
	s.recv_nonce += 1
	shannon_decrypt(&s.recv_cipher, header[:])

	cmd = header[0]
	size, _ := endian.get_u16(header[1:3], .Big)

	body := make([]byte, int(size) + 4)
	if body_ok, _ := recv_exact(s.socket, body); !body_ok {
		delete(body)
		s.connected = false
		return 0, nil, .Dead
	}
	shannon_decrypt(&s.recv_cipher, body[:size])

	expected: [4]byte
	shannon_finish(&s.recv_cipher, expected[:])
	if !bytes.equal(expected[:], body[size:]) {
		delete(body)
		fmt.eprintln("access point packet failed its MAC check")
		// The keystream is past the point of recovery, so nothing that follows
		// will decode either. Say so, and let the caller build a new session.
		s.connected = false
		return 0, nil, .Dead
	}

	payload = make([]byte, int(size))
	copy(payload, body[:size])
	delete(body)
	return cmd, payload, .Packet
}

// Reads whatever the access point has sent us unprompted — in practice its
// keepalive ping, which it expects answered within a minute or so. Nothing
// else here touches the socket between requests, so on a long track the pings
// pile up unanswered, the access point hangs up, and every load from then on
// fails against a socket nobody ever rebuilds. That is the hang that a restart
// "fixed". Returns false once the connection is gone.
ap_pump :: proc(s: ^AP_Session) -> bool {
	if s == nil || !s.connected do return false
	for {
		cmd, payload, state := ap_recv_packet(s, wait = false)
		switch state {
		case .Idle:
			return true
		case .Dead:
			return false
		case .Packet:
			if cmd == PACKET_PING do ap_send(s, PACKET_PONG, payload)
			delete(payload)
		}
	}
}

// ------------------------------------------------------------------- plumbing

@(private = "file")
send_all :: proc(socket: net.TCP_Socket, data: []byte) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(socket, data[sent:])
		if err != nil || n <= 0 do return false
		sent += n
	}
	return true
}

// Reads exactly len(buf) bytes. `idle` separates "the peer has not sent
// anything yet" from a broken connection, which is what lets the keepalive
// poll ask without committing: once a single byte has arrived we are mid
// packet and have to see it through, timeout or not, or the stream desyncs.
@(private = "file")
recv_exact :: proc(socket: net.TCP_Socket, buf: []byte) -> (ok: bool, idle: bool) {
	deadline := time.time_add(time.now(), AP_IO_TIMEOUT)
	got := 0
	for got < len(buf) {
		n, err := net.recv_tcp(socket, buf[got:])
		if err == .Timeout || err == .Would_Block || err == .Interrupted {
			if got == 0 && err != .Interrupted do return false, true
			if time.since(deadline) > 0 do return false, false
			continue
		}
		if err != nil || n <= 0 do return false, false
		got += n
	}
	return true, false
}

@(private = "file")
int_to_bytes :: proc(v: ^big.Int) -> (out: []byte, ok: bool) {
	size, err := big.int_to_bytes_size(v)
	if err != nil do return nil, false
	buf := make([]byte, size)
	if big.int_to_bytes_big(v, buf) != nil {
		delete(buf)
		return nil, false
	}
	return buf, true
}

@(private = "file")
reverse_bytes :: proc(b: []byte) {
	for i in 0 ..< len(b) / 2 {
		b[i], b[len(b) - 1 - i] = b[len(b) - 1 - i], b[i]
	}
}

// ------------------------------------------------------------------ mercury

// Mercury is the access point's request/response channel: a small framing over
// AP packets carrying a protobuf header plus payload parts. It is how we get a
// session token and track metadata, neither of which the Web API exposes.
PACKET_MERCURY_REQ :: 0xb2

KEYMASTER_CLIENT_ID :: "65b708073fc0480ea92a077233ca87bd"

Mercury_Response :: struct {
	status_code: int,
	parts:       [][]byte,
}

mercury_response_destroy :: proc(r: Mercury_Response) {
	for p in r.parts do delete(p)
	delete(r.parts)
}

ap_mercury_get :: proc(s: ^AP_Session, uri: string) -> (resp: Mercury_Response, ok: bool) {
	if !s.connected do return {}, false

	header: Pb
	defer pb_destroy(&header)
	pb_str(&header, 1, uri)
	pb_str(&header, 3, "GET")

	head := pb_bytes(&header)
	seq := s.mercury_seq
	s.mercury_seq += 1

	req: [dynamic]byte
	defer delete(req)
	append_u16(&req, 8) // sequence length
	append_u64(&req, seq)
	append(&req, 1) // flags: FINAL
	append_u16(&req, 1) // part count: header only
	append_u16(&req, u16(len(head)))
	append(&req, ..head)

	if !ap_send(s, PACKET_MERCURY_REQ, req[:]) do return {}, false

	parts: [dynamic][]byte
	for {
		cmd, payload, recv_ok := ap_recv(s)
		if !recv_ok {
			for p in parts do delete(p)
			delete(parts)
			return {}, false
		}

		if cmd == PACKET_PING {
			ap_send(s, PACKET_PONG, payload)
			delete(payload)
			continue
		}
		if cmd != PACKET_MERCURY_REQ {
			delete(payload) // country code, product info and friends
			continue
		}
		defer delete(payload)

		r := Pb_Reader{data = payload}
		seq_len := int(read_u16(&r))
		got_seq := u64(0)
		for _ in 0 ..< seq_len {
			got_seq = got_seq << 8 | u64(read_u8(&r))
		}
		flags := read_u8(&r)
		count := int(read_u16(&r))

		for _ in 0 ..< count {
			n := int(read_u16(&r))
			if r.pos + n > len(r.data) do break
			part := make([]byte, n)
			copy(part, r.data[r.pos:r.pos + n])
			r.pos += n
			append(&parts, part)
		}

		if got_seq != seq do continue
		if flags != 1 do continue // more packets to come

		resp.parts = parts[:]
		if len(resp.parts) > 0 {
			// Header.status_code is a sint32, so zigzag encoded.
			if raw, found := pb_find_varint(resp.parts[0], 4); found {
				resp.status_code = int(i64(raw >> 1) ~ -i64(raw & 1))
			}
		}
		return resp, true
	}
}

// Trades the AP session for a Spotify-issued access token. spclient rejects
// our own OAuth token ("RBAC: access denied") but accepts this one.
ap_session_token :: proc(
	s: ^AP_Session,
	device_id: string,
	scopes: string,
	client_id: string = KEYMASTER_CLIENT_ID,
) -> (string, bool) {
	uri := fmt.tprintf(
		"hm://keymaster/token/authenticated?scope=%s&client_id=%s&device_id=%s",
		scopes,
		client_id,
		device_id,
	)
	resp, ok := ap_mercury_get(s, uri)
	if !ok do return "", false
	defer mercury_response_destroy(resp)

	if resp.status_code != 200 || len(resp.parts) < 2 {
		return "", false
	}

	v, err := json.parse_string(string(resp.parts[1]))
	if err != nil do return "", false
	defer json.destroy_value(v)

	token := jstr(v, "accessToken")
	if token == "" do return "", false
	return strings.clone(token), true
}

Audio_File :: struct {
	file_id: []byte,
	format:  int,
	gid:     []byte, // the track this file belongs to
}

Track_Files :: struct {
	files: [dynamic]Audio_File, // primary first, then alternatives
}

track_files_destroy :: proc(tf: ^Track_Files) {
	for f in tf.files {
		delete(f.file_id)
		delete(f.gid)
	}
	delete(tf.files)
}

// hm://metadata/4/track/<gid> returns the Track protobuf, whose `file` entries
// carry the file ids the audio-key and storage endpoints need.
// Collects the playable files for a track, including its alternatives.
// Spotify lists a different recording under `alternative` when the original is
// not licensed in your country, and refuses an audio key for the original —
// so a client that ignores alternatives silently skips a lot of music.
ap_track_files :: proc(s: ^AP_Session, gid: []byte) -> (files: [dynamic]Audio_File, ok: bool) {
	// Version 3, not 4: Spotify answers 404 on /4/ now. psst uses /3/.
	uri := fmt.tprintf("hm://metadata/3/track/%s", to_hex_string(gid, context.temp_allocator))
	resp, req_ok := ap_mercury_get(s, uri)
	if !req_ok do return files, false
	defer mercury_response_destroy(resp)

	if resp.status_code != 200 || len(resp.parts) < 2 {
		fmt.eprintfln("metadata request failed (status %d)", resp.status_code)
		return files, false
	}

	// Track.file is field 12, repeated, so walk the message ourselves.
	track := resp.parts[1]
	r := Pb_Reader{data = track}
	for r.pos < len(r.data) {
		tag, tag_ok := pb_read_uvarint(&r)
		if !tag_ok do break
		field := u32(tag >> 3)
		wire := u32(tag & 7)

		if wire == WIRE_LEN {
			n, n_ok := pb_read_uvarint(&r)
			if !n_ok || r.pos + int(n) > len(r.data) do break
			chunk := r.data[r.pos:r.pos + int(n)]
			r.pos += int(n)

			switch field {
			case 12:
				collect_audio_file(&files, chunk, gid)
			case 13:
				// An alternative is a whole Track message: its own gid and its
				// own files, which is what the audio key must be requested for.
				alt_gid, has_gid := pb_find(chunk, 1)
				if !has_gid do break
				alt := Pb_Reader{data = chunk}
				for alt.pos < len(alt.data) {
					atag, atag_ok := pb_read_uvarint(&alt)
					if !atag_ok do break
					afield := u32(atag >> 3)
					awire := u32(atag & 7)
					if awire == WIRE_LEN {
						an, an_ok := pb_read_uvarint(&alt)
						if !an_ok || alt.pos + int(an) > len(alt.data) do break
						achunk := alt.data[alt.pos:alt.pos + int(an)]
						alt.pos += int(an)
						if afield == 12 do collect_audio_file(&files, achunk, alt_gid)
					} else if awire == WIRE_VARINT {
						pb_read_uvarint(&alt) or_break
					} else if awire == 5 {
						alt.pos += 4
					} else if awire == 1 {
						alt.pos += 8
					} else {
						break
					}
				}
			}
		} else if wire == WIRE_VARINT {
			pb_read_uvarint(&r) or_break
		} else if wire == 5 {
			r.pos += 4
		} else if wire == 1 {
			r.pos += 8
		} else {
			break
		}
	}
	return files, true
}

@(private = "file")
collect_audio_file :: proc(files: ^[dynamic]Audio_File, chunk: []byte, gid: []byte) {
	id, has_id := pb_find(chunk, 1)
	if !has_id do return
	format, _ := pb_find_varint(chunk, 2)

	copy_id := make([]byte, len(id))
	copy(copy_id, id)
	copy_gid := make([]byte, len(gid))
	copy(copy_gid, gid)
	append(files, Audio_File{file_id = copy_id, format = int(format), gid = copy_gid})
}

audio_format_name :: proc(format: int) -> string {
	switch format {
	case 0:
		return "OGG_VORBIS_96"
	case 1:
		return "OGG_VORBIS_160"
	case 2:
		return "OGG_VORBIS_320"
	case 3:
		return "MP3_256"
	case 4:
		return "MP3_320"
	case 5:
		return "MP3_160"
	case 16:
		return "FLAC"
	}
	return fmt.tprintf("format %d", format)
}

@(private = "file")
append_u16 :: proc(b: ^[dynamic]byte, v: u16) {
	append(b, byte(v >> 8), byte(v))
}

@(private = "file")
append_u64 :: proc(b: ^[dynamic]byte, v: u64) {
	for i := 7; i >= 0; i -= 1 do append(b, byte(v >> uint(i * 8)))
}

@(private = "file")
read_u8 :: proc(r: ^Pb_Reader) -> byte {
	if r.pos >= len(r.data) do return 0
	v := r.data[r.pos]
	r.pos += 1
	return v
}

@(private = "file")
read_u16 :: proc(r: ^Pb_Reader) -> u16 {
	return u16(read_u8(r)) << 8 | u16(read_u8(r))
}

// Spotify ids are base62 over this alphabet; the wire wants the raw 16 bytes.
// Note the ordering: digits, then LOWERCASE, then uppercase. Getting this
// backwards still decodes 22 characters into a plausible-looking 16 bytes, and
// the metadata service simply answers 404.
BASE62 :: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

track_gid :: proc(uri: string) -> (gid: []byte, ok: bool) {
	id := uri
	if colon := strings.last_index(uri, ":"); colon >= 0 do id = uri[colon + 1:]
	if len(id) != 22 do return nil, false

	n: big.Int
	base, digit: big.Int
	defer big.destroy(&n, &base, &digit)
	if big.set(&base, 62) != nil do return nil, false

	for ch in id {
		index := strings.index_rune(BASE62, ch)
		if index < 0 do return nil, false
		if big.mul(&n, &n, &base) != nil do return nil, false
		if big.set(&digit, index) != nil do return nil, false
		if big.add(&n, &n, &digit) != nil do return nil, false
	}

	raw, raw_ok := int_to_bytes_public(&n)
	if !raw_ok do return nil, false
	defer delete(raw)
	if len(raw) > 16 do return nil, false

	out := make([]byte, 16)
	copy(out[16 - len(raw):], raw)
	return out, true
}

@(private = "file")
int_to_bytes_public :: proc(v: ^big.Int) -> (out: []byte, ok: bool) {
	size, err := big.int_to_bytes_size(v)
	if err != nil do return nil, false
	buf := make([]byte, size)
	if big.int_to_bytes_big(v, buf) != nil {
		delete(buf)
		return nil, false
	}
	return buf, true
}

// ---------------------------------------------------------------- audio key

PACKET_REQUEST_KEY :: 0x0c
PACKET_AES_KEY :: 0x0d
PACKET_AES_KEY_ERROR :: 0x0e

// The per-file AES key. Spotify hands these out only over an authenticated
// session, one file at a time.
// Minimum spacing between key requests, and the extra wait added per refusal.
KEY_MIN_INTERVAL :: 400 * time.Millisecond
KEY_BACKOFF_STEP :: 400 * time.Millisecond
KEY_BACKOFF_MAX :: 4 * time.Second
// Idle time after which the accumulated backoff is forgotten.
KEY_BACKOFF_RESET :: 30 * time.Second

// How long to wait before the next key request. The caller does the waiting,
// because it holds the socket lock and sleeping under it would stall anything
// the user asked for behind a preload that happens to be backing off.
ap_key_wait :: proc(s: ^AP_Session) -> time.Duration {
	// A quiet stretch is the throttling clearing itself: keep the backoff from
	// outliving the burst that earned it, or one bad minute of skipping makes
	// every later request slow.
	if s.refusals > 0 && time.since(s.last_key) > KEY_BACKOFF_RESET do s.refusals = 0

	wait := KEY_MIN_INTERVAL
	if s.refusals > 0 {
		wait += min(KEY_BACKOFF_STEP * time.Duration(s.refusals), KEY_BACKOFF_MAX)
	}
	elapsed := time.since(s.last_key)
	return elapsed < wait ? wait - elapsed : 0
}

// `transient` marks a refusal that is about us asking too much rather than the
// recording being unavailable — those clear on their own, and trying the
// track's alternatives only makes the throttling worse.
ap_audio_key :: proc(
	s: ^AP_Session,
	gid: []byte,
	file_id: []byte,
) -> (
	key: [16]byte,
	ok: bool,
	transient: bool,
) {
	if len(gid) != 16 || len(file_id) != 20 do return key, false, false

	// Keys do not change, so a track played twice costs one request.
	cache_key := to_hex_string(file_id, context.temp_allocator)
	if cached, hit := s.key_cache[cache_key]; hit do return cached, true, false

	// A dead session refuses everything, and that is not the track's fault.
	if !s.connected do return key, false, true

	s.last_key = time.now()

	seq := s.key_seq
	s.key_seq += 1

	req: [dynamic]byte
	defer delete(req)
	append(&req, ..file_id)
	append(&req, ..gid)
	append(&req, byte(seq >> 24), byte(seq >> 16), byte(seq >> 8), byte(seq))
	append(&req, 0x00, 0x00)

	if !ap_send(s, PACKET_REQUEST_KEY, req[:]) do return key, false, true

	for {
		cmd, payload, recv_ok := ap_recv(s)
		if !recv_ok do return key, false, true

		switch cmd {
		case PACKET_AES_KEY:
			defer delete(payload)
			if len(payload) < 20 do return key, false, false
			copy(key[:], payload[4:20])
			s.refusals = 0
			s.key_cache[strings.clone(cache_key)] = key
			return key, true, false
		case PACKET_AES_KEY_ERROR:
			defer delete(payload)
			code := len(payload) >= 6 ? int(payload[4]) << 8 | int(payload[5]) : -1
			// Only throttling should widen the backoff. A track that simply
			// is not available to us says nothing about how fast we are
			// asking, and letting it slow every later request would punish
			// the whole queue for one bad song.
			if code == 2 do s.refusals += 1
			// Code 2 shows up on tracks that play fine moments later, so treat
			// it as "slow down" rather than "unavailable". Neither case is
			// reported here: the caller retries transient refusals and falls
			// through to alternative recordings on hard ones, so a refusal is
			// only news if the track ends up unplayable.
			transient = code == 2
			return key, false, transient
		case PACKET_PING:
			ap_send(s, PACKET_PONG, payload)
			delete(payload)
		case:
			delete(payload)
		}
	}
}
