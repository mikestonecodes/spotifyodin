package spoticyclint

// The Shannon stream cipher (Hawkes & Rose), which Spotify's access points use
// to encrypt and authenticate every packet after the handshake. Ported from
// reference/shannon/shannon.rs — see reference/NOTICE.md.
//
// It is a 16-word non-linear feedback register that produces a keystream and
// accumulates a MAC over the plaintext at the same time, so encryption and
// authentication are one pass.

import "core:encoding/endian"

SHN_N :: 16
SHN_FOLD :: SHN_N
SHN_INITKONST :: u32(0x6996c53a)
SHN_KEYP :: 13

Shannon :: struct {
	r:     [SHN_N]u32,
	crc:   [SHN_N]u32,
	init_r: [SHN_N]u32,
	konst: u32,
	sbuf:  u32,
	mbuf:  u32,
	nbuf:  int,
}

@(private = "file")
rotl :: proc "contextless" (w: u32, x: u32) -> u32 {
	return (w << x) | (w >> (32 - x))
}

@(private = "file")
sbox1 :: proc "contextless" (w: u32) -> u32 {
	w := w
	w ~= rotl(w, 5) | rotl(w, 7)
	w ~= rotl(w, 19) | rotl(w, 22)
	return w
}

@(private = "file")
sbox2 :: proc "contextless" (w: u32) -> u32 {
	w := w
	w ~= rotl(w, 7) | rotl(w, 22)
	w ~= rotl(w, 5) | rotl(w, 19)
	return w
}

shannon_init :: proc(c: ^Shannon, key: []byte) {
	// Register seeded with Fibonacci numbers, counter zeroed.
	c^ = Shannon {
		konst = SHN_INITKONST,
	}
	c.r[0] = 1
	c.r[1] = 1
	for i in 2 ..< SHN_N do c.r[i] = c.r[i - 1] + c.r[i - 2]

	shannon_loadkey(c, key)
	c.konst = c.r[0]
	c.init_r = c.r
}

// Re-keys for one packet. The AP numbers packets from zero in each direction.
shannon_nonce_u32 :: proc(c: ^Shannon, n: u32) {
	nonce: [4]byte
	endian.put_u32(nonce[:], .Big, n)
	shannon_nonce(c, nonce[:])
}

shannon_nonce :: proc(c: ^Shannon, nonce: []byte) {
	c.r = c.init_r
	c.konst = SHN_INITKONST
	shannon_loadkey(c, nonce)
	c.konst = c.r[0]
	c.nbuf = 0
}

@(private = "file")
shannon_cycle :: proc "contextless" (c: ^Shannon) {
	// Non-linear feedback.
	t := c.r[12] ~ c.r[13] ~ c.konst
	t = sbox1(t) ~ rotl(c.r[0], 1)

	for i in 1 ..< SHN_N do c.r[i - 1] = c.r[i]
	c.r[SHN_N - 1] = t

	t = sbox2(c.r[2] ~ c.r[15])
	c.r[0] ~= t
	c.sbuf = t ~ c.r[8] ~ c.r[12]
}

@(private = "file")
shannon_diffuse :: proc "contextless" (c: ^Shannon) {
	for _ in 0 ..< SHN_FOLD do shannon_cycle(c)
}

// Folds key or nonce material into the register. Also seeds the CRC, which is
// what makes key loading irreversible.
@(private = "file")
shannon_loadkey :: proc(c: ^Shannon, key: []byte) {
	i := 0
	for ; i + 4 <= len(key); i += 4 {
		c.r[SHN_KEYP] ~= u32le(key[i:i + 4])
		shannon_cycle(c)
	}
	if i < len(key) {
		xtra: [4]byte
		copy(xtra[:], key[i:])
		c.r[SHN_KEYP] ~= u32le(xtra[:])
		shannon_cycle(c)
	}

	c.r[SHN_KEYP] ~= u32(len(key))
	shannon_cycle(c)

	c.crc = c.r
	shannon_diffuse(c)
	for i in 0 ..< SHN_N do c.r[i] ~= c.crc[i]
}

// 32 parallel CRC-16s over the plaintext, later folded into the MAC.
@(private = "file")
shannon_crcfunc :: proc "contextless" (c: ^Shannon, i: u32) {
	t := c.crc[0] ~ c.crc[2] ~ c.crc[15] ~ i
	for j in 1 ..< SHN_N do c.crc[j - 1] = c.crc[j]
	c.crc[SHN_N - 1] = t
}

@(private = "file")
shannon_macfunc :: proc "contextless" (c: ^Shannon, i: u32) {
	shannon_crcfunc(c, i)
	c.r[SHN_KEYP] ~= i
}

@(private = "file")
shannon_partial :: proc "contextless" (c: ^Shannon, b: ^byte, encrypting: bool) {
	shift := u32(32 - c.nbuf)
	if encrypting {
		c.mbuf ~= u32(b^) << shift
		b^ ~= byte((c.sbuf >> shift) & 0xff)
	} else {
		b^ ~= byte((c.sbuf >> shift) & 0xff)
		c.mbuf ~= u32(b^) << shift
	}
}

@(private = "file")
shannon_process :: proc(c: ^Shannon, buf: []byte, encrypting: bool) {
	i := 0

	// Bytes left over from a previous call that didn't end on a word.
	if c.nbuf != 0 {
		for c.nbuf > 0 {
			if i >= len(buf) do return
			shannon_partial(c, &buf[i], encrypting)
			i += 1
			c.nbuf -= 8
			shannon_macfunc(c, c.mbuf)
		}
	}

	rest := buf[i:]
	whole := len(rest) &~ 3

	for j := 0; j < whole; j += 4 {
		shannon_cycle(c)
		t := u32le(rest[j:j + 4])
		if encrypting {
			shannon_macfunc(c, t)
			t ~= c.sbuf
		} else {
			t ~= c.sbuf
			shannon_macfunc(c, t)
		}
		put_u32le(rest[j:j + 4], t)
	}

	extra := rest[whole:]
	if len(extra) > 0 {
		shannon_cycle(c)
		c.mbuf = 0
		c.nbuf = 32
		for k in 0 ..< len(extra) {
			shannon_partial(c, &extra[k], encrypting)
			c.nbuf -= 8
		}
	}
}

shannon_encrypt :: proc(c: ^Shannon, buf: []byte) {
	shannon_process(c, buf, true)
}

shannon_decrypt :: proc(c: ^Shannon, buf: []byte) {
	shannon_process(c, buf, false)
}

// Finishes the MAC for this packet and writes it out. Trailing bytes count as
// encrypted zeroes, and the end of input is marked in a way plaintext can't
// reproduce, which is what stops extension attacks.
shannon_finish :: proc(c: ^Shannon, buf: []byte) {
	if c.nbuf != 0 {
		shannon_macfunc(c, c.mbuf)
	}

	shannon_cycle(c)
	c.r[SHN_KEYP] ~= SHN_INITKONST ~ (u32(c.nbuf) << 3)
	c.nbuf = 0

	for i in 0 ..< SHN_N do c.r[i] ~= c.crc[i]
	shannon_diffuse(c)

	for j := 0; j < len(buf); j += 4 {
		shannon_cycle(c)
		if j + 4 <= len(buf) {
			put_u32le(buf[j:j + 4], c.sbuf)
		} else {
			for k in 0 ..< len(buf) - j {
				buf[j + k] = byte((c.sbuf >> u32(8 * k)) & 0xff)
			}
		}
	}
}

@(private = "file")
u32le :: proc "contextless" (b: []byte) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private = "file")
put_u32le :: proc "contextless" (b: []byte, v: u32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}
