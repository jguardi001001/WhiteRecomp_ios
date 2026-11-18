// The OpenGL backend of `ren`: NOT WRITTEN. The package exists so that its place is clear (and so that nothing can import
// it by mistake and get a backend that silently is not there): importing it does not compile.
//
// When it is written it is a ren.Factory like ren/vulkan's (probe without a window, create from a Native_Surface), with
// `fresh_window = true` where the window system ties a window to one graphics API (Windows' SetPixelFormat), it needs the
// platform's GL context calls (gl_create_context, gl_swap: see iv_system/README.md), and it draws exactly what the Vulkan
// backend draws (same materials, same blend maths, UNORM colours). Then ren/auto adds its factory and ren.DEFAULT_ORDER
// lists .OpenGL after .Vulkan.
package ren_opengl

#panic("iv_system/ren/opengl: the OpenGL backend is not written yet")
