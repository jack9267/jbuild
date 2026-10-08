# CLAUDE.md — jbuild

Shared build-system helpers factored out of the consuming repos (the Galactic engine, its tools, Dependencies)
to be vendored as a submodule. This repo builds **no code of its own** — it describes HOW consumers configure,
build, install, and link, across three generators that must stay in lockstep. The authoritative facts about
*building the SpiderMonkey DLL itself* live in **SpiderMonkeyBuilder**'s CLAUDE.md, not here.

## The three build systems stay in lockstep
- `cmake/` (the `j-*.cmake` modules + `presets.json` + `bat/` launchers), `premake/` (`*.lua` + a committed
  `premake5.exe`), and `make/` (`*.mk`) each express the SAME build. A change to one — a compiler flag, a
  library, a platform rule — must be mirrored to the others, or a consumer that happens to use a different
  generator silently misses it. (Worked example: the esr140 `/utf-8`+`XP_WIN` consumer flags belong in
  `cmake/j-spidermonkey.cmake`, the premake SpiderMonkey wiring, and `make/spidermonkey.mk` alike.)
- `premake/premake5.exe` is deliberately **committed** — consumers run it directly, nothing to install.
- `premake/Generate.ps1` is the **shared** premake driver: it maps friendly params to premake options, runs
  premake against the CONSUMER's `premake5.lua` (via `-Root`), then **discovers** and optionally MSBuilds the
  generated `.sln`. The solution NAME lives in each consumer's `workspace(...)`, never in the driver, so nothing
  consumer-specific is hardcoded here. A consumer keeps a thin wrapper that calls this with its own root (or,
  once jbuild is its submodule, invokes it directly). Generation alone is still just `premake5.exe vs2022`.

## Conventions
- **Never `git push`.** Commit when asked; report what's unpushed. (User always pushes.)
- **Line endings matter here because this repo mixes all of them:** `.sh` and `.mk` are **LF** (they run under
  bash/make), `.bat` and `.ps1` are **CRLF**. Enforced by `.gitattributes` — don't let an editor flip them.
- **No copyright/licence headers** in new files; keep commit messages short.
- `CMake.tmp/` (build scratch, relocated here from each consumer's root) is gitignored. Never commit build dirs.

## Windows XP targeting (the CONSUMER's binaries)
- A modern toolset (v143) reaches XP via **VC-LTL5 + YY-Thunks**, selected by `SUPPORT_WINXP` / the
  `winxp-modern` preset (CMake `j-xp.cmake`) and `--support-winxp` (premake `XP.lua`), with subsystem 5.01
  (x86) / 5.02 (x64). `v141_xp` (VS2017 targets) still reaches XP the old way and is offered too; both produce
  equivalent output.
- **`--target-os` (premake `XP.lua`) supersedes `--support-winxp`:** it names the OLDEST Windows the binaries
  must run on — `win2000`/`winxp`/`vista`/`win7`/`win8`/`win81`/`win10`/`win11` — and sets the subsystem
  version, YY-Thunks object, and VC-LTL tier PER ARCH from one table. Notably x64 has no floor below XP x64
  (5.02), so a `win2000` x64 build targets XP x64; `win81` reuses the Win8 thunks. `--support-winxp=on` stays
  as the equivalent of `--target-os=winxp` for back-compat. The XP machinery only ever touches x86/x86_64.

## Architectures in the generated solution
- **`--architecture` (premake `Common.lua`)** chooses which CPU platforms the `.sln` CONTAINS: a comma list of
  `x86,x64,arm,arm64` (or `all`); unset = `x86,x64`, the pair repos declared by hand before. Consumers call
  `common_platforms()` in place of a hardcoded `platforms { "Win32", "x64" }`. `Generate.ps1` offers it as a
  multi-select menu and the `.sln`-driven build menu then lists exactly what was generated. ARM/ARM64 are
  **generation-only** — building them needs the ARM toolchain and ARM-built dependencies installed; they get
  no XP/VC-LTL/YY treatment (ARM Windows is Win10+). Their output is suffixed `_arm`/`_arm64` (`_d_*` in Debug).
- This is the engine/tool side only. Producing the `mozjs-<NN>.dll` that those binaries load is a *separate*
  repo (SpiderMonkeyBuilder) with its own XP method and its own hard-won gotchas.

## SpiderMonkey consumption
- Choose the ESR with `SPIDERMONKEY_VERSION` (CMake `-D`) / `--spidermonkey-version` (premake); it drives the
  SDK subdir (`esr<NN>`) and the lib name (`mozjs-<NN>`). `jspidermonkey_home` points at the SDK root
  (`GitHub\SpiderMonkey`), whose `esr<NN>/{include,Lib/<plat>/<config>}` layout is produced by SpiderMonkeyBuilder.
- **esr140+ consumers need two things when compiling any TU that includes the JS headers:** `/utf-8` (its
  bundled `{fmt}` headers enforce it with a `static_assert`) and **`XP_WIN` defined** (`mozilla/UniquePtrExtensions.h`
  `#error`s "Unsupported OS?" without a platform macro). `target_link_spidermonkey` / the premake wiring add both
  for esr≥140; a module's own sources need them set at module scope too (see the consumer's
  `src/JSScripting/CMakeLists.txt`).
- **The `msvcrt.dll` CRT "mismatch" is fine and intended:** mozjs ships as a VC-LTL (msvcrt) DLL while a
  consumer links the static UCRT; they meet only across the DLL boundary, and SpiderMonkey has its own
  allocators, so nothing crosses mismatched. This is how every ESR has always linked.

## Installing is mandatory for downstream linking
- `cmake --build` populates the build tree but does **NOT** write `Lib/<platform>/<toolset>_static/<config>` —
  only `cmake --install` does. Downstream (a premake tool, a sample) links *that installed tree*, so skipping
  the install makes it silently link a **stale** library with no warning. Always install the engine after
  building it, before building anything that consumes it. (This has burned days — see Galactic's CLAUDE.md.)
