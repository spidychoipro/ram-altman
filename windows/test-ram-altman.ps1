#requires -Version 5.1
<#
    Windows test suite for the PowerShell, batch and exe editions.

    Uses simulated memory (RAM_ALTMAN_FAKE_MEMORY), a throwaway state directory
    and a file outbox, so no mail is sent and the real user profile is left
    alone. Run from the repo root:

        pwsh -File windows\test-ram-altman.ps1 -ExePath dist\ram-altman.exe

    Add -SkipExe to test only the script editions.
#>
[CmdletBinding()]
param(
    [string]$ExePath = '',
    [switch]$SkipExe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$psScript = Join-Path $repoRoot 'ram-altman.ps1'
$batScript = Join-Path $repoRoot 'ram-altman.bat'
$pwshPath = (Get-Process -Id $PID).Path

if (-not $ExePath) {
    $ExePath = Join-Path $repoRoot 'dist\ram-altman.exe'
}
if (-not (Test-Path -LiteralPath $ExePath)) {
    if (-not $SkipExe) {
        throw "exe not found at $ExePath; build it first or pass -SkipExe"
    }
    $ExePath = ''
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('ram-altman-tests-' + [Guid]::NewGuid().ToString('N'))
$state = Join-Path $work 'state'
$outbox = Join-Path $work 'outbox.eml'
$config = Join-Path $work 'config.ini'

New-Item -ItemType Directory -Force -Path $work | Out-Null

$script:Pass = 0
$script:Fail = 0
$script:Failures = @()

$envNames = @(
    'RAM_ALTMAN_CONFIG', 'RAM_ALTMAN_STATE_DIR', 'RAM_ALTMAN_TO', 'RAM_ALTMAN_FROM',
    'RAM_ALTMAN_FROM_NAME', 'RAM_ALTMAN_THRESHOLD', 'RAM_ALTMAN_FAKE_MEMORY',
    'RAM_ALTMAN_OUTBOX', 'RAM_ALTMAN_SENDMAIL', 'RAM_ALTMAN_SMTP_HOST',
    'RAM_ALTMAN_SMTP_PORT', 'RAM_ALTMAN_SMTP_USER', 'RAM_ALTMAN_SMTP_PASSWORD',
    'RAM_ALTMAN_SMTP_TLS', 'RAM_ALTMAN_TEST_SENDMAIL_OUT'
)

function Check {
    param([string]$Name, [object]$Actual, [object]$Expected)
    if ("$Actual" -eq "$Expected") {
        $script:Pass++
        Write-Output "ok    $Name"
    }
    else {
        $script:Fail++
        $script:Failures += $Name
        Write-Output "FAIL  $Name (expected '$Expected', got '$Actual')"
    }
}

function Check-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:Pass++
        Write-Output "ok    $Name"
    }
    else {
        $script:Fail++
        $script:Failures += $Name
        $suffix = if ($Detail) { " ($Detail)" } else { '' }
        Write-Output "FAIL  $Name$suffix"
    }
}

