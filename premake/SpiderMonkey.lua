-- SpiderMonkey: the SDK SpiderMonkeyBuilder lays out at $(jspidermonkey_home)\esr<NN>\{include,Lib\<plat>\<config>}.
-- premake's side of cmake/j-spidermonkey.cmake and make/spidermonkey.mk - keep the three in step.
--
--     include "jbuild/premake/SpiderMonkey.lua"
--     spidermonkey_workspace() -- optional: the SDK's headers and libraries on every project's search path
--     spidermonkey_headers()   -- in a project whose sources include the JS headers
--     spidermonkey_links()     -- in a project that links the engine (implies spidermonkey_headers())
--     spidermonkey_copy()      -- in ONE project per output directory: mozjs-<NN>.dll beside it
--
-- Including this file is what declares --spidermonkey-version, and so what makes JBuild.ps1 offer the
-- installed ESRs to choose from.

newoption {
	trigger = "spidermonkey-version",
	value = "NN",
	description = "SpiderMonkey ESR to build against ($(jspidermonkey_home)\\esr<NN>)",
	default = "140",
}

function spidermonkey_version()
	return _OPTIONS["spidermonkey-version"]
end

-- <root>\esr<NN>. The version is in the directory AND in the library name (mozjs-<NN>).
function spidermonkey_root()
	return "$(jspidermonkey_home)\\esr" .. spidermonkey_version()
end

-- The SDK's include and library directories for every project, for a workspace where many projects reach
-- the engine. Windows only: the Makefile build takes them from make/spidermonkey.mk.
function spidermonkey_workspace()
	if os.target() ~= "windows" then
		return
	end

	includedirs { spidermonkey_root() .. "\\include" }
	libdirs { spidermonkey_root() .. "\\Lib\\$(PlatformTarget)\\" .. DEPENDENCY_CONFIG }
end

-- What any source including the JS headers needs:
--   esr102+  /Zc:preprocessor - js/ProtoKey.h nests argument macros (JS_FOR_EACH_PROTOTYPE ->
--            JS_FOR_PROTOTYPES_ with IF_INTL/IF_WASM_TYPE) that MSVC's traditional preprocessor mis-expands,
--            leaving a malformed JSProtoKey enum in jspubtd.h, which jsapi.h includes. Mozilla builds with
--            clang-cl; the conformant preprocessor matches it.
--   esr140+  /utf-8, which its bundled {fmt} enforces with a static_assert, and XP_WIN, without which
--            mozilla/UniquePtrExtensions.h #errors "Unsupported OS?".
-- Off Windows, make/spidermonkey.mk's SPIDERMONKEY_INCLUDE carries the headers and XP_UNIX/XP_DARWIN.
function spidermonkey_headers()
	if os.target() ~= "windows" then
		buildoptions { "$(SPIDERMONKEY_INCLUDE)" }
		return
	end

	includedirs { spidermonkey_root() .. "\\include" }

	local version = tonumber(spidermonkey_version()) or 0
	filter { "action:vs*" }
		if version >= 102 then
			buildoptions { "/Zc:preprocessor" }
		end
		if version >= 140 then
			buildoptions { "/utf-8" }
			defines { "XP_WIN" }
		end
	filter {}
end

-- mozjs-<NN>.lib keeps that one name in every configuration - only the DLL is renamed (mozjs-<NN>_d.dll) -
-- and the SDK's library path has NO toolset segment, unlike the dependency tree's and Galactic's.
-- Off Windows the Makefile links it (spidermonkey.mk's SPIDERMONKEY_LDFLAGS/LDLIBS).
function spidermonkey_links()
	spidermonkey_headers()

	if os.target() ~= "windows" then
		return
	end

	libdirs { spidermonkey_root() .. "\\Lib\\$(PlatformTarget)\\" .. DEPENDENCY_CONFIG }
	links { "mozjs-" .. spidermonkey_version() }
end

-- ONE project per output directory, or two post-build steps race for the same file. From esr140 the SDK is
-- the one DLL (no nspr4/plc4/plds4 beside it).
function spidermonkey_copy()
	copy_dependency(spidermonkey_root() .. "\\Lib\\$(PlatformTarget)", "mozjs-" .. spidermonkey_version())
end
