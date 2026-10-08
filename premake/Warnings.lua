-- MSVC warning policy. Copied between repositories unchanged.
--
--     include "Warnings.lua"
--     warnings_options()     -- before the workspace, beside common_options()
--     warnings_workspace()   -- after common_workspace()
--
-- Port of the cmake j-warnings.cmake, keeping its key property: the LEVEL is only touched when
-- asked for, so a repo that says nothing keeps its own (this one is deliberately at 3). The
-- suppressions are unconditional, as there; they cost nothing when the warning cannot fire.

function warnings_options()
	-- The counterpart of -DCUSTOM_MSVC_WARNING_LEVEL=4. Unset, nothing here changes the level.
	newoption {
		trigger = "warning-level",
		value = "N",
		description = "MSVC warning level to force, 0 to 4. Unset leaves the repository's own",
		allowed = {
			{ "0", "/W0 - no warnings at all" },
			{ "1", "/W1" },
			{ "2", "/W2" },
			{ "3", "/W3 - the usual default" },
			{ "4", "/W4" }
		}
	}
end

function warnings_workspace()
	local level = _OPTIONS["warning-level"]

	if level == "0" then
		warnings "Off"
	elseif level == "3" then
		warnings "Default"
	elseif level == "4" then
		warnings "High"
	elseif level == "1" or level == "2" then
		-- premake has no name for these two: Off, Default, High, Extra and Everything map to /W0,
		-- /W3, /W4, /W4 and /Wall. This goes on after <WarningLevel>, and the last /W wins.
		buildoptions { "/W" .. level }
	end

	-- Unreferenced formal parameter. Level 4, and unavoidable in code implementing an interface it
	-- did not design.
	disablewarnings { "4100" }

	-- Inline asm assigning to FS:0 - installing a SEH handler by hand, seen by /SAFESEH.
	disablewarnings { "4733" }

	-- Exported class needs a dll-interface. Fires on an exported class with a standard library
	-- member, where the advice is wrong: both sides use the same toolset and static runtime.
	disablewarnings { "4251" }

	-- LNK4197: export specified twice - a symbol exported by both __declspec and the .def.
	linkoptions { "/ignore:4197" }

	-- LNK4221: object file defines no new public symbols - a translation unit behind an #if, or a
	-- .cpp that exists only to build a precompiled header. Noise, not a finding. It sits in
	-- cmake\j-common.cmake rather than j-warnings.cmake, so a side-by-side comparison misses it.
	linkoptions { "/ignore:4221" }

	-- NOTHING HERE FOR LNK4006, deliberately. It fired on every static library for a while, from the
	-- librarian not the linker: lib.exe MERGES what it is handed instead of resolving against it, so the
	-- workspace's import libraries were copied into the archive, each bringing a duplicate
	-- __NULL_IMPORT_DESCRIPTOR. Silencing it here was the wrong fix and was removed - Common.lua stopped
	-- handing a StaticLib those links at all, which is the cause. On an executable LNK4006 is a real
	-- symbol defined twice and should still be heard.
end

-- premake routes linkoptions to the right tool itself, so a static library gets these in <Lib>,
-- where LNK4221 comes from, and an executable or DLL in <Link>. Verified both ways.
