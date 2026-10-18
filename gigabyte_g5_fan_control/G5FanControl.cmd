@echo off
rem Double-click to open the fan control menu (asks for administrator rights).
rem Arguments are passed through, e.g.:  G5FanControl.cmd set 0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0G5FanControl.ps1" %*
