package spoticyclint

import "core:crypto"
import "core:math/rand"
import "core:slice"

// A plain permutation clumps the same artist together on a large library.
// "Smart" here means artist-aware: every artist's tracks are laid out evenly
// across the whole queue (offset and jittered at random), then the queue is
// read off in position order. An artist with k tracks in a library of n ends
// up roughly n/k songs apart instead of wherever chance put them.
smart_shuffle :: proc(tracks: []Track, allocator := context.allocator) -> []Track {
	out := make([]Track, len(tracks), allocator)
	if len(tracks) == 0 do return out

	seed_bytes: [8]byte
	crypto.rand_bytes(seed_bytes[:])
	r := rand.create((^u64)(&seed_bytes[0])^)
	rctx := rand.default_random_generator(&r)

	// Bucket by artist, keeping each artist's own tracks in random order.
	buckets: [dynamic][dynamic]Track
	index_of: map[string]int
	defer {
		for &b in buckets do delete(b)
		delete(buckets)
		delete(index_of)
	}

	scratch := make([]Track, len(tracks), context.temp_allocator)
	copy(scratch, tracks)
	for i := len(scratch) - 1; i > 0; i -= 1 {
		j := int(rand.uint64(rctx) % u64(i + 1))
		scratch[i], scratch[j] = scratch[j], scratch[i]
	}

	for t in scratch {
		key := t.artist_id != "" ? t.artist_id : t.artist
		idx, seen := index_of[key]
		if !seen {
			idx = len(buckets)
			append(&buckets, [dynamic]Track{})
			index_of[key] = idx
		}
		append(&buckets[idx], t)
	}

	Placed :: struct {
		pos:   f64,
		track: Track,
	}
	placed := make([dynamic]Placed, 0, len(scratch), context.temp_allocator)

	n := f64(len(scratch))
	for &b in buckets {
		spacing := n / f64(len(b))
		offset := rand.float64(rctx) * spacing
		for t, i in b {
			jitter := (rand.float64(rctx) - 0.5) * spacing * 0.5
			append(&placed, Placed{pos = offset + f64(i) * spacing + jitter, track = t})
		}
	}

	slice.sort_by(placed[:], proc(a, b: Placed) -> bool {return a.pos < b.pos})
	for p, i in placed do out[i] = p.track
	return out
}
