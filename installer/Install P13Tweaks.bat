@echo off
rem Double-click to install P13Tweaks and turn on automatic updates.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-P13Tweaks.ps1" -Install
