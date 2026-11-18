#!/usr/bin/env python3
"""Generates a `main` package that runs the @(test) procedures of Odin packages without the test runner (Odin cannot link a
test runner when cross-compiling to Linux from Windows, but it can compile a normal program to objects).
usage: gen_harness.py <outdir> <import-path>=<file-glob-suffix> [...]
  e.g. gen_harness.py out iv_system/platform:platform_tests_linux.odin iv_system/ren/vulkan:ren_vulkan_test.odin
"""
import os
import re
import sys

SHARED = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))  # the shared folder

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
imports = []
runs = []
for i, spec in enumerate(sys.argv[2:]):
    pkg, files = spec.split(":", 1)
    alias = "p%d" % i
    imports.append('import %s "shared:%s"' % (alias, pkg))
    for fname in files.split(","):
        text = open(os.path.join(SHARED, *pkg.split("/"), fname), encoding="utf-8").read()
        for m in re.finditer(r"@\(test\)\s*\n(\w+)\s*::", text):
            runs.append((alias, m.group(1)))

src = """package main

import "core:fmt"
import "core:log"
import "core:testing"
%s

errors_in_test: int

counting_logger :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	if level >= .Error {
		errors_in_test += 1
	}
	if level >= .Info {
		fmt.printfln("    [%%v] %%s", level, text)
	}
}

run :: proc(name: string, p: proc(^testing.T), failed: ^int) {
	errors_in_test = 0
	t: testing.T
	p(&t)
	free_all(context.temp_allocator)
	if errors_in_test > 0 {
		fmt.printfln("FAIL  %%s (%%d errors)", name, errors_in_test)
		failed^ += 1
	} else {
		fmt.printfln("ok    %%s", name)
	}
}

main :: proc() {
	context.logger = log.Logger{counting_logger, nil, .Info, {}}
	failed := 0
%s
	fmt.printfln("%%d tests, %%d failed", %d, failed)
}
""" % ("\n".join(imports), "\n".join('\trun("%s", %s.%s, &failed)' % (a + "." + n, a, n) for a, n in runs), len(runs))
open(os.path.join(out, "main.odin"), "w", encoding="utf-8").write(src)
print("wrote", len(runs), "tests")
