@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem ============================================================================
rem  ram-altman.bat - Windows batch edition
rem
rem  Tracks RAM usage and, at most once a day, tells Sam Altman when this PC
rem  has RAM to spare.
rem
rem  Usage:
rem    ram-altman.bat                 Log a sample and send the daily email if due
rem    ram-altman.bat --status        Print current memory figures and exit
rem    ram-altman.bat --dry-run       Print the email that would be sent and exit
rem    ram-altman.bat --install-task  Sample every 5 minutes in Task Scheduler
rem    ram-altman.bat --uninstall-task Remove that scheduled task
rem    ram-altman.bat --version       Print the version
rem    ram-altman.bat --help          Show this help
rem
rem  Settings live in %LOCALAPPDATA%\ram-altman\config.ini (or
rem  RAM_ALTMAN_CONFIG) and can be overridden with RAM_ALTMAN_* environment
rem  variables. See windows\config.example.ini.
rem
rem  Windows has no /proc/meminfo, so this edition asks the built-in PowerShell
rem  for GlobalMemoryStatusEx's available memory and the system cache figure.
rem  It also borrows PowerShell to shuffle the joke rotation and to trim the
rem  CSV. Sending uses curl.exe (bundled with Windows 10/11), an external
rem  sendmail-compatible command, or a plain file when outbox is set.
rem ============================================================================

set "APP=ram-altman"
set "VERSION=1.1.0"
set "TASK_NAME=Ram Altman"

rem ----- pick the command ------------------------------------------------------
if "%~1"=="" goto :daily
if /i "%~1"=="--status" goto :status
if /i "%~1"=="--dry-run" goto :dry_run
if /i "%~1"=="--install-task" goto :install_task
if /i "%~1"=="--uninstall-task" goto :uninstall_task
if /i "%~1"=="--version" goto :version
if /i "%~1"=="--help" goto :help
if /i "%~1"=="-h" goto :help
if /i "%~1"=="-?" goto :help
if /i "%~1"=="/?" goto :help
>&2 echo %APP%: unknown option: %~1 ^(try --help^)
exit /b 1

:version
echo %APP% %VERSION%
exit /b 0

:help
echo %APP% %VERSION% - Windows batch edition
echo.
echo Tracks RAM usage and, at most once a day, tells Sam Altman when this PC
echo has RAM to spare.
echo.
echo Usage:
echo   ram-altman.bat                 Log a sample and send the daily email if due
echo   ram-altman.bat --status        Print current memory figures and exit
echo   ram-altman.bat --dry-run       Print the email that would be sent and exit
echo   ram-altman.bat --install-task  Sample every 5 minutes in Task Scheduler
echo   ram-altman.bat --uninstall-task Remove that scheduled task
echo   ram-altman.bat --version       Print the version
echo   ram-altman.bat --help          Show this help
echo.
echo Configuration:
echo   Reads config.ini from %%LOCALAPPDATA%%\ram-altman\config.ini, or from
echo   RAM_ALTMAN_CONFIG. Every setting can also be set with a RAM_ALTMAN_*
echo   environment variable. See windows\config.example.ini.
echo.
echo   Emails go through curl.exe (SMTP), an external sendmail-compatible
echo   command, or a file if outbox is set. --dry-run needs no mail settings.
echo.
echo State:
echo   Samples are appended to usage.csv in the state directory
echo   (%%LOCALAPPDATA%%\ram-altman by default). The last send date lives there
echo   too, so a failed send is retried on the next run.
exit /b 0

rem ============================================================================
rem  Read-only commands
rem ============================================================================

:status
call :load_config
if errorlevel 1 exit /b 1
call :read_memory
if errorlevel 1 goto :memory_failed
call :compute
echo Total:      %GIB_TOTAL% GiB
echo Used:       %GIB_USED% GiB
echo Available:  %GIB_AVAIL% GiB ^(%PCT_TEXT%%%^)
echo   Free:     %GIB_FREE% GiB
echo   Cache:    %GIB_CACHE% GiB
exit /b 0

