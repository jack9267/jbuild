<#
.SYNOPSIS
    Shared premake driver for repos that consume jbuild. Generates the Visual Studio solution and,
    with -Build, builds it headlessly via MSBuild.

.DESCRIPTION
    The build is described by the CONSUMER's premake5.lua at its repo root; this script only maps friendly
    parameters to premake options, runs premake (fetched into jbuild\tools\premake\<version>\), then locates the
    generated solution and hands it to MSBuild. Generic: the solution NAME and location come from the
    consumer's premake `workspace` (location(rootPath)), never this script - the *.sln is DISCOVERED, not
    hardcoded. Generation alone is just `premake5.exe vs2022` at the consumer's root; this wrapper
    adds the parameter mapping and the optional non-interactive build (CI / no Visual Studio open).

.PARAMETER Root
    The consumer repo root - where premake5.lua lives and its `location(rootPath)` writes the .sln.
    Defaults to this script's parent (correct when jbuild is a submodule at <consumer>\jbuild, this driver
    at the jbuild root); pass it explicitly for a sibling checkout.

.PARAMETER Build
    Also build the generated solution with MSBuild after generating.
#>
param(
    [string] $Root = (Split-Path $PSScriptRoot -Parent),

    # Which build system to drive. Empty auto-detects (premake if the repo root has premake5.lua, cmake if it
    # has CMakeLists.txt) and, when both exist interactively, offers a menu with premake as the default.
    [ValidateSet('', 'premake', 'cmake')]
    [string] $BuildSystem = '',

    # Empty offers an interactive menu (what a double-click with no args gets); a value skips it.
    [ValidateSet('', '2017', '2019', '2022', '2026')]
    [string] $VisualStudio = '',

    [string] $Toolset = 'v143',

    # What to do. Empty offers a menu when interactive (a double-click), else Configure - or Build with -Build.
    # Configure: generate only. Build: generate, then build a configuration and platform (asked for, or
    # -Configuration/-Platform). BuildAll: generate, then build every configuration and platform. Rebuild: the
    # same, cleaning first (MSBuild /t:Rebuild). Clean: clean every configuration and platform of the solution
    # already generated (MSBuild /t:Clean, which removes what the projects build and nothing else).
    [ValidateSet('', 'Configure', 'Build', 'BuildAll', 'Rebuild', 'Clean')]
    [string] $Action = '',

    [switch] $Build,

    # Build configuration; empty = chosen from the solution's own configurations (a prompt, or the default).
    [string] $Configuration = '',

    # Empty lets the build step choose (a prompt, or the solution's first platform); 'All' builds every
    # platform the generated solution offers.
    [ValidateSet('', 'Win32', 'x64', 'ARM', 'ARM64', 'All')]
    [string] $Platform = '',

    # Which CPU architectures the generated solution CONTAINS (distinct from -Platform, which picks what to
    # build from it). A comma list of x86,x64,arm,arm64 or 'all'; empty = x86,x64, premake5.lua's own default.
    [string] $Architecture = '',

    [string] $NoEnhancedInstructions = '',

    # Oldest Windows the binaries must run on (supersedes -SupportWinXP). The menu offers this list.
    [ValidateSet('', 'win2000', 'winxp', 'vista', 'win7', 'win8', 'win81', 'win10', 'win11')]
    [string] $TargetOs = '',

    [string] $SupportWinXP = '',
    [string] $UseMsvcrt = '',

    # Full CRT selector (supersedes -UseMsvcrt): msvcrt | static | dynamic | ucrt-local. Empty = consumer default.
    [ValidateSet('', 'msvcrt', 'static', 'dynamic', 'ucrt-local')]
    [string] $Crt = '',

    # The Debug config's CRT (mirrors -Crt). Empty = static (keeps the debug heap / leak detection).
    [ValidateSet('', 'msvcrt', 'static', 'dynamic', 'ucrt-local')]
    [string] $CrtDebug = '',

    [string] $YYThunksTLS = '',

    [ValidateSet('0', '1', '2', '3', '4')]
    [string] $WarningLevel = '',

    # SpiderMonkey ESR the JS backend links against ($(jspidermonkey_home)\esr<NN>); empty keeps
    # the consumer premake5.lua's default. Mirrors the engine's -DSPIDERMONKEY_VERSION.
    [string] $SpiderMonkeyVersion = ''
)

$ErrorActionPreference = 'Stop'

# Colorized output in the style of the makefiles' CMake-like tags (make/common.mk: green [CXX], cyan [AR],
# bold-blue [LINK]). Dropped when NO_COLOR is set or output is redirected (CI logs / dumb terminals).
$script:Color = (-not $env:NO_COLOR) -and (-not [Console]::IsOutputRedirected)
function Paint([string]$text, [string]$code) { if ($script:Color) { "$([char]27)[${code}m$text$([char]27)[0m" } else { $text } }
function Tag([string]$name, [string]$code)   { Paint "[$name]" $code }

# A menu's answer. Where every answer is one character (up to 9 choices, or a letter), one key does it, no Enter;
# Enter alone is '' (the default), as Read-Host's empty line was. Where an answer can be longer - 10 or more
# choices, or input that is not a console (piped, CI) - a line, as before.
function Read-Choice([string]$Prompt, [int]$Count = 9) {
    if ($Count -gt 9 -or [Console]::IsInputRedirected) { return Read-Host $Prompt }
    Write-Host "${Prompt}: " -NoNewline
    $key = [Console]::ReadKey($true)
    if ($key.Key -eq [ConsoleKey]::Enter) { Write-Host ''; return '' }
    Write-Host $key.KeyChar
    return [string]$key.KeyChar
}

