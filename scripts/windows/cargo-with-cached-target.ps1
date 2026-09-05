[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [AllowEmptyCollection()]
    [string[]] $CargoArguments
)

$ErrorActionPreference = "Stop"

function Normalize-Path([string] $Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        return $full.TrimEnd([char[]] @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    }
    return $full
}

function Expand-HomePath([string] $Path) {
    if ($Path -eq "~") {
        return $HOME
    }
    if ($Path.StartsWith("~\") -or $Path.StartsWith("~/")) {
        return Join-Path $HOME $Path.Substring(2)
    }
    return $Path
}

function Paths-Equal([string] $Left, [string] $Right) {
    return [StringComparer]::OrdinalIgnoreCase.Equals((Normalize-Path $Left), (Normalize-Path $Right))
}

function Invoke-RealCargo([string] $RealCargo, [string[]] $Arguments) {
    & $RealCargo @Arguments
    exit $LASTEXITCODE
}

function Test-SubcommandArgument([string] $Wanted, [int] $SubcommandIndex) {
    for ($i = $SubcommandIndex + 1; $i -lt $CargoArguments.Count; $i++) {
        $argument = $CargoArguments[$i]
        if ($argument -eq "--") { break }
        if ($argument -eq $Wanted -or $argument.StartsWith("$Wanted=")) { return $true }
    }
    return $false
}

function Get-SubcommandOption([string] $Wanted, [int] $SubcommandIndex) {
    for ($i = $SubcommandIndex + 1; $i -lt $CargoArguments.Count; $i++) {
        $argument = $CargoArguments[$i]
        if ($argument -eq "--") { break }
        if ($argument.StartsWith("$Wanted=")) { return $argument.Substring($Wanted.Length + 1) }
        if ($argument -eq $Wanted -and $i + 1 -lt $CargoArguments.Count) { return $CargoArguments[$i + 1] }
    }
    return $null
}

function Get-NestedSubcommand([int] $SubcommandIndex) {
    $optionsWithValues = @("--config", "--color", "--manifest-path", "--target-dir", "-C", "-m", "-Z")
    for ($i = $SubcommandIndex + 1; $i -lt $CargoArguments.Count; $i++) {
        $argument = $CargoArguments[$i]
        if ($argument -eq "--") { break }
        if ($optionsWithValues -contains $argument) { $i++; continue }
        if ($argument.StartsWith("-")) { continue }
        return $argument
    }
    return $null
}

function Get-ReparseTarget([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
        return $null
    }
    $targets = @($item.Target)
    if ($targets.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string] $targets[0])) {
        return $null
    }
    $target = [string] $targets[0]
    if (-not [IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path -Parent $Path) $target
    }
    return Normalize-Path $target
}

function Get-ManagedTarget([string] $Link, [string[]] $CacheRoots) {
    $destination = Get-ReparseTarget $Link
    if ($null -eq $destination) { return $null }
    foreach ($cacheRoot in $CacheRoots) {
        if (Paths-Equal (Split-Path -Parent $destination) $cacheRoot) {
            return $destination
        }
    }
    return $null
}

function Remove-DirectoryLink([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
        throw "refusing to remove a path that is not a directory link: $Path"
    }
    [IO.Directory]::Delete($Path, $false)
}

if ($null -eq $CargoArguments) { $CargoArguments = @() }

$realCargo = $env:CARGO_WRAPPER_REAL_CARGO
if ([string]::IsNullOrWhiteSpace($realCargo)) {
    $cargoCommand = Get-Command cargo.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $cargoCommand) {
        Write-Error "cargo wrapper: cargo.exe was not found on PATH"
        exit 1
    }
    $realCargo = $cargoCommand.Source
}

$toolchainArguments = [Collections.Generic.List[string]]::new()
$cargoPrefixArguments = [Collections.Generic.List[string]]::new()
$metadataArguments = [Collections.Generic.List[string]]::new()
$subcommand = $null
$subcommandIndex = -1
$hasTargetDirectory = $false

if ($CargoArguments.Count -gt 0 -and $CargoArguments[0].StartsWith("+")) {
    $toolchainArguments.Add($CargoArguments[0])
}

