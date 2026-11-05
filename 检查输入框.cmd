@echo off
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0whale-shot.ps1" -TestComposer
echo.
echo This check does not paste, type, or send anything. Results are also saved in whale-shot.log.
pause