# This driver is at the jbuild root; the shared .lua modules are in jbuild\premake\. The consumer's own
# premake5.lua is at its repo root ($Root). premake itself is not committed on any platform: it is fetched
# on first use into jbuild\tools\premake\<version>\ (gitignored) - here premake's Windows release, elsewhere
# make\premake.sh's. ONE PIN: the version is read from premake.sh's VERSION= rather than written twice.
$jbuildPremake = Join-Path $PSScriptRoot 'premake'
$premakeVersion = (Select-String -Path (Join-Path $PSScriptRoot 'make\premake.sh') -Pattern '^VERSION=(.+)$' |
    Select-Object -First 1).Matches.Groups[1].Value.Trim()
$premake = Join-Path $PSScriptRoot "tools\premake\$premakeVersion\premake5.exe"
$consumerPremake = $Root

# A Visual Studio's own toolset when -Toolset was not given: v145 for 2026, else v143 (the parameter's default).
$toolsetGiven = $PSBoundParameters.ContainsKey('Toolset')
function Set-DefaultToolset {
    if ($toolsetGiven) { return }
    $script:Toolset = if ($VisualStudio -eq '2026') { 'v145' } else { 'v143' }
}

# The premake option flags (everything except the vsNNNN action), from the params/menu choices. Shared by
# the pre-generate summary and the real generation so the two can never disagree.
function Get-OptionArgs {
    $a = @("--toolset=$Toolset")
    if ($NoEnhancedInstructions) { $a += "--no-enhanced-instructions=$($NoEnhancedInstructions.ToLower())" }
    if ($Architecture)           { $a += "--architecture=$($Architecture.ToLower())" }
    if ($TargetOs)               { $a += "--target-os=$TargetOs" }
    if ($WarningLevel)           { $a += "--warning-level=$WarningLevel" }
    if ($SupportWinXP)           { $a += "--support-winxp=$($SupportWinXP.ToLower())" }
    if ($UseMsvcrt)              { $a += "--use-msvcrt=$($UseMsvcrt.ToLower())" }
    if ($Crt)                    { $a += "--crt=$($Crt.ToLower())" }
    if ($CrtDebug)               { $a += "--crt-debug=$($CrtDebug.ToLower())" }
    if ($YYThunksTLS)            { $a += "--yy-thunks-tls=$($YYThunksTLS.ToLower())" }
    if ($SpiderMonkeyVersion)    { $a += "--spidermonkey-version=$SpiderMonkeyVersion" }
    return $a
}

# Print what "generate now" commits to - resolved by premake itself (consumer premake5.lua defaults
# included) via the read-only jbuild-summary action. Silent if the consumer doesn't provide it (no XP.lua)
# or premake can't run; the real generation surfaces any actual problem.
function Show-Summary {
    $lines = @()
    Push-Location $consumerPremake
    try { $lines = & $premake jbuild-summary @(Get-OptionArgs) 2>$null } catch { } finally { Pop-Location }
    $body = @($lines | Where-Object { $_ -match '^    \S' })
    if (-not $body) { return }
    Write-Host ''
    Write-Host (Paint "These settings will be used (press 'o' below to change any):" '1;36')
    Write-Host ("    {0,-14} {1}" -f 'Visual Studio', "Visual Studio $VisualStudio")
    $body | ForEach-Object { Write-Host $_ }
}

