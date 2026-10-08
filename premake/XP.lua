-- Targeting Windows XP from a current toolset. Copied between repositories unchanged.
--
--     include "XP.lua"     -- AFTER Common.lua, whose support_winxp() this takes over
--     xp_options()         -- before the workspace, beside common_options()
--     xp_workspace()       -- after common_workspace()
--
-- Port of Galactic's cmake\j-xp.cmake. v141_xp was long the only way to reach XP, so "supports
-- XP" and "is the XP toolset" were one statement. Two pieces separate them:
--
--   VC-LTL5     a CRT binding to Windows' own msvcrt.dll, which predates fiber local storage and
--               so never calls FlsAlloc, rather than to VCRUNTIME140 and the UCRT
--   YY-Thunks   an object DEFINING the __imp__ symbols for Win32 APIs XP lacks, so a call
--               compiled as `call [__imp__AcquireSRWLockExclusive@4]` binds to it, not kernel32
--
-- Hence two questions rather than one, because the consumers want different answers:
--
--   support_winxp()      what the OUTPUT must run on
--   using_xp_toolset()   what is BUILDING it - v141_xp needs none of this file
--
-- THE TWO PIECES ARE INDEPENDENT, measured in Galactic. The stock v143 CRT calls FlsAlloc from
-- its own startup, so XP looks to need the msvcrt one - but an object on the link line is
-- included unconditionally where a library member is pulled only to resolve something undefined,
-- so kernel32's copies are never reached and the CRT's own references bind to the thunks too.
-- --support-winxp=on with --use-msvcrt=off gives subsystem 5.01 and no post-XP imports.
--
-- BOTH PATHS HAVE RUN ON 5.1.2600: the msvcrt one through this repository's ThunksTest, the
-- thunks-only one through Galactic's gpakviewer on a stock static UCRT. So --use-msvcrt really
-- is the size and deployment choice it claims to be, not a hedge against the UCRT misbehaving.

-- WHAT A REPOSITORY WANTS IS ITS OWN DECISION, so the defaults are passed in rather than fixed
-- here, exactly as common_options(defaultToolset) takes the toolset. Each is a string "on" or
-- "off", or left out for the file's own answer:
--
--     xp_options()                                      follow the toolset, no VC-LTL
--     xp_options { supportWinXP = "on", useMsvcrt = "on" }    XP and msvcrt.dll whatever builds it
--
-- A default is only a default: --support-winxp=off on the command line still wins over one.

-- This file's own directory, captured at include time (premake points _SCRIPT_DIR at each included file
-- while it runs), so the Windows 2000 post-link patcher under ../tools can be located relative to jbuild
-- itself, whatever the consumer's working directory is.
local XP_SCRIPT_DIR = _SCRIPT_DIR

