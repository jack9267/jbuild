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
function xp_options(defaults)
	defaults = defaults or {}

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
	local option = _OPTIONS["support-winxp"]

	if option then
		return option == "on"
	end

	return using_xp_toolset()
end

function use_msvcrt()
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
		local version = support_winxp() and platform.xp or platform.plain

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
local YY_THUNKS_OBJ = "\"$(YY_Thunks_Root)/objs/$(PlatformShortName)/YY_Thunks_for_WinXP.obj\""

function use_yy_thunks()
	if workspaceThunks then
		return
	end

	local root = os.getenv("YY_Thunks_Root")

	for _, platform in ipairs({ "x86", "x64" }) do
		if not root or not os.isfile(root .. "/objs/" .. platform .. "/YY_Thunks_for_WinXP.obj") then
			error("YY-Thunks is needed here. Set YY_Thunks_Root to the extracted "
				.. "YY-Thunks-Objs.zip (https://github.com/Chuyu-Team/YY-Thunks/releases). "
				.. "Looked for objs/" .. platform .. ".")
		end
	end

	linkoptions { YY_THUNKS_OBJ }

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
local SUBSYSTEM_VERSIONS = {
	{ arch = "x86",    version = "5.01" },
	{ arch = "x86_64", version = "5.02" },
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
	removelinkoptions { YY_THUNKS_OBJ }
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
end

function xp_workspace()
	-- STATIC LIBRARIES WANT NONE OF THIS and are excluded throughout: the thunks object is pulled
	-- into whatever links them, so linking it here as well only collides, and premake routes
	-- linkoptions to <Lib> for a StaticLib, where lib.exe has no idea what /OPT:REF means.
	if use_msvcrt() then
		use_vc_ltl()
		workspaceVCLTL = true
	end

	-- The Win32 APIs, a separate question from the CRT, so this follows support_winxp(). v141_xp
	-- already answers for both and needs nothing added.
	if not support_winxp() or using_xp_toolset() then
		filter {}
		return
	end

	filter { "not kind:StaticLib" }
		use_yy_thunks()

	filter {}

	for _, entry in ipairs(SUBSYSTEMS) do
		subsystem_linkoptions(entry.subsystem, "kind:" .. entry.kind)
	end

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
