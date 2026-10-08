<#
.SYNOPSIS
    Shared premake driver for repos that consume jbuild. Generates the Visual Studio solution and,
    with -Build, builds it headlessly via MSBuild.

.DESCRIPTION
    The build is described by the CONSUMER's premake5.lua at its repo root; this script only maps friendly
    parameters to premake options, runs the committed premake5.exe (jbuild\premake\), then locates the
    generated solution and hands it to MSBuild. Generic: the solution NAME and location come from the
    consumer's premake `workspace` (location(rootPath)), never this script - the *.sln is DISCOVERED, not
    hardcoded. Generation alone is just `premake5.exe vs2022` in the consumer's premake\ dir; this wrapper
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
    [ValidateSet('', '2017', '2019', '2022')]
    [string] $VisualStudio = '',

    [string] $Toolset = 'v143',

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

# This driver is at the jbuild root; premake5.exe and the shared .lua modules are in jbuild\premake\. The
# consumer's own premake5.lua is at its repo root ($Root). Checked in the premake branch below, so the
# cmake branch needs none of it.
$jbuildPremake = Join-Path $PSScriptRoot 'premake'
$premake = Join-Path $jbuildPremake 'premake5.exe'
$consumerPremake = $Root

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
            $p = Read-Host 'Enter 1-3 (or Enter for the default)'
            $vs = if ($p -match '^[1-3]$') { $vers[[int]$p - 1] } else { $vers[0] }
        }
        if (-not $arch) {
            Write-Host ''
            Write-Host (Paint 'Architecture?' '1;36')
            Write-Host ("  {0} Win32 (x86){1}" -f (Paint '[1]' '0;36'), (Paint '  (default)' '0;32'))
            Write-Host ("  {0} x64" -f (Paint '[2]' '0;36'))
            $p = Read-Host 'Enter 1-2 (or Enter for Win32)'
            $arch = if ($p -eq '2') { 'x64' } else { 'Win32' }
        }
        # 2017 is XP-only; 2019 offers modern (v142) or XP (v141_xp); 2022 is v143 (XP via SUPPORT_WINXP).
        if ($vs -eq '2017') { $xpToolset = $true }
        elseif ($vs -eq '2019') {
            Write-Host ''
            Write-Host (Paint 'Toolset?' '1;36')
            Write-Host ("  {0} v142 - modern (reaches XP via VC-LTL5 + YY-Thunks){1}" -f (Paint '[1]' '0;36'), (Paint '  (default)' '0;32'))
            Write-Host ("  {0} v141_xp - the XP toolset" -f (Paint '[2]' '0;36'))
            $p = Read-Host 'Enter 1-2 (or Enter for v142)'
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
            $p = Read-Host "Enter 1-$($esr.Count) (or Enter to keep the default)"
            if ($p -match '^\d+$' -and [int]$p -ge 1 -and [int]$p -le $esr.Count) { $sm = $esr[[int]$p - 1] }
        }
    }
    if ($sm) { $defs += "-DSPIDERMONKEY_VERSION=$sm" }

    # XP support - only meaningful for a modern toolset (the _xp presets are XP by definition). NO_ENHANCED_
    # INSTRUCTIONS follows it in the cmake script itself, so it is not a separate prompt.
    if (-not $xpToolset) {
        if ($interactive) {
            $p = Read-Host "`nWindows XP support?  [Enter] yes (default) / n no"
            if ($p -match '^[nN]') { $defs += '-DSUPPORT_WINXP=OFF' }
        }
        elseif ($SupportWinXP -eq 'Off') { $defs += '-DSUPPORT_WINXP=OFF' }
    }

    # Runtime - msvcrt.dll via VC-LTL5, or the static UCRT. Enter keeps the preset's default (non-XP presets
    # default to msvcrt, _xp ones to static), so static must pass -DUSE_MSVCRT=OFF explicitly to override it.
    # cmake has no dynamic / app-local UCRT equivalent.
    if ($interactive) {
        $p = Read-Host "`nCRT?  [Enter] the preset default / 1 msvcrt (VC-LTL5) / 2 static UCRT"
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
    if (-not $Build -and -not $interactive) { return }
    $cfg = $Configuration
    if (-not $cfg) {
        if (-not $interactive) { return }
        $p = Read-Host "`nBuild now?  [Enter] skip / 1 Debug / 2 Release / 3 both"
        switch ($p) { '1' { $cfg = 'Debug' } '2' { $cfg = 'Release' } '3' { $cfg = 'both' } default { return } }
    }
    if (-not $binDir) { Write-Error 'Could not resolve the preset build directory.'; exit 1 }
    foreach ($c in $(if ($cfg -eq 'both') { @('Debug', 'Release') } else { @($cfg) })) {
        Write-Host "$(Tag 'build' '1;34') $preset $c"
        & $cmake.Source --build $binDir --config $c
        if ($LASTEXITCODE -ne 0) { Write-Error "cmake build ($c) failed."; exit $LASTEXITCODE }
    }
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
        $p = Read-Host 'Enter 1-2 (or Enter for premake)'
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
if (-not (Test-Path -LiteralPath $premake)) {
    Write-Error "premake5.exe is missing from $jbuildPremake - it is committed to jbuild; check the working tree is complete."
    exit 1
}
if (-not $hasPremake) { Write-Error "Build system 'premake' chosen, but no premake5.lua at '$Root'."; exit 1 }

# No VS version chosen (e.g. a double-click with no args): offer a menu. In a non-interactive context
# (piped / CI, where stdin is redirected) fall back to the newest so a prompt never hangs the run.
if (-not $VisualStudio) {
    $versions = @('2022', '2019', '2017')
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        # --- Visual Studio version ---
        Write-Host ''
        Write-Host (Paint 'Generate for which Visual Studio?' '1;36')
        for ($i = 0; $i -lt $versions.Count; $i++) {
            Write-Host ("  {0} Visual Studio {1}{2}" -f (Paint ("[{0}]" -f ($i + 1)) '0;36'), $versions[$i], $(if ($i -eq 0) { Paint '  (default)' '0;32' } else { '' }))
        }
        $pick = Read-Host 'Enter 1-3 (or press Enter for the default)'
        if ([string]::IsNullOrWhiteSpace($pick)) { $VisualStudio = $versions[0] }
        elseif ($pick -match '^[1-3]$')          { $VisualStudio = $versions[[int]$pick - 1] }
        else { Write-Error "Not a choice: '$pick'."; exit 1 }

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
                    $p = Read-Host "Enter 1-$($esr.Count) (or Enter to keep the default)"
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
                $p = Read-Host "Enter 1-$($oses.Count) (or Enter to keep the default)"
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
                $p = Read-Host "Enter 1-4 (or Enter to keep the default)"
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
                    $p = Read-Host "Enter 1-4 (or Enter for static)"
                    switch ($p) { '1' { $CrtDebug = 'msvcrt' } '2' { $CrtDebug = 'static' } '3' { $CrtDebug = 'dynamic' } '4' { $CrtDebug = 'ucrt-local' } }
                }
            }
            # (Building is offered after generation, where the configurations/platforms are read from the .sln.)
        }
    }
    else { $VisualStudio = $versions[0] }
}

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

