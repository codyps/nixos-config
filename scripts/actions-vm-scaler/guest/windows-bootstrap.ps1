# Runs as SYSTEM inside a disposable guest. No controller credential enters it.
$ErrorActionPreference = 'Stop'
try {
    $seed = $null
    for ($i = 0; $i -lt 120; $i++) {
        $volume = Get-Volume | Where-Object FileSystemLabel -eq 'RUNNER_SEED' | Select-Object -First 1
        if ($volume -and $volume.DriveLetter) {
            $path = "$($volume.DriveLetter):\jitconfig"
            if (Test-Path -LiteralPath $path) { $seed = $path; break }
        }
        Start-Sleep -Seconds 1
    }
    if (-not $seed) { throw 'No runner seed appeared' }
    $env:ACTIONS_RUNNER_INPUT_JITCONFIG = [IO.File]::ReadAllText($seed).Trim()
    if (-not $env:ACTIONS_RUNNER_INPUT_JITCONFIG) { throw 'Empty runner seed' }
    Set-Location C:\actions-runner
    & .\run.cmd
    if ($LASTEXITCODE -ne 0) { throw 'Runner exited unsuccessfully' }
} finally {
    Remove-Item Env:\ACTIONS_RUNNER_INPUT_JITCONFIG -ErrorAction SilentlyContinue
    Stop-Computer -Force
}
