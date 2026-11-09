@echo off
REM ============================================================================
REM run_bench.bat -- sdi_stream_wr 吞吐 / 协议 / 环回绕 回归
REM
REM 用法：
REM   run_bench.bat                 跑默认扫描
REM   run_bench.bat full            跑完整扫描（含 B_LAT / W_LAT / RING 三组）
REM
REM 依赖：Vivado 2018.3 的 xvlog / xelab / xsim（在 PATH 或用绝对路径）。
REM 产物：当前目录下 run.log（每次覆盖）。
REM
REM 参数从 bench.txt 读。**不用 +testplusarg**：Windows 上 xsim.bat 的参数
REM 转发会把 "B_LAT=12" 在 "=" 处劈开，报 "Expected a switch but found 12"。
REM ============================================================================
setlocal

set XVLOG=C:\Users\takomi\AppData\Local\Temp\opencode\sdi_sim\xvlog.bat
if exist "C:\apps\Xilinx\Vivado\2018.3\bin\xvlog.bat" set XVLOG=C:\apps\Xilinx\Vivado\2018.3\bin\xvlog.bat
if exist "S:\apps\Xilinx\Vivado\2018.3\bin\xvlog.bat" set XVLOG=S:\apps\Xilinx\Vivado\2018.3\bin\xvlog.bat

set XELAB=%XVLOG:xvlog.bat=xelab.bat%
set XSIM=%XVLOG:xvlog.bat=xsim.bat%

set RTL=%~dp0..\rtl\cap\sdi_stream_wr.v
set TB=%~dp0tb_sdi_stream_wr.v

if not exist inc mkdir inc
if not exist defs.vh (
  rem 用 ">" 而不是 echo，免得反引号被 cmd 当转义
  > inc\defs.vh echo ^`define MAX_OUT_VAL 8
)

echo === compile ===
call :XV %XVLOG% -i inc "%RTL%" "%TB%" || goto :fail
if exist xsim.dir rmdir /s /q xsim.dir
if exist xsim.pb del /q xsim.pb
call :XV %XELAB% tb_sdi_stream_wr -s tb8 || goto :fail

echo.
echo ============================ BRESP 延迟 B_LAT =============================
for %%B in (1 8 16 32 64 96 127) do (
  echo AW_LAT 1> bench.txt
  echo W_LAT 1 >> bench.txt
  echo B_LAT %%B >> bench.txt
  echo CYCLES 200000 >> bench.txt
  echo RING_BYTES 0 >> bench.txt
  call :RUN B_LAT=%%B
)

if /I "%~1"=="full" goto :full

echo.
echo ================================ 默认完成 ================================
goto :end

:full
echo.
echo =============================== W 通道反压 W_LAT ==============================
for %%W in (1 2 4 8) do (
  echo AW_LAT 1> bench.txt
  echo W_LAT %%W >> bench.txt
  echo B_LAT 32 >> bench.txt
  echo CYCLES 200000 >> bench.txt
  echo RING_BYTES 0 >> bench.txt
  call :RUN W_LAT=%%W
)

echo.
echo =============================== 环回绕 RING_BYTES =============================
for %%R in (0 33554432 4096 1000 128 64 16 4) do (
  echo AW_LAT 1> bench.txt
  echo W_LAT 1 >> bench.txt
  echo B_LAT 32 >> bench.txt
  echo CYCLES 200000 >> bench.txt
  echo RING_BYTES %%R >> bench.txt
  call :RUN RING=%%R
)
goto :end

:run
call :XV %XSIM% tb8 -runall
findstr /C:"throughput" /C:"AXI protocol" /C:"RING-ERROR" /C:"RING BOUNDS" /C:"DUT err_stat" run.log
echo.
goto :eof

:xv
echo %*
%*
exit /b %errorlevel%

:fail
echo *** COMPILE OR ELABORATION FAILED -- see xvlog.log / xelab.log
exit /b 1

:end
endlocal