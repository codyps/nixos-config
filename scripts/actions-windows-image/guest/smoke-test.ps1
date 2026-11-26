param([switch]$WriteInventory, [switch]$Canary)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Invoke-Checked([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File failed ($LASTEXITCODE)" }
}
if ($env:USERNAME -ne 'runner') { throw 'Smoke tests must run as the runtime runner account' }
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$packages = Get-Content C:\ProgramData\ActionsVm\packages.json -Raw | ConvertFrom-Json
if ($PSVersionTable.PSVersion.Major -ge 6) { Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue }
$winget = Join-Path (Get-AppxPackage Microsoft.DesktopAppInstaller).InstallLocation 'winget.exe'
# Test the execution alias as well as AppX registration: workflow commands use PATH.
Invoke-Checked winget @('--info')
Invoke-Checked $winget @('search', '--id', 'GitHub.cli', '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
if ($Canary) {
    $jq = $packages.winget_packages | Where-Object id -eq 'jqlang.jq'
    Invoke-Checked $winget @('install', '--id', $jq.id, '--version', $jq.version, '--exact', '--source', 'winget', '--scope', 'machine', '--force', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
}
$versions = [ordered]@{}
foreach ($command in @('git', 'gh', 'choco', 'jq', 'rg', 'cmake', 'ninja', 'clang', 'node', 'npm.cmd', 'python', 'uv', 'rustup', 'rustc', 'cargo', 'dotnet', 'pwsh', 'winget')) {
    $versions[$command] = (Invoke-Checked $command @('--version') | Out-String).Trim()
}
$versions['git-lfs'] = (Invoke-Checked git @('lfs', 'version') | Out-String).Trim()
$versions['7zip'] = (Invoke-Checked 7z @('i') | Out-String).Trim()
Invoke-Checked bash @('--noprofile', '--norc', '-c', 'test -n "$BASH_VERSION" && command -v git && command -v tar')
Invoke-Checked python @('-m', 'pip', '--version')
Invoke-Checked rustup @('component', 'list', '--installed')
Invoke-Checked cargo @('fmt', '--version')
Invoke-Checked cargo @('clippy', '--version')
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $vs) { throw 'C++ toolchain is missing' }
$versions['visual-studio'] = (Invoke-Checked $vswhere @('-latest', '-products', '*', '-format', 'json') | Out-String | ConvertFrom-Json).catalog.productDisplayVersion
# Import a developer environment only for native build tests, not globally.
$environment = & cmd.exe /d /s /c "`"`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul && set`""
if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize the MSVC environment' }
foreach ($line in $environment) {
    if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process') }
}
$temporary = Join-Path $env:TEMP ('actions-image-smoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
Push-Location $temporary
try {
    @'
cmake_minimum_required(VERSION 3.20)
project(runner_smoke LANGUAGES C CXX)
enable_testing()
add_executable(smoke_c main.c)
add_executable(smoke_cpp main.cpp)
add_test(NAME c COMMAND smoke_c)
add_test(NAME cpp COMMAND smoke_cpp)
'@ | Set-Content CMakeLists.txt -Encoding ascii
    'int main(void) { return 0; }' | Set-Content main.c -Encoding ascii
    '#include <iostream>' + "`n" + 'int main() { std::cout << "ok"; }' | Set-Content main.cpp -Encoding ascii
    Invoke-Checked cmake @('-S', '.', '-B', 'build', '-G', 'Ninja', '-DCMAKE_C_COMPILER=cl', '-DCMAKE_CXX_COMPILER=cl')
    Invoke-Checked cmake @('--build', 'build')
    Invoke-Checked ctest @('--test-dir', 'build', '--output-on-failure')
    Invoke-Checked clang @('main.c', '-o', 'clang-smoke.exe')
    Invoke-Checked .\clang-smoke.exe @()
    Invoke-Checked cargo @('new', '--bin', '--vcs', 'none', 'rust-smoke')
    Push-Location rust-smoke
    try {
        Invoke-Checked cargo @('build', '--offline')
        Invoke-Checked cargo @('clippy', '--offline', '--', '-D', 'warnings')
        Invoke-Checked .\target\debug\rust-smoke.exe @()
        # Match workflows that locate the real MinGW bin directory rather than
        # WinGet's portable command links (the assembler needs companion DLLs).
        $mingw = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter dlltool.exe |
            Where-Object { $_.DirectoryName -like '*\mingw64\bin' } | Select-Object -First 1 -ExpandProperty DirectoryName
        if (-not $mingw) { throw 'WinLibs MinGW bin directory is missing' }
        $savedPath = $env:Path
        try {
            $env:Path = "$mingw;$env:Path"
            $versions['gcc'] = (Invoke-Checked gcc @('--version') | Out-String).Trim()
            Invoke-Checked dlltool @('--version')
            Invoke-Checked gcc @('..\main.c', '-o', 'gcc-smoke.exe')
            Invoke-Checked .\gcc-smoke.exe @()
            Invoke-Checked cargo @("+$($packages.rust_gnu_toolchain)", 'build', '--offline', '--target-dir', 'target-gnu')
            Invoke-Checked .\target-gnu\debug\rust-smoke.exe @()
        } finally { $env:Path = $savedPath }
    } finally { Pop-Location }
    Invoke-Checked python @('-m', 'venv', 'python-smoke')
    Invoke-Checked .\python-smoke\Scripts\python.exe @('-c', 'import ssl, sqlite3, sys; assert sys.prefix != sys.base_prefix')
    Invoke-Checked uv @('venv', '--python', 'python', 'uv-smoke')
    Invoke-Checked node @('-e', 'const assert = require("node:assert"); assert.equal(2 + 2, 4)')
    Invoke-Checked npm.cmd @('init', '--yes')
    Invoke-Checked dotnet @('new', 'console', '--output', 'dotnet-smoke', '--no-restore')
    Invoke-Checked dotnet @('restore', 'dotnet-smoke', '--ignore-failed-sources')
    Invoke-Checked dotnet @('run', '--project', 'dotnet-smoke', '--no-restore')
    Invoke-Checked 7z @('a', 'smoke.7z', 'main.c')
    Invoke-Checked 7z @('t', 'smoke.7z')
} finally {
    Pop-Location
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
if ($WriteInventory) {
    $os = Get-CimInstance Win32_OperatingSystem
    $inventory = [ordered]@{
        image_version = $packages.image_version
        built_at_utc = [DateTime]::UtcNow.ToString('o')
        windows = @{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber }
        manifest = $packages
        versions = $versions
        validation = 'post-reboot noninteractive runner account; native, Rust, Python, Node, .NET builds'
    }
    $inventory | ConvertTo-Json -Depth 12 | Set-Content C:\ProgramData\ActionsVm\software-inventory.json -Encoding utf8
}
Write-Host 'Windows builder smoke tests passed'
