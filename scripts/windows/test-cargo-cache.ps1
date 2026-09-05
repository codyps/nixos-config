[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Assert([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "assertion failed: $Message" }
}

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    Write-Output "Windows integration tests skipped: this host is not Windows."
    exit 0
}

$realCargo = (Get-Command cargo.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$powerShell = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
$wrapper = Join-Path $PSScriptRoot "cargo-with-cached-target.ps1"
$collector = Join-Path $PSScriptRoot "cargo-gc.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("cargo-cache-test-" + [Guid]::NewGuid().ToString("N"))
$project = Join-Path $testRoot "project-with-dash"
$cacheHome = Join-Path $testRoot "cache-home"
$cacheRoot = Join-Path $cacheHome "cargo-targets"

try {
    New-Item -ItemType Directory -Path (Join-Path $project "src") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $project "Cargo.toml") -Encoding ASCII -Value @"
[package]
name = "cargo-cache-wrapper-test"
version = "0.0.0"
edition = "2021"
"@
    Set-Content -LiteralPath (Join-Path $project "src/main.rs") -Encoding ASCII -Value "fn main() {}"

    $oldRealCargo = $env:CARGO_WRAPPER_REAL_CARGO
    $oldCacheHome = $env:XDG_CACHE_HOME
    $hadRealCargo = Test-Path Env:CARGO_WRAPPER_REAL_CARGO
    $hadCacheHome = Test-Path Env:XDG_CACHE_HOME
    $env:CARGO_WRAPPER_REAL_CARGO = $realCargo
    $env:XDG_CACHE_HOME = $cacheHome

    Push-Location $project
    try {
        & $powerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wrapper metadata --no-deps --format-version 1 | Out-Null
        Assert ($LASTEXITCODE -eq 0) "cargo metadata failed"
        Assert (-not (Test-Path -LiteralPath (Join-Path $project "target"))) "metadata created target"

        & $powerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wrapper build --help | Out-Null
        Assert ($LASTEXITCODE -eq 0) "cargo build --help failed"
        Assert (-not (Test-Path -LiteralPath (Join-Path $project "target"))) "build --help created target"

        & $powerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wrapper build --quiet
        Assert ($LASTEXITCODE -eq 0) "cargo build failed"
        $target = Get-Item -LiteralPath (Join-Path $project "target") -Force
        Assert (($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) "target is not a junction"
        Assert ((Get-ChildItem -LiteralPath $cacheRoot -Directory).Count -eq 1) "expected one cache directory"

        & $powerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $wrapper clean
        Assert ($LASTEXITCODE -eq 0) "cargo clean failed"
        Assert (-not (Test-Path -LiteralPath (Join-Path $project "target"))) "clean left the target junction"
    } finally {
        Pop-Location
    }

    $sample = Join-Path $cacheRoot "sample"
    New-Item -ItemType Directory -Path $sample -Force | Out-Null
    & $powerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $collector gc --cache-root $cacheRoot | Out-Null
    Assert ($LASTEXITCODE -eq 0) "cargo gc preview failed"
    Assert (Test-Path -LiteralPath $sample) "preview deleted a cache"
    & $powerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $collector gc --cache-root $cacheRoot --delete | Out-Null
    Assert ($LASTEXITCODE -eq 0) "cargo gc --delete failed"
    Assert (-not (Test-Path -LiteralPath $sample)) "cargo gc did not delete a cache"

    Write-Output "Windows Cargo cache tests: ok"
} finally {
    if ($hadRealCargo) { $env:CARGO_WRAPPER_REAL_CARGO = $oldRealCargo } else { Remove-Item Env:CARGO_WRAPPER_REAL_CARGO -ErrorAction SilentlyContinue }
    if ($hadCacheHome) { $env:XDG_CACHE_HOME = $oldCacheHome } else { Remove-Item Env:XDG_CACHE_HOME -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
