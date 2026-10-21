#Requires -Version 5.1
<#
.SYNOPSIS
    123D Design - HiddenFeatures : active des options internes non exposees dans l'UI.

.DESCRIPTION
    Ecrit des elements <Option> dans les fichiers d'options XML de 123D Design :

      %APPDATA%\Autodesk\123D Design\Options\NMachineSpecificOptions.xml
          <BootstrapOptionsGroup>  (options "restart-required")
      %APPDATA%\Autodesk\123D Design\Autodesk\123D Design\Options\NGlobalOptions.xml
          <UIBaseOptionGroup>      (options UI generales)

    Options appliquees (jeu recommande) :
      BootstrapOptionsGroup : Analytics=0, UpdateCheck=0, FirstLaunch=0
      (AnalyticsAlert reste a 1 = alerte deja acquittee ; 0 la fait reapparaitre)
      UIBaseOptionGroup     : WantToShowTextCommands=1, TrackGoogleAnalytics=0,
                              ShowWelcomeScreenOnStartup=0

    Options facultatives (-DebugEnvironment) :
      UIBaseOptionGroup     : ShowDebugEnvironment=1

    Verification effectuee au runtime (Options.List / Options.Get) sur ce build :
      NuBase10.dll  SHA256 16bc1320024cabcba4526d9970d147a5307309f78f8efcab9b51af8e55cd720f
      Launcher      SHA256 57148e59bdc75d8eb763982ee7e8eba87c3fc8bd37090906b4b8cfd550a37a40

    Aucun binaire n'est modifie. Backup .orig cree a cote de chaque XML avant ecriture.

.PARAMETER Restore
    Restaure les fichiers .xml.orig et quitte.

.PARAMETER SkipTextCommands
    Ne pas activer la fenetre de commandes texte (WantToShowTextCommands).

.PARAMETER KeepTelemetry
    Ne pas desactiver Analytics / TrackGoogleAnalytics / UpdateCheck.

.PARAMETER KeepWelcomeScreen
    Conserver l'ecran d'accueil au demarrage.

.PARAMETER DebugEnvironment
    Active ShowDebugEnvironment=1 (environnement de debug interne - instable, reserve dev).
#>
[CmdletBinding()]
param(
    [switch]$Restore,
    [switch]$SkipTextCommands,
    [switch]$KeepTelemetry,
    [switch]$KeepWelcomeScreen,
    [switch]$DebugEnvironment
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
    throw "APPDATA est vide dans cette session Windows; impossible de construire le chemin des options."
}

$MachineXml = Join-Path $env:APPDATA 'Autodesk\123D Design\Options\NMachineSpecificOptions.xml'
$GlobalXml  = Join-Path $env:APPDATA 'Autodesk\123D Design\Autodesk\123D Design\Options\NGlobalOptions.xml'

function Read-Utf16File([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return [System.Text.Encoding]::Unicode.GetString($bytes).TrimStart([char]0xFEFF)
}

function Write-Utf16File([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::Unicode.GetBytes($Content))
}

function Test-ValidXml([string]$Content, [string]$Label) {
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($Content)
    } catch { throw "$Label : XML invalide - $($_.Exception.Message)" }
}

# Insere ou met a jour un element <OptionId .../> dans un element <Group ...>...</Group>
function Set-OptionElement {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][hashtable]$Option   # Id, Value, UserName, ToolTip
    )
    $id = [regex]::Escape($Option.Id)
    $groupRe = [regex]"(?s)(<$GroupName\b[^>]*>)(.*?)(</$GroupName>)"
    $m = $groupRe.Match($Content)
    if (-not $m.Success) { throw "Groupe <$GroupName> introuvable." }
    $body = $m.Groups[2].Value

    if ($body -match "<$id\b[^>]*>") {
        # element existant : met a jour Value (et attributs UserName/ToolTip si fournis)
        $body = [regex]::Replace($body, "(<$id\b[^>]*\bValue\s*=\s*"")[^""]*("")", "`${1}$($Option.Value)`${2}")
        if ($Option.UserName) {
            if ($body -match "<$id\b[^>]*\bUserName\s*=") {
                $body = [regex]::Replace($body, "(<$id\b[^>]*\bUserName\s*=\s*"")[^""]*("")", "`${1}$($Option.UserName)`${2}")
            }
        }
    } else {
        $attrs = ''
        if ($Option.ToolTip)  { $attrs += ' ToolTip="'  + $Option.ToolTip  + '"' }
        if ($Option.UserName) { $attrs += ' UserName="' + $Option.UserName + '"' }
        $body = "    <$($Option.Id)$attrs Value=`"$($Option.Value)`"/>`r`n" + $body
    }
    return $Content.Substring(0, $m.Groups[2].Index) + $body + $Content.Substring($m.Groups[2].Index + $m.Groups[2].Length)
}

# Cree l'element groupe s'il n'existe pas encore
function Ensure-Group {
    param([Parameter(Mandatory)][string]$Content, [Parameter(Mandatory)][string]$GroupName,
          [Parameter(Mandatory)][string]$GroupAttrs)
    if ($Content -match "<$GroupName\b") { return $Content }
    $insert = "  <$GroupName $GroupAttrs>`r`n  </$GroupName>`r`n"
    if ($Content -notmatch '(?s)</OptionGroups>') { throw "Balise </OptionGroups> introuvable." }
    return $Content -replace '(?s)</OptionGroups>', ($insert + '</OptionGroups>')
}

function Backup-Once([string]$Path) {
    $bak = "$Path.orig"
    if (-not (Test-Path $bak)) {
        Copy-Item $Path $bak -Force
        Write-Host "  Backup : $bak"
    } else {
        Write-Host "  Backup existant conserve : $bak"
    }
}

Write-Host "=== 123D Design - HiddenFeatures ===" -ForegroundColor Cyan

$running = Get-Process -Name '123D Design','123D10' -ErrorAction SilentlyContinue
if ($running) { throw "123D Design est en cours d'execution. Fermez-le avant application ou restauration." }

# ---- Mode restauration -------------------------------------------------------
if ($Restore) {
    foreach ($f in @($MachineXml, $GlobalXml)) {
        $bak = "$f.orig"
        if (Test-Path $bak) {
            Copy-Item $bak $f -Force
            Remove-Item $bak -Force
            Write-Host "Restaure : $f"
        } else {
            Write-Host "Pas de backup pour $f (rien a restaurer)"
        }
    }
    Write-Host "Restauration terminee."
    return
}

# ---- Verification des cibles --------------------------------------------------
foreach ($f in @($MachineXml, $GlobalXml)) {
    if (-not (Test-Path $f)) { throw "Fichier d'options introuvable : $f`nLancez 123D Design une premiere fois pour le generer, puis relancez ce script." }
}