function Clear-TestEnvironment {
    foreach ($name in $envNames) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

function Invoke-Tool {
    param(
        [ValidateSet('ps', 'bat', 'exe')]
        [string]$Kind,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{}
    )

    Clear-TestEnvironment
    foreach ($key in $Environment.Keys) {
        Set-Item -LiteralPath "Env:$key" -Value ([string]$Environment[$key])
    }

    $global:LASTEXITCODE = 0
    switch ($Kind) {
        'ps' {
            $output = & $pwshPath -NoProfile -ExecutionPolicy Bypass -File $psScript @Arguments 2>&1
        }
        'exe' {
            $output = & $ExePath @Arguments 2>&1
        }
        'bat' {
            $argString = '"' + $batScript + '"'
            if ($Arguments.Count -gt 0) { $argString += ' ' + ($Arguments -join ' ') }
            $output = & $env:ComSpec /d /c $argString 2>&1
        }
    }
    $code = $LASTEXITCODE
    Clear-TestEnvironment

    return [pscustomobject]@{
        Output   = (($output | ForEach-Object { "$_" }) -join "`n")
        ExitCode = $code
    }
}

function Reset-State {
    Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outbox -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $config -Force -ErrorAction SilentlyContinue
}

function BaseEnvironment {
    param([string]$Memory = '16000000,9000000,100000')
    return @{
        RAM_ALTMAN_CONFIG      = $config
        RAM_ALTMAN_STATE_DIR   = $state
        RAM_ALTMAN_TO          = 'sam@example.com'
        RAM_ALTMAN_FROM        = 'pc@example.com'
        RAM_ALTMAN_FAKE_MEMORY = $Memory
        RAM_ALTMAN_OUTBOX      = $outbox
    }
}

try {
    # ----- status output ------------------------------------------------------
    foreach ($kind in @('ps', 'bat', 'exe')) {
        if ($kind -eq 'exe' -and -not $ExePath) { continue }
        Reset-State
        $result = Invoke-Tool -Kind $kind -Arguments @('--status') -Environment (BaseEnvironment)
        Check-True "$kind status exits 0" ($result.ExitCode -eq 0) "exit $($result.ExitCode)"
        Check-True "$kind status total" ($result.Output -match 'Total:\s+15\.3 GiB') $result.Output
        Check-True "$kind status available" ($result.Output -match 'Available:\s+8\.6 GiB \(56\.2%\)') $result.Output
        Check-True "$kind status free" ($result.Output -match 'Free:\s+0\.1 GiB') $result.Output
        Check-True "$kind status cache" ($result.Output -match 'Cache:\s+8\.5 GiB') $result.Output
        Check-True "$kind status does not write state" (-not (Test-Path -LiteralPath $state)) 'state dir was created'
    }

    # ----- report -------------------------------------------------------------
    foreach ($kind in @('ps', 'bat', 'exe')) {
        if ($kind -eq 'exe' -and -not $ExePath) { continue }
        Reset-State
        $report = Invoke-Tool -Kind $kind -Arguments @('--report') -Environment (BaseEnvironment)
        Check "$kind report exits 0" $report.ExitCode 0
        Check-True "$kind report has a title" ($report.Output -match 'Ram Altman - Windows Division') $report.Output
        Check-True "$kind report has a machine" ($report.Output -match 'Machine:\s+\S') $report.Output
        Check-True "$kind report has commit" ($report.Output -match 'Commit:\s+') $report.Output
        Check-True "$kind report has uptime" ($report.Output -match 'Uptime:\s+') $report.Output
        Check-True "$kind report has processes" ($report.Output -match 'Top processes by working set:') $report.Output
        Check-True "$kind report has a verdict" ($report.Output -match 'Verdict:\s+') $report.Output
        Check-True "$kind report writes no state" (-not (Test-Path -LiteralPath $state)) 'state dir was created'
    }

    # ----- version / help -----------------------------------------------------
    foreach ($kind in @('ps', 'bat', 'exe')) {
        if ($kind -eq 'exe' -and -not $ExePath) { continue }
        $version = Invoke-Tool -Kind $kind -Arguments @('--version')
        Check "$kind version" ($version.Output.Trim()) 'ram-altman 1.2.0'
        $help = Invoke-Tool -Kind $kind -Arguments @('--help')
        Check "$kind help exits 0" $help.ExitCode 0
        Check-True "$kind help mentions --dry-run" ($help.Output -match '--dry-run') $help.Output
    }

    # ----- dry run ------------------------------------------------------------
    Reset-State
    $dryState = Join-Path $work 'dry-state'
    $dryOutbox = Join-Path $work 'dry-outbox.eml'
    $dryEnv = @{
        RAM_ALTMAN_CONFIG      = $config
        RAM_ALTMAN_STATE_DIR   = $dryState
        RAM_ALTMAN_FAKE_MEMORY = '16000000,9000000,100000'
        RAM_ALTMAN_OUTBOX      = $dryOutbox
    }
    foreach ($kind in @('ps', 'bat', 'exe')) {
        if ($kind -eq 'exe' -and -not $ExePath) { continue }
        $dry = Invoke-Tool -Kind $kind -Arguments @('--dry-run') -Environment $dryEnv
        Check "$kind dry run exits 0" $dry.ExitCode 0
        Check-True "$kind dry run prints a subject" ($dry.Output -match '(?m)^Subject: .+') $dry.Output
        Check-True "$kind dry run prints the greeting" ($dry.Output -match 'Hi Sam,') $dry.Output
        Check-True "$kind dry run shows sender placeholder" ($dry.Output -match '(?m)^From: sender-not-set@example\.com$') $dry.Output
        Check-True "$kind dry run shows recipient placeholder" ($dry.Output -match '(?m)^To: recipient-not-set@example\.com$') $dry.Output
        Check-True "$kind dry run writes no state" (-not (Test-Path -LiteralPath $dryState)) 'dry run created state'
        Check-True "$kind dry run sends nothing" (-not (Test-Path -LiteralPath $dryOutbox)) 'dry run wrote outbox'
    }

    # ----- daily limit and CSV, for each edition ------------------------------
    foreach ($kind in @('ps', 'bat', 'exe')) {
        if ($kind -eq 'exe' -and -not $ExePath) { continue }
        Reset-State
        $first = Invoke-Tool -Kind $kind -Environment (BaseEnvironment)
        Check "$kind first run exits 0" $first.ExitCode 0
        Check-True "$kind first run writes outbox" (Test-Path -LiteralPath $outbox) $first.Output
        Check-True "$kind first run records today" ((Test-Path -LiteralPath (Join-Path $state 'last_sent')) -and ((Get-Content -LiteralPath (Join-Path $state 'last_sent')).Trim() -eq (Get-Date -Format 'yyyy-MM-dd'))) 'last_sent missing'

        $before = (Get-Item -LiteralPath $outbox).LastWriteTimeUtc
        Start-Sleep -Milliseconds 1100
        $second = Invoke-Tool -Kind $kind -Environment (BaseEnvironment)
        Check "$kind second run exits 0" $second.ExitCode 0
        Check-True "$kind second run same day sends nothing" ((Get-Item -LiteralPath $outbox).LastWriteTimeUtc -eq $before) 'outbox was rewritten'

        $logPath = Join-Path $state 'usage.csv'
        $lines = @(Get-Content -LiteralPath $logPath)
        Check "$kind CSV header" $lines[0] 'timestamp,total_kb,used_kb,available_kb,available_pct'
        Check "$kind CSV row count" ($lines.Count - 1) 2
        $fields = $lines[1].Split(',')
        Check "$kind CSV total" $fields[1] '16000000'
        Check "$kind CSV used" $fields[2] '7000000'
        Check "$kind CSV available" $fields[3] '9000000'
        Check "$kind CSV percent" $fields[4] '56.2'

        # ----- threshold boundary --------------------------------------------
        Remove-Item -LiteralPath (Join-Path $state 'last_sent') -Force
        $sendmailOut = Join-Path $work 'sendmail-out.eml'
        Remove-Item -LiteralPath $sendmailOut -Force -ErrorAction SilentlyContinue
        $fakeSendmail = Join-Path $work 'fake-sendmail.cmd'
        Set-Content -LiteralPath $fakeSendmail -Value @(
            '@echo off',
            'more > "%RAM_ALTMAN_TEST_SENDMAIL_OUT%"'
        ) -Encoding ASCII
        $sendmailEnv = BaseEnvironment -Memory '16000000,1600000,100000'
        $sendmailEnv.Remove('RAM_ALTMAN_OUTBOX')
        $sendmailEnv['RAM_ALTMAN_SENDMAIL'] = $fakeSendmail
        $sendmailEnv['RAM_ALTMAN_TEST_SENDMAIL_OUT'] = $sendmailOut

        $exact = Invoke-Tool -Kind $kind -Environment $sendmailEnv
        Check "$kind exactly 10% exits 0" $exact.ExitCode 0
        Check-True "$kind exactly 10% sends nothing" (-not (Test-Path -LiteralPath $sendmailOut)) $exact.Output

        $sendmailEnv['RAM_ALTMAN_FAKE_MEMORY'] = '16000000,1700000,100000'
        $over = Invoke-Tool -Kind $kind -Environment $sendmailEnv
        Check "$kind over 10% exits 0" $over.ExitCode 0
        Check-True "$kind over 10% sends mail" (Test-Path -LiteralPath $sendmailOut) $over.Output
        Check-True "$kind sendmail got the message" ((Get-Content -LiteralPath $sendmailOut -Raw) -match 'Hi Sam,') 'sendmail output empty'

        # ----- failed send is not recorded -----------------------------------
        Remove-Item -LiteralPath (Join-Path $state 'last_sent') -Force -ErrorAction SilentlyContinue
        $failEnv = BaseEnvironment
        $failEnv['RAM_ALTMAN_OUTBOX'] = $work
        $failed = Invoke-Tool -Kind $kind -Environment $failEnv
        Check-True "$kind failed send exits non-zero" ($failed.ExitCode -ne 0) "exit $($failed.ExitCode)"
        Check-True "$kind failed send is not recorded" (-not (Test-Path -LiteralPath (Join-Path $state 'last_sent'))) 'last_sent was written'

        # ----- missing recipient ---------------------------------------------
        Reset-State
        $noTo = BaseEnvironment
        $noTo['RAM_ALTMAN_TO'] = ''
        $missing = Invoke-Tool -Kind $kind -Environment $noTo
        Check-True "$kind missing recipient refused" ($missing.ExitCode -ne 0) "exit $($missing.ExitCode)"
    }

    # ----- config file and environment precedence -----------------------------
    Reset-State
    Set-Content -LiteralPath $config -Value @(
        '# test config',
        'to = "sam@example.com"',
        'from = pc@example.com',
        'fromName = Test PC',
        'threshold = 10'
    ) -Encoding ASCII
    $configEnv = @{
        RAM_ALTMAN_CONFIG      = $config
        RAM_ALTMAN_STATE_DIR   = $state
        RAM_ALTMAN_FAKE_MEMORY = '16000000,9000000,100000'
        RAM_ALTMAN_OUTBOX      = $outbox
    }
    foreach ($kind in @('ps', 'bat', 'exe')) {
        if ($kind -eq 'exe' -and -not $ExePath) { continue }
        Remove-Item -LiteralPath $outbox -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $state 'last_sent') -Force -ErrorAction SilentlyContinue
        $configRun = Invoke-Tool -Kind $kind -Environment $configEnv
        Check "$kind config file supplies recipient" $configRun.ExitCode 0
        Check-True "$kind config file loads" (Test-Path -LiteralPath $outbox) $configRun.Output
        $configText = Get-Content -LiteralPath $outbox -Raw
        Check-True "$kind config file supplies sender" ($configText -match 'From: Test PC <pc@example.com>') $configText
        Check-True "$kind config file supplies recipient header" ($configText -match 'To: sam@example.com') $configText
    }

    # ----- rotation -----------------------------------------------------------
    Reset-State
    $rotationEnv = BaseEnvironment
    $subjects = @()
    $bodies = @()
    for ($i = 0; $i -lt 40; $i++) {
        Remove-Item -LiteralPath (Join-Path $state 'last_sent') -Force -ErrorAction SilentlyContinue
        $null = Invoke-Tool -Kind 'ps' -Environment $rotationEnv
        $text = Get-Content -LiteralPath $outbox -Raw
        $subjects += [regex]::Match($text, '(?m)^Subject: (.*)\r?$').Groups[1].Value
        $bodies += [regex]::Match($text, "Hi Sam,\r?\n\r?\n(.*?)\r?\n").Groups[1].Value
    }
    Check 'rotation uses all 8 subjects' (@($subjects | Sort-Object -Unique).Count) 8
    Check 'rotation uses all 10 bodies' (@($bodies | Sort-Object -Unique).Count) 10
    $repeats = 0
    for ($i = 1; $i -lt $bodies.Count; $i++) {
        if ($bodies[$i] -eq $bodies[$i - 1]) { $repeats++ }
    }
    Check 'rotation never repeats back to back' $repeats 0

    # ----- batch rotation, lighter -------------------------------------------
    Reset-State
    $batchSubjects = @()
    for ($i = 0; $i -lt 10; $i++) {
        Remove-Item -LiteralPath (Join-Path $state 'last_sent') -Force -ErrorAction SilentlyContinue
        $null = Invoke-Tool -Kind 'bat' -Environment $rotationEnv
        $text = Get-Content -LiteralPath $outbox -Raw
        $batchSubjects += [regex]::Match($text, '(?m)^Subject: (.*)\r?$').Groups[1].Value
    }
    Check-True 'batch rotation spreads subjects' (@($batchSubjects | Sort-Object -Unique).Count -ge 6) ($batchSubjects -join ' | ')
    $batchRepeats = 0
    for ($i = 1; $i -lt $batchSubjects.Count; $i++) {
        if ($batchSubjects[$i] -eq $batchSubjects[$i - 1]) { $batchRepeats++ }
    }
    Check 'batch rotation never repeats back to back' $batchRepeats 0

    # ----- real machine status (informational) -------------------------------
    Clear-TestEnvironment
    Write-Output ''
    Write-Output '--- real machine status ---'
    & $pwshPath -NoProfile -ExecutionPolicy Bypass -File $psScript --status
}
finally {
    Clear-TestEnvironment
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output "$script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) {
    Write-Output ('failed: ' + ($script:Failures -join '; '))
    exit 1
}
exit 0
