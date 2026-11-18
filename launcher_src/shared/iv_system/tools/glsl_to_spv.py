#!/usr/bin/env python3
"""
glsl_to_spv.py: GLSL fragment shaders written the way raylib's are  ->  SPIR-V for ren's custom shaders, as an Odin file.

A raylib fragment shader (`#version 330`) has loose uniforms and `in` / `out` variables with no locations:

    #version 330
    in vec2 fragTexCoord;
    in vec4 fragColor;
    out vec4 finalColor;
    uniform sampler2D texture0;
    uniform float dt;
    uniform vec4 storms[8];

Vulkan has no loose uniforms, so this script rewrites the shader (line for line, so that the compiler's messages name the
lines of the original) into what ren.Shader_Desc describes:

    layout(location = 0) in vec2 fragTexCoord;          (fragTexCoord is location 0, fragColor is location 1)
    layout(location = 0) out vec4 finalColor;
    layout(set = 1, binding = 0) uniform sampler2D texture0;    (sampler2Ds in the order they are declared)
    layout(scalar, set = 0, binding = 0) uniform Uniforms { float dt; vec4 storms[8]; };   (every other uniform, scalar layout)

compiles it with glslang (-V, Vulkan 1.3) and writes, for a shader file `gas_sim.fs`:

    GAS_SIM_SPV        :: [N]u32{...}
    Gas_Sim_Uniforms   :: struct { dt: f32, storms: [8][4]f32 }   (laid out like C: that is what scalar layout means)
    Gas_Sim_Sampler    :: enum { texture0, ... }                  (the index of each sampler2D: the order of draw_shader's textures)
    GAS_SIM_UNIFORM_SIZE, GAS_SIM_SAMPLER_COUNT

Usage:  python glsl_to_spv.py --package main --out shaders_spv.odin  a.fs b.fs ...
The compiler is glslang (Khronos), found in tools/glslang/bin next to this script, or in $GLSLANG.
"""
import argparse
import os
import re
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

GL_TYPES = {  # GLSL type -> (Odin type, number of 4-byte components)
    "float": ("f32", 1), "int": ("i32", 1), "uint": ("u32", 1), "bool": ("b32", 1),
    "vec2": ("[2]f32", 2), "vec3": ("[3]f32", 3), "vec4": ("[4]f32", 4),
    "ivec2": ("[2]i32", 2), "ivec3": ("[3]i32", 3), "ivec4": ("[4]i32", 4),
    "uvec2": ("[2]u32", 2), "uvec3": ("[3]u32", 3), "uvec4": ("[4]u32", 4),
    "bvec2": ("[2]b32", 2), "bvec3": ("[3]b32", 3), "bvec4": ("[4]b32", 4),
    "mat2": ("[4]f32", 4), "mat3": ("[9]f32", 9), "mat4": ("[16]f32", 16),
}
ODIN_KEYWORDS = {
    "asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue", "defer", "distinct", "do",
    "dynamic", "else", "enum", "fallthrough", "for", "foreign", "if", "import", "in", "map", "matrix", "not_in", "or_break",
    "or_continue", "or_else", "or_return", "package", "proc", "return", "struct", "switch", "transmute", "typeid", "union",
    "using", "when", "where",
}
IN_LOCATIONS = {"fragTexCoord": 0, "fragColor": 1}

UNIFORM = re.compile(r"^(\s*)uniform\s+(\w+)\s+(\w+)\s*(\[\s*([^\]]+?)\s*\])?\s*;(.*)$")
IN_VAR = re.compile(r"^(\s*)in\s+(\w+)\s+(\w+)\s*;(.*)$")
OUT_VAR = re.compile(r"^(\s*)out\s+(\w+)\s+(\w+)\s*;(.*)$")


def find_glslang():
    env = os.environ.get("GLSLANG")
    if env:
        return env
    for name in ("glslang.exe", "glslang", "glslangValidator.exe", "glslangValidator"):
        p = os.path.join(HERE, "glslang", "bin", name)
        if os.path.exists(p):
            return p
    sys.exit("glslang not found (tools/glslang/bin, or set GLSLANG)")


def constants(text):
    """The integer constants of the shader (#define N 8, const int N = 8;), for the sizes of arrays."""
    values = {}
    for m in re.finditer(r"^\s*#define\s+(\w+)\s+(\d+)\s*(?://.*)?$", text, re.M):
        values[m.group(1)] = int(m.group(2))
    for m in re.finditer(r"^\s*const\s+int\s+(\w+)\s*=\s*(\d+)\s*;", text, re.M):
        values[m.group(1)] = int(m.group(2))
    return values


def array_length(expr, values, shader):
    expr = expr.strip()
    if expr.isdigit():
        return int(expr)
    try:
        return int(eval(expr, {"__builtins__": {}}, values))
    except Exception:
        sys.exit("%s: cannot work out the array size [%s]" % (shader, expr))


