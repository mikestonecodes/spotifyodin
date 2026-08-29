package spoticyclint

import "core:fmt"
import "core:os"
import tt "vendor:stb/truetype"

FIRST_CHAR :: 32
NUM_CHARS :: 96 // printable ASCII; enough for track and artist names here
ATLAS_SIZE :: 1024

Font :: struct {
	chars:      [NUM_CHARS]tt.bakedchar,
	tex:        u32,
	bake_px:    f32,
	ascent:     f32,
	descent:    f32,
	line_gap:   f32,
}

// Bakes one glyph atlas and parks it in the bindless table. Text is drawn at
// any size by scaling the baked quads, so a whole UI needs two atlases.
font_load :: proc(g: ^Gpu, path: string, px: f32) -> (font: Font, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read font %s: %v", path, err)
		return {}, false
	}
	defer delete(data)

	bitmap := make([]byte, ATLAS_SIZE * ATLAS_SIZE)
	defer delete(bitmap)

	res := tt.BakeFontBitmap(
		raw_data(data),
		0,
		px,
		raw_data(bitmap),
		ATLAS_SIZE,
		ATLAS_SIZE,
		FIRST_CHAR,
		NUM_CHARS,
		raw_data(font.chars[:]),
	)
	if res == 0 {
		fmt.eprintfln("font atlas too small for %s at %.0fpx", path, px)
		return {}, false
	}

	tt.GetScaledFontVMetrics(raw_data(data), 0, px, &font.ascent, &font.descent, &font.line_gap)
	font.bake_px = px
	font.tex = texture_upload(g, bitmap, ATLAS_SIZE, ATLAS_SIZE, 1)
	return font, true
}

font_scale :: proc(f: ^Font, size: f32) -> f32 {
	return size / f.bake_px
}

font_width :: proc(f: ^Font, text: string, size: f32) -> f32 {
	scale := font_scale(f, size)
	w: f32
	for ch in text {
		i := int(ch) - FIRST_CHAR
		if i < 0 || i >= NUM_CHARS do i = int('?') - FIRST_CHAR
		w += f.chars[i].xadvance
	}
	return w * scale
}

// Trims text to fit `max_width`, appending an ellipsis when it has to cut.
font_ellipsize :: proc(f: ^Font, text: string, size: f32, max_width: f32) -> string {
	if font_width(f, text, size) <= max_width do return text

	ell := font_width(f, "...", size)
	scale := font_scale(f, size)
	w: f32
	for ch, byte_index in text {
		i := int(ch) - FIRST_CHAR
		if i < 0 || i >= NUM_CHARS do i = int('?') - FIRST_CHAR
		next := w + f.chars[i].xadvance * scale
		if next + ell > max_width {
			return fmt.tprintf("%s...", text[:byte_index])
		}
		w = next
	}
	return text
}
