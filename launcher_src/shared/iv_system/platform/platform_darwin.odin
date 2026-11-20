package platform

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:math"
import "core:os"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import CG "core:sys/darwin/CoreGraphics"
import CT "core:sys/darwin/CoreText"
import ObjC "core:sys/darwin/ObjectiveC"
import NS "vendor:darwin/AppKit"
import GC "vendor:darwin/GameController"
import CA "vendor:darwin/QuartzCore"
import input "../../iv_input"

// ---------------------------------------------------------------------------
// The macOS part of platform: Cocoa (AppKit), through Odin's Objective-C bindings. Each window is an NSWindow (of a small
// subclass, so that a window without a title bar can still take the keyboard) whose content view hosts a CAMetalLayer: that
// layer is what a graphics backend draws into (Vulkan through MoltenVK's VK_EXT_metal_surface, or Metal).
//
// How it runs: the program owns the loop, never [NSApp run]. poll takes every event that is waiting (nextEventMatchingMask
// with a date in the past), reads the keys and the mouse from it and hands it on to AppKit (sendEvent), so that the title bar,
// the menu and the window buttons work as usual. What a window is (size, scale, focus, minimized, zoomed, fullscreen) is read
// from it after the events, rather than followed through delegate callbacks; only the close button needs a delegate
// (windowShouldClose: says no, and the program is asked).
//
// What differs from Windows, and what the program notices:
//  * `size` is in pixels: the view's size in points times backingScaleFactor (2 on a Retina screen); dpi_scale is that factor.
//    The layer's contentsScale follows the factor, so the drawable is in pixels too.
//  * Fullscreen is the system's own (its own Space, with the animation), so w.fullscreen changes when the animation is done.
//  * Dragging the title bar or an edge runs AppKit's tracking loop inside sendEvent: frames stall meanwhile, as on Windows.
//  * Keys are read from the event (positional key codes, kVK_*); text comes from the event's characters, so there is no IME
//    or marked text (interpretKeyEvents is not used). Keys pressed with Command go to the menu as well (Command+Q quits:
//    it asks the program to close, as the close button does).
//  * begin_resize does nothing: a window without decorations is still resizable from its edges by the system.
//
// Untested without a Mac: written against Apple's documentation and the binding sources only.
// ---------------------------------------------------------------------------

_Native :: struct {
	ns_window:          ^NS.Window,
	view:               ^NS.View,
	layer:              ^CA.MetalLayer, // retained: the view's layer, what a backend draws into
	tracking:           ^NS.TrackingArea, // owned: tells when the mouse comes in and goes out
	allocator:          runtime.Allocator,
	scale:              f64, // backingScaleFactor
	visible:            bool,
	pending_maximize:   bool, // asked while hidden: done when it is shown
	pending_fullscreen: bool,
}

// What belongs to the application, not to one window.
@(private)
Cocoa :: struct {
	app:             ^NS.Application,
	ready:           bool,
	activated:       bool,
	window_class:    NS.Class, // IvSystemNSWindow: an NSWindow that can become key without a title bar
	window_delegate: ^NS.WindowDelegate, // one for all windows (it is told which window)
	app_delegate:    ^NS.ApplicationDelegate,
	windows:         [dynamic]^Window,
	mouse_down:      ^NS.Event, // retained: the last press of the left button (begin_move drags with it)
	cursor_hidden:   bool, // NSCursor hide / unhide are counted: hidden at most once
}

@(private)
cocoa: Cocoa

// [IvSystemNSWindow alloc]. (objc_send wants a class known when compiling, and this one is made at run time: the class
// method's implementation is called with its own prototype, which is what a message send does.)
@(private = "file")
alloc_window :: proc(class: NS.Class) -> ^NS.Window {
	Alloc :: #type proc "c" (class: NS.Class, sel: NS.SEL) -> ^NS.Window
	sel := intrinsics.objc_find_selector("alloc")
	imp := ObjC.class_getMethodImplementation(ObjC.object_getClass(cast(ObjC.id)class), sel) // (a class's class is its metaclass, where class methods are)
	if imp == nil {
		return nil
	}
	return (cast(Alloc)imp)(class, sel)
}

// ---- strings ------------------------------------------------------------------------------------------------------------

// An autoreleased NSString with a copy of `s`.
@(private = "file")
ns_string :: proc(s: string) -> ^NS.String {
	str := NS.String.alloc()->initWithBytes(raw_data(s), NS.UInteger(len(s)), NS.UTF8StringEncoding)
	return str->autorelease()
}

// A copy of an NSString in `allocator` ("" for nil).
@(private = "file")
odin_string :: proc(str: ^NS.String, allocator: runtime.Allocator) -> string {
	if str == nil {
		return ""
	}
	return strings.clone(str->odinString(), allocator)
}

// ---- the application ----------------------------------------------------------------------------------------------------

// The Quit menu item and the Dock's Quit ask every window to close (the program decides), instead of ending the process.
@(private = "file")
quit_action :: proc "c" (unused: rawptr, name: NS.SEL, sender: ^NS.Object) {
	context = runtime.default_context()
	for w in cocoa.windows {
		request_close(w)
	}
}

@(private = "file")
app_should_terminate :: proc(sender: ^NS.Application) -> NS.ApplicationTerminateReply {
	if len(cocoa.windows) == 0 {
		return .Now
	}
	for w in cocoa.windows {
		request_close(w)
	}
	return .Cancel
}

@(private = "file")
window_should_close :: proc(sender: ^NS.Window) -> bool {
	if w := window_of(sender); w != nil {
		request_close(w)
	}
	return false // the program closes it (destroy_window), or not
}

@(private = "file")
yes_proc :: proc "c" (self: NS.id, cmd: NS.SEL) -> bool {
	return true
}

