@echo off
if [%CMAKE_GENERATOR%]==[] echo Insufficient parameters! && pause && exit /b 1
set "SRC=%CD%"
rem Short, space-free build-dir token (vs2022/vs2019/vs2017) from the generator's year - cmake fails
rem compiler detection when the build-dir path contains a space.
for %%G in (%CMAKE_GENERATOR:"=%) do set "GENTOKEN=vs%%G"
set "BUILD=%SRC%\.jbuild\CMake.tmp\%GENTOKEN%\%CMAKE_GENERATOR_PLATFORM%\%CMAKE_GENERATOR_TOOLSET%%CMAKE_EXTRA_PATH%"
if not exist "%BUILD%" mkdir "%BUILD%"
pushd "%BUILD%"
cmake "%SRC%" -G %CMAKE_GENERATOR% -A %CMAKE_GENERATOR_PLATFORM% -T %CMAKE_GENERATOR_TOOLSET% -DCMAKE_INSTALL_PREFIX="%SRC%" %CMAKE_EXTRA_ARGS%
if %ERRORLEVEL% neq 0 goto fail
popd
goto eof
:fail
popd
pause
:eof
