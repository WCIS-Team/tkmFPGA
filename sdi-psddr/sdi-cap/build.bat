@echo off
rem build.bat -- compile the SDI capture card bitstream.
rem
rem   build.bat              full build (synth + impl + bitstream)
rem   build.bat synth        synth only, fast sanity check (~15 min)
rem   build.bat full         full build with the U6/U5 GT reference clock pair
rem
rem   build.bat synth full 8  synth only, full variant, 8 jobs
rem
rem Output lands in dist\ . The log is vivado.log in this directory.

setlocal

set SYNTH_ONLY=0
set BOARD_VARIANT=lite
set JOBS=4

if /I "%~1"=="synth"  set SYNTH_ONLY=1
if /I "%~1"=="full"  set BOARD_VARIANT=full
if /I "%~2"=="synth" set SYNTH_ONLY=1
if /I "%~2"=="full" set BOARD_VARIANT=full
if not "%~3"==""     set JOBS=%~3
if not "%~4"==""     set JOBS=%~4

echo variant=%BOARD_VARIANT%  synth_only=%SYNTH_ONLY%  jobs=%JOBS%

call "S:\apps\Xilinx\Vivado\2018.3\bin\vivado.bat" -mode batch -nojournal -source "%~dp0build.tcl"
echo.
echo vivado exit code = %ERRORLEVEL%

endlocal