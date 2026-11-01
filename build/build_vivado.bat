@echo off
rem ===========================================================================
rem  build_vivado.bat -- ZYNQ7020 mmWave heart-rate Block Design, one-click
rem
rem  Usage (double-click, or from cmd):
rem      build_vivado.bat            run everything (project->BD->synth->impl->bit->xsa)
rem      build_vivado.bat bd         project + Block Design only   (~2 min)
rem      build_vivado.bat synth      up to synthesis done          (~6-10 min)
rem      build_vivado.bat gui        build BD then open the GUI    (~2 min)
rem
rem  Change VIVADO_BIN below if Vivado lives somewhere else.
rem  ASCII-only on purpose: cmd.exe on a Chinese Windows would otherwise
rem  garble non-ASCII output.
rem ===========================================================================
setlocal enabledelayedexpansion
set VIVADO_BIN=D:\vivado2019\Vivado\2019.1\bin
set BUILD_DIR=%~dp0
for %%I in ("%BUILD_DIR%.")  do set BUILD_DIR=%%~fI
for %%I in ("%BUILD_DIR%\..") do set PROJ_ROOT=%%~fI
set TCL=%BUILD_DIR%tcl\build_everything.tcl

echo.
if not exist "%VIVADO_BIN%\vivado.bat" (
    echo [ERROR] Vivado not found: %VIVADO_BIN%
    echo         Edit VIVADO_BIN at the top of this file.
    pause
    exit /b 1
)

set MODE=%~1
if "%MODE%"=="" set MODE=all

if /I "%MODE%"=="bd"    set VS_STOP_AFTER=bd
if /I "%MODE%"=="synth" set VS_STOP_AFTER=synth
if /I "%MODE%"=="gui"   set VS_STOP_AFTER=bd
if /I "%MODE%"=="all"   set VS_STOP_AFTER=bit

echo ===========================================================
echo   project : %PROJ_ROOT%
echo   vivado  : %VIVADO_BIN%
echo   mode    : %MODE%   (stop after %VS_STOP_AFTER%)
echo ===========================================================
if /I "%MODE%"=="all" (
    echo.
    echo   NOTE: synthesis + implementation + bitstream take about
    echo         10-25 minutes. Do not close this window.
    echo.
)

call "%VIVADO_BIN%\vivado.bat" -mode batch -source "%TCL%"
set RC=%ERRORLEVEL%

if /I "%MODE%"=="gui" (
    echo.
    echo   opening Vivado GUI ...
    start "" "%VIVADO_BIN%\vivado.bat" "%PROJ_ROOT%\build\vivado\vs_fpga.xpr"
)

echo.
echo ===========================================================
if "%RC%"=="0" (
    echo   done. project: %PROJ_ROOT%\build\vivado\vs_fpga.xpr
    echo   open it and double-click vs_bd.bd to see the data flow
) else (
    echo   FAILED (exit code = %RC%^)
    echo   scroll up and look for lines starting with "!!"
)
echo ===========================================================
pause
