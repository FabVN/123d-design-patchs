#Requires -Version 5.1
<#
.SYNOPSIS
    123D Design - FrenchLanguage : debloque la langue fr-FR et l'active.

.DESCRIPTION
    Le build de 123D Design livre les StringTable\fr-FR\*.xml complets, mais
    NsBase10.dll contient une whitelist de langues "supportees" qui exclut
    fr-FR (Autodesk n'a pas livre qt_fr.qm). Au demarrage,
    BootstrapOptionGroup::userLanguage() detecte une valeur non whitelistee
    et REECRIT l'option a "en-US" -> le choix fr-FR n'est jamais pris en
    compte, quelle que soit la valeur ecrite dans le XML.

    Ce patch :

      1) Neutralise Ns::BootstrapOptionGroup::isLanguageSupported
         (NsBase10.dll, VA 0x1800524D0 / offset fichier 0x518D0) :
            original : 40 53 48 83 EC 30   push rbx ; sub rsp,30h
            patch    : B8 01 00 00 00 C3   mov eax,1 ; ret
         -> toute valeur de langue devient "supportee", fr-FR inclus.

      2) NuBase10.dll - redirection du chargeur Qt (.qm) :
         Le chargeur code en dur la map langue -> fichiers
         (ja-JP/zh-CN/tr-TR/es-ES -> qml_*.qm + qt_*.qm ; en-US -> rien)
         et verifie ensuite un hash de contenu contre des constantes
         signees Autodesk avant d'appeler installTranslator.
         Patchs (offsets fichier) :
            0x448888 : 'qml_es.qm' -> 'qml_fr.qm'   (UTF-16, taille identique)
            0x4488A0 : 'qt_es.qm'  -> 'qt_fr.qm'    (UTF-16, taille identique)
            0x4488B8 : 'es-ES'     -> 'fr-FR'       (UTF-16, taille identique)
            0x10351D : 0F 94 C3    -> B3 01 90      (sete bl -> mov bl,1 ; nop)
         -> fr-FR charge qml_fr.qm + qt_fr.qm et le hash-check est
            neutralise (nos .qm ne sont pas signes Autodesk).
         Effet de bord documente : la vraie langue es-ES ne charge plus
         ses .qm (elle conserve ses StringTable XML).

      3) Ecrit <userLanguageOptionId Value="fr-FR"/> dans
         %APPDATA%\Autodesk\123D Design\Options\NMachineSpecificOptions.xml
         sous <BootstrapOptionsGroup> (UTF-16 preserve, idempotent).

      4) Installe qm\*.qm -> StringTable\qtTranslations\ :
         l'UI visible de 123D Design est QML (Qt 4.8). Les traductions
         QML sont chargees depuis qtTranslations\qml_<lang>.qm ; le build
         ne livre que es/ja/tr/zh_CN. Le fichier qml_fr.qm fourni ici est
         genere a partir de la structure officielle qml_es.qm avec des
         traductions francaises (menus, barre d'outils, palettes,
         dialogues). qt_fr.qm, s'il est present, traduit les chaines
         du framework Qt (boites de dialogue fichier, boutons communs).

      5) qrc_Resources.rcc - tooltip des boutons de flyout :
         SecondaryToolbarButton.qml (ressource compressee) mesurait la
         largeur sur toolHelptext, souvent vide. Le patch mesure maintenant
         tooltext et reduit la hauteur de 38 a 24*scaleFactor.
         La zone RCC est bornee et verifiee avant/apres ecriture : longueur
         compressee 892, slot zlib 888 octets, source QML 3015 -> 3011 octets.

    Effet attendu : l'UI charge StringTable\fr-FR\*.xml (existant) ET
    qml_fr.qm -> menus, barres d'outils et dialogues QML en francais.

    Verification effectuee sur :
      NsBase10.dll  SHA256 8c04ce615f811c3327c26060830b1b2f3522f901c4779798940a9b73cbcfb567

    Backups : *.orig crees a cote de chaque fichier avant modification.

.PARAMETER Restore
    Restaure les fichiers sauvegardes (.orig), supprime les .qm francais
    installes par ce patch, puis quitte.

