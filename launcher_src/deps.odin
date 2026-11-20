// What the launcher needs on the computer, how it finds each, and how it installs what is missing.
//   C compiler  builds the game from the bundled sources: clang only, on every system (on Windows a MinGW one, LLVM-MinGW
//               or MSYS2's clang64: the runtime needs pthreads and the D3D9 import library; Visual C++ cannot build it
//               yet). GCC is not taken: every build is the same compiler's, the one the game is tested with. Probed by compiling and running a
//               small program, so a compiler that is there but cannot build this is not taken.
//   FFmpeg      encodes the movies (Convert Movies: libx264 + aac). Playing them needs no FFmpeg program: the game
//               links FFmpeg's libraries statically (third_party/ffmpeg, bundled)
// Installs: Windows winget (per user: no administrator), Linux the distribution's package manager (always as
// administrator: pkexec asks), macOS Xcode's command line tools and Homebrew (neither needs administrator).
// A dependency whose install needs administrator says so on its button, and only that program is elevated.
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

Dep_Kind :: enum {
	Compiler,
	FFmpeg,
}

Dep :: struct {
	name:        string,
	purpose:     string,
	path:        string, // found: the program
	note:        string, // what was found, or why not
	can_encode:  bool, // FFmpeg: has libx264 and aac
	install:     []string, // the install command (nil: cannot install it automatically)
	install_how: string, // what the button says happens
	needs_admin: bool,
}

deps_mutex: sync.Mutex
deps: [Dep_Kind]Dep
deps_checked: bool

// Every C compiler that can build the game (Clang first: it makes the faster game). The Options tab chooses one
// (settings.compiler); deps[.Compiler] is the one chosen.
Compiler :: struct {
	path:  string,
	clang: bool,
	label: string, // what the Options tab lists: "Clang (Best)", "GCC", ...
}
compilers: [dynamic]Compiler

compilers_get :: proc(allocator := context.temp_allocator) -> []Compiler {
	sync.mutex_lock(&deps_mutex)
	defer sync.mutex_unlock(&deps_mutex)
	return slice.clone(compilers[:], allocator)
}

// The compiler to use: the one in the settings if it still works, else the best (and the settings remember it).
choose_compiler :: proc() {
	sync.mutex_lock(&deps_mutex)
	defer sync.mutex_unlock(&deps_mutex)
	if len(compilers) == 0 {return}
	pick := compilers[0]
	for c in compilers {if c.path == settings.compiler {pick = c}}
	if settings.compiler != pick.path {
		settings.compiler = strings.clone(pick.path)
		save_settings()
	}
	deps[.Compiler].path = pick.path
	deps[.Compiler].note = pick.path
}

// The Options tab picked another compiler.
select_compiler :: proc(path: string) {
	settings.compiler = strings.clone(path)
	save_settings()
	choose_compiler()
}

dep_get :: proc(k: Dep_Kind) -> Dep {
	sync.mutex_lock(&deps_mutex)
	defer sync.mutex_unlock(&deps_mutex)
	return deps[k]
}
@(private = "file")
dep_set :: proc(k: Dep_Kind, d: Dep) {
	sync.mutex_lock(&deps_mutex)
	defer sync.mutex_unlock(&deps_mutex)
	deps[k] = d
}

// ---------------------------------------------------------------------------------------------- the compiler
PROBE_C :: `#include <pthread.h>
#include <stdio.h>
#include <xmmintrin.h>
#ifdef _WIN32
#include <windows.h>
#include <d3d9.h>
#endif
static void *f(void *p) { return p; }
int main(void) {
	pthread_t t;
	pthread_create(&t, 0, f, 0);
	pthread_join(t, 0);
#ifdef _WIN32
	if (!&Direct3DCreate9) return 2;
#endif
	printf("ok %d\n", (int)_mm_cvtss_f32(_mm_sqrt_ss(_mm_set_ss(16.0f))));
	return 0;
}
`

