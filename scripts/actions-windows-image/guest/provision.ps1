param([switch]$Finalize)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = 'C:\ProgramData\ActionsImage'
$reboot = $false
$receipt = @{ success = $false; stage = 'starting' }
function Invoke-Checked([string]$File, [string[]]$Arguments, [int[]]$SuccessCodes = @(0)) {
    & $File @Arguments
    if ($LASTEXITCODE -notin $SuccessCodes) { throw "$File failed ($LASTEXITCODE)" }
}
function Install-Program([string]$File, [string]$Arguments) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "Installer failed: $([IO.Path]::GetFileName($File)) ($($process.ExitCode))" }
}
if (-not $Finalize) {
    $seed = Get-Volume | Where-Object FileSystemLabel -eq 'IMAGE_BUILD' | Select-Object -First 1
    if (-not $seed.DriveLetter) { throw 'Missing image build seed' }
    $source = "$($seed.DriveLetter):\"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Invoke-Checked icacls.exe @($root, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
    foreach ($name in @('build.json', 'packages.json', 'provision.ps1', 'smoke-test.ps1')) {
        Copy-Item -LiteralPath (Join-Path $source $name) $root -Force
    }
}
$meta = Get-Content -LiteralPath "$root\build.json" -Raw | ConvertFrom-Json
$packages = Get-Content -LiteralPath "$root\packages.json" -Raw | ConvertFrom-Json
Start-Transcript -Path C:\Windows\Temp\actions-image-provision.log -Append | Out-Null
try {
    if ($env:USERNAME -ne 'runner') { throw 'Image preparation must run as runner' }
    if (-not $Finalize) {
        Invoke-Checked powercfg.exe @('/hibernate', 'off')
        Invoke-Checked powercfg.exe @('/change', 'standby-timeout-ac', '0')
        Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem LongPathsEnabled 1
        # Updates are applied deliberately during image maintenance, never mid-job.
        New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU -Force | Out-Null
        New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU -Name NoAutoUpdate -Value 1 -PropertyType DWord -Force | Out-Null
        $receipt.stage = 'git'
        Install-Program (Join-Path $source 'git.exe') '/VERYSILENT /NORESTART /SP- /ALLUSERS'
        $receipt.stage = 'powershell'
        Install-Program msiexec.exe "/i `"$(Join-Path $source 'powershell.msi')`" /qn /norestart"
        $receipt.stage = 'winget'
        $dependencies = Join-Path $env:TEMP 'winget-dependencies'
        Expand-Archive -LiteralPath (Join-Path $source 'winget-dependencies.zip') -DestinationPath $dependencies -Force
        # The official release contains separate architecture directories.
        $appx = @(Get-ChildItem "$dependencies\x64" -Recurse -File | Where-Object Extension -in @('.appx', '.msix'))
        if (-not $appx.Count) { throw 'Missing x64 WinGet dependencies' }
        Add-AppxPackage -Path (Join-Path $source 'winget.msixbundle') -DependencyPath $appx.FullName -ForceApplicationShutdown
        $winget = Join-Path (Get-AppxPackage Microsoft.DesktopAppInstaller).InstallLocation 'winget.exe'
        Invoke-Checked $winget @('--info')
        Invoke-Checked $winget @('source', 'update', '--name', 'winget', '--disable-interactivity')
        $receipt.stage = 'build-tools'
        $tools = Join-Path $env:TEMP 'vs-buildtools.exe'
        Invoke-WebRequest -Uri $packages.visual_studio.bootstrapper -OutFile $tools
        $signature = Get-AuthenticodeSignature -LiteralPath $tools
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            throw 'Build Tools installer signature did not verify as Microsoft'
        }
        $components = ($packages.visual_studio.components | ForEach-Object { "--add $_" }) -join ' '
        Install-Program $tools "--quiet --wait --norestart --nocache --installPath C:\BuildTools $components"
        Remove-Item -LiteralPath $tools -Force
        # Pin the Rust toolchain independently of the rustup installer. Avoid
        # downloading a moving stable toolchain as part of rustup installation.
        $env:RUSTUP_INIT_SKIP_PATH_CHECK = 'yes'
        foreach ($package in $packages.winget_packages) {
            # Installers update the registry PATH, not this existing shell.
            # Git LFS in particular needs the Git installed earlier in this run.
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
            $receipt.stage = $package.id
            $arguments = @('install', '--id', $package.id, '--exact', '--version', $package.version,
                '--source', 'winget', '--silent', '--disable-interactivity',
                '--accept-source-agreements', '--accept-package-agreements')
            # Some upstream manifests omit Scope even though the installer has
            # fixed behavior. A strict --scope filter rejects those installers.
            if ($package.scope_filter -ne $false) { $arguments += @('--scope', $package.scope) }
            if ($package.custom) { $arguments += @('--custom', $package.custom) }
            if ($package.architecture) { $arguments += @('--architecture', $package.architecture) }
            else { $arguments += @('--architecture', 'x64') }
            if ($package.installer_type) { $arguments += @('--installer-type', $package.installer_type) }
            if ($package.id -eq 'Rustlang.Rustup') {
                $arguments += @('--override', '-y --default-host x86_64-pc-windows-msvc --default-toolchain none --profile minimal --no-modify-path')
            }
            Invoke-Checked $winget $arguments @(0, 3010)
        }
        $receipt.stage = 'rust-toolchain'
        $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
        Invoke-Checked "$cargoBin\rustup.exe" @('toolchain', 'install', $packages.rust_toolchain, '--profile', 'minimal', '--component', 'rustfmt', '--component', 'clippy')
        Invoke-Checked "$cargoBin\rustup.exe" @('toolchain', 'install', $packages.rust_gnu_toolchain, '--profile', 'minimal')
        Invoke-Checked "$cargoBin\rustup.exe" @('default', $packages.rust_toolchain)
        [Environment]::SetEnvironmentVariable('Path', "$cargoBin;" + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')
        $receipt.stage = 'runner'
        New-Item -ItemType Directory -Path C:\actions-runner -Force | Out-Null
        Expand-Archive -LiteralPath (Join-Path $source 'runner.zip') -DestinationPath C:\actions-runner
        if (-not (Test-Path C:\actions-runner\bin\Runner.Listener.exe)) { throw 'Runner extraction failed' }
        New-Item -ItemType Directory -Path C:\ProgramData\ActionsVm -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $source 'windows-bootstrap.ps1') C:\ProgramData\ActionsVm\bootstrap.ps1
        Copy-Item "$root\packages.json" C:\ProgramData\ActionsVm\packages.json
        Copy-Item "$root\smoke-test.ps1" C:\ProgramData\ActionsVm\smoke-test.ps1
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::SetEnvironmentVariable('Path', "C:\Program Files\Git\bin;C:\Program Files\LLVM\bin;C:\Program Files\7-Zip;$machinePath", 'Machine')
        Invoke-Checked icacls.exe @('C:\ProgramData\ActionsVm', '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
        # Remove interactive logon before the deliberate reboot. The random task
        # password is stored by Task Scheduler, never in a file or command line.
        $logon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $logon AutoAdminLogon '0'
        foreach ($name in @('DefaultPassword', 'DefaultUserName', 'AutoLogonCount')) {
            Remove-ItemProperty $logon $name -ErrorAction SilentlyContinue
        }
        $password = [Guid]::NewGuid().ToString() + [Guid]::NewGuid().ToString() + '!9aA'
        Set-LocalUser -Name runner -Password (ConvertTo-SecureString $password -AsPlainText -Force) -PasswordNeverExpires $true
        $user = "$env:COMPUTERNAME\runner"
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 8) -StartWhenAvailable
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $trigger.Delay = 'PT30S'
        $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
        $action = New-ScheduledTaskAction -Execute $pwsh -Argument '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\ProgramData\ActionsVm\bootstrap.ps1'
        Register-ScheduledTask -TaskName ActionsVmRunner -Action $action -Trigger $trigger -User $user -Password $password -RunLevel Highest -Settings $settings -Force | Out-Null
        Disable-ScheduledTask -TaskName ActionsVmRunner | Out-Null
        $action = New-ScheduledTaskAction -Execute $pwsh -Argument '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\ProgramData\ActionsImage\provision.ps1 -Finalize'
        Register-ScheduledTask -TaskName ActionsImageFinalize -Action $action -Trigger $trigger -User $user -Password $password -RunLevel Highest -Settings $settings -Force | Out-Null
        $password = $null
        $receipt.stage = 'rebooting'
        $reboot = $true
    } else {
        $receipt.stage = 'smoke-test'
        # This runs after a real reboot, as the runtime account, without a desktop.
        & "$root\smoke-test.ps1" -WriteInventory
        Invoke-Checked 'C:\Program Files\Git\cmd\git.exe' @('config', '--system', 'core.longpaths', 'true')
        Invoke-Checked 'C:\Program Files\Git\cmd\git.exe' @('lfs', 'install', '--system', '--skip-repo')
        $receipt.stage = 'sealing'
        foreach ($name in @('.runner', '.credentials', '.credentials_rsaparams', '_work')) {
            if (Test-Path "C:\actions-runner\$name") { throw 'Image contains runner registration or job state' }
        }
        Unregister-ScheduledTask -TaskName ActionsImageFinalize -Confirm:$false
        Remove-Item C:\Windows\Panther\unattend.xml,C:\Windows\Panther\Unattend\unattend.xml,C:\Windows\System32\Sysprep\unattend.xml -Force -ErrorAction SilentlyContinue
        Clear-History
        Remove-Item "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt" -Force -ErrorAction SilentlyContinue
        Enable-ScheduledTask -TaskName ActionsVmRunner | Out-Null
        $receipt.success = $true
        $receipt.stage = 'sealed'
    }
} catch {
    $reboot = $false
    $_ | Out-File C:\Windows\Temp\actions-image-error.log
} finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    if ($reboot) {
        Restart-Computer -Force
    } else {
        if ($receipt.success) {
            try {
                if (Test-Path C:\Windows\Temp\actions-image-error.log) { Remove-Item C:\Windows\Temp\actions-image-error.log -Force }
                Remove-Item C:\Windows\Temp\actions-image-provision.log -Force
                Remove-Item $root -Recurse -Force
            } catch {
                $receipt.success = $false
                $receipt.stage = 'cleanup-failed'
                $_ | Out-File C:\Windows\Temp\actions-image-error.log
            }
        }
        try {
            Invoke-RestMethod -Method Post -Uri $meta.receipt_url -ContentType application/json -Body ($receipt | ConvertTo-Json -Compress) | Out-Null
        } finally {
            Stop-Computer -Force
        }
    }
}
