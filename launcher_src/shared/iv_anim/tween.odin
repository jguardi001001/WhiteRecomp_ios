package iv_anim

import "base:intrinsics"
import "core:math"

// ---------------------------------------------------------------------------
// Things that change over time and are asked for their value: a Tween (from here to there, with a curve), a Spring (chases a target), a Track
// (keyframes), a Timer, and Frames (which picture of a flip-book now). The type of the value is anything that can be added and scaled by a number:
// f32, f64 (for Spring and Tween of f64 pass seconds as f32 anyway), [2]f32, [3]f32, [4]f32 (positions, colors).
// ---------------------------------------------------------------------------

Loop :: enum u8 {
	Once, // stops at the end
	Repeat, // starts again
	Ping_Pong, // goes there and back
}

// ---- tween ---------------------------------------------------------------------------------------------------------------------------

Tween :: struct($T: typeid) {
	from, to: T,
	duration: f32, // seconds
	delay:    f32, // seconds to wait before it starts (the value is `from` meanwhile)
	ease:     Ease,
	loop:     Loop,
	time:     f32, // seconds since it was made (the delay included)
}

tween_make :: proc(from, to: $T, duration: f32, ease := Ease.In_Out_Quad, delay: f32 = 0, loop := Loop.Once) -> Tween(T) {
	return {from = from, to = to, duration = duration, delay = delay, ease = ease, loop = loop}
}

tween_update :: proc(t: ^Tween($T), dt: f32) {
	t.time += dt
}

// Back to the start (delay again).
tween_restart :: proc(t: ^Tween($T)) {
	t.time = 0
}

// How far along it is, 0..1 (before the curve is applied). A looping tween is always on its way: this is the position in the current turn.
tween_progress :: proc(t: ^Tween($T)) -> f32 {
	local := t.time - t.delay
	if local <= 0 {
		return 0
	}
	if t.duration <= 0 {
		return 1
	}
	switch t.loop {
	case .Once:
		return min(local / t.duration, 1)
	case .Repeat:
		return math.mod(local, t.duration) / t.duration
	case .Ping_Pong:
		p := math.mod(local, 2 * t.duration) / t.duration
		return p if p <= 1 else 2 - p
	}
	return 0
}

tween_value :: proc(t: ^Tween($T)) -> T {
	e := ease(t.ease, tween_progress(t))
	return t.from + scale(t.to - t.from, e)
}

// Has a tween that plays once reached its end? (A looping one is never done.)
tween_done :: proc(t: ^Tween($T)) -> bool {
	return t.loop == .Once && t.time >= t.delay + t.duration
}

// ---- spring --------------------------------------------------------------------------------------------------------------------------

// A value pulled toward a target by a spring with friction. It is solved exactly (not stepped), so it is stable at any dt, even a long hitch.
//   frequency  how fast it swings, in cycles per second (about 1 is lazy, 4 is snappy)
//   damping    1 reaches the target without overshooting at the soonest, less than 1 overshoots and rings, more than 1 creeps in
Spring :: struct($T: typeid) {
	value:     T,
	velocity:  T,
	frequency: f32,
	damping:   f32,
}

spring_make :: proc(value: $T, frequency: f32 = 3, damping: f32 = 0.6) -> Spring(T) {
	return {value = value, frequency = frequency, damping = damping}
}

spring_update :: proc(s: ^Spring($T), target: T, dt: f32) {
	if dt <= 0 {
		return
	}
	omega := 2 * math.PI * max(s.frequency, 0.0001)
	zeta := max(s.damping, 0)
	x := s.value - target
	v := s.velocity
	if zeta < 1 { // under-damped: it rings
		zw := zeta * omega
		wd := omega * math.sqrt(1 - zeta * zeta)
		decay := math.exp(-zw * dt)
		c := math.cos(wd * dt)
		sn := math.sin(wd * dt)
		b := scale(v + scale(x, zw), 1 / wd) // (the sine's share of the motion)
		s.value = target + scale(scale(x, c) + scale(b, sn), decay)
		s.velocity = scale(scale(b, wd * c) - scale(x, wd * sn) - scale(scale(x, c) + scale(b, sn), zw), decay)
	} else if zeta == 1 { // critically damped: the quickest way in with no overshoot
		decay := math.exp(-omega * dt)
		k := v + scale(x, omega)
		s.value = target + scale(x + scale(k, dt), decay)
		s.velocity = scale(v - scale(k, omega * dt), decay)
	} else { // over-damped: it creeps in
		root := math.sqrt(zeta * zeta - 1)
		r1 := -omega * (zeta - root)
		r2 := -omega * (zeta + root)
		c2 := scale(v - scale(x, r1), 1 / (r2 - r1))
		c1 := x - c2
		e1 := math.exp(r1 * dt)
		e2 := math.exp(r2 * dt)
		s.value = target + scale(c1, e1) + scale(c2, e2)
		s.velocity = scale(c1, r1 * e1) + scale(c2, r2 * e2)
	}
}

