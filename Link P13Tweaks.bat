@echo off
rem Same job as link.ps1, for PCs that block PowerShell scripts: just double-click it.
rem Links this project folder into each game's AddOns folder (directory junction, no admin needed),
rem so "Update P13Tweaks.bat" (git pull) here updates the game.
rem   _forever_  = WoW Forever      (loads P13Tweaks.toc)
rem   _classic_  = MoP Classic      (loads P13Tweaks_Mists.toc)
rem Finds WoW via the registry and the usual folders on every drive. A plain copied
rem AddOns\P13Tweaks folder is replaced by the link. Safe to run again any time.
setlocal EnableDelayedExpansion
title Link P13Tweaks
set "HERE=%~dp0"
set "HERE=!HERE:~0,-1!"
set "LINKED=0"
set "SEEN=;"

for %%K in ("HKLM\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft" "HKLM\SOFTWARE\Blizzard Entertainment\World of Warcraft") do (
    for /f "tokens=2,*" %%A in ('reg query %%K /v InstallPath 2^>nul ^| findstr /i "InstallPath"') do call :root "%%B"
)
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\" (
        call :root "%%D:\Program Files (x86)\World of Warcraft"
        call :root "%%D:\Program Files\World of Warcraft"
        call :root "%%D:\World of Warcraft"
        call :root "%%D:\Games\World of Warcraft"
    )
)

echo.
if "!LINKED!"=="0" (
    echo Couldn't find World of Warcraft ^(_forever_ or _classic_^) on this PC.
) else (
    echo Done. Double-click "Update P13Tweaks.bat" to get new versions, then restart WoW.
)
echo.
pause
exit /b

rem ---- %1 = a WoW folder (or a _flavor_ folder inside it, as the registry sometimes gives)
:root
set "R=%~1"
if "!R:~-1!"=="\" set "R=!R:~0,-1!"
for %%P in ("!R!") do (
    set "LEAF=%%~nxP"
    set "PARENT=%%~dpP"
)
if "!LEAF:~0,1!!LEAF:~-1!"=="__" set "R=!PARENT:~0,-1!"
set "TEST=!SEEN:;%R%;=!"
if not "!TEST!"=="!SEEN!" exit /b
set "SEEN=!SEEN!!R!;"
call :flavor "!R!\_forever_"
call :flavor "!R!\_classic_"
exit /b

rem ---- %1 = a _flavor_ folder: put the link in its AddOns folder
:flavor
set "ADDONS=%~1\Interface\AddOns"
if not exist "!ADDONS!\" exit /b
set "T=!ADDONS!\P13Tweaks"
if /i "!T!"=="!HERE!" (
    echo This folder already is !T! - nothing to link.
    set /a LINKED+=1
    exit /b
)
if exist "!T!" call :remove
mklink /J "!T!" "!HERE!" >nul
if errorlevel 1 (
    echo Couldn't link !T!
) else (
    echo Linked !T!
    set /a LINKED+=1
)
exit /b

rem ---- remove whatever is at !T!: a link loses only the link, a plain copy is deleted
:remove
dir /AL /B "!ADDONS!" 2>nul | findstr /X /I "P13Tweaks" >nul
if not errorlevel 1 (
    rd "!T!"
    exit /b
)
rd /s /q "!T!"
exit /b
