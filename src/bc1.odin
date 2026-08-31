package spoticyclint

// Covers are kept on disk in the form the GPU wants them: BC1 blocks. Decoding
// a JPEG and downscaling it costs about a millisecond each, which a screenful
// of tiles turns into a visible fill-in; a BC1 file is read and handed to the
// driver as-is, so a cover that has been seen once costs a 25KB read and a
// memcpy. It is also a sixth of the VRAM, which is what the bindless table is
// actually short of.
//
// The encode happens once, on the art thread, right after the download.

// Four bytes of endpoints and four of indices per 4x4 block: half a byte a
// pixel.
BC1_BLOCK :: 8

bc1_size :: proc(width, height: int) -> int {
	return ((width + 3) / 4) * ((height + 3) / 4) * BC1_BLOCK
}

// BC1 addresses whole 4x4 blocks, so anything else would need padding that the
// sampler would then have to be kept away from.
bc1_fits :: proc(width, height: int) -> bool {
	return width > 0 && height > 0 && width % 4 == 0 && height % 4 == 0
}

@(private = "file")
to_565 :: proc(r, g, b: int) -> u16 {
	return u16(((r * 31 + 127) / 255) << 11 | ((g * 63 + 127) / 255) << 5 | (b * 31 + 127) / 255)
}

@(private = "file")
from_565 :: proc(c: u16) -> (r, g, b: int) {
	r5 := int(c >> 11) & 31
	g6 := int(c >> 5) & 63
	b5 := int(c) & 31
	return r5 * 255 / 31, g6 * 255 / 63, b5 * 255 / 31
}

// Range fit: take the bounding box of the block's colors as the two endpoints
// and snap every pixel to the nearest of the four colors they span. It is the
// cheap end of BC1 encoding, and on album art — photographic, no hard edges
// inside a 4x4 block — it is hard to tell from the exact fit.
bc1_encode :: proc(rgba: []byte, width, height: int, allocator := context.allocator) -> []byte {
	out := make([]byte, bc1_size(width, height), allocator)
	at := 0

	for by := 0; by < height; by += 4 {
		for bx := 0; bx < width; bx += 4 {
			lo := [3]int{255, 255, 255}
			hi := [3]int{0, 0, 0}
			texel: [16][3]int
			for y in 0 ..< 4 {
				for x in 0 ..< 4 {
					o := ((by + y) * width + bx + x) * 4
					c := [3]int{int(rgba[o]), int(rgba[o + 1]), int(rgba[o + 2])}
					texel[y * 4 + x] = c
					for i in 0 ..< 3 {
						lo[i] = min(lo[i], c[i])
						hi[i] = max(hi[i], c[i])
					}
				}
			}

			c0 := to_565(hi[0], hi[1], hi[2])
			c1 := to_565(lo[0], lo[1], lo[2])
			// c0 > c1 selects the four-color block. Equal endpoints mean a
			// flat block, where every index reads back the same color anyway.
			if c0 < c1 do c0, c1 = c1, c0

			pal: [4][3]int
			pal[0][0], pal[0][1], pal[0][2] = from_565(c0)
			pal[1][0], pal[1][1], pal[1][2] = from_565(c1)
			for i in 0 ..< 3 {
				pal[2][i] = (2 * pal[0][i] + pal[1][i]) / 3
				pal[3][i] = (pal[0][i] + 2 * pal[1][i]) / 3
			}

			bits: u32
			for t in 0 ..< 16 {
				best, best_d := 0, max(int)
				for p in 0 ..< 4 {
					dr := texel[t][0] - pal[p][0]
					dg := texel[t][1] - pal[p][1]
					db := texel[t][2] - pal[p][2]
					d := dr * dr + dg * dg + db * db
					if d < best_d do best, best_d = p, d
				}
				bits |= u32(best) << uint(2 * t)
			}

			out[at] = byte(c0)
			out[at + 1] = byte(c0 >> 8)
			out[at + 2] = byte(c1)
			out[at + 3] = byte(c1 >> 8)
			out[at + 4] = byte(bits)
			out[at + 5] = byte(bits >> 8)
			out[at + 6] = byte(bits >> 16)
			out[at + 7] = byte(bits >> 24)
			at += BC1_BLOCK
		}
	}
	return out
}

// Only the tests need this — the GPU does it in the sampler — but an encoder
// nobody can check is an encoder nobody can trust.
bc1_decode :: proc(blocks: []byte, width, height: int, allocator := context.allocator) -> []byte {
	rgba := make([]byte, width * height * 4, allocator)
	at := 0
	for by := 0; by < height; by += 4 {
		for bx := 0; bx < width; bx += 4 {
			if at + BC1_BLOCK > len(blocks) do return rgba
			c0 := u16(blocks[at]) | u16(blocks[at + 1]) << 8
			c1 := u16(blocks[at + 2]) | u16(blocks[at + 3]) << 8
			bits :=
				u32(blocks[at + 4]) |
				u32(blocks[at + 5]) << 8 |
				u32(blocks[at + 6]) << 16 |
				u32(blocks[at + 7]) << 24
			at += BC1_BLOCK

			pal: [4][3]int
			pal[0][0], pal[0][1], pal[0][2] = from_565(c0)
			pal[1][0], pal[1][1], pal[1][2] = from_565(c1)
			for i in 0 ..< 3 {
				pal[2][i] = (2 * pal[0][i] + pal[1][i]) / 3
				pal[3][i] = (pal[0][i] + 2 * pal[1][i]) / 3
			}

			for y in 0 ..< 4 {
				for x in 0 ..< 4 {
					p := pal[(bits >> uint(2 * (y * 4 + x))) & 3]
					o := ((by + y) * width + bx + x) * 4
					rgba[o] = byte(p[0])
					rgba[o + 1] = byte(p[1])
					rgba[o + 2] = byte(p[2])
					rgba[o + 3] = 255
				}
			}
		}
	}
	return rgba
}
