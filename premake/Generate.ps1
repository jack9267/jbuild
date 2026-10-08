<#
.SYNOPSIS
    Shared premake driver for repos that consume jbuild. Generates the Visual Studio solution and,
    with -Build, builds it headlessly via MSBuild.

.DESCRIPTION
    The build is described by the CONSUMER's premake\premake5.lua; this script only maps friendly
    parameters to premake options and runs the committed premake5.exe (co-located here), then locates
    the generated solution and hands it to MSBuild. It is generic: the solution NAME and location come
    from the consumer's premake `workspace` (location(rootPath)), never from this script - so the
    generated *.sln is DISCOVERED, not hardcoded.

    Generation alone is just `premake5.exe vs2022` run in the consumer's premake\ dir; this wrapper adds
    the parameter mapping and the optional non-interactive build (CI / no Visual Studio open).

.PARAMETER Root
    The consumer repo root - where premake\premake5.lua lives and where its `location(rootPath)` writes
    the .sln. Defaults to this script's grandparent (correct when jbuild is a submodule at <consumer>\jbuild);
    pass it explicitly for a sibling checkout.

.PARAMETER Build
    Also build the generated solution with MSBuild after generating.
#>
param(
    [string] $Root = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),

    # Empty offers an interactive menu (what a double-click with no args gets); a value skips it.
    [ValidateSet('', '2017', '2019', '2022')]
    [string] $VisualStudio = '',

    [string] $Toolset = 'v143',

    [switch] $Build,

    # Build configuration; empty = chosen from the solution's own configurations (a prompt, or the default).
    [string] $Configuration = '',

    # Empty lets the build step choose (a prompt, or the solution's first platform); 'All' builds every
    # platform the generated solution offers.
    [ValidateSet('', 'Win32', 'x64', 'All')]
    [string] $Platform = '',

    [string] $NoEnhancedInstructions = '',

    # Oldest Windows the binaries must run on (supersedes -SupportWinXP). The menu offers this list.
    [ValidateSet('', 'win2000', 'winxp', 'vista', 'win7', 'win8', 'win81', 'win10', 'win11')]
    [string] $TargetOs = '',

    [string] $SupportWinXP = '',
    [string] $UseMsvcrt = '',
    [string] $YYThunksTLS = '',

    [ValidateSet('0', '1', '2', '3', '4')]
    [string] $WarningLevel = '',

    # SpiderMonkey ESR the JS backend links against ($(jspidermonkey_home)\esr<NN>); empty keeps
    # the consumer premake5.lua's default. Mirrors the engine's -DSPIDERMONKEY_VERSION.
    [string] $SpiderMonkeyVersion = ''
)

$ErrorActionPreference = 'Stop'

# Colorized output in the style of the makefiles' CMake-like tags (make/common.mk: green [CXX], cyan [AR],
# bold-blue [LINK]). Dropped when NO_COLOR is set or the output is redirected (CI logs / dumb terminals).
$script:Color = (-not $env:NO_COLOR) -and (-not [Console]::IsOutputRedirected)
function Paint([string]$text, [string]$code) { if ($script:Color) { "$([char]27)[${code}m$text$([char]27)[0m" } else { $text } }
function Tag([string]$name, [string]$code)   { Paint "[$name]" $code }

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
        # flag (premake errors on one). Discover declared options by scanning its premake tree for newoption
        # triggers. Each prompt defaults to Enter = keep premake5.lua's own default.
        Write-Host ''
        Write-Host "Press 'o' to set options, or Enter to generate now " -NoNewline
        $gate = [Console]::ReadKey($true); Write-Host ''
        if ($gate.KeyChar -eq 'o' -or $gate.KeyChar -eq 'O') {
            # Scan the consumer's premake dir AND this driver's own dir ($PSScriptRoot) - the shared jbuild
            # modules (XP.lua / Common.lua, which declare support-winxp / use-msvcrt) live beside the driver,
            # so options moved into the jbuild submodule are still discovered.
            $declared = @(
                (@(Get-ChildItem (Join-Path $Root 'premake') -Recurse -Filter *.lua -EA SilentlyContinue) +
                 @(Get-ChildItem $PSScriptRoot -Filter *.lua -EA SilentlyContinue)) |
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
                    $pml = Join-Path $Root 'premake\premake5.lua'
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
            # CRT - not offered for a Windows 2000 target (its x86 msvcrt.dll predates VC-LTL's XP floor).
            if (($declared -contains 'use-msvcrt') -and -not $UseMsvcrt -and $TargetOs -ne 'win2000') {
                $p = Read-Host "`nCRT?  [Enter] keep default / 1 msvcrt (VC-LTL5) / 2 static UCRT"
                if ($p -eq '1') { $UseMsvcrt = 'On' } elseif ($p -eq '2') { $UseMsvcrt = 'Off' }
            }
            # (Building is offered after generation, where the configurations/platforms are read from the .sln.)
        }
    }
    else { $VisualStudio = $versions[0] }
}

$premake = Join-Path $PSScriptRoot 'premake5.exe'
if (-not (Test-Path -LiteralPath $premake)) {
    Write-Error "premake5.exe is missing from $PSScriptRoot - it is committed to jbuild; check the working tree is complete."
    exit 1
}

$consumerPremake = Join-Path $Root 'premake'
if (-not (Test-Path -LiteralPath (Join-Path $consumerPremake 'premake5.lua'))) {
    Write-Error "No premake5.lua under '$consumerPremake'. Pass -Root <consumer repo root>."
    exit 1
}

$arguments = @("vs$VisualStudio", "--toolset=$Toolset")
if ($NoEnhancedInstructions) { $arguments += "--no-enhanced-instructions=$($NoEnhancedInstructions.ToLower())" }
if ($TargetOs)               { $arguments += "--target-os=$TargetOs" }
if ($WarningLevel)           { $arguments += "--warning-level=$WarningLevel" }
if ($SupportWinXP)           { $arguments += "--support-winxp=$($SupportWinXP.ToLower())" }
if ($UseMsvcrt)              { $arguments += "--use-msvcrt=$($UseMsvcrt.ToLower())" }
if ($YYThunksTLS)            { $arguments += "--yy-thunks-tls=$($YYThunksTLS.ToLower())" }
if ($SpiderMonkeyVersion)    { $arguments += "--spidermonkey-version=$SpiderMonkeyVersion" }

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

# DISCOVER the generated solution - its name is the premake workspace's, written to location(rootPath).
$solution = Get-ChildItem -LiteralPath $Root -Filter *.sln -File | Select-Object -First 1
if (-not $solution) { Write-Error "premake generated no .sln under '$Root'."; exit 1 }
Write-Host "$(Tag 'solution' '0;36') $($solution.FullName)"

# ---- optional build ----
# The configurations and platforms come from the generated solution itself (ground truth for what's
# supported - a consumer may define more than Debug/Release, or be one platform only).
$slnText = Get-Content -LiteralPath $solution.FullName -Raw
$slnPairs = [regex]::Matches($slnText, '(?m)^\s*(\w+)\|(\w+)\s*=\s*\1\|\2\s*$')
$slnConfigs   = @($slnPairs | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
$slnPlatforms = @($slnPairs | ForEach-Object { $_.Groups[2].Value }) | Sort-Object -Unique
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
