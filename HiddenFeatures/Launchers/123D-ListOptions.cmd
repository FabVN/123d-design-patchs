@echo off
REM Dump toutes les options internes dans %TEMP%\123D_options.txt puis ouvre le fichier
start "" "C:\Program Files\Autodesk\123D Design\123D Design.exe" --execute "Options.List -output %TEMP%\123D_options.txt"
echo Le fichier %TEMP%\123D_options.txt sera cree au chargement de l'application.
pause
