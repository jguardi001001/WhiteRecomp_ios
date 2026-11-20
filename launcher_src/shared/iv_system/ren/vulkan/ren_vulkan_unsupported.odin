#+build !windows
#+build !linux
#+build !darwin
package ren_vulkan

// The Vulkan backend has an operating-system file for each window system it can make surfaces for
// (ren_vulkan_windows.odin: Win32; ren_vulkan_linux.odin: Wayland; ren_vulkan_darwin.odin: CAMetalLayer, through MoltenVK).
// Any other operating system has none yet.
#panic("iv_system/ren/vulkan: this operating system is not supported yet (Windows, Linux/Wayland and macOS only)")