$globalOptionsWithValues = @("--config", "--color", "--explain", "--manifest-path", "--target-dir", "-m", "-Z")
for ($i = 0; $i -lt $CargoArguments.Count; $i++) {
    $argument = $CargoArguments[$i]
    if ($i -eq 0 -and $argument.StartsWith("+")) { continue }
    if ($argument -eq "-C") {
        if ($i + 1 -lt $CargoArguments.Count) {
            $cargoPrefixArguments.Add($argument)
            $cargoPrefixArguments.Add($CargoArguments[++$i])
        }
        continue
    }
    if ($argument.StartsWith("-C") -and $argument.Length -gt 2) {
        $cargoPrefixArguments.Add($argument)
        continue
    }
    if ($globalOptionsWithValues -contains $argument) { $i++; continue }
    if ($argument -eq "--") { break }
    if ($argument.StartsWith("-")) { continue }
    $subcommand = $argument
    $subcommandIndex = $i
    break
}

# Dispatch the wrapper-owned collector directly. This does not depend on Cargo
# or Rust's Windows executable lookup recognizing a .cmd external subcommand.
if ($subcommand -eq "gc") {
    $gcArguments = @($CargoArguments[$subcommandIndex..($CargoArguments.Count - 1)])
    & (Join-Path $PSScriptRoot "cargo-gc.ps1") @gcArguments
    exit $LASTEXITCODE
}

for ($i = 0; $i -lt $CargoArguments.Count; $i++) {
    $argument = $CargoArguments[$i]
    if ($argument -eq "--") { break }
    switch -Regex ($argument) {
        '^--target-dir$' { $hasTargetDirectory = $true; $i++; continue }
        '^--target-dir=' { $hasTargetDirectory = $true; continue }
        '^(--manifest-path|--config|-m|-Z)$' {
            if ($i + 1 -lt $CargoArguments.Count) {
                $metadataArguments.Add($argument)
                $metadataArguments.Add($CargoArguments[++$i])
            }
            continue
        }
        '^(--manifest-path=|--config=|-m.+|-Z.+)' { $metadataArguments.Add($argument); continue }
        '^(--locked|--offline|--frozen)$' { $metadataArguments.Add($argument); continue }
    }
}

if (-not [string]::IsNullOrEmpty($env:CARGO_TARGET_DIR) -or $hasTargetDirectory) {
    Invoke-RealCargo $realCargo $CargoArguments
}

$targetAction = "none"
$workspaceManifestOverride = $null
$createCommands = @("b", "bench", "build", "c", "check", "clippy", "d", "doc", "expand", "fix", "package", "publish", "r", "run", "rustc", "rustdoc", "t", "test")
if ($createCommands -contains $subcommand) {
    $targetAction = "create"
} elseif ($subcommand -eq "clean") {
    $targetAction = "clean"
} elseif ($subcommand -in @("embed", "flash")) {
    if (-not (Test-SubcommandArgument "--path" $subcommandIndex)) {
        $targetAction = "create"
        $workDirectory = Get-SubcommandOption "--work-dir" $subcommandIndex
        if ($null -ne $workDirectory) { $workspaceManifestOverride = Join-Path $workDirectory "Cargo.toml" }
    }
} elseif ($subcommand -eq "install") {
    $installPath = Get-SubcommandOption "--path" $subcommandIndex
    if ($null -ne $installPath) {
        $targetAction = "create"
        $workspaceManifestOverride = Join-Path $installPath "Cargo.toml"
    }
} elseif ($subcommand -eq "miri") {
    if (@("bench", "nextest", "run", "test") -contains (Get-NestedSubcommand $subcommandIndex)) {
        $targetAction = "create"
    }
} elseif ($subcommand -eq "mommy") {
    $nested = Get-NestedSubcommand $subcommandIndex
    if ($nested -eq "clean") {
        $targetAction = "clean"
    } elseif ($createCommands -contains $nested) {
        $targetAction = "create"
    }
} elseif ($subcommand -match '^l(l)?(bench|build|check|clippy|doc|fix|run|rustc|rustdoc|test)$') {
    $targetAction = "create"
}

if ($subcommand -eq "expand" -and (Test-SubcommandArgument "--themes" $subcommandIndex)) {
    $targetAction = "none"
}

$helpOrVersion = $false
foreach ($argument in $CargoArguments) {
    if ($argument -eq "--") { break }
    if ($argument -in @("-h", "--help", "-V", "--version")) { $helpOrVersion = $true; break }
}
if ($targetAction -eq "none" -or $helpOrVersion) {
    Invoke-RealCargo $realCargo $CargoArguments
}

$probeMetadataArguments = [Collections.Generic.List[string]]::new()
foreach ($argument in $metadataArguments) { $probeMetadataArguments.Add($argument) }
if ($null -ne $workspaceManifestOverride) {
    $probeMetadataArguments.Add("--manifest-path")
    $probeMetadataArguments.Add($workspaceManifestOverride)
}

