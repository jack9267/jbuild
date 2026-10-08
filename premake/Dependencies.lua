-- The installed dependency trees. Copied between repositories unchanged.
--
--     include "Dependencies.lua"
--     dependencies_workspace()   -- after common_workspace(), BEFORE galactic_workspace()
--
-- Port of the cmake j-dependencies.cmake. Separate from Common.lua because every line here
-- assumes %jdependencies_home% exists, and Common.lua has to work without it.
--
-- ORDER MATTERS - search paths are tried in append order - and Galactic.lua needs this file: it
-- links SDL2, zlib, png, bzip2, tinyxml and freetype, all of which live in this tree.

-- Without the configuration on the end: copy_dependency appends Debug or Release itself.
DEPENDENCIES = "$(jdependencies_home)\\Lib\\$(PlatformTarget)\\$(PlatformToolset)_static"

function dependencies_workspace()
	-- The STATIC defines each tell one library's headers to stop decorating their API with
	-- __declspec(dllimport). Get one wrong and the symbol is looked for as __imp_<name>. Here rather
	-- than Common.lua because each names a library in THIS tree.
	--
	-- SDL_MAIN_HANDLED is not linkage: it stops SDL_main.h doing `#define main SDL_main` to install its
	-- own WinMain. Nothing here wants that (every executable declares wmain/wWinMain, which SDL never
	-- rewrites), but saying it up front means the entry point doesn't depend on how it is spelled. Found
	-- when /Yu discarded the define RendererProbe carried itself and the link failed on unresolved _main.
	defines {
		"CURL_STATICLIB",
		"SDL2_STATIC",
		"SDL_MAIN_HANDLED",
		"ASMJIT_STATIC",
		"RMLUI_STATIC_LIB"
	}

	-- The DirectX SDK's import libraries, NOT in the Windows SDK - dxerr.lib exists nowhere else, and
	-- is the whole reason $(dxsdk_dir) is searched.
	--
	-- Not on a static library, for the reason Common.lua's link list spells out: lib.exe merges what it
	-- is handed into the archive instead of resolving against it.
	filter { "not kind:StaticLib" }
		links {
			"dxerr",
			"dxguid",
			"dsound"
		}

	filter {}

	-- MSBuild macros, so switching platform, toolset or configuration needs no regeneration. A
	-- directory that does not exist is ignored and an unset macro never matches.
	--
	-- $(WindowsSDK_IncludePath) is listed FIRST, ahead of the DirectX SDK, so the modern Windows SDK's
	-- own d2d1/dwrite/wincodec/dxgi headers win. The June-2010 DXSDK ships ancient copies of those same
	-- headers next to its exclusive ones (dxerr.h, the old d3dx/XNAMath); without the Windows SDK ahead
	-- of it, those old copies shadow the real ones and break any modern Direct2D/WIC/DWrite consumer
	-- (e.g. the WebView2 host). This keeps the DXSDK global - only its exclusive headers are now reached.
	includedirs {
		"$(WindowsSDK_IncludePath)",
		"$(dxsdk_dir)\\include",
		"$(jdependencies_home)\\include",
		"$(jdependencies_home)\\include\\mongoose6",
		"$(jdependencies_home)\\include\\lua5.3"
	}

	libdirs {
		"$(dxsdk_dir)\\Lib\\$(PlatformTarget)",
		"$(jdependencies_home)\\Lib\\$(PlatformTarget)\\$(PlatformToolset)_static\\" .. DEPENDENCY_CONFIG
	}
end
