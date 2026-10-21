#Requires -Version 4.0
# ============================================================
# 123D Design - Boost stack reserve (~9,5 Mo -> 256 Mo)
# Patches the PE header field SizeOfStackReserve of
# "123D Design.exe". Community fix against stack overflows
# during deep geometry-kernel call chains (booleans, undo).
#
# Self-contained: applies byte-level changes to the USER'S OWN
# exe. Contains no Autodesk code, only patch logic.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File Apply-BoostStackMemory.ps1
#   powershell ... -File Apply-BoostStackMemory.ps1 -InstallDir "D:\123D Design"
#   powershell ... -File Apply-BoostStackMemory.ps1 -Restore
# ============================================================
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\Autodesk\123D Design',
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
$ExeName = '123D Design.exe'
$BakName = '123D Design.exe.orig'
$ORIG  = [UInt64]0x989680     # 10 000 000 octets ~ 9,5 Mo - valeur Autodesk
$BOOST = [UInt64]0x10000000   # 256 Mo

$exePath = Join-Path $InstallDir $ExeName
$bakPath = Join-Path $InstallDir $BakName

function Get-StackReserveInfo([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40) { throw "ABORT: truncated PE file: $Path" }
    $peOffset = [UInt64][BitConverter]::ToUInt32($bytes, 0x3C)
    if ($peOffset + 24 -gt $bytes.Length) { throw "ABORT: invalid PE offset: $Path" }
    if ([BitConverter]::ToUInt32($bytes, [int]$peOffset) -ne 0x00004550) {
        throw "ABORT: not a PE file: $Path"
    }
    $optionalHeader = [int]$peOffset + 24
    $optionalSize = [BitConverter]::ToUInt16($bytes, [int]$peOffset + 20)
    if ($optionalSize -lt 0x50 -or $optionalHeader + $optionalSize -gt $bytes.Length) {
        throw "ABORT: invalid optional header: $Path"
    }
    if ([BitConverter]::ToUInt16($bytes, $optionalHeader) -ne 0x20B) {
        throw "ABORT: expected PE32+ optional header: $Path"
    }
    $offset = $optionalHeader + 0x48
    return [pscustomobject]@{
        Bytes = $bytes
        Offset = $offset
        Value = [BitConverter]::ToUInt64($bytes, $offset)
        Length = $bytes.Length
    }
}

function Test-SameExceptStackReserve([string]$FirstPath, [string]$SecondPath, [int]$Offset) {
    $first = [IO.File]::ReadAllBytes($FirstPath)
    $second = [IO.File]::ReadAllBytes($SecondPath)
    if ($first.Length -ne $second.Length -or $Offset -lt 0 -or $Offset + 8 -gt $first.Length) {
        return $false
    }
    [Array]::Clear($first, $Offset, 8)
    [Array]::Clear($second, $Offset, 8)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $firstHash = [BitConverter]::ToString($sha.ComputeHash($first)).Replace('-', '')
        $secondHash = [BitConverter]::ToString($sha.ComputeHash($second)).Replace('-', '')
        return $firstHash -eq $secondHash
    } finally {
        $sha.Dispose()
    }
}

$running = Get-Process -Name '123D Design','123D10' -ErrorAction SilentlyContinue
if ($running) { throw "123D Design est en cours d'execution. Fermez-le avant application ou restauration." }

# ---------- RESTORE ----------
if ($Restore) {
    if (-not (Test-Path $bakPath)) { throw "No backup found: $bakPath" }
    $backupInfo = Get-StackReserveInfo $bakPath
    if ($backupInfo.Value -ne $ORIG) { throw "ABORT: backup does not contain the original stack reserve: $bakPath" }
    if (Test-Path $exePath) {
        $targetInfo = Get-StackReserveInfo $exePath
        if ($targetInfo.Length -ne $backupInfo.Length -or
            ($targetInfo.Value -ne $BOOST -and $targetInfo.Value -ne $ORIG) -or
            -not (Test-SameExceptStackReserve $exePath $bakPath $targetInfo.Offset)) {
            throw "ABORT: target does not match this stack-reserve backup; refusing to restore."
        }
    }
    Copy-Item $bakPath $exePath -Force
    if ((Get-FileHash $exePath -Algorithm SHA256).Hash -ne (Get-FileHash $bakPath -Algorithm SHA256).Hash) {
        throw "ABORT: verification failed after restore"
    }
    Write-Output "Restored original exe from $bakPath"
    return
}

# ---------- READ + LOCATE FIELD ----------
if (-not (Test-Path $exePath)) { throw "123D Design.exe not found: $exePath" }
$info = Get-StackReserveInfo $exePath
$b = $info.Bytes
$off = $info.Offset
$cur = $info.Value

# ---------- SAFETY CHECK ----------
if ($cur -eq $BOOST) {
    if (Test-Path $bakPath) {
        $backupInfo = Get-StackReserveInfo $bakPath
        if ($backupInfo.Value -ne $ORIG -or
            -not (Test-SameExceptStackReserve $exePath $bakPath $off)) {
            throw "ABORT: existing backup does not match the patched executable: $bakPath"
        }
    } else {
        Write-Warning "Stack reserve is already patched, but no original backup exists; rollback is unavailable."
    }
    Write-Output "Already patched (stack reserve = 256 Mo). Nothing to do."
    return
}
if ($cur -ne $ORIG) {
    throw ("ABORT: unexpected SizeOfStackReserve = 0x{0:X} ({1} octets).`n  Expected 0x{2:X}. Refusing to patch blindly." -f $cur, $cur, $ORIG)
}

# ---------- BACKUP + PATCH ----------
if (-not (Test-Path $bakPath)) {
    Copy-Item $exePath $bakPath
    Write-Output "Backup created: $bakPath"
} else {
    $backupInfo = Get-StackReserveInfo $bakPath
    if ($backupInfo.Value -ne $ORIG -or
        -not (Test-SameExceptStackReserve $exePath $bakPath $off)) {
        throw "ABORT: existing backup does not match the original executable: $bakPath"
    }
}
[BitConverter]::GetBytes($BOOST).CopyTo($b, $off)
[IO.File]::WriteAllBytes($exePath, $b)

# ---------- VERIFY ----------
$chk = [BitConverter]::ToUInt64([IO.File]::ReadAllBytes($exePath), $off)
if ($chk -ne $BOOST) { throw "ABORT: verification failed after write" }

Write-Output ("Stack reserve patched: 0x{0:X} -> 0x{1:X}  (~9,5 Mo -> 256 Mo)" -f $ORIG, $BOOST)
Write-Output "Note: reserves virtual address space per thread only -"
Write-Output "physical RAM is committed solely if the stack actually grows."
Write-Output "Rollback: Apply-BoostStackMemory.ps1 -Restore"
