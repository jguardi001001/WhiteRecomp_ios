// The software (CPU) backend of `ren`: NOT WRITTEN. The package exists so that its place is clear (and so that nothing can
// import it by mistake): importing it does not compile.
//
// When it is written it rasterizes the Draw_List on the CPU, is the reference every other backend is compared against
// (the parity tests), can draw to memory with no window (Native_Surface{kind = .None}) and shows its pixels through the
// platform's present_pixels (see iv_system/README.md). Then ren/auto adds its factory and ren.DEFAULT_ORDER lists
// .Software last.
package ren_software

#panic("iv_system/ren/software: the software backend is not written yet")
