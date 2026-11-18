@echo off
rem Builds the sound editor optimized and runs it.
rem
rem   build.bat              build and run
rem   build.bat song.psng    build and open a file
rem   build.bat --selftest   build and run the checks
rem
rem Always build with -o:speed: the synthesizer renders about five times faster than in the
rem default build that "odin run" makes, which is what makes WAV export fast.
rem (It can be run from any folder; the editor is written to snd_editor.exe in the folder you run it from.)
rem The shared packages (iv_snd, iv_ui, iv_input, iv_input/raylib) are in the "shared" collection, two folders above this one.
odin build %~dp0. -o:speed -collection:shared=%~dp0..\.. -out:snd_editor.exe
if errorlevel 1 exit /b 1
snd_editor.exe %*