# ---- Options Bootstrap (NMachineSpecificOptions.xml) --------------------------
$bootstrapOptions = @()
if (-not $KeepTelemetry) {
    # NB : AnalyticsAlert reste a 1 (valeur = "alerte privacy deja acquittee" ;
    # la remettre a 0 fait reapparaitre le dialogue "Analytics" au lancement).
    $bootstrapOptions += @{ Id = 'Analytics';      Value = '0'; UserName = 'Analytics' }
    $bootstrapOptions += @{ Id = 'UpdateCheck';    Value = '0'; UserName = 'UpdateCheck' }
    $bootstrapOptions += @{ Id = 'FirstLaunch';    Value = '0'; UserName = 'FirstLaunch' }
}

$machine = Read-Utf16File $MachineXml
Test-ValidXml $machine 'NMachineSpecificOptions.xml'
foreach ($o in $bootstrapOptions) {
    $machine = Set-OptionElement -Content $machine -GroupName 'BootstrapOptionsGroup' -Option $o
}

# ---- Options UIBase (NGlobalOptions.xml) --------------------------------------
$uiOptions = @()
if (-not $SkipTextCommands) {
    $uiOptions += @{ Id = 'WantToShowTextCommands'; Value = '1';
                     ToolTip = 'Should the text command window be shown';
                     UserName = 'Show text commands' }
}
if (-not $KeepTelemetry) {
    $uiOptions += @{ Id = 'TrackGoogleAnalytics'; Value = '0';
                     ToolTip = 'Should command usage be tracked using Google Analytics';
                     UserName = 'Track Google Analytics' }
}
if (-not $KeepWelcomeScreen) {
    $uiOptions += @{ Id = 'ShowWelcomeScreenOnStartup'; Value = '0';
                     ToolTip = 'Should the Welcome Screen be sstartup';
                     UserName = 'Show Welcome Screen On startup' }
}
if ($DebugEnvironment) {
    $uiOptions += @{ Id = 'ShowDebugEnvironment'; Value = '1';
                     ToolTip = 'Should the Debug Environment be shown';
                     UserName = 'Show Debug Environment' }
}

$global_ = Read-Utf16File $GlobalXml
Test-ValidXml $global_ 'NGlobalOptions.xml'
if ($uiOptions.Count -gt 0) {
    $global_ = Ensure-Group -Content $global_ -GroupName 'UIBaseOptionGroup' `
        -GroupAttrs 'SchemaVersion="1" ToolTip="Preferences controlling general UI behavior" UserName="General"'
    foreach ($o in $uiOptions) {
        $global_ = Set-OptionElement -Content $global_ -GroupName 'UIBaseOptionGroup' -Option $o
    }
}

# ---- Ecriture + verification ---------------------------------------------------
Test-ValidXml $machine 'NMachineSpecificOptions.xml (apres modification)'
Test-ValidXml $global_  'NGlobalOptions.xml (apres modification)'

if ($bootstrapOptions.Count -gt 0) { Backup-Once $MachineXml }
if ($uiOptions.Count -gt 0)       { Backup-Once $GlobalXml }

if ($bootstrapOptions.Count -gt 0) { Write-Utf16File $MachineXml $machine; Write-Host "Ecrit : $MachineXml" }
if ($uiOptions.Count -gt 0)       { Write-Utf16File $GlobalXml  $global_;  Write-Host "Ecrit : $GlobalXml" }

# verification de relecture
foreach ($o in $bootstrapOptions) {
    $cur = Read-Utf16File $MachineXml
    if ($cur -notmatch "<$($o.Id)\b[^>]*Value=`"$($o.Value)`"") { throw "Verification echouee : $($o.Id)" }
}
foreach ($o in $uiOptions) {
    $cur = Read-Utf16File $GlobalXml
    if ($cur -notmatch "<$($o.Id)\b[^>]*Value=`"$($o.Value)`"") { throw "Verification echouee : $($o.Id)" }
}

Write-Host ""
Write-Host "Options appliquees :" -ForegroundColor Green
foreach ($o in $bootstrapOptions) { Write-Host ("  [Bootstrap] {0,-32} = {1}" -f $o.Id, $o.Value) }
foreach ($o in $uiOptions)        { Write-Host ("  [UIBase   ] {0,-32} = {1}" -f $o.Id, $o.Value) }
Write-Host ""
Write-Host "Redemarrez 123D Design pour prendre en compte les changements."
Write-Host "Rollback : Remove-HiddenFeatures.cmd"
