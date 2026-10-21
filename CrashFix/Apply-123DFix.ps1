#Requires -Version 4.0
# ============================================================
# 123D Design - Null-activeCommand fix (v4)
# Patches Na123DUI10.dll: guards null this passed to the folded
# NuBase10 getter chain used by command predicates / menu builder.
#
# Self-contained: applies byte-level changes to the USER'S OWN
# original DLL. Contains no Autodesk code, only patch logic.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File Apply-123DFix.ps1
#   powershell ... -File Apply-123DFix.ps1 -OutputOnly C:\out\Na123DUI10.dll
#   powershell ... -File Apply-123DFix.ps1 -Restore
#   powershell ... -File Apply-123DFix.ps1 -SkipExeStackFix
# ============================================================
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\Autodesk\123D Design\Applications\123D',
    [string]$OutputOnly,
    [switch]$Restore,
    [switch]$SkipExeStackFix
)

$ErrorActionPreference = 'Stop'
$DllName  = 'Na123DUI10.dll'
$BakName  = 'Na123DUI10.dll.bak123d'
$HASH_ORIG    = '7D300E8DDBCCB5802EB59C3DA98DA1624BD63155CB12A0F0F161B1544EB35A69'
$HASH_PATCHED_V3 = '8C0774552555A2EFD2B3A47ADBF39E4BE27F9BC13513F8A376512F2C232FE04E'
$HASH_CURRENT_VARIANT = '9DF6EFBDE0A3E2622BC07D692352FFF7C61EA8487AEF5F52E6A1AC3C3F6183AE'
$HASH_PATCHED = 'DD1B31295122B5DF99FF21A391BDACBB3085A7BD5D10407753F40A8CF96346EC'
$ImageBase = [Int64]0x180000000

function Sha256([string]$p) { (Get-FileHash $p -Algorithm SHA256).Hash }

