@echo off
:: ggplot Voice Copilot (Multi-LLM) — Launcher Bootstrap
:: This batch file bypasses PowerShell ExecutionPolicy and delegates to launch.ps1
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1"
exit /b %ERRORLEVEL%
