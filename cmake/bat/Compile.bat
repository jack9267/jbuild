@echo off
if [%CMAKE_GENERATOR%]==[] echo Insufficient parameters! && pause && exit /b 1
set "SRC=%CD%"
set GENDIR=%CMAKE_GENERATOR:"=%
set "BUILD=%SRC%\.jbuild\CMake.tmp\%GENDIR%\%CMAKE_GENERATOR_PLATFORM%\%CMAKE_GENERATOR_TOOLSET%%CMAKE_EXTRA_PATH%"
if not exist "%BUILD%" mkdir "%BUILD%"
pushd "%BUILD%"
cmake "%SRC%" -G %CMAKE_GENERATOR% -A %CMAKE_GENERATOR_PLATFORM% -T %CMAKE_GENERATOR_TOOLSET% -DCMAKE_INSTALL_PREFIX="%SRC%" %CMAKE_EXTRA_ARGS%
if %ERRORLEVEL% neq 0 goto fail
cmake --build . --config Debug --target install
if %ERRORLEVEL% neq 0 goto fail
cmake --build . --config Release --target install
if %ERRORLEVEL% neq 0 goto fail
popd
goto eof
:fail
popd
pause
:eof
