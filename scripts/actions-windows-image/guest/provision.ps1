$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$seed = Get-Volume | Where-Object FileSystemLabel -eq 'IMAGE_BUILD' | Select-Object -First 1
if (-not $seed.DriveLetter) { throw 'Missing image build seed' }
$source = "$($seed.DriveLetter):\"
$meta = Get-Content -LiteralPath (Join-Path $source 'build.json') -Raw | ConvertFrom-Json
$receipt = @{ success = $false; stage = 'starting' }
Start-Transcript -Path C:\Windows\Temp\actions-image-provision.log -Force | Out-Null
function Install-Program([string]$File, [string]$Arguments) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "Installer failed: $([IO.Path]::GetFileName($File)) ($($process.ExitCode))" }
}
try {
    powercfg.exe /hibernate off
    powercfg.exe /change standby-timeout-ac 0
    Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem LongPathsEnabled 1
    # Keep image installation independent of interactive update/reboot prompts.
    New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU -Force | Out-Null
    New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU -Name NoAutoUpdate -Value 1 -PropertyType DWord -Force | Out-Null
    $receipt.stage = 'git'
    Install-Program (Join-Path $source 'git.exe') '/VERYSILENT /NORESTART /SP-'
    $receipt.stage = 'powershell'
    Install-Program msiexec.exe "/i `"$(Join-Path $source 'powershell.msi')`" /qn /norestart"
    $receipt.stage = 'build-tools'
    $tools = Join-Path $env:TEMP 'vs-buildtools.exe'
    Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile $tools
    $signature = Get-AuthenticodeSignature -LiteralPath $tools
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw 'Build Tools installer signature did not verify as Microsoft'
    }
    Install-Program $tools '--quiet --wait --norestart --nocache --installPath C:\BuildTools --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
    Remove-Item -LiteralPath $tools -Force
    $receipt.stage = 'runner'
    New-Item -ItemType Directory -Path C:\actions-runner -Force | Out-Null
    Expand-Archive -LiteralPath (Join-Path $source 'runner.zip') -DestinationPath C:\actions-runner
    if (-not (Test-Path C:\actions-runner\bin\Runner.Listener.exe)) { throw 'Runner extraction failed' }
    New-Item -ItemType Directory -Path C:\ProgramData\ActionsVm -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'windows-bootstrap.ps1') C:\ProgramData\ActionsVm\bootstrap.ps1
    icacls.exe C:\ProgramData\ActionsVm /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    # The startup task is installed disabled: the image builder enables it only
    # immediately before the final shutdown. No GitHub registration is baked in.
    $action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\ProgramData\ActionsVm\bootstrap.ps1'
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 8) -StartWhenAvailable
    Register-ScheduledTask -TaskName ActionsVmRunner -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -User SYSTEM -RunLevel Highest -Settings $settings -Force | Out-Null
    Disable-ScheduledTask -TaskName ActionsVmRunner | Out-Null
    $receipt.stage = 'smoke-test'
    $vs = & 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe' -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw 'C++ toolchain is missing' }
    'int main(void) { return 0; }' | Set-Content C:\Windows\Temp\runner-smoke.c -Encoding ascii
    & cmd.exe /d /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" && cl /nologo C:\Windows\Temp\runner-smoke.c /Fo:C:\Windows\Temp\runner-smoke.obj /Fe:C:\Windows\Temp\runner-smoke.exe && C:\Windows\Temp\runner-smoke.exe"
    if ($LASTEXITCODE -ne 0) { throw 'C++ compiler smoke test failed' }
    & 'C:\Program Files\Git\cmd\git.exe' --version
    if ($LASTEXITCODE -ne 0) { throw 'Git smoke test failed' }
    & 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    if ($LASTEXITCODE -ne 0) { throw 'PowerShell smoke test failed' }
    if (Test-Path C:\actions-runner\.runner) { throw 'Image contains a registered runner' }
    if (Test-Path C:\actions-runner\_work) { throw 'Image contains a job workspace' }
    $receipt.stage = 'sealing'
    & 'C:\Program Files\Git\cmd\git.exe' config --system core.longpaths true
    if ($LASTEXITCODE -ne 0) { throw 'Git long path configuration failed' }
    $logon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $logon AutoAdminLogon '0'
    foreach ($name in @('DefaultPassword', 'DefaultUserName', 'AutoLogonCount')) {
        Remove-ItemProperty $logon $name -ErrorAction SilentlyContinue
    }
    Disable-LocalUser -Name builder
    $password = ConvertTo-SecureString ([Guid]::NewGuid().ToString() + [Guid]::NewGuid().ToString()) -AsPlainText -Force
    Set-LocalUser -Name builder -Password $password
    Remove-Item C:\Windows\Panther\unattend.xml,C:\Windows\Panther\Unattend\unattend.xml,C:\Windows\System32\Sysprep\unattend.xml -Force -ErrorAction SilentlyContinue
    Remove-Item C:\Windows\Temp\runner-smoke.* -Force -ErrorAction SilentlyContinue
    Clear-History
    $history = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
    Remove-Item -LiteralPath $history -Force -ErrorAction SilentlyContinue
    Enable-ScheduledTask -TaskName ActionsVmRunner | Out-Null
    Stop-Transcript | Out-Null
    Remove-Item C:\Windows\Temp\actions-image-provision.log -Force
    $receipt.success = $true
    $receipt.stage = 'sealed'
} catch {
    # Error text may contain download URLs; return only the stage to the host.
    $receipt.success = $false
    $_ | Out-File C:\Windows\Temp\actions-image-error.log
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
} finally {
    try {
        Invoke-RestMethod -Method Post -Uri $meta.receipt_url -ContentType application/json -Body ($receipt | ConvertTo-Json -Compress) | Out-Null
    } finally {
        Stop-Computer -Force
    }
}