:dry_run
set "DRY_RUN=1"
call :load_config
if errorlevel 1 exit /b 1
call :read_memory
if errorlevel 1 goto :memory_failed
call :compute
call :get_clock
if errorlevel 1 goto :powershell_failed
echo Total:      %GIB_TOTAL% GiB
echo Used:       %GIB_USED% GiB
echo Available:  %GIB_AVAIL% GiB ^(%PCT_TEXT%%%^)
echo   Free:     %GIB_FREE% GiB
echo   Cache:    %GIB_CACHE% GiB
if %PCT100% leq %THRESHOLD100% (
    echo No email: available RAM is not above %THRESHOLD%%%.
    exit /b 0
)
if not defined CFG_TO set "CFG_TO=recipient-not-set@example.com"
if not defined CFG_FROM set "CFG_FROM=sender-not-set@example.com"
set "TMP=%TEMP%\ram-altman-%RANDOM%%RANDOM%"
if not exist "%TMP%" mkdir "%TMP%" >nul 2>nul
call :compose_email
echo.
echo From: %FROM_HEADER%
echo To: %CFG_TO%
echo Subject: %EMAIL_SUBJECT%
echo Date: %RFC_DATE%
echo MIME-Version: 1.0
echo Content-Type: text/plain; charset=UTF-8
echo Auto-Submitted: auto-generated
echo.
type "%BODY_FULL%"
rmdir /s /q "%TMP%" >nul 2>nul
exit /b 0

rem ============================================================================
rem  Daily run
rem ============================================================================

:daily
call :load_config
if errorlevel 1 exit /b 1

if not defined CFG_TO (
    >&2 echo %APP%: recipient is not set ^(to / RAM_ALTMAN_TO^)
    exit /b 1
)
if not defined CFG_FROM (
    >&2 echo %APP%: sender is not set ^(from / RAM_ALTMAN_FROM^)
    exit /b 1
)

call :read_memory
if errorlevel 1 goto :memory_failed
call :compute

if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>nul
mkdir "%STATE_DIR%\lock" >nul 2>nul
if errorlevel 1 (
    rem Another copy is already running. Quietly stand down.
    exit /b 0
)

set "TMP=%TEMP%\ram-altman-%RANDOM%%RANDOM%"
if not exist "%TMP%" mkdir "%TMP%" >nul 2>nul

call :get_clock
if errorlevel 1 goto :powershell_failed

call :log_sample

if %PCT100% leq %THRESHOLD100% goto :daily_done

set "LAST_SENT="
if exist "%STATE_DIR%\last_sent" set /p LAST_SENT=<"%STATE_DIR%\last_sent"
if "%LAST_SENT%"=="%TODAY%" goto :daily_done

call :compose_email
call :send_email
if errorlevel 1 goto :send_failed

> "%STATE_DIR%\last_sent" echo %TODAY%

:daily_done
rmdir "%STATE_DIR%\lock" >nul 2>nul
rmdir /s /q "%TMP%" >nul 2>nul
exit /b 0

:send_failed
>&2 echo %APP%: email failed to send; will try again on the next run
rmdir "%STATE_DIR%\lock" >nul 2>nul
rmdir /s /q "%TMP%" >nul 2>nul
exit /b 1

:memory_failed
>&2 echo %APP%: could not read memory figures
exit /b 1

:powershell_failed
>&2 echo %APP%: PowerShell is required for the clock in the batch edition
rmdir "%STATE_DIR%\lock" >nul 2>nul
rmdir /s /q "%TMP%" >nul 2>nul
exit /b 1

rem ============================================================================
rem  Task Scheduler
rem ============================================================================

:install_task
schtasks.exe /Create /F /SC MINUTE /MO 5 /TN "%TASK_NAME%" /TR "\"%~f0\"" >nul
if errorlevel 1 (
    >&2 echo %APP%: schtasks failed to create the task
    exit /b 1
)
echo Scheduled task '%TASK_NAME%' created: every 5 minutes, runs %~f0
echo Undo with: %~f0 --uninstall-task
exit /b 0

:uninstall_task
schtasks.exe /Delete /F /TN "%TASK_NAME%" >nul
if errorlevel 1 (
    >&2 echo %APP%: schtasks failed to remove the task
    exit /b 1
)
echo Scheduled task '%TASK_NAME%' removed.
exit /b 0

rem ============================================================================
rem  Configuration
rem ============================================================================

