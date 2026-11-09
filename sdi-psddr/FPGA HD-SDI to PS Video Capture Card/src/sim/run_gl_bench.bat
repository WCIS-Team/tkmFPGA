@echo off
rem ==========================================================================
rem  run_gl_bench.bat -- gate-level simulation of sdi_stream_wr.
rem
rem  Behavioural RTL cannot see memory-inference bugs at all (a Verilog array
rem  always reads asynchronously, a RAMB18E1 never does), and it cannot see a
rem  byte-order bug either. This runs the real synthesised netlist against the
rem  real Xilinx primitive models, with the same data-content checking
rem  testbench used for the RTL runs.
rem
rem  This is only a wrapper. The real work is in run_gl_bench.ps1 -- cmd
rem  quoting cannot survive this many nested file lists.
rem
rem  Usage:  run_gl_bench.bat  [cycles]      (default 200000, = suite B_LAT_32)
rem ==========================================================================

setlocal
set CYCLES=%1
if "%CYCLES%"=="" set CYCLES=200000

powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0run_gl_bench.ps1" -Cycles %CYCLES%
exit /b %ERRORLEVEL%