-- ===== TARGET OS (--target-os) =====
-- An explicit --target-os supersedes the legacy support-winxp/toolset path and drives the subsystem
-- version, the YY-Thunks obj and the VC-LTL tier TOGETHER, so the three cannot drift apart. When
-- --target-os is absent, everything below falls back to the EXACT previous behavior - existing consumers
-- are byte-for-byte unaffected - and --target-os=winxp is identical to --support-winxp=on.
--
-- EVERYTHING IS PER ARCH, because 64-bit Windows begins at XP x64 (NT 5.2 / Server 2003): a target older
-- than XP has no 64-bit form, so its x86_64 column is XP x64's. Each arch carries:
--   sub       PE subsystem version (what the exe declares it needs); an explicit target always stamps it,
--             down for XP/2000 and up for 8/8.1/10/11. Distinct per OS, 10 and 11 alike at 10.00.
--   thunks    the YY-Thunks obj suffix (YY_Thunks_for_<suffix>.obj); nil = native there, so no thunks and
--             no subsystem lowering are needed (10/11). 8.1 reuses Win8 (YY ships no 8.1 obj).
--   vcltl     VC-LTL TargetPlatform, used only under --use-msvcrt; nil = msvcrt.dll is not available for
--             that arch. Win2000 x86 is nil: VC-LTL floors at XP and 2000's older msvcrt.dll (v6.10) lacks
--             exports the XP bindings assume. Win2000 x64 is XP x64's, which does have it.
--   xpEra     (per OS, not arch) true for the 2000/XP source flags Common.lua keys off support_winxp() for
--             (/arch:IA32 for pre-SSE2 CPUs, /Zc:threadSafeInit- for the XP loader's TLS bug); Vista+ none.
-- Windows 2000 is best-effort/unverified: YY-Thunks ships a Win2K obj, but the static UCRT's own floor is
-- XP, so the CRT may still reach for APIs 2000 lacks. XP is the first genuinely-proven rung.
local TARGET_OS = {
	win2000 = { order = 1, label = "Windows 2000", xpEra = true,
		x86    = { sub = "5.00",  thunks = "Win2K", vcltl = nil           },   -- real 2000; its msvcrt too old for VC-LTL
		x86_64 = { sub = "5.02",  thunks = "WinXP", vcltl = "5.2.3790.0"  } },  -- no 64-bit 2000 -> XP x64
	winxp   = { order = 2, label = "Windows XP", xpEra = true,
		x86    = { sub = "5.01",  thunks = "WinXP", vcltl = "5.1.2600.0"  },
		x86_64 = { sub = "5.02",  thunks = "WinXP", vcltl = "5.2.3790.0"  } },
	vista   = { order = 3, label = "Windows Vista",
		x86    = { sub = "6.00",  thunks = "Vista", vcltl = "6.0.6000.0"  },
		x86_64 = { sub = "6.00",  thunks = "Vista", vcltl = "6.0.6000.0"  } },
	win7    = { order = 4, label = "Windows 7",
		x86    = { sub = "6.01",  thunks = "Win7",  vcltl = "6.0.6000.0"  },
		x86_64 = { sub = "6.01",  thunks = "Win7",  vcltl = "6.0.6000.0"  } },
	win8    = { order = 5, label = "Windows 8",
		x86    = { sub = "6.02",  thunks = "Win8",  vcltl = "6.2.9200.0"  },
		x86_64 = { sub = "6.02",  thunks = "Win8",  vcltl = "6.2.9200.0"  } },
	win81   = { order = 6, label = "Windows 8.1",
		x86    = { sub = "6.03",  thunks = "Win8",  vcltl = "6.2.9200.0"  },
		x86_64 = { sub = "6.03",  thunks = "Win8",  vcltl = "6.2.9200.0"  } },
	win10   = { order = 7, label = "Windows 10",
		x86    = { sub = "10.00", thunks = nil,     vcltl = "10.0.19041.0" },
		x86_64 = { sub = "10.00", thunks = nil,     vcltl = "10.0.19041.0" } },
	win11   = { order = 8, label = "Windows 11",
		x86    = { sub = "10.00", thunks = nil,     vcltl = "10.0.19041.0" },
		x86_64 = { sub = "10.00", thunks = nil,     vcltl = "10.0.19041.0" } },
}

-- The chosen target, or nil for the legacy path. Defined up here so xp_options can list the allowed values.
function target_os()
	return _OPTIONS["target-os"]
end

local function os_info()
	local t = target_os()
	return t and TARGET_OS[t] or nil
end

function xp_options(defaults)
	defaults = defaults or {}

	-- The OS the OUTPUT must run on, oldest first. Supersedes --support-winxp (kept below for
	-- compatibility); leave both out to follow the toolset, exactly as before.
	local osAllowed = {}
	for key, info in pairs(TARGET_OS) do osAllowed[info.order] = { key, info.label } end
	newoption {
		trigger = "target-os",
		value = "OS",
		description = "Oldest Windows the binaries must run on (win2000 .. win11); supersedes --support-winxp",
		allowed = osAllowed
	}

	-- cmake's option(SUPPORT_WINXP ... ${USING_XP_TOOLSET}). With no default it follows the
	-- TOOLSET, which is what "supports XP" meant before the two could differ.
	newoption {
		trigger = "support-winxp",
		value = "VALUE",
		default = defaults.supportWinXP,
		description = "Produce binaries that run on Windows XP",
		allowed = {
			{ "on",  "VC-LTL5 and/or YY-Thunks as needed - the default under an XP toolset" },
			{ "off", "Whatever the toolset targets on its own" }
		}
	}

	-- ITS OWN SWITCH, not something --support-winxp turns on quietly: it changes which CRT every
	-- binary links. Worth having away from XP too - nothing to redistribute, and imports replace
	-- the static CRT, a fairly fixed ~130 KB a binary.
	newoption {
		trigger = "use-msvcrt",
		value = "VALUE",
		default = defaults.useMsvcrt,
		description = "Link Windows' own msvcrt.dll as the CRT, through VC-LTL5",
		allowed = {
			{ "on",      "VC-LTL5 in every configuration" },
			{ "release", "VC-LTL5 in Release only; Debug keeps the toolset's own CRT (and its debug heap / leak detection)" },
			{ "off",     "The toolset's own CRT" }
		}
	}

	-- XP's loader never patches a LoadLibrary'd module's _tls_index, so its thread_local reads
	-- garbage. Off because Common.lua already fixes that from the other end for everything that
	-- is not an executable, with /Zc:threadSafeInit-. On for a DLL with real thread_local of its
	-- own; note it takes an entry point that is not the CRT's.
	newoption {
		trigger = "yy-thunks-tls",
		value = "VALUE",
		default = defaults.yyThunksTLS,
		description = "Let YY-Thunks initialise a DLL's own TLS on XP",
		allowed = {
			{ "on",  "/ENTRY:DllMainCRTStartupForYY_Thunks on every SharedLib" },
			{ "off", "The CRT's own entry point" }
		}
	}
end

-- THE BUILD ENVIRONMENT, not the output. Entirely a question of the toolset: one ending _xp
-- exists for no other reason.
function using_xp_toolset()
	return _OPTIONS["toolset"]:match("_xp$") ~= nil
end

-- THE OUTPUT, and DELIBERATELY THE SAME GLOBAL Common.lua ALREADY DEFINES. Common.lua answers it
-- from the toolset, which was the whole truth until this file existed; several of its own
-- decisions hang off the answer and must follow the richer one:
--
--   /Zc:threadSafeInit-   a magic static's TLS guard breaks in a LoadLibrary'd DLL on XP
--                         WHATEVER BUILT IT, so this is the question it wants
--   /arch:IA32            the processors that run XP include ones with no SSE2 - again about
--                         where the binary lands, not about the compiler
--
-- Replacing it rather than adding a second name is what lets Common.lua stay byte-identical to
-- the copy in every other repository while still getting the right answer here. Lua resolves a
-- global at CALL time, so common_workspace() reaches this one as long as XP.lua was included
-- first - which the guard below insists on rather than leaving to chance.
if support_winxp == nil then
	error("XP.lua must be included after Common.lua - it takes over that file's support_winxp().")
end

function support_winxp()
	-- An explicit --target-os answers directly: only 2000/XP want the pre-SSE2 / XP-loader source flags.
	local info = os_info()
	if info then
		return info.xpEra == true
	end

	local option = _OPTIONS["support-winxp"]

	if option then
		return option == "on"
	end

	return using_xp_toolset()
end

-- The target needs the downlevel treatment (a lowered subsystem + YY-Thunks) rather than the toolset's
-- own native output. For an explicit --target-os that is any OS still carrying a thunks obj (2000..8.1);
-- for the legacy path it stays support_winxp() (XP), unchanged. v141_xp answers for itself, so is excluded.
function needs_downlevel()
	if using_xp_toolset() then
		return false
	end

	local info = os_info()
	if info then
		return info.x86.thunks ~= nil or info.x86_64.thunks ~= nil
	end

	return support_winxp()
end

function use_msvcrt()
	-- The plain option question. msvcrt availability is PER ARCH (Windows 2000 x86 has no VC-LTL tier, its
	-- msvcrt.dll being too old) and use_vc_ltl simply skips an arch with no tier; the menu also doesn't offer
	-- msvcrt for a 2000 target. So nothing OS-specific belongs here.
	local o = _OPTIONS["use-msvcrt"]
	return o == "on" or o == "release"
end

-- The filter VC-LTL is limited to, or nil for all configs. "release" uses "not Debug" rather than
-- "Release" so it covers EVERY non-Debug configuration - GTAC's "Public Release" and RelWithDebInfo
-- included - the same way Common.lua's DEPENDENCY_CONFIG and release flags decide release-ness. Only
-- Debug keeps the toolset's own static CRT, so its debug heap and leak detection (_CrtDumpMemoryLeaks /
-- _CrtSetDbgFlag) still work - the point of a debug diagnostic build.
function msvcrt_config_filter()
	return (_OPTIONS["use-msvcrt"] == "release") and "not configurations:Debug" or nil