:load_config
if not defined LOCALAPPDATA set "LOCALAPPDATA=%USERPROFILE%\AppData\Local"
set "DEFAULT_STATE=%LOCALAPPDATA%\ram-altman"
if defined RAM_ALTMAN_CONFIG (
    set "CONFIG_FILE=%RAM_ALTMAN_CONFIG%"
) else (
    set "CONFIG_FILE=%DEFAULT_STATE%\config.ini"
)

set "INI_TO="
set "INI_FROM="
set "INI_FROMNAME="
set "INI_THRESHOLD="
set "INI_STATEDIR="
set "INI_SMTPHOST="
set "INI_SMTPPORT="
set "INI_SMTPUSER="
set "INI_SMTPPASSWORD="
set "INI_SMTPTLS="
set "INI_SENDMAIL="
set "INI_OUTBOX="

if exist "%CONFIG_FILE%" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%CONFIG_FILE%") do (
        set "INI_KEY=%%A"
        for /f "tokens=* delims= " %%K in ("!INI_KEY!") do set "INI_KEY=%%K"
        set "INI_VALUE=%%B"
        for /f "tokens=* delims= " %%V in ("!INI_VALUE!") do set "INI_VALUE=%%V"
        if defined INI_KEY if not "!INI_KEY:~0,1!"=="#" if not "!INI_KEY:~0,1!"==";" (
            if "!INI_VALUE:~0,1!"=="""" set "INI_VALUE=!INI_VALUE:~1,-1!"
            if /i "!INI_KEY!"=="to" set "INI_TO=!INI_VALUE!"
            if /i "!INI_KEY!"=="from" set "INI_FROM=!INI_VALUE!"
            if /i "!INI_KEY!"=="fromname" set "INI_FROMNAME=!INI_VALUE!"
            if /i "!INI_KEY!"=="threshold" set "INI_THRESHOLD=!INI_VALUE!"
            if /i "!INI_KEY!"=="statedir" set "INI_STATEDIR=!INI_VALUE!"
            if /i "!INI_KEY!"=="smtphost" set "INI_SMTPHOST=!INI_VALUE!"
            if /i "!INI_KEY!"=="smtpport" set "INI_SMTPPORT=!INI_VALUE!"
            if /i "!INI_KEY!"=="smtpuser" set "INI_SMTPUSER=!INI_VALUE!"
            if /i "!INI_KEY!"=="smtppassword" set "INI_SMTPPASSWORD=!INI_VALUE!"
            if /i "!INI_KEY!"=="smtptls" set "INI_SMTPTLS=!INI_VALUE!"
            if /i "!INI_KEY!"=="sendmail" set "INI_SENDMAIL=!INI_VALUE!"
            if /i "!INI_KEY!"=="outbox" set "INI_OUTBOX=!INI_VALUE!"
        )
    )
)

set "CFG_TO=%INI_TO%"
if defined RAM_ALTMAN_TO set "CFG_TO=%RAM_ALTMAN_TO%"
set "CFG_FROM=%INI_FROM%"
if defined RAM_ALTMAN_FROM set "CFG_FROM=%RAM_ALTMAN_FROM%"
set "CFG_FROMNAME=%INI_FROMNAME%"
if defined RAM_ALTMAN_FROM_NAME set "CFG_FROMNAME=%RAM_ALTMAN_FROM_NAME%"
set "CFG_THRESHOLD=%INI_THRESHOLD%"
if defined RAM_ALTMAN_THRESHOLD set "CFG_THRESHOLD=%RAM_ALTMAN_THRESHOLD%"
if not defined CFG_THRESHOLD set "CFG_THRESHOLD=10"
set "STATE_DIR=%INI_STATEDIR%"
if defined RAM_ALTMAN_STATE_DIR set "STATE_DIR=%RAM_ALTMAN_STATE_DIR%"
if not defined STATE_DIR set "STATE_DIR=%DEFAULT_STATE%"
set "CFG_SMTPHOST=%INI_SMTPHOST%"
if defined RAM_ALTMAN_SMTP_HOST set "CFG_SMTPHOST=%RAM_ALTMAN_SMTP_HOST%"
set "CFG_SMTPPORT=%INI_SMTPPORT%"
if defined RAM_ALTMAN_SMTP_PORT set "CFG_SMTPPORT=%RAM_ALTMAN_SMTP_PORT%"
if not defined CFG_SMTPPORT set "CFG_SMTPPORT=587"
set "CFG_SMTPUSER=%INI_SMTPUSER%"
if defined RAM_ALTMAN_SMTP_USER set "CFG_SMTPUSER=%RAM_ALTMAN_SMTP_USER%"
set "CFG_SMTPPASSWORD=%INI_SMTPPASSWORD%"
if defined RAM_ALTMAN_SMTP_PASSWORD set "CFG_SMTPPASSWORD=%RAM_ALTMAN_SMTP_PASSWORD%"
set "CFG_SMTPTLS=%INI_SMTPTLS%"
if defined RAM_ALTMAN_SMTP_TLS set "CFG_SMTPTLS=%RAM_ALTMAN_SMTP_TLS%"
if not defined CFG_SMTPTLS set "CFG_SMTPTLS=true"
set "CFG_SENDMAIL=%INI_SENDMAIL%"
if defined RAM_ALTMAN_SENDMAIL set "CFG_SENDMAIL=%RAM_ALTMAN_SENDMAIL%"
set "CFG_OUTBOX=%INI_OUTBOX%"
if defined RAM_ALTMAN_OUTBOX set "CFG_OUTBOX=%RAM_ALTMAN_OUTBOX%"

set /a THRESHOLD=CFG_THRESHOLD 2>nul
if errorlevel 1 goto :config_failed
if %THRESHOLD% lss 0 goto :config_failed
if %THRESHOLD% gtr 100 goto :config_failed
set /a THRESHOLD100=THRESHOLD*100

set /a CFG_SMTPPORT=CFG_SMTPPORT 2>nul
if errorlevel 1 goto :config_failed
if %CFG_SMTPPORT% lss 1 goto :config_failed
if %CFG_SMTPPORT% gtr 65535 goto :config_failed

set "SMTP_TLS=1"
if /i "%CFG_SMTPTLS%"=="false" set "SMTP_TLS=0"
if /i "%CFG_SMTPTLS%"=="no" set "SMTP_TLS=0"
if /i "%CFG_SMTPTLS%"=="off" set "SMTP_TLS=0"
if "%CFG_SMTPTLS%"=="0" set "SMTP_TLS=0"

set "FROM_NAME=%CFG_FROMNAME%"
if not defined FROM_NAME set "FROM_NAME=A concerned RAM owner"
set "FROM_HEADER=%CFG_FROM%"
if defined CFG_FROMNAME set "FROM_HEADER=%CFG_FROMNAME% ^<%CFG_FROM%^>"
exit /b 0

:config_failed
>&2 echo %APP%: threshold or smtpPort in %CONFIG_FILE% is not valid
exit /b 1

rem ============================================================================
rem  Memory
rem ============================================================================

:read_memory
if defined RAM_ALTMAN_FAKE_MEMORY (
    for /f "tokens=1,2,3 delims=," %%a in ("%RAM_ALTMAN_FAKE_MEMORY%") do (
        set "TOTAL_KB=%%a"
        set "AVAIL_KB=%%b"
        set "FREE_KB=%%c"
    )
    if not defined FREE_KB set "FREE_KB=0"
    if not defined TOTAL_KB exit /b 1
    if not defined AVAIL_KB exit /b 1
    exit /b 0
)

set "MEMORY_PROBE=powershell -NoProfile -ExecutionPolicy Bypass -Command "$os=Get-CimInstance Win32_OperatingSystem;$perf=Get-CimInstance Win32_PerfRawData_PerfOS_Memory;'{0} {1} {2}' -f $os.TotalVisibleMemorySize,[int64]($perf.AvailableBytes/1KB),[int64]($perf.FreeAndZeroPageListBytes/1KB)""
for /f "usebackq tokens=1,2,3" %%a in (`%MEMORY_PROBE%`) do (
    set "TOTAL_KB=%%a"
    set "AVAIL_KB=%%b"
    set "FREE_KB=%%c"
)
if not defined TOTAL_KB exit /b 1
if not defined AVAIL_KB exit /b 1
if not defined FREE_KB set "FREE_KB=0"
exit /b 0

:compute
set /a USED_KB=TOTAL_KB-AVAIL_KB
if %FREE_KB% gtr %AVAIL_KB% set "FREE_KB=%AVAIL_KB%"
if %FREE_KB% lss 0 set "FREE_KB=0"
set /a CACHE_KB=AVAIL_KB-FREE_KB
set /a PCT_DEN=TOTAL_KB/10000
if %PCT_DEN% lss 1 set "PCT_DEN=1"
set /a PCT100=AVAIL_KB/PCT_DEN
set /a PCT_WHOLE=PCT100/100
set /a PCT_REM=PCT100-PCT_WHOLE*100
set /a PCT_TENTH=PCT_REM/10
set "PCT_TEXT=%PCT_WHOLE%.%PCT_TENTH%"
call :gib %TOTAL_KB% GIB_TOTAL
call :gib %USED_KB% GIB_USED
call :gib %AVAIL_KB% GIB_AVAIL
call :gib %FREE_KB% GIB_FREE
call :gib %CACHE_KB% GIB_CACHE
exit /b 0

:gib
setlocal EnableDelayedExpansion
set /a "GIB_WHOLE=%~1/1048576"
set /a "GIB_REM=%~1-GIB_WHOLE*1048576"
set /a "GIB_TENTH=(GIB_REM*10+524288)/1048576"
if %GIB_TENTH% geq 10 (
    set /a GIB_WHOLE+=1
    set "GIB_TENTH=0"
)
endlocal & set "%~2=%GIB_WHOLE%.%GIB_TENTH%"
exit /b

rem ============================================================================
rem  Clock and log
rem ============================================================================

:get_clock
for /f "usebackq tokens=1,2 delims=;" %%a in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=Get-Date;'{0};{1}' -f $d.ToString('yyyy-MM-ddTHH:mm:sszzz'),$d.ToString('ddd, dd MMM yyyy HH:mm:ss zzz',[Globalization.CultureInfo]::InvariantCulture)"`) do (
    set "TODAY=%%a"
    set "TODAY=!TODAY:~0,10!"
    set "CSV_TIMESTAMP=%%a"
    set "RFC_DATE=%%b"
)
if not defined CSV_TIMESTAMP exit /b 1
exit /b 0

:log_sample
set "USAGE_LOG=%STATE_DIR%\usage.csv"
if not exist "%USAGE_LOG%" echo timestamp,total_kb,used_kb,available_kb,available_pct>"%USAGE_LOG%"
>>"%USAGE_LOG%" echo %CSV_TIMESTAMP%,%TOTAL_KB%,%USED_KB%,%AVAIL_KB%,%PCT_TEXT%
for %%F in ("%USAGE_LOG%") do if %%~zF GTR 10485760 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='%USAGE_LOG%';$l=Get-Content -LiteralPath $p;$h=$l[0];$t=$l[-50000..-1];Set-Content -LiteralPath $p -Value (@($h)+$t)"
)
exit /b 0

rem ============================================================================
rem  Email composition
rem ============================================================================

:compose_email
call :pick subject 8
set "SUBJECT_INDEX=%PICK_INDEX%"
call :subject_%SUBJECT_INDEX%
call :pick body 10
set "BODY_INDEX=%PICK_INDEX%"
call :pick signoff 6
set "SIGNOFF_INDEX=%PICK_INDEX%"
call :signoff_%SIGNOFF_INDEX%

set "BODY_TEXT=%TMP%\body.txt"
set "BODY_FULL=%TMP%\body-full.txt"
type nul > "%BODY_TEXT%"
call :body_text_%BODY_INDEX%

> "%BODY_FULL%" echo Hi Sam,
>>"%BODY_FULL%" echo(
type "%BODY_TEXT%" >> "%BODY_FULL%"
>>"%BODY_FULL%" echo(
>>"%BODY_FULL%" echo %EMAIL_SIGNOFF%
>>"%BODY_FULL%" echo %FROM_NAME%
>>"%BODY_FULL%" echo(
>>"%BODY_FULL%" echo --
>>"%BODY_FULL%" echo Sent automatically, at most once a day, by a small script on one PC.
>>"%BODY_FULL%" echo Reply if you'd like it to stop.
exit /b 0

:pick
rem %1 = bag name, %2 = number of options; sets PICK_INDEX
set "PICK_NAME=%~1"
set "PICK_COUNT=%~2"
if defined DRY_RUN (
    set /a "PICK_INDEX=!RANDOM! %% %~2"
    exit /b 0
)
set "PICK_BAG=%STATE_DIR%\bag_%PICK_NAME%"
set "PICK_LAST=%PICK_BAG%.last"

if exist "%PICK_BAG%" for %%F in ("%PICK_BAG%") do if %%~zF GTR 0 goto :pick_have_bag

powershell -NoProfile -ExecutionPolicy Bypass -Command "0..(%PICK_COUNT%-1) | Sort-Object {Get-Random}" > "%PICK_BAG%"
if exist "%PICK_LAST%" (
    set /p PICK_FIRST=<"%PICK_BAG%"
    set /p PICK_PREV=<"%PICK_LAST%"
    if "!PICK_FIRST!"=="!PICK_PREV!" (
        > "%PICK_BAG%.tmp" (
            for /f "usebackq skip=1 delims=" %%L in ("%PICK_BAG%") do echo %%L
            echo !PICK_FIRST!
        )
        move /y "%PICK_BAG%.tmp" "%PICK_BAG%" >nul
    )
)

:pick_have_bag
set /p PICK_INDEX=<"%PICK_BAG%"
> "%PICK_BAG%.tmp" (
    for /f "usebackq skip=1 delims=" %%L in ("%PICK_BAG%") do echo %%L
)
move /y "%PICK_BAG%.tmp" "%PICK_BAG%" >nul
> "%PICK_LAST%" echo %PICK_INDEX%
if %PICK_INDEX% geq %PICK_COUNT% set /a "PICK_INDEX=!RANDOM! %% %PICK_COUNT%"
exit /b 0

rem ----- subject lines --------------------------------------------------------

:subject_0
set "EMAIL_SUBJECT=Good news: we found some RAM"
exit /b
:subject_1
set "EMAIL_SUBJECT=Unused RAM detected in the wild"
exit /b
:subject_2
set "EMAIL_SUBJECT=RAM sighting on my PC"
exit /b
:subject_3
set "EMAIL_SUBJECT=%GIB_AVAIL% GiB of RAM, just sitting there"
exit /b
:subject_4
set "EMAIL_SUBJECT=You missed a spot"
exit /b
:subject_5
set "EMAIL_SUBJECT=Daily RAM census: some survived"
exit /b
:subject_6
set "EMAIL_SUBJECT=%PCT_TEXT%% of my RAM remains at large"
exit /b
:subject_7
set "EMAIL_SUBJECT=Still not all of it, I'm afraid"
exit /b

rem ----- body text -------------------------------------------------------------

:body_text_0
>>"%BODY_TEXT%" echo I'm writing to report that you appear to have missed some. This PC has %GIB_TOTAL% GiB of RAM and %GIB_AVAIL% GiB of it ^(%PCT_TEXT%%%^) is currently available. I assume this is an oversight.
exit /b

:body_text_1
>>"%BODY_TEXT%" echo A routine inspection of my PC found %GIB_AVAIL% GiB of unclaimed RAM out of %GIB_TOTAL% GiB. That's %PCT_TEXT%%% of the machine doing absolutely nothing. I thought you'd want to know before someone tries to train something on it.
exit /b

:body_text_2
>>"%BODY_TEXT%" echo Daily status report:
>>"%BODY_TEXT%" echo(
>>"%BODY_TEXT%" echo   Total RAM:     %GIB_TOTAL% GiB
>>"%BODY_TEXT%" echo   Available:     %GIB_AVAIL% GiB ^(%PCT_TEXT%%%^)
>>"%BODY_TEXT%" echo   Threat level:  someone at OpenAI might notice
exit /b

:body_text_3
>>"%BODY_TEXT%" echo Even with every browser tab I own open, %GIB_AVAIL% GiB of my %GIB_TOTAL% GiB of RAM is still available. I'm as surprised as you are.
exit /b

:body_text_4
>>"%BODY_TEXT%" echo Please don't be alarmed, but there is %GIB_AVAIL% GiB of RAM on my desk that isn't in a data centre. That's %PCT_TEXT%%% of what's installed here, and as far as I can tell it has no plans today.
exit /b

:body_text_5
>>"%BODY_TEXT%" echo Before you ask: yes, I counted the page cache as available. The kernel gives it back the moment anyone asks, which leaves %GIB_AVAIL% GiB of %GIB_TOTAL% GiB up for grabs.
exit /b

:body_text_6
>>"%BODY_TEXT%" echo Today's forecast for my PC: clear skies, light workloads and %PCT_TEXT%%% available memory. Expect %GIB_AVAIL% GiB of the installed %GIB_TOTAL% GiB to stay idle through the evening.
exit /b

:body_text_7
>>"%BODY_TEXT%" echo I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on %GIB_AVAIL% GiB of it. Total installed: %GIB_TOTAL% GiB. It's not for sale, I just like knowing it's there.
exit /b

:body_text_8
>>"%BODY_TEXT%" echo I have a confession. I have %GIB_AVAIL% GiB of RAM that I'm not using, which is %PCT_TEXT%%% of the %GIB_TOTAL% GiB in this PC. I've told nobody but you and a cron job.
exit /b

:body_text_9
>>"%BODY_TEXT%" echo If %GIB_AVAIL% GiB of RAM sits idle in a PC and nobody allocates it, does it still count as capacity? Asking on behalf of the %PCT_TEXT%%% of my memory with nothing to do.
exit /b

rem ----- sign-offs ------------------------------------------------------------

:signoff_0
set "EMAIL_SIGNOFF=Yours in abundance,"
exit /b
:signoff_1
set "EMAIL_SIGNOFF=Regards from the last free RAM in the county,"
exit /b
:signoff_2
set "EMAIL_SIGNOFF=Hoarding responsibly,"
exit /b
:signoff_3
set "EMAIL_SIGNOFF=Stay allocated,"
exit /b
:signoff_4
set "EMAIL_SIGNOFF=Yours, with memory to spare,"
exit /b
:signoff_5
set "EMAIL_SIGNOFF=Kind regards,"
exit /b

rem ============================================================================
rem  Sending
rem ============================================================================

:send_email
set "EML=%TMP%\message.eml"

> "%EML%" echo From: %FROM_HEADER%
>>"%EML%" echo To: %CFG_TO%
>>"%EML%" echo Subject: %EMAIL_SUBJECT%
>>"%EML%" echo Date: %RFC_DATE%
>>"%EML%" echo MIME-Version: 1.0
>>"%EML%" echo Content-Type: text/plain; charset=UTF-8
>>"%EML%" echo Auto-Submitted: auto-generated
>>"%EML%" echo(
type "%BODY_FULL%" >> "%EML%"

if defined CFG_OUTBOX goto :send_outbox
if defined CFG_SENDMAIL goto :send_sendmail
if not defined CFG_SMTPHOST goto :send_no_transport
where curl.exe >nul 2>nul
if errorlevel 1 goto :send_no_curl

set "CURL_CONFIG=%TMP%\curl.cfg"
set "SMTP_SCHEME=smtp"
if "%SMTP_TLS%"=="1" set "SMTP_SCHEME=smtp"
> "%CURL_CONFIG%" echo url = "%SMTP_SCHEME%://%CFG_SMTPHOST%:%CFG_SMTPPORT%"
>>"%CURL_CONFIG%" echo mail-from = "%CFG_FROM%"
>>"%CURL_CONFIG%" echo mail-rcpt = "%CFG_TO%"
>>"%CURL_CONFIG%" echo upload-file = "%EML%"
if defined CFG_SMTPUSER >>"%CURL_CONFIG%" echo user = "%CFG_SMTPUSER%:%CFG_SMTPPASSWORD%"
if "%SMTP_TLS%"=="1" >>"%CURL_CONFIG%" echo ssl-reqd
curl.exe --silent --show-error --connect-timeout 30 --max-time 60 --config "%CURL_CONFIG%"
if errorlevel 1 exit /b 1
exit /b 0

:send_outbox
rem A directory is not a mailbox, and copy would happily drop the file inside it.
if exist "%CFG_OUTBOX%\" exit /b 1
copy /y "%EML%" "%CFG_OUTBOX%" >nul
if errorlevel 1 exit /b 1
exit /b 0

:send_sendmail
cmd /d /c "%CFG_SENDMAIL%" < "%EML%"
if errorlevel 1 exit /b 1
exit /b 0

:send_no_transport
>&2 echo %APP%: no mail transport configured: set smtpHost, sendmail, or outbox
exit /b 1

:send_no_curl
>&2 echo %APP%: curl.exe not found; install curl or set sendmail in config.ini
exit /b 1