// Sets up NSApplication once, for a plain executable (in an .app bundle or not): a regular application with a Dock icon and a
// menu bar, launched without [NSApp run].
@(private = "file")
ensure_app :: proc() -> bool {
	if cocoa.ready {
		return true
	}
	NS.scoped_autoreleasepool()
	app := NS.Application.sharedApplication()
	if app == nil {
		return false
	}
	cocoa.app = app
	app->setActivationPolicy(.Regular) // (an executable started from a terminal is a background program otherwise)

	cocoa.app_delegate = NS.application_delegate_register_and_alloc({applicationShouldTerminate = app_should_terminate}, "IvSystemApplicationDelegate", context)
	if cocoa.app_delegate != nil {
		app->setDelegate(cocoa.app_delegate)
	}
	cocoa.window_delegate = NS.window_delegate_register_and_alloc({windowShouldClose = window_should_close}, "IvSystemWindowDelegate", context)

	// an NSWindow without a title bar cannot become the key window (take the keyboard) unless its class says it can
	cls := ObjC.objc_allocateClassPair(intrinsics.objc_find_class("NSWindow"), "IvSystemNSWindow", 0)
	if cls != nil {
		ObjC.class_addMethod(cls, intrinsics.objc_find_selector("canBecomeKeyWindow"), auto_cast yes_proc, "B@:")
		ObjC.class_addMethod(cls, intrinsics.objc_find_selector("canBecomeMainWindow"), auto_cast yes_proc, "B@:")
		ObjC.objc_registerClassPair(cls)
	} else {
		cls = ObjC.objc_lookUpClass("IvSystemNSWindow")
	}
	cocoa.window_class = cls

	make_menu(app)
	app->finishLaunching()
	cocoa.ready = true
	return true
}

// The menu bar: the application menu (Hide, Hide Others, Show All, Quit) and a Window menu (Minimize, Zoom).
@(private = "file")
make_menu :: proc(app: ^NS.Application) {
	name := NS.ProcessInfo.processInfo()->processName()->odinString()
	bar := NS.Menu.alloc()->init()

	app_item := NS.MenuItem.alloc()->init()
	bar->addItem(app_item)
	app_menu := NS.Menu.alloc()->init()
	app_menu->addItemWithTitle(ns_string(strings.concatenate({"Hide ", name}, context.temp_allocator)), intrinsics.objc_find_selector("hide:"), NS.AT("h"))
	others := app_menu->addItemWithTitle(NS.AT("Hide Others"), intrinsics.objc_find_selector("hideOtherApplications:"), NS.AT("h"))
	others->setKeyEquivalentModifierMask({.Option, .Command})
	app_menu->addItemWithTitle(NS.AT("Show All"), intrinsics.objc_find_selector("unhideAllApplications:"), NS.AT(""))
	app_menu->addItem(NS.MenuItem.separatorItem())
	quit := NS.MenuItem.registerActionCallback("ivSystemQuit", quit_action)
	app_menu->addItemWithTitle(ns_string(strings.concatenate({"Quit ", name}, context.temp_allocator)), quit, NS.AT("q"))
	app_item->setSubmenu(app_menu)

	window_item := NS.MenuItem.alloc()->init()
	bar->addItem(window_item)
	window_menu := NS.Menu.alloc()->initWithTitle(NS.AT("Window"))
	window_menu->addItemWithTitle(NS.AT("Minimize"), intrinsics.objc_find_selector("performMiniaturize:"), NS.AT("m"))
	window_menu->addItemWithTitle(NS.AT("Zoom"), intrinsics.objc_find_selector("performZoom:"), NS.AT(""))
	window_item->setSubmenu(window_menu)

	app->setMainMenu(bar)
	app->setWindowsMenu(window_menu)
	// (the bar keeps what it was given)
	app_menu->release()
	app_item->release()
	window_menu->release()
	window_item->release()
	bar->release()
}

// Brings the application to the front, once (when its first window is shown).
@(private = "file")
activate_app :: proc() {
	if cocoa.activated {
		return
	}
	cocoa.activated = true
	if cocoa.app->respondsToSelector(intrinsics.objc_find_selector("activate")) {
		cocoa.app->activate() // macOS 14 and later
	} else {
		cocoa.app->activateIgnoringOtherApps(true)
	}
}

@(private = "file")
window_of :: proc "contextless" (ns_window: ^NS.Window) -> ^Window {
	if ns_window == nil {
		return nil
	}
	for w in cocoa.windows {
		if w.ns_window == ns_window {
			return w
		}
	}
	return nil
}

// ---- windows ------------------------------------------------------------------------------------------------------------

@(private = "file")
style_mask :: proc(flags: Window_Flags) -> NS.WindowStyleMask {
	style: NS.WindowStyleMask
	if .No_Decorations in flags {
		style = {.Miniaturizable} // borderless: no title bar, but it can still be minimized
	} else {
		style = {.Titled, .Closable, .Miniaturizable}
	}
	if .Fixed_Size not_in flags {
		style += {.Resizable} // (a borderless window that is resizable is resized from its edges by the system)
	}
	return style
}

// The scale the window will have before it exists: the main screen's.
@(private = "file")
main_screen_scale :: proc() -> f64 {
	if screen := NS.Screen.mainScreen(); screen != nil {
		return max(f64(screen->backingScaleFactor()), 1)
	}
	return 1
}

