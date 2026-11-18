#+build !windows
#+build !linux
package platform

// iv_system/platform has a Windows part (platform_windows.odin, Win32) and a Linux part (platform_linux.odin, Wayland only).
// Any other operating system has no part yet, so it does not compile: the alternative, a window layer that quietly does
// nothing, would be found at run time. (macOS: platform_darwin.odin, Cocoa; not written.)
#panic("iv_system/platform: this operating system is not supported yet (Windows and Linux/Wayland only)")
