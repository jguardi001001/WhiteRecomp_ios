package iv_text

import "base:runtime"

// ---------------------------------------------------------------------------
// A cache with a fixed number of places, keyed by a rune, that gives up the one used least recently when it is full. One allocation for the nodes and
// one for the index, never more: a node is a place in a doubly linked list (most recently used first) and in the chain of its hash bucket, all by
// position in the node array, so nothing is allocated per entry and nothing moves.
//
// Every use is stamped (`stamp`: the caller says what time it is; iv_text uses the frame number) so that the owner can refuse to give up what was
// used in the current frame (see lru_oldest): a glyph that is already in the frame's draw list must keep its place in the atlas until the frame is drawn.
// ---------------------------------------------------------------------------

Lru_Node :: struct($V: typeid) {
	key:   rune,
	value: V,
	used:  u64, // the stamp of the last get / add
	prev:  i32, // towards the most recently used (-1: none)
	next:  i32, // towards the least recently used; in the list of free nodes: the next free one
	chain: i32, // the next node of the same bucket (-1: none)
}

Lru :: struct($V: typeid) {
	nodes:     []Lru_Node(V),
	buckets:   []i32, // the first node of each bucket (-1: none); a power of two long
	shift:     u32, // 32 - log2(len(buckets))
	head:      i32, // the most recently used (-1: none)
	tail:      i32, // the least recently used
	free:      i32, // the first unused node (-1: none)
	count:     int, // nodes in use
	allocator: runtime.Allocator,
}

lru_init :: proc(l: ^Lru($V), capacity: int, allocator := context.allocator) {
	places := max(capacity, 1)
	l.allocator = allocator
	l.nodes = make([]Lru_Node(V), places, allocator)
	bits := u32(1)
	for (1 << bits) < places * 2 {
		bits += 1
	}
	l.buckets = make([]i32, 1 << bits, allocator)
	l.shift = 32 - bits
	lru_clear(l)
}

lru_destroy :: proc(l: ^Lru($V)) {
	delete(l.nodes, l.allocator)
	delete(l.buckets, l.allocator)
	l^ = {}
}

// Forgets everything.
lru_clear :: proc(l: ^Lru($V)) {
	for &b in l.buckets {
		b = -1
	}
	for i in 0 ..< len(l.nodes) {
		l.nodes[i].next = i32(i + 1) if i + 1 < len(l.nodes) else -1
	}
	l.free = 0 if len(l.nodes) > 0 else -1
	l.head, l.tail = -1, -1
	l.count = 0
}

// Is every place taken (the next lru_add needs a lru_evict_oldest first)?
lru_full :: proc(l: ^Lru($V)) -> bool {
	return l.count >= len(l.nodes)
}

// The value of a key and makes it the most recently used (stamped `stamp`); nil if the cache does not have it.
lru_get :: proc(l: ^Lru($V), key: rune, stamp: u64) -> ^V {
	i := lru_find(l, key)
	if i < 0 {
		return nil
	}
	if l.head != i {
		lru_unlink(l, i)
		lru_push_front(l, i)
	}
	l.nodes[i].used = stamp
	return &l.nodes[i].value
}

// Adds a key that is not in the cache, as the most recently used; the cache must not be full. Returns where the value is.
lru_add :: proc(l: ^Lru($V), key: rune, value: V, stamp: u64) -> ^V {
	assert(!lru_full(l) && lru_find(l, key) < 0)
	i := l.free
	l.free = l.nodes[i].next
	slot := lru_slot(l, key)
	n := &l.nodes[i]
	n.key = key
	n.value = value
	n.used = stamp
	n.chain = l.buckets[slot]
	l.buckets[slot] = i
	lru_push_front(l, i)
	l.count += 1
	return &n.value
}

// The least recently used: its key, where its value is, and the stamp of its last use. ok = false when the cache is empty.
lru_oldest :: proc(l: ^Lru($V)) -> (key: rune, value: ^V, used: u64, ok: bool) {
	if l.tail < 0 {
		return 0, nil, 0, false
	}
	n := &l.nodes[l.tail]
	return n.key, &n.value, n.used, true
}

// Takes the least recently used out (its place is free for the next lru_add).
lru_evict_oldest :: proc(l: ^Lru($V)) {
	i := l.tail
	if i < 0 {
		return
	}
	lru_unlink(l, i)
	p := &l.buckets[lru_slot(l, l.nodes[i].key)] // out of its bucket's chain
	for p^ != i {
		p = &l.nodes[p^].chain
	}
	p^ = l.nodes[i].chain
	l.nodes[i].next = l.free
	l.free = i
	l.count -= 1
}

@(private)
lru_slot :: proc(l: ^Lru($V), key: rune) -> u32 {
	return (u32(key) * 2654435761) >> l.shift
}

@(private)
lru_find :: proc(l: ^Lru($V), key: rune) -> i32 {
	if len(l.buckets) == 0 {
		return -1
	}
	i := l.buckets[lru_slot(l, key)]
	for i >= 0 {
		if l.nodes[i].key == key {
			return i
		}
		i = l.nodes[i].chain
	}
	return -1
}

@(private)
lru_unlink :: proc(l: ^Lru($V), i: i32) {
	n := &l.nodes[i]
	if n.prev >= 0 {
		l.nodes[n.prev].next = n.next
	} else {
		l.head = n.next
	}
	if n.next >= 0 {
		l.nodes[n.next].prev = n.prev
	} else {
		l.tail = n.prev
	}
}

@(private)
lru_push_front :: proc(l: ^Lru($V), i: i32) {
	n := &l.nodes[i]
	n.prev = -1
	n.next = l.head
	if l.head >= 0 {
		l.nodes[l.head].prev = i
	}
	l.head = i
	if l.tail < 0 {
		l.tail = i
	}
}
