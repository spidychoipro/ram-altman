# Ram Altman for Windows

The same joke as the bash original, with Windows memory accounting and three
ways to run it: a small console executable, a PowerShell script, and a batch
file. All three read the same configuration, write the same CSV and send at
most one email a day.

The original Linux edition (`ram-altman.sh`) is untouched.

## Which edition?

| Edition | File | Needs | Best for |
| --- | --- | --- | --- |
| Console app | `ram-altman.exe` | Nothing, .NET Framework 4.x is already on Windows 10/11 | Scheduled tasks, the MSI, people who like `.exe` |
| PowerShell | `ram-altman.ps1` | PowerShell 5.1+ (included in Windows) | Reading and editing the source |
| Batch | `ram-altman.bat` | `cmd.exe` plus PowerShell for the clock, memory probe and shuffle | Maximum nostalgia |

The exe and the PowerShell script do everything themselves. The batch file is
still batch, but it borrows the built-in PowerShell for three jobs Windows
batch cannot do on its own: reading the clock in a useful format, asking the
system for available memory, and shuffling the joke rotation. If PowerShell is
missing (it is not, on a normal Windows install), the batch edition will not
run.

## Install

### MSI (recommended)

Download `ram-altman-<version>.msi` and run it. It is a **per-user** installer:
no administrator prompt, no UAC. It puts the tools in
`%LOCALAPPDATA%\Programs\Ram Altman`, adds that folder to your user `PATH`, and
creates a Start Menu shortcut that opens `--status`.

The installer does not start anything, schedule anything, or configure an
address. That part is on you, and it is in the next section.

### Portable zip

Download `ram-altman-<version>-portable.zip` and extract it anywhere,
including a USB stick. Run the edition you want from that folder. Nothing is
installed, no registry keys are written, and uninstalling means deleting the
folder.

### From source

```powershell
git clone https://github.com/spidychoipro/ram-altman.git
cd ram-altman
.\ram-altman.ps1 --status
.\ram-altman.bat --status
```

