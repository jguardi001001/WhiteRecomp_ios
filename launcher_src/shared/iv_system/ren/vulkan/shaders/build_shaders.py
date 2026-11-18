#!/usr/bin/env python3
"""
Assembles the SPIR-V of the Vulkan backend's shaders into shaders.odin.

Why this exists: the shaders are tiny, and writing them in SPIR-V assembly (the *.spvasm files next to this script, one
file per shader, with the GLSL they implement in the *.vert / *.frag files for reference) means that nothing but Python is
needed to build them: no Vulkan SDK, no glslc. If you have glslc, `glslc ui.vert -o ui.vert.spv` etc. produce equivalent
modules and you may load those instead.

Usage (from anywhere):  python build_shaders.py

The assembler understands exactly the subset of SPIR-V the shaders use:
    [%result =] OpName [operands...]
  operands: %id, an integer, f32:<float>, "a string", or a name from ENUMS (Shader, Logical, GLSL450, Location, ...).
"""
import os
import re
import struct
import sys

# opcode -> (number, has result type, has result id)
OPS = {
    "OpExtInstImport": (11, False, True),
    "OpExtInst": (12, True, True),
    "OpMemoryModel": (14, False, False),
    "OpEntryPoint": (15, False, False),
    "OpExecutionMode": (16, False, False),
    "OpCapability": (17, False, False),
    "OpTypeVoid": (19, False, True),
    "OpTypeInt": (21, False, True),
    "OpTypeFloat": (22, False, True),
    "OpTypeVector": (23, False, True),
    "OpTypeImage": (25, False, True),
    "OpTypeSampledImage": (27, False, True),
    "OpTypeStruct": (30, False, True),
    "OpTypePointer": (32, False, True),
    "OpTypeFunction": (33, False, True),
    "OpConstant": (43, True, True),
    "OpFunction": (54, True, True),
    "OpFunctionEnd": (56, False, False),
    "OpVariable": (59, True, True),
    "OpLoad": (61, True, True),
    "OpStore": (62, False, False),
    "OpAccessChain": (65, True, True),
    "OpDecorate": (71, False, False),
    "OpMemberDecorate": (72, False, False),
    "OpCompositeConstruct": (80, True, True),
    "OpCompositeExtract": (81, True, True),
    "OpCompositeInsert": (82, True, True),
    "OpImageSampleImplicitLod": (87, True, True),
    "OpFAdd": (129, True, True),
    "OpFSub": (131, True, True),
    "OpFMul": (133, True, True),
    "OpFwidth": (209, True, True),
    "OpLabel": (248, False, True),
    "OpReturn": (253, False, False),
}

ENUMS = {
    # capability
    "Shader": 1,
    # addressing / memory model
    "Logical": 0,
    "GLSL450": 1,
    # execution model / mode
    "Vertex": 0,
    "Fragment": 4,
    "OriginUpperLeft": 7,
    # storage class
    "UniformConstant": 0,
    "Input": 1,
    "Output": 3,
    "PushConstant": 9,
    # decoration
    "Block": 2,
    "BuiltIn": 11,
    "Location": 30,
    "Binding": 33,
    "DescriptorSet": 34,
    "Offset": 35,
    # builtin
    "Position": 0,
    # function control, image dim / format
    "None": 0,
    "2D": 1,
    "Unknown": 0,
    # GLSL.std.450 instructions
    "FMax": 40,
    "SmoothStep": 49,
}

TOKEN = re.compile(r'"[^"]*"|\S+')


def pack_string(s):
    b = s.encode("utf-8") + b"\0"
    while len(b) % 4:
        b += b"\0"
    return list(struct.unpack("<%dI" % (len(b) // 4), b))


def assemble(text, name):
    ids = {}

    def ident(token):
        if token not in ids:
            ids[token] = len(ids) + 1
        return ids[token]

    words = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split(";")[0].strip()
        if not line:
            continue
        tokens = TOKEN.findall(line)
        result = None
        if len(tokens) >= 2 and tokens[1] == "=":
            result = tokens[0]
            tokens = tokens[2:]
        op = tokens[0]
        if op not in OPS:
            sys.exit("%s:%d: unknown instruction %s" % (name, lineno, op))
        number, has_type, has_result = OPS[op]
        if has_result != (result is not None):
            sys.exit("%s:%d: %s %s a result" % (name, lineno, op, "needs" if has_result else "has no"))
        operands = tokens[1:]
        body = []
        if has_type:
            body.append(ident(operands.pop(0)))
        if has_result:
            body.append(ident(result))
        for t in operands:
            if t.startswith("%"):
                body.append(ident(t))
            elif t.startswith('"'):
                body.extend(pack_string(t[1:-1]))
            elif t.startswith("f32:"):
                body.append(struct.unpack("<I", struct.pack("<f", float(t[4:])))[0])
            elif t in ENUMS:
                body.append(ENUMS[t])
            else:
                try:
                    body.append(int(t))
                except ValueError:
                    sys.exit("%s:%d: cannot read operand %s" % (name, lineno, t))
        # an ExtInst's instruction number is an operand like the others (already looked up above)
        words.append(((len(body) + 1) << 16) | number)
        words.extend(body)

    header = [0x07230203, 0x00010000, 0, len(ids) + 1, 0]
    return header + words


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    shaders = [
        ("VERTEX_SPV", "ui.vert.spvasm"),
        ("FRAGMENT_TEXTURED_SPV", "ui_textured.frag.spvasm"),
        ("FRAGMENT_COVERAGE_SPV", "ui_coverage.frag.spvasm"),
        ("FRAGMENT_SDF_SPV", "ui_sdf.frag.spvasm"),
    ]
    out = [
        "package ren_vulkan",
        "",
        "// GENERATED by shaders/build_shaders.py from shaders/*.spvasm. Do not edit: change the .spvasm and run the script.",
        "// SPIR-V 1.0 modules, as 32-bit words.",
        "",
    ]
    for const, filename in shaders:
        with open(os.path.join(here, filename), encoding="utf-8") as f:
            words = assemble(f.read(), filename)
        out.append("%s := [%d]u32{" % (const, len(words)))
        for i in range(0, len(words), 8):
            out.append("\t" + ", ".join("0x%08X" % w for w in words[i : i + 8]) + ",")
        out.append("}")
        out.append("")
    target = os.path.join(here, "..", "shaders.odin")
    with open(target, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))
    print("wrote", os.path.normpath(target))


if __name__ == "__main__":
    main()