# DISCOVER the generated solution - its name is the premake workspace's, written to location(). The
# convention is location ".jbuild" (gitignored build output), so look there first, then the repo root.
$solution = @(
    @(Get-ChildItem -LiteralPath (Join-Path $Root '.jbuild') -Filter *.sln -File -EA SilentlyContinue) +
    @(Get-ChildItem -LiteralPath $Root -Filter *.sln -File -EA SilentlyContinue)) | Select-Object -First 1
if (-not $solution) { Write-Error "premake generated no .sln under '$Root' (or its .jbuild\)."; exit 1 }
Write-Host "$(Tag 'solution' '0;36') $($solution.FullName)"

# ---- optional build ----
# The configurations and platforms come from the generated solution itself (ground truth for what's
# supported - a consumer may define more than Debug/Release, or be one platform only).
$slnText = Get-Content -LiteralPath $solution.FullName -Raw
$slnPairs = [regex]::Matches($slnText, '(?m)^\s*(\w+)\|(\w+)\s*=\s*\1\|\2\s*$')
$slnConfigs   = @($slnPairs | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
# Build-menu order, NOT alphabetical: x86 (Win32) is the standing default (index 0), then x64, then the ARM
# platforms - so a solution that contains ARM doesn't default to building the dead 32-bit ARM. Anything a
# consumer names outside this list sorts alphabetically after the known four.
$platOrder = @('Win32', 'x64', 'ARM', 'ARM64')
$slnPlatforms = @($slnPairs | ForEach-Object { $_.Groups[2].Value } | Sort-Object -Unique |
    Sort-Object @{ Expression = { $i = $platOrder.IndexOf($_); if ($i -lt 0) { 99 } else { $i } } }, @{ Expression = { $_ } })
if (-not $slnConfigs)   { $slnConfigs   = @('Release') }
if (-not $slnPlatforms) { $slnPlatforms = @('Win32') }

$interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

# Whether to build. Not asked for unless interactive; -Build (or picking a configuration below) opts in.
if (-not $Build) {
    if (-not $interactive) { exit 0 }   # generation only
    Write-Host ''
    Write-Host (Paint 'Build now? Pick a configuration, or press Enter to just generate and open it yourself:' '1;36')
    for ($i = 0; $i -lt $slnConfigs.Count; $i++) { Write-Host ("  {0} {1}" -f (Paint ("[{0}]" -f ($i + 1)) '0;36'), $slnConfigs[$i]) }
    $cfgAllIdx = $slnConfigs.Count + 1
    if ($slnConfigs.Count -gt 1) { Write-Host ("  {0} All ({1})" -f (Paint ("[{0}]" -f $cfgAllIdx) '0;36'), ($slnConfigs -join ' + ')) }
    $p = Read-Host 'Enter a number to build (or Enter to skip)'
    if ([string]::IsNullOrWhiteSpace($p)) { exit 0 }
    elseif ($p -match '^\d+$' -and [int]$p -ge 1 -and [int]$p -le $slnConfigs.Count) { $Build = $true; $Configuration = $slnConfigs[[int]$p - 1] }
    elseif ($slnConfigs.Count -gt 1 -and $p -eq "$cfgAllIdx") { $Build = $true; $Configuration = 'All' }
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
        $p = Read-Host 'Enter a number (or Enter for the default)'
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
$msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { Write-Error 'No MSBuild was found. Build from Visual Studio instead.'; exit 1 }

$buildConfigs   = if ($Configuration -eq 'All') { $slnConfigs }   else { @($Configuration) }
$buildPlatforms = if ($Platform      -eq 'All') { $slnPlatforms } else { @($Platform) }
foreach ($cfg in $buildConfigs) {
    foreach ($plat in $buildPlatforms) {
        if ($slnPlatforms -notcontains $plat) {
            Write-Warning "The solution has no '$plat' platform (has: $($slnPlatforms -join ', ')); skipping."
            continue
        }
        Write-Host ''
        Write-Host "$(Tag 'build' '1;34') $cfg / $plat"
        Write-Host ''
        & $msbuild $solution.FullName "/p:Configuration=$cfg" "/p:Platform=$plat" /v:minimal /nologo /m
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}
exit 0