// Makes the NSWindow, its view and the view's CAMetalLayer.
@(private = "file")
make_ns_window :: proc(w: ^Window, desc: Window_Desc) -> bool {
	NS.scoped_autoreleasepool()
	w.desc = desc
	scale := main_screen_scale()
	points := NS.Rect{{0, 0}, {NS.Float(f64(max(desc.width, 1)) / scale), NS.Float(f64(max(desc.height, 1)) / scale)}}

	ns_window := alloc_window(cocoa.window_class)
	ns_window = ns_window->initWithContentRect_styleMask_backing_defer(points, style_mask(desc.flags), .Buffered, false)
	if ns_window == nil {
		return false
	}
	w.ns_window = ns_window
	ns_window->setReleasedWhenClosed(false) // destroy_window releases it
	if cocoa.window_delegate != nil {
		ns_window->setDelegate(cocoa.window_delegate)
	}
	ns_window->setTitle(ns_string(desc.title))
	ns_window->setAcceptsMouseMovedEvents(true)
	ns_window->setRestorable(false)
	ns_window->setTabbingMode(.Disallowed)
	ns_window->setCollectionBehavior({.Managed, .FullScreenPrimary})
	if c, ok := desc.background.?; ok {
		ns_window->setBackgroundColor(NS.Color.colorWithSRGBRed(NS.Float(c.r) / 255, NS.Float(c.g) / 255, NS.Float(c.b) / 255, 1))
	}
	if .Always_On_Top in desc.flags {
		ns_window->setLevel(NS.FloatingWindowLevel)
	}

	// the view hosts a CAMetalLayer (setLayer before setWantsLayer: a layer-hosting view), in pixels by contentsScale
	view := NS.View.alloc()->initWithFrame(points)
	layer := CA.MetalLayer.layer()
	layer->retain()
	layer->setContentsScale(CG.Float(scale))
	layer->setOpaque(true)
	view->setLayer(layer)
	view->setWantsLayer(true)
	tracking := NS.TrackingArea.alloc()->initWithRect({}, {.MouseEnteredAndExited, .ActiveAlways, .InVisibleRect}, view, nil)
	view->addTrackingArea(tracking)
	ns_window->setContentView(view)
	view->release() // (the window keeps it)
	w.view = view
	w.layer = layer
	w.tracking = tracking

	w.scale = 0
	w.size = {}
	w.visible = false
	w.pending_maximize = .Maximized in desc.flags
	w.pending_fullscreen = .Fullscreen in desc.flags
	set_size_limits(w)
	ns_window->center()
	append(&cocoa.windows, w)

	if .Hidden not_in desc.flags {
		show(w)
	}
	refresh(w)
	w.events = {} // what the creation itself stirred up is not news
	clear(&w.input)
	return true
}

// Orders the window in (and does what was asked for while it was hidden).
@(private = "file")
show :: proc(w: ^Window) {
	if .No_Activate in w.desc.flags {
		w.ns_window->orderFront(nil)
	} else {
		activate_app()
		w.ns_window->makeKeyAndOrderFront(nil)
	}
	w.visible = true
	if w.pending_maximize {
		w.pending_maximize = false
		if !w.ns_window->isZoomed() {
			w.ns_window->zoom(nil)
		}
	}
	if w.pending_fullscreen {
		w.pending_fullscreen = false
		if .FullScreen not_in w.ns_window->styleMask() {
			w.ns_window->toggleFullScreen(nil)
		}
	}
}

@(private = "file")
set_size_limits :: proc(w: ^Window) {
	scale := w.scale if w.scale > 0 else main_screen_scale()
	w.ns_window->setContentMinSize({NS.Float(f64(w.desc.min_width) / scale), NS.Float(f64(w.desc.min_height) / scale)})
}

// Takes the NSWindow away (the Window stays).
@(private = "file")
destroy_ns_window :: proc(w: ^Window) {
	NS.scoped_autoreleasepool()
	for other, i in cocoa.windows {
		if other == w {
			ordered_remove(&cocoa.windows, i)
			break
		}
	}
	if w.cursor_hidden && cocoa.cursor_hidden && w.mouse_inside {
		NS.Cursor.unhide()
		cocoa.cursor_hidden = false
	}
	if w.view != nil && w.tracking != nil {
		w.view->removeTrackingArea(w.tracking)
	}
	if w.tracking != nil {
		w.tracking->release()
	}
	if w.ns_window != nil {
		w.ns_window->setDelegate(nil)
		w.ns_window->orderOut(nil)
		w.ns_window->close()
		w.ns_window->release()
	}
	if w.layer != nil {
		w.layer->release()
	}
	w.ns_window, w.view, w.layer, w.tracking = nil, nil, nil, nil
}

// Reads what the window is now (size, scale, focus, minimized, zoomed, fullscreen) and reports what changed.
@(private = "file")
refresh :: proc(w: ^Window) {
	win := w.ns_window
	if win == nil {
		return
	}
	scale := max(f64(win->backingScaleFactor()), 1)
	if scale != w.scale {
		first := w.scale == 0
		w.scale = scale
		w.dpi_scale = f32(scale)
		w.layer->setContentsScale(CG.Float(scale)) // the drawable stays in pixels on the new screen
		set_size_limits(w)
		if !first {
			w.events += {.Dpi_Changed}
		}
	}
	bounds := w.view->bounds()
	size := [2]int{int(math.round(f64(bounds.size.width) * scale)), int(math.round(f64(bounds.size.height) * scale))}
	if size != w.size {
		w.size = size
		w.events += {.Resized}
	}

	focused := win->isKeyWindow()
	if focused != w.focused {
		w.focused = focused
		if focused {
			w.events += {.Focus_Gained}
		} else {
			w.events += {.Focus_Lost}
			queue_input(w, {kind = .Focus_Lost}) // nothing may stay held
		}
	}
	minimized := win->isMiniaturized()
	if minimized != w.minimized {
		w.minimized = minimized
		w.events += {.Minimized if minimized else .Restored}
	}
	w.fullscreen = .FullScreen in win->styleMask()
	if !minimized {
		w.maximized = !w.fullscreen && win->isZoomed()
	}
	w.decorated = !w.fullscreen && .No_Decorations not_in w.desc.flags
}

// ---- events -------------------------------------------------------------------------------------------------------------

// The mouse position of an event in client pixels (from the top left).
@(private = "file")
event_position :: proc(w: ^Window, e: ^NS.Event) -> (x, y: f32, inside: bool) {
	p := w.view->convertPoint_fromView(e->locationInWindow(), nil)
	bounds := w.view->bounds()
	inside = p.x >= 0 && p.y >= 0 && p.x < bounds.size.width && p.y < bounds.size.height
	return f32(f64(p.x) * w.scale), f32(f64(bounds.size.height - p.y) * w.scale), inside
}

@(private = "file")
mouse_button :: proc "contextless" (number: NS.Integer) -> input.Mouse_Button {
	switch number {
	case 0:
		return .Left
	case 1:
		return .Right
	case 2:
		return .Middle
	case 3:
		return .Back
	case 4:
		return .Forward
	}
	return .Extra
}