// `v` times a number, for a scalar or an array of floats.
@(private)
scale :: #force_inline proc(v: $T, k: f32) -> T {
	when intrinsics.type_is_array(T) {
		return v * k
	} else {
		return v * T(k)
	}
}

// Has the spring come to rest at `target` (within `epsilon`, and nearly still)?
spring_settled :: proc(s: ^Spring($T), target: T, epsilon: f32 = 0.001) -> bool {
	return length_sq(s.value - target) <= epsilon * epsilon && length_sq(s.velocity) <= epsilon * epsilon
}

// Puts the spring at `value` with no speed.
spring_snap :: proc(s: ^Spring($T), value: T) {
	s.value = value
	s.velocity = {}
}

@(private)
length_sq :: proc(v: $T) -> f32 {
	when T == f32 {
		return v * v
	} else when T == f64 {
		return f32(v * v)
	} else {
		sum: f32
		for c in v {
			sum += f32(c * c)
		}
		return sum
	}
}

// ---- keyframes -----------------------------------------------------------------------------------------------------------------------

Key :: struct($T: typeid) {
	time:  f32, // seconds
	value: T,
	ease:  Ease, // the curve from the previous key to this one
}

// Values at times, with a curve between each two. Keys must be in order of time.
Track :: struct($T: typeid) {
	keys: [dynamic]Key(T),
	loop: Loop,
}

track_destroy :: proc(t: ^Track($T)) {
	delete(t.keys)
	t^ = {}
}

// Adds a key after the last (time must not be before it).
track_add :: proc(t: ^Track($T), time: f32, value: T, ease := Ease.Linear) {
	append(&t.keys, Key(T){time, value, ease})
}

track_duration :: proc(t: ^Track($T)) -> f32 {
	return t.keys[len(t.keys) - 1].time if len(t.keys) > 0 else 0
}

// The value at `time` seconds: the first key's before it, the last's after it (a looping track wraps `time` first).
track_sample :: proc(t: ^Track($T), time: f32) -> T {
	n := len(t.keys)
	if n == 0 {
		return {}
	}
	time := time
	d := track_duration(t)
	if d > 0 {
		switch t.loop {
		case .Once:
		case .Repeat:
			time = math.mod(time, d)
			if time < 0 {
				time += d
			}
		case .Ping_Pong:
			time = math.mod(time, 2 * d)
			if time < 0 {
				time += 2 * d
			}
			if time > d {
				time = 2 * d - time
			}
		}
	}
	if time <= t.keys[0].time {
		return t.keys[0].value
	}
	for i in 1 ..< n {
		b := t.keys[i]
		if time <= b.time {
			a := t.keys[i - 1]
			span := b.time - a.time
			p: f32 = 1 if span <= 0 else (time - a.time) / span
			return a.value + scale(b.value - a.value, ease(b.ease, p))
		}
	}
	return t.keys[n - 1].value
}

// ---- timer ---------------------------------------------------------------------------------------------------------------------------

// A countdown. `timer_update` returns true on the call in which it runs out (a repeating one: on every turn, counting how many turns a long dt made).
Timer :: struct {
	duration: f32,
	elapsed:  f32,
	repeat:   bool,
	paused:   bool,
}

timer_make :: proc(duration: f32, repeat := false) -> Timer {
	return {duration = duration, repeat = repeat}
}

timer_update :: proc(t: ^Timer, dt: f32) -> (fired: int) {
	if t.paused || t.duration <= 0 {
		return 0
	}
	if !t.repeat && t.elapsed >= t.duration {
		return 0
	}
	t.elapsed += dt
	if t.repeat {
		for t.elapsed >= t.duration {
			t.elapsed -= t.duration
			fired += 1
		}
		return
	}
	if t.elapsed >= t.duration {
		t.elapsed = t.duration
		return 1
	}
	return 0
}

timer_reset :: proc(t: ^Timer) {
	t.elapsed = 0
}

timer_done :: proc(t: ^Timer) -> bool {
	return !t.repeat && t.elapsed >= t.duration
}

// How far through, 0..1.
timer_progress :: proc(t: ^Timer) -> f32 {
	return clamp(t.elapsed / t.duration, 0, 1) if t.duration > 0 else 1
}

timer_remaining :: proc(t: ^Timer) -> f32 {
	return max(t.duration - t.elapsed, 0)
}

// ---- frames --------------------------------------------------------------------------------------------------------------------------

// A flip-book: which of `count` pictures to show `time` seconds in, at `fps` pictures a second.
Frames :: struct {
	count: int,
	fps:   f32,
	loop:  Loop,
}

frame_at :: proc(f: Frames, time: f32) -> int {
	if f.count <= 0 {
		return 0
	}
	step := int(math.floor(max(time, 0) * f.fps))
	switch f.loop {
	case .Once:
		return min(step, f.count - 1)
	case .Repeat:
		return step % f.count
	case .Ping_Pong:
		if f.count == 1 {
			return 0
		}
		cycle := 2 * (f.count - 1)
		k := step % cycle
		return k if k < f.count else cycle - k
	}
	return 0
}
