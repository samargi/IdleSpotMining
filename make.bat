@echo off
setlocal

REM === CONFIG ===
set "TASKNAME=IdleSpotMining"
set "SCRIPT=C:\Scripts\IdleSpotMining.ps1"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "LOGFILE=C:\Scripts\miner-switch.log"
REM käytä kirjautunutta käyttäjää oletuksena
set "RUNUSER=%COMPUTERNAME%\%USERNAME%"

if "%~1"=="" goto USAGE
set "CMD=%~1"
shift

if /I "%CMD%"=="create"        goto NEED_ELEVATE_CREATE
if /I "%CMD%"=="create-nopass" goto NEED_ELEVATE_CREATE_NOPASS
if /I "%CMD%"=="status"        goto STATUS
if /I "%CMD%"=="run"           goto RUN
if /I "%CMD%"=="end"           goto END_TASK
if /I "%CMD%"=="delete"        goto NEED_ELEVATE_DELETE
if /I "%CMD%"=="tail"          goto TAIL
if /I "%CMD%"=="who"           goto WHO

echo Unknown command: %CMD%
goto USAGE

:STATUS
schtasks /query /tn "%TASKNAME%" /fo LIST /v
goto END

:RUN
schtasks /run /tn "%TASKNAME%"
goto END

:END_TASK
schtasks /end /tn "%TASKNAME%" 2>nul
goto END

:TAIL
if not exist "%LOGFILE%" ( 2> "%LOGFILE%" echo. )
"%POWERSHELL%" -NoProfile -Command "Get-Content -Path '%LOGFILE%' -Tail 50 -Wait"
goto END

:WHO
schtasks /query /tn "%TASKNAME%" /fo LIST /v | findstr /i "Run As User Status Last Run Time Last Result"
goto END

REM === CREATE (elevates, asks password) ===
:NEED_ELEVATE_CREATE
set "XML=%TEMP%\%TASKNAME%.xml"
call :WRITE_XML "%XML%"
set "TMPBAT=%TEMP%\mk_create_%TASKNAME%.cmd"
> "%TMPBAT%" echo @echo off
>>"%TMPBAT%" echo schtasks /create /tn "%TASKNAME%" /xml "%XML%" /ru "%RUNUSER%" /rp *
echo Elevating to create task (will prompt for password)...
powershell -NoProfile -Command ^
 "Start-Process -FilePath '%ComSpec%' -Verb RunAs -ArgumentList '/k','""%TMPBAT%""'"
goto END

REM === CREATE (no password; uses current token) ===
:NEED_ELEVATE_CREATE_NOPASS
set "XML=%TEMP%\%TASKNAME%.xml"
call :WRITE_XML "%XML%"
schtasks /create /tn "%TASKNAME%" /xml "%XML%" /ru "%RUNUSER%"
goto END

REM === DELETE (elevates) ===
:NEED_ELEVATE_DELETE
set "TMPDEL=%TEMP%\mk_del_%TASKNAME%.cmd"
> "%TMPDEL%" echo @echo off
>>"%TMPDEL%" echo schtasks /end /tn "%TASKNAME%" 2^>nul
>>"%TMPDEL%" echo schtasks /delete /tn "%TASKNAME%" /f
echo Elevating to delete task...
powershell -NoProfile -Command ^
 "Start-Process -FilePath '%ComSpec%' -Verb RunAs -ArgumentList '/k','""%TMPDEL%""'"
goto END

