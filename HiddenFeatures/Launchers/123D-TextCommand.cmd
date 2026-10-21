@echo off
REM Execute une commande texte au chargement des add-ins.
REM   Usage : 123D-TextCommand.cmd "Options.List -output C:\Temp\opts.txt"
REM           123D-TextCommand.cmd "? -output C:\Temp\help.txt"
if "%~1"=="" (
    echo Usage : %~nx0 "TextCommand [args] [-output fichier]"
    pause
    exit /b 1
)
start "" "C:\Program Files\Autodesk\123D Design\123D Design.exe" --execute "%~1"
