package spoticyclint

import "core:fmt"
import "core:testing"

@(test)
test_smart_shuffle_spreads_artists :: proc(t: ^testing.T) {
	tracks: [dynamic]Track
	names := []string{"A", "B", "C", "D"}
	counts := []int{40, 30, 20, 10}
	for name, i in names {
		for n in 0 ..< counts[i] {
			append(&tracks, Track{uri = fmt.tprintf("u:%s:%d", name, n), name = "x", artist = name, artist_id = name})
		}
	}
	order := smart_shuffle(tracks[:])
	testing.expect_value(t, len(order), 100)

	seen: map[string]bool
	for tr in order do seen[tr.uri] = true
	testing.expect_value(t, len(seen), 100)

	adjacent := 0
	for i in 1 ..< len(order) {
		if order[i].artist == order[i - 1].artist do adjacent += 1
	}
	fmt.println("adjacent same-artist pairs:", adjacent)
	testing.expect(t, adjacent <= 8, "artists should rarely repeat back to back")
}

@(test)
test_single_artist_and_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, len(smart_shuffle(nil)), 0)

	tracks: [dynamic]Track
	for n in 0 ..< 5 do append(&tracks, Track{uri = fmt.tprintf("u%d", n), artist = "solo", artist_id = "solo"})
	order := smart_shuffle(tracks[:])
	testing.expect_value(t, len(order), 5)
	seen: map[string]bool
	for tr in order do seen[tr.uri] = true
	testing.expect_value(t, len(seen), 5)
}