function Assert-KnownInstallDll([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    $hash = Sha256 $Path
    if ($hash -eq $HASH_CURRENT_VARIANT) {
        throw "ABORT: installed DLL is a custom premium-state variant; applying standard CrashFix would remove those edits. Use -OutputOnly and review the variant before installing."
    }
    if ($hash -ne $HASH_ORIG -and $hash -ne $HASH_PATCHED_V3 -and $hash -ne $HASH_PATCHED) {
        throw "ABORT: installed DLL has unrecognized/custom changes ($hash); refusing to overwrite."
    }
}

function Assert-SafeOutputPath(
    [string]$Destination,
    [string[]]$ProtectedPaths,
    [string[]]$ProtectedDirectories
) {
    $fullDestination = [IO.Path]::GetFullPath($Destination)
    foreach ($protectedPath in $ProtectedPaths) {
        if ([IO.Path]::GetFullPath($protectedPath).Equals(
            $fullDestination,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "ABORT: -OutputOnly cannot overwrite an input, installed program file, or backup: $fullDestination"
        }
    }
    foreach ($directory in $ProtectedDirectories) {
        $fullDirectory = [IO.Path]::GetFullPath($directory)
        if (-not $fullDirectory.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
            $fullDirectory += [IO.Path]::DirectorySeparatorChar
        }
        if ($fullDestination.StartsWith($fullDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            throw "ABORT: -OutputOnly destination must be outside the 123D installation: $fullDestination"
        }
    }
    return $fullDestination
}

$dllPath = Join-Path $InstallDir $DllName
$bakPath = Join-Path $InstallDir $BakName
$applicationRoot = Split-Path -Parent (Split-Path -Parent $InstallDir)
$exePath = Join-Path $applicationRoot '123D Design.exe'
$exeBakPath = "$exePath.bak123d-stack"

function Get-ExeStackReserveInfo([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40) { throw "ABORT: truncated launcher PE: $Path" }
    $peOffset = [UInt64][BitConverter]::ToUInt32($bytes, 0x3C)
    if ($peOffset + 24 -gt $bytes.Length) { throw "ABORT: invalid launcher PE offset: $Path" }
    if ([BitConverter]::ToUInt32($bytes, [int]$peOffset) -ne 0x00004550) {
        throw "ABORT: launcher is not a PE file: $Path"
    }
    $optionalHeader = [int]$peOffset + 24
    $optionalSize = [BitConverter]::ToUInt16($bytes, [int]$peOffset + 20)
    if ($optionalSize -lt 0x50 -or $optionalHeader + $optionalSize -gt $bytes.Length) {
        throw "ABORT: invalid launcher optional header: $Path"
    }
    if ([BitConverter]::ToUInt16($bytes, $optionalHeader) -ne 0x20B) {
        throw "ABORT: launcher must be PE32+: $Path"
    }
    $offset = $optionalHeader + 0x48
    return [pscustomobject]@{
        Bytes = $bytes
        Offset = $offset
        Value = [BitConverter]::ToUInt64($bytes, $offset)
        Length = $bytes.Length
    }
}

function Test-ExeSameExceptStackReserve([string]$FirstPath, [string]$SecondPath, [int]$Offset) {
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

# ---------- RESTORE ----------
if ($Restore) {
    $running = Get-Process -Name '123D Design','123D10' -ErrorAction SilentlyContinue
    if ($running) { throw "123D Design est en cours d'execution. Fermez-le avant restauration." }
    if (-not (Test-Path $bakPath)) { throw "No backup found: $bakPath" }
    $h = Sha256 $bakPath
    if ($h -ne $HASH_ORIG) { throw "ABORT: backup hash $h is not the known original; refusing to restore." }
    if (Test-Path $dllPath) {
        $targetHash = Sha256 $dllPath
        if ($targetHash -ne $HASH_ORIG -and
            $targetHash -ne $HASH_PATCHED_V3 -and
            $targetHash -ne $HASH_PATCHED -and
            $targetHash -ne $HASH_CURRENT_VARIANT) {
            throw "ABORT: installed DLL is neither the known original nor this patch; refusing to overwrite."
        }
        if ($targetHash -eq $HASH_CURRENT_VARIANT) {
            Write-Warning "Restoration will revert the extra premium-state modifications in this known local variant."
        }
    }
    $targetExeInfo = $null
    if (Test-Path $exePath) { $targetExeInfo = Get-ExeStackReserveInfo $exePath }
    $restoreExe = $false
    if (Test-Path $exeBakPath) {
        $backupInfo = Get-ExeStackReserveInfo $exeBakPath
        if ($backupInfo.Value -ne 0x989680) {
            throw "ABORT: CrashFix launcher backup has an unexpected stack reserve: $exeBakPath"
        }
        if (-not $targetExeInfo) { throw "ABORT: launcher not found for stack-reserve restore: $exePath" }
        if ($targetExeInfo.Length -ne $backupInfo.Length -or
            ($targetExeInfo.Value -ne 0x989680 -and $targetExeInfo.Value -ne 0x10000000) -or
            -not (Test-ExeSameExceptStackReserve $exePath $exeBakPath $targetExeInfo.Offset)) {
            throw "ABORT: launcher does not match the CrashFix stack-reserve backup."
        }
        $restoreExe = $true
    }
    Copy-Item $bakPath $dllPath -Force
    if ((Sha256 $dllPath) -ne $HASH_ORIG) { throw "ABORT: DLL restore verification failed." }
    Write-Output "Restored original DLL from $bakPath"
    if ($restoreExe -and $targetExeInfo.Value -ne 0x989680) {
        Copy-Item $exeBakPath $exePath -Force
        if ((Get-FileHash $exePath -Algorithm SHA256).Hash -ne (Get-FileHash $exeBakPath -Algorithm SHA256).Hash) {
            throw "ABORT: launcher restore verification failed."
        }
        Write-Output "Restored launcher stack reserve from $exeBakPath"
    } elseif (-not $restoreExe -and $targetExeInfo -and $targetExeInfo.Value -eq 0x10000000) {
            Write-Warning "Launcher stack reserve left unchanged: no CrashFix-owned backup exists (it may belong to BoostStackMemory)."
    }
    return
}

if (-not $OutputOnly) { Assert-KnownInstallDll $dllPath }

# ---------- SOURCE SELECTION ----------
if ($OutputOnly) {
    # patch from backup if present, else current dll (must match orig hash)
    $src = if (Test-Path $bakPath) { $bakPath } else { $dllPath }
    $dst = $OutputOnly
} else {
    $running = Get-Process -Name '123D Design','123D10' -ErrorAction SilentlyContinue
    if ($running) { throw "123D Design est en cours d'execution. Fermez-le avant installation." }
    $src = $dllPath
    if (Test-Path $bakPath) {
        # prefer pristine backup so re-running is idempotent
        $backupHash = Sha256 $bakPath
        if ($backupHash -ne $HASH_ORIG) { throw "ABORT: existing DLL backup is not the known original ($backupHash)." }
        $src = $bakPath
    }
    $dst = Join-Path ([IO.Path]::GetTempPath()) 'Na123DUI10_patched.dll'
}

if ($OutputOnly) {
    $dst = Assert-SafeOutputPath -Destination $dst `
        -ProtectedPaths @($src, $dllPath, $bakPath, $exePath, $exeBakPath) `
        -ProtectedDirectories @($InstallDir, $applicationRoot)
}

if (-not (Test-Path $src)) { throw "Source not found: $src" }
$srcHash = Sha256 $src
if ($srcHash -eq $HASH_PATCHED -and -not $OutputOnly) {
    if (-not (Test-Path $bakPath) -or (Sha256 $bakPath) -ne $HASH_ORIG) {
        throw "ABORT: DLL is patched but no verified original backup exists; cannot guarantee rollback."
    }
    Write-Output "Already patched (hash match; verified original backup exists). Nothing to do."
    return
}
if ($srcHash -ne $HASH_ORIG) {
    throw "ABORT: $src is not the known original 123D build.`n  hash: $srcHash`n  This patch only supports the build matching`n  $HASH_ORIG"
}

$exePreflight = $null
if (-not $OutputOnly -and -not $SkipExeStackFix -and (Test-Path $exePath)) {
    $exePreflight = Get-ExeStackReserveInfo $exePath
    if (Test-Path $exeBakPath) {
        $exeBackupPreflight = Get-ExeStackReserveInfo $exeBakPath
        if ($exeBackupPreflight.Value -ne 0x989680 -or
            $exeBackupPreflight.Length -ne $exePreflight.Length -or
            ($exePreflight.Value -in @(0x989680, 0x10000000) -and
             -not (Test-ExeSameExceptStackReserve $exePath $exeBakPath $exePreflight.Offset))) {
            throw "ABORT: existing CrashFix launcher backup does not match $exePath"
        }
    }
}

$b = [IO.File]::ReadAllBytes($src)
if ($b.Length -ne 0x789600) { throw "ABORT: unexpected file size $($b.Length)" }

# ---------- PE: add executable .fix section ----------
$e = [BitConverter]::ToUInt32($b, 0x3C); $coff = $e + 4; $opt = $coff + 20
$nsec = [BitConverter]::ToUInt16($b, $coff + 2)
$optSize = [BitConverter]::ToUInt16($b, $coff + 16)
$secAlign = [BitConverter]::ToUInt32($b, $opt + 0x20)
$fileAlign = [BitConverter]::ToUInt32($b, $opt + 0x24)
$sizeImage = [BitConverter]::ToUInt32($b, $opt + 0x38)
$sizeCode  = [BitConverter]::ToUInt32($b, $opt + 4)
$hdrEnd = $opt + $optSize + $nsec * 40
if ($nsec -ne 7) { throw "ABORT: expected 7 sections" }
for ($i = 0; $i -lt 40; $i++) { if ($b[$hdrEnd + $i] -ne 0) { throw "ABORT: no header room for .fix" } }

$fixVa  = [Int64]$sizeImage
$fixRaw = [Int64][Math]::Ceiling($b.Length / $fileAlign) * $fileAlign
$fixRawSz = 0x200
$nb = New-Object byte[] ($fixRaw + $fixRawSz)
[Array]::Copy($b, $nb, $b.Length)

$name = [Text.Encoding]::ASCII.GetBytes(".fix`0`0`0`0")
[Array]::Copy($name, 0, $nb, $hdrEnd, 8)
[BitConverter]::GetBytes([UInt32]$fixRawSz).CopyTo($nb, $hdrEnd + 8)
[BitConverter]::GetBytes([UInt32]$fixVa).CopyTo($nb, $hdrEnd + 12)
[BitConverter]::GetBytes([UInt32]$fixRawSz).CopyTo($nb, $hdrEnd + 16)
[BitConverter]::GetBytes([UInt32]$fixRaw).CopyTo($nb, $hdrEnd + 20)
[BitConverter]::GetBytes([UInt32]0x60000020).CopyTo($nb, $hdrEnd + 36)
[BitConverter]::GetBytes([UInt16]($nsec + 1)).CopyTo($nb, $coff + 2)
[BitConverter]::GetBytes([UInt32]($fixVa + $secAlign)).CopyTo($nb, $opt + 0x38)
[BitConverter]::GetBytes([UInt32]($sizeCode + $fixRawSz)).CopyTo($nb, $opt + 4)

function Fo([Int64]$rva) {
    if ($rva -ge $fixVa -and $rva -lt ($fixVa + $fixRawSz)) { return [Int64]($fixRaw + ($rva - $fixVa)) }
    return [Int64]($rva - 0x1000 + 0x400)
}
function Rel32([Int64]$fromRip, [Int64]$tgtVa) {
    $d = $tgtVa - $fromRip
    if ($d -gt 0x7FFFFFFF -or $d -lt -2147483648) { throw "rel32 overflow" }
    return [BitConverter]::GetBytes([Int32]$d)
}
function W([Int64]$off, $bytes) { for ($i = 0; $i -lt $bytes.Length; $i++) { $nb[$off + $i] = $bytes[$i] } }
function B8([Int64]$disp) { if ($disp -lt -128 -or $disp -gt 127) { throw "disp8 overflow" }; return [byte]($disp -band 0xFF) }

$caveVa = $ImageBase + $fixVa
$zeroVa = $caveVa + 0x19
$a = $fixRaw

# caveA: jrcxz->zero; call[activeCommand]; test rax,rax; jz->zero;
#        mov rcx,rax; call[commandDefinition]; ret | zero: xor eax,eax; ret
$nb[$a] = 0xE3; $nb[$a+1] = B8 ($zeroVa - ($caveVa + 2))
W ($a+2)  ([byte[]](0xFF,0x15) + (Rel32 ($caveVa + 8) ($ImageBase + 0x4915F8)))
W ($a+8)  ([byte[]](0x48,0x85,0xC0))
$nb[$a+11] = 0x74; $nb[$a+12] = B8 ($zeroVa - ($caveVa + 13))
W ($a+13) ([byte[]](0x48,0x8B,0xC8))
W ($a+16) ([byte[]](0xFF,0x15) + (Rel32 ($caveVa + 22) ($ImageBase + 0x491848)))
$nb[$a+22] = 0xC3
W ($a+0x19) ([byte[]](0x33,0xC0,0xC3))

# caveB @+0x60: test r13,r13; jz->0xAAEA5; mov rcx,r13; call[848]; jmp->0xAAE4C
$caveB = $caveVa + 0x60
$o = $a + 0x60
W $o ([byte[]](0x4D,0x85,0xED))
W ($o+3) ([byte[]](0x0F,0x84) + (Rel32 ($caveB + 9) ($ImageBase + 0xAAEA5)))
W ($o+9) ([byte[]](0x49,0x8B,0xCD))
W ($o+12) ([byte[]](0xFF,0x15) + (Rel32 ($caveB + 18) ($ImageBase + 0x491848)))
W ($o+18) ([byte[]](0xE9) + (Rel32 ($caveB + 23) ($ImageBase + 0xAAE4C)))

# 6 generic null-safe stubs @+0x20 step 8: jrcxz->zero; jmp [slot]
$stubSlots = @(0x4915F0, 0x4915E8, 0x491568, 0x491768, 0x491B28, 0x48DFC8)
$stubOf = @{}
for ($i = 0; $i -lt $stubSlots.Length; $i++) {
    $sv = $caveVa + 0x20 + $i * 8
    $stubOf['{0:X}' -f $stubSlots[$i]] = $sv
    $nb[$a + 0x20 + $i*8] = 0xE3
    $nb[$a + 0x21 + $i*8] = B8 ($zeroVa - ($sv + 2))
    W ($a + 0x22 + $i*8) ([byte[]](0xFF,0x25) + (Rel32 ($sv + 8) ($ImageBase + $stubSlots[$i])))
}

# Guard previously unguarded SelectToolbar commandDefinition paths. The return labels are
# the existing fall-through paths used when the corresponding predicate fails.
$selectToolbarGuards = @(
    @{ call = 0xCD313; skip = 0xCD39E },
    @{ call = 0xCD6EC; skip = 0xCD859 },
    @{ call = 0xCD89B; skip = 0xCDA1B }
)
for ($i = 0; $i -lt $selectToolbarGuards.Length; $i++) {
    $g = $selectToolbarGuards[$i]
    $callRva = [Int64]$g.call
    $callOff = Fo $callRva
    $callVa = $ImageBase + $callRva
    $movThis = ($nb[$callOff-3] -eq 0x49 -and
                $nb[$callOff-2] -eq 0x8B -and
                $nb[$callOff-1] -eq 0xCD)
    if (-not $movThis -or $nb[$callOff] -ne 0xFF -or $nb[$callOff+1] -ne 0x15) {
        throw ("ABORT: unexpected SelectToolbar commandDefinition site @0x{0:X}" -f $callRva)
    }
    $targetRva = $callRva + 6 + [BitConverter]::ToInt32($nb, $callOff + 2)
    if ($targetRva -ne 0x491848) {
        throw ("ABORT: unexpected SelectToolbar import target @0x{0:X}" -f $callRva)
    }

    $stubVa = $caveVa + 0x80 + $i * 0x20
    $stubOff = $fixRaw + 0x80 + $i * 0x20
    for ($j = 0; $j -lt 0x20; $j++) {
        if ($nb[$stubOff + $j] -ne 0) { throw "ABORT: commandDefinition guard space is occupied." }
    }
    $stub = [byte[]](
        ([byte[]](0xE3,0x06,0xFF,0x25)) +
        (Rel32 ($stubVa + 8) ($ImageBase + 0x491848)) +
        ([byte[]](0x48,0x83,0xC4,0x08,0xE9)) +
        (Rel32 ($stubVa + 17) ($ImageBase + [Int64]$g.skip))
    )
    if ($stub.Length -ne 17) { throw "ABORT: unexpected commandDefinition guard size." }
    W $stubOff $stub

    $callPatch = [byte[]](
        ([byte[]](0xE8)) +
        (Rel32 ($callVa + 5) $stubVa) +
        ([byte[]](0x90))
    )
    W $callOff $callPatch
}

# 5 predicate sleds: call caveA; test rax,rax; jz32->false-path; nop
$preds = @(
    @{ site = 0x282715; ret0 = 0x282765 },
    @{ site = 0x24CD09; ret0 = 0x24CD59 },
    @{ site = 0x2EE5F6; ret0 = 0x2EE637 },
    @{ site = 0x2EEDB8; ret0 = 0x2EEE96 },
    @{ site = 0x2EEF3F; ret0 = 0x2EF0C1 }
)
foreach ($p in $preds) {
    $rva = [Int64]$p.site; $o = Fo $rva; $sv = $ImageBase + $rva
    $ok = ($nb[$o] -eq 0xFF -and $nb[$o+1] -eq 0x15 -and $nb[$o+6] -eq 0x48 -and $nb[$o+7] -eq 0x8B -and $nb[$o+8] -eq 0xC8 -and $nb[$o+9] -eq 0xFF -and $nb[$o+10] -eq 0x15)
    if (-not $ok) { throw ("ABORT: bad pattern at 0x" + $rva.ToString('X')) }
    $t1 = ($sv + 6) + [BitConverter]::ToInt32($nb, $o + 2)
    $t2 = ($sv + 15) + [BitConverter]::ToInt32($nb, $o + 11)
    if ($t1 -ne ($ImageBase + 0x4915F8) -or $t2 -ne ($ImageBase + 0x491848)) { throw ("ABORT: bad targets 0x" + $rva.ToString('X')) }
    $nb[$o] = 0xE8
    (Rel32 ($sv + 5) $caveVa).CopyTo($nb, $o + 1)
    W ($o+5) ([byte[]](0x48,0x85,0xC0))
    W ($o+8) ([byte[]](0x0F,0x84) + (Rel32 ($sv + 14) ($ImageBase + $p.ret0)))
    $nb[$o+14] = 0x90
}

# menu-builder sled @0xAAE43: jmp caveB + 4 nop (orig: mov rcx,r13; call[848])
$rva = [Int64]0xAAE43; $o = Fo $rva; $sv = $ImageBase + $rva
$ok = ($nb[$o] -eq 0x49 -and $nb[$o+1] -eq 0x8B -and $nb[$o+2] -eq 0xCD -and $nb[$o+3] -eq 0xFF -and $nb[$o+4] -eq 0x15)
if (-not $ok) { throw "ABORT: bad pattern at 0xAAE43" }
if ((($sv + 9) + [BitConverter]::ToInt32($nb, $o + 5)) -ne ($ImageBase + 0x491848)) { throw "ABORT: bad call target at 0xAAE46" }
$nb[$o] = 0xE9
(Rel32 ($sv + 5) $caveB).CopyTo($nb, $o + 1)
for ($i = 5; $i -lt 9; $i++) { $nb[$o + $i] = 0x90 }

# rewrite every FF15 indirect call to the 6 slots -> E8 stub + NOP
$counts = @{}
for ($i = 0x400; $i -lt 0x400 + 0x487800 - 6; $i++) {
    if ($nb[$i] -eq 0xFF -and $nb[$i+1] -eq 0x15) {
        $rva = [Int64](0x1000 + ($i - 0x400))
        $slot = $rva + 6 + [BitConverter]::ToInt32($nb, $i + 2)
        $k = '{0:X}' -f $slot
        if ($stubOf.ContainsKey($k)) {
            $sv = $ImageBase + $rva
            $nb[$i] = 0xE8
            (Rel32 ($sv + 5) $stubOf[$k]).CopyTo($nb, $i + 1)
            $nb[$i + 5] = 0x90
            $counts[$k] = 1 + [Int64]($counts[$k])
        }
    }
}
if ([Int64]($counts['48DFC8']) -ne 68 -or [Int64]($counts['491568']) -ne 103 -or
    [Int64]($counts['4915E8']) -ne 86 -or [Int64]($counts['4915F0']) -ne 313 -or
    [Int64]($counts['491768']) -ne 54 -or [Int64]($counts['491B28']) -ne 33) {
    throw "ABORT: unexpected call-site counts ($($counts | Out-String))"
}

[IO.File]::WriteAllBytes($dst, $nb)
$dh = Sha256 $dst
if ($dh -ne $HASH_PATCHED) { throw "ABORT: output hash mismatch ($dh)" }

# ---------- INSTALL ----------
if ($OutputOnly) {
    Write-Output "Wrote patched DLL: $dst"
    Write-Output "SHA256: $dh  [OK]"
    return
}

Assert-KnownInstallDll $dllPath

if (-not (Test-Path $bakPath)) {
    Copy-Item $dllPath $bakPath
    Write-Output "Backup created: $bakPath"
}
Copy-Item $dst $dllPath -Force
$installedHash = Sha256 $dllPath
if ($installedHash -ne $HASH_PATCHED) { throw "ABORT: installed DLL hash mismatch ($installedHash)" }
Write-Output "Installed patched DLL: $dllPath"
Write-Output "SHA256: $installedHash  [OK]"

# ---------- optional: exe stack-reserve fix (community patch) ----------
if (-not $SkipExeStackFix -and $exePreflight) {
    if ($exePreflight.Value -eq 0x989680) {
        if (-not (Test-Path $exeBakPath)) {
            Copy-Item $exePath $exeBakPath
            if ((Get-FileHash $exeBakPath -Algorithm SHA256).Hash -ne (Get-FileHash $exePath -Algorithm SHA256).Hash) {
                throw "ABORT: launcher backup verification failed."
            }
            Write-Output "Launcher backup created: $exeBakPath"
        }
        $xb = [IO.File]::ReadAllBytes($exePath)
        [BitConverter]::GetBytes([UInt64]0x10000000).CopyTo($xb, $exePreflight.Offset)
        [IO.File]::WriteAllBytes($exePath, $xb)
        if ((Get-ExeStackReserveInfo $exePath).Value -ne 0x10000000) {
            throw "ABORT: launcher stack-reserve verification failed."
        }
        Write-Output "Exe stack reserve patched (0x989680 -> 0x10000000)"
    } elseif ($exePreflight.Value -eq 0x10000000) {
        Write-Output "Exe stack reserve already patched."
    } else {
        Write-Warning ("Exe stack reserve = 0x" + $exePreflight.Value.ToString('X') + " - untouched")
    }
} elseif (-not $SkipExeStackFix -and -not (Test-Path $exePath)) {
    Write-Warning "Launcher not found; optional stack-reserve patch skipped: $exePath"
}
Write-Output "`nDone. Rollback: Apply-123DFix.ps1 -Restore"
