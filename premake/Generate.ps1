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

    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [ValidateSet('Win32', 'x64')]
    [string] $Platform = 'Win32',

    [string] $NoEnhancedInstructions = '',
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

# No VS version chosen (e.g. a double-click with no args): offer a menu. In a non-interactive context
# (piped / CI, where stdin is redirected) fall back to the newest so a prompt never hangs the run.
if (-not $VisualStudio) {
    $versions = @('2022', '2019', '2017')
    if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        # --- Visual Studio version ---
        Write-Host ''
        Write-Host 'Generate for which Visual Studio?'
        for ($i = 0; $i -lt $versions.Count; $i++) {
            Write-Host ("  [{0}] Visual Studio {1}{2}" -f ($i + 1), $versions[$i], $(if ($i -eq 0) { '  (default)' } else { '' }))
        }
        $pick = Read-Host 'Enter 1-3 (or press Enter for the default)'
        if ([string]::IsNullOrWhiteSpace($pick)) { $VisualStudio = $versions[0] }
        elseif ($pick -match '^[1-3]$')          { $VisualStudio = $versions[[int]$pick - 1] }
        else { Write-Error "Not a choice: '$pick'."; exit 1 }

        # --- optional extra options ---
        # Only the knobs the consumer's premake actually declares are offered, so we never pass an unknown
        # flag (premake errors on one). Discover declared options by scanning its premake tree for newoption
        # triggers. Each prompt defaults to Enter = keep premake5.lua's own default.
        if ((Read-Host "`nPress Enter to generate now, or type 'o' to set options") -match '^[oO]') {
            $declared = @(Get-ChildItem (Join-Path $Root 'premake') -Recurse -Filter *.lua -EA SilentlyContinue |
                Select-String -Pattern 'trigger\s*=\s*"([^"]+)"' -AllMatches |
                ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique

            # SpiderMonkey ESR - list what's actually installed under jspidermonkey_home.
            if (($declared -contains 'spidermonkey-version') -and -not $SpiderMonkeyVersion -and
                $env:jspidermonkey_home -and (Test-Path -LiteralPath $env:jspidermonkey_home)) {
                $esr = @(Get-ChildItem -LiteralPath $env:jspidermonkey_home -Directory -Filter 'esr*' -EA SilentlyContinue |
                    ForEach-Object { $_.Name -replace '^esr', '' } | Where-Object { $_ -match '^\d+$' }) |
                    Sort-Object { [int]$_ }
                if ($esr) {
                    Write-Host "`nSpiderMonkey ESR (installed under $env:jspidermonkey_home):"
                    for ($i = 0; $i -lt $esr.Count; $i++) { Write-Host ("  [{0}] esr{1}" -f ($i + 1), $esr[$i]) }
                    $p = Read-Host "Enter 1-$($esr.Count) (or Enter to keep premake5.lua's default)"
                    if ($p -match '^\d+$' -and [int]$p -ge 1 -and [int]$p -le $esr.Count) { $SpiderMonkeyVersion = $esr[[int]$p - 1] }
                }
            }
            # Windows XP support.
            if (($declared -contains 'support-winxp') -and -not $SupportWinXP) {
                $p = Read-Host "`nWindows XP support?  [Enter] keep default (On) / 1 On / 2 Off"
                if ($p -eq '1') { $SupportWinXP = 'On' } elseif ($p -eq '2') { $SupportWinXP = 'Off' }
            }
            # CRT.
            if (($declared -contains 'use-msvcrt') -and -not $UseMsvcrt) {
                $p = Read-Host "`nCRT?  [Enter] keep default / 1 msvcrt (VC-LTL5) / 2 static UCRT"
                if ($p -eq '1') { $UseMsvcrt = 'On' } elseif ($p -eq '2') { $UseMsvcrt = 'Off' }
            }
            # Build after generating?
            if (-not $Build) {
                $p = Read-Host "`nBuild after generating?  [Enter] no, just generate / 1 Release / 2 Debug"
                if ($p -eq '1') { $Build = $true; $Configuration = 'Release' }
                elseif ($p -eq '2') { $Build = $true; $Configuration = 'Debug' }
            }
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
if ($WarningLevel)           { $arguments += "--warning-level=$WarningLevel" }
if ($SupportWinXP)           { $arguments += "--support-winxp=$($SupportWinXP.ToLower())" }
if ($UseMsvcrt)              { $arguments += "--use-msvcrt=$($UseMsvcrt.ToLower())" }
if ($YYThunksTLS)            { $arguments += "--yy-thunks-tls=$($YYThunksTLS.ToLower())" }
if ($SpiderMonkeyVersion)    { $arguments += "--spidermonkey-version=$SpiderMonkeyVersion" }

$xp = if ($SupportWinXP) { $SupportWinXP -eq 'On' } else { $true }
Write-Host "premake    $(& $premake --version)"
Write-Host "generating vs$VisualStudio ($Toolset, $(if ($xp) {'Windows XP and later'} else {'Windows 10 and later'}))"

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
Write-Host "solution   $($solution.FullName)"

if (-not $Build) { exit 0 }

# MSBuild is wherever this machine's Visual Studio put it; vswhere is the supported way to ask.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    Write-Error 'vswhere.exe was not found, so MSBuild cannot be located. Build from Visual Studio instead.'
    exit 1
}
$msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { Write-Error 'No MSBuild was found. Build from Visual Studio instead.'; exit 1 }

Write-Host ''
Write-Host "building   $Configuration / $Platform"
Write-Host ''
& $msbuild $solution.FullName "/p:Configuration=$Configuration" "/p:Platform=$Platform" /v:minimal /nologo /m
exit $LASTEXITCODE