REM === XML writer (LOGON + 4x TimeTrigger at :00/:15/:30/:45, each repeats hourly) ===
:WRITE_XML
set "OUT=%~1"
>  "%OUT%" echo ^<?xml version="1.0" encoding="UTF-16"?^>
>> "%OUT%" echo ^<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"^>
>> "%OUT%" echo   ^<RegistrationInfo^>^<Description^>IdleSpotMining^</Description^>^</RegistrationInfo^>
>> "%OUT%" echo   ^<Triggers^>
REM -- Logon trigger
>> "%OUT%" echo     ^<LogonTrigger^>^<Enabled^>true^</Enabled^>^</LogonTrigger^>
REM -- :00 every hour
>> "%OUT%" echo     ^<TimeTrigger^>
>> "%OUT%" echo       ^<StartBoundary^>2000-01-01T00:00:00^</StartBoundary^>
>> "%OUT%" echo       ^<Enabled^>true^</Enabled^>
>> "%OUT%" echo       ^<Repetition^>^<Interval^>PT1H^</Interval^>^<StopAtDurationEnd^>false^</StopAtDurationEnd^>^</Repetition^>
>> "%OUT%" echo     ^</TimeTrigger^>
REM -- :15 every hour
>> "%OUT%" echo     ^<TimeTrigger^>
>> "%OUT%" echo       ^<StartBoundary^>2000-01-01T00:15:00^</StartBoundary^>
>> "%OUT%" echo       ^<Enabled^>true^</Enabled^>
>> "%OUT%" echo       ^<Repetition^>^<Interval^>PT1H^</Interval^>^<StopAtDurationEnd^>false^</StopAtDurationEnd^>^</Repetition^>
>> "%OUT%" echo     ^</TimeTrigger^>
REM -- :30 every hour
>> "%OUT%" echo     ^<TimeTrigger^>
>> "%OUT%" echo       ^<StartBoundary^>2000-01-01T00:30:00^</StartBoundary^>
>> "%OUT%" echo       ^<Enabled^>true^</Enabled^>
>> "%OUT%" echo       ^<Repetition^>^<Interval^>PT1H^</Interval^>^<StopAtDurationEnd^>false^</StopAtDurationEnd^>^</Repetition^>
>> "%OUT%" echo     ^</TimeTrigger^>
REM -- :45 every hour
>> "%OUT%" echo     ^<TimeTrigger^>
>> "%OUT%" echo       ^<StartBoundary^>2000-01-01T00:45:00^</StartBoundary^>
>> "%OUT%" echo       ^<Enabled^>true^</Enabled^>
>> "%OUT%" echo       ^<Repetition^>^<Interval^>PT1H^</Interval^>^<StopAtDurationEnd^>false^</StopAtDurationEnd^>^</Repetition^>
>> "%OUT%" echo     ^</TimeTrigger^>
>> "%OUT%" echo   ^</Triggers^>
>> "%OUT%" echo   ^<Principals^>
>> "%OUT%" echo     ^<Principal id="Author"^>^<RunLevel^>HighestAvailable^</RunLevel^>^</Principal^>
>> "%OUT%" echo   ^</Principals^>
>> "%OUT%" echo   ^<Settings^>
>> "%OUT%" echo     ^<MultipleInstancesPolicy^>IgnoreNew^</MultipleInstancesPolicy^>
>> "%OUT%" echo     ^<DisallowStartIfOnBatteries^>false^</DisallowStartIfOnBatteries^>
>> "%OUT%" echo     ^<StopIfGoingOnBatteries^>false^</StopIfGoingOnBatteries^>
>> "%OUT%" echo     ^<StartWhenAvailable^>true^</StartWhenAvailable^>
>> "%OUT%" echo     ^<AllowStartOnDemand^>true^</AllowStartOnDemand^>
>> "%OUT%" echo     ^<Enabled^>true^</Enabled^>
>> "%OUT%" echo     ^<Hidden^>false^</Hidden^>
>> "%OUT%" echo     ^<RunOnlyIfIdle^>false^</RunOnlyIfIdle^>
>> "%OUT%" echo     ^<ExecutionTimeLimit^>PT10M^</ExecutionTimeLimit^>
>> "%OUT%" echo   ^</Settings^>
>> "%OUT%" echo   ^<Actions Context="Author"^>
>> "%OUT%" echo     ^<Exec^>
>> "%OUT%" echo       ^<Command^>%POWERSHELL%^</Command^>
>> "%OUT%" echo       ^<Arguments^>-NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"^</Arguments^>
>> "%OUT%" echo       ^<WorkingDirectory^>C:\Scripts^</WorkingDirectory^>
>> "%OUT%" echo     ^</Exec^>
>> "%OUT%" echo   ^</Actions^>
>> "%OUT%" echo ^</Task^>
exit /b 0

:USAGE
echo Usage: make ^<command^>
echo   create            Create task (elevates, asks password)
echo   create-nopass     Create task without password (current token)
echo   status            Show task status
echo   run               Run once now
echo   end               Stop running instance
echo   delete            Delete task (elevates)
echo   tail              Follow log file
echo   who               Show RunAs/Last run/Result
goto END

:END
endlocal
