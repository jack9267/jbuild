-- Shared premake settings. Copied between repositories unchanged.
--
--     include "Common.lua"
--     common_options("v141_xp")   -- before the workspace
--     common_workspace()          -- after configurations/platforms, which its filters name
--     common_project()            -- inside each project
--
-- Nothing a repository should decide for itself belongs here - workspace name and location,
-- warning level, targetdir, which projects exist. Dependency trees are Dependencies.lua's, the
-- engine Galactic.lua's, warnings Warnings.lua's. See CLAUDE.md.

-- v141_xp targets Windows XP and later but is not in VS2022; it comes from VS2017's targets, and
-- MSBuild reports MSB8020 without it. v143 targets Windows 10 and later.
function common_options(defaultToolset)
	newoption {
		trigger = "toolset",
		value = "NAME",
		description = "Platform toolset to generate for",
		default = defaultToolset or "v141_xp",
		allowed = {
			{ "v141_xp", "Visual Studio 2017 - targets Windows XP and later" },
			{ "v143",    "Visual Studio 2022 - targets Windows 10 and later" }
		}
	}

	-- cmake\j-common.cmake's NO_ENHANCED_INSTRUCTIONS, same on/off. Unset, it follows the
	-- TOOLSET - see no_enhanced_instructions().
	newoption {
		trigger = "no-enhanced-instructions",
		value = "VALUE",
		description = "Compile 32-bit code for plain x86, with no SSE or SSE2 (/arch:IA32)",
		allowed = {
			{ "on",  "No SSE or SSE2 - the default under an XP toolset" },
			{ "off", "SSE2, the compiler's own default" }
		}
	}

	-- Which CPU architectures the generated solution contains: a comma-separated list of x86, x64,
	-- arm, arm64 (or "all" for every one). FREE-FORM rather than premake's `allowed`, which validates
	-- a value whole and cannot express a comma list - common_platforms() parses and checks it. Unset
	-- means x86,x64, the pair every repo declared by hand before this option existed.
	newoption {
		trigger = "architecture",
		value = "LIST",
		description = "CPU architectures in the solution: a comma list of x86,x64,arm,arm64 (or all); default x86,x64"
	}
end

-- The premake platform name for each architecture token, and the order the solution's platform
-- dropdown always reads in regardless of how --architecture spelled the request.
local PLATFORM_FOR_ARCH = {
	x86   = "Win32",
	x64   = "x64",
	arm   = "ARM",
	arm64 = "ARM64",
}
local ARCH_ORDER = { "x86", "x64", "arm", "arm64" }

-- The platforms{} list the workspace is generated with, honouring --architecture (a comma list of
-- x86,x64,arm,arm64, or "all"); unset = x86,x64, what every repo declared by hand before. The
-- .sln-driven build menu then offers exactly what was generated, nothing more. A consumer calls this
-- in place of a hardcoded `platforms { "Win32", "x64" }`, AFTER common_options() has declared the option.
function common_platforms()
	local option = _OPTIONS["architecture"]

	if not option or option == "" then
		return { "Win32", "x64" }
	end

	local wanted = {}
	if option:lower() == "all" then
		wanted = ARCH_ORDER
	else
		for token in option:gmatch("[^,]+") do
			token = token:match("^%s*(.-)%s*$"):lower()
			if not PLATFORM_FOR_ARCH[token] then
				error("--architecture: unknown architecture '" .. token .. "' (want x86, x64, arm, arm64, a comma list, or all)")
			end
			table.insert(wanted, token)
		end
	end

	-- Fixed order, de-duplicated, so "x64,x86" and "x86,x64" generate the one same solution.
	local seen = {}
	for _, token in ipairs(wanted) do seen[token] = true end

	local platforms = {}
	for _, token in ipairs(ARCH_ORDER) do
		if seen[token] then table.insert(platforms, PLATFORM_FOR_ARCH[token]) end
	end

	if #platforms == 0 then error("--architecture: no architectures selected") end

	return platforms
end

-- Entirely a question of the toolset: one ending _xp exists for no other reason, and
-- cmake\j-common.cmake sets SUPPORT_WINXP the same way. A function rather than a pattern match
-- repeated in each place, because several decisions hang off it - TLS guards, SSE2, which
-- SpiderMonkey release still runs.
function support_winxp()
	return _OPTIONS["toolset"]:match("_xp$") ~= nil
