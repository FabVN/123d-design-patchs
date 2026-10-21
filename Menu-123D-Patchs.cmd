@echo off
REM ============================================================
REM  123D Design - Menu du kit de patchs hors-ligne
REM  Aucun droit admin requis ici : chaque installateur demande
REM  l'elevation UAC lui-meme si necessaire.
REM ============================================================
setlocal EnableDelayedExpansion
set "KIT=%~dp0"
cd /d "%KIT%"

:MENU
cls
echo ============================================================
echo  123D Design - Kit de patchs hors-ligne
echo ============================================================
echo.
echo  IMPORTANT : fermez 123D Design avant d'appliquer ou de
echo  retirer un patch.
echo.
echo  [1] BoostStackMemory
echo      Reserve de pile de "123D Design.exe" : ~9,5 Mo vers 256 Mo.
echo      Corrige les crashs "stack overflow" sur les operations
echo      lourdes (booleens, annulations profondes).
echo.
echo  [2] CrashFix (v4)
echo      Corrige les crashs "null activeCommand" de Na123DUI10.dll
echo      apres une commande (Snap, menus, barre d'outils).
echo      Patche aussi la reserve de pile du lanceur.
echo.
echo  [3] FrenchLanguage
echo      Debloque et active le francais (fr-FR) : NsBase10.dll,
echo      NuBase10.dll, fichiers .qm, option XML, tooltip flyout.
echo.
echo  [4] HiddenFeatures
echo      Options internes (XML utilisateur seulement) :
echo      telemetry / mises a jour / ecran d'accueil OFF,
echo      fenetre de commandes texte ON.
echo.
echo  [R] Afficher un README              [Q] Quitter
echo.
set "_CHOIX="
set /p "_CHOIX=Votre choix : "
if /i "%_CHOIX%"=="1" (call :SUB BoostStackMemory BoostStackMemory & goto MENU)
if /i "%_CHOIX%"=="2" (call :SUB CrashFix 123DFix & goto MENU)
if /i "%_CHOIX%"=="3" (call :SUB FrenchLanguage FrenchLanguage & goto MENU)
if /i "%_CHOIX%"=="4" (call :SUB HiddenFeatures HiddenFeatures & goto MENU)
if /i "%_CHOIX%"=="R" goto RDMENU
if /i "%_CHOIX%"=="Q" goto END
goto MENU

REM ------------------------------------------------ sous-menu patch
:SUB
set "_DIR=%~1"
set "_PKG=%~2"
:SUBLOOP
cls
echo ============================================================
echo  Patch : %_PKG%   (dossier %_DIR%\)
echo ============================================================
echo.
if /i "%_PKG%"=="FrenchLanguage" (
    echo  [P] Preflight : controle tous les pre-requis
    echo      sans rien modifier ^(-PreflightOnly^)
    echo.
)
echo  [I] Installer / appliquer le patch
echo  [M] Afficher le README de ce patch
echo  [D] Desinstaller / restaurer l'original
echo  [B] Retour au menu principal
echo.
set "_ACT="
set /p "_ACT=Action : "
if /i "%_ACT%"=="P" if /i "%_PKG%"=="FrenchLanguage" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%KIT%%_DIR%\Apply-FrenchLanguage.ps1" -PreflightOnly
    echo.
    pause
    goto SUBLOOP
)
if /i "%_ACT%"=="I" (
    call :RUN "%_DIR%" "Install-%_PKG%.cmd"
    goto SUBLOOP
)
if /i "%_ACT%"=="M" (
    call :README "%_DIR%"
    goto SUBLOOP
)
if /i "%_ACT%"=="D" (
    call :RUN "%_DIR%" "Remove-%_PKG%.cmd"
    goto SUBLOOP
)
if /i "%_ACT%"=="B" exit /b
goto SUBLOOP

REM ------------------------------------------------ choix du README
:RDMENU
cls
echo ============================================================
echo  Documentation des patchs
echo ============================================================
echo.
echo  [1] BoostStackMemory
echo  [2] CrashFix
echo  [3] FrenchLanguage
echo  [4] HiddenFeatures
echo  [B] Retour
echo.
set "_R="
set /p "_R=Quel README ? "
if /i "%_R%"=="1" (call :README BoostStackMemory & goto RDMENU)
if /i "%_R%"=="2" (call :README CrashFix & goto RDMENU)
if /i "%_R%"=="3" (call :README FrenchLanguage & goto RDMENU)
if /i "%_R%"=="4" (call :README HiddenFeatures & goto RDMENU)
if /i "%_R%"=="B" goto MENU
goto RDMENU

REM ------------------------------------------------ utilitaires
:RUN
if exist "%KIT%%~1\%~2" (
    call "%KIT%%~1\%~2"
) else (
    echo.
    echo  ERREUR : fichier introuvable : %KIT%%~1\%~2
    echo  Copiez le dossier du patch complet dans ce kit.
    pause
)
exit /b

:README
if exist "%KIT%%~1\README.txt" (
    more "%KIT%%~1\README.txt"
) else (
    echo.
    echo  README absent : %KIT%%~1\README.txt
)
echo.
pause
exit /b

:END
endlocal
exit /b 0
