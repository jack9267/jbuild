@echo off
rem One-time build-and-run wrapper for pesubsys (the PE OS/subsystem patcher). The build wires this in
rem as a post-link step for a below-floor target (Windows 2000 x86); it is NOT a solution project, so
rem the first invocation compiles pesubsys.exe beside this script with the cl already on PATH in the
rem post-build environment, caches it (gitignored), and every later call just runs it.
rem
rem     pesubsys.cmd <image> <major> <minor>
setlocal enabledelayedexpansion
set "DIR=%~dp0"
set "EXE=%DIR%pesubsys.exe"

if not exist "%EXE%" (
	echo [pesubsys] building one-time PE subsystem patcher...
	rem NOT named TMP/TEMP - cl uses those for its own intermediates and clobbering one breaks the compile.
	set "STAGE=%DIR%pesubsys.%RANDOM%.tmp.exe"
	rem /MT so the cached helper carries no vcruntime DLL dependency. Compile from the source beside this.
	cl /nologo /O1 /MT /Fe:"!STAGE!" /Fo:"!STAGE!.obj" "%DIR%pesubsys.c" >nul
	if errorlevel 1 (
		echo [pesubsys] compile failed - is cl on PATH? 1>&2
		if exist "!STAGE!" del "!STAGE!" >nul 2>&1
		exit /b 1
	)
	del "!STAGE!.obj" >nul 2>&1
	rem Atomic-ish publish: if a parallel build won the race, drop ours and use theirs.
	if not exist "%EXE%" ( move /Y "!STAGE!" "%EXE%" >nul ) else ( del "!STAGE!" >nul 2>&1 )
)

"%EXE%" %*
exit /b %errorlevel%
