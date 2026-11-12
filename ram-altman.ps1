#!/usr/bin/env pwsh
#requires -Version 5.1
#
# ram-altman.ps1 - Windows/PowerShell edition.
#
# Tracks RAM usage and, at most once a day, tells Sam Altman when this PC has
# RAM to spare.
#
# Usage:
#   .\ram-altman.ps1                 Log a sample and send the daily email if due
#   .\ram-altman.ps1 --status        Print current memory figures and exit
#   .\ram-altman.ps1 --dry-run       Print the email that would be sent and exit
#   .\ram-altman.ps1 --install-task  Sample every 5 minutes in Task Scheduler
#   .\ram-altman.ps1 --uninstall-task Remove that scheduled task
#
# Settings come from %LOCALAPPDATA%\ram-altman\config.ini (see
# windows\config.example.ini) or from RAM_ALTMAN_* environment variables.
#
# How "used" is worked out on Windows:
#   used = total physical - available physical
#
#   "Available" is GlobalMemoryStatusEx().ullAvailPhys, which is the same figure
#   Task Manager shows as available: free memory plus standby/cached pages that
#   Windows can hand to a new program without paging. The cache figure is
#   GetPerformanceInfo().SystemCache, so free is shown as available minus cache.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppName = 'ram-altman'
$script:Version = '1.1.0'
$script:TaskName = 'Ram Altman'
$script:ScriptPath = $PSCommandPath
$script:StateDir = $null
$script:LockStream = $null

function Write-ErrorLine {
    param([string]$Message)
    [Console]::Error.WriteLine("$($script:AppName): $Message")
}

function Get-ConfigString {
    param(
        [hashtable]$Ini,
        [string]$EnvName,
        [string]$Key,
        [string]$Default = ''
    )

    $envValue = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) { return $envValue.Trim() }
    if ($Key -and $Ini.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$Ini[$Key])) {
        return ([string]$Ini[$Key]).Trim()
    }
    return $Default
}

function Read-IniFile {
    param([string]$Path)

    $ini = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $ini }

    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }
        $equals = $trimmed.IndexOf('=')
        if ($equals -lt 1) { continue }
        $key = $trimmed.Substring(0, $equals).Trim().ToLowerInvariant()
        $value = $trimmed.Substring($equals + 1).Trim()
        if ($value.Length -ge 2) {
            $first = $value[0]
            $last = $value[$value.Length - 1]
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        if ($key) { $ini[$key] = $value }
    }
    return $ini
}

function Get-RamAltmanConfig {
    $defaultStateDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ram-altman'

    $configPath = [Environment]::GetEnvironmentVariable('RAM_ALTMAN_CONFIG')
    if ([string]::IsNullOrWhiteSpace($configPath)) {
        $configPath = Join-Path $defaultStateDir 'config.ini'
    }

    $ini = Read-IniFile -Path $configPath

    $stateDir = Get-ConfigString -Ini $ini -EnvName 'RAM_ALTMAN_STATE_DIR' -Key 'statedir' -Default $defaultStateDir
    if (-not [IO.Path]::IsPathRooted($stateDir)) {
        $stateDir = Join-Path (Get-Location).Path $stateDir
    }

    $thresholdText = Get-ConfigString -Ini $ini -EnvName 'RAM_ALTMAN_THRESHOLD' -Key 'threshold' -Default '10'
    $threshold = 0
    if (-not [int]::TryParse($thresholdText, [ref]$threshold) -or $threshold -lt 0 -or $threshold -gt 100) {
        throw "threshold must be a whole number between 0 and 100 (got '$thresholdText')"
    }

    $portText = Get-ConfigString -Ini $ini -EnvName 'RAM_ALTMAN_SMTP_PORT' -Key 'smtpport' -Default '587'
    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "smtpPort must be a port number between 1 and 65535 (got '$portText')"
    }

    $tlsText = Get-ConfigString -Ini $ini -EnvName 'RAM_ALTMAN_SMTP_TLS' -Key 'smtptls' -Default 'true'
    $tls = @('false', '0', 'no', 'off') -notcontains $tlsText.Trim().ToLowerInvariant()

    [pscustomobject]@{
        ConfigPath   = $configPath
        To           = Get-ConfigString -Ini $ini -EnvName 'RAM_ALTMAN_TO' -Key 'to'
        From         = Get-ConfigString -Ini $ini -EnvName 'RAM_ALTMAN_FROM' -Key 'from'
        FromName     = Get-ConfigString -Ini $ini -EnvName 'RAM_ALTMAN_FROM_NAME' -Key 'fromname'
        Threshold    = $threshold
        StateDir     = $stateDir
        SmtpHost     = Get-ConfigString -Ini $ini -EnvName 'RAM_ALTMAN_SMTP_HOST' -Key 'smtphost'
        SmtpPort     = $port
        SmtpUser     = Get-ConfigString -Ini $ini -EnvName 'RAM_ALTMAN_SMTP_USER' -Key 'smtpuser'
        SmtpPassword = Get-ConfigString -Ini $ini -EnvName 'RAM_ALTMAN_SMTP_PASSWORD' -Key 'smtppassword'
        SmtpTls      = $tls
        Sendmail     = Get-ConfigString -Ini $ini -EnvName 'RAM_ALTMAN_SENDMAIL' -Key 'sendmail'
        Outbox       = Get-ConfigString -Ini $ini -EnvName 'RAM_ALTMAN_OUTBOX' -Key 'outbox'
    }
}

