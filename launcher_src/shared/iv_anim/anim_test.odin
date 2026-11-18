package iv_anim

import "core:math"
import "core:testing"

@(test)
every_curve_starts_at_0_and_ends_at_1 :: proc(t: ^testing.T) {
	for e in Ease {
		testing.expectf(t, abs(ease(e, 0)) < 1e-4, "%v at 0 is %v", e, ease(e, 0))
		testing.expectf(t, abs(ease(e, 1) - 1) < 1e-4, "%v at 1 is %v", e, ease(e, 1))
		testing.expectf(t, ease(e, -3) == ease(e, 0) && ease(e, 5) == ease(e, 1), "%v is clamped", e)
	}
	testing.expect(t, ease(.In_Quad, 0.5) < 0.5 && ease(.Out_Quad, 0.5) > 0.5)
	testing.expect_value(t, ease(.In_Out_Cubic, 0.5), 0.5)
	testing.expect(t, ease(.Out_Back, 0.8) > 1) // overshoots
	testing.expect(t, ease(.In_Back, 0.2) < 0) // pulls back
}

@(test)
tween_goes_from_to_with_delay_and_loops :: proc(t: ^testing.T) {
	tw := tween_make(f32(10), 20, 2, .Linear, delay = 1)
	testing.expect_value(t, tween_value(&tw), 10)
	tween_update(&tw, 1) // the delay is over
	testing.expect_value(t, tween_value(&tw), 10)
	tween_update(&tw, 1)
	testing.expect_value(t, tween_value(&tw), 15)
	testing.expect(t, !tween_done(&tw))
	tween_update(&tw, 5)
	testing.expect_value(t, tween_value(&tw), 20)
	testing.expect(t, tween_done(&tw))

	v := tween_make([2]f32{0, 0}, [2]f32{10, 20}, 1, .Linear)
	tween_update(&v, 0.5)
	testing.expect_value(t, tween_value(&v), [2]f32{5, 10})

	pp := tween_make(f32(0), 1, 1, .Linear, loop = .Ping_Pong)
	tween_update(&pp, 1.25)
	testing.expect_value(t, tween_value(&pp), 0.75)
	rp := tween_make(f32(0), 1, 1, .Linear, loop = .Repeat)
	tween_update(&rp, 2.25)
	testing.expect_value(t, tween_value(&rp), 0.25)
	testing.expect(t, !tween_done(&rp))
}

@(test)
spring_settles_and_is_steady_at_any_step :: proc(t: ^testing.T) {
	// a critically damped spring never overshoots; an under-damped one does; an over-damped one creeps
	crit := spring_make(f32(0), 3, 1)
	under := spring_make(f32(0), 3, 0.3)
	over := spring_make(f32(0), 3, 2)
	top_crit, top_under, top_over: f32
	for _ in 0 ..< 600 {
		spring_update(&crit, 1, 1.0 / 60)
		spring_update(&under, 1, 1.0 / 60)
		spring_update(&over, 1, 1.0 / 60)
		top_crit = max(top_crit, crit.value)
		top_under = max(top_under, under.value)
		top_over = max(top_over, over.value)
	}
	testing.expect(t, top_crit <= 1.0001, "critical: no overshoot")
	testing.expect(t, top_under > 1.1, "under-damped: overshoots")
	testing.expect(t, top_over <= 1.0001, "over-damped: no overshoot")
	testing.expect(t, spring_settled(&crit, 1) && spring_settled(&under, 1) && spring_settled(&over, 1))

	// the same time in one big step and in many small ones lands in the same place (it is solved, not stepped)
	a := spring_make(f32(0), 2, 0.5)
	b := spring_make(f32(0), 2, 0.5)
	spring_update(&a, 1, 0.5)
	for _ in 0 ..< 50 {
		spring_update(&b, 1, 0.01)
	}
	testing.expectf(t, abs(a.value - b.value) < 1e-4, "same value: %v vs %v", a.value, b.value)
	testing.expectf(t, abs(a.velocity - b.velocity) < 1e-3, "same velocity: %v vs %v", a.velocity, b.velocity)

	// vectors
	p := spring_make([2]f32{0, 0})
	for _ in 0 ..< 600 {
		spring_update(&p, [2]f32{4, -2}, 1.0 / 60)
	}
	testing.expect(t, spring_settled(&p, [2]f32{4, -2}))
	spring_snap(&p, [2]f32{1, 1})
	testing.expect_value(t, p.velocity, [2]f32{})
}

@(test)
track_samples_between_keys :: proc(t: ^testing.T) {
	tr: Track(f32)
	defer track_destroy(&tr)
	track_add(&tr, 0, 0)
	track_add(&tr, 1, 10)
	track_add(&tr, 3, 0, .In_Quad)
	testing.expect_value(t, track_duration(&tr), 3)
	testing.expect_value(t, track_sample(&tr, -1), 0)
	testing.expect_value(t, track_sample(&tr, 0.5), 5)
	testing.expect_value(t, track_sample(&tr, 1), 10)
	testing.expect_value(t, track_sample(&tr, 2), 7.5) // halfway through an In_Quad: 0.25 of the way down
	testing.expect_value(t, track_sample(&tr, 9), 0)
	tr.loop = .Repeat
	testing.expect_value(t, track_sample(&tr, 3.5), 5)
	tr.loop = .Ping_Pong
	testing.expect_value(t, track_sample(&tr, 3.5), 4.375) // on the way back: 2.5 s in, where In_Quad is 0.75 of the way from 10 down to 0 (10 - 10 * 0.5625)
	empty: Track(f32)
	testing.expect_value(t, track_sample(&empty, 1), 0)
}

