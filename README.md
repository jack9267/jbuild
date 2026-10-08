# jbuild

Shared build boilerplate, consumed as a git submodule so each repository *names what it builds*
instead of copy-pasting the build logic. One source of truth across Galactic, GalacticSamples,
GalacticTools and friends - the same role the CMake-Modules submodule already plays for CMake.

## premake/

The premake5 modules plus the committed `premake5.exe` (nothing to install). A consuming repo's own
`premake5.lua` includes these and then declares only its workspace and projects:

```lua
include "Common.lua"        -- compiler, configs, platforms, warnings-as-errors off, static runtime
include "Dependencies.lua"  -- the %jdependencies_home% tree (zlib, png, SDL2, lua, ...)
include "Galactic.lua"      -- linking an INSTALLED Galactic (headers + Lib/<platform>/<toolset>)
include "Warnings.lua"
include "XP.lua"            -- Windows XP via VC-LTL5 + YY-Thunks
```

`XP.lua`'s `xp_options { supportWinXP = ..., useMsvcrt = ... }`:
- `supportWinXP` - `on` links YY-Thunks for the Win32 APIs XP lacks.
- `useMsvcrt` - `on` binds Windows' own `msvcrt.dll` (small binaries) in every config; `release` does so
  in non-Debug configs only (so Debug keeps the toolset's static CRT and its `_CrtDumpMemoryLeaks` leak
  detection); `off` uses the toolset's own CRT throughout.

## cmake/

The `j-*.cmake` modules, the same set Galactic consumes today through the standalone CMake-Modules
submodule. A consuming repo's `CMakeLists.txt` adds this directory to `CMAKE_MODULE_PATH` and
`include()`s what it needs:

- `j-common.cmake` - compiler flags, configs, static runtime.
- `j-dependencies.cmake` - the `%jdependencies_home%` tree (zlib, png, SDL2, lua, ...).
- `j-galactic.cmake` - linking an INSTALLED Galactic (headers + `Lib/<platform>/<toolset>`), via
  `add_external_project`.
- `j-macros.cmake` - the shared macros (`add_external_project`, source globbing, ...).
- `j-signing.cmake` - code-signing.
- `j-spidermonkey.cmake` - the SpiderMonkey SDK for the JS backend.
- `j-warnings.cmake` - warnings-as-errors policy.
- `j-xp.cmake` - Windows XP via VC-LTL5 + YY-Thunks.

### cmake/bat/

The Windows CMake-build launchers, shared verbatim instead of copy-pasted per repo. Run one from a
consuming repo's root (the repo is the working directory, e.g. `jbuild\cmake\bat\VS2022.bat`):

- `Compile.bat` / `Configure.bat` - the engines: configure (+ build+install, for `Compile`) from the
  `CMAKE_GENERATOR*` / `CMAKE_EXTRA_ARGS` the caller set. The build scratch lives inside jbuild
  (`jbuild\cmake\bat\CMake.tmp\<generator>\<platform>\<toolset>_static\`), while the source and the
  install prefix are the repo root (the working directory the launcher was run from).
- `VS2017*/VS2019*/VS2022*.bat` and `Configure_VS*.bat` - one per toolset/arch: set the generator
  matrix + args, then call the matching engine. Non-XP toolsets (v141/v142/v143) build XP-compatible
  via `-DSUPPORT_WINXP=ON` + YY-Thunks (expects a `YY-Thunks` folder beside the repo); the native XP
  toolset (`v141_xp`) uses `-DNO_ENHANCED_INSTRUCTIONS=ON` on Win32 instead.
- `BuildAll.bat` - the shipping set (`AUTOMATION=1`, no pauses).
- `Clean.bat` - removes only jbuild's own build scratch (`%~dp0CMake.tmp`); it touches nothing at the
  repo root. Each repo keeps its own root `Clean.bat` for its install outputs (`Lib\`, plus `include\`
  where that is a build output rather than source) that `call`s this one for the scratch - so a repo
  whose `include\` is tracked source (e.g. Galactic) is never at risk.

### cmake/presets.json

The shared CMake preset definitions (the same toolset matrix as `bat/`, converged to match it). CMake
only auto-discovers presets from a repo's **root** `CMakePresets.json`, so a consuming repo keeps a thin
root stub that includes this file:

```json
{ "version": 6, "include": ["jbuild/cmake/presets.json"] }
```

`${sourceDir}` in the shared file still resolves to the repo root, so each repo's presets install to its
own root and build into its own `jbuild\cmake\bat\CMake.tmp\...` (the same tree the matching bat uses).
Non-XP toolsets set `SUPPORT_WINXP` + a `YY_Thunks_Root` environment; the `v141_xp` ones set
`NO_ENHANCED_INSTRUCTIONS` on Win32. A repo opts in purely by adding the root stub - it's optional.

## make/

The Unix/Linux (GNU make) boilerplate, split out of Galactic's hand-written Makefile so a consuming
repo names only what it builds. A thin `Makefile` sets `JBUILD`, includes the pieces it needs, declares
its modules/tools, and calls `finalize`:

```make
JBUILD ?= jbuild
include $(JBUILD)/make/common.mk        # toolchain, config, platform, flags, module/tool templates
include $(JBUILD)/make/dependencies.mk  # the %jdependencies_home% tree
include $(JBUILD)/make/spidermonkey.mk  # SpiderMonkey SDK for the JS backend (JS=0 to skip)

GALACTIC_LIBDIR := $(LIBDIR)            # in-tree build; downstream consumers omit this
include $(JBUILD)/make/galactic.mk      # engine defines/headers + the link group
TOOL_LDFLAGS := $(GALACTIC_LDFLAGS)
TOOL_LDLIBS  := $(GALACTIC_LDLIBS)

$(eval $(call module,Engine,Galactic,-DENGINE_BUILDING=1))
$(eval $(call tool,hbfmodel))
$(eval $(call finalize))
```

- `common.mk` - toolchain, debug/release config, platform (bitness) detection, the common compile
  flags, and the reusable `module` / `tool` / `split_debug` / `finalize` templates.
- `dependencies.mk` - the `%jdependencies_home%` tree (headers + `Lib/<platform>` static libs).
- `spidermonkey.mk` - the SpiderMonkey SDK for the JS backend; `JS=0` skips it.
- `galactic.mk` - linking Galactic and its dependency closure (the engine defines, headers, and the
  `--start-group` link line), for both in-tree tools and downstream consumers.

The `.mk` files are LF-only (a CR in a recipe breaks GNU make) - see `.gitattributes`.