$script:MemoryNativeSource = @'
using System;
using System.Runtime.InteropServices;

namespace RamAltman
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public class MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;

        public MEMORYSTATUSEX()
        {
            dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        }
    }

    public static class NativeMemory
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);
    }
}
'@

function Import-MemoryNative {
    if (-not ('RamAltman.NativeMemory' -as [type])) {
        Add-Type -TypeDefinition $script:MemoryNativeSource -Language CSharp
    }
}

function Read-RamAltmanMemory {
    $fake = [Environment]::GetEnvironmentVariable('RAM_ALTMAN_FAKE_MEMORY')

    if (-not [string]::IsNullOrWhiteSpace($fake)) {
        $parts = $fake.Split(',')
        if ($parts.Count -lt 2) { throw "RAM_ALTMAN_FAKE_MEMORY must be totalKb,availableKb[,freeKb]" }
        [int64]$totalKb = 0
        [int64]$availableKb = 0
        [int64]$freeKb = 0
        if (-not [int64]::TryParse($parts[0].Trim(), [ref]$totalKb) -or $totalKb -le 0) {
            throw "RAM_ALTMAN_FAKE_MEMORY has an invalid total"
        }
        if (-not [int64]::TryParse($parts[1].Trim(), [ref]$availableKb)) {
            throw "RAM_ALTMAN_FAKE_MEMORY has an invalid available figure"
        }
        if ($parts.Count -ge 3 -and $parts[2].Trim()) {
            [void][int64]::TryParse($parts[2].Trim(), [ref]$freeKb)
        }
    }
    else {
        Import-MemoryNative

        $status = New-Object RamAltman.MEMORYSTATUSEX
        if (-not [RamAltman.NativeMemory]::GlobalMemoryStatusEx($status)) {
            throw "GlobalMemoryStatusEx failed (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }
        $totalKb = [int64]($status.ullTotalPhys / 1024)
        $availableKb = [int64]($status.ullAvailPhys / 1024)
        [int64]$freeKb = 0

        try {
            $perf = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory -ErrorAction Stop
            $freeKb = [int64]([double]$perf.FreeAndZeroPageListBytes / 1024)
        }
        catch {
            $freeKb = 0
        }
    }

    if ($totalKb -le 0) { throw 'could not read total physical memory' }
    if ($availableKb -gt $totalKb) { $availableKb = $totalKb }
    if ($availableKb -lt 0) { $availableKb = 0 }
    if ($freeKb -gt $availableKb) { $freeKb = $availableKb }
    if ($freeKb -lt 0) { $freeKb = 0 }

    $usedKb = $totalKb - $availableKb
    $cacheKb = $availableKb - $freeKb
    $pct = [math]::Round(($availableKb * 100.0) / $totalKb, 1)

    [pscustomobject]@{
        TotalKb     = $totalKb
        UsedKb      = $usedKb
        AvailableKb = $availableKb
        FreeKb      = $freeKb
        CacheKb     = $cacheKb
        Percent     = $pct
    }
}

function Format-Gib {
    param([int64]$Kb)
    $gib = [math]::Round($Kb / 1048576.0, 1)
    $gib.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' GiB'
}

function Format-Percent {
    param([double]$Value)
    $Value.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
}

function Show-RamAltmanStatus {
    param($Memory)

    Write-Output "Total:      $(Format-Gib $Memory.TotalKb)"
    Write-Output "Used:       $(Format-Gib $Memory.UsedKb)"
    Write-Output "Available:  $(Format-Gib $Memory.AvailableKb) ($(Format-Percent $Memory.Percent)%)"
    Write-Output "  Free:     $(Format-Gib $Memory.FreeKb)"
    Write-Output "  Cache:    $(Format-Gib $Memory.CacheKb)"
}

function Test-RamAltmanOverThreshold {
    param($Memory, [int]$Threshold)
    return (($Memory.AvailableKb * 100) -gt ([int64]$Threshold * $Memory.TotalKb))
}

function Get-RamAltmanPick {
    param(
        [string]$StateDir,
        [string]$Name,
        [int]$Count,
        [switch]$DryRun
    )

    if ($DryRun -or $Count -le 1) {
        return Get-Random -Minimum 0 -Maximum $Count
    }

    $bagPath = Join-Path $StateDir "bag_$Name"
    $lastPath = "$bagPath.last"

    if ((-not (Test-Path -LiteralPath $bagPath)) -or ((Get-Item -LiteralPath $bagPath).Length -eq 0)) {
        $items = @(0..($Count - 1) | Sort-Object { Get-Random })
        if (Test-Path -LiteralPath $lastPath) {
            $last = ([IO.File]::ReadAllText($lastPath)).Trim()
            if ($items.Count -gt 1 -and [string]$items[0] -eq $last) {
                $items = @($items[1..($items.Count - 1)]) + @($items[0])
            }
        }
        [IO.File]::WriteAllLines($bagPath, [string[]]$items)
    }

    $queue = @([IO.File]::ReadAllLines($bagPath) | Where-Object { $_ -ne '' })
    if ($queue.Count -eq 0) { return Get-Random -Minimum 0 -Maximum $Count }

    $next = [int]$queue[0]
    if ($queue.Count -gt 1) {
        [IO.File]::WriteAllLines($bagPath, [string[]]$queue[1..($queue.Count - 1)])
    }
    else {
        [IO.File]::WriteAllText($bagPath, '')
    }
    [IO.File]::WriteAllText($lastPath, [string]$next)

    if ($next -ge $Count) { $next = Get-Random -Minimum 0 -Maximum $Count }
    return $next
}

function New-RamAltmanEmail {
    param($Config, $Memory, [switch]$DryRun)

    $total = Format-Gib $Memory.TotalKb
    $available = Format-Gib $Memory.AvailableKb
    $pct = Format-Percent $Memory.Percent

    $subjects = @(
        'Good news: we found some RAM',
        'Unused RAM detected in the wild',
        'RAM sighting on my PC',
        '{1} of RAM, just sitting there',
        'You missed a spot',
        'Daily RAM census: some survived',
        '{2}% of my RAM remains at large',
        "Still not all of it, I'm afraid"
    )

    $bodies = @(
        "I'm writing to report that you appear to have missed some. This PC has {0} of RAM and {1} of it ({2}%) is currently available. I assume this is an oversight.",
        "A routine inspection of my PC found {1} of unclaimed RAM out of {0}. That's {2}% of the machine doing absolutely nothing. I thought you'd want to know before someone tries to train something on it.",
        "Daily status report:`r`n`r`n  Total RAM:     {0}`r`n  Available:     {1} ({2}%)`r`n  Threat level:  someone at OpenAI might notice",
        "Even with every browser tab I own open, {1} of my {0} of RAM is still available. I'm as surprised as you are.",
        "Please don't be alarmed, but there is {1} of RAM on my desk that isn't in a data centre. That's {2}% of what's installed here, and as far as I can tell it has no plans today.",
        'Before you ask: yes, I counted the page cache as available. The kernel gives it back the moment anyone asks, which leaves {1} of {0} up for grabs.',
        "Today's forecast for my PC: clear skies, light workloads and {2}% available memory. Expect {1} of the installed {0} to stay idle through the evening.",
        "I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on {1} of it. Total installed: {0}. It's not for sale, I just like knowing it's there.",
        "I have a confession. I have {1} of RAM that I'm not using, which is {2}% of the {0} in this PC. I've told nobody but you and a cron job.",
        'If {1} of RAM sits idle in a PC and nobody allocates it, does it still count as capacity? Asking on behalf of the {2}% of my memory with nothing to do.'
    )

    $signoffs = @(
        'Yours in abundance,',
        'Regards from the last free RAM in the county,',
        'Hoarding responsibly,',
        'Stay allocated,',
        'Yours, with memory to spare,',
        'Kind regards,'
    )

    $stateDir = $Config.StateDir
    if (-not $DryRun -and -not (Test-Path -LiteralPath $stateDir)) {
        [void](New-Item -ItemType Directory -Path $stateDir -Force)
    }

    $subjectIndex = Get-RamAltmanPick -StateDir $stateDir -Name 'subject' -Count $subjects.Count -DryRun:$DryRun
    $bodyIndex = Get-RamAltmanPick -StateDir $stateDir -Name 'body' -Count $bodies.Count -DryRun:$DryRun
    $signoffIndex = Get-RamAltmanPick -StateDir $stateDir -Name 'signoff' -Count $signoffs.Count -DryRun:$DryRun

    $subject = $subjects[$subjectIndex] -f $total, $available, $pct
    $bodyText = $bodies[$bodyIndex] -f $total, $available, $pct
    $signoff = $signoffs[$signoffIndex]
    $fromName = if ($Config.FromName) { $Config.FromName } else { 'A concerned RAM owner' }

    $body = "Hi Sam,`r`n`r`n$bodyText`r`n`r`n$signoff`r`n$fromName`r`n`r`n--`r`nSent automatically, at most once a day, by a small script on one PC.`r`nReply if you'd like it to stop."

    [pscustomobject]@{
        Subject = $subject
        Body    = $body
    }
}

function Get-RamAltmanRenderedMessage {
    param($Config, $Email)

    $from = if ($Config.FromName) { "$($Config.FromName) <$($Config.From)>" } else { $Config.From }
    $date = [DateTimeOffset]::Now.ToString('ddd, dd MMM yyyy HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture)

    $headers = @(
        "From: $from",
        "To: $($Config.To)",
        "Subject: $($Email.Subject)",
        "Date: $date",
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset=UTF-8',
        'Auto-Submitted: auto-generated'
    )
    return (($headers -join "`r`n") + "`r`n`r`n" + $Email.Body)
}

function Send-RamAltmanEmail {
    param($Config, $Email)

    $message = Get-RamAltmanRenderedMessage -Config $Config -Email $Email

    if ($Config.Outbox) {
        $directory = Split-Path -Parent $Config.Outbox
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
        [IO.File]::WriteAllText($Config.Outbox, $message, (New-Object Text.UTF8Encoding($false)))
        return
    }

    if ($Config.Sendmail) {
        $processInfo = New-Object Diagnostics.ProcessStartInfo
        $processInfo.FileName = $env:ComSpec
        $processInfo.Arguments = '/d /c ' + $Config.Sendmail
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardInput = $true
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.CreateNoWindow = $true

        $process = [Diagnostics.Process]::Start($processInfo)
        $process.StandardInput.Write($message)
        $process.StandardInput.Close()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "sendmail command exited with $($process.ExitCode): $($stderr.Trim())"
        }
        return
    }

    if (-not $Config.SmtpHost) {
        throw 'no mail transport configured: set smtpHost/smtpUser/smtpPassword, set sendmail, or set outbox'
    }

    $mail = New-Object Net.Mail.MailMessage
    try {
        $mail.From = New-Object Net.Mail.MailAddress($Config.From, $Config.FromName)
        [void]$mail.To.Add($Config.To)
        $mail.Subject = $Email.Subject
        $mail.Body = $Email.Body
        $mail.BodyEncoding = [Text.Encoding]::UTF8
        $mail.Headers['Auto-Submitted'] = 'auto-generated'

        $client = New-Object Net.Mail.SmtpClient($Config.SmtpHost, $Config.SmtpPort)
        try {
            $client.EnableSsl = $Config.SmtpTls
            $client.Timeout = 30000
            if ($Config.SmtpUser) {
                $client.Credentials = New-Object Net.NetworkCredential($Config.SmtpUser, $Config.SmtpPassword)
            }
            $client.Send($mail)
        }
        finally {
            $client.Dispose()
        }
    }
    finally {
        $mail.Dispose()
    }
}

function Write-RamAltmanSample {
    param($Config, $Memory)

    $logPath = Join-Path $Config.StateDir 'usage.csv'
    $encoding = New-Object Text.UTF8Encoding($false)

    if (-not (Test-Path -LiteralPath $logPath)) {
        [IO.File]::AppendAllText($logPath, "timestamp,total_kb,used_kb,available_kb,available_pct`r`n", $encoding)
    }

    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture)
    $line = '{0},{1},{2},{3},{4}' -f $timestamp, $Memory.TotalKb, $Memory.UsedKb, $Memory.AvailableKb, (Format-Percent $Memory.Percent)
    [IO.File]::AppendAllText($logPath, $line + "`r`n", $encoding)

    $maxBytes = 10 * 1024 * 1024
    if ((Get-Item -LiteralPath $logPath).Length -gt $maxBytes) {
        $lines = [IO.File]::ReadAllLines($logPath)
        $keep = 50000
        $trimmed = @($lines[0])
        if ($lines.Count -gt $keep) {
            $trimmed += $lines[($lines.Count - $keep)..($lines.Count - 1)]
        }
        else {
            $trimmed += $lines[1..($lines.Count - 1)]
        }
        [IO.File]::WriteAllLines($logPath, [string[]]$trimmed, $encoding)
    }
}

