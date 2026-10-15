-- jbuildmake: writes what a repo builds, for one target system, as a fragment for its hand-written
-- Makefile (jbuild/make/common.mk's rules). premake5.lua stays the one list of libraries, sources,
-- include dirs and defines; the Makefile keeps only how to compile for each toolchain.
--
--     premake5 --os=macosx jbuildmake      -> .jbuild/make/macosx.mk
--
-- --os picks what os.target() and the "system:" filters answer, so premake5.lua describes every
-- platform in the one file. Each static library comes out as
--
--     <name>_SRCS := ...    <name>_INCS := -I...    <name>_DEFS := -D...
--     $(eval $(call deplib,<name>,$(<name>_SRCS),$(<name>_INCS),$(<name>_DEFS)))
--
-- (<name> is the project's without "_static", as deplib adds it back). Shared libraries and utility
-- projects are Windows' business and are left out. Nothing generated is committed: the Makefile's rule
-- for its fragment runs this (fetching premake through jbuild/make/premake.sh) when the fragment is
-- missing or older than the premake scripts.

-- premake 5.0-beta8 has no Android in --os's allowed list; premake5.lua asks os.target() alone, so
-- adding the name is all it takes.
do
	local osOption = premake.option.get("os")
	if osOption and osOption.allowed and not table.contains(table.extract(osOption.allowed, 1), "android") then
		table.insert(osOption.allowed, { "android", "Android" })
	end
end

-- makecondition "ifeq ($(JS),1)": the project is built only when the Makefile's condition holds - an
-- option of make's own (make JS=0) that premake cannot answer when it writes the fragment.
premake.api.register {
	name = "makecondition",
	scope = "project",
	kind = "string",
}

-- makecall "sample" / makeargs "--file=...": the Makefile's own template the fragment calls for this
-- project, in place of deplib or premake_tool, and what it is handed after the defines - for what only
-- the repo knows how to make of a project (an application bundle, an APK, the media packed into it).
premake.api.register {
	name = "makecall",
	scope = "project",
	kind = "string",
}
premake.api.register {
	name = "makeargs",
	scope = "project",
	kind = "string",
}

local MAKE_SOURCE_EXTENSIONS = { [".c"] = true, [".cpp"] = true, [".cc"] = true, [".m"] = true, [".mm"] = true }

-- Repo-relative, forward slashes: the Makefile runs from the repo root.
local function make_path(p)
	return path.getrelative(_MAIN_SCRIPT_DIR, p):gsub("\\", "/")
end

-- A -D as the shell will pass it: quoted when it carries characters the shell would eat.
local function make_define(d)
	local flag = "-D" .. d
	if flag:find("[\"%s%(%)<>&;|*?$]") then
		return "'" .. flag:gsub("'", "'\\''") .. "'"
	end
	return flag
end

local function write_list(name, items)
	if #items == 0 then
		_p("%s :=", name)
		return
	end
	_p("%s := \\", name)
	for i, item in ipairs(items) do
		_p("  %s%s", item, i < #items and " \\" or "")
	end
end

-- The values in a that b lacks, in a's order.
local function only_in(a, b)
	local seen, out = {}, {}
	for _, v in ipairs(b) do seen[v] = true end
	for _, v in ipairs(a) do if not seen[v] then out[#out + 1] = v end end
	return out
end

-- The workspace's own configuration (what every project inherits: common_workspace()'s WIN32,
-- NDEBUG, the CRT's include dirs...). Those are the Windows build's, and the Makefile's rules carry
-- their own, so a library's fragment is only what its project adds.
local function workspace_config(wks, buildcfg, platform)
	for cfg in premake.workspace.eachconfig(wks) do
		if cfg.buildcfg == buildcfg and cfg.platform == platform then return cfg end
	end
	return { defines = {}, includedirs = {}, forceincludes = {} }
end

-- ---- headers_project(entries) ----------------------------------------------------------------
-- The include\ tree a repo assembles from its libraries' own headers, said once for every target.
-- On Windows it is the "headers" Utility project, a post-build step of copies; elsewhere the
-- fragment's `headers` target, the same copies with cp. Each entry, in order:
--
--     { dir = "Projects/zlib/include" }                          its contents, into include\
--     { dir = "Projects/flac/src/include/FLAC", to = "FLAC" }    into include\FLAC
--     { file = "Projects/bzip2/src/bzlib.h" }                     one file
--     { files = "Projects/RakNet/src/Source/*.h", to = "RakNet" } a wildcard (recursive = true: /S, Windows only)
--     ... systems = { "windows", "macosx", ... }                 where it is copied (os.target()); every target if not given
local HEADERS = nil

local function header_wanted(entry)
	return not entry.systems or table.contains(entry.systems, os.target())
end

function headers_project(entries)
	HEADERS = entries
	if os.target() ~= "windows" then
		return
	end

	local function win(p) return "$(SolutionDir)..\\" .. p:gsub("/", "\\") end
	local include = win("include")
	local commands = { '{MKDIR} "' .. include .. '"' }
	for _, entry in ipairs(entries) do
		if header_wanted(entry) then
			local into = entry.to and (include .. "\\" .. entry.to:gsub("/", "\\")) or include
			if entry.to then commands[#commands + 1] = '{MKDIR} "' .. into .. '"' end
			if entry.dir then
				commands[#commands + 1] = '{COPYDIR} "' .. win(entry.dir) .. '" "' .. into .. '"'
			elseif entry.file then
				commands[#commands + 1] = '{COPYFILE} "' .. win(entry.file) .. '" "' .. into .. '"'
			else
				commands[#commands + 1] = 'xcopy /Y /Q /D /I ' .. (entry.recursive and "/S " or "")
					.. '"' .. win(entry.files) .. '" "' .. into .. '\\"'
			end
		end
	end

	-- A post-build event, not buildcommands: project-level buildcommands on a Utility kind do not run
	-- under MSBuild, but a PostBuildEvent reliably does. xcopy /D skips unchanged files, so repeat builds
	-- are cheap.
	project "headers"
		location ".jbuild/Projects"
		kind "Utility"
		postbuildcommands(commands)
end

local function write_headers()
	-- What clean removes: the tree this assembles, and nothing at all where it assembles none (a repo's
	-- include/ may be its own source).
	_p("PREMAKE_HEADERS := %s", HEADERS and "include" or "")
	_p(".PHONY: headers")
	_p("headers:")
	if not HEADERS then return end
	_p(1, "@mkdir -p include")
	for _, entry in ipairs(HEADERS) do
		if header_wanted(entry) then
			local into = "include/" .. (entry.to and (entry.to .. "/") or "")
			if entry.to then _p(1, "@mkdir -p %s", into) end
			if entry.dir then
				_p(1, "@cp -rf %s/. %s", entry.dir, into)
			elseif entry.file then
				_p(1, "@cp -f %s %s", entry.file, into)
			elseif entry.recursive then
				error("headers_project: a recursive wildcard (" .. entry.files .. ") is copied on Windows only")
			else
				_p(1, "@cp -f %s %s", entry.files, into)
			end
		end
	end
end

local function write_fragment(wks)
	_p("# Generated by premake (jbuildmake, --os=%s) from premake5.lua - do not edit; regenerate with JBuild.", os.target())
	_p("")

	local platform = wks.platforms and wks.platforms[1] or nil
	local wksRelease = workspace_config(wks, "Release", platform)
	local wksDebug = workspace_config(wks, "Debug", platform)

	for prj in premake.workspace.eachproject(wks) do
		local isTool = prj.kind == "ConsoleApp" or prj.kind == "WindowedApp"
		if prj.kind == "StaticLib" or isTool then
			local release = premake.project.getconfig(prj, "Release", platform)
			local debug = premake.project.getconfig(prj, "Debug", platform)

			local sources = {}
			for _, f in ipairs(release.files) do
				if MAKE_SOURCE_EXTENSIONS[path.getextension(f):lower()] then
					sources[#sources + 1] = make_path(f)
				end
			end
			table.sort(sources)

			-- A library with nothing to compile here is not built here.
			if #sources > 0 then
				local name = prj.name:gsub("_static$", "")

				local includes = {}
				for _, dir in ipairs(only_in(release.includedirs, wksRelease.includedirs)) do
					includes[#includes + 1] = "-I" .. make_path(dir)
				end
				for _, header in ipairs(only_in(release.forceincludes or {}, wksRelease.forceincludes or {})) do
					local forced = path.isabsolute(header) and make_path(header) or header
					includes[#includes + 1] = "-include " .. forced
				end
				-- buildoptions go to the compiler as they are: a make variable ($(SPIDERMONKEY_INCLUDE)), a
				-- flag only this target's compiler takes.
				for _, option in ipairs(only_in(release.buildoptions or {}, wksRelease.buildoptions or {})) do
					includes[#includes + 1] = option
				end

				local releaseDefines = only_in(release.defines, wksRelease.defines)
				local defines = {}
				for _, d in ipairs(releaseDefines) do defines[#defines + 1] = make_define(d) end
				local debugDefines = {}
				for _, d in ipairs(only_in(only_in(debug.defines, wksDebug.defines), releaseDefines)) do
					debugDefines[#debugDefines + 1] = make_define(d)
				end

				_p("# %s", prj.name)
				if prj.makecondition then _p("%s", prj.makecondition) end
				write_list(name .. "_SRCS", sources)
				write_list(name .. "_INCS", includes)
				write_list(name .. "_DEFS", defines)
				if #debugDefines > 0 then
					_p("ifeq ($(CONFIG),debug)")
					_p("  %s_DEFS += %s", name, table.concat(debugDefines, " "))
					_p("endif")
				end
				local call = prj.makecall or (isTool and "premake_tool" or "deplib")
				_p("$(eval $(call %s,%s,$(%s_SRCS),$(%s_INCS),$(%s_DEFS)%s))", call, name, name, name, name,
					prj.makeargs and ("," .. prj.makeargs) or "")
				if prj.makecondition then _p("endif") end
				_p("")
			end
		end
	end

	write_headers()
end

newaction {
	trigger = "jbuildmake",
	description = "Write .jbuild/make/<os>.mk - what the Makefile builds for the --os target",
	onWorkspace = function(wks)
		local file = path.join(_MAIN_SCRIPT_DIR, ".jbuild/make", os.target() .. ".mk")
		os.mkdir(path.getdirectory(file))
		premake.generate(wks, file, write_fragment)
	end,
}
