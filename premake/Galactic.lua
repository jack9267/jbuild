-- Consuming Galactic from premake, meant to be copied between repositories unchanged.
--
--     include "Galactic.lua"
--     galactic_workspace()                      -- after common_workspace()
--     galactic_links { "Direct3D9Renderer" }    -- inside a project that links the engine
--
-- The premake counterpart of Galactic's cmake\j-galactic.cmake, for the same reason Common.lua
-- exists: a repository that wants the engine names the MODULES it wants rather than restating the
-- search paths, the library set and their order.
--
-- Separate from Common.lua deliberately: that file is what every repository built this way shares
-- whether or not it has heard of Galactic, and one that links no engine should not carry engine
-- paths. It also puts the install requirement below next to the thing that requires it.
--
-- GALACTIC MUST BE INSTALLED, NOT MERELY BUILT. `cmake --install <binaryDir> --config <Config>`
-- is what populates Lib\<platform>\<toolset>_static\<configuration>; `cmake --build` alone never
-- writes a byte of it. Skip it and the link picks up a STALE library with no warning - the
-- symptom is a fix that appears to do nothing, or a crash only in the configuration you forgot.
-- Debug and Release go stale independently, so a fresh Debug says nothing about Release.

-- The engine's Lib directory WITHOUT the configuration on the end, for copy_dependency and
-- copy_single_dependency. Galactic installs a few runtime files beside its libraries -
-- WebView2Loader.dll among them - and a consumer that needs one wants this rather than a path
-- written out again.
GALACTIC_LIBS = "$(galactic_home)\\Lib\\$(PlatformTarget)\\$(PlatformToolset)_static"

-- The search paths and the one define, at workspace scope. Called AFTER common_workspace() so
-- the dependency trees keep the order they are searched in. The paths are left as MSBuild macros
-- so switching platform, toolset or configuration needs no regeneration.
--
-- ENGINE_STATIC selects the static build of the engine's headers, the only one these libraries
-- are. Set for EVERY project rather than only those linking the engine: it costs a project that
-- includes no Galactic header nothing, and a define that is only correct when you remember a
-- second call is the worse trade.
--
-- GALACTIC_OPENSSL picks OpenSSL's RAND_bytes for secure random bytes. On Windows it decides
-- nothing - MathUtil.cpp takes CryptGenRandom first - and the engine's own build sets it anyway;
-- it is here so a consumer's define set matches GTAC's, which is the point of a copied file.
--
-- NOT here: UNICODE and _UNICODE, which characterset "Unicode" in Common.lua already defines and
-- without which Galactic's headers do not compile; and WIN32_LEAN_AND_MEAN, which those headers
-- define themselves, so repeating it on the command line is a C4005 on every file.
function galactic_workspace()
	defines { "GALACTIC_OPENSSL=1", "ENGINE_STATIC=1" }

	includedirs { "$(galactic_home)\\include" }

	libdirs {
		"$(galactic_home)\\Lib\\$(PlatformTarget)\\$(PlatformToolset)_static\\" .. DEPENDENCY_CONFIG
	}
end

-- The engine and the third-party libraries it is built against. Every consumer needs all of
-- these whatever else it uses. Their search paths are Common.lua's, not this file's, because
-- $(jdependencies_home) is a tree in its own right that a repository can use without Galactic.
local coreStatic = {
	"Galactic_static",

	-- SDL2 IS THE ONE TAKEN AS A DLL. Both are installed, and the import library is SDL2.lib in
	-- BOTH configurations, so this one name is right everywhere - only the DLL changes name, which
	-- is copy_dependency's job. It costs the binary its self-containment: anything linking
	-- Galactic needs SDL2.dll beside it at RUN time, wherever it ends up.
	"SDL2",
	"zlib_static",
	"png_static",
	"bzip2_static",
	"tinyxml_static",
	"freetype_static",
}

-- setupapi is SDL2's, so it belongs to the core rather than to any one module. The rest of the
-- Windows import libraries are already linked at workspace scope by Common.lua.
local coreSystem = {
	"setupapi",
}

-- The system libraries a module needs on top of the core. ONLY Direct3D9Renderer is verified -
-- it is what DDrawWrap links. Others are absent rather than guessed: a wrong entry is a link
-- error in someone else's repository, an absent one is a line they add themselves.
--
-- The installed tree holds Audio, Cef, Direct3D9Renderer, Direct3D11Renderer, FileIntegrity, IPC,
-- JSScripting, LuaScripting, LucasFont, LucasGUI, Multiplayer, Network, OpenGLRenderer,
-- RemoteScripting, RmlGUI, SDLApp, Scripting, SquirrelScripting, WindowsApp.
local moduleSystem = {
	Direct3D9Renderer = { "d3d9", "d3dx9" },
}

-- Link the named modules and everything they rest on.
--
-- ORDER IS LOAD-BEARING, which is why this is a function rather than a list to copy: the linker
-- takes the first definition it finds, so modules come before the engine they call into and every
-- static library before the import libraries.
function galactic_links(modules)
	local all = {}

	for _, name in ipairs(modules or {}) do
		table.insert(all, name .. "_static")
	end

	for _, name in ipairs(coreStatic) do
		table.insert(all, name)
	end

	for _, name in ipairs(modules or {}) do
		for _, extra in ipairs(moduleSystem[name] or {}) do
			table.insert(all, extra)
		end
	end

	for _, name in ipairs(coreSystem) do
		table.insert(all, name)
	end

	links (all)
end

-- WHY THIS DOES NOT COPY SDL2.dll ITSELF. Copying it here would break when two projects share an
-- output directory: both post-build steps write the same file, MSBuild runs projects in parallel
-- under /m, and one fails with it locked. Measured - DDrawWrap and RendererProbe both write
-- Bin\x86, and the parallel build failed four commands where /m:1 passed.
--
-- So the copy has ONE OWNER: a repository calls copy_dependency(DEPENDENCIES, "SDL2") in the
-- project that ships, and everything sharing that directory is served by it.

