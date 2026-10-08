@echo off
setlocal
set CMAKE_GENERATOR="Visual Studio 17 2022"
set CMAKE_GENERATOR_PLATFORM=x64
set CMAKE_GENERATOR_TOOLSET=v143
set CMAKE_EXTRA_PATH=_static
set CMAKE_EXTRA_ARGS=-DFORCE_STATIC_VCRT=ON -DSUPPORT_WINXP=ON -DUSE_MSVCRT=ON
set YY_Thunks_Root=%CD%\..\YY-Thunks
call "%~dp0Compile.bat"
endlocal
if not defined AUTOMATION pause