end

-- Set once xp_workspace() has applied either piece at workspace scope, where it reaches every
-- project. The per-project entry points below then do nothing: linking YY-Thunks' object TWICE
-- is not a harmless duplicate but ~1100 duplicate symbols, and VC-LTL's directories said twice
-- are merely noise. This is what keeps ThunksTest's own use_vc_ltl()/use_yy_thunks() calls
-- correct under --toolset=v141_xp, where they are the only source of either, AND under
-- --toolset=v143 --support-winxp=on, where the workspace has already done it.
local workspaceVCLTL = false
local workspaceThunks = false

-- VC-LTL5 in place of the stock CRT.
--
-- The stock v143 CRT reaches for FlsAlloc, InitializeCriticalSectionEx and friends from its own
-- startup, none of which XP has. VC-LTL's binds to the msvcrt.dll built into Windows instead -
-- there since NT 4, and predating FLS entirely - so the CRT simply never asks.
--
-- THE TARGET PLATFORM IS PINNED rather than left to VC-LTL's own detection, which keys off
-- SupportWinXP or an "_xp" in the toolset name. Neither is true of a v143 project, and XP is the
-- whole point here. VC-LTL ships 5.1.2600.0 for Win32 ONLY and 5.2.3790.0 for x64 only - XP x64
-- reports itself as 5.2, as Server 2003 did - so the version has to follow the architecture.
-- Naming one for both is how an x64 build silently ends up with library directories that do not
-- exist, and the stock CRT linked because nothing failed.
--
-- CHECKED AT GENERATION TIME, because the failure is otherwise silent and late: with the variable
-- unset the paths resolve to nothing, the stock CRT gets linked, and the result builds and runs
-- perfectly here while being unable to load on XP.
local VC_LTL_PLATFORMS = {
	-- 6.0.6000.0 is VC-LTL's own floor and the one that ships both architectures. It is what
	-- --use-msvcrt=on --support-winxp=off asks for: msvcrt.dll for the size, Vista for the floor.
	{ arch = "x86",    xp = "5.1.2600.0", plain = "6.0.6000.0", lib = "Win32" },
	{ arch = "x86_64", xp = "5.2.3790.0", plain = "6.0.6000.0", lib = "x64" },
}

