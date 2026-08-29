package spoticyclint

// Just enough protobuf for the access-point handshake and login: varints,
// length-delimited fields, and nested lookup. The Spotify schemas we touch use
// only these two wire types, so a full protobuf implementation would be dead
// weight. Schemas live in reference/librespot/*.proto.

WIRE_VARINT :: 0
WIRE_LEN :: 2

Pb :: struct {
	buf: [dynamic]byte,
}

pb_destroy :: proc(w: ^Pb) {
	delete(w.buf)
}

pb_bytes :: proc(w: ^Pb) -> []byte {
	return w.buf[:]
}

@(private = "file")
pb_uvarint :: proc(w: ^Pb, value: u64) {
	v := value
	for {
		b := byte(v & 0x7f)
		v >>= 7
		if v != 0 do b |= 0x80
		append(&w.buf, b)
		if v == 0 do break
	}
}

@(private = "file")
pb_tag :: proc(w: ^Pb, field: u32, wire: u32) {
	pb_uvarint(w, u64(field) << 3 | u64(wire))
}

pb_varint :: proc(w: ^Pb, field: u32, value: u64) {
	pb_tag(w, field, WIRE_VARINT)
	pb_uvarint(w, value)
}

pb_blob :: proc(w: ^Pb, field: u32, data: []byte) {
	pb_tag(w, field, WIRE_LEN)
	pb_uvarint(w, u64(len(data)))
	append(&w.buf, ..data)
}

pb_str :: proc(w: ^Pb, field: u32, s: string) {
	pb_blob(w, field, transmute([]byte)s)
}

// Nests one message inside another. `sub` is consumed by the caller as usual.
pb_sub :: proc(w: ^Pb, field: u32, sub: ^Pb) {
	pb_blob(w, field, sub.buf[:])
}

// ------------------------------------------------------------------ reading

Pb_Reader :: struct {
	data: []byte,
	pos:  int,
}

pb_read_uvarint :: proc(r: ^Pb_Reader) -> (value: u64, ok: bool) {
	shift: uint
	for r.pos < len(r.data) {
		b := r.data[r.pos]
		r.pos += 1
		value |= u64(b & 0x7f) << shift
		if b & 0x80 == 0 do return value, true
		shift += 7
		if shift > 63 do return 0, false
	}
	return 0, false
}

// Walks a message looking for `field`, returning its raw bytes. Repeated
// fields yield the first match, which is all these schemas need.
pb_find :: proc(data: []byte, field: u32) -> (value: []byte, ok: bool) {
	r := Pb_Reader{data = data}
	for r.pos < len(r.data) {
		tag := pb_read_uvarint(&r) or_return
		f := u32(tag >> 3)
		wire := u32(tag & 7)

		switch wire {
		case WIRE_LEN:
			n := pb_read_uvarint(&r) or_return
			if r.pos + int(n) > len(r.data) do return nil, false
			chunk := r.data[r.pos:r.pos + int(n)]
			r.pos += int(n)
			if f == field do return chunk, true
		case WIRE_VARINT:
			start := r.pos - varint_size(tag)
			_ = start
			v := pb_read_uvarint(&r) or_return
			if f == field {
				// Hand back a view the caller can decode with pb_find_varint.
				_ = v
				return nil, false
			}
		case 5:
			r.pos += 4
		case 1:
			r.pos += 8
		case:
			return nil, false
		}
	}
	return nil, false
}

pb_find_varint :: proc(data: []byte, field: u32) -> (value: u64, ok: bool) {
	r := Pb_Reader{data = data}
	for r.pos < len(r.data) {
		tag := pb_read_uvarint(&r) or_return
		f := u32(tag >> 3)
		wire := u32(tag & 7)

		switch wire {
		case WIRE_VARINT:
			v := pb_read_uvarint(&r) or_return
			if f == field do return v, true
		case WIRE_LEN:
			n := pb_read_uvarint(&r) or_return
			if r.pos + int(n) > len(r.data) do return 0, false
			r.pos += int(n)
		case 5:
			r.pos += 4
		case 1:
			r.pos += 8
		case:
			return 0, false
		}
	}
	return 0, false
}

// Follows a chain of nested message fields, e.g. challenge -> crypto -> gs.
pb_path :: proc(data: []byte, fields: ..u32) -> (value: []byte, ok: bool) {
	cur := data
	for f in fields {
		cur = pb_find(cur, f) or_return
	}
	return cur, true
}

@(private = "file")
varint_size :: proc(v: u64) -> int {
	n := 1
	x := v >> 7
	for x != 0 {
		n += 1
		x >>= 7
	}
	return n
}

to_hex_string :: proc(b: []byte, allocator := context.allocator) -> string {
	HEX := "0123456789abcdef"
	out := make([]byte, len(b) * 2, allocator)
	for v, i in b {
		out[i * 2] = HEX[v >> 4]
		out[i * 2 + 1] = HEX[v & 0xf]
	}
	return string(out)
}
