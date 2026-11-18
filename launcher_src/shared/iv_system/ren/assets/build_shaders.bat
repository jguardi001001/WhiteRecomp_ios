@echo off
rem Compiles the GLSL of ren\assets\shaders into SPIR-V (shaders_spv.odin, next to this file) with iv_system\tools\glsl_to_spv.py (needs Python;
rem glslang is in iv_system\tools\glslang). Run this after changing a shader here, then add it to BUILTIN_SHADERS in builtin.odin.
python "%~dp0..\..\tools\glsl_to_spv.py" --package ren_assets --out "%~dp0shaders_spv.odin" ^
  "%~dp0shaders\bloom_extract.fs" "%~dp0shaders\blur.fs" "%~dp0shaders\bloom_combine.fs" "%~dp0shaders\neon.fs"