function use_vc_ltl()
	if workspaceVCLTL then
		return
	end

	local root = os.getenv("VC_LTL_Root")

	-- nil, or "not configurations:Debug" when --use-msvcrt=release. Added to every filter below so a Debug
	-- build in that mode gets none of VC-LTL and links the toolset's own (debug) CRT instead - while every
	-- release-type config (Release, Public Release, ...) still binds msvcrt.dll.
	local cfg = msvcrt_config_filter()

	for _, platform in ipairs(VC_LTL_PLATFORMS) do
		-- An explicit --target-os picks the tier for its own floor, PER ARCH, and nil skips an arch with
		-- no msvcrt (Windows 2000 x86 - its msvcrt.dll is too old, so that arch stays on the static CRT);
		-- the legacy path keeps XP-or-Vista.
		local info = os_info()
		local version = (info and info[platform.arch].vcltl)
			or (not info and (support_winxp() and platform.xp or platform.plain))

		if version then
			if not root or not os.isdir(root .. "/TargetPlatform/" .. version .. "/lib") then
				error("VC-LTL5 is needed here. Set VC_LTL_Root to the extracted VC-LTL-Binary.7z "
					.. "(https://github.com/Chuyu-Team/VC-LTL5/releases). Looked for "
					.. "TargetPlatform/" .. version .. ".")
			end

			-- THE SEPARATOR IS OURS TO ADD, not something the variable has to carry. The check above
			-- inserts one; emitting "$(VC_LTL_Root)TargetPlatform/" did not, so a value without a
			-- trailing slash passed the check and then produced ...VC-LTL5TargetPlatform. Windows
			-- takes a doubled separator perfectly happily - measured, C:\x\/y resolves the same as
			-- C:\x\y - so one slash here is correct whichever way the variable is written.
			local ltl = "$(VC_LTL_Root)/TargetPlatform/"

			local terms = { "architecture:" .. platform.arch }
			if cfg then table.insert(terms, cfg) end

			filter (terms)
				includedirs { ltl .. "header", ltl .. version .. "/header" }
				libdirs { ltl .. version .. "/lib/" .. platform.lib }
		end
	end

	filter {}

	-- These tell the headers above they are VC-LTL's, so they are scoped exactly as the headers are:
	-- under --use-msvcrt=release a Debug build gets neither and stays on the stock CRT.
	filter (cfg and { cfg } or {})
		defines { "_Build_By_LTL=1", "_LTL_Core_Version=5" }

	filter {}

	-- The import libraries above replace libucrt and libvcruntime, which are the linker's default
	-- names only for a static CRT. Common.lua already says this at workspace scope; repeating it
	-- is what makes the function correct when called on its own.
	staticruntime "On"