// the flags every compile of the game uses for the target (x86-64 only: the translation uses SSE)
when ODIN_OS == .Darwin {
	@(rodata) ARCH_FLAGS := []string{"-arch", "x86_64"} // (Apple silicon: built for Intel, run by Rosetta 2)
} else {
	@(rodata) ARCH_FLAGS := []string{"-m64"}
}
// what FFmpeg's static libraries need of the system (TLS for libavformat's https: Schannel / OpenSSL 3 /
// SecureTransport, plus the VideoToolbox hwaccel's frameworks on macOS); the game only reads local files
when ODIN_OS == .Windows {
	@(rodata) FFMPEG_SYS_LIBS := []string{"-lws2_32", "-lsecur32", "-lcrypt32", "-lncrypt", "-lbcrypt"}
} else when ODIN_OS == .Darwin {
	@(rodata) FFMPEG_SYS_LIBS := []string{"-framework", "Security", "-framework", "CoreFoundation", "-framework", "CoreMedia", "-framework", "CoreVideo", "-framework", "VideoToolbox", "-framework", "CoreServices"}
} else {
	@(rodata) FFMPEG_SYS_LIBS := []string{"-l:libssl.so.3", "-l:libcrypto.so.3"}
}
when ODIN_OS == .Windows {
	// (--image-base: the exe above guest memory, which is at a fixed address from 0x7fff0000 to 0x17fff0000: src/include/xrc.h)
	@(rodata) LINK_LIBS := []string{"-static", "-Wl,--image-base,0x200000000", "-pthread", "-ld3d9", "-ldinput8", "-ldxguid", "-lole32", "-loleaut32", "-luuid", "-luser32", "-lgdi32", "-lwinmm", "-lm"}
} else {
	@(rodata) LINK_LIBS := []string{"-pthread", "-lm", "-ldl"} // (-ldl: Vulkan and SDL2 are loaded at run time)
}
// a cross build's (cross.odin: Linux targets): FFmpeg's OpenSSL, and the game's own
@(rodata) CROSS_LINUX_SYS_LIBS := []string{"-l:libssl.so.3", "-l:libcrypto.so.3", "-pthread", "-lm", "-ldl"}
arch_flags :: proc() -> []string {return ARCH_FLAGS}
link_libs :: proc() -> []string {return LINK_LIBS}

@(private = "file")
compiler_candidates :: proc() -> [dynamic]string {
	c := make([dynamic]string, context.temp_allocator)
	add :: proc(c: ^[dynamic]string, p: string) {if p != "" {append(c, p)}}
	when ODIN_OS == .Windows {
		for n in ([]string{"x86_64-w64-mingw32-clang", "clang"}) {add(&c, find_program(n))}
		// winget's llvm-mingw (not on this process's PATH right after it was installed)
		la := os.get_env("LOCALAPPDATA", context.temp_allocator)
		pk := pjoin({la, "Microsoft", "WinGet", "Packages"}, context.temp_allocator)
		if list, err := os.read_all_directory_by_path(pk, context.temp_allocator); err == nil {
			for e in list {
				if !strings.has_prefix(e.name, "MartinStorsjo.LLVM-MinGW") {continue}
				if sub, serr := os.read_all_directory_by_path(e.fullpath, context.temp_allocator); serr == nil {
					for s in sub {
						p := pjoin({s.fullpath, "bin", "x86_64-w64-mingw32-clang.exe"}, context.temp_allocator)
						if file_exists(p) {append(&c, p)}
					}
				}
			}
		}
		for p in ([]string{`C:\msys64\ucrt64\bin\clang.exe`, `C:\msys64\clang64\bin\clang.exe`}) {
			if file_exists(p) {append(&c, p)}
		}
	} else {
		for n in ([]string{"clang", "cc"}) {add(&c, find_program(n))} // (cc: macOS's is clang; a GCC one is left out below)
	}
	return c
}

// Compiles and runs the probe with cc. why: what went wrong.
@(private = "file")
probe_compiler :: proc(t: ^Task, cc: string) -> (ok: bool, why: string) {
	dir := data_path("probe")
	_ = os.make_directory_all(dir)
	src := pjoin({dir, "probe.c"}, context.temp_allocator)
	exe := pjoin({dir, strings.concatenate({"probe", EXE_SUFFIX}, context.temp_allocator)}, context.temp_allocator)
	_ = os.remove(exe)
	if os.write_entire_file(src, transmute([]u8)string(PROBE_C)) != nil {return false, "cannot write in the launcher's folder"}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, cc)
	append(&args, ..arch_flags())
	append(&args, "-O0", src, "-o", exe)
	append(&args, ..link_libs())
	out := strings.builder_make(context.temp_allocator)
	code, started := run(t, args[:], mode = .Quiet, capture = &out)
	if !started {return false, "it does not start"}
	if why := child_failure(code); why != "" {return false, why}
	if code != 0 {
		s := strings.to_string(out)
		first, _, _ := strings.partition(s, "\n")
		return false, fmt.tprintf("it cannot build the game (%s)", strings.trim_space(first))
	}
	res := strings.builder_make(context.temp_allocator)
	code, started = run(t, {exe}, mode = .Quiet, capture = &res)
	if why := child_failure(code); started && why != "" {return false, fmt.tprintf("the programs it makes do not run here (%s)", why)}
	if !started || code != 0 || !strings.has_prefix(strings.to_string(res), "ok 4") {return false, "the programs it makes do not run here"}
	return true, ""
}

