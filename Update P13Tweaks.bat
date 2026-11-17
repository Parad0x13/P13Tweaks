@echo off
rem Double-click to get the newest P13Tweaks (git pull), no PowerShell needed.
rem Run "Link P13Tweaks.bat" once first so the game loads this folder.
title Update P13Tweaks
cd /d "%~dp0"
where git >nul 2>nul
if errorlevel 1 (
    echo Git isn't installed ^(or isn't on PATH^). Install it from https://git-scm.com and try again.
    echo.
    pause
    exit /b
)
git pull
if errorlevel 1 (
    echo The update failed - see the message above.
) else (
    echo Updated. Type /reload in WoW ^(or restart WoW if the version number didn't change^).
)
echo.
pause
