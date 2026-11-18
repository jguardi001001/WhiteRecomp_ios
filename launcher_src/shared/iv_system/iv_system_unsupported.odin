#+build !windows
#+build !linux
package iv_system

// iv_system makes a ren.Native_Surface from the platform's window per operating system (iv_system_windows.odin,
// iv_system_linux.odin). Any other operating system has no platform layer yet.
#panic("iv_system: this operating system is not supported yet (Windows and Linux/Wayland only)")
