[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [AllowEmptyCollection()]
    [string[]] $GcArguments
)

$ErrorActionPreference = "Stop"

function Show-Usage {
    @"
usage: cargo gc [--delete | --dry-run] [--caches] [--older-than DAYS]
                [--broken-links --root PATH ...] [--cache-root PATH]

Preview removal of wrapper-owned Cargo target caches. Stop builds before --delete.

  --delete          perform the displayed removals
  --dry-run         preview only (the default)
  --caches          select cache directories (default unless --broken-links)
  --older-than DAYS only caches with no modification anywhere in DAYS
  --broken-links    remove target junctions into caches that are/will be absent
  --root PATH       project tree to search; repeatable; links are not followed
  --cache-root PATH override cache root; basename must be cargo-targets
"@
}

function Fail-Usage([string] $Message) {
    [Console]::Error.WriteLine("cargo gc: $Message")
    [Console]::Error.WriteLine("Try 'cargo gc --help' for more information.")
    exit 2
}

function Expand-HomePath([string] $Path) {
    if ($Path -eq "~") { return $HOME }
    if ($Path.StartsWith("~\") -or $Path.StartsWith("~/")) { return Join-Path $HOME $Path.Substring(2) }
    return $Path
}

function Normalize-Path([string] $Path) {
    $full = [IO.Path]::GetFullPath((Expand-HomePath $Path))
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        return $full.TrimEnd([char[]] @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    }
    return $full
}

function Paths-Equal([string] $Left, [string] $Right) {
    return [StringComparer]::OrdinalIgnoreCase.Equals((Normalize-Path $Left), (Normalize-Path $Right))
}

function Get-ReparseTarget([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) { return $null }
    $targets = @($item.Target)
    if ($targets.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string] $targets[0])) { return $null }
    $target = [string] $targets[0]
    if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $Path) $target }
    return Normalize-Path $target
}

function Get-NewestWriteTime([IO.DirectoryInfo] $Directory) {
    $newest = $Directory.LastWriteTimeUtc
    $stack = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $stack.Push($Directory)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $current.FullName -Force -ErrorAction Stop) {
            if ($item.LastWriteTimeUtc -gt $newest) { $newest = $item.LastWriteTimeUtc }
            if ($item.PSIsContainer -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
                $stack.Push([IO.DirectoryInfo] $item)
            }
        }
    }
    return $newest
}

function Remove-DirectoryLink([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
        throw "refusing to remove a path that is not a directory link: $Path"
    }
    [IO.Directory]::Delete($Path, $false)
}

if ($null -eq $GcArguments) { $GcArguments = @() }
if ($GcArguments.Count -gt 0 -and $GcArguments[0] -eq "gc") { $GcArguments = @($GcArguments | Select-Object -Skip 1) }

$delete = $false
$dryRun = $false
$caches = $false
$brokenLinks = $false
$olderThan = $null
$cacheRootArgument = $null
$roots = [Collections.Generic.List[string]]::new()

for ($i = 0; $i -lt $GcArguments.Count; $i++) {
    $argument = $GcArguments[$i]
    switch -Regex ($argument) {
        '^--delete$' { $delete = $true; continue }
        '^--dry-run$' { $dryRun = $true; continue }
        '^--caches$' { $caches = $true; continue }
        '^--broken-links$' { $brokenLinks = $true; continue }
        '^(-h|--help)$' { Show-Usage; exit 0 }
        '^--older-than=(.*)$' { $olderThan = $Matches[1]; continue }
        '^--cache-root=(.*)$' { $cacheRootArgument = $Matches[1]; continue }
        '^--root=(.*)$' { $roots.Add($Matches[1]); continue }
        '^--older-than$' {
            if (++$i -ge $GcArguments.Count) { Fail-Usage "--older-than requires DAYS" }
            $olderThan = $GcArguments[$i]
            continue
        }
        '^--cache-root$' {
            if (++$i -ge $GcArguments.Count) { Fail-Usage "--cache-root requires PATH" }
            $cacheRootArgument = $GcArguments[$i]
            continue
        }
        '^--root$' {
            if (++$i -ge $GcArguments.Count) { Fail-Usage "--root requires PATH" }
            $roots.Add($GcArguments[$i])
            continue
        }
        default { Fail-Usage "unrecognized argument '$argument'" }
    }
}

