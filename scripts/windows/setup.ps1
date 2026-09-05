[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $InstallDirectory = (Join-Path $HOME ".local\lib\cargo-cache")
)

$ErrorActionPreference = "Stop"

function Expand-InstallPath([string] $Path) {
    if ($Path -eq "~") {
        $Path = $HOME
    } elseif ($Path.StartsWith("~\") -or $Path.StartsWith("~/")) {
        $Path = Join-Path $HOME $Path.Substring(2)
    }
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd([char[]] @('\', '/'))
}

function Get-ComparisonPath([string] $Path) {
    try {
        return Expand-InstallPath $Path
    } catch {
        return $Path.Trim().TrimEnd([char[]] @('\', '/'))
    }
}

if ($env:OS -ne "Windows_NT") {
    throw "This setup script installs the native Windows wrapper and must run on Windows."
}

$realCargo = Get-Command cargo.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $realCargo) {
    throw "cargo.exe was not found on PATH. Install Rust/Cargo before installing the wrapper."
}

$installPath = Expand-InstallPath $InstallDirectory
$sourcePath = Expand-InstallPath $PSScriptRoot
$runtimeFiles = @(
    "cargo.cmd",
    "cargo-gc.cmd",
    "cargo-with-cached-target.ps1",
    "cargo-gc.ps1"
)

foreach ($name in $runtimeFiles) {
    $source = Join-Path $sourcePath $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "required runtime file is missing: $source"
    }
}

if ($PSCmdlet.ShouldProcess($installPath, "install the Cargo target-cache wrapper")) {
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    foreach ($name in $runtimeFiles) {
        $source = Join-Path $sourcePath $name
        $destination = Join-Path $installPath $name
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals($source, $destination)) {
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
    }
}

# Keep the install directory first in the user PATH and remove duplicate copies
# of that exact directory. Other entries retain their existing order.
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$pathEntries = @()
if (-not [string]::IsNullOrWhiteSpace($userPath)) {
    $pathEntries = @($userPath.Split([IO.Path]::PathSeparator) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$newEntries = [Collections.Generic.List[string]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$newEntries.Add($installPath)
[void] $seen.Add((Get-ComparisonPath $installPath))
foreach ($entry in $pathEntries) {
    $trimmed = $entry.Trim()
    $comparison = Get-ComparisonPath $trimmed
    if ($seen.Add($comparison)) {
        $newEntries.Add($trimmed)
    }
}
$newUserPath = [string]::Join([IO.Path]::PathSeparator, $newEntries)

if ($PSCmdlet.ShouldProcess("the current user's PATH", "prepend $installPath")) {
    [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
}

if ($WhatIfPreference) {
    Write-Output "No changes made because -WhatIf was supplied."
    exit 0
}

# This only affects the setup process, but lets us validate command discovery.
# Existing parent shells still need to be reopened to receive the user PATH.
$processEntries = @($env:Path.Split([IO.Path]::PathSeparator) | Where-Object {
    -not [StringComparer]::OrdinalIgnoreCase.Equals((Get-ComparisonPath $_), (Get-ComparisonPath $installPath))
})
$env:Path = [string]::Join([IO.Path]::PathSeparator, @($installPath) + $processEntries)
$resolvedCargo = Get-Command cargo -CommandType Application -ErrorAction Stop | Select-Object -First 1
$expectedLauncher = Join-Path $installPath "cargo.cmd"
if (-not [StringComparer]::OrdinalIgnoreCase.Equals((Get-ComparisonPath $resolvedCargo.Source), (Get-ComparisonPath $expectedLauncher))) {
    throw "installation completed, but cargo resolves to '$($resolvedCargo.Source)' instead of '$expectedLauncher'"
}

Write-Output "Installed Cargo target-cache wrapper in: $installPath"
Write-Output "Real Cargo executable: $($realCargo.Source)"
Write-Output "Updated the current user's PATH with the wrapper directory first."
Write-Output "Open a new terminal (and restart Codex if it was already running) before using cargo."
