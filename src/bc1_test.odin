package spoticyclint

import "core:math"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"

@(private = "file")
psnr :: proc(a, b: []byte) -> f64 {
	sum: f64
	n := 0
	for i := 0; i < len(a); i += 4 {
		for ch in 0 ..< 3 {
			d := f64(a[i + ch]) - f64(b[i + ch])
			sum += d * d
			n += 1
		}
	}
	mse := sum / f64(n)
	if mse == 0 do return 99
	return 10 * math.log10(255 * 255 / mse)
}

@(test)
test_bc1_keeps_flat_blocks_exact :: proc(t: ^testing.T) {
	// A block of one color has to survive: the endpoints land on it and every
	// index reads it back. Only the 565 rounding is allowed to move it.
	src := make([]byte, 8 * 8 * 4)
	defer delete(src)
	for i := 0; i < len(src); i += 4 {
		src[i], src[i + 1], src[i + 2], src[i + 3] = 66, 132, 198, 255
	}

	blocks := bc1_encode(src, 8, 8)
	defer delete(blocks)
	testing.expect_value(t, len(blocks), bc1_size(8, 8))

	out := bc1_decode(blocks, 8, 8)
	defer delete(out)
	for i := 0; i < len(out); i += 4 {
		testing.expect(t, abs(int(out[i]) - 66) <= 4, "red drifted")
		testing.expect(t, abs(int(out[i + 1]) - 132) <= 2, "green drifted")
		testing.expect(t, abs(int(out[i + 2]) - 198) <= 4, "blue drifted")
		testing.expect_value(t, out[i + 3], 255)
	}
}

@(test)
test_bc1_holds_up_on_a_gradient :: proc(t: ^testing.T) {
	// The hard case for four colors a block: a smooth ramp in two directions.
	// Album art is gentler than this, so this is a floor, not a typical score.
	W :: 64
	src := make([]byte, W * W * 4)
	defer delete(src)
	for y in 0 ..< W {
		for x in 0 ..< W {
			o := (y * W + x) * 4
			src[o] = byte(x * 4)
			src[o + 1] = byte(y * 4)
			src[o + 2] = byte((x + y) * 2)
			src[o + 3] = 255
		}
	}

	blocks := bc1_encode(src, W, W)
	defer delete(blocks)
	out := bc1_decode(blocks, W, W)
	defer delete(out)

	q := psnr(src, out)
	testing.expectf(t, q > 34, "gradient came back at %.1f dB, expected better than 34", q)
}

@(test)
test_bc1_size_is_half_a_byte_a_pixel :: proc(t: ^testing.T) {
	testing.expect_value(t, bc1_size(224, 224), 224 * 224 / 2)
	testing.expect(t, bc1_fits(224, 224), "224 is a whole number of blocks")
	testing.expect(t, !bc1_fits(199, 224), "199 is not")
	testing.expect(t, !bc1_fits(0, 0), "nothing is not a texture")
}

@(test)
test_art_blocks_round_trip :: proc(t: ^testing.T) {
	dir := "/tmp/spoticyclint-test-cache"
	old := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
	os.set_env("XDG_CACHE_HOME", dir)
	defer os.set_env("XDG_CACHE_HOME", old)
	defer os.remove(fmt.tprintf("%s/spoticyclint/art", dir))

	url := "https://i.scdn.co/image/ab67616d00001e02deadbeef"
	src := make([]byte, 8 * 8 * 4)
	defer delete(src)
	for i := 0; i < len(src); i += 4 {
		src[i], src[i + 1], src[i + 2], src[i + 3] = byte(i), 40, 200, 255
	}
	blocks := bc1_encode(src, 8, 8)
	defer delete(blocks)

	save_art_blocks(url, 8, blocks, 8, 8)
	file, back, w, h, ok := load_art_blocks(url, 8)
	defer delete(file)
	testing.expect(t, ok, "the cover did not come back")
	testing.expect_value(t, w, 8)
	testing.expect_value(t, h, 8)
	testing.expect_value(t, len(back), len(blocks))
	testing.expect(t, mem.compare(back, blocks) == 0, "the blocks came back changed")

	// A different size is a different file, not a wrong-sized one.
	_, _, _, _, other := load_art_blocks(url, 224)
	testing.expect(t, !other, "the 224px cover should not be the 8px one")
}
