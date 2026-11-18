package iv_anim

// ---------------------------------------------------------------------------
// Set a value going and forget it. A Pool holds animations of values that live somewhere else (a field of a struct, an element of an array); every
// update it moves each of them a step and drops the ones that arrived. Asking for a new animation of a value that is already being animated replaces
// the old one (the value goes from where it is now), so a hover fade that is told "go to 1" and then "go to 0" never fights itself.
//
//   iv_anim.animate(&pool, &panel.alpha, 1, 0.25, .Out_Quad)
//   iv_anim.animate(&pool, &button.pos, [2]f32{40, 8}, 0.4, .Out_Back, on_done = proc(user: rawptr) {...}, user = button)
//   iv_anim.pool_update(&pool, dt)         // once a frame
//
// The values may be f32 or arrays of up to four f32 (positions, colors). The pool keeps pointers: a value must stay where it is while it is animated
// (cancel it first, `cancel(&pool, &value)`, or clear the pool, if the thing that owns it goes away).
// ---------------------------------------------------------------------------

MAX_COMPONENTS :: 4

Job :: struct {
	target:     [^]f32,
	count:      int, // how many f32 (1 .. 4)
	from, to:   [MAX_COMPONENTS]f32,
	duration:   f32,
	delay:      f32,
	time:       f32,
	ease:       Ease,
	on_done:    proc(user: rawptr),
	user:       rawptr,
}

Pool :: struct {
	jobs: [dynamic]Job,
}

pool_init :: proc(p: ^Pool, allocator := context.allocator) {
	p.jobs = make([dynamic]Job, allocator)
}

pool_destroy :: proc(p: ^Pool) {
	delete(p.jobs)
	p^ = {}
}

// Forgets every animation (the values stay where they are).
pool_clear :: proc(p: ^Pool) {
	clear(&p.jobs)
}

// How many animations are running.
pool_count :: proc(p: ^Pool) -> int {
	return len(p.jobs)
}

// Animates `target` from its value now to `to` over `duration` seconds (after `delay`). `on_done` is called with `user` when it arrives (not when it is
// replaced or cancelled).
animate :: proc(
	p: ^Pool,
	target: ^$T,
	to: T,
	duration: f32,
	ease := Ease.In_Out_Quad,
	delay: f32 = 0,
	on_done: proc(user: rawptr) = nil,
	user: rawptr = nil,
) where size_of(T) % size_of(f32) == 0 && size_of(T) <= MAX_COMPONENTS * size_of(f32) && (T == f32 || T == [2]f32 || T == [3]f32 || T == [4]f32) {
	job := Job {
		target   = cast([^]f32)target,
		count    = size_of(T) / size_of(f32),
		duration = duration,
		delay    = delay,
		ease     = ease,
		on_done  = on_done,
		user     = user,
	}
	from := target^
	to := to
	copy(job.from[:job.count], (cast([^]f32)&from)[:job.count])
	copy(job.to[:job.count], (cast([^]f32)&to)[:job.count])
	cancel_target(p, job.target)
	append(&p.jobs, job)
}

// Stops the animation of this value (it stays where it is). false if it was not being animated.
cancel :: proc(p: ^Pool, target: ^$T) -> bool {
	return cancel_target(p, cast([^]f32)target)
}

// Is this value being animated?
is_animating :: proc(p: ^Pool, target: ^$T) -> bool {
	for j in p.jobs {
		if j.target == cast([^]f32)target {
			return true
		}
	}
	return false
}

@(private)
cancel_target :: proc(p: ^Pool, target: [^]f32) -> bool {
	for j, i in p.jobs {
		if j.target == target {
			ordered_remove(&p.jobs, i)
			return true
		}
	}
	return false
}

// Moves every animation `dt` seconds on. A value that arrives is set to exactly its goal, and its on_done is called (after all the values are moved, so
// the callback may start new animations).
pool_update :: proc(p: ^Pool, dt: f32) {
	finished := make([dynamic]Job, context.temp_allocator)
	i := 0
	for i < len(p.jobs) {
		j := &p.jobs[i]
		j.time += dt
		local := j.time - j.delay
		if local < 0 {
			i += 1
			continue
		}
		progress: f32 = 1 if j.duration <= 0 else min(local / j.duration, 1)
		e := ease(j.ease, progress)
		for c in 0 ..< j.count {
			j.target[c] = j.from[c] + (j.to[c] - j.from[c]) * e if progress < 1 else j.to[c]
		}
		if progress >= 1 {
			append(&finished, j^)
			ordered_remove(&p.jobs, i)
			continue
		}
		i += 1
	}
	for j in finished {
		if j.on_done != nil {
			j.on_done(j.user)
		}
	}
}