@(private = "file")
check_compiler :: proc(t: ^Task) -> Dep {
	d := Dep{name = "C compiler", purpose = "builds the game from the bundled sources"}
	tried := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	found := make([dynamic]Compiler)
	versions := make(map[string]bool, context.temp_allocator) // (cc and gcc are often the same program)
	for cc in compiler_candidates() {
		key := strings.to_lower(cc, context.temp_allocator)
		if key in seen {continue}
		seen[key] = true
		ok, why := probe_compiler(t, cc)
		if !ok {
			append(&tried, fmt.tprintf("%s: %s", filepath.base(cc), why))
			continue
		}
		ver := strings.builder_make(context.temp_allocator)
		_, _ = run(t, {cc, "--version"}, mode = .Quiet, capture = &ver)
		v := strings.to_string(ver)
		// the same compiler under another name (cc / gcc): its version text without the name it starts with
		_, _, key_v := strings.partition(v, " ")
		if key_v != "" && key_v in versions {continue}
		versions[strings.clone(key_v, context.temp_allocator)] = true
		if !strings.contains(v, "clang") {
			append(&tried, fmt.tprintf("%s: GCC (the game is built with Clang only)", filepath.base(cc)))
			continue
		}
		append(&found, Compiler{path = strings.clone(cc), clang = strings.contains(v, "clang")})
	}
	if len(found) > 0 {
		for &c in found {c.label = len(found) > 1 ? fmt.aprintf("Clang — %s", c.path) : strings.clone("Clang")}
		sync.mutex_lock(&deps_mutex)
		compilers = found
		sync.mutex_unlock(&deps_mutex)
		d.path = found[0].path
		d.note = found[0].path
		return d
	}
	sync.mutex_lock(&deps_mutex)
	clear(&compilers)
	sync.mutex_unlock(&deps_mutex)
	when ODIN_OS == .Windows {
		if find_program("cl") != "" {append(&tried, "Visual C++ (cl) is installed, but it cannot build the game yet (it needs clang)")}
	}
	if len(tried) == 0 {
		d.note = "none found"
	} else {
		d.note = strings.clone(strings.join(tried[:], "; ", context.temp_allocator))
	}
	when ODIN_OS == .Windows {
		if wg := find_program("winget"); wg != "" {
			d.install = clone_cmd({wg, "install", "--id", "MartinStorsjo.LLVM-MinGW.UCRT", "-e", "--scope", "user", "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"})
			d.install_how = "Install LLVM-MinGW (winget)"
		}
	} else when ODIN_OS == .Darwin {
		d.install = clone_cmd({"/usr/bin/xcode-select", "--install"})
		d.install_how = "Install Apple's command line tools"
	} else {
		pm, cmd := linux_install_cmd("compiler")
		if pm != "" {
			d.install = cmd
			d.install_how = fmt.aprintf("Install Clang (%s)", pm)
			d.needs_admin = true
		}
	}
	return d
}

// ---------------------------------------------------------------------------------------------- FFmpeg
@(private = "file")
ffmpeg_candidates :: proc() -> [dynamic]string {
	c := make([dynamic]string, context.temp_allocator)
	if p := find_program("ffmpeg"); p != "" {append(&c, p)}
	when ODIN_OS == .Windows {
		la := os.get_env("LOCALAPPDATA", context.temp_allocator)
		home := os.get_env("USERPROFILE", context.temp_allocator)
		for p in ([]string{
				pjoin({la, "Microsoft", "WinGet", "Links", "ffmpeg.exe"}, context.temp_allocator),
				`C:\ProgramData\chocolatey\bin\ffmpeg.exe`,
				pjoin({home, "scoop", "shims", "ffmpeg.exe"}, context.temp_allocator),
			}) {
			if file_exists(p) {append(&c, p)}
		}
		pk := pjoin({la, "Microsoft", "WinGet", "Packages"}, context.temp_allocator)
		if list, err := os.read_all_directory_by_path(pk, context.temp_allocator); err == nil {
			for e in list {
				if !strings.has_prefix(e.name, "Gyan.FFmpeg") {continue}
				if sub, serr := os.read_all_directory_by_path(e.fullpath, context.temp_allocator); serr == nil {
					for s in sub {
						p := pjoin({s.fullpath, "bin", "ffmpeg.exe"}, context.temp_allocator)
						if file_exists(p) {append(&c, p)}
					}
				}
			}
		}
	} else when ODIN_OS == .Darwin {
		for p in ([]string{"/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"}) {if file_exists(p) {append(&c, p)}}
	}
	return c
}