def convert(text, shader):
    """-> (vulkan glsl, [(glsl type, name, length or None)], [sampler names])"""
    values = constants(text)
    lines = text.splitlines()
    uniforms, samplers, outs = [], [], 0
    block_line = None
    for i, line in enumerate(lines):
        if line.strip().startswith("#version"):
            lines[i] = "#version 450\n#extension GL_EXT_scalar_block_layout : require\n#line 2"
            continue
        m = UNIFORM.match(line)
        if m:
            indent, typ, name, _, length, rest = m.groups()
            if typ == "sampler2D":
                lines[i] = "%slayout(set = 1, binding = %d) uniform sampler2D %s;%s" % (indent, len(samplers), name, rest)
                samplers.append(name)
            elif typ in GL_TYPES:
                uniforms.append((typ, name, array_length(length, values, shader) if length else None))
                if block_line is None:
                    block_line = i
                lines[i] = rest.strip()
            else:
                sys.exit("%s: line %d: a uniform of type %s is not supported" % (shader, i + 1, typ))
            continue
        m = IN_VAR.match(line)
        if m:
            indent, typ, name, rest = m.groups()
            if name not in IN_LOCATIONS:
                sys.exit("%s: line %d: `in %s %s`: only fragTexCoord and fragColor come from the vertex shader" % (shader, i + 1, typ, name))
            lines[i] = "%slayout(location = %d) in %s %s;%s" % (indent, IN_LOCATIONS[name], typ, name, rest)
            continue
        m = OUT_VAR.match(line)
        if m:
            indent, typ, name, rest = m.groups()
            lines[i] = "%slayout(location = %d) out %s %s;%s" % (indent, outs, typ, name, rest)
            outs += 1
            continue
    if uniforms:
        members = " ".join("%s %s%s;" % (t, n, "[%d]" % l if l is not None else "") for t, n, l in uniforms)
        lines[block_line] = "layout(scalar, set = 0, binding = 0) uniform Uniforms { %s };" % members + lines[block_line]
    return "\n".join(lines) + "\n", uniforms, samplers


def compile_spv(source, shader, glslang):
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "shader.frag")
        out = os.path.join(tmp, "shader.spv")
        with open(src, "w", encoding="utf-8", newline="\n") as f:
            f.write(source)
        proc = subprocess.run([glslang, "-V", "--target-env", "vulkan1.3", "-S", "frag", "-o", out, src], capture_output=True, text=True)
        if proc.returncode != 0:
            sys.stderr.write(proc.stdout + proc.stderr)
            sys.exit("%s: glslang failed (line numbers are those of the original file)" % shader)
        data = open(out, "rb").read()
    return list(struct.unpack("<%dI" % (len(data) // 4), data))


def camel(name):
    return "_".join(p.capitalize() for p in name.split("_"))


def odin_name(name):
    return name + "_" if name in ODIN_KEYWORDS else name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("shaders", nargs="+")
    args = ap.parse_args()
    glslang = find_glslang()

    out = [
        "package %s" % args.package, "",
        "// GENERATED by iv_system/tools/glsl_to_spv.py from: %s" % ", ".join(os.path.basename(s) for s in args.shaders),
        "// Do not edit: change the shader and run the script again.", "",
    ]
    for path in args.shaders:
        base = os.path.splitext(os.path.basename(path))[0]
        upper, title = base.upper(), camel(base)
        text = open(path, encoding="utf-8").read()
        glsl, uniforms, samplers = convert(text, os.path.basename(path))
        words = compile_spv(glsl, os.path.basename(path), glslang)
        out.append("%s_SPV := [%d]u32{" % (upper, len(words)))
        for i in range(0, len(words), 8):
            out.append("\t" + ", ".join("0x%08X" % w for w in words[i:i + 8]) + ",")
        out.append("}")
        out.append("")
        if uniforms:
            out.append("%s_Uniforms :: struct {" % title)
            for t, n, l in uniforms:
                odin_t = GL_TYPES[t][0]
                out.append("\t%s: %s," % (odin_name(n), "[%d]%s" % (l, odin_t) if l is not None else odin_t))
            out.append("}")
            out.append("")
            out.append("%s_UNIFORM_SIZE :: size_of(%s_Uniforms)" % (upper, title))
        else:
            out.append("%s_UNIFORM_SIZE :: 0" % upper)
        out.append("%s_SAMPLER_COUNT :: %d" % (upper, len(samplers)))
        if samplers:
            out.append("%s_Sampler :: enum {" % title)
            for n in samplers:
                out.append("\t%s," % odin_name(n))
            out.append("}")
        out.append("")
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))
    print("wrote", args.out, "(%d shaders)" % len(args.shaders))


if __name__ == "__main__":
    main()
