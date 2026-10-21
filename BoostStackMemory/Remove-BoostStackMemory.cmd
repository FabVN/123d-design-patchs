@echo off
REM Self-elevating rollback: restores the original exe from backup
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    set "_123D_SELF=%~f0"
    powershell -NoProfile -Command "Start-Process -FilePath $env:_123D_SELF -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-BoostStackMemory.ps1" -Restore
pause
