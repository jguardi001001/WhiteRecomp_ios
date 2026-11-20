#+build !windows
#+build !linux
#+build !darwin
package platform

// iv_system/platform has a Windows part (platform_windows.odin, Win32), a Linux part (platform_linux.odin, Wayland only) and a
// macOS part (platform_darwin.odin, Cocoa). Any other operating system has no part yet, so it does not compile: the
// alternative, a window layer that quietly does nothing, would be found at run time.
#panic("iv_system/platform: this operating system is not supported yet (Windows, Linux/Wayland and macOS only)")
