@echo off
rem jbuild's launcher. Picks pwsh (falling back to Windows PowerShell) and runs the JBuild driver against
rem the CONSUMING repo - the parent of this jbuild folder, which JBuild.ps1 resolves from its own location.
rem A consumer keeps only a one-line JBuild.cmd at its root that calls this, so none of this boilerplate is
rem copied per repo. Forwards any args (e.g. -VisualStudio 2019, -Build, -Crt ucrt-local, -TargetOs winxp).
setlocal
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0JBuild.ps1" %*
echo.
pause
endlocal