# ----- cmake path -----
# Mirror the premake prompts where cmake supports them (Visual Studio, architecture, XP toolset, XP
# support, SpiderMonkey, runtime), map them to one of jbuild's configure presets plus -D overrides,
# configure, optionally build. The premake-only knobs (--crt dynamic modes, --target-os ladder, multi-arch)
# are not offered - cmake does one architecture per configure and has no equivalent.
function Invoke-Cmake {
    $cmake = Get-Command cmake -EA SilentlyContinue
    if (-not $cmake) { Write-Error 'cmake is not on PATH.'; exit 1 }

    $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    $vs = $VisualStudio
    $arch = if ($Architecture -match 'x64|x86_64') { 'x64' } elseif ($Architecture -match 'x86|win32|Win32') { 'Win32' } else { '' }
    $xpToolset = $false

    if ($interactive) {
        if (-not $vs) {
            $vers = @('2022', '2019', '2017')
            Write-Host ''
            Write-Host (Paint 'Generate for which Visual Studio?' '1;36')
            for ($i = 0; $i -lt $vers.Count; $i++) { Write-Host ("  {0} Visual Studio {1}{2}" -f (Paint ("[{0}]" -f ($i + 1)) '0;36'), $vers[$i], $(if ($i -eq 0) { Paint '  (default)' '0;32' } else { '' })) }
            $p = Read-Choice 'Enter 1-3 (or Enter for the default)' 3
            $vs = if ($p -match '^[1-3]$') { $vers[[int]$p - 1] } else { $vers[0] }
        }
        if (-not $arch) {
            Write-Host ''
            Write-Host (Paint 'Architecture?' '1;36')
            Write-Host ("  {0} Win32 (x86){1}" -f (Paint '[1]' '0;36'), (Paint '  (default)' '0;32'))
            Write-Host ("  {0} x64" -f (Paint '[2]' '0;36'))
            $p = Read-Choice 'Enter 1-2 (or Enter for Win32)' 2
            $arch = if ($p -eq '2') { 'x64' } else { 'Win32' }
        }
        # 2017 is XP-only; 2019 offers modern (v142) or XP (v141_xp); 2022 is v143 (XP via SUPPORT_WINXP).
        if ($vs -eq '2017') { $xpToolset = $true }
        elseif ($vs -eq '2019') {
            Write-Host ''
            Write-Host (Paint 'Toolset?' '1;36')
            Write-Host ("  {0} v142 - modern (reaches XP via VC-LTL5 + YY-Thunks){1}" -f (Paint '[1]' '0;36'), (Paint '  (default)' '0;32'))
            Write-Host ("  {0} v141_xp - the XP toolset" -f (Paint '[2]' '0;36'))
            $p = Read-Choice 'Enter 1-2 (or Enter for v142)' 2
            $xpToolset = ($p -eq '2')
        }
    }
    else {
        if (-not $vs) { $vs = '2022' }
        if (-not $arch) { $arch = 'Win32' }
        if ($vs -eq '2017') { $xpToolset = $true }
    }

    $preset = "vs$vs" + $(if ($xpToolset) { '-xp' } else { '' }) + '-' + $arch.ToLower()

    # -D overrides mirroring the remaining premake prompts.
    $defs = @()

    # SpiderMonkey - only if the consumer's build references it.
    $sm = $SpiderMonkeyVersion
    $usesSm = Select-String -Path (Join-Path $Root 'CMakeLists.txt') -Pattern 'SPIDERMONKEY_VERSION|j-spidermonkey' -Quiet -EA SilentlyContinue
    if ($interactive -and $usesSm -and -not $sm -and $env:jspidermonkey_home -and (Test-Path -LiteralPath $env:jspidermonkey_home)) {
        $esr = @(Get-ChildItem -LiteralPath $env:jspidermonkey_home -Directory -Filter 'esr*' -EA SilentlyContinue |
            ForEach-Object { $_.Name -replace '^esr', '' } | Where-Object { $_ -match '^\d+$' }) | Sort-Object { [int]$_ }
        if ($esr) {
            Write-Host ''
            Write-Host (Paint "SpiderMonkey ESR (installed under $env:jspidermonkey_home):" '1;36')
            for ($i = 0; $i -lt $esr.Count; $i++) { Write-Host ("  {0} esr{1}" -f (Paint ("[{0}]" -f ($i + 1)) '0;36'), $esr[$i]) }
            $p = Read-Choice "Enter 1-$($esr.Count) (or Enter to keep the default)" $esr.Count
            if ($p -match '^\d+$' -and [int]$p -ge 1 -and [int]$p -le $esr.Count) { $sm = $esr[[int]$p - 1] }
        }
    }
    if ($sm) { $defs += "-DSPIDERMONKEY_VERSION=$sm" }

    # XP support - only meaningful for a modern toolset (the _xp presets are XP by definition). NO_ENHANCED_
    # INSTRUCTIONS follows it in the cmake script itself, so it is not a separate prompt.
    if (-not $xpToolset) {
        if ($interactive) {
            $p = Read-Choice "`nWindows XP support?  [Enter] yes (default) / n no"
            if ($p -match '^[nN]') { $defs += '-DSUPPORT_WINXP=OFF' }
        }
        elseif ($SupportWinXP -eq 'Off') { $defs += '-DSUPPORT_WINXP=OFF' }
    }

    # Runtime - msvcrt.dll via VC-LTL5, or the static UCRT. Enter keeps the preset's default (non-XP presets
    # default to msvcrt, _xp ones to static), so static must pass -DUSE_MSVCRT=OFF explicitly to override it.
    # cmake has no dynamic / app-local UCRT equivalent.
    if ($interactive) {
        $p = Read-Choice "`nCRT?  [Enter] the preset default / 1 msvcrt (VC-LTL5) / 2 static UCRT" 2
        if ($p -eq '1') { $defs += '-DUSE_MSVCRT=ON' } elseif ($p -eq '2') { $defs += '-DUSE_MSVCRT=OFF' }
    }
    elseif ($UseMsvcrt -eq 'On' -or $Crt -eq 'msvcrt') { $defs += '-DUSE_MSVCRT=ON' }
    elseif ($UseMsvcrt -eq 'Off' -or $Crt -eq 'static') { $defs += '-DUSE_MSVCRT=OFF' }

    Write-Host "$(Tag 'cmake' '0;36') $(& $cmake.Source --version | Select-Object -First 1)"
    Write-Host "$(Tag 'configure' '0;32') preset $preset $($defs -join ' ')"

    Push-Location $Root
    try {
        & $cmake.Source --preset $preset @defs
        if ($LASTEXITCODE -ne 0) { Write-Error 'cmake configure failed.'; exit $LASTEXITCODE }
    }
    finally { Pop-Location }

    # The build dir from the chosen preset (jbuild/cmake/presets.json), with ${sourceDir} -> $Root.
    $binDir = $null
    try {
        $pj = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'cmake\presets.json') -Raw | ConvertFrom-Json
        $bd = ($pj.configurePresets | Where-Object { $_.name -eq $preset }).binaryDir
        if ($bd) { $binDir = $bd -replace '\$\{sourceDir\}', ($Root -replace '\\', '/') }
    }
    catch { }
    Write-Host "$(Tag 'solution' '0;36') configured$(if ($binDir) { " -> $binDir" })"

    # ---- optional build ----
    # Configure stops here; Build asks for a configuration when none was given; BuildAll, Rebuild and Clean
    # take every one ('All', set with the action).
    if (-not $Build) { return }
    $cfg = $Configuration
    if (-not $cfg) {
        if ($interactive) {
            $p = Read-Choice "`nBuild which configuration?  1 Debug / [Enter] 2 Release / 3 both" 3
            switch ($p) { '1' { $cfg = 'Debug' } '3' { $cfg = 'both' } default { $cfg = 'Release' } }
        }
        else { $cfg = 'Release' }
    }
    if (-not $binDir) { Write-Error 'Could not resolve the preset build directory.'; exit 1 }
    $how = switch ($msbuildTarget) { 'Clean' { @('--target', 'clean') } 'Rebuild' { @('--clean-first') } default { @() } }
    foreach ($c in $(if ($cfg -in @('both', 'All')) { @('Debug', 'Release') } else { @($cfg) })) {
        Write-Host "$(Tag $msbuildTarget.ToLower() '1;34') $preset $c"
        & $cmake.Source --build $binDir --config $c @how
        if ($LASTEXITCODE -ne 0) { Write-Error "cmake $($msbuildTarget.ToLower()) ($c) failed."; exit $LASTEXITCODE }
    }
}

