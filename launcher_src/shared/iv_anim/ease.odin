// Animation for programs: easing curves, tweens, springs, keyframe tracks, timers, frame sequences and a pool that runs fire-and-forget animations of
// values. No drawing and no clock: the program passes the seconds that passed (`dt`) to the update procedures, so everything here runs the same
// in the game, in a test, and in a replay, and a paused game pauses it by not calling.
//
//   iv_anim.ease(.Out_Cubic, t)                                  // a curve: t 0..1 in, 0..1 out
//   tw := iv_anim.tween_make(0.0, 100.0, 0.4, .Out_Back)         // a value that travels over 0.4 s
//   iv_anim.tween_update(&tw, dt);  x := iv_anim.tween_value(&tw)
//   s := iv_anim.spring_make(0.0)                                // a value that chases a target with a spring's bounce
//   iv_anim.spring_update(&s, target, dt);  x := s.value
//   iv_anim.animate(&pool, &panel.alpha, 1, 0.25, .Out_Quad)     // set it going and forget it: the pool moves the value until it gets there
//   fade = iv_anim.approach(fade, 1, 8, dt)                      // frame-rate-independent smoothing toward a goal
package iv_anim

import "base:intrinsics"
import "core:math"

// A curve for the progress of an animation: 0..1 in, 0..1 out (some overshoot: Back and Elastic leave the range on the way). `In` starts slowly,
// `Out` ends slowly, `In_Out` does both.
Ease :: enum u8 {
	Linear,
	In_Quad,
	Out_Quad,
	In_Out_Quad,
	In_Cubic,
	Out_Cubic,
	In_Out_Cubic,
	In_Quart,
	Out_Quart,
	In_Out_Quart,
	In_Quint,
	Out_Quint,
	In_Out_Quint,
	In_Sine,
	Out_Sine,
	In_Out_Sine,
	In_Expo,
	Out_Expo,
	In_Out_Expo,
	In_Circ,
	Out_Circ,
	In_Out_Circ,
	In_Back, // pulls back first
	Out_Back, // overshoots, then settles
	In_Out_Back,
	In_Elastic,
	Out_Elastic, // rings like a spring
	In_Out_Elastic,
	In_Bounce,
	Out_Bounce, // lands and bounces
	In_Out_Bounce,
	Smoothstep, // 3t² - 2t³
	Smootherstep, // 6t⁵ - 15t⁴ + 10t³
}