if ($delete -and $dryRun) { Fail-Usage "--delete and --dry-run are mutually exclusive" }
if ($brokenLinks -and $roots.Count -eq 0) { Fail-Usage "--broken-links requires at least one --root" }
if (-not $brokenLinks -and $roots.Count -gt 0) { Fail-Usage "--root requires --broken-links" }
if ($null -ne $olderThan -and $brokenLinks -and -not $caches) { Fail-Usage "--older-than filters caches; add --caches" }

$olderThanDays = $null
if ($null -ne $olderThan) {
    $parsedDays = 0.0
    if (-not [double]::TryParse($olderThan, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref] $parsedDays) -or
        $parsedDays -lt 0 -or [double]::IsNaN($parsedDays) -or [double]::IsInfinity($parsedDays)) {
        Fail-Usage "--older-than must be a finite nonnegative number"
    }
    $olderThanDays = $parsedDays
}

$defaultCacheHome = Join-Path $HOME ".cache"
$cacheHome = $defaultCacheHome
if (-not [string]::IsNullOrWhiteSpace($env:XDG_CACHE_HOME)) { $cacheHome = Expand-HomePath $env:XDG_CACHE_HOME }
$cacheRoot = if ($null -ne $cacheRootArgument) { Normalize-Path $cacheRootArgument } else { Normalize-Path (Join-Path $cacheHome "cargo-targets") }
if ((Split-Path -Leaf $cacheRoot) -ne "cargo-targets") { Fail-Usage "cache root must be a directory named cargo-targets" }
$cacheRootItem = Get-Item -LiteralPath $cacheRoot -Force -ErrorAction SilentlyContinue
if ($null -ne $cacheRootItem -and (($cacheRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    Fail-Usage "cache root must not be a link or junction"
}

$resolvedRoots = [Collections.Generic.List[string]]::new()
foreach ($root in $roots) {
    $resolved = Normalize-Path $root
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { Fail-Usage "every --root must be an existing directory" }
    $resolvedRoots.Add($resolved)
}

$selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($caches -or -not $brokenLinks) {
    if (Test-Path -LiteralPath $cacheRoot -PathType Container) {
        $cutoff = if ($null -eq $olderThanDays) { [DateTime]::MaxValue } else { [DateTime]::UtcNow.AddDays(-$olderThanDays) }
        foreach ($entry in Get-ChildItem -LiteralPath $cacheRoot -Directory -Force | Sort-Object FullName) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($null -eq $olderThanDays -or (Get-NewestWriteTime $entry) -lt $cutoff) {
                [void] $selected.Add((Normalize-Path $entry.FullName))
            }
        }
    }
}

$verb = if ($delete) { "remove" } else { "would remove" }
foreach ($entry in @($selected) | Sort-Object) {
    Write-Output "$verb cache: $entry"
    if ($delete) {
        $item = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not (Paths-Equal (Split-Path -Parent $entry) $cacheRoot)) {
            throw "cache path changed during collection: $entry"
        }
        Remove-Item -LiteralPath $entry -Recurse -Force
    }
}

if ($brokenLinks) {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $resolvedRoots) {
        $stack = [Collections.Generic.Stack[string]]::new()
        $stack.Push($root)
        while ($stack.Count -gt 0) {
            $parent = $stack.Pop()
            if (Paths-Equal $parent $cacheRoot) { continue }
            $link = Join-Path $parent "target"
            if ($seen.Add((Normalize-Path $link))) {
                $destination = Get-ReparseTarget $link
                if ($null -ne $destination -and (Paths-Equal (Split-Path -Parent $destination) $cacheRoot)) {
                    $destinationExists = Test-Path -LiteralPath $destination -PathType Container
                    if (-not $destinationExists -or $selected.Contains($destination)) {
                        Write-Output "$verb link: $link -> $destination"
                        if ($delete) {
                            $currentDestination = Get-ReparseTarget $link
                            if ($null -eq $currentDestination -or -not (Paths-Equal $currentDestination $destination)) {
                                throw "target link changed during collection: $link"
                            }
                            Remove-DirectoryLink $link
                        }
                    }
                }
            }
            foreach ($directory in Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction Stop) {
                if ($directory.Name -in @(".git", "target")) { continue }
                if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if (Paths-Equal $directory.FullName $cacheRoot) { continue }
                $stack.Push($directory.FullName)
            }
        }
    }
}

if (-not $delete) { Write-Output "Preview only. Use --delete to apply." }