.PARAMETER SkipOptionWrite
    Patche la DLL sans toucher au fichier d'options (la langue restera celle
    actuellement configuree ; utile pour tester d'autres langues).

.PARAMETER PreflightOnly
    Verifie les pre-requis sans modifier les fichiers de l'installation.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\Autodesk\123D Design',
    [switch]$Restore,
    [switch]$SkipOptionWrite,
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    throw "PSScriptRoot est vide. Lancez le script avec -File ou Install-FrenchLanguage.cmd."
}
if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
    throw "APPDATA est vide dans cette session Windows; impossible de construire le chemin des options."
}

$DllPath    = Join-Path $InstallDir 'NsBase10.dll'
$NuBasePath = Join-Path $InstallDir 'NuBase10.dll'
$MachineXml = Join-Path $env:APPDATA 'Autodesk\123D Design\Options\NMachineSpecificOptions.xml'
$GlobalXml  = Join-Path $env:APPDATA 'Autodesk\123D Design\Autodesk\123D Design\Options\NGlobalOptions.xml'
$QtDir      = Join-Path $InstallDir 'StringTable\qtTranslations'
$QmSource   = Join-Path $PSScriptRoot 'qm'
$RccPath    = Join-Path $InstallDir 'Fusion\UI\FusionUI\Adaptations\QT\res\qrc_Resources.rcc'
$RequiredQmHashes = @{
    'qml_fr.qm' = '70229D386B463F44B2F73C176700F5428D5608E168C58CF918F2C8F1AD1D05C0'
    'qt_fr.qm'  = '9EEEB060F76BCD2085429DC8641C51C272694EAC6AAF58438BBF7F8ABAD23854'
}

$PatchOffset   = 0x518D0   # file offset de isLanguageSupported (VA 0x1800524D0)
$ExpectedBytes = [byte[]](0x40,0x53,0x48,0x83,0xEC,0x30)   # push rbx ; sub rsp,30h
$PatchedBytes  = [byte[]](0xB8,0x01,0x00,0x00,0x00,0xC3)   # mov eax,1 ; ret
$OrigHash      = '8c04ce615f811c3327c26060830b1b2f3522f901c4779798940a9b73cbcfb567'

# NuBase10.dll : table de patchs "es -> fr" + bypass du hash-check des .qm
# Chaque entree : offset fichier, octets attendus (original), octets patch.
$NuPatches = @(
    @{ Name = "nom fichier qml_es.qm -> qml_fr.qm"
       Off  = 0x448888
       Old  = [byte[]](0x71,0x00,0x6D,0x00,0x6C,0x00,0x5F,0x00,0x65,0x00,0x73,0x00,0x2E,0x00,0x71,0x00,0x6D,0x00)  # 'qml_es.qm'
       New  = [byte[]](0x71,0x00,0x6D,0x00,0x6C,0x00,0x5F,0x00,0x66,0x00,0x72,0x00,0x2E,0x00,0x71,0x00,0x6D,0x00)  # 'qml_fr.qm'
    },
    @{ Name = "nom fichier qt_es.qm -> qt_fr.qm"
       Off  = 0x4488A0
       Old  = [byte[]](0x71,0x00,0x74,0x00,0x5F,0x00,0x65,0x00,0x73,0x00,0x2E,0x00,0x71,0x00,0x6D,0x00)              # 'qt_es.qm'
       New  = [byte[]](0x71,0x00,0x74,0x00,0x5F,0x00,0x66,0x00,0x72,0x00,0x2E,0x00,0x71,0x00,0x6D,0x00)              # 'qt_fr.qm'
    },
    @{ Name = "langue es-ES -> fr-FR (map chargeur + verif)"
       Off  = 0x4488B8
       Old  = [byte[]](0x65,0x00,0x73,0x00,0x2D,0x00,0x45,0x00,0x53,0x00)                                            # 'es-ES'
       New  = [byte[]](0x66,0x00,0x72,0x00,0x2D,0x00,0x46,0x00,0x52,0x00)                                            # 'fr-FR'
    },
    @{ Name = "hash-check .qm toujours vrai (sete bl -> mov bl,1; nop)"
       Off  = 0x10351D
       Old  = [byte[]](0x0F,0x94,0xC3)                                                                              # sete bl
       New  = [byte[]](0xB3,0x01,0x90)                                                                              # mov bl,1 ; nop
    }
)

