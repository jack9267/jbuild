@echo off
rem Copy the Universal CRT (and the VC runtime) app-local, for --crt=ucrt-local: a /MD binary then runs
rem on Windows XP SP3+ with nothing installed. Wired in as a post-build step by XP.lua's copy_ucrt_local().
rem
rem     copyucrt.cmd <targetdir> <arch x86|x64> <config> <VCInstallDir> <WindowsSdkDir> <UCRTVersion>
rem
rem Release copies the redistributable release DLLs. Debug ALSO copies the NON-redistributable debug DLLs
rem (ucrtbased.dll / vcruntime140d.dll) so a local debug build runs - such a build must NOT be shared.
setlocal enabledelayedexpansion
set "DEST=%~1"
set "ARCH=%~2"
set "CONFIG=%~3"
set "VCINSTALL=%~4"
set "SDK=%~5"
set "UCRTVER=%~6"

rem The UCRT redist set: ucrtbase.dll + the api-ms-win-*.dll forwarders (needed on pre-Win10 / XP; in-box
rem on Win10+, where copying them is harmless). %SDK% ends in a backslash, as $(WindowsSdkDir) does.
set "UCRTDLLS=%SDK%Redist\%UCRTVER%\ucrt\DLLs\%ARCH%"
if exist "%UCRTDLLS%" (
	copy /Y "%UCRTDLLS%\*.dll" "%DEST%" >nul
) else (
	echo [copyucrt] WARNING: UCRT redist not found at "%UCRTDLLS%" 1>&2
)

rem $(VCToolsRedistDir) is NOT a defined MSBuild property (measured - it comes back empty), so derive the VC
rem runtime redist from $(VCInstallDir)Redist\MSVC\<ver>\ - newest version that actually carries this arch's
rem CRT. The VC<nnn> folder name follows the toolset (v141/v142/v143 all ship vcruntime140.dll), so glob it.
rem (if exist does not expand a wildcard in a mid-path component, so test the plain %ARCH%\ dir, then let
rem for /d glob the VC<nnn>.CRT folder below - for /d does expand wildcards.)
set "REDIST="
for /f "delims=" %%V in ('dir /b /ad /o-n "%VCINSTALL%Redist\MSVC" 2^>nul') do (
	if not defined REDIST if exist "%VCINSTALL%Redist\MSVC\%%V\%ARCH%\" set "REDIST=%VCINSTALL%Redist\MSVC\%%V\"
)

if defined REDIST (
	for /d %%D in ("!REDIST!%ARCH%\Microsoft.VC*.CRT") do copy /Y "%%D\*.dll" "%DEST%" >nul 2>&1
) else (
	echo [copyucrt] WARNING: VC runtime redist not found under "%VCINSTALL%Redist\MSVC" 1>&2
)

if /I "%CONFIG%"=="Debug" (
	rem The debug VC runtime - non-redistributable, under debug_nonredist\.
	if defined REDIST for /d %%D in ("!REDIST!debug_nonredist\%ARCH%\Microsoft.VC*.DebugCRT") do copy /Y "%%D\*.dll" "%DEST%" >nul 2>&1
	rem The debug UCRT (ucrtbased.dll) - non-redistributable, under bin\, not Redist\.
	if exist "%SDK%bin\%UCRTVER%\%ARCH%\ucrt\ucrtbased.dll" copy /Y "%SDK%bin\%UCRTVER%\%ARCH%\ucrt\ucrtbased.dll" "%DEST%" >nul
	echo [copyucrt] %ARCH% Debug: app-local UCRT incl. non-redistributable debug DLLs - LOCAL USE ONLY
) else (
	echo [copyucrt] %ARCH% %CONFIG%: app-local UCRT redist copied
)

exit /b 0