// The device-dependent modifier bits of NSEvent.modifierFlags (IOKit's NX_DEVICE*KEYMASK), which tell left from right.
@(private = "file")
modifier_mask :: proc "contextless" (code: u16) -> c.ulong {
	#partial switch NS.kVK(code) {
	case .Control:
		return 0x0001
	case .Shift:
		return 0x0002
	case .RightShift:
		return 0x0004
	case .Command:
		return 0x0008
	case .RightCommand:
		return 0x0010
	case .Option:
		return 0x0020
	case .RightOption:
		return 0x0040
	case .RightControl:
		return 0x2000
	case:
	}
	return 0
}

// Reads what an event means for the program (keys, mouse, text) and says whether AppKit should get it too.
@(private = "file")
handle_event :: proc(e: ^NS.Event) -> (forward: bool) {
	w := window_of(e->window())
	if w == nil {
		return true
	}
	type := e->type()
	#partial switch type {
	case .KeyDown, .KeyUp:
		code := e->keyCode()
		flags := e->modifierFlags()
		key := translate_key(code)
		if type == .KeyUp {
			if key != .None {
				queue_input(w, {kind = .Key_Up, key = key})
			}
			return false
		}
		repeat := e->isARepeat()
		if key != .None {
			queue_input(w, {kind = .Key_Repeat if repeat else .Key_Down, key = key})
		}
		// text: what the key types (not with Command or Control: those are shortcuts); the function keys type characters in
		// the private use area 0xF700 .. 0xF8FF, and the control characters are keys, not text
		if .Command not_in flags && .Control not_in flags {
			for r in e->characters()->odinString() {
				if r >= 32 && r != 127 && !(r >= 0xF700 && r <= 0xF8FF) {
					queue_input(w, {kind = .Char, char = r})
				}
			}
		}
		// with Command it is a key equivalent: the menu (Command+Q, Command+H, Command+M) has it too. Without, AppKit would only
		// beep (no view takes the keyboard)
		return .Command in flags

	case .FlagsChanged:
		code := e->keyCode()
		key := translate_key(code)
		if key == .None {
			return true
		}
		if NS.kVK(code) == .CapsLock { // one event per press (the lock toggles): a press and a release
			queue_input(w, {kind = .Key_Down, key = key})
			queue_input(w, {kind = .Key_Up, key = key})
			return true
		}
		down := transmute(c.ulong)e->modifierFlags() & modifier_mask(code) != 0
		queue_input(w, {kind = .Key_Down if down else .Key_Up, key = key})
		return true

	case .LeftMouseDown, .RightMouseDown, .OtherMouseDown:
		x, y, inside := event_position(w, e)
		if !inside {
			return true // the title bar, or outside: AppKit's
		}
		if type == .LeftMouseDown {
			if cocoa.mouse_down != nil {
				cocoa.mouse_down->release()
			}
			cocoa.mouse_down = e->retain()
			if w.hit_test != nil && w.hit_test(w, int(x), int(y), w.hit_test_user) == .Caption {
				// the program's title bar: what a title bar does, and the program sees nothing
				cocoa.app->sendEvent(e)
				if e->clickCount() == 2 {
					toggle_maximize(w)
				} else {
					w.ns_window->performWindowDragWithEvent(e)
				}
				return false
			}
		}
		queue_input(w, {kind = .Mouse_Move, x = x, y = y})
		queue_input(w, {kind = .Mouse_Down, button = mouse_button(e->buttonNumber())})
		return true

	case .LeftMouseUp, .RightMouseUp, .OtherMouseUp:
		x, y, _ := event_position(w, e)
		queue_input(w, {kind = .Mouse_Move, x = x, y = y})
		queue_input(w, {kind = .Mouse_Up, button = mouse_button(e->buttonNumber())})
		return true

	case .MouseMoved, .LeftMouseDragged, .RightMouseDragged, .OtherMouseDragged:
		x, y, inside := event_position(w, e)
		if inside != w.mouse_inside {
			w.mouse_inside = inside
			apply_cursor(w)
		} else if inside {
			apply_cursor(w) // (the title bar and the edges set cursors of their own)
		}
		if inside || NS.Event.pressedMouseButtons() != 0 {
			queue_input(w, {kind = .Mouse_Move, x = x, y = y})
		}
		return true

	case .MouseEntered, .MouseExited:
		w.mouse_inside = type == .MouseEntered
		apply_cursor(w)
		return true

	case .ScrollWheel:
		dx, dy := f64(e->scrollingDeltaX()), f64(e->scrollingDeltaY())
		if e->hasPreciseScrollingDeltas() {
			// a trackpad or a Magic Mouse: points, not lines (about 10 to a notch, as on Wayland)
			dx /= 10
			dy /= 10
		}
		// AppKit's y is already "away from the user is positive" (after the natural scrolling setting); its x is positive to the left
		if dx != 0 || dy != 0 {
			queue_input(w, {kind = .Wheel, x = f32(-dx), y = f32(dy)})
		}
		return true
	}
	return true
}

// ---- the API ------------------------------------------------------------------------------------------------------------

// Makes a window (and, the first time, sets the application up: Dock icon, menu bar). Fails only if AppKit does.
create_window :: proc(desc: Window_Desc, allocator := context.allocator) -> (w: ^Window, ok: bool) {
	if !ensure_app() {
		return nil, false
	}
	w = new(Window, allocator)
	w.allocator = allocator
	w.input = make([dynamic]Input_Event, allocator)
	if !make_ns_window(w, desc) {
		destroy_ns_window(w)
		delete(w.input)
		free(w, allocator)
		return nil, false
	}
	return w, true
}

destroy_window :: proc(w: ^Window) {
	if w == nil {
		return
	}
	destroy_ns_window(w)
	allocator := w.allocator
	delete(w.input)
	free(w, allocator)
}

// Makes the NSWindow again with the same title, size and state; the `^Window` stays the same. Anything that was made for the
// old layer (a swapchain) is gone and must be made again.
recreate_window :: proc(w: ^Window) -> bool {
	desc := w.desc
	desc.width, desc.height = w.size.x, w.size.y
	desc.flags -= {.Fullscreen, .Maximized, .Hidden}
	if w.fullscreen {
		desc.flags += {.Fullscreen}
	}
	if w.maximized {
		desc.flags += {.Maximized}
	}
	if !w.visible {
		desc.flags += {.Hidden}
	}
	destroy_ns_window(w)
	clear(&w.input)
	return make_ns_window(w, desc)
}