$locateArguments = @($toolchainArguments) + @($cargoPrefixArguments) + @("locate-project", "--workspace", "--message-format", "plain") + @($probeMetadataArguments)
$manifestOutput = & $realCargo @locateArguments 2>$null
if ($LASTEXITCODE -ne 0) { Invoke-RealCargo $realCargo $CargoArguments }
$manifestPath = (($manifestOutput | Out-String).Trim())
if ([string]::IsNullOrWhiteSpace($manifestPath)) { Invoke-RealCargo $realCargo $CargoArguments }

$defaultCacheHome = Join-Path $HOME ".cache"
$cacheHome = $defaultCacheHome
if (-not [string]::IsNullOrWhiteSpace($env:XDG_CACHE_HOME)) {
    $cacheHome = Expand-HomePath $env:XDG_CACHE_HOME
}
$cacheRoot = Join-Path $cacheHome "cargo-targets"
$defaultCacheRoot = Join-Path $defaultCacheHome "cargo-targets"
$candidateTarget = Join-Path (Split-Path -Parent $manifestPath) "target"
$managedTarget = Get-ManagedTarget $candidateTarget @($cacheRoot, $defaultCacheRoot)
$candidateItem = Get-Item -LiteralPath $candidateTarget -Force -ErrorAction SilentlyContinue

if ($targetAction -eq "clean" -and $null -eq $candidateItem) {
    Invoke-RealCargo $realCargo $CargoArguments
}
if ($targetAction -ne "clean" -and $null -ne $candidateItem -and $null -eq $managedTarget) {
    Invoke-RealCargo $realCargo $CargoArguments
}

$cargoMetadataArguments = @($toolchainArguments) + @($cargoPrefixArguments) + @("metadata", "--no-deps", "--format-version", "1") + @($probeMetadataArguments)
$metadataOutput = & $realCargo @cargoMetadataArguments 2>$null
if ($LASTEXITCODE -ne 0) { Invoke-RealCargo $realCargo $CargoArguments }
try {
    $metadata = ($metadataOutput | Out-String) | ConvertFrom-Json
    $workspaceRoot = [string] $metadata.workspace_root
    $targetDirectory = [string] $metadata.target_directory
} catch {
    Invoke-RealCargo $realCargo $CargoArguments
}
if ([string]::IsNullOrWhiteSpace($workspaceRoot) -or [string]::IsNullOrWhiteSpace($targetDirectory)) {
    Invoke-RealCargo $realCargo $CargoArguments
}

$defaultTarget = Join-Path $workspaceRoot "target"
if (-not (Paths-Equal $targetDirectory $defaultTarget)) {
    Invoke-RealCargo $realCargo $CargoArguments
}

# Double literal dashes before flattening drive/path separators.
$workspaceCacheKey = $workspaceRoot.Replace("-", "--") -replace '[:\\/]', '-'
$cacheTarget = Join-Path $cacheRoot $workspaceCacheKey

if ($null -ne $managedTarget) {
    $cacheTarget = $managedTarget
    if ($targetAction -ne "clean") {
        New-Item -ItemType Directory -Path $cacheTarget -Force | Out-Null
        Invoke-RealCargo $realCargo $CargoArguments
    }
}

if ($targetAction -eq "clean") {
    if ($null -eq $managedTarget) { Invoke-RealCargo $realCargo $CargoArguments }
    $oldTargetDirectory = $env:CARGO_TARGET_DIR
    $hadTargetDirectory = Test-Path Env:CARGO_TARGET_DIR
    try {
        $env:CARGO_TARGET_DIR = $cacheTarget
        & $realCargo @CargoArguments
        $cleanStatus = $LASTEXITCODE
    } finally {
        if ($hadTargetDirectory) { $env:CARGO_TARGET_DIR = $oldTargetDirectory } else { Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue }
    }
    if (-not (Test-SubcommandArgument "--dry-run" $subcommandIndex) -and -not (Test-Path -LiteralPath $cacheTarget)) {
        if ($null -ne (Get-ReparseTarget $defaultTarget)) { Remove-DirectoryLink $defaultTarget }
    }
    exit $cleanStatus
}

New-Item -ItemType Directory -Path $cacheTarget -Force | Out-Null
try {
    New-Item -ItemType Junction -Path $defaultTarget -Target $cacheTarget -ErrorAction Stop | Out-Null
} catch {
    if ($null -eq (Get-Item -LiteralPath $defaultTarget -Force -ErrorAction SilentlyContinue)) {
        Write-Error "cargo wrapper: could not create target junction at $defaultTarget"
        exit 1
    }
}

Invoke-RealCargo $realCargo $CargoArguments