end

-- YY-Thunks: the Win32 half of the same problem, where VC-LTL is the CRT half.
--
-- One object file that DEFINES the __imp__ symbols for APIs XP lacks, so a call windows.h
-- compiled as `call [__imp__AcquireSRWLockExclusive@4]` binds to it rather than to kernel32. An
-- object on the link line is included unconditionally - a library member is pulled only to
-- resolve something still undefined - which is why this works where a static library cannot.
--
-- Named through linkoptions rather than links{} so it lands verbatim: premake would otherwise try
-- to interpret a path with an extension as a project name. ONE spelling, because xp_no_thunks()
-- takes it back out by exact string match and a second copy of the path would not match.
--
-- THE SEPARATOR AFTER THE MACRO IS OURS, as it is for VC-LTL above: this read
-- "$(YY_Thunks_Root)objs/..." and so quietly required the variable to end in a slash, which the
-- check below does not require and nothing tells you. YY-Thunks has no such convention of its
-- own - VC-LTL's documentation does, which is how the two came to differ.
-- PER ARCH: the obj's dir is x86 or x64, and its suffix follows --target-os for THAT arch - Windows 2000
-- x64 uses XP's (WinXP), there being no 64-bit Windows 2000; 8.1 reuses Win8; the legacy path keeps WinXP.
-- A function rather than one string, so the suffixes can differ by arch (they do only for 2000) and
-- xp_no_thunks() rebuilds the SAME string, under the same arch filter, to remove it.
local function yy_thunks_obj(arch)
	local info = os_info()
	local suffix = (info and info[arch].thunks) or "WinXP"
	local dir = (arch == "x86_64") and "x64" or "x86"
	return "\"$(YY_Thunks_Root)/objs/" .. dir .. "/YY_Thunks_for_" .. suffix .. ".obj\""
end

function use_yy_thunks()
	if workspaceThunks then
		return
	end

	local root = os.getenv("YY_Thunks_Root")

	for _, arch in ipairs({ "x86", "x86_64" }) do
		local info = os_info()
		local suffix = (info and info[arch].thunks) or "WinXP"
		local dir = (arch == "x86_64") and "x64" or "x86"
		if not root or not os.isfile(root .. "/objs/" .. dir .. "/YY_Thunks_for_" .. suffix .. ".obj") then
			error("YY-Thunks is needed here. Set YY_Thunks_Root to the extracted "
				.. "YY-Thunks-Objs.zip (https://github.com/Chuyu-Team/YY-Thunks/releases). "
				.. "Looked for objs/" .. dir .. "/YY_Thunks_for_" .. suffix .. ".obj.")
		end

		filter { "architecture:" .. arch }
			linkoptions { yy_thunks_obj(arch) }
	end

	filter {}

	-- /OPT:REF EVEN IN DEBUG, which is not the usual advice and is needed here. The object holds a
	-- thunk for around 1100 APIs, and some of them reach other DLLs directly rather than through
	-- GetProcAddress - so without dead-code removal the exe acquires a static dependency on every
	-- one. Measured: 23 imported DLLs in Debug against 2 in Release, including ESENT and WINHTTP
	-- for a program that does nothing of the sort. Release already sets this; Debug does not.
	linkoptions { "/OPT:REF" }

	-- Both are incompatible with /OPT:REF and would otherwise be reported as LNK4075 on every
	-- Debug link. Saying so here is the same decision stated once rather than warned about twice.
	editandcontinue "Off"
	linkoptions { "/INCREMENTAL:NO" }

	-- LNK4075: ignoring /EDITANDCONTINUE due to /OPT:ICF. The remaining one comes from VC-LTL's
	-- own prebuilt objects, which carry the directive and cannot be recompiled from here. Turning
	-- it off above covers our code; this covers theirs.
	linkoptions { "/ignore:4075" }
