package iv_text

import "core:testing"

@(test)
lru_keeps_the_most_recently_used :: proc(t: ^testing.T) {
	l: Lru(int)
	lru_init(&l, 3)
	defer lru_destroy(&l)

	testing.expect(t, lru_get(&l, 'a', 1) == nil)
	lru_add(&l, 'a', 1, 1)
	lru_add(&l, 'b', 2, 2)
	lru_add(&l, 'c', 3, 3)
	testing.expect(t, lru_full(&l))
	testing.expect_value(t, l.count, 3)

	// 'a' is the oldest; using it makes 'b' the oldest
	key, _, used, ok := lru_oldest(&l)
	testing.expect(t, ok && key == 'a' && used == 1)
	v := lru_get(&l, 'a', 4)
	testing.expect(t, v != nil && v^ == 1)
	key, _, used, ok = lru_oldest(&l)
	testing.expect(t, ok && key == 'b' && used == 2)

	// a new key needs a place: the oldest goes
	lru_evict_oldest(&l)
	testing.expect(t, !lru_full(&l))
	testing.expect(t, lru_get(&l, 'b', 5) == nil)
	lru_add(&l, 'd', 4, 5)
	testing.expect_value(t, l.count, 3)
	Pair :: struct {
		k: rune,
		v: int,
	}
	for want in ([?]Pair{{'a', 1}, {'c', 3}, {'d', 4}}) {
		got := lru_get(&l, want.k, 6)
		testing.expectf(t, got != nil && got^ == want.v, "%c", want.k)
	}

	lru_clear(&l)
	testing.expect_value(t, l.count, 0)
	testing.expect(t, lru_get(&l, 'a', 7) == nil)
	_, _, _, has := lru_oldest(&l)
	testing.expect(t, !has)
	lru_add(&l, 'a', 9, 7) // usable again after a clear
	testing.expect_value(t, lru_get(&l, 'a', 8)^, 9)
}

// Many more keys than places, in and out in every order: whatever is in the cache is found, and nothing else is.
@(test)
lru_stays_consistent_when_it_is_used_hard :: proc(t: ^testing.T) {
	PLACES :: 50
	l: Lru(rune)
	lru_init(&l, PLACES)
	defer lru_destroy(&l)

	stamp: u64
	for i in 0 ..< 5000 {
		key := rune((i * 7919) % 313 + 0x3000) // a spread of keys that collide in the buckets
		stamp += 1
		if v := lru_get(&l, key, stamp); v != nil {
			testing.expect_value(t, v^, key)
			continue
		}
		if lru_full(&l) {
			lru_evict_oldest(&l)
		}
		lru_add(&l, key, key, stamp)
		testing.expect(t, l.count <= PLACES)
	}
	testing.expect_value(t, l.count, PLACES)

	// the list runs through every node once, newest to oldest, and the stamps go down
	n := 0
	last := max(u64)
	for i := l.head; i >= 0; i = l.nodes[i].next {
		testing.expect(t, l.nodes[i].used <= last)
		last = l.nodes[i].used
		testing.expect(t, lru_find(&l, l.nodes[i].key) == i)
		n += 1
	}
	testing.expect_value(t, n, PLACES)
}