Write-Host "=== 123D Design - FrenchLanguage ===" -ForegroundColor Cyan

function Backup-Once([string]$Path) {
    $bak = "$Path.orig"
    if (-not (Test-Path $bak)) {
        Copy-Item $Path $bak -Force
        Write-Host "  Backup : $bak"
    } else {
        Write-Host "  Backup existant conserve : $bak"
    }
}

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

function Get-RccAdlerBytes([byte[]]$Data) {
    [long]$s1 = 1
    [long]$s2 = 0
    foreach ($value in $Data) {
        $s1 = ($s1 + $value) % 65521
        $s2 = ($s2 + $s1) % 65521
    }
    $bytes = [BitConverter]::GetBytes([uint32]($s2 * 65536 + $s1))
    [Array]::Reverse($bytes)
    return ,$bytes
}

function Expand-RccZlibSlot([byte[]]$Slot, [int]$ExpectedLength) {
    if ($Slot.Length -lt 8 -or $Slot[0] -ne 0x78 -or $Slot[1] -ne 0x9C) {
        throw "En-tete zlib RCC inattendu."
    }

    # Le slot reserve peut contenir quelques octets de remplissage apres le flux.
    for ($candidateLength = $Slot.Length; $candidateLength -ge 6; $candidateLength--) {
        $candidate = New-Object byte[] $candidateLength
        [Array]::Copy($Slot, 0, $candidate, 0, $candidateLength)
        $rawLength = $candidateLength - 6
        $rawDeflate = New-Object byte[] $rawLength
        if ($rawLength -gt 0) {
            [Array]::Copy($candidate, 2, $rawDeflate, 0, $rawLength)
        }

        $memory = $null
        $decoder = $null
        $output = $null
        $plain = $null
        try {
            $memory = New-Object System.IO.MemoryStream(,$rawDeflate)
            $decoder = New-Object System.IO.Compression.DeflateStream(
                $memory,
                [System.IO.Compression.CompressionMode]::Decompress
            )
            $output = New-Object System.IO.MemoryStream
            $decoder.CopyTo($output)
            $plain = $output.ToArray()
        } catch {
            $plain = $null
        } finally {
            if ($decoder) { $decoder.Dispose() }
            if ($memory)  { $memory.Dispose() }
            if ($output)  { $output.Dispose() }
        }

        if ($plain -isnot [byte[]] -or $plain.Length -ne $ExpectedLength) { continue }
        $adler = Get-RccAdlerBytes $plain
        $checksumMatches = $true
        for ($i = 0; $i -lt 4; $i++) {
            if ($candidate[$candidateLength - 4 + $i] -ne $adler[$i]) {
                $checksumMatches = $false
                break
            }
        }
        if ($checksumMatches) { return ,$plain }
    }
    throw "Impossible de decomprimer/verifier le flux zlib RCC (taille attendue: $ExpectedLength)."
}

function Compress-RccZlib([byte[]]$Data) {
    $memory = New-Object System.IO.MemoryStream
    $encoder = New-Object System.IO.Compression.DeflateStream(
        $memory,
        [System.IO.Compression.CompressionMode]::Compress
    )
    try {
        $encoder.Write($Data, 0, $Data.Length)
    } finally {
        $encoder.Dispose()
    }
    $rawDeflate = $memory.ToArray()
    $memory.Dispose()

    $zlib = New-Object byte[] ($rawDeflate.Length + 6)
    $zlib[0] = 0x78
    $zlib[1] = 0x9C
    [Array]::Copy($rawDeflate, 0, $zlib, 2, $rawDeflate.Length)
    $adler = Get-RccAdlerBytes $Data
    [Array]::Copy($adler, 0, $zlib, 2 + $rawDeflate.Length, 4)
    return ,$zlib
}

