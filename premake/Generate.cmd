@echo off
rem Double-click to generate the CONSUMING repo's solution: a menu picks the Visual Studio version and,
rem optionally, SpiderMonkey ESR / XP support / CRT and the build (configuration + platform, incl. All).
rem Runs the co-located Generate.ps1, whose -Root defaults to two levels up - i.e. the consumer repo when
rem jbuild is vendored at <consumer>\jbuild. Forwards any args (e.g. -VisualStudio 2019, -Build).
setlocal
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Generate.ps1" %*
echo.
pause
endlocal