end

-- THE SUBSYSTEM HAS TO BE SAID OUT LOUD on a toolset that is not v141_xp, whose Toolset.props
-- sets it from its own targets. v143 emits 6.00 and XP refuses that whatever the imports look
-- like - a load failure at process start, not a missing feature.
--
-- AND IT HAS TO BE SAID PER KIND, which is why Common.lua deliberately does not say it at all:
-- one /SUBSYSTEM:CONSOLE at workspace scope turns every WindowedApp here into a console program.
-- j-xp.cmake needs a generator expression for this because CMake reads WIN32_EXECUTABLE too
-- early; premake's kind filters answer it directly.
--
-- XP x64 reports itself as 5.2, as Server 2003 did - so the version follows the architecture,
-- and a project naming 5.01 for both is wrong on one of them.
-- Per arch, from --target-os (down for XP/2000, up for 8/8.1/10/11); the legacy path keeps XP's 5.01/5.02.
local function subsystem_version(arch)
	local info = os_info()
	if info then
		return info[arch].sub
	end
	return arch == "x86" and "5.01" or "5.02"
end

-- "maj.min" as a comparable number (5.00->500, 5.02->502, 6.00->600, 10.00->1000) - a plain string
-- compare is wrong ("10.00" < "5.02" lexically).
local function ver_num(v)
	local maj, min = v:match("^(%d+)%.(%d+)$")
	return tonumber(maj) * 100 + tonumber(min)
end

-- The linker floors /SUBSYSTEM at 5.01 (x86) / 5.02 (x64): anything lower is LNK4010 and silently
-- becomes 6.0. So the LINK uses the greater of the wanted version and the floor (no warning, no 6.0
-- surprise), and a wanted-below-floor target (only Windows 2000 x86, 5.00) is corrected to its real
-- value by a post-link PE patch - see patch_subsystem_postbuild().
local SUBSYSTEM_FLOOR = { x86 = "5.01", x86_64 = "5.02" }

local function link_subsystem_version(arch)
	local want = subsystem_version(arch)
	local floor = SUBSYSTEM_FLOOR[arch] or "5.01"
	return ver_num(want) < ver_num(floor) and floor or want
end

local function needs_subsystem_patch(arch)
	return ver_num(subsystem_version(arch)) < ver_num(SUBSYSTEM_FLOOR[arch] or "5.01")
end

local SUBSYSTEM_VERSIONS = {
	{ arch = "x86",    version = link_subsystem_version("x86") },
	{ arch = "x86_64", version = link_subsystem_version("x86_64") },
}

local SUBSYSTEMS = {
	{ kind = "ConsoleApp",  subsystem = "CONSOLE" },
	{ kind = "WindowedApp", subsystem = "WINDOWS" },
	-- A DLL has no subsystem of its own that matters, but the field is still stamped into the
	-- header and still checked, so it gets the same treatment.
	{ kind = "SharedLib",   subsystem = "WINDOWS" },
}

local function subsystem_linkoptions(subsystem, kindFilter)
	for _, target in ipairs(SUBSYSTEM_VERSIONS) do
		local terms = { "architecture:" .. target.arch }

		if kindFilter then
			table.insert(terms, 1, kindFilter)
		end

		filter (terms)
			linkoptions { "/SUBSYSTEM:" .. subsystem .. "," .. target.version }
	end

	filter {}
end

-- Post-link PE patch for a below-floor target (only Windows 2000 x86, 5.00): the link above used the
-- 5.01 floor, so this stamps the real OS/subsystem 5.0 into the header afterwards. Non-StaticLib only
-- (an archive has no PE header). The patcher is compiled on first use by its wrapper, not a solution
-- project - tools/pesubsys. A no-op for every other target (nothing is below its floor).
local function patch_subsystem_postbuild()
	local wrapper = path.translate(path.getabsolute("../tools/pesubsys/pesubsys.cmd", XP_SCRIPT_DIR), "\\")

	for _, arch in ipairs({ "x86", "x86_64" }) do
		if needs_subsystem_patch(arch) then
			local maj, min = subsystem_version(arch):match("^(%d+)%.(%d+)$")

			-- $(TargetPath) is MSBuild's absolute path to the primary output - robust wherever the
			-- post-build runs, unlike premake's own buildtarget token which can come out relative.
			filter { "architecture:" .. arch, "not kind:StaticLib" }
				postbuildcommands { string.format('call "%s" "$(TargetPath)" %d %d',
					wrapper, tonumber(maj), tonumber(min)) }
		end
	end

	filter {}
