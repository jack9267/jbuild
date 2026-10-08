@echo off
if exist "%CD%\.jbuild\CMake.tmp" rmdir /S /Q "%CD%\.jbuild\CMake.tmp"
if not defined AUTOMATION pause