The exe is built from `windows\src\RamAltman.cs`; see [Building](#building).

## Quick start

```powershell
ram-altman.exe --status     # see the evidence against you
ram-altman.exe --dry-run    # preview the email without sending it
```

`--status` and `--dry-run` never write a sample, never create the state
directory and never send anything. `--dry-run` does not need an email address
or a mail server, which makes it the safest way to enjoy the jokes.

Example output, from a PC that has confessed:

```text
Total:      15.3 GiB
Used:       6.7 GiB
Available:  8.6 GiB (56.2%)
  Free:     0.1 GiB
  Cache:    8.5 GiB
```

To run it for real, configure an address and a transport (below), then run it
once by hand:

```powershell
ram-altman.exe
```

That appends a sample to `usage.csv` and, if available RAM is above the
threshold and nothing has been sent today, sends one email. Run it again and
it logs another sample but stays quiet.

## Configuration

Settings live in `%LOCALAPPDATA%\ram-altman\config.ini`. Set
`RAM_ALTMAN_CONFIG` to use a different file. Every setting can also be given as
a `RAM_ALTMAN_*` environment variable, which wins over the file. Start from
[`config.example.ini`](config.example.ini).

| INI key | Environment variable | What it does | Default |
| --- | --- | --- | --- |
| `to` | `RAM_ALTMAN_TO` | Who receives the bad news | Required |
| `from` | `RAM_ALTMAN_FROM` | A real address you can send from | Required |
| `fromName` | `RAM_ALTMAN_FROM_NAME` | Your name, or your nom de RAM | `A concerned RAM owner` |
| `threshold` | `RAM_ALTMAN_THRESHOLD` | Email when available RAM is above this percentage (whole number, 0-100) | `10` |
| `statedir` | `RAM_ALTMAN_STATE_DIR` | Where `usage.csv`, `last_sent` and the rotation live | `%LOCALAPPDATA%\ram-altman` |
| `smtpHost` | `RAM_ALTMAN_SMTP_HOST` | SMTP server | empty |
| `smtpPort` | `RAM_ALTMAN_SMTP_PORT` | SMTP port | `587` |
| `smtpUser` | `RAM_ALTMAN_SMTP_USER` | SMTP user name | empty |
| `smtpPassword` | `RAM_ALTMAN_SMTP_PASSWORD` | SMTP password | empty |
| `smtpTls` | `RAM_ALTMAN_SMTP_TLS` | Use STARTTLS (`true`/`false`) | `true` |
| `sendmail` | `RAM_ALTMAN_SENDMAIL` | A sendmail-compatible command instead of SMTP | empty |
| `outbox` | `RAM_ALTMAN_OUTBOX` | Write the message to this file instead of sending | empty |

At least one transport is required for a real send: SMTP, a `sendmail`
command, or an `outbox` file. If none is configured the run fails, says why,
and does not record the day, so the next run tries again.

`sendmail` is run through `cmd.exe /d /c`, and the complete message is written
to its standard input. That means msmtp, blat, or anything else that accepts an
RFC 822 message on stdin will do:

```ini
sendmail = "C:\msys64\usr\bin\msmtp.exe" -t
```

`outbox` is for testing and for people who prefer to send mail themselves:

```ini
outbox = %LOCALAPPDATA%\Temp\ram-altman.eml
```

### Environment-only example

```powershell
$env:RAM_ALTMAN_TO = 'sam@example.com'
$env:RAM_ALTMAN_FROM = 'you@example.com'
$env:RAM_ALTMAN_SMTP_HOST = 'smtp.example.com'
$env:RAM_ALTMAN_SMTP_USER = 'you@example.com'
$env:RAM_ALTMAN_SMTP_PASSWORD = 'app-password'
.\ram-altman.ps1
```

## What counts as "used"?

```text
used = total physical - available physical
```

`available` is `GlobalMemoryStatusEx().ullAvailPhys`, the same number Task
Manager calls available: free memory plus standby pages Windows can hand to a
new program without paging. `free` is the `FreeAndZeroPageListBytes` counter,
and `cache` is the difference between the two. It is the Windows translation of
the Linux edition's `MemAvailable` split, and it is deliberately generous to
the other side.

The batch edition reads the same figures through CIM
(`Win32_OperatingSystem` and `Win32_PerfRawData_PerfOS_Memory`) because batch
does not speak Win32.

## Scheduling

All three editions can create a Task Scheduler job that runs every five
minutes, which is what the cron entry does on Linux. The daily limit lives in
`last_sent`, so sampling often does not send more often.

```powershell
ram-altman.exe --install-task
ram-altman.exe --uninstall-task
```

The task is created for the current user and runs the same edition that created
it (the batch task runs the batch file, and so on). The first run after
installing a task may take a few seconds while Task Scheduler starts.

You can also use Task Scheduler's own UI and run `ram-altman.exe` with no
arguments every five minutes. That is all `--install-task` does.

## Update, uninstall, and cleanup

- **MSI:** run a newer MSI to upgrade in place, or use *Settings → Apps →
  Installed apps → Ram Altman → Uninstall*. The Start Menu folder and `PATH`
  entry are removed. Your config and CSV are left alone.
- **Portable:** delete the folder.
- **Scheduled task:** `ram-altman.exe --uninstall-task` (or delete "Ram Altman"
  in Task Scheduler).
- **State:** delete `%LOCALAPPDATA%\ram-altman` to remove the config, CSV and
  rotation. This is not done by any uninstaller, because it is your data.

## Security notes

- The SMTP password is stored in plain text in `config.ini`, because a scheduled
  task cannot type a password. Use an app-specific password, and keep the file
  out of anything you share. `RAM_ALTMAN_SMTP_PASSWORD` in a user environment
  variable is a little better.
- The MSI installs per user, so it cannot write to `Program Files` or the
  machine `PATH`, and it never asks for elevation.
- `--dry-run` opens no sockets and touches no state.
- Do not point `sendmail` at a shell script you would not run yourself; the
  config file is executable input.

## Audit yourself

The CSV has one row per sample:

```text
timestamp,total_kb,used_kb,available_kb,available_pct
```

PowerShell can do the maths the `awk` one-liner does on Linux:

```powershell
Import-Csv "$env:LOCALAPPDATA\ram-altman\usage.csv" | ForEach-Object {
    [pscustomobject]@{
        used  = [double]$_.used_kb
        total = [double]$_.total_kb
    }
} | Measure-Object -Property used,total -Sum | ForEach-Object {
    $sums = $_.Sum
    'Your RAM in use: {0:N1}% (the claim: maybe 5%)' -f ($sums[0] * 100 / $sums[1])
}
```

## Building

Requirements: Windows with .NET Framework 4.x (the `csc.exe` compiler is part
of it), PowerShell 7 for the tests, and WiX Toolset 5.x for the MSI.

```powershell
dotnet tool install --global wix --version 5.0.2
pwsh -File windows\build.ps1
```

WiX 5 is the last release without the Open Source Maintenance Fee EULA. If you
already have WiX 6 or 7, accept its EULA with `wix eula accept wix7` (or pass
`-acceptEula wix7`); the build itself does not need changing.

Artifacts land in `dist\`:

```text
dist\ram-altman.exe
dist\ram-altman-1.1.0.msi
dist\ram-altman-1.1.0-portable.zip
```

`build.ps1` compiles the exe with the .NET Framework compiler, runs the test
suite, then packages the zip and MSI. Useful switches:
`-Version 1.2.0`, `-SkipTests`, `-SkipMsi`.

The exe is deliberately built against .NET Framework 4.x rather than .NET 8 so
it runs on a fresh Windows machine without installing a runtime.

## Tests

```powershell
pwsh -File windows\test-ram-altman.ps1 -ExePath dist\ram-altman.exe
```

The suite uses simulated memory (`RAM_ALTMAN_FAKE_MEMORY`), a throwaway state
directory and a file outbox, so no mail is sent and your real profile is left
alone. It covers the status output, dry run, daily limit, threshold boundary,
CSV, config precedence, failed sends and the rotation. Add `-SkipExe` to test
only the script editions.

Set `RAM_ALTMAN_FAKE_MEMORY=totalKb,availableKb[,freeKb]` to try any figure by
hand:

```powershell
$env:RAM_ALTMAN_FAKE_MEMORY = '16000000,9000000,100000'
.\ram-altman.exe --status
```

## License

Free as in unallocated. See `LICENSE`.
