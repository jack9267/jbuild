-- Authenticode signing, the premake counterpart of cmake\j-signing.cmake.
--
--     include "Signing.lua"
--     signing_workspace()   -- after common_workspace(): sign every .exe and .dll built, when it can
--
-- The CMake module's two rules are kept: sign only when the certificate is present, and only executables
-- and shared libraries (a static library is not signable; the filter leaves it alone). A machine without
-- the certificate builds everything as before, unsigned and without error. ENGINE_SIGNING is defined for
-- every project whenever the certificate is present - as add_definitions(-DENGINE_SIGNING) at include -
-- so code can tell it is part of a signed build.
--
-- Where it differs: the CMake module writes a SignMe.bat that puts two directories on PATH, one a
-- hardcoded SDK build right on exactly one machine. This finds signtool.exe from the Windows Kits'
-- KitsRoot10 (the newest SDK installed, the v7.1A SDK failing that) and puts the command straight into the
-- post-build event, so there is no generated script to keep in step. A certificate with no signtool found
-- signs nothing and says so, rather than failing every build.
--
-- NOT DONE, as in the CMake module: /tr timestamping. Without it a signature stops verifying when the
-- certificate expires; with it every build depends on a timestamp server.

-- %dropbox% is set by the Dropbox client. The certificate is deliberately outside every repository - it is
-- the one file that must never be committed.
local CERTIFICATE = "\\Private\\Certificate\\Output\\Code.pfx"

-- Where signtool.exe is, and its SDK's version, or nil.
local function find_signtool()
	local roots = {
		"HKLM:SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots\\KitsRoot10",
		"HKLM:SOFTWARE\\WOW6432Node\\Microsoft\\Windows Kits\\Installed Roots\\KitsRoot10",
	}

	-- x64 first where it can run. signtool's architecture has nothing to do with what it signs.
	local arches = os.is64bit() and { "x64", "x86" } or { "x86" }

	local best, bestVersion

	-- Component by component as NUMBERS. As strings, "10.0.9" sorts above "10.0.26100".
	local function newer(a, b)
		if not b then
			return true
		end

		local ita, itb = a:gmatch("%d+"), b:gmatch("%d+")

		for _ = 1, 4 do
			local x = tonumber(ita() or 0)
			local y = tonumber(itb() or 0)

			if x ~= y then
				return x > y
			end
		end

		return false
	end

	for _, key in ipairs(roots) do
		local ok, root = pcall(os.getWindowsRegistry, key)

		if ok and root then
			for _, dir in ipairs(os.matchdirs(root .. "bin/10.*")) do
				local version = path.getname(dir)

				for _, arch in ipairs(arches) do
					local exe = dir .. "/" .. arch .. "/signtool.exe"

					if os.isfile(exe) and newer(version, bestVersion) then
						best, bestVersion = exe, version
						break
					end
				end
			end
		end
	end

	if best then
		return best, bestVersion
	end

	-- The Windows 7.1A SDK, the CMake module's other directory. Only reached with no Windows 10 kit.
	local legacy = os.getenv("ProgramFiles(x86)")

	if legacy then
		legacy = legacy .. "\\Microsoft SDKs\\Windows\\v7.1A\\Bin\\signtool.exe"

		if os.isfile(legacy) then
			return legacy, "v7.1A"
		end
	end

	return nil
end

-- Decided once, at generation, as the CMake module decides at configure.
local dropbox = os.getenv("dropbox")
local hasCertificate = dropbox ~= nil and os.isfile(dropbox .. CERTIFICATE)
local signtool, signtoolVersion

if hasCertificate then
	signtool, signtoolVersion = find_signtool()
end

-- True when the certificate is here (ENGINE_SIGNING is defined); signing_available() when a build will
-- actually be signed too.
function signing_certificate()
	return hasCertificate
end

function signing_available()
	return hasCertificate and signtool ~= nil
end

-- The certificate path stays an MSBuild property ($(dropbox), from the environment) so the generated
-- project is not specific to one account. signtool cannot be written that way - nothing defines a macro
-- for it - so it is resolved here.
local function command()
	return '"' .. path.translate(signtool) .. '" sign /v /f "$(dropbox)' .. CERTIFICATE
		.. '" /fd SHA256 "$(TargetPath)"'
end

-- The define and the signing, at workspace scope, after common_workspace().
function signing_workspace()
	if not hasCertificate then
		print("signing    off - no certificate")
		return
	end

	defines { "ENGINE_SIGNING" }

	if not signtool then
		print("signing    off - the certificate is here, but no signtool.exe was found")
		return
	end

	print("signing    on - signtool " .. signtoolVersion)

	filter { "kind:ConsoleApp or WindowedApp or SharedLib" }
		postbuildmessage "Signing %{cfg.buildtarget.name}"
		postbuildcommands { command() }

	filter {}
end