// Takes every event that is waiting (for all windows; never waits) and returns what happened to `w` since the last call. Its
// keys and mouse are queued for feed_input.
poll :: proc(w: ^Window) -> Window_Events {
	if cocoa.ready {
		NS.scoped_autoreleasepool()
		for {
			e := cocoa.app->nextEventMatchingMask(NS.EventMaskAny, NS.Date.distantPast(), NS.DefaultRunLoopMode, true)
			if e == nil {
				break
			}
			if handle_event(e) {
				cocoa.app->sendEvent(e)
			}
		}
		cocoa.app->updateWindows()
		for other in cocoa.windows {
			refresh(other)
		}
	}
	events := w.events
	w.events = {}
	return events
}

// Sleeps until an event arrives or `timeout` seconds have passed (< 0: no limit), whichever is first; then poll. (The event is
// left in the queue for poll.)
wait_events :: proc(w: ^Window, timeout: f64) {
	if !cocoa.ready || len(w.input) > 0 || w.events != {} {
		return
	}
	NS.scoped_autoreleasepool()
	until := NS.Date.distantFuture() if timeout < 0 else NS.Date.dateWithTimeIntervalSinceNow(NS.TimeInterval(timeout))
	cocoa.app->nextEventMatchingMask(NS.EventMaskAny, until, NS.DefaultRunLoopMode, false)
}

// (Window_Desc.background is the NSWindow's background colour, which the layer covers once something is drawn.)
stop_background :: proc(w: ^Window) {}

set_title :: proc(w: ^Window, title: string) {
	NS.scoped_autoreleasepool()
	w.desc.title = title // not copied: keep it alive (a literal is fine)
	w.ns_window->setTitle(ns_string(title))
}

// Fullscreen in its own Space, the system's way (an animation: w.fullscreen changes when it is done, see poll).
set_fullscreen :: proc(w: ^Window, on: bool) {
	if !w.visible {
		w.pending_fullscreen = on
		return
	}
	if on != (.FullScreen in w.ns_window->styleMask()) {
		w.ns_window->toggleFullScreen(nil)
	}
}

// Sets the client size in pixels (it is turned into points by the window's scale). Ignored in fullscreen.
set_size :: proc(w: ^Window, width, height: int) {
	if w.fullscreen || w.ns_window == nil {
		return
	}
	scale := w.scale if w.scale > 0 else 1
	w.ns_window->setContentSize({NS.Float(f64(max(width, 1)) / scale), NS.Float(f64(max(height, 1)) / scale)})
	refresh(w)
}

// Lets the user move the window with the left button that is down now (AppKit takes over until it is released).
begin_move :: proc(w: ^Window) {
	if cocoa.mouse_down != nil && w.ns_window != nil {
		w.ns_window->performWindowDragWithEvent(cocoa.mouse_down)
	}
}

// AppKit has no way to start a resize from the program; a resizable window without decorations is resized from its edges by
// the system itself, so there is nothing to do here.
begin_resize :: proc(w: ^Window, edge: Resize_Edge) {
}

set_visible :: proc(w: ^Window, visible: bool) {
	if visible == w.visible {
		return
	}
	if visible {
		show(w)
	} else {
		w.ns_window->orderOut(nil)
		w.visible = false
	}
}

// Zooms the window (the green button's "fill the screen" without fullscreen). w.maximized follows at the next poll.
maximize :: proc(w: ^Window) {
	if !w.visible {
		w.pending_maximize = true
		return
	}
	if !w.ns_window->isZoomed() {
		w.ns_window->zoom(nil)
	}
}

// Back from minimized, or from zoomed to the size before.
restore :: proc(w: ^Window) {
	w.pending_maximize = false
	if w.ns_window->isMiniaturized() {
		w.ns_window->deminiaturize(nil)
	} else if w.ns_window->isZoomed() {
		w.ns_window->zoom(nil)
	}
}

minimize :: proc(w: ^Window) {
	w.ns_window->miniaturize(nil)
}

// The title bar and border, or none (the .No_Decorations flag).
set_decorated :: proc(w: ^Window, on: bool) {
	if on {
		w.desc.flags -= {.No_Decorations}
	} else {
		w.desc.flags += {.No_Decorations}
	}
	if !w.fullscreen {
		w.ns_window->setStyleMask(style_mask(w.desc.flags))
		w.ns_window->setTitle(ns_string(w.desc.title)) // (a style change can lose the title)
	}
	w.decorated = !w.fullscreen && on
}

// Lets the user resize the window, or not (the .Fixed_Size flag).
set_resizable :: proc(w: ^Window, on: bool) {
	if on {
		w.desc.flags -= {.Fixed_Size}
	} else {
		w.desc.flags += {.Fixed_Size}
	}
	style := w.ns_window->styleMask()
	if on {
		style += {.Resizable}
	} else {
		style -= {.Resizable}
	}
	w.ns_window->setStyleMask(style)
}

// Above the other windows (the floating window level), or back among them.
set_always_on_top :: proc(w: ^Window, on: bool) {
	if on {
		w.desc.flags += {.Always_On_Top}
	} else {
		w.desc.flags -= {.Always_On_Top}
	}
	w.ns_window->setLevel(NS.FloatingWindowLevel if on else NS.NormalWindowLevel)
}

// ---- the mouse cursor ----

// Sets the cursor of the window's shape while the mouse is over the client area, hidden if the program asked for that.
@(private = "file")
apply_cursor :: proc(w: ^Window) {
	hide := w.cursor_hidden && w.mouse_inside
	if hide != cocoa.cursor_hidden {
		if hide {
			NS.Cursor.hide()
		} else {
			NS.Cursor.unhide()
		}
		cocoa.cursor_hidden = hide
	}
	if !w.mouse_inside {
		return
	}
	cursor: ^NS.Cursor
	switch w.cursor_shape {
	case .Default:
		cursor = NS.Cursor.arrowCursor()
	case .Hand:
		cursor = NS.Cursor.pointingHandCursor()
	case .Text:
		cursor = NS.Cursor.IBeamCursor()
	case .Crosshair:
		cursor = NS.Cursor.crosshairCursor()
	case .Resize_Horizontal:
		cursor = NS.Cursor.resizeLeftRightCursor()
	}
	cursor->set()
}

