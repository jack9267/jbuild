-- ModLauncher: its tree at $(jmodlauncher_home) - include\, and Lib\<arch>\<toolset>_static\<Debug|Release> as
-- ModLauncher's own JBuild build writes it, the same shape as Galactic's and the dependencies'.
--
--     include "jbuild/premake/ModLauncher.lua"
--     modlauncher_workspace()                    -- after galactic_workspace(): headers and libraries searched
--     modlauncher_links { "ModLauncher", "HackSupport" }   -- in a project that uses them
--     modlauncher_copy_xlive()                   -- in ONE project per output directory
--     modlauncher_copy_updater()                 -- likewise, for a launcher that updates itself

-- Where its libraries and runtime files are, without the configuration, which callers add.
MODLAUNCHER_LIBS = "$(jmodlauncher_home)\\Lib\\$(PlatformTarget)\\$(PlatformToolset)_static"

function modlauncher_workspace()
	includedirs { "$(jmodlauncher_home)\\include" }
	libdirs { MODLAUNCHER_LIBS .. "\\" .. DEPENDENCY_CONFIG }
end

-- What its tree holds, for a consumer to pick from:
--
--     CrashHandler   CustomWindow   DiscordRichPresence   HackSupport
--     IPCServer      Injection      ModLauncher           Taskbar
--
-- NO IMPLICIT CORE, unlike galactic_links(), where everything rests on Galactic_static: these are separate
-- pieces, so a consumer names what it links, in the order it needs. The TLSFixup* libraries beside them are
-- ModLauncher's own XP thread-local-storage tests, not something to link.
function modlauncher_links(modules)
	local all = {}

	for _, name in ipairs(modules or {}) do
		table.insert(all, name .. "_static")
	end

	links (all)
end

-- xlive.dll, the Games for Windows - LIVE replacement, which has to sit beside whatever loads it.
-- copy_single_dependency, not copy_dependency: ITS NAME DOES NOT CHANGE between builds (no _d, no _x64),
-- only the directory it comes from.
function modlauncher_copy_xlive()
	copy_single_dependency(MODLAUNCHER_LIBS, "xlive.dll")
	copy_single_dependency(MODLAUNCHER_LIBS, "xlive.pdb")
end

-- ModLauncher's Updater (Updater_d.exe in Debug), which a launcher runs to replace itself. An exe, so not
-- copy_dependency's (that copies .dll/.pdb).
function modlauncher_copy_updater()
	filter { "configurations:Debug" }
		postbuildcommands {
			'{COPYFILE} "' .. MODLAUNCHER_LIBS .. '\\Debug\\Updater_d.exe" "%{cfg.targetdir}"',
			'{COPYFILE} "' .. MODLAUNCHER_LIBS .. '\\Debug\\Updater_d.pdb" "%{cfg.targetdir}"',
		}
	filter { "not configurations:Debug" }
		postbuildcommands {
			'{COPYFILE} "' .. MODLAUNCHER_LIBS .. '\\Release\\Updater.exe" "%{cfg.targetdir}"',
			'{COPYFILE} "' .. MODLAUNCHER_LIBS .. '\\Release\\Updater.pdb" "%{cfg.targetdir}"',
		}
	filter {}
end