function Enter-RamAltmanLock {
    param([string]$StateDir)

    $lockPath = Join-Path $StateDir 'lock'
    try {
        return [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        return $null
    }
}

function Get-PowerShellPath {
    return (Get-Process -Id $PID).Path
}

function Install-RamAltmanTask {
    $scriptPath = $script:ScriptPath
    $powerShellPath = Get-PowerShellPath
    $taskCommand = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $powerShellPath, $scriptPath

    $output = & schtasks.exe /Create /F /SC MINUTE /MO 5 /TN $script:TaskName /TR $taskCommand 2>&1
    if ($LASTEXITCODE -ne 0) { throw "schtasks failed: $($output -join ' ')" }
    Write-Output "Scheduled task '$($script:TaskName)' created: every 5 minutes, runs $scriptPath"
    Write-Output "Undo with: $scriptPath --uninstall-task"
}

function Uninstall-RamAltmanTask {
    $output = & schtasks.exe /Delete /F /TN $script:TaskName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "schtasks failed: $($output -join ' ')" }
    Write-Output "Scheduled task '$($script:TaskName)' removed."
}

function Show-RamAltmanHelp {
    Write-Output @"
$($script:AppName) $($script:Version) - Windows/PowerShell edition

Tracks RAM usage and, at most once a day, tells Sam Altman when this PC has
RAM to spare.

Usage:
  ram-altman.ps1                 Log a sample and send the daily email if due
  ram-altman.ps1 --status        Print current memory figures and exit
  ram-altman.ps1 --dry-run       Print the email that would be sent and exit
  ram-altman.ps1 --install-task  Sample every 5 minutes in Task Scheduler
  ram-altman.ps1 --uninstall-task Remove that scheduled task
  ram-altman.ps1 --version       Print the version
  ram-altman.ps1 --help          Show this help

Configuration:
  Ram-altman reads config.ini from %LOCALAPPDATA%\ram-altman\config.ini,
  or from RAM_ALTMAN_CONFIG. Every setting can also be set with a
  RAM_ALTMAN_* environment variable. See windows\config.example.ini.

  Emails go through SMTP (smtpHost/smtpUser/smtpPassword), an external
  sendmail-compatible command, or a file if outbox is set. --dry-run needs
  no mail settings at all.

State:
  Samples are appended to usage.csv in the state directory
  (%LOCALAPPDATA%\ram-altman by default). The last send date lives there too,
  so a failed send is retried on the next run.
"@
}

