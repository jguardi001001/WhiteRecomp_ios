package ren

// ---------------------------------------------------------------------------
// Generational handles and the pool a backend keeps its objects in. A handle is a u32: the low 20 bits are the slot + 1
// (so 0 is never a valid handle), the high 12 bits count how often the slot was reused. Destroying an object bumps the
// slot's generation, so a handle that is kept too long fails the lookup (nil) instead of reaching a stranger.
// ---------------------------------------------------------------------------

HANDLE_INDEX_BITS :: 20
HANDLE_INDEX_MASK :: (1 << HANDLE_INDEX_BITS) - 1
HANDLE_GEN_MASK :: (1 << (32 - HANDLE_INDEX_BITS)) - 1

Pool_Slot :: struct($T: typeid) {
	value: T,
	gen:   u32, // 0 .. HANDLE_GEN_MASK; the slot is live while `used`
	used:  bool,
}

Pool :: struct($T: typeid) {
	slots: [dynamic]Pool_Slot(T),
	free:  [dynamic]u32, // indices of unused slots
	count: int,
}

pool_init :: proc(p: ^Pool($T), allocator := context.allocator) {
	p.slots = make([dynamic]Pool_Slot(T), allocator)
	p.free = make([dynamic]u32, allocator)
	p.count = 0
}

pool_destroy :: proc(p: ^Pool($T)) {
	delete(p.slots)
	delete(p.free)
	p^ = {}
}

// Puts a value in the pool and returns its handle (never 0). Returns 0 if the pool is full (2^20 - 1 live objects).
pool_add :: proc(p: ^Pool($T), value: T) -> u32 {
	index: u32
	if n := len(p.free); n > 0 {
		index = p.free[n - 1]
		pop(&p.free)
	} else {
		if len(p.slots) >= HANDLE_INDEX_MASK {
			return 0
		}
		append(&p.slots, Pool_Slot(T){})
		index = u32(len(p.slots) - 1)
	}
	s := &p.slots[index]
	s.value = value
	s.used = true
	p.count += 1
	return (s.gen << HANDLE_INDEX_BITS) | (index + 1)
}

// The object of a handle, or nil if the handle is 0, out of range, destroyed or from an earlier life of the slot.
pool_get :: proc(p: ^Pool($T), handle: u32) -> ^T {
	index := int(handle & HANDLE_INDEX_MASK) - 1
	if index < 0 || index >= len(p.slots) {
		return nil
	}
	s := &p.slots[index]
	if !s.used || s.gen != handle >> HANDLE_INDEX_BITS {
		return nil
	}
	return &s.value
}

// Removes an object; false if the handle was not live. The slot is reused with a new generation.
pool_remove :: proc(p: ^Pool($T), handle: u32) -> bool {
	if pool_get(p, handle) == nil {
		return false
	}
	index := (handle & HANDLE_INDEX_MASK) - 1
	s := &p.slots[index]
	s.value = {}
	s.used = false
	s.gen = (s.gen + 1) & HANDLE_GEN_MASK
	append(&p.free, index)
	p.count -= 1
	return true
}
