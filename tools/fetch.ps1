# Fetches a pinned third-party release into jbuild\tools\<name>\<version>\, once: downloaded, checked against
# its SHA-256, extracted, then marked complete. Run by premake\XP.lua for a tool whose environment variable is
# not set (VC-LTL5, YY-Thunks), the way make\premake.sh fetches premake into tools\premake\.
#
#     fetch.ps1 -Name vc-ltl5 -Version 5.3.1 -Url <asset> -Sha256 <hash>
#
# A .zip is extracted by PowerShell, a .7z by Windows' own tar.exe (libarchive, in System32 since Windows 10
# 1803) - named by its full path, as Git's tar may be first on PATH and reads no 7z. The folder is complete
# only when its marker is there; a failure part-way leaves no marker and the next run starts again.

param(
	[Parameter(Mandatory)] [string] $Name,
	[Parameter(Mandatory)] [string] $Version,
	[Parameter(Mandatory)] [string] $Url,
	[Parameter(Mandatory)] [string] $Sha256
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's progress bar makes it many times slower

$dest = Join-Path (Join-Path $PSScriptRoot $Name) $Version
$marker = Join-Path $dest '.jbuild-complete'
if (Test-Path $marker) {
	exit 0
}

Write-Host "[fetch] $Name $Version ($Url)"

$work = "$dest.tmp"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Force $work | Out-Null

try {
	$file = Join-Path $work ([System.IO.Path]::GetFileName(([Uri]$Url).AbsolutePath))
	[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
	Invoke-WebRequest -Uri $Url -OutFile $file -UseBasicParsing

	$got = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
	if ($got -ne $Sha256.ToLowerInvariant()) {
		throw "$Name $Version has SHA-256 $got, expected $Sha256"
	}

	$out = Join-Path $work 'out'
	New-Item -ItemType Directory -Force $out | Out-Null
	if ($file -like '*.zip') {
		Expand-Archive -Path $file -DestinationPath $out -Force
	} else {
		$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
		if (-not (Test-Path $tar)) {
			throw "Windows' tar.exe ($tar) is needed to extract $file; or extract it yourself and set the tool's variable"
		}
		& $tar -xf $file -C $out
		if ($LASTEXITCODE -ne 0) { throw "tar could not extract $file" }
	}

	Move-Item $out $dest
	Set-Content -Path $marker -Value "$Name $Version $Url"
} finally {
	if (Test-Path $work) { Remove-Item -Recurse -Force $work }
}
