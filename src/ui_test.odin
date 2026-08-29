package spoticyclint

import "core:testing"

// Drives the widget layer the way the compositor drives it: one frame per
// event, with pressed/released only true on the frame they happen.
@(private = "file")
frame :: proc(ui: ^UI, input: ^Input, x, y: f32, down: bool) {
	was_down := input.down[0]
	input.mouse = {x, y}
	input.has_mouse = true
	input.pressed = {}
	input.released = {}
	input.pressed[0] = down && !was_down
	input.released[0] = !down && was_down
	input.down[0] = down
	ui_begin(ui, 1000, 700, input, 1.0 / 60)
}

@(test)
test_button_click :: proc(t: ^testing.T) {
	ui: UI
	defer ui_destroy(&ui)
	input: Input
	defer delete(input.keys_pressed)
	r := Rect{100, 100, 200, 50}

	frame(&ui, &input, 150, 120, false)
	clicked, hovered := ui_invisible_button(&ui, ui_id("b"), r)
	ui_end(&ui)
	testing.expect(t, hovered, "should hover when the pointer is inside")
	testing.expect(t, !clicked, "hovering is not a click")

	frame(&ui, &input, 150, 120, true)
	clicked, _ = ui_invisible_button(&ui, ui_id("b"), r)
	ui_end(&ui)
	testing.expect(t, !clicked, "press alone is not a click")

	frame(&ui, &input, 150, 120, false)
	clicked, _ = ui_invisible_button(&ui, ui_id("b"), r)
	ui_end(&ui)
	testing.expect(t, clicked, "release inside the button should click")
}

@(test)
test_slider_drag :: proc(t: ^testing.T) {
	ui: UI
	defer ui_destroy(&ui)
	input: Input
	defer delete(input.keys_pressed)
	r := Rect{100, 600, 200, 20} // 100..300 across

	value: f32 = 1

	// Press at the quarter point.
	frame(&ui, &input, 150, 610, true)
	value = ui_slider(&ui, "vol", r, value, DIM, ACCENT, TEXT)
	ui_end(&ui)
	testing.expectf(t, abs(value - 0.25) < 0.01, "press should jump to 0.25, got %f", value)

	// Drag right.
	frame(&ui, &input, 250, 610, true)
	value = ui_slider(&ui, "vol", r, value, DIM, ACCENT, TEXT)
	ui_end(&ui)
	testing.expectf(t, abs(value - 0.75) < 0.01, "drag should follow to 0.75, got %f", value)

	// Release, then move away: the value must stay put.
	frame(&ui, &input, 250, 610, false)
	value = ui_slider(&ui, "vol", r, value, DIM, ACCENT, TEXT)
	ui_end(&ui)
	frame(&ui, &input, 900, 100, false)
	value = ui_slider(&ui, "vol", r, value, DIM, ACCENT, TEXT)
	ui_end(&ui)
	testing.expectf(t, abs(value - 0.75) < 0.01, "value should hold after release, got %f", value)
}
