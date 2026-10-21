@echo off
REM Installateur HiddenFeatures - pas d'admin requis (fichiers dans %APPDATA% de l'utilisateur)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-HiddenFeatures.ps1"
pause
