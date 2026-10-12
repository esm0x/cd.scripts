@echo off
rem Double-click to open the fan control window (asks for administrator rights).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0G5FanControlGui.ps1" %*