end

-- FOR A PROJECT THAT SUPPLIES THE DOWNLEVEL APIS ITSELF, and so must not also link an object
-- defining them. Downlevel is the whole example: it EXPORTS GetTickCount64 for XP, and
-- YY_Thunks_for_WinXP.obj defines it too, so both on one link line is LNK2005 and then LNK1169.
-- The two are ALTERNATIVES - the same job answered with a DLL to ship or an object to link - and
-- a project that is one of them cannot be built out of the other.
--
--     xp_no_thunks()   -- after common_project(), before anything else adds link options
--
-- Only the object is taken back out. /OPT:REF and the rest were added on its account but are
-- harmless without it, and /OPT:REF in particular is still wanted.
function xp_no_thunks()
	-- Per arch, matching how use_yy_thunks added it (the x86/x64 obj strings differ for Windows 2000).
	for _, arch in ipairs({ "x86", "x86_64" }) do
		filter { "architecture:" .. arch }
			removelinkoptions { yy_thunks_obj(arch) }
	end

	filter {}
end

-- FOR A PROJECT THAT SETS ITS OWN TOOLSET, and so cannot be served by xp_workspace() - here,
-- Downlevel and ThunksTest, which are v143 inside a workspace that may well be v141_xp. It names
-- its own subsystem because it knows its own kind, where the workspace has to filter for it.
--
--     xp_subsystem("CONSOLE")   -- or "WINDOWS"
--
-- Does nothing once xp_workspace() has covered the whole tree, so the two cannot both fire and
-- leave two /SUBSYSTEM options on one link line.
function xp_subsystem(subsystem)
	if workspaceThunks then
		return
	end

	subsystem_linkoptions(subsystem)
	patch_subsystem_postbuild()
end

function xp_workspace()
	-- STATIC LIBRARIES WANT NONE OF THIS and are excluded throughout: the thunks object is pulled
	-- into whatever links them, so linking it here as well only collides, and premake routes
	-- linkoptions to <Lib> for a StaticLib, where lib.exe has no idea what /OPT:REF means.
	if use_msvcrt() then
		use_vc_ltl()
		workspaceVCLTL = true
	end

	-- The Win32 APIs, a separate question from the CRT, applied when the target is downlevel: an explicit
	-- --target-os of 2000..8.1, or - unchanged - the legacy support_winxp() (XP). v141_xp and a native
	-- target (10/11, or support-winxp=off) answer for themselves and need nothing added.
	if not needs_downlevel() then
		filter {}
		return
	end

	filter { "not kind:StaticLib" }
		use_yy_thunks()

	filter {}

	for _, entry in ipairs(SUBSYSTEMS) do
		subsystem_linkoptions(entry.subsystem, "kind:" .. entry.kind)
	end

	-- Windows 2000 x86 only: correct the header 5.01 -> 5.00 after linking (see the function).
	patch_subsystem_postbuild()

	-- DLLs only - the loader handles an executable's own TLS either way. The alternatename hands
	-- YY-Thunks the CRT entry it replaces, decorated on x86.
	if _OPTIONS["yy-thunks-tls"] == "on" then
		filter { "kind:SharedLib", "architecture:x86" }
			linkoptions {
				"/ENTRY:DllMainCRTStartupForYY_Thunks",
				"/alternatename:_YY_ThunksOriginalDllMainCRTStartup@12=__DllMainCRTStartup@12"
			}

		filter { "kind:SharedLib", "architecture:x86_64" }
			linkoptions {
				"/ENTRY:DllMainCRTStartupForYY_Thunks",
				"/alternatename:YY_ThunksOriginalDllMainCRTStartup=_DllMainCRTStartup"
			}
	end

	filter {}

	workspaceThunks = true
end