# ----- what to do -----
# Asked first on a double-click; given by -Action (or -Build) otherwise. Everything after reads $Build,
# $Configuration and $Platform as it always has, so the menu only sets those, plus the MSBuild target.
if (-not $Action) {
    if ($Build) { $Action = 'Build' }
    elseif ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        $actions = @(
            @{ k = 'Configure'; n = 'Configure       - generate the solution' }
            @{ k = 'Build';     n = 'Build           - configure, then build a configuration and platform' }
            @{ k = 'BuildAll';  n = 'Build all       - configure, then build every configuration and platform' }
            @{ k = 'Rebuild';   n = 'Rebuild all     - configure, then clean and build everything' }
            @{ k = 'Clean';     n = 'Clean           - clean everything the solution builds' }
        )
        Write-Host ''
        Write-Host (Paint 'What would you like to do?' '1;36')
        for ($i = 0; $i -lt $actions.Count; $i++) {
            Write-Host ("  {0} {1}{2}" -f (Paint ("[{0}]" -f ($i + 1)) '0;36'), $actions[$i].n, $(if ($i -eq 0) { Paint '  (default)' '0;32' } else { '' }))
        }
        $p = Read-Choice "Enter 1-$($actions.Count) (or Enter for the default)" $actions.Count
        if ([string]::IsNullOrWhiteSpace($p)) { $Action = 'Configure' }
        elseif ($p -match '^\d+$' -and [int]$p -ge 1 -and [int]$p -le $actions.Count) { $Action = $actions[[int]$p - 1].k }
        else { Write-Error "Not a choice: '$p'."; exit 1 }
    }
    else { $Action = 'Configure' }
}
$msbuildTarget = 'Build'
switch ($Action) {
    'Build'    { $Build = $true }
    'BuildAll' { $Build = $true }
    'Rebuild'  { $Build = $true; $msbuildTarget = 'Rebuild' }
    'Clean'    { $Build = $true; $msbuildTarget = 'Clean' }
}
if ($Action -in @('BuildAll', 'Rebuild', 'Clean')) {
    if (-not $Configuration) { $Configuration = 'All' }
    if (-not $Platform)      { $Platform = 'All' }
}

# ----- which build system -----
# Detected from the repo root: premake if premake5.lua is there, cmake if CMakeLists.txt is. When both
# exist and we're interactive, offer a choice with premake as the default; otherwise take the only one.
$hasPremake = Test-Path -LiteralPath (Join-Path $Root 'premake5.lua')
$hasCmake   = Test-Path -LiteralPath (Join-Path $Root 'CMakeLists.txt')

if (-not $BuildSystem) {
    if ($hasPremake -and $hasCmake -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        Write-Host ''
        Write-Host (Paint 'Build system?' '1;36')
        Write-Host ("  {0} premake  (generate a Visual Studio solution){1}" -f (Paint '[1]' '0;36'), (Paint '  (default)' '0;32'))
        Write-Host ("  {0} cmake    (configure with CMake presets)" -f (Paint '[2]' '0;36'))
        $p = Read-Choice 'Enter 1-2 (or Enter for premake)' 2
        $BuildSystem = if ($p -eq '2') { 'cmake' } else { 'premake' }
    }
    elseif ($hasPremake) { $BuildSystem = 'premake' }
    elseif ($hasCmake)   { $BuildSystem = 'cmake' }
    else { Write-Error "No premake5.lua or CMakeLists.txt at '$Root'. Pass -Root <consumer repo root>."; exit 1 }
}

if ($BuildSystem -eq 'cmake') {
    if (-not $hasCmake) { Write-Error "Build system 'cmake' chosen, but no CMakeLists.txt at '$Root'."; exit 1 }
    Invoke-Cmake
    exit 0
}