set_cursor_visible :: proc(w: ^Window, visible: bool) {
	w.cursor_hidden = !visible
	apply_cursor(w)
}

set_cursor_shape :: proc(w: ^Window, shape: Cursor_Shape) {
	w.cursor_shape = shape
	apply_cursor(w)
}

// Moves the pointer to (x, y) in client pixels. (Quartz's global coordinates have their origin at the top left of the main
// display, Cocoa's screen coordinates at its bottom left.)
set_mouse_position :: proc(w: ^Window, x, y: int) -> bool {
	if w.ns_window == nil || w.scale <= 0 {
		return false
	}
	bounds := w.view->bounds()
	p := NS.Point{NS.Float(f64(x) / w.scale), bounds.size.height - NS.Float(f64(y) / w.scale)}
	in_window := w.view->convertPoint_toView(p, nil)
	on_screen := w.ns_window->convertPointToScreen(in_window)
	main_height := CG.Float(CG.DisplayPixelsHigh(CG.MainDisplayID()))
	if screens := NS.Screen.screens(); screens != nil && screens->count() > 0 {
		main_height = (^NS.Screen)(screens->objectAtIndex(0))->frame().size.height // (the first screen is the one with the menu bar: the origin's)
	}
	if CG.WarpMouseCursorPosition({on_screen.x, main_height - on_screen.y}) != .Success {
		return false
	}
	CG.AssociateMouseAndMouseCursorPosition(true) // (a warp stops the pointer for a moment otherwise)
	return true
}

// ---- the clipboard (the general NSPasteboard) ----

clipboard_text :: proc(w: ^Window, allocator := context.allocator) -> (text: string, ok: bool) {
	NS.scoped_autoreleasepool()
	str := NS.Pasteboard.generalPasteboard()->stringForType(NS.PasteboardTypeString)
	if str == nil {
		return "", false
	}
	return odin_string(str, allocator), true
}

set_clipboard_text :: proc(w: ^Window, text: string) -> bool {
	NS.scoped_autoreleasepool()
	board := NS.Pasteboard.generalPasteboard()
	board->clearContents()
	return board->setString(ns_string(text), NS.PasteboardTypeString)
}

// ---- the file dialogs (NSOpenPanel, NSSavePanel; modal: they block until they are closed) ----

@(private = "file")
file_url :: proc(path: string, is_dir: bool) -> ^NS.URL {
	return NS.URL.fileURLWithPath_isDirectory(ns_string(path), is_dir)
}

@(private = "file")
open_panel :: proc(title, dir: string, folders: bool, allocator: runtime.Allocator) -> (path: string, ok: bool) {
	if !ensure_app() {
		return "", false
	}
	NS.scoped_autoreleasepool()
	panel := NS.OpenPanel.openPanel()
	panel->setCanChooseDirectories(folders)
	panel->setCanChooseFiles(!folders)
	panel->setAllowsMultipleSelection(false)
	panel->setCanCreateDirectories(folders)
	panel->setMessage(ns_string(title)) // (a panel's title is not shown on current macOS; its message is)
	panel->setTitle(ns_string(title))
	if dir != "" {
		panel->setDirectoryURL(file_url(dir, true))
	}
	if panel->runModal() != NS.ModalResponseOK {
		return "", false
	}
	urls := panel->URLs()
	if urls == nil || urls->count() == 0 {
		return "", false
	}
	url := (^NS.URL)(urls->objectAtIndex(0))
	path = odin_string(url->path(), allocator)
	return path, path != ""
}

// Asks the user for a folder (it blocks until the panel is closed). Returns the folder's full path (the caller owns the
// string), or false if it was cancelled.
pick_folder :: proc(w: ^Window, title: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return open_panel(title, "", true, allocator)
}

// Asks the user where to save a file. `suggested` is the name it starts with ("" for none), `dir` the folder it opens in
// ("" lets macOS choose). The panel asks before replacing a file. Returns the full path, or false if it was cancelled.
pick_save_file :: proc(w: ^Window, title, suggested, dir: string, allocator := context.allocator) -> (path: string, ok: bool) {
	if !ensure_app() {
		return "", false
	}
	NS.scoped_autoreleasepool()
	panel := NS.SavePanel.savePanel()
	panel->setCanCreateDirectories(true)
	panel->setMessage(ns_string(title))
	panel->setTitle(ns_string(title))
	if suggested != "" {
		panel->setNameFieldStringValue(ns_string(suggested))
	}
	if dir != "" {
		panel->setDirectoryURL(file_url(dir, true))
	}
	if panel->runModal() != NS.ModalResponseOK {
		return "", false
	}
	url := panel->URL()
	if url == nil {
		return "", false
	}
	path = odin_string(url->path(), allocator)
	return path, path != ""
}

// Asks the user for a program (any file: macOS programs have no extension of their own, an .app is a folder the panel opens
// as a file only when it is chosen). `dir` is the folder it opens in.
pick_program :: proc(w: ^Window, title, dir: string, allocator := context.allocator) -> (path: string, ok: bool) {
	return open_panel(title, dir, false, allocator)
}

// ---- message boxes (NSAlert, modal) ----

// Asks whether to save unsaved changes, with Save / Don't Save / Cancel.
ask_save_changes :: proc(w: ^Window, title, text: string) -> (answer: Save_Answer, ok: bool) {
	if !ensure_app() {
		return .Cancel, false
	}
	NS.scoped_autoreleasepool()
	alert := NS.Alert.alloc()->init()
	defer alert->release()
	alert->setAlertStyle(.Warning)
	alert->setMessageText(ns_string(title))
	alert->setInformativeText(ns_string(text))
	alert->addButtonWithTitle(NS.AT("Save"))
	alert->addButtonWithTitle(NS.AT("Don't Save"))
	cancel := alert->addButtonWithTitle(NS.AT("Cancel"))
	cancel->setKeyEquivalent(NS.AT("\x1b"))
	switch alert->runModal() {
	case NS.AlertFirstButtonReturn:
		return .Save, true
	case NS.AlertSecondButtonReturn:
		return .Discard, true
	}
	return .Cancel, true
}