@(test)
timer_and_frames :: proc(t: ^testing.T) {
	tm := timer_make(1)
	testing.expect_value(t, timer_update(&tm, 0.6), 0)
	testing.expect_value(t, timer_update(&tm, 0.6), 1)
	testing.expect(t, timer_done(&tm))
	testing.expect_value(t, timer_update(&tm, 1), 0) // already done
	timer_reset(&tm)
	testing.expect_value(t, timer_remaining(&tm), 1)

	rep := timer_make(0.5, true)
	testing.expect_value(t, timer_update(&rep, 1.3), 2) // a long step fires twice
	testing.expect(t, abs(timer_progress(&rep) - 0.6) < 1e-4)

	f := Frames{count = 4, fps = 10, loop = .Repeat}
	testing.expect_value(t, frame_at(f, 0), 0)
	testing.expect_value(t, frame_at(f, 0.35), 3)
	testing.expect_value(t, frame_at(f, 0.45), 0)
	f.loop = .Once
	testing.expect_value(t, frame_at(f, 9), 3)
	f.loop = .Ping_Pong // 0 1 2 3 2 1 0 1 ...
	testing.expect_value(t, frame_at(f, 0.45), 2)
	testing.expect_value(t, frame_at(f, 0.65), 0)
}

@(test)
smoothing_helpers :: proc(t: ^testing.T) {
	// approach: the same at any frame rate
	a: f32 = 0
	b: f32 = 0
	for _ in 0 ..< 30 {
		a = approach(a, 1, 5, f32(1.0 / 30))
	}
	for _ in 0 ..< 60 {
		b = approach(b, 1, 5, f32(1.0 / 60))
	}
	testing.expect(t, abs(a - b) < 1e-4)
	testing.expect(t, abs(a - (1 - math.exp(f32(-5)))) < 1e-4)
	testing.expect_value(t, move_toward(0, 10, 3), 3)
	testing.expect_value(t, move_toward(9, 10, 3), 10)
	testing.expect_value(t, move_toward(0, -10, 3), -3)
	testing.expect_value(t, smoothstep(0, 10, 5), 0.5)
	testing.expect_value(t, smoothstep(0, 10, -5), 0)
	testing.expect(t, abs(lerp_angle(0.1, math.TAU - 0.1, 0.5)) < 1e-5) // by the short way, through 0
}

@(test)
pool_animates_replaces_and_calls_back :: proc(t: ^testing.T) {
	pool: Pool
	pool_init(&pool)
	defer pool_destroy(&pool)

	Thing :: struct {
		alpha: f32,
		pos:   [2]f32,
		done:  int,
	}
	thing := Thing{}
	animate(&pool, &thing.alpha, 1, 1, .Linear)
	animate(&pool, &thing.pos, [2]f32{10, 20}, 2, .Linear, on_done = proc(user: rawptr) {
		(^Thing)(user).done += 1
	}, user = &thing)
	testing.expect_value(t, pool_count(&pool), 2)
	pool_update(&pool, 0.5)
	testing.expect_value(t, thing.alpha, 0.5)
	testing.expect_value(t, thing.pos, [2]f32{2.5, 5})
	pool_update(&pool, 0.5)
	testing.expect_value(t, thing.alpha, 1)
	testing.expect_value(t, pool_count(&pool), 1) // alpha arrived
	testing.expect_value(t, thing.done, 0)

	// asking again replaces: it goes on from where it is
	animate(&pool, &thing.pos, [2]f32{0, 0}, 1, .Linear)
	testing.expect_value(t, pool_count(&pool), 1)
	pool_update(&pool, 0.5)
	testing.expect_value(t, thing.pos, [2]f32{2.5, 5}) // halfway from (5,10) to 0
	testing.expect_value(t, thing.done, 0) // (the replaced one never calls back)
	testing.expect(t, is_animating(&pool, &thing.pos))
	testing.expect(t, cancel(&pool, &thing.pos))
	testing.expect(t, !is_animating(&pool, &thing.pos))

	// delays, and a callback that starts the next animation
	animate(&pool, &thing.alpha, 0, 1, .Linear, delay = 1, on_done = proc(user: rawptr) {
		(^Thing)(user).done += 1
	}, user = &thing)
	pool_update(&pool, 0.9)
	testing.expect_value(t, thing.alpha, 1) // still waiting
	pool_update(&pool, 1.5)
	testing.expect_value(t, thing.alpha, 0)
	testing.expect_value(t, thing.done, 1)
	testing.expect_value(t, pool_count(&pool), 0)
}