# ----- premake path -----
# premake's Windows release, checked by SHA-256 (tools\fetch.ps1, as VC-LTL5 and YY-Thunks are). A new version
# in premake.sh needs this hash changed with it.
if (-not (Test-Path -LiteralPath $premake)) {
    # fetch.ps1 is a script that downloads and unpacks executables - what an antivirus heuristic deletes (AVG has).
    # Put back from git; if it goes again, say so rather than blaming premake.
    $fetch = Join-Path $PSScriptRoot 'tools\fetch.ps1'
    if (-not (Test-Path -LiteralPath $fetch)) {
        Write-Host "$(Tag 'premake' '0;33') tools\fetch.ps1 is missing - restoring it from git"
        & git -C $PSScriptRoot checkout -- tools/fetch.ps1 2>$null
    }
    if (-not (Test-Path -LiteralPath $fetch)) {
        Write-Error ("$fetch is missing - almost certainly an antivirus deleting it (a script that downloads executables " +
            "looks like malware to one). Restore it from the antivirus's quarantine, or with " +
            "'git -C `"$PSScriptRoot`" checkout -- tools/fetch.ps1', add this folder to the antivirus's exceptions, and run this again.")
        exit 1
    }
    try {
        & $fetch -Name premake -Version $premakeVersion `
            -Url "https://github.com/premake/premake-core/releases/download/v$premakeVersion/premake-$premakeVersion-windows.zip" `
            -Sha256 'e64ce2ed8778e0098f63674cca61fe33941b5f0c8d9a4afd651152bdea3758ab'
    } catch {
        Write-Host "$(Tag 'premake' '0;31') $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $premake)) {
        Write-Error ("premake $premakeVersion could not be fetched into $(Split-Path $premake). If an antivirus removed " +
            "premake5.exe, allow it there (it is premake's own release, from github.com/premake/premake-core) and run this again.")
        exit 1
    }
}
if (-not $hasPremake) { Write-Error "Build system 'premake' chosen, but no premake5.lua at '$Root'."; exit 1 }

# The solution generated before, if any: in .jbuild (the convention, location ".jbuild"), then the repo root.
# Visual Studio 2026's is a .slnx (XML), every earlier one's a .sln, and one of each may sit side by side after
# generating for both: given a Visual Studio, only its format counts; given none, the one written last.
# (-Filter *.sln also matches .slnx - a three-letter extension pattern does - hence the exact check.)
function Find-Solution([string]$ForVisualStudio = '') {
    $extensions = if ($ForVisualStudio -eq '2026') { @('.slnx') } elseif ($ForVisualStudio) { @('.sln') } else { @('.sln', '.slnx') }
    foreach ($folder in (Join-Path $Root '.jbuild'), $Root) {
        $found = @(Get-ChildItem -LiteralPath $folder -Filter *.sln* -File -EA SilentlyContinue |
            Where-Object { $extensions -contains $_.Extension } | Sort-Object LastWriteTime -Descending)
        if ($found) { return $found[0] }
    }
    return $null
}

# Cleaning is of what the solution there builds, so it is not generated again; its Visual Studio is read from it,
# for choosing the MSBuild below. With none there, nothing has been built from it.
$skipGenerate = $false
if ($Action -eq 'Clean') {
    $existing = Find-Solution
    if (-not $existing) { Write-Host "$(Tag 'clean' '0;33') no solution has been generated under '$Root', so there is nothing to clean"; exit 0 }
    $skipGenerate = $true
    if (-not $VisualStudio) {
        if ($existing.Extension -eq '.slnx') { $VisualStudio = '2026' }
        else {
            $major = [regex]::Match((Get-Content -LiteralPath $existing.FullName -Raw), '(?m)^VisualStudioVersion\s*=\s*(\d+)\.').Groups[1].Value
            $VisualStudio = switch ($major) { '15' { '2017' } '16' { '2019' } default { '2022' } }
        }
    }
}

# No VS version chosen (e.g. a double-click with no args): offer a menu. In a non-interactive context
# (piped / CI, where stdin is redirected) fall back to the newest so a prompt never hangs the run.
if (-not $VisualStudio) {
    # Newest first; 2022 stays the default. 2026 brings its own toolset, v145 (Set-DefaultToolset), and has not
    # been tried on an installation of it yet.
    $versions = @('2026', '2022', '2019', '2017')
    $defaultVersion = '2022'
    $notes = @{ '2026' = '  (should work - untested)' }
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        # --- Visual Studio version ---
        Write-Host ''
        Write-Host (Paint 'Generate for which Visual Studio?' '1;36')
        for ($i = 0; $i -lt $versions.Count; $i++) {
            $mark = if ($versions[$i] -eq $defaultVersion) { Paint '  (default)' '0;32' } elseif ($notes[$versions[$i]]) { Paint $notes[$versions[$i]] '0;33' } else { '' }
            Write-Host ("  {0} Visual Studio {1}{2}" -f (Paint ("[{0}]" -f ($i + 1)) '0;36'), $versions[$i], $mark)
        }
        $pick = Read-Choice "Enter 1-$($versions.Count) (or press Enter for the default)" $versions.Count
        if ([string]::IsNullOrWhiteSpace($pick)) { $VisualStudio = $defaultVersion }
        elseif ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $versions.Count) { $VisualStudio = $versions[[int]$pick - 1] }
        else { Write-Error "Not a choice: '$pick'."; exit 1 }
        Set-DefaultToolset

        # --- optional extra options ---
        # Only the knobs the consumer's premake actually declares are offered, so we never pass an unknown
        # flag (premake errors on one). Declared options are discovered by scanning its premake tree for
        # newoption triggers. Each prompt defaults to Enter = keep premake5.lua's own default.
        Show-Summary
        Write-Host ''
        Write-Host "Press 'o' to set options, or Enter to generate now " -NoNewline
        $gate = [Console]::ReadKey($true); Write-Host ''
        if ($gate.KeyChar -eq 'o' -or $gate.KeyChar -eq 'O') {
            # Scan the consumer's premake dir AND jbuild's own - the shared jbuild modules (XP.lua /
            # Common.lua, declaring support-winxp / use-msvcrt / crt / ...) live there, so options defined
            # in the jbuild submodule are still discovered.
            $declared = @(
                (@(Get-ChildItem $Root -Filter *.lua -EA SilentlyContinue) +
                 @(Get-ChildItem $jbuildPremake -Filter *.lua -EA SilentlyContinue)) |
                Select-String -Pattern 'trigger\s*=\s*"([^"]+)"' -AllMatches |
                ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique

            # SpiderMonkey ESR - list what's actually installed under jspidermonkey_home.
            if (($declared -contains 'spidermonkey-version') -and -not $SpiderMonkeyVersion -and
                $env:jspidermonkey_home -and (Test-Path -LiteralPath $env:jspidermonkey_home)) {
                $esr = @(Get-ChildItem -LiteralPath $env:jspidermonkey_home -Directory -Filter 'esr*' -EA SilentlyContinue |
                    ForEach-Object { $_.Name -replace '^esr', '' } | Where-Object { $_ -match '^\d+$' }) |
                    Sort-Object { [int]$_ }
                if ($esr) {
                    # mark the consumer's own declared default (premake5.lua's spidermonkey-version default)
                    $smDefault = $null
                    $pml = Join-Path $Root 'premake5.lua'
                    if ((Test-Path -LiteralPath $pml) -and
                        ((Get-Content -LiteralPath $pml -Raw) -match '(?s)spidermonkey-version.*?default\s*=\s*"(\d+)"')) { $smDefault = $Matches[1] }
                    Write-Host ''
                    Write-Host (Paint "SpiderMonkey ESR (installed under $env:jspidermonkey_home):" '1;36')
                    for ($i = 0; $i -lt $esr.Count; $i++) {
                        $mark = if ($esr[$i] -eq $smDefault) { Paint '  (default)' '0;32' } else { '' }
                        Write-Host ("  {0} esr{1}{2}" -f (Paint ("[{0}]" -f ($i + 1)) '0;36'), $esr[$i], $mark)
                    }
                    $p = Read-Choice "Enter 1-$($esr.Count) (or Enter to keep the default)" $esr.Count
                    if ($p -match '^\d+$' -and [int]$p -ge 1 -and [int]$p -le $esr.Count) { $SpiderMonkeyVersion = $esr[[int]$p - 1] }
                }
            }
            # Architecture(s) the solution CONTAINS. Multi-select: a list of numbers, or 'a' for all; Enter
            # keeps premake5.lua's default (x86,x64). Offered only when the consumer's Common.lua declares it.
            if (($declared -contains 'architecture') -and -not $Architecture) {
                $archs = @(
                    @{ k = 'x86';   n = 'x86    (Win32)' }
                    @{ k = 'x64';   n = 'x64' }
                    @{ k = 'arm';   n = 'ARM    (32-bit; legacy - needs the ARM toolchain + ARM-built deps)' }
                    @{ k = 'arm64'; n = 'ARM64  (needs the ARM64 toolchain + ARM64-built deps)' }
                )
                Write-Host ''
                Write-Host (Paint 'Architecture(s) in the solution?' '1;36')
                for ($i = 0; $i -lt $archs.Count; $i++) { Write-Host ("  {0} {1}" -f (Paint ("[{0}]" -f ($i + 1)) '0;36'), $archs[$i].n) }
                Write-Host ("  {0} All of them" -f (Paint '[a]' '0;36'))
                $p = Read-Host "Pick one or more (e.g. 1,2), 'a' for all, or Enter for x86+x64 (the default)"
                if ($p -match '^\s*[aA]') {
                    $Architecture = 'all'
                } elseif ($p -match '\d') {
                    $picked = @()
                    foreach ($tok in ($p -split '[,\s]+')) {
                        if ($tok -match '^\d+$' -and [int]$tok -ge 1 -and [int]$tok -le $archs.Count) { $picked += $archs[[int]$tok - 1].k }
                    }
                    if ($picked.Count) { $Architecture = (($picked | Select-Object -Unique) -join ',') }
                }
            }
            # Target OS - the oldest Windows the output must run on. Supersedes --support-winxp; offered only
            # when the consumer's XP.lua declares --target-os.
            if (($declared -contains 'target-os') -and -not $TargetOs) {
                $oses = @(
                    @{ k = 'win2000'; n = 'Windows 2000  (32-bit only; x64 builds as XP x64 - unverified)' }
                    @{ k = 'winxp';   n = 'Windows XP' }
                    @{ k = 'vista';   n = 'Windows Vista' }
                    @{ k = 'win7';    n = 'Windows 7' }
                    @{ k = 'win8';    n = 'Windows 8' }
                    @{ k = 'win81';   n = 'Windows 8.1' }
                    @{ k = 'win10';   n = 'Windows 10' }
                    @{ k = 'win11';   n = 'Windows 11' }
                )
                Write-Host ''
                Write-Host (Paint 'Target OS - oldest Windows the binaries must run on?' '1;36')
                for ($i = 0; $i -lt $oses.Count; $i++) { Write-Host ("  {0} {1}" -f (Paint ("[{0}]" -f ($i + 1)) '0;36'), $oses[$i].n) }
                $p = Read-Choice "Enter 1-$($oses.Count) (or Enter to keep the default)" $oses.Count
                if ($p -match '^\d+$' -and [int]$p -ge 1 -and [int]$p -le $oses.Count) { $TargetOs = $oses[[int]$p - 1].k }
            }
            # CRT - the full selector (msvcrt / static / dynamic / app-local UCRT), offered when the consumer
            # declares --crt. Sets --crt, which supersedes --use-msvcrt; [Enter] keeps the consumer's default.
            if (($declared -contains 'crt') -and -not $Crt -and -not $UseMsvcrt) {
                Write-Host ''
                Write-Host (Paint 'CRT - which C runtime?' '1;36')
                Write-Host ("  {0} Keep the consumer's default" -f (Paint '[Enter]' '0;36'))
                Write-Host ("  {0} msvcrt.dll via VC-LTL5 - small, nothing to ship, runs XP+" -f (Paint '[1]' '0;36'))
                Write-Host ("  {0} Static UCRT (/MT) - self-contained, keeps MSVC's debug heap" -f (Paint '[2]' '0;36'))
                Write-Host ("  {0} Dynamic UCRT (/MD) - needs the runtime present on the target" -f (Paint '[3]' '0;36'))
                Write-Host ("  {0} Dynamic UCRT, copied app-local - runs XP SP3+ with nothing installed" -f (Paint '[4]' '0;36'))
                if ($TargetOs -eq 'win2000') {
                    Write-Host (Paint "  note: for a Windows 2000 target, msvcrt (1) applies to x64 only - x86 has no VC-LTL tier and stays static." '0;33')
                }
                $p = Read-Choice "Enter 1-4 (or Enter to keep the default)" 4
                switch ($p) { '1' { $Crt = 'msvcrt' } '2' { $Crt = 'static' } '3' { $Crt = 'dynamic' } '4' { $Crt = 'ucrt-local' } }

                # Debug CRT - only worth asking once a non-default Release CRT is chosen. Enter keeps the
                # static (debug) UCRT, so the debug heap and leak detection keep working whatever Release uses.
                if ($Crt -and -not $CrtDebug) {
                    Write-Host ''
                    Write-Host (Paint 'Debug CRT?  (Enter keeps static - the debug heap & leak detection)' '1;36')
                    Write-Host ("  {0} msvcrt.dll via VC-LTL5" -f (Paint '[1]' '0;36'))
                    Write-Host ("  {0} Static UCRT (/MT) - the default" -f (Paint '[2]' '0;36'))
                    Write-Host ("  {0} Dynamic UCRT (/MD)" -f (Paint '[3]' '0;36'))
                    Write-Host ("  {0} Dynamic UCRT, app-local (incl. non-redistributable debug DLLs)" -f (Paint '[4]' '0;36'))
                    $p = Read-Choice "Enter 1-4 (or Enter for static)" 4
                    switch ($p) { '1' { $CrtDebug = 'msvcrt' } '2' { $CrtDebug = 'static' } '3' { $CrtDebug = 'dynamic' } '4' { $CrtDebug = 'ucrt-local' } }
                }
            }
            # (Building is offered after generation, where the configurations/platforms are read from the .sln.)
        }
    }
    else { $VisualStudio = $defaultVersion }
}
Set-DefaultToolset

if (-not $skipGenerate) {
    $arguments = @("vs$VisualStudio") + (Get-OptionArgs)

    $xp = if ($SupportWinXP) { $SupportWinXP -eq 'On' } else { $true }
    Write-Host "$(Tag 'premake' '0;36') $(& $premake --version)"
    Write-Host "$(Tag 'generate' '0;32') vs$VisualStudio ($Toolset, $(if ($xp) {'Windows XP and later'} else {'Windows 10 and later'}))"

    Push-Location $consumerPremake
    try {
        & $premake @arguments
        if ($LASTEXITCODE -ne 0) { Write-Error 'premake could not generate the solution.'; exit $LASTEXITCODE }
    } finally {
        Pop-Location
    }
}

# DISCOVER the generated solution - its name is the premake workspace's, written to location().
$solution = Find-Solution $VisualStudio
if (-not $solution) { Write-Error "premake generated no $(if ($VisualStudio -eq '2026') { '.slnx' } else { '.sln' }) under '$Root' (or its .jbuild\)."; exit 1 }
Write-Host "$(Tag 'solution' '0;36') $($solution.FullName)"

# ---- optional build ----
# The configurations and platforms come from the generated solution itself (ground truth for what's
# supported - a consumer may define more than Debug/Release, or be one platform only).
if ($solution.Extension -eq '.slnx') {
    $slnx = [xml](Get-Content -LiteralPath $solution.FullName -Raw)
    $slnConfigNames   = @($slnx.Solution.Configurations.BuildType | ForEach-Object { $_.Name })
    $slnPlatformNames = @($slnx.Solution.Configurations.Platform | ForEach-Object { $_.Name })
} else {
    $slnText = Get-Content -LiteralPath $solution.FullName -Raw
    $slnPairs = [regex]::Matches($slnText, '(?m)^\s*(\w+)\|(\w+)\s*=\s*\1\|\2\s*$')
    $slnConfigNames   = @($slnPairs | ForEach-Object { $_.Groups[1].Value })
    $slnPlatformNames = @($slnPairs | ForEach-Object { $_.Groups[2].Value })
}
$slnConfigs   = @($slnConfigNames | Where-Object { $_ }) | Sort-Object -Unique
# Build-menu order, NOT alphabetical: x86 (Win32) is the standing default (index 0), then x64, then the ARM
# platforms - so a solution that contains ARM doesn't default to building the dead 32-bit ARM. Anything a
# consumer names outside this list sorts alphabetically after the known four.
$platOrder = @('Win32', 'x64', 'ARM', 'ARM64')
$slnPlatforms = @($slnPlatformNames | Where-Object { $_ } | Sort-Object -Unique |
    Sort-Object @{ Expression = { $i = $platOrder.IndexOf($_); if ($i -lt 0) { 99 } else { $i } } }, @{ Expression = { $_ } })
if (-not $slnConfigs)   { $slnConfigs   = @('Release') }
if (-not $slnPlatforms) { $slnPlatforms = @('Win32') }

$interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

# Configure is generation only. Build asks which configuration when none was given (Enter: Release, or the first).
if (-not $Build) { exit 0 }
if (-not $Configuration -and $interactive) {
    $cfgDefault = if ($slnConfigs -contains 'Release') { $slnConfigs.IndexOf('Release') } else { 0 }
    Write-Host ''
    Write-Host (Paint 'Build which configuration?' '1;36')
    for ($i = 0; $i -lt $slnConfigs.Count; $i++) { Write-Host ("  {0} {1}{2}" -f (Paint ("[{0}]" -f ($i + 1)) '0;36'), $slnConfigs[$i], $(if ($i -eq $cfgDefault) { Paint '  (default)' '0;32' } else { '' })) }
    $cfgAllIdx = $slnConfigs.Count + 1
    if ($slnConfigs.Count -gt 1) { Write-Host ("  {0} All ({1})" -f (Paint ("[{0}]" -f $cfgAllIdx) '0;36'), ($slnConfigs -join ' + ')) }
    $p = Read-Choice 'Enter a number (or Enter for the default)' ($slnConfigs.Count + $(if ($slnConfigs.Count -gt 1) { 1 } else { 0 }))
    if ([string]::IsNullOrWhiteSpace($p)) { $Configuration = $slnConfigs[$cfgDefault] }
    elseif ($p -match '^\d+$' -and [int]$p -ge 1 -and [int]$p -le $slnConfigs.Count) { $Configuration = $slnConfigs[[int]$p - 1] }
    elseif ($slnConfigs.Count -gt 1 -and $p -eq "$cfgAllIdx") { $Configuration = 'All' }
    else { Write-Error "Not a choice: '$p'."; exit 1 }
}

# Resolve the configuration (prefer Release) and validate it against the solution ('All' = every config).
if (-not $Configuration) { $Configuration = if ($slnConfigs -contains 'Release') { 'Release' } else { $slnConfigs[0] } }
elseif ($Configuration -ne 'All' -and $slnConfigs -notcontains $Configuration) {
    Write-Error "The solution has no '$Configuration' configuration (has: $($slnConfigs -join ', '))."; exit 1
}

# Resolve the platform: a value, or interactively from the solution's own platforms (+ All when >1).
if (-not $Platform) {
    if ($interactive) {
        Write-Host ''
        Write-Host (Paint 'Build which platform?' '1;36')
        for ($i = 0; $i -lt $slnPlatforms.Count; $i++) { Write-Host ("  {0} {1}{2}" -f (Paint ("[{0}]" -f ($i + 1)) '0;36'), $slnPlatforms[$i], $(if ($i -eq 0) { Paint '  (default)' '0;32' } else { '' })) }
        $allIdx = $slnPlatforms.Count + 1
        if ($slnPlatforms.Count -gt 1) { Write-Host ("  {0} All ({1})" -f (Paint ("[{0}]" -f $allIdx) '0;36'), ($slnPlatforms -join ' + ')) }
        $p = Read-Choice 'Enter a number (or Enter for the default)' ($slnPlatforms.Count + $(if ($slnPlatforms.Count -gt 1) { 1 } else { 0 }))
        if ([string]::IsNullOrWhiteSpace($p)) { $Platform = $slnPlatforms[0] }
        elseif ($p -match '^\d+$' -and [int]$p -ge 1 -and [int]$p -le $slnPlatforms.Count) { $Platform = $slnPlatforms[[int]$p - 1] }
        elseif ($slnPlatforms.Count -gt 1 -and $p -eq "$allIdx") { $Platform = 'All' }
        else { Write-Error "Not a choice: '$p'."; exit 1 }
    }
    else { $Platform = $slnPlatforms[0] }
}

# MSBuild is wherever this machine's Visual Studio put it; vswhere is the supported way to ask.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    Write-Error 'vswhere.exe was not found, so MSBuild cannot be located. Build from Visual Studio instead.'
    exit 1
}
# AN INSTALLATION THAT HAS THE TOOLSET, not merely the newest. -latest alone picked VS 2026 beside VS 2022, whose
# MSBuild has no v143 unless its installer added that component - MSB8020 on every project. And vswhere lists only
# Community/Professional/Enterprise unless told -products *, so Build Tools for Visual Studio was never seen at all.
# Every installation is considered, the one generated for (by version) first, and one counts only if its MSBuild
# has $Toolset under VC\v*\Platforms\*\PlatformToolsets - the folder MSBuild itself looks in.
$vsRanges = @{ '2017' = 15; '2019' = 16; '2022' = 17; '2026' = 18 }
# Out-String: vswhere's lines as one JSON text. ForEach-Object: Windows PowerShell 5.1's ConvertFrom-Json passes a
# JSON array on as ONE object (7 unrolls it), which then sorted as an array and failed to cast to [version].
$instances = @(& $vswhere -all -products * -requires Microsoft.Component.MSBuild -format json | Out-String | ConvertFrom-Json | ForEach-Object { $_ })
$hasToolset = { param($i) [bool](Get-ChildItem -Path (Join-Path $i.installationPath "MSBuild\Microsoft\VC\v*\Platforms\*\PlatformToolsets\$Toolset") -Directory -EA SilentlyContinue) }
$wanted = $vsRanges["$VisualStudio"]
$chosen = @($instances | Where-Object { & $hasToolset $_ } |
    Sort-Object @{ Expression = { $wanted -and ([int]($_.installationVersion -split '\.')[0]) -eq $wanted }; Descending = $true },
                @{ Expression = { [version]$_.installationVersion }; Descending = $true }) | Select-Object -First 1
$msbuild = $null
if ($chosen) {
    $msbuild = Get-ChildItem -Path (Join-Path $chosen.installationPath 'MSBuild\*\Bin\MSBuild.exe') -EA SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $msbuild) {
    $found = ($instances | ForEach-Object { "$($_.displayName) $($_.installationVersion)" }) -join '; '
    # The installer names a toolset's component after the Visual Studio it came with, whichever installs it.
    $toolsetVs = @{ 'v141_xp' = '2017'; 'v141' = '2017'; 'v142' = '2019'; 'v143' = '2022'; 'v145' = '2026' }[$Toolset]
    if (-not $toolsetVs) { $toolsetVs = $VisualStudio }
    Write-Error ("No Visual Studio here has the $Toolset build tools (found: $(if ($found) { $found } else { 'none' })). " +
        "Add them with the Visual Studio Installer: Modify > Individual components > " +
        "'MSVC $Toolset - VS $toolsetVs C++ x64/x86 build tools'. Or build from Visual Studio instead.")
    exit 1
}
Write-Host "$(Tag 'build' '0;36') $msbuild"

$buildConfigs   = if ($Configuration -eq 'All') { $slnConfigs }   else { @($Configuration) }
$buildPlatforms = if ($Platform      -eq 'All') { $slnPlatforms } else { @($Platform) }
foreach ($cfg in $buildConfigs) {
    foreach ($plat in $buildPlatforms) {
        if ($slnPlatforms -notcontains $plat) {
            Write-Warning "The solution has no '$plat' platform (has: $($slnPlatforms -join ', ')); skipping."
            continue
        }
        Write-Host ''
        Write-Host "$(Tag $msbuildTarget.ToLower() '1;34') $cfg / $plat"
        Write-Host ''
        & $msbuild $solution.FullName "/t:$msbuildTarget" "/p:Configuration=$cfg" "/p:Platform=$plat" /v:minimal /nologo /m
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}
exit 0