// A question with Yes and No (a warning). No is the default (Return), as on Windows.
ask_yes_no :: proc(w: ^Window, title, text: string) -> (yes: bool, ok: bool) {
	if !ensure_app() {
		return false, false
	}
	NS.scoped_autoreleasepool()
	alert := NS.Alert.alloc()->init()
	defer alert->release()
	alert->setAlertStyle(.Warning)
	alert->setMessageText(ns_string(title))
	alert->setInformativeText(ns_string(text))
	yes_button := alert->addButtonWithTitle(NS.AT("Yes"))
	no_button := alert->addButtonWithTitle(NS.AT("No"))
	yes_button->setKeyEquivalent(NS.AT(""))
	no_button->setKeyEquivalent(NS.AT("\r"))
	return alert->runModal() == NS.AlertFirstButtonReturn, true
}

// ---- the Finder ----

// Shows `path` in the Finder: a folder is opened; a file's folder is opened with the file selected.
show_in_file_manager :: proc(path: string, is_dir: bool) -> bool {
	NS.scoped_autoreleasepool()
	workspace := NS.Workspace.sharedWorkspace()
	if is_dir {
		return workspace->openURL_(file_url(path, true))
	}
	workspace->activateFileViewerSelectingURLs(NS.Array.arrayWithObject(file_url(path, false)))
	return true
}

// To do: starting a program with a command line (posix_spawn, with the arguments split as a shell would). Not done yet, as on
// Linux.
run_program :: proc(program, args: string) -> bool {
	return false
}

// Moves a file or a folder (with what is in it) to the Trash, where the Finder can put it back from.
move_to_trash :: proc(path: string) -> bool {
	NS.scoped_autoreleasepool()
	return NS.FileManager.defaultManager()->trashItemAtURL_error(NS.URL.fileURLWithPath_(ns_string(path)), nil, nil) // (the URL asks the disk whether it is a folder)
}

// ---- the system's fonts ----
// What is installed is asked of NSFontManager, and a family's bytes are read from the file Core Text says the font is in.

// The installed font families (the caller owns the names and the slice).
list_font_families :: proc(allocator := context.allocator) -> []Font_Family {
	NS.scoped_autoreleasepool()
	manager := NS.FontManager.sharedFontManager()
	families := manager->availableFontFamilies()
	if families == nil {
		return nil
	}
	list := make([dynamic]Font_Family, 0, int(families->count()), allocator)
	for i in 0 ..< families->count() {
		name := (^NS.String)(families->objectAtIndex(i))
		if name == nil {
			continue
		}
		font := manager->fontWithFamily(name, {}, 5, 12) // 5: the regular weight
		append(&list, Font_Family{name = odin_string(name, allocator), monospace = font != nil && font->isFixedPitch()})
	}
	return list[:]
}

// The bytes of a family's regular (or bold) face: the whole font file. A face that lives in a collection (.ttc) comes as the
// whole collection (whose first face is used, which may not be this one). false if the family is not installed or its
// file cannot be read (some system fonts have no file a program may read).
font_data :: proc(family: string, bold := false, allocator := context.allocator) -> (data: []u8, ok: bool) {
	if family == "" {
		return nil, false
	}
	NS.scoped_autoreleasepool()
	traits: NS.FontTraitMask = {.BoldFontMask} if bold else {}
	font := NS.FontManager.sharedFontManager()->fontWithFamily(ns_string(family), traits, 9 if bold else 5, 64)
	if font == nil {
		return nil, false
	}
	// an NSFont is a CTFont (toll-free bridged)
	url := CF.URLRef(CT.FontCopyAttribute(CT.FontRef(rawptr(font)), CT.kFontURLAttribute))
	if url == nil {
		return nil, false
	}
	defer CF.Release(CF.TypeRef(url))
	buf: [1024]u8
	if !CF.URLGetFileSystemRepresentation(url, true, &buf[0], len(buf)) {
		return nil, false
	}
	bytes, err := os.read_entire_file_from_path(string(cstring(&buf[0])), allocator)
	if err != nil {
		return nil, false
	}
	return bytes, true
}

// ---- gamepads (the GameController framework) ----
// The pads with an extended gamepad profile (Xbox, PlayStation, Switch Pro and the like), in the order the framework lists
// them. The framework finds pads while the run loop runs, which poll does.

read_gamepads :: proc(pads: ^[input.MAX_PADS]Pad_State) {
	NS.scoped_autoreleasepool()
	controllers := GC.Controller.controllers()
	if controllers == nil {
		return
	}
	slot := 0
	for i in 0 ..< controllers->count() {
		if slot >= input.MAX_PADS {
			break
		}
		g := (^GC.Controller)(controllers->objectAtIndex(i))->extendedGamepad()
		if g == nil {
			continue
		}
		p := &pads[slot]
		slot += 1
		p.connected = true
		// (a button the pad does not have is nil, and a message to nil answers false / 0)
		p.buttons[.Face_Down] = g->buttonA()->isPressed()
		p.buttons[.Face_Right] = g->buttonB()->isPressed()
		p.buttons[.Face_Left] = g->buttonX()->isPressed()
		p.buttons[.Face_Up] = g->buttonY()->isPressed()
		p.buttons[.Left_Shoulder] = g->leftShoulder()->isPressed()
		p.buttons[.Right_Shoulder] = g->rightShoulder()->isPressed()
		p.buttons[.Back] = g->buttonOptions()->isPressed()
		p.buttons[.Start] = g->buttonMenu()->isPressed()
		p.buttons[.Guide] = g->buttonHome()->isPressed()
		p.buttons[.Left_Stick] = g->leftThumbstickButton()->isPressed()
		p.buttons[.Right_Stick] = g->rightThumbstickButton()->isPressed()
		dpad := g->dpad()
		p.buttons[.Dpad_Up] = dpad->up()->isPressed()
		p.buttons[.Dpad_Down] = dpad->down()->isPressed()
		p.buttons[.Dpad_Left] = dpad->left()->isPressed()
		p.buttons[.Dpad_Right] = dpad->right()->isPressed()
		// the framework's y points up; iv_input's down
		left, right := g->leftThumbstick(), g->rightThumbstick()
		p.axes[.Left_X] = f32(left->xAxis()->value())
		p.axes[.Left_Y] = -f32(left->yAxis()->value())
		p.axes[.Right_X] = f32(right->xAxis()->value())
		p.axes[.Right_Y] = -f32(right->yAxis()->value())
		p.axes[.Left_Trigger] = f32(g->leftTrigger()->value())
		p.axes[.Right_Trigger] = f32(g->rightTrigger()->value())
		p.buttons[.Left_Trigger] = p.axes[.Left_Trigger] > 0.5
		p.buttons[.Right_Trigger] = p.axes[.Right_Trigger] > 0.5
	}
}