function Read-RccUInt32BE([byte[]]$Data, [int]$Offset) {
    $bytes = [byte[]]@($Data[$Offset], $Data[$Offset + 1], $Data[$Offset + 2], $Data[$Offset + 3])
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Update-RccFlyoutTooltipBytes([byte[]]$RccBytes) {
    $nodeOffset = 0x3642
    $dataOffset = $nodeOffset + 8
    $slotLength = 888
    $nextResourceOffset = 0x39C2
    if ($RccBytes.Length -lt ($nextResourceOffset + 4)) {
        throw "qrc_Resources.rcc : fichier trop court pour cette version."
    }
    $compressedLength = Read-RccUInt32BE $RccBytes $nodeOffset
    $uncompressedLength = Read-RccUInt32BE $RccBytes ($nodeOffset + 4)

    if ($compressedLength -ne 892 -or ($compressedLength - 4) -ne $slotLength) {
        throw "qrc_Resources.rcc : taille compressee inattendue ($compressedLength)."
    }
    if ($dataOffset + $slotLength -ne $nextResourceOffset -or
        $RccBytes.Length -lt ($nextResourceOffset + 4)) {
        throw "qrc_Resources.rcc : bornes de la ressource flyout inattendues."
    }
    if ((Read-RccUInt32BE $RccBytes $nextResourceOffset) -ne 1425) {
        throw "qrc_Resources.rcc : en-tete de la ressource suivante inattendu."
    }
    if ($uncompressedLength -notin @(3015, 3011)) {
        throw "qrc_Resources.rcc : taille QML inattendue ($uncompressedLength)."
    }

    $slot = New-Object byte[] $slotLength
    [Array]::Copy($RccBytes, $dataOffset, $slot, 0, $slotLength)
    $plain = Expand-RccZlibSlot $slot ([int]$uncompressedLength)
    $source = [System.Text.Encoding]::UTF8.GetString($plain)

    $oldWidth = 'width: toolHelptext.paintedWidth + 12*scaleFactor'
    $newWidth = 'width: tooltext.paintedWidth + 12*scaleFactor'
    $oldHeight = 'height: 38*scaleFactor'
    $newHeight = 'height: 24*scaleFactor'
    $widthOldCount = [regex]::Matches($source, [regex]::Escape($oldWidth)).Count
    $widthNewCount = [regex]::Matches($source, [regex]::Escape($newWidth)).Count
    $heightOldCount = [regex]::Matches($source, [regex]::Escape($oldHeight)).Count
    $heightNewCount = [regex]::Matches($source, [regex]::Escape($newHeight)).Count

    if (($widthOldCount + $widthNewCount) -ne 1 -or
        ($heightOldCount + $heightNewCount) -ne 1 -or
        -not $source.Contains('GetSecondaryHelpText(tooltipstring)')) {
        throw "SecondaryToolbarButton.qml : contenu inattendu, RCC non modifie."
    }
    if ($widthNewCount -eq 1 -and $heightNewCount -eq 1) {
        return [pscustomobject]@{
            Bytes = $RccBytes
            Changed = $false
            UncompressedLength = $plain.Length
            CompressedLength = 0
        }
    }

    $patchedSource = $source.Replace($oldWidth, $newWidth).Replace($oldHeight, $newHeight)
    $patchedPlain = [System.Text.Encoding]::UTF8.GetBytes($patchedSource)
    $compressed = Compress-RccZlib $patchedPlain
    if ($compressed.Length -gt $slotLength) {
        throw "SecondaryToolbarButton.qml compresse a $($compressed.Length) octets; slot maximum $slotLength. RCC non modifie."
    }

    $patchedBytes = [byte[]]$RccBytes.Clone()
    $lengthBytes = [BitConverter]::GetBytes([uint32]$patchedPlain.Length)
    [Array]::Reverse($lengthBytes)
    [Array]::Copy($lengthBytes, 0, $patchedBytes, $nodeOffset + 4, 4)
    [Array]::Clear($patchedBytes, $dataOffset, $slotLength)
    [Array]::Copy($compressed, 0, $patchedBytes, $dataOffset, $compressed.Length)

    if ((Read-RccUInt32BE $patchedBytes $nodeOffset) -ne $compressedLength -or
        (Read-RccUInt32BE $patchedBytes ($nodeOffset + 4)) -ne $patchedPlain.Length -or
        (Read-RccUInt32BE $patchedBytes $nextResourceOffset) -ne 1425) {
        throw "Verification des en-tetes RCC echouee; fichier non ecrit."
    }
    $verifySlot = New-Object byte[] $slotLength
    [Array]::Copy($patchedBytes, $dataOffset, $verifySlot, 0, $slotLength)
    $verifyPlain = Expand-RccZlibSlot $verifySlot $patchedPlain.Length
    if ([System.Text.Encoding]::UTF8.GetString($verifyPlain) -cne $patchedSource) {
        throw "Verification aller-retour RCC echouee; fichier non ecrit."
    }

    return [pscustomobject]@{
        Bytes = $patchedBytes
        Changed = $true
        UncompressedLength = $patchedPlain.Length
        CompressedLength = $compressed.Length
    }
}

# ------------------------------------------------------------------ RESTORE
$running = Get-Process -Name '123D Design','123D10' -ErrorAction SilentlyContinue
if ($running) { throw "123D Design est en cours d'execution. Fermez-le avant application ou restauration." }
if ($Restore -and $PreflightOnly) { throw "-Restore et -PreflightOnly ne peuvent pas etre combines." }

if ($Restore) {
    foreach ($f in @($DllPath, $NuBasePath, $MachineXml, $RccPath)) {
        $bak = "$f.orig"
        if (Test-Path $bak) {
            Copy-Item $bak $f -Force
            Remove-Item $bak -Force
            Write-Host "Restaure : $f"
        } else {
            Write-Host "Pas de backup pour $f (rien a restaurer)"
        }
    }
    # restaure les .qm preexistants ou retire ceux ajoutes par ce patch
    foreach ($qm in @('qml_fr.qm','qt_fr.qm')) {
        $dst = Join-Path $QtDir $qm
        $bak = "$dst.orig"
        if (Test-Path $bak) {
            Copy-Item $bak $dst -Force
            Remove-Item $bak -Force
            Write-Host "Restaure : $dst"
        } elseif (Test-Path $dst) {
            Remove-Item $dst -Force
            Write-Host "Supprime : $dst"
        }
    }
    Write-Host "Restauration terminee."
    return
}

# ------------------------------------------------------------------ CHECKS
Write-Host "[0/5] Preflight : chemins, traductions, RCC et options"
if (-not (Test-Path $DllPath))    { throw "DLL introuvable : $DllPath" }
if (-not (Test-Path $NuBasePath)) { throw "DLL introuvable : $NuBasePath" }
if (-not (Test-Path $RccPath))    { throw "Ressources Qt introuvables : $RccPath" }
if (-not (Test-Path -LiteralPath $QmSource -PathType Container)) {
    throw "Dossier qm absent : $QmSource. Copiez le dossier FrenchLanguage complet, avec son sous-dossier qm."
}

# preflight avant toute ecriture : fichiers de traduction, RCC et XML d'options
foreach ($qmName in @('qml_fr.qm','qt_fr.qm')) {
    $qmPath = Join-Path $QmSource $qmName
    if (-not (Test-Path $qmPath)) { throw "Traduction requise absente : $qmPath" }
    $qmBytes = [System.IO.File]::ReadAllBytes($qmPath)
    if ($qmBytes.Length -lt 4 -or
        $qmBytes[0] -ne 0x3C -or $qmBytes[1] -ne 0xB8 -or
        $qmBytes[2] -ne 0x64 -or $qmBytes[3] -ne 0x18) {
        throw "Fichier Qt QM invalide : $qmPath"
    }
    $qmHash = (Get-FileHash $qmPath -Algorithm SHA256).Hash
    if ($qmHash -ne $RequiredQmHashes[$qmName]) {
        throw "Hash inattendu pour $qmPath : $qmHash"
    }
}

$rccBefore = [System.IO.File]::ReadAllBytes($RccPath)
$rccPreflightHash = (Get-FileHash $RccPath -Algorithm SHA256).Hash
$rccPatch = Update-RccFlyoutTooltipBytes $rccBefore

if (-not $SkipOptionWrite) {
    if (Test-Path $MachineXml) {
        $machinePreflight = Read-Utf16File $MachineXml
        Test-ValidXml $machinePreflight 'NMachineSpecificOptions.xml'
        if ($machinePreflight -notmatch '<BootstrapOptionsGroup\b') {
            throw "Groupe <BootstrapOptionsGroup> introuvable dans $MachineXml"
        }
    }
    if (Test-Path $GlobalXml) {
        $globalPreflight = Read-Utf16File $GlobalXml
        Test-ValidXml $globalPreflight 'NGlobalOptions.xml'
    } else {
        Write-Host "  NGlobalOptions.xml absent (non modifie par ce patch)"
    }
}

$nuPreflight = [System.IO.File]::ReadAllBytes($NuBasePath)
$nuAllOld = $true
$nuAllNew = $true
foreach ($patch in $NuPatches) {
    $found = $nuPreflight[$patch.Off..($patch.Off + $patch.Old.Length - 1)]
    $isOld = (($found -join ',') -eq ($patch.Old -join ','))
    $isNew = (($found -join ',') -eq ($patch.New -join ','))
    if (-not $isOld -and -not $isNew) {
        throw ("NuBase10.dll preflight : octets inattendus @0x{0:X} ({1}); aucune modification effectuee." -f $patch.Off, $patch.Name)
    }
    if (-not $isOld) { $nuAllOld = $false }
    if (-not $isNew) { $nuAllNew = $false }
}
if (-not $nuAllOld -and -not $nuAllNew) {
    throw "NuBase10.dll preflight : etat mixte; restaurez le backup avant installation."
}
if ($PreflightOnly) {
    Write-Host "Preflight valide. Aucun fichier n'a ete modifie." -ForegroundColor Green
    return
}

# ------------------------------------------------------------------ PATCH DLL
Write-Host ""
Write-Host "[1/5] Patch de NsBase10.dll (whitelist langues -> toujours vrai)"

# Backup AVANT d'ouvrir le handle (un handle ReadWrite bloque Copy-Item)
$peek = [System.IO.File]::ReadAllBytes($DllPath)
$curPeek = ($peek[$PatchOffset..($PatchOffset+5)] | ForEach-Object { $_.ToString('X2') }) -join ' '
$exp = ($ExpectedBytes | ForEach-Object { $_.ToString('X2') }) -join ' '
if ($curPeek -eq $exp) { Backup-Once $DllPath }

$fs = [System.IO.File]::Open($DllPath, 'Open', 'ReadWrite', 'ReadWrite')
try {
    $fs.Seek($PatchOffset, 'Begin') | Out-Null
    $buf = New-Object byte[] 6
    [void]$fs.Read($buf, 0, 6)

    $cur = ($buf | ForEach-Object { $_.ToString('X2') }) -join ' '
    $new = ($PatchedBytes  | ForEach-Object { $_.ToString('X2') }) -join ' '

    if ($cur -eq $new) {
        Write-Host "  Deja patche (bytes = $cur)"
    } elseif ($cur -eq $exp) {
        $fs.Seek($PatchOffset, 'Begin') | Out-Null
        $fs.Write($PatchedBytes, 0, 6)
        $fs.Flush()
        Write-Host "  Patche : $exp  ->  $new"
    } else {
        $hash = (Get-FileHash $DllPath -Algorithm SHA256).Hash
        if ($hash -ne $OrigHash) {
            throw "NsBase10.dll n'est ni l'original connu ni deja patche`n  bytes\@0x518D0 = $cur`n  SHA256 = $hash`n  ABORT."
        }
        throw "Bytes inattendus a l'offset 0x518D0 : $cur`n  (SHA256 conforme mais contenu different - ABORT par securite)"
    }

    # relecture / verification
    $fs.Seek($PatchOffset, 'Begin') | Out-Null
    $chk = New-Object byte[] 6
    [void]$fs.Read($chk, 0, 6)
    if (($chk | ForEach-Object { $_.ToString('X2') }) -join ' ' -ne $new) {
        throw "Verification post-patch echouee."
    }
} finally {
    $fs.Close()
}

# ------------------------------------------------------------------ PATCH NuBase10
Write-Host ""
Write-Host "[2/5] Patch de NuBase10.dll (chargeur .qm : es -> fr + bypass hash-check)"

# detection etat : lit les octets aux 4 offsets
$peek2 = [System.IO.File]::ReadAllBytes($NuBasePath)
$allOld = $true; $allNew = $true
foreach ($p in $NuPatches) {
    $cur = $peek2[$p.Off..($p.Off + $p.Old.Length - 1)]
    $isOld = (($cur -join ',') -eq ($p.Old -join ','))
    $isNew = (($cur -join ',') -eq ($p.New -join ','))
    if (-not $isOld -and -not $isNew) {
        throw ("NuBase10.dll : octets inattendus @0x{0:X} ({1})`n  attendu original : {2}`n  attendu patche  : {3}`n  trouve          : {4}`n  ABORT." -f
            $p.Off, $p.Name,
            (($p.Old | ForEach-Object { $_.ToString('X2') }) -join ' '),
            (($p.New | ForEach-Object { $_.ToString('X2') }) -join ' '),
            (($cur   | ForEach-Object { $_.ToString('X2') }) -join ' '))
    }
    if (-not $isOld) { $allOld = $false }
    if (-not $isNew) { $allNew = $false }
}

if ($allNew) {
    Write-Host "  Deja patche (4 sites conformes)."
} elseif (-not $allOld) {
    throw "NuBase10.dll : etat mixte detecte (partiellement patche).`n  Restaurez NuBase10.dll.orig puis relancez, ou restaurez manuellement."
} else {
    # tous les sites sont a l'etat original -> backup puis patch
    Backup-Once $NuBasePath
    $fs2 = [System.IO.File]::Open($NuBasePath, 'Open', 'ReadWrite', 'ReadWrite')
    try {
        foreach ($p in $NuPatches) {
            $fs2.Seek($p.Off, 'Begin') | Out-Null
            $fs2.Write($p.New, 0, $p.New.Length)
            Write-Host ("  Patche @0x{0:X} : {1}" -f $p.Off, $p.Name)
        }
        $fs2.Flush()
        # verification post-patch
        foreach ($p in $NuPatches) {
            $fs2.Seek($p.Off, 'Begin') | Out-Null
            $chk2 = New-Object byte[] $p.New.Length
            [void]$fs2.Read($chk2, 0, $p.New.Length)
            if (($chk2 -join ',') -ne ($p.New -join ',')) {
                throw "Verification post-patch echouee @0x$($p.Off.ToString('X'))."
            }
        }
    } finally {
        $fs2.Close()
    }
}

# ------------------------------------------------------------------ OPTION XML
if ($SkipOptionWrite) {
    Write-Host ""
    Write-Host "[3/5] Ecriture de l'option : ignoree (-SkipOptionWrite)"
} else {
    Write-Host ""
    Write-Host "[3/5] userLanguageOptionId = fr-FR"

    if (-not (Test-Path $MachineXml)) {
        # fichier absent : on cree le squelette minimal attendu par l'app
        $dir = Split-Path $MachineXml
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $skeleton = "<?xml version=""1.0"" encoding=""UTF-16"" standalone=""no"" ?>`r`n<OptionGroups>`r`n  <BootstrapOptionsGroup SchemaVersion=""1"" ToolTip=""Special preferences that require the application to be restarted after a change."" UserName=""Bootstrap"">`r`n  </BootstrapOptionsGroup>`r`n</OptionGroups>`r`n"
        Write-Utf16File $MachineXml $skeleton
        Write-Host "  Cree : $MachineXml"
    }

    $xml = Read-Utf16File $MachineXml
    Test-ValidXml $xml 'NMachineSpecificOptions.xml'

    if ($xml -notmatch '<BootstrapOptionsGroup\b') {
        throw "Groupe <BootstrapOptionsGroup> introuvable dans $MachineXml"
    }

    $already = $xml -match '<userLanguageOptionId\b[^>]*\bValue\s*=\s*"fr-FR"'
    if ($already) {
        Write-Host "  userLanguageOptionId vaut deja fr-FR (rien a faire)"
    } else {
        Backup-Once $MachineXml
        $m = [regex]::Match($xml, '(?s)(<BootstrapOptionsGroup\b[^>]*>)(.*?)(</BootstrapOptionsGroup>)')
        $body = $m.Groups[2].Value
        if ($body -match '<userLanguageOptionId\b') {
            $body = [regex]::Replace($body, '(<userLanguageOptionId\b[^>]*\bValue\s*=\s*")[^"]*(")', '${1}fr-FR${2}')
        } else {
            $body = '    <userLanguageOptionId UserName="User language" Value="fr-FR"/>' + "`r`n" + $body
        }
        $xml = $xml.Substring(0, $m.Groups[2].Index) + $body + $xml.Substring($m.Groups[2].Index + $m.Groups[2].Length)
        Test-ValidXml $xml 'NMachineSpecificOptions.xml (apres modification)'
        Write-Utf16File $MachineXml $xml
        Write-Host "  Ecrit : $MachineXml"

        $chk = Read-Utf16File $MachineXml
        if ($chk -notmatch '<userLanguageOptionId\b[^>]*\bValue\s*=\s*"fr-FR"') {
            throw "Verification de relecture echouee."
        }
        Write-Host "  Verifie : Value=fr-FR present."
    }
}

# ------------------------------------------------------------------ QML .qm
Write-Host ""
Write-Host "[4/5] Traductions Qt/QML (qtTranslations)"

if (-not (Test-Path $QtDir)) { throw "Dossier qtTranslations introuvable : $QtDir" }

foreach ($qmName in @('qml_fr.qm','qt_fr.qm')) {
    $src = Join-Path $QmSource $qmName
    $dst = Join-Path $QtDir $qmName
    if (Test-Path $dst) {
        Backup-Once $dst
        if ((Get-FileHash $dst).Hash -eq (Get-FileHash $src).Hash) {
            Write-Host "  Deja present : $dst"
            continue
        }
        Copy-Item $src $dst -Force
        Write-Host "  Installe : $dst"
    } else {
        Copy-Item $src $dst -Force
        Write-Host "  Installe : $dst"
    }
}

# -------------------------------------------------------- RCC FLYOUT TOOLTIP
Write-Host ""
Write-Host "[5/5] Tooltip des boutons de flyout (qrc_Resources.rcc)"

if ((Get-FileHash $RccPath -Algorithm SHA256).Hash -ne $rccPreflightHash) {
    throw "qrc_Resources.rcc a change apres le preflight; RCC non modifie."
}
Backup-Once $RccPath
if ($rccPatch.Changed) {
    [System.IO.File]::WriteAllBytes($RccPath, $rccPatch.Bytes)

    $rccAfter = [System.IO.File]::ReadAllBytes($RccPath)
    $rccVerify = Update-RccFlyoutTooltipBytes $rccAfter
    if ($rccVerify.Changed) {
        throw "Verification post-patch RCC echouee."
    }
    Write-Host "  Patche : largeur basee sur tooltext; hauteur 24*scaleFactor."
    Write-Host "  QML $($rccPatch.UncompressedLength) octets; zlib $($rccPatch.CompressedLength)/888; en-tete suivant intact."
} else {
    Write-Host "  Deja patche : largeur tooltext et hauteur 24*scaleFactor."
}

Write-Host ""
Write-Host "Patch applique." -ForegroundColor Green
Write-Host "Lancez 123D Design : l'interface doit etre en francais."
Write-Host "Verification interne possible : Options.Language doit afficher 'fr-FR'."
Write-Host "Rollback : Remove-FrenchLanguage.cmd"
