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
- **`JBuild.ps1` (at the jbuild root) is the shared premake driver**: it maps friendly params to premake
  options, runs premake (`premake/premake5.exe`) against the CONSUMER's `premake5.lua` (via `-Root`, which
  defaults to jbuild's parent), then **discovers** and optionally MSBuilds the generated `.sln`. The solution
  NAME lives in each consumer's `workspace(...)`, never in the driver, so nothing consumer-specific is hardcoded.
- **`JBuild.cmd` (at the jbuild root) is the launcher** holding all the boilerplate (pick pwsh, run `JBuild.ps1`,
  pause). A consumer keeps only a **one-line `JBuild.cmd` at its repo root**: `@call "%~dp0jbuild\JBuild.cmd" %*`
  — so none of the launcher boilerplate is copied per repo. Generation alone is still just `premake5.exe vs2022`.
- **`JBuild.ps1` is a build-system front-end.** It detects the system from the repo ROOT — `premake5.lua` →
  premake, `CMakeLists.txt` → cmake — and, when both exist interactively, offers a choice (premake default).
  The consumer's `premake5.lua` now lives at the **repo root** (not `premake/`). The cmake path (`Invoke-Cmake`)
  mirrors the premake prompts WHERE cmake supports them — Visual Studio, architecture, XP toolset, XP support,
  SpiderMonkey, runtime — maps them to one of the configure presets + `-D` overrides, runs `cmake --preset`, and
  optionally builds. The premake-only knobs (`--crt` dynamic modes, the `--target-os` ladder, multi-arch) are
  not offered there. **KNOWN: modern cmake (seen with 4.x) fails compiler detection when the build-dir path has
  a space, and every preset's `binaryDir` contains "Visual Studio NN YYYY" — a pre-existing spaced-path issue,
  not from the `.jbuild` move; de-spacing the generator segment (presets + bats together) is the fix if needed.**
- **`.jbuild/` is the gitignored build-output folder** at each consumer's root, for all three systems: premake
  `location ".jbuild"` (its `.sln`/`.vcxproj` + `$(SolutionDir)obj`), cmake preset `binaryDir`
  `${sourceDir}/.jbuild/CMake.tmp/...` (and `bat/` writes there via `%SRC%\.jbuild`), and make `OBJROOT`
  `.jbuild/make/...`. `JBuild.ps1` discovers the generated `.sln` in `.jbuild/` first, then the root.

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
  **`--target-os` is premake-only** (CMake `j-xp.cmake` still uses the fixed `support-winxp` 5.01/5.02 path;
  `make/` has no XP subsystem logic). So win2000 — and the subsystem patch below — live only in premake; the
  lockstep rule doesn't yet apply to them because the feature doesn't exist in the other two. Porting
  `--target-os` to CMake/make (which would bring win2000 with it) is the follow-up if XP-via-those is wanted.
- **Windows 2000 (5.00) needs a post-link PE patch — the linker won't emit it.** `link.exe` floors
  `/SUBSYSTEM` at 5.01 (x86) / 5.02 (x64): 5.00 is **LNK4010** and silently becomes 6.00 (verified — a 6.0
  binary loads on neither 2000 nor XP). So for a below-floor target (only win2000 x86) the build LINKS at the
  5.01 floor — no warning — then stamps the real OS+subsystem 5.0 into the PE optional header after linking.
  The patcher is **`tools/pesubsys/pesubsys.c`**, compiled on first use by **`pesubsys.cmd`** (not a solution
  project — one-time build, cached beside the source, gitignored) and wired as a post-build step by
  `patch_subsystem_postbuild()` under `architecture:x86, not kind:StaticLib`. It recomputes the image checksum
  only if one is present (a `/RELEASE`-less build leaves it 0). No other target is below its floor, so this is
  a no-op everywhere else. `editbin` shares link.exe's floor and can't do it either.

## Which C runtime (`--crt`, premake `XP.lua`)
- **The MSVC C runtime is three separate pieces since VS2015:** the **UCRT** (`ucrtbase.dll` +
  `api-ms-win-crt-*.dll` — the C stdlib), the **VCRuntime** (`vcruntime140.dll` — EH/`/GS`/RTTI glue), and the
  **C++ stdlib** (`msvcp140.dll`). A `/MD` build needs all three. The UCRT and the VC-LTL `msvcrt.dll` route are
  **mutually-exclusive** strategies for the same job, never combined.
- **`--crt=<mode>` is the full selector** (supersedes `--use-msvcrt`, kept as the on/off/release alias). One of:
  - `msvcrt` — Windows' own `msvcrt.dll` via VC-LTL5. Tiny, nothing to ship, runs XP+.
  - `static` — the UCRT linked static (`/MT`). Self-contained; keeps MSVC's debug heap.
  - `dynamic` — the UCRT dynamic (`/MD`), relying on the runtime being present on the target.
  - `ucrt-local` — `/MD` with the UCRT + VC runtime copied **app-local**, so it runs on **XP SP3+** with nothing
    installed. Release copies the redistributable DLLs; Debug ALSO copies the **non-redistributable** debug DLLs
    (`ucrtbased.dll`/`vcruntime140d.dll`) so a local debug build runs — **that build must not be shared**.
- **The CRT is PER CONFIG** (`crt_pair()` → release mode, debug mode). `--crt` sets the Release/non-Debug CRT;
  **Debug defaults to `static`** so a debug build keeps MSVC's debug heap and leak detection, and **`--crt-debug`**
  overrides it (mirrors `--crt`). So `--crt=ucrt-local` ships the app-local UCRT in Release while Debug stays
  self-contained static; `--crt-debug=ucrt-local` opts Debug in too (copying the non-redistributable debug DLLs).
  With no `--crt`, the legacy `--use-msvcrt` path is byte-for-byte unchanged (`on` = msvcrt both, `release` =
  msvcrt/static split, `off` = static both). `apply_dynamic_crt(mode, cfg)` sets `/MD` per config; VC-LTL is
  scoped by `msvcrt_config_filter()` (both / release-only / debug-only). Nothing about the proven static/msvcrt
  XP paths changes when `--crt` is unset.
- **`JBuild.ps1` shows a resolved-settings summary** before the `o`/Enter gate (toolset, SpiderMonkey,
  architectures, target OS + subsystem, and the release/debug CRT), so Enter is an informed choice. It comes
  from premake itself via the read-only **`jbuild-summary`** action (ground truth, consumer defaults included),
  not a regex guess; silent if the consumer has no XP.lua.
- **The app-local copy** is `tools/copyucrt/copyucrt.cmd`, wired by `copy_ucrt_local()` as a post-build step.
  It derives the VC redist dir from **`$(VCInstallDir)`** — `$(VCToolsRedistDir)` is NOT a defined MSBuild
  property (measured: it comes back empty); `$(WindowsSdkDir)`/`$(UCRTVersion)` are real. Like `--target-os`,
  `--crt` is **premake-only** so far.

## Architectures in the generated solution
- **`--architecture` (premake `Common.lua`)** chooses which CPU platforms the `.sln` CONTAINS: a comma list of
  `x86,x64,arm,arm64` (or `all`); unset = `x86,x64`, the pair repos declared by hand before. Consumers call
  `common_platforms()` in place of a hardcoded `platforms { "Win32", "x64" }`. `JBuild.ps1` offers it as a
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