// For whoever draws into the window: the CAMetalLayer of the window's view (window) and the NSView (display).
native_handle :: proc(w: ^Window) -> Native_Handle {
	return {window = rawptr(w.layer), display = rawptr(w.view)}
}

// Seconds since some fixed point (a monotonic clock: the system's uptime): for timing frames.
time_seconds :: proc() -> f64 {
	return f64(NS.ProcessInfo.processInfo()->systemUptime())
}

// ---- keys ----

// The key of a virtual key code (Carbon's kVK_*, which are positions on the keyboard: kVK_ANSI_A is where A is on a US layout).
@(private = "file")
translate_key :: proc "contextless" (code: u16) -> input.Key {
	if code == 0x6E { // kVK_ContextualMenu (not in the binding's list)
		return .Menu
	}
	#partial switch NS.kVK(code) {
	case .ANSI_A: return .A
	case .ANSI_B: return .B
	case .ANSI_C: return .C
	case .ANSI_D: return .D
	case .ANSI_E: return .E
	case .ANSI_F: return .F
	case .ANSI_G: return .G
	case .ANSI_H: return .H
	case .ANSI_I: return .I
	case .ANSI_J: return .J
	case .ANSI_K: return .K
	case .ANSI_L: return .L
	case .ANSI_M: return .M
	case .ANSI_N: return .N
	case .ANSI_O: return .O
	case .ANSI_P: return .P
	case .ANSI_Q: return .Q
	case .ANSI_R: return .R
	case .ANSI_S: return .S
	case .ANSI_T: return .T
	case .ANSI_U: return .U
	case .ANSI_V: return .V
	case .ANSI_W: return .W
	case .ANSI_X: return .X
	case .ANSI_Y: return .Y
	case .ANSI_Z: return .Z
	case .ANSI_0: return .Num_0
	case .ANSI_1: return .Num_1
	case .ANSI_2: return .Num_2
	case .ANSI_3: return .Num_3
	case .ANSI_4: return .Num_4
	case .ANSI_5: return .Num_5
	case .ANSI_6: return .Num_6
	case .ANSI_7: return .Num_7
	case .ANSI_8: return .Num_8
	case .ANSI_9: return .Num_9
	case .F1: return .F1
	case .F2: return .F2
	case .F3: return .F3
	case .F4: return .F4
	case .F5: return .F5
	case .F6: return .F6
	case .F7: return .F7
	case .F8: return .F8
	case .F9: return .F9
	case .F10: return .F10
	case .F11: return .F11
	case .F12: return .F12
	case .F13: return .F13
	case .F14: return .F14
	case .F15: return .F15
	case .F16: return .F16
	case .F17: return .F17
	case .F18: return .F18
	case .F19: return .F19
	case .F20: return .F20
	case .Escape: return .Escape
	case .Return: return .Enter
	case .Tab: return .Tab
	case .Space: return .Space
	case .Delete: return .Backspace // (the Mac's "delete" is the key left of it)
	case .ForwardDelete: return .Delete
	case .Help: return .Insert // (where a PC keyboard has Insert)
	case .Home: return .Home
	case .End: return .End
	case .PageUp: return .Page_Up
	case .PageDown: return .Page_Down
	case .LeftArrow: return .Left
	case .RightArrow: return .Right
	case .UpArrow: return .Up
	case .DownArrow: return .Down
	case .Shift: return .Left_Shift
	case .RightShift: return .Right_Shift
	case .Control: return .Left_Ctrl
	case .RightControl: return .Right_Ctrl
	case .Option: return .Left_Alt
	case .RightOption: return .Right_Alt
	case .Command: return .Left_Super
	case .RightCommand: return .Right_Super
	case .CapsLock: return .Caps_Lock
	case .ANSI_Quote: return .Apostrophe
	case .ANSI_Comma: return .Comma
	case .ANSI_Minus: return .Minus
	case .ANSI_Period: return .Period
	case .ANSI_Slash: return .Slash
	case .ANSI_Semicolon: return .Semicolon
	case .ANSI_Equal: return .Equal
	case .ANSI_LeftBracket: return .Left_Bracket
	case .ANSI_Backslash: return .Backslash
	case .ANSI_RightBracket: return .Right_Bracket
	case .ANSI_Grave: return .Grave
	case .ANSI_Keypad0: return .Kp_0
	case .ANSI_Keypad1: return .Kp_1
	case .ANSI_Keypad2: return .Kp_2
	case .ANSI_Keypad3: return .Kp_3
	case .ANSI_Keypad4: return .Kp_4
	case .ANSI_Keypad5: return .Kp_5
	case .ANSI_Keypad6: return .Kp_6
	case .ANSI_Keypad7: return .Kp_7
	case .ANSI_Keypad8: return .Kp_8
	case .ANSI_Keypad9: return .Kp_9
	case .ANSI_KeypadDecimal: return .Kp_Decimal
	case .ANSI_KeypadDivide: return .Kp_Divide
	case .ANSI_KeypadMultiply: return .Kp_Multiply
	case .ANSI_KeypadMinus: return .Kp_Subtract
	case .ANSI_KeypadPlus: return .Kp_Add
	case .ANSI_KeypadEnter: return .Kp_Enter
	case .ANSI_KeypadEquals: return .Kp_Equal
	case .ANSI_KeypadClear: return .Num_Lock // (the Mac keypad's Clear is where Num Lock is)
	}
	return .None
}