ease :: proc(e: Ease, progress: f32) -> f32 {
	t := clamp(progress, 0, 1)
	switch e {
	case .Linear:
		return t
	case .In_Quad:
		return t * t
	case .Out_Quad:
		return 1 - (1 - t) * (1 - t)
	case .In_Out_Quad:
		return 2 * t * t if t < 0.5 else 1 - math.pow(-2 * t + 2, 2) / 2
	case .In_Cubic:
		return t * t * t
	case .Out_Cubic:
		return 1 - math.pow(1 - t, 3)
	case .In_Out_Cubic:
		return 4 * t * t * t if t < 0.5 else 1 - math.pow(-2 * t + 2, 3) / 2
	case .In_Quart:
		return t * t * t * t
	case .Out_Quart:
		return 1 - math.pow(1 - t, 4)
	case .In_Out_Quart:
		return 8 * t * t * t * t if t < 0.5 else 1 - math.pow(-2 * t + 2, 4) / 2
	case .In_Quint:
		return t * t * t * t * t
	case .Out_Quint:
		return 1 - math.pow(1 - t, 5)
	case .In_Out_Quint:
		return 16 * t * t * t * t * t if t < 0.5 else 1 - math.pow(-2 * t + 2, 5) / 2
	case .In_Sine:
		return 1 - math.cos(t * math.PI / 2)
	case .Out_Sine:
		return math.sin(t * math.PI / 2)
	case .In_Out_Sine:
		return -(math.cos(math.PI * t) - 1) / 2
	case .In_Expo:
		return 0 if t == 0 else math.pow(2, 10 * t - 10)
	case .Out_Expo:
		return 1 if t == 1 else 1 - math.pow(2, -10 * t)
	case .In_Out_Expo:
		switch {
		case t == 0:
			return 0
		case t == 1:
			return 1
		case t < 0.5:
			return math.pow(2, 20 * t - 10) / 2
		}
		return (2 - math.pow(2, -20 * t + 10)) / 2
	case .In_Circ:
		return 1 - math.sqrt(1 - t * t)
	case .Out_Circ:
		return math.sqrt(1 - (t - 1) * (t - 1))
	case .In_Out_Circ:
		if t < 0.5 {
			return (1 - math.sqrt(1 - 4 * t * t)) / 2
		}
		return (math.sqrt(1 - math.pow(-2 * t + 2, 2)) + 1) / 2
	case .In_Back:
		c1: f32 = 1.70158
		return (c1 + 1) * t * t * t - c1 * t * t
	case .Out_Back:
		c1: f32 = 1.70158
		return 1 + (c1 + 1) * math.pow(t - 1, 3) + c1 * math.pow(t - 1, 2)
	case .In_Out_Back:
		c2: f32 = 1.70158 * 1.525
		if t < 0.5 {
			return (math.pow(2 * t, 2) * ((c2 + 1) * 2 * t - c2)) / 2
		}
		return (math.pow(2 * t - 2, 2) * ((c2 + 1) * (t * 2 - 2) + c2) + 2) / 2
	case .In_Elastic:
		if t == 0 || t == 1 {
			return t
		}
		return -math.pow(2, 10 * t - 10) * math.sin((t * 10 - 10.75) * (2 * math.PI / 3))
	case .Out_Elastic:
		if t == 0 || t == 1 {
			return t
		}
		return math.pow(2, -10 * t) * math.sin((t * 10 - 0.75) * (2 * math.PI / 3)) + 1
	case .In_Out_Elastic:
		if t == 0 || t == 1 {
			return t
		}
		c5: f32 = 2 * math.PI / 4.5
		if t < 0.5 {
			return -(math.pow(2, 20 * t - 10) * math.sin((20 * t - 11.125) * c5)) / 2
		}
		return (math.pow(2, -20 * t + 10) * math.sin((20 * t - 11.125) * c5)) / 2 + 1
	case .In_Bounce:
		return 1 - bounce_out(1 - t)
	case .Out_Bounce:
		return bounce_out(t)
	case .In_Out_Bounce:
		if t < 0.5 {
			return (1 - bounce_out(1 - 2 * t)) / 2
		}
		return (1 + bounce_out(2 * t - 1)) / 2
	case .Smoothstep:
		return t * t * (3 - 2 * t)
	case .Smootherstep:
		return t * t * t * (t * (t * 6 - 15) + 10)
	}
	return t
}

@(private)
bounce_out :: proc(t: f32) -> f32 {
	n1: f32 = 7.5625
	d1: f32 = 2.75
	switch {
	case t < 1 / d1:
		return n1 * t * t
	case t < 2 / d1:
		u := t - 1.5 / d1
		return n1 * u * u + 0.75
	case t < 2.5 / d1:
		u := t - 2.25 / d1
		return n1 * u * u + 0.9375
	}
	u := t - 2.625 / d1
	return n1 * u * u + 0.984375
}

// ---- small helpers -----------------------------------------------------------------------------------------------------------------

// A value that moves toward `target` the same way at any frame rate: each second it closes the fraction 1 - e^-rate of the gap (rate 8: about 98%
// of it in half a second). The usual way to smooth a camera, a hover fade or a bar.
approach :: proc(current, target, rate, dt: $T) -> T where intrinsics.type_is_float(T) {
	return target + (current - target) * math.exp(-rate * dt)
}

// The same for vectors (an array of floats).
approach_v :: proc(current, target: [$N]f32, rate, dt: f32) -> [N]f32 {
	k := math.exp(-rate * dt)
	return target + (current - target) * k
}

// Moves `current` toward `target` by at most `step` (a constant speed, no easing).
move_toward :: proc(current, target, step: f32) -> f32 {
	if abs(target - current) <= step {
		return target
	}
	return current + step if target > current else current - step
}

lerp :: proc(a, b: $T, t: f32) -> T {
	return a + scale(b - a, t)
}

// 0 below `lo`, 1 above `hi`, smooth between.
smoothstep :: proc(lo, hi, x: f32) -> f32 {
	if hi == lo {
		return 1 if x >= hi else 0
	}
	t := clamp((x - lo) / (hi - lo), 0, 1)
	return t * t * (3 - 2 * t)
}

// The angle (radians) a fraction t of the way from `a` to `b` by the short way round.
lerp_angle :: proc(a, b, t: f32) -> f32 {
	d := math.mod(b - a, math.TAU)
	if d > math.PI {
		d -= math.TAU
	} else if d < -math.PI {
		d += math.TAU
	}
	return a + d * t
}