@(private = "file")
check_ffmpeg :: proc(t: ^Task) -> Dep {
	d := Dep{name = "FFmpeg", purpose = "converts the movies (the game plays them without it)"}
	// the launcher's own (the Windows bundle: tools/ffmpeg.exe, unpacked with the converter by Build and Convert Movies)
	if bundle_has("tools/ffmpeg.exe") {
		d.path = strings.clone(data_path("tools", "ffmpeg.exe"))
		d.note = "included with the launcher"
		d.can_encode = true
		return d
	}
	fallback := ""
	for p in ffmpeg_candidates() {
		out := strings.builder_make(context.temp_allocator)
		code, started := run(t, {p, "-hide_banner", "-encoders"}, mode = .Quiet, capture = &out)
		if !started || code != 0 {continue}
		s := strings.to_string(out)
		if strings.contains(s, " libx264 ") && strings.contains(s, " aac ") {
			d.path = strings.clone(p)
			d.note = strings.clone(p)
			d.can_encode = true
			return d
		}
		if fallback == "" {fallback = p}
	}
	if fallback != "" {
		// it plays the MP4s, but cannot make them
		d.path = strings.clone(fallback)
		d.note = fmt.aprintf("%s (it has no H.264 encoder: it cannot convert the movies)", fallback)
	} else {
		d.note = "not found"
	}
	when ODIN_OS == .Windows {
		if wg := find_program("winget"); wg != "" {
			d.install = clone_cmd({wg, "install", "--id", "Gyan.FFmpeg", "-e", "--scope", "user", "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"})
			d.install_how = "Install FFmpeg (winget)"
		}
	} else when ODIN_OS == .Darwin {
		brew := ""
		for p in ([]string{"/opt/homebrew/bin/brew", "/usr/local/bin/brew"}) {if file_exists(p) {brew = p}}
		if brew != "" {
			d.install = clone_cmd({brew, "install", "ffmpeg"})
			d.install_how = "Install FFmpeg (Homebrew)"
		} else {
			d.install_how = "Install Homebrew (brew.sh) first, then FFmpeg"
		}
	} else {
		pm, cmd := linux_install_cmd("ffmpeg")
		if pm != "" {
			d.install = cmd
			d.install_how = fmt.aprintf("Install FFmpeg (%s)", pm)
			d.needs_admin = true
		}
	}
	return d
}

// ---------------------------------------------------------------------------------------------- installing
@(private = "file")
clone_cmd :: proc(cmd: []string) -> []string {
	out := make([]string, len(cmd))
	for s, i in cmd {out[i] = strings.clone(s)}
	return out
}

// The distribution's package manager and the command that installs what: "compiler" or "ffmpeg".
@(private = "file")
linux_install_cmd :: proc(what: string) -> (pm: string, cmd: []string) {
	if p := find_program("apt-get"); p != "" {
		if what == "compiler" {return "apt", clone_cmd({p, "install", "-y", "clang", "libc6-dev"})}
		return "apt", clone_cmd({p, "install", "-y", "ffmpeg"})
	}
	if p := find_program("dnf"); p != "" {
		return "dnf", clone_cmd({p, "install", "-y", what == "compiler" ? "clang" : "ffmpeg-free"})
	}
	if p := find_program("pacman"); p != "" {
		return "pacman", clone_cmd({p, "-S", "--needed", "--noconfirm", what == "compiler" ? "clang" : "ffmpeg"})
	}
	if p := find_program("zypper"); p != "" {
		return "zypper", clone_cmd({p, "--non-interactive", "install", what == "compiler" ? "clang" : "ffmpeg"})
	}
	return "", nil
}

check_deps_task :: proc(t: ^Task) {
	set_status(t, -1, "Looking for C compilers")
	dep_set(.Compiler, check_compiler(t))
	choose_compiler()
	set_status(t, -1, "Looking for FFmpeg")
	dep_set(.FFmpeg, check_ffmpeg(t))
	for k in Dep_Kind {
		d := dep_get(k)
		logf(t, "%s: %s", d.name, d.note)
	}
	sync.atomic_store(&deps_checked, true)
	set_status(t, 1, "Checked what is installed")
}

// Installs one dependency (task user = the Dep_Kind), then checks again.
install_dep_task :: proc(t: ^Task) {
	k := Dep_Kind(uintptr(t.user))
	d := dep_get(k)
	if d.install == nil {return}
	set_status(t, -1, "%s", d.install_how)
	code: int
	started: bool
	if d.needs_admin {
		code, started = run_elevated(t, d.install)
	} else {
		code, started = run(t, d.install)
	}
	if !started || code != 0 {
		if started {logf(t, "The install ended with code %d.", code)}
		t.failed = true
	}
	when ODIN_OS == .Darwin {
		if k == .Compiler {log_line(t, "Finish the installer Apple opened, then press Check again.")}
	}
	check_deps_task(t)
}
