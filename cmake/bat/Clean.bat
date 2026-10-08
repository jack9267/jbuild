@echo off
if exist "%~dp0CMake.tmp" rmdir /S /Q "%~dp0CMake.tmp"
if not defined AUTOMATION pause