function Invoke-RamAltman {
    param([string[]]$CliArgs)

    $command = if ($CliArgs -and $CliArgs.Count -gt 0) { $CliArgs[0] } else { '' }

    switch -Exact ($command.ToLowerInvariant()) {
        { $_ -in @('--help', '-h', '-?', '/?') } {
            Show-RamAltmanHelp
            return
        }
        '--version' {
            Write-Output "$($script:AppName) $($script:Version)"
            return
        }
        '--status' {
            $config = Get-RamAltmanConfig
            $memory = Read-RamAltmanMemory
            Show-RamAltmanStatus -Memory $memory
            return
        }
        '--dry-run' {
            $config = Get-RamAltmanConfig
            $memory = Read-RamAltmanMemory
            Show-RamAltmanStatus -Memory $memory
            if (-not (Test-RamAltmanOverThreshold -Memory $memory -Threshold $config.Threshold)) {
                Write-Output "No email: available RAM is not above $($config.Threshold)%."
                return
            }
            $email = New-RamAltmanEmail -Config $config -Memory $memory -DryRun
            $preview = [pscustomobject]@{
                From     = if ($config.From) { $config.From } else { 'sender-not-set@example.com' }
                To       = if ($config.To) { $config.To } else { 'recipient-not-set@example.com' }
                FromName = $config.FromName
                Subject  = $email.Subject
                Body     = $email.Body
            }
            Write-Output ''
            Write-Output (Get-RamAltmanRenderedMessage -Config $preview -Email $email)
            return
        }
        '--install-task' {
            Install-RamAltmanTask
            return
        }
        '--uninstall-task' {
            Uninstall-RamAltmanTask
            return
        }
        ''
        {
            # continue below
        }
        default {
            throw "unknown option: $command (try --help)"
        }
    }

    $config = Get-RamAltmanConfig
    $script:StateDir = $config.StateDir

    if (-not $config.To) { throw 'recipient is not set (to / RAM_ALTMAN_TO)' }
    if (-not $config.From) { throw 'sender is not set (from / RAM_ALTMAN_FROM)' }

    if (-not (Test-Path -LiteralPath $config.StateDir)) {
        [void](New-Item -ItemType Directory -Path $config.StateDir -Force)
    }

    $script:LockStream = Enter-RamAltmanLock -StateDir $config.StateDir
    if ($null -eq $script:LockStream) { return }

    try {
        $memory = Read-RamAltmanMemory
        Write-RamAltmanSample -Config $config -Memory $memory

        if (-not (Test-RamAltmanOverThreshold -Memory $memory -Threshold $config.Threshold)) { return }

        $today = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $lastSentPath = Join-Path $config.StateDir 'last_sent'
        $lastSent = if (Test-Path -LiteralPath $lastSentPath) { ([IO.File]::ReadAllText($lastSentPath)).Trim() } else { '' }
        if ($lastSent -eq $today) { return }

        $email = New-RamAltmanEmail -Config $config -Memory $memory
        Send-RamAltmanEmail -Config $config -Email $email

        [IO.File]::WriteAllText($lastSentPath, $today)
        return
    }
    finally {
        if ($script:LockStream) {
            $script:LockStream.Dispose()
            $script:LockStream = $null
        }
    }
}

$script:CliArgs = @($args)
$script:ExitCode = 0
try {
    Invoke-RamAltman -CliArgs $script:CliArgs
}
catch {
    Write-ErrorLine $_.Exception.Message
    $script:ExitCode = 1
}
exit $script:ExitCode
