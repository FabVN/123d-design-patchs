@echo off
REM Restaure les fichiers d'options XML d'origine (backups .orig)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-HiddenFeatures.ps1" -Restore
pause