end

-- IT FOLLOWS THE TOOLSET, which is the decision already made: a toolset ending _xp is there to
-- run on XP, and the processors that run XP include ones with no SSE2. GTAC reaches the same
-- answer the long way, passing -DNO_ENHANCED_INSTRUCTIONS=ON by hand in three XP scripts.
function no_enhanced_instructions()
	local option = _OPTIONS["no-enhanced-instructions"]

	if option then
		return option == "on"
	end

	return support_winxp()
end

function common_workspace()
	language "C++"

	-- v141_xp DOES support C++17: it is the ordinary v141 compiler with a different SDK and CRT
	-- behind it, so it is the RUNTIME that targets an older Windows, not the language.
	cppdialect "C++17"

	-- WITHOUT THIS THE LINE ABOVE IS HALF INVISIBLE. MSVC reports __cplusplus as 199711L whatever
	-- /std: says - measured, 201703L with this switch and 199711L without - so a header asking
	-- `#if __cplusplus >= 201703L` takes its C++98 path and nothing warns. SDL prompted it, and
	-- reaches here through Galactic's SDL2_static.
	buildoptions "/Zc:__cplusplus"

	-- Defines UNICODE and _UNICODE. premake's default already, written out because it is
	-- load-bearing - Galactic's headers do not compile without it - and because CMake defaults to
	-- MBCS and has to be told.
	characterset "Unicode"

	-- One file you can hand someone, with nothing to install alongside it.
	staticruntime "On"
	multiprocessorcompile "On"

	-- Manifest generation is deliberately left on - the linker's default is what a Windows program
	-- should carry. A project wanting none says `manifest "Off"` for itself.

	-- A 32-bit process is held to 2 GB of address space without this.
	largeaddressaware "On"

	-- Both configurations: a release binary with no pdb is one you cannot symbolise a crash from.
	symbols "On"

	-- NOMINMAX stops windows.h defining min and max as macros. PSAPI_VERSION=1 keeps psapi calls
	-- out of Kernel32's K32 exports, which are Windows 7 and later and would fail the process at
	-- LOAD on anything older. The rest silence deprecations for calls used deliberately.
	defines {
		"WIN32",
		"_WINDOWS",
		"NOMINMAX",
		"_CRT_SECURE_NO_DEPRECATE",
		"_CRT_SECURE_NO_WARNINGS",
		"_USE_MATH_DEFINES=1",
		"PSAPI_VERSION=1",
		"_WINSOCK_DEPRECATED_NO_WARNINGS"
	}

	-- Workspace scope, so these are searched BEFORE anything a project links: the linker takes the
	-- first definition it finds, and a static library defining a Windows API name wins if it comes
	-- first - SpiderMonkey's own HeapAlloc is what bit GTAC. Unused entries cost nothing.
	--
	-- EXCEPT ON A STATIC LIBRARY, WHICH DOES NOT LINK AT ALL. premake puts a project's links in
	-- <Lib><AdditionalDependencies> for a StaticLib, and lib.exe does not resolve imports - it
	-- MERGES each named library into the archive. The result is an archive carrying a copy of
	-- every Windows import library (IV-Tools' was 39MB), and a LNK4006 for the duplicate
	-- __NULL_IMPORT_DESCRIPTOR each one after the first brings with it. Nothing wants either:
	-- whatever eventually links the archive names these itself, from this same list.
	filter { "not kind:StaticLib" }
		links {
			"kernel32",
			"Gdiplus",
			"wldap32",
			"crypt32",
			"ws2_32",
			"comctl32",
			"uxtheme",
			"winmm",
			"imm32",
			"version",
			"shlwapi",
			"psapi",
			"dbghelp",
			"iphlpapi",
			"Rpcrt4",
			"legacy_stdio_definitions",
		}

	filter {}

	-- NO INSTALLED TREE IS SEARCHED FROM HERE - that is Dependencies.lua's and Galactic.lua's,
	-- both appended after this function.

	filter { "platforms:Win32" }
		architecture "x86"

	filter { "platforms:x64" }
		architecture "x86_64"
		defines { "WIN64" }

	-- ARM is generation-level: a solution can carry these platforms, but actually building them needs
	-- the ARM toolchain and ARM-built dependencies installed. ARM64 is 64-bit (WIN64), ARM (32-bit) not.
	filter { "platforms:ARM" }
		architecture "ARM"

	filter { "platforms:ARM64" }
		architecture "ARM64"
		defines { "WIN64" }

	filter { "configurations:Debug" }
		defines { "DEBUG=1", "_DEBUG" }
		optimize "Off"
		runtime "Debug"

	-- THE FOUR BUILDS ARE NAMED SO THEY CAN SIT IN ONE DIRECTORY: _d, _x64, _d_x64, and nothing at
	-- all for the 32-bit release that ships. The filters overlap deliberately - targetsuffix is a
	-- single value, so the later, more specific match replaces the one above rather than adding to
	-- it. Filtering on `architecture` keeps it independent of what a repository calls its
	-- platforms.
	--
	-- ONLY WHAT RUNS IS RENAMED. Nothing loads a static library by name at run time, so a
	-- StaticLib keeps the plain name in every configuration - which is precisely why
	-- common_project() gives it a directory of its own, one per configuration. Left in a shared
	-- Bin\ the second build would silently overwrite the first.
	filter { "configurations:Debug", "not kind:StaticLib" }
		targetsuffix "_d"

	filter { "configurations:Debug", "architecture:x86_64", "not kind:StaticLib" }
		targetsuffix "_d_x64"

	filter { "not configurations:Debug", "architecture:x86_64", "not kind:StaticLib" }
		targetsuffix "_x64"

	filter { "configurations:Debug", "architecture:ARM", "not kind:StaticLib" }
		targetsuffix "_d_arm"

	filter { "not configurations:Debug", "architecture:ARM", "not kind:StaticLib" }
		targetsuffix "_arm"

	filter { "configurations:Debug", "architecture:ARM64", "not kind:StaticLib" }
		targetsuffix "_d_arm64"

	filter { "not configurations:Debug", "architecture:ARM64", "not kind:StaticLib" }
		targetsuffix "_arm64"

	-- AND A DLL'S IMPORT LIBRARY KEEPS THE PLAIN NAME: Foo_d.dll ships with Foo.lib, so whatever
	-- links against it writes one name whichever configuration it is built for - exactly how the
	-- dependency tree is arranged. `implibsuffix ""` does it; `implibname` does NOT, because
	-- premake appends targetsuffix to that as well.
	filter { "kind:SharedLib" }
		implibsuffix ""

	-- "NOT DEBUG" RATHER THAN "RELEASE", because a repository may have more than two
	-- configurations and this file is copied into one. GTAC's third, Public Release, would under
	-- `configurations:Release` get no optimisation, no NDEBUG and the debug runtime - silently,
	-- since nothing fails; it just builds a slow binary against the wrong CRT.
	filter { "not configurations:Debug" }
		defines { "NDEBUG" }
		optimize "Size"
		runtime "Release"

		-- /Ob2. EXPLICIT RATHER THAN A CHANGE: premake emits no /Ob of its own and /O1 already
		-- implies /Ob2 - measured, `/O1 /Oi /Oy-` without this line and `/O1 /Ob2 /Oi /Oy-` with
		-- it. Written out because cmake\j-common.cmake spells the pair out, where it IS load
		-- bearing: CMake's MinSizeRel flags pass /Ob1 and would otherwise win.
		inlining "Auto"

		-- /GL and /LTCG: code generation deferred to link time so the optimiser can work ACROSS
		-- translation units. Not free - the link is slower and cannot be incremental - which is
		-- why it is in the Release filter only.
		--
		-- THE LINK ALREADY USED IT WITHOUT ASKING: the dependency tree is built with /GL, so the
		-- linker reports "module compiled with /GL found; restarting link with /LTCG" and links
		-- twice. Asking up front is what stops the restart.
		--
		-- Supersedes the older flags { "LinkTimeOptimization" } plus /LTCG by hand; this emits
		-- both <WholeProgramOptimization> and <LinkTimeCodeGeneration>.
		linktimeoptimization "On"

	-- INCREMENTAL LINKING IS ALREADY RIGHT: premake defaults it true in Debug and false in
	-- Release, from the optimisation level rather than from LTO. An old
	-- `removeflags { "NoIncrementalLink" }` was reaching for that, and premake5 deprecates the
	-- flag it removes.

	filter {}

	-- NO ENHANCED INSTRUCTIONS: plain x86, 32-bit only - /arch:IA32 does not exist on x64, where
	-- SSE2 is part of the architecture.
	--
	-- Two reasons to want it. A Pentium III or Athlon XP has no SSE2 and faults on a binary built
	-- without this, however carefully the rest targets XP. And it changes HOW FLOATING POINT IS
	-- EVALUATED: x87 keeps intermediates at 80 bits and rounds on store, where SSE2 rounds every
	-- step to the declared width - which a byte-for-byte comparison against an older build needs.
	if no_enhanced_instructions() then
		filter { "architecture:x86" }
			buildoptions { "/arch:IA32" }

		filter {}
	end

	-- MAGIC STATICS USE A TLS GUARD, AND TLS IS THE XP TRAP. A function-local static from VS2015
	-- on gets a thread-safe init guard built on thread-local storage, and a DLL using static TLS
	-- fails to load on XP when something brings it in with LoadLibrary - the loader does not
	-- extend the TLS directory for a module loaded after process start. Executables are
	-- unaffected, so this goes on everything that is not one.
	--
	-- PREVENTIVE rather than a fix: ddraw.dll has an empty Thread Storage Directory today and both
	-- hosts import it statically. It is one function-local static away from not being, and the
	-- cost of finding out on XP is a DLL that will not load.
	if support_winxp() then
		filter { "not kind:ConsoleApp", "not kind:WindowedApp" }
			buildoptions { "/Zc:threadSafeInit-" }

		filter {}
	end

	-- v141_xp's Toolset.props sets the XP subsystem itself. Spelling out /SUBSYSTEM here would
	-- override a WindowedApp project and turn a GUI into a console program.
	toolset (_OPTIONS["toolset"])
end

-- WHICH FLAVOUR OF AN INSTALLED TREE TO LINK AGAINST. Every tree is built twice, Debug and
-- Release, so a repository with a third configuration wants the Release one.
--
-- $(Configuration) cannot say that: it expands to the configuration's NAME, so GTAC's "Public
-- Release" would look for a Lib\Public Release that was never built. This token is evaluated per
-- configuration at generation time and writes the literal Debug or Release into each.
DEPENDENCY_CONFIG = "%{cfg.buildcfg == 'Debug' and 'Debug' or 'Release'}"

-- WHERE A LINK-TIME ARTIFACT GOES - an import library or a static library, both of which are
-- CONSUMED by a later link rather than run. Laid out the way the installed dependency trees
-- already are, Lib\<arch>\<toolset>_static\<Debug|Release>, rather than a second shape to learn.
-- common_project() puts both there; see its own comments for why neither can sit in Bin\.
-- $(SolutionDir).. is the REPO ROOT: the solution is generated into .jbuild\ (the gitignored build
-- output), one level down, but Lib\ is a PRODUCT downstream trees link against and belongs at the root.
LINK_LIBRARIES = "$(SolutionDir)..\\Lib\\$(PlatformTarget)\\$(PlatformToolset)_static\\" .. DEPENDENCY_CONFIG

-- The same four names targetsuffix gives our own binaries, because the dependency tree is built
-- by the same rules: SDL2_d.dll, SDL2_d_x64.dll, SDL2.dll, SDL2_x64.dll.
local RUNTIME_BUILDS = {
	{ config = "configurations:Debug",     arch = "x86",    from = "Debug",   suffix = "_d" },
	{ config = "configurations:Debug",     arch = "x86_64", from = "Debug",   suffix = "_d_x64" },
	{ config = "not configurations:Debug", arch = "x86",    from = "Release", suffix = "" },
	{ config = "not configurations:Debug", arch = "x86_64", from = "Release", suffix = "_x64" },
}

-- Copy a dependency's DLL and .pdb next to the binary, so what was just built can run.
--
--     copy_dependency(DEPENDENCIES, "SDL2")
--
-- `dir` is the Lib directory WITHOUT the configuration - this adds Debug or Release itself,
-- because which one to take and what the file is called are the same decision. symbols = false
-- for a dependency shipping no .pdb; copying a missing file is a build error, not a skip.
--
-- ONE project per output directory: two copying the same file to the same place is a failure, not
-- a wasted copy, because MSBuild runs projects in parallel under /m and one finds it locked.
function copy_dependency(dir, name, symbols)
	if symbols == nil then
		symbols = true
	end

	for _, build in ipairs(RUNTIME_BUILDS) do
		filter { build.config, "architecture:" .. build.arch }

		local file = dir .. "\\" .. build.from .. "\\" .. name .. build.suffix

		postbuildcommands { '{COPYFILE} "' .. file .. '.dll" "%{cfg.targetdir}"' }

		if symbols then
			postbuildcommands { '{COPYFILE} "' .. file .. '.pdb" "%{cfg.targetdir}"' }
		end
	end

	filter {}
end

-- Copy ONE named file whose name is the same in every build - only the directory changes. Unlike
-- copy_dependency, there is no _d to add and nothing to decide per architecture.
--
--     copy_single_dependency(dir, "xlive.dll")
--
-- Name it WITH its extension. The same one-owner-per-output-directory rule applies.
function copy_single_dependency(dir, name)
	filter { "configurations:Debug" }
		postbuildcommands { '{COPYFILE} "' .. dir .. '\\Debug\\' .. name .. '" "%{cfg.targetdir}"' }

	filter { "not configurations:Debug" }
		postbuildcommands { '{COPYFILE} "' .. dir .. '\\Release\\' .. name .. '" "%{cfg.targetdir}"' }

	filter {}
end

function common_project()
	-- Project, platform, toolset, configuration - the dependency tree's shape, and the toolset
	-- segment keeps v141_xp and v143 objects from mixing.
	--
	-- "!" opts out of premake making the path unique; without it premake appends platform,
	-- configuration and project again as literals, MSBuild macros being opaque to its comparison.
	-- That also removes its safety net, so every macro here must resolve: $(ProjectName), never
	-- $(ShortProjectName), which is empty under v141_xp. See CLAUDE.md.
	objdir "!$(SolutionDir)obj\\$(ProjectName)\\$(Platform)\\$(PlatformToolset)\\$(Configuration)"

	-- AN IMPORT LIBRARY DOES NOT GO BESIDE THE BINARY, it goes in Lib\ laid out the way the
	-- installed dependency tree is: Lib\<arch>\<toolset>_static\<Debug|Release>.
	--
	-- Bin\ is deliberately shared by every configuration - Foo_d.exe sits next to Foo.exe - and
	-- that is fine for things whose names differ. An import library's does NOT: implibsuffix ""
	-- above gives both configurations a plain Foo.lib, so in one directory the second build
	-- overwrites the first and a Release binary silently links the Debug import library, naming
	-- Foo_d.dll in its import table. That happened here, and nothing failed until the import
	-- table was read.
	--
	-- The dependency tree never had the problem because it splits per configuration. This follows
	-- it rather than inventing a second layout, and DEPENDENCY_CONFIG is used rather than
	-- $(Configuration) for the same reason it is used there - a repository is allowed a third
	-- configuration, and it links the Release flavour.
	implibdir (LINK_LIBRARIES)

	-- AND A STATIC LIBRARY IS THE SAME PROBLEM, for the same reason: targetsuffix above renames
	-- only what RUNS, so Foo.lib is Foo.lib in both configurations. A repository's targetdir is
	-- its own business - Bin\ is shared by every configuration on purpose - but an archive cannot
	-- live there, because the second build overwrites the first and MSBuild will then happily
	-- link a Release executable against the Debug archive it finds.
	--
	-- Not hypothetical: IV-Tools hit it within minutes of having a StaticLib, and GTAC had already
	-- worked around it in its own premake5.lua. Two repositories reaching the same rule separately
	-- is what moved it here. A repository wanting somewhere else says so after common_project().
	filter { "kind:StaticLib" }
		targetdir (LINK_LIBRARIES)

	filter {}
end
