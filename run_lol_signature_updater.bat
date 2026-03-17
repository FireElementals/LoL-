@echo off
:: Check for admin rights
net session >nul 2>&1
if %errorLevel% == 0 (
    echo Running as Administrator.
) else (
    echo Requesting Administrator Privileges...
    powershell Start-Process "%~f0" -Verb runAs
    exit /b
)

:: Change directory to the location of the script
cd /d "%~dp0"

:: Run the PowerShell script
PowerShell -ExecutionPolicy Bypass -File "%~dp0changemessage.ps1"
pause
