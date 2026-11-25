@echo off
rem Double-click once: links this project folder into WoW Forever's AddOns folder
rem (a directory junction, no admin needed), so a "git pull" here updates the game.
rem Safe to run again any time. If the addon ever stops updating, run it again: it says
rem what it found in the AddOns folder (a link, a plain copy, or nothing) and fixes it.
rem Can't find WoW? Drag the World of Warcraft folder onto this file, or paste the path when asked.
rem It also removes leftovers of the old auto-updater (Startup shortcut "P13Tweaks updater",
rem desktop "Update P13Tweaks" shortcut, %LOCALAPPDATA%\P13Tweaks), which ran at every Windows start.
setlocal EnableDelayedExpansion
title Link P13Tweaks
set "HERE=%~dp0"
set "HERE=!HERE:~0,-1!"
set "LINKED=0"
set "SEEN=;"
set "VER=?"
for /f "tokens=2 delims=:" %%V in ('findstr /B /C:"## Version:" "!HERE!\P13Tweaks.toc" 2^>nul') do set "VER=%%V"
set "VER=!VER: =!"

echo P13Tweaks folder: !HERE!  ^(version !VER!^)
call :cleanup

if not "%~1"=="" call :root "%~1"
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
if "!LINKED!"=="0" (
    echo.
    echo Couldn't find WoW Forever ^(a _forever_ folder^) on this PC.
    set "ASK="
    set /p "ASK=Paste your World of Warcraft folder path and press Enter (or just Enter to quit): "
    if defined ASK (
        set "ASK=!ASK:"=!"
        call :root "!ASK!"
    )
)

echo.
if "!LINKED!"=="0" (
    echo Nothing was linked.
) else (
    echo Done. From now on: "git pull" in this folder, then fully restart WoW.
    echo If the addon stops updating again, run link.bat again - it shows what it finds.
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
if exist "!R!\_forever_\" call :link "!R!\_forever_"
exit /b

rem ---- %1 = a _forever_ folder: put the link in its AddOns folder
:link
set "ADDONS=%~1\Interface\AddOns"
set "T=!ADDONS!\P13Tweaks"
echo.
echo WoW Forever AddOns folder: !ADDONS!
if not exist "!ADDONS!\" mkdir "!ADDONS!"
if /i "!T!"=="!HERE!" (
    echo   This folder already is the addon folder - nothing to link.
    set /a LINKED+=1
    exit /b
)
call :describe
if "!KIND!"=="link" (
    if /i "!LT!"=="!HERE!" if exist "!T!\Core.lua" (
        echo   Already linked to this folder - all good.
        set /a LINKED+=1
        exit /b
    )
    echo   Found a link to "!LT!" - pointing it here instead.
    rd "!T!"
)
if "!KIND!"=="folder" (
    set "OLDVER=?"
    for /f "tokens=2 delims=:" %%V in ('findstr /B /C:"## Version:" "!T!\P13Tweaks.toc" 2^>nul') do set "OLDVER=%%V"
    echo   Found a PLAIN FOLDER here ^(version !OLDVER: =!^), not the link.
    echo   Something replaced the link: the old auto-updater, an addon manager
    echo   ^(CurseForge, WowUp^), or a backup/sync tool. Replacing it with the link.
    rd /s /q "!T!"
)
if "!KIND!"=="none" echo   No P13Tweaks here yet.
mklink /J "!T!" "!HERE!" >nul
if exist "!T!\Core.lua" (
    echo   Linked: !T!  -^>  !HERE!
    set /a LINKED+=1
) else (
    echo   Couldn't link !T! - is WoW running? Close it and run this again.
)
exit /b

rem ---- what is at !T!: KIND = link (LT = its target), folder, or none
:describe
set "KIND=none"
set "LT="
set "LINE="
for /f "delims=" %%L in ('dir /AL "!ADDONS!" 2^>nul ^| findstr /L /I /C:" P13Tweaks ["') do set "LINE=%%L"
if defined LINE (
    set "KIND=link"
    set "LT=!LINE:*[=!"
    set "LT=!LT:~0,-1!"
    exit /b
)
if exist "!T!\" set "KIND=folder"
exit /b

rem ---- remove the old copy-based auto-updater, which rewrote AddOns\P13Tweaks at every Windows start
:cleanup
for %%F in ("%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\P13Tweaks updater.lnk" "%USERPROFILE%\Desktop\Update P13Tweaks.lnk" "%OneDrive%\Desktop\Update P13Tweaks.lnk" "%PUBLIC%\Desktop\Update P13Tweaks.lnk") do (
    if exist "%%~F" (
        del /f /q "%%~F"
        echo Removed old auto-updater shortcut: %%~F
    )
)
if exist "%LOCALAPPDATA%\P13Tweaks\" (
    rd /s /q "%LOCALAPPDATA%\P13Tweaks"
    echo Removed old auto-updater folder: %LOCALAPPDATA%\P13Tweaks
)
exit /b
