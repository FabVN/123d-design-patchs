#Requires -Version 4.0
# ============================================================
# 123D Design - Null-activeCommand fix (v12)
# Patches Na123DUI10.dll: guards null this passed to the folded
# NuBase10 getter chain used by command predicates / menu builder.
# v5: with a null activeCommand, SelectToolbar guards now enter the
# existing "relaunch Select command" block instead of skipping it,
# restoring normal element selection after commands such as Snap.
# v6: the QTSelectToolbar "exit mode" slot FUN_1800c5540 no longer
# returns early on a null activeCommand; it still runs its Select
# relaunch block, which is what restores element picking after a
# command (e.g. Snap) has already destroyed itself.
# v7: ROOT CAUSE in NuBase10.dll. Nu::CommandMgr::popStackingCommand
# ends+destroys the top command, pops it, then only resumes a command
# when another remains on the stack. When the stack becomes empty
# (Snap pushes with stackingBehavior=1 which clears Select first, or
# same stacking-category replace), nothing relaunches the default
# session command: activeCommand stays null and the dead command's
# face/edge pick filter keeps handling clicks. The patch redirects
# the "stack empty" JZ to a stub that calls the framework's own
# Nu::CommandMgr::launchDefaultSessionCommand(), which fires
# CommandManagerDefaultCommandEvent -> the Na123DUI10 subscriber
# fills in SelectCmdDef -> executeCommand restarts Select.
# v8: same relaunch added on the SECOND teardown path found at runtime:
# destroyCommand ends SUSPENDED tracked commands (e.g. the Snap stage
# FusionSnapFaceCommand) via a direct endCommand call that bypasses
# popStackingCommand. The CALL site at 0x1652DF now jumps to a stub that
# replays the call, then relaunches the default session command when the
# stack is empty and reason != 3.
# v9: two more teardown paths covered the same way -
#  * destroyCommand path-3 (0x165309): a registered command that is
#    neither suspended nor stack top is silently unregistered; relaunch
#    when the stack is empty and reason != 3.
#  * clearStackingCommands exit (0x16459D): a behavior==1 push wipes the
#    whole stack (Select included) via direct endCommand(2) + manual pop;
#    relaunch Select there so the incoming push stacks over a healthy
#    default command which popStackingCommand later resumes.
# v10: the clearStackingCommands stub was REMOVED (site 0x16459D
#    restored): it fired on every clear including empty-stack no-ops and
#    recursed launchDef->executeCommand->push->clear->relaunch -> silent
#    stack overflow on Snap click. Added instead:
#  * destroyCommand early-return (0x16524A): when cmd is already in the
#    +0x68 destroy-pending set (tracked commands like CommitCommand /
#    FusionSnapFaceCommand torn down via CommandBase::destroy) the
#    function returned with no end, no pop and no relaunch.
#  * a reentrancy flag byte in .fix (+0x1F0) guards every
#    launchDefaultSessionCommand call.
# v11: crash-at-startup + stub fixes.
#  * .fix section is now WRITABLE (char 0xC0000020): v10 stored the
#    reentrancy flag in a read/execute-only section -> the first
#    mov byte[flag],1 raised AV at .fix+0x11B on launch.
#  * stub1 (popStackingCommand) emitted since v7 was corrupt: the JNZ
#    overwrote the last byte of `cmp [rbx+0x20],rax`, turning the
#    stack-empty test into a bogus `cmp [rbx+0x75]` plus stray
#    sub/add instructions that performed memory writes on every pop.
#    Relaid out: cmp intact, jnz +0x36, flag test, flagset, relaunch.
# v12: THE blocking exception. After a failed Snap, the default
#    command's begin() calls Nu::CommandContext::argumentAsPointer,
#    which runs boost::lexical_cast<ulong> on a context argument whose
#    wstring does not parse -> bad_lexical_cast. The exception unwound
#    through CommandMgr::executeCommand PAST the reentrancy counter--
#    (mgr+0xC leaked to 1), so every later executeCommand took the
#    'nested' path (begin+end immediately) and the dead command's
#    face/edge pick filter stayed active forever (Ctrl-stuck mode).
#    The throw branch of lexical_cast<ulong> (sole caller:
#    argumentAsPointer) now destroys the streambuf and returns 0,
#    i.e. 'argument absent' semantics the caller already handles.#  * all destroyCommand-path stubs (2/3/5) now also check
#    [mgr+0x10] (session) before relaunching.
#
# Self-contained: applies byte-level changes to the USER'S OWN
# original DLLs. Contains no Autodesk code, only patch logic.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File Apply-123DFix.ps1
#   powershell ... -File Apply-123DFix.ps1 -OutputOnly C:\out\Na123DUI10.dll
#   powershell ... -File Apply-123DFix.ps1 -Restore
#   powershell ... -File Apply-123DFix.ps1 -SkipExeStackFix
#   powershell ... -File Apply-123DFix.ps1 -SkipNuBaseFix
# ============================================================
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Program Files\Autodesk\123D Design\Applications\123D',
    [string]$OutputOnly,
    [switch]$Restore,
    [switch]$SkipExeStackFix,
    [switch]$SkipNuBaseFix
)

$ErrorActionPreference = 'Stop'
$DllName  = 'Na123DUI10.dll'
$BakName  = 'Na123DUI10.dll.bak123d'
$HASH_ORIG    = '7D300E8DDBCCB5802EB59C3DA98DA1624BD63155CB12A0F0F161B1544EB35A69'
$HASH_PATCHED_V3 = '8C0774552555A2EFD2B3A47ADBF39E4BE27F9BC13513F8A376512F2C232FE04E'
$HASH_PATCHED_V4 = 'DD1B31295122B5DF99FF21A391BDACBB3085A7BD5D10407753F40A8CF96346EC'
$HASH_PATCHED_V5 = '11A5327153A2DA699DF16C41E7BED5671157ACA0C92B9B0D3B9C9836468F0485'
$HASH_CURRENT_VARIANT = '9DF6EFBDE0A3E2622BC07D692352FFF7C61EA8487AEF5F52E6A1AC3C3F6183AE'
$HASH_PATCHED = '051AF352D2CC4E04BD3C906A8552ABA84286674D9F5B8D59B6C22215ED9B06F5'
$NuBaseName = 'NuBase10.dll'
$NuBaseBakName = 'NuBase10.dll.bak123d'
$HASH_NUB_ORIG = '0DAEE4ABBE50016836095ACF646B75CDF59719CE0CD6B7669EED83CE82A1F44B'
$HASH_NUB_PATCHED_V7 = '1B86A07C26D439681DCD4D4B6C376F1CA0E981968241C5F3E806BC4FB779DE65'
$HASH_NUB_PATCHED_V8 = 'D1040F9EB3F2D51CF8592B199169ECDA3435A757E4F914D26C4378C47438671E'
$HASH_NUB_PATCHED_V9 = '89B1F6A26832C6250E44B6D3AFC6F40987F902D8D67476E4A40F2A7C8DDD7005'
$HASH_NUB_PATCHED_V10 = '86D01D2685D950F79E75159B1E545BE1BB25B9A9E8FBDA7F656AB0150E9A714A'
$HASH_NUB_PATCHED_V11A = 'B97A915183DAC07B64EE26263ED070E222310D87469ED9E3D189AF79C7CD4B22'
$HASH_NUB_PATCHED_V11B = '775EF8A1300F699685C733FA99BF5E7819B14D8CBE027F4D2A6B4C67D9165483'
$HASH_NUB_PATCHED = '96F8C96CCCE200D7E5B65E27E6BF6B3921A32EEB7C5AD93355F98DB27DC0C76E'
$ImageBase = [Int64]0x180000000

function Sha256([string]$p) { (Get-FileHash $p -Algorithm SHA256).Hash }

function Assert-KnownInstallDll([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    $hash = Sha256 $Path
    if ($hash -eq $HASH_CURRENT_VARIANT) {
        throw "ABORT: installed DLL is a custom premium-state variant; applying standard CrashFix would remove those edits. Use -OutputOnly and review the variant before installing."
    }
    if ($hash -ne $HASH_ORIG -and $hash -ne $HASH_PATCHED_V3 -and $hash -ne $HASH_PATCHED_V4 -and $hash -ne $HASH_PATCHED_V5 -and $hash -ne $HASH_PATCHED) {
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
$nuBasePath = Join-Path $applicationRoot $NuBaseName
$nuBaseBakPath = Join-Path $applicationRoot $NuBaseBakName

function Assert-KnownNuBaseDll([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    $hash = Sha256 $Path
    if ($hash -ne $HASH_NUB_ORIG -and $hash -ne $HASH_NUB_PATCHED_V7 -and $hash -ne $HASH_NUB_PATCHED_V8 -and $hash -ne $HASH_NUB_PATCHED_V9 -and $hash -ne $HASH_NUB_PATCHED_V10 -and $hash -ne $HASH_NUB_PATCHED_V11A -and $hash -ne $HASH_NUB_PATCHED_V11B -and $hash -ne $HASH_NUB_PATCHED) {
        throw "ABORT: installed NuBase10.dll has unrecognized/custom changes ($hash); refusing to overwrite."
    }
}

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
            $targetHash -ne $HASH_PATCHED_V4 -and
            $targetHash -ne $HASH_PATCHED_V5 -and
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
    if (Test-Path $nuBaseBakPath) {
        $nubBackupHash = Sha256 $nuBaseBakPath
        if ($nubBackupHash -ne $HASH_NUB_ORIG) { throw "ABORT: NuBase10 backup hash $nubBackupHash is not the known original; refusing to restore." }
        if (Test-Path $nuBasePath) {
            $nubTargetHash = Sha256 $nuBasePath
            if ($nubTargetHash -ne $HASH_NUB_ORIG -and $nubTargetHash -ne $HASH_NUB_PATCHED_V7 -and $nubTargetHash -ne $HASH_NUB_PATCHED_V8 -and $nubTargetHash -ne $HASH_NUB_PATCHED_V9 -and $nubTargetHash -ne $HASH_NUB_PATCHED_V10 -and $nubTargetHash -ne $HASH_NUB_PATCHED_V11A -and $nubTargetHash -ne $HASH_NUB_PATCHED_V11B -and $nubTargetHash -ne $HASH_NUB_PATCHED) {
                throw "ABORT: installed NuBase10.dll is neither the known original nor this patch; refusing to overwrite."
            }
        }
        Copy-Item $nuBaseBakPath $nuBasePath -Force
        if ((Sha256 $nuBasePath) -ne $HASH_NUB_ORIG) { throw "ABORT: NuBase10 restore verification failed." }
        Write-Output "Restored original NuBase10.dll from $nuBaseBakPath"
    }
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
$uiDone = $false
if ($srcHash -eq $HASH_PATCHED -and -not $OutputOnly) {
    if (-not (Test-Path $bakPath) -or (Sha256 $bakPath) -ne $HASH_ORIG) {
        throw "ABORT: DLL is patched but no verified original backup exists; cannot guarantee rollback."
    }
    Write-Output "Na123DUI10.dll already patched (hash match; verified original backup exists)."
    $uiDone = $true
}
if (-not $uiDone -and $srcHash -ne $HASH_ORIG) {
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

$name = [Text.Encoding]::ASCII.GetBytes(".fix`0`0`0`0")
function Rel32([Int64]$fromRip, [Int64]$tgtVa) {
    $d = $tgtVa - $fromRip
    if ($d -gt 0x7FFFFFFF -or $d -lt -2147483648) { throw "rel32 overflow" }
    return [BitConverter]::GetBytes([Int32]$d)
}

if (-not $uiDone) {

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

# Guard previously unguarded SelectToolbar commandDefinition paths. With a null
# activeCommand each guarded call jumps just past CommandBase::destroy, into the
# existing block that looks up and executes the Select command definition
# (selectCommandId -> findCommandDefinitionById -> executeCommand). A null command
# needs no destroy but still needs Select restarted; skipping the whole block (v4)
# left Snap's face/edge pick filter active with no command running.
$selectToolbarGuards = @(
    @{ call = 0xCD313; skip = 0xCD370 },   # 'hide'       -> selectCommandId()
    @{ call = 0xCD6EC; skip = 0xCD749 },   # 'showall'    -> selectCommandId()
    @{ call = 0xCD89B; skip = 0xCD8F8 }    # 'HideSolids' -> executeImmediately + selectCommandId()
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

# v6: FUN_1800c5540 is the QTSelectToolbar "exit mode" slot (qt_metacall case 6,
# invoked from QML when a command's toolframe closes). It destroys the active
# command then rebuilds a CommandContext and relaunches Select. With a null
# activeCommand it returned immediately, so Select never restarted and the
# finished command's pick filter (e.g. Snap face/edge mode) stayed active.
# Redirect the null JZ from the function epilogue to the Select relaunch block
# at 0xC566F (just after CommandBase::destroy - nothing to destroy anyway).
$rva = [Int64]0xC5581; $o = Fo $rva
if ($nb[$o] -ne 0x0F -or $nb[$o+1] -ne 0x84) { throw "ABORT: bad pattern at 0xC5581" }
$jzTgt = ($ImageBase + $rva + 6) + [BitConverter]::ToInt32($nb, $o + 2)
if ($jzTgt -ne ($ImageBase + 0xC56D2)) { throw "ABORT: unexpected JZ target at 0xC5581" }
(Rel32 ($ImageBase + $rva + 6) ($ImageBase + 0xC566F)).CopyTo($nb, $o + 2)

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
if ($OutputOnly) {
    Write-Output "Wrote patched DLL: $dst"
    Write-Output "SHA256: $dh  [OK]"
}

} # end if (-not $uiDone)

# ---------- NuBase10 v7: relaunch default session command on empty stack ----------
# Root cause of the post-Snap face/edge lock: Nu::CommandMgr::popStackingCommand
# ends+destroys the top command, pops it, then only resumes when another command
# remains. If the stack becomes EMPTY (Snap pushes with stackingBehavior=1 which
# clearStackingCommands()s Select first, or a same-stacking-category replace),
# nobody relaunches the default session command: activeCommand stays null and
# the dead command's face/edge pick filter keeps receiving clicks (additive,
# Ctrl-like selection on every object).
# Fix: the "stack empty" JZ at 0x164619 (reason != 3 already checked) now jumps
# to a stub in a new .fix section: mov rcx,rbx ; call
# Nu::CommandMgr::launchDefaultSessionCommand (0x165E30) ; jmp epilogue
# (0x164672). That fires CommandManagerDefaultCommandEvent -> the Na123DUI10
# CommandEventSite fills in SelectCmdDef -> executeCommand restarts Select.
#
# v8 adds a second site at 0x1652DF: destroyCommand ends a command found in the
# SUSPENDED set (+0x48) through a direct endCommand call that bypasses
# popStackingCommand entirely. A suspended tracked command such as
# FusionSnapFaceCommand (the Snap face-pick stage) can outlive the snap and die
# later on this path with an empty command stack -> Select is never relaunched
# and the residual face/edge pick state keeps handling clicks. The stub replays
# the endCommand call, then relaunches the default session command when the
# stack is empty and reason != 3 (shutdown stays untouched).
$nuBaseDst = $null
if (-not $SkipNuBaseFix -and ((Test-Path $nuBasePath) -or (Test-Path $nuBaseBakPath))) {
    $nubSrc = $nuBasePath
    if (Test-Path $nuBaseBakPath) {
        $nubBakHash = Sha256 $nuBaseBakPath
        if ($nubBakHash -ne $HASH_NUB_ORIG) { throw "ABORT: existing NuBase10 backup is not the known original ($nubBakHash)." }
        $nubSrc = $nuBaseBakPath
    }
    $nubSrcHash = Sha256 $nubSrc
    if ($nubSrcHash -ne $HASH_NUB_ORIG) {
        throw "ABORT: $nubSrc is not the known NuBase10 build.`n  hash: $nubSrcHash`n  This patch only supports the build matching`n  $HASH_NUB_ORIG"
    }
    if (-not $OutputOnly) { Assert-KnownNuBaseDll $nuBasePath }
    if ($OutputOnly) {
        $nuBaseDst = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($dst))) 'NuBase10_patched.dll'
        $nuBaseDst = Assert-SafeOutputPath -Destination $nuBaseDst `
            -ProtectedPaths @($nubSrc, $nuBasePath, $nuBaseBakPath) `
            -ProtectedDirectories @($InstallDir, $applicationRoot)
    } else {
        $nuBaseDst = Join-Path ([IO.Path]::GetTempPath()) 'NuBase10_patched.dll'
    }

    $b2 = [IO.File]::ReadAllBytes($nubSrc)
    if ($b2.Length -ne 0x1505E00) { throw "ABORT: unexpected NuBase10 file size $($b2.Length)" }

    # PE: add executable .fix section (same scheme as Na123DUI10)
    $e2 = [BitConverter]::ToUInt32($b2, 0x3C); $coff2 = $e2 + 4; $opt2 = $coff2 + 20
    $nsec2 = [BitConverter]::ToUInt16($b2, $coff2 + 2)
    $optSize2 = [BitConverter]::ToUInt16($b2, $coff2 + 16)
    $secAlign2 = [BitConverter]::ToUInt32($b2, $opt2 + 0x20)
    $fileAlign2 = [BitConverter]::ToUInt32($b2, $opt2 + 0x24)
    $sizeImage2 = [BitConverter]::ToUInt32($b2, $opt2 + 0x38)
    $sizeCode2 = [BitConverter]::ToUInt32($b2, $opt2 + 4)
    $hdrEnd2 = $opt2 + $optSize2 + $nsec2 * 40
    if ($nsec2 -ne 7) { throw "ABORT: NuBase10: expected 7 sections" }
    for ($i = 0; $i -lt 40; $i++) { if ($b2[$hdrEnd2 + $i] -ne 0) { throw "ABORT: NuBase10: no header room for .fix" } }

    $fixVa2 = [Int64]$sizeImage2
    $fixRaw2 = [Int64][Math]::Ceiling($b2.Length / $fileAlign2) * $fileAlign2
    $fixRawSz2 = 0x200
    $nb2 = New-Object byte[] ($fixRaw2 + $fixRawSz2)
    [Array]::Copy($b2, $nb2, $b2.Length)
    [Array]::Copy($name, 0, $nb2, $hdrEnd2, 8)
    [BitConverter]::GetBytes([UInt32]$fixRawSz2).CopyTo($nb2, $hdrEnd2 + 8)
    [BitConverter]::GetBytes([UInt32]$fixVa2).CopyTo($nb2, $hdrEnd2 + 12)
    [BitConverter]::GetBytes([UInt32]$fixRawSz2).CopyTo($nb2, $hdrEnd2 + 16)
    [BitConverter]::GetBytes([UInt32]$fixRaw2).CopyTo($nb2, $hdrEnd2 + 20)
    [BitConverter]::GetBytes([UInt32]3758096416).CopyTo($nb2, $hdrEnd2 + 36)  # 0xE0000020 = CODE|EXEC|READ|WRITE
    [BitConverter]::GetBytes([UInt16]($nsec2 + 1)).CopyTo($nb2, $coff2 + 2)
    [BitConverter]::GetBytes([UInt32]($fixVa2 + $secAlign2)).CopyTo($nb2, $opt2 + 0x38)
    [BitConverter]::GetBytes([UInt32]($sizeCode2 + $fixRawSz2)).CopyTo($nb2, $opt2 + 4)

    function FoN([Int64]$rva) {
        if ($rva -ge $fixVa2 -and $rva -lt ($fixVa2 + $fixRawSz2)) { return [Int64]($fixRaw2 + ($rva - $fixVa2)) }
        return [Int64]($rva - 0x1000 + 0x400)
    }
    function WN([Int64]$off, $bytes) { for ($i = 0; $i -lt $bytes.Length; $i++) { $nb2[$off + $i] = $bytes[$i] } }

    $caveVa2 = $ImageBase + $fixVa2
    $flagVa  = $caveVa2 + 0x1F0   # reentrancy flag byte (0 = idle)
    # v10: every stub that calls launchDefaultSessionCommand now guards with a
    # reentrancy flag. launchDef -> executeCommand -> pushStackingCommand can
    # re-enter command teardown (txn cleanup, behavior==1 clearStackingCommands,
    # nested destroys) which re-hits a stub and recursed forever -> silent
    # stack-overflow death. The flag makes the inner relaunch a no-op.
    function FlagTest([Int64]$hereVa) { [byte[]](0x80,0x3D) + [BitConverter]::GetBytes([int]($flagVa - ($hereVa + 7))) + @(0x00) }          # cmp byte[flag],0
    function FlagSet([Int64]$hereVa)  { [byte[]](0xC6,0x05) + [BitConverter]::GetBytes([int]($flagVa - ($hereVa + 7))) + @(0x01) }          # mov byte[flag],1
    function FlagClr([Int64]$hereVa)  { [byte[]](0xC6,0x05) + [BitConverter]::GetBytes([int]($flagVa - ($hereVa + 7))) + @(0x00) }          # mov byte[flag],0
    # stub1: re-do the "stack empty" check removed at the patch site.
    #   non-empty or reentrant -> jmp 0x16461B (original resume path)
    #   empty     -> flag=1 ; mov rcx,rbx ; call launchDefaultSessionCommand ; flag=0 ; jmp 0x164672
    WN $fixRaw2        ([byte[]](0x48,0x8B,0x43,0x28))              # mov rax,[rbx+0x28]
    WN ($fixRaw2+4)    ([byte[]](0x48,0x39,0x43,0x20))              # cmp [rbx+0x20],rax
    WN ($fixRaw2+8)    ([byte[]](0x75,0x2C))                        # jnz ->+0x36 (resume path)
    WN ($fixRaw2+0xA)  (FlagTest ($caveVa2 + 0xA))                  # cmp byte[flag],0
    WN ($fixRaw2+0x11) ([byte[]](0x75,0x23))                        # jnz ->+0x36 (reentrant -> resume path)
    WN ($fixRaw2+0x13) (FlagSet ($caveVa2 + 0x13))                  # mov byte[flag],1
    WN ($fixRaw2+0x1A) ([byte[]](0x48,0x8B,0xCB))                   # mov rcx,rbx
    WN ($fixRaw2+0x1D) ([byte[]](0xE8) + (Rel32 ($caveVa2 + 0x22) ($ImageBase + 0x165E30)))
    WN ($fixRaw2+0x22) (FlagClr ($caveVa2 + 0x22))                  # mov byte[flag],0
    WN ($fixRaw2+0x29) ([byte[]](0xE9) + (Rel32 ($caveVa2 + 0x2E) ($ImageBase + 0x164672)))
    for ($i = 0x2E; $i -lt 0x36; $i++) { $nb2[$fixRaw2+$i] = 0xCC }
    WN ($fixRaw2+0x36) ([byte[]](0xE9) + (Rel32 ($caveVa2 + 0x3B) ($ImageBase + 0x16461B)))

    # 0x164611: MOV RAX,[RBX+0x28] / CMP [RBX+0x20],RAX / JZ 0x164672 (74 57 -
    # short JZ cannot reach .fix) -> JMP stub (5 bytes) + 5 NOP. Nothing else
    # jumps into 0x164611-0x16461A, so overwriting is safe.
    $rvaN = [Int64]0x164611; $oN = FoN $rvaN
    $seq = [byte[]](0x48,0x8B,0x43,0x28,0x48,0x39,0x43,0x20,0x74,0x57)
    for ($i = 0; $i -lt $seq.Length; $i++) {
        if ($nb2[$oN + $i] -ne $seq[$i]) { throw "ABORT: bad pattern at NuBase10 0x164611" }
    }
    WN $oN ([byte[]](0xE9) + (Rel32 ($ImageBase + $rvaN + 5) $caveVa2))
    for ($i = 5; $i -lt 10; $i++) { $nb2[$oN + $i] = 0x90 }

    # v8 stub2 @.fix+0x40 (v10: reentrancy-guarded): suspended-command destroy
    # path in destroyCommand. Ends a SUSPENDED tracked command (e.g.
    # FusionSnapFaceCommand) via endCommand directly, bypassing
    # popStackingCommand -> no default-command relaunch. Replace the CALL
    # endCommand at 0x1652DF: stub replays the call, then (reason != 3 &&
    # stack empty && !reentrant) calls launchDefaultSessionCommand.
    #   RSI = mgr, R13D = reason (callee-saved, still live). RSP 16-aligned.
    $stub2 = $fixRaw2 + 0x40
    WN $stub2         ([byte[]](0xE8) + (Rel32 ($caveVa2 + 0x45) ($ImageBase + 0x164270)))   # call endCommand
    WN ($stub2 + 5)   ([byte[]](0x41,0x83,0xFD,0x03))                                       # cmp r13d,3
    WN ($stub2 + 9)   ([byte[]](0x0F,0x84) + [BitConverter]::GetBytes([int](($ImageBase + 0x1652E4) - ($caveVa2 + 0x4F))))  # je ->0x1652E4
    WN ($stub2 + 0xF) ([byte[]](0x48,0x83,0x7E,0x10,0x00))                                  # cmp qword [rsi+0x10],0 (session)
    WN ($stub2 + 0x14)([byte[]](0x0F,0x84) + [BitConverter]::GetBytes([int](($ImageBase + 0x1652E4) - ($caveVa2 + 0x5A))))  # je ->0x1652E4
    WN ($stub2 + 0x1A)(FlagTest ($caveVa2 + 0x5A))                                          # cmp byte[flag],0
    WN ($stub2 + 0x21)([byte[]](0x0F,0x85) + [BitConverter]::GetBytes([int](($ImageBase + 0x1652E4) - ($caveVa2 + 0x67))))  # jne ->0x1652E4
    WN ($stub2 + 0x27)([byte[]](0x48,0x8B,0x46,0x28))                                       # mov rax,[rsi+0x28]
    WN ($stub2 + 0x2B)([byte[]](0x48,0x39,0x46,0x20))                                       # cmp [rsi+0x20],rax
    WN ($stub2 + 0x2F)([byte[]](0x0F,0x85) + [BitConverter]::GetBytes([int](($ImageBase + 0x1652E4) - ($caveVa2 + 0x75))))  # jne ->0x1652E4
    WN ($stub2 + 0x35)(FlagSet ($caveVa2 + 0x75))                                           # mov byte[flag],1
    WN ($stub2 + 0x3C)([byte[]](0x48,0x8B,0xCE))                                            # mov rcx,rsi
    WN ($stub2 + 0x3F)([byte[]](0xE8) + (Rel32 ($caveVa2 + 0x84) ($ImageBase + 0x165E30)))  # call launchDefaultSessionCommand
    WN ($stub2 + 0x44)(FlagClr ($caveVa2 + 0x84))                                           # mov byte[flag],0
    WN ($stub2 + 0x4B)([byte[]](0xE9) + (Rel32 ($caveVa2 + 0x90) ($ImageBase + 0x1652E4)))  # jmp ->0x1652E4

    # site 0x1652DF: CALL endCommand (E8 8C EF FF FF) -> JMP stub2
    $rvaN2 = [Int64]0x1652DF; $oN2 = FoN $rvaN2
    $seq2 = [byte[]](0xE8,0x8C,0xEF,0xFF,0xFF)
    for ($i = 0; $i -lt $seq2.Length; $i++) {
        if ($nb2[$oN2 + $i] -ne $seq2[$i]) { throw "ABORT: bad pattern at NuBase10 0x1652DF" }
    }
    WN $oN2 ([byte[]](0xE9) + (Rel32 ($ImageBase + $rvaN2 + 5) ($caveVa2 + 0x40)))

    # v9 stub3 @.fix+0xA0 (v10: moved + reentrancy-guarded): destroyCommand
    # third teardown path. A registered command that is neither suspended nor
    # stack top is silently unregistered (0x165309 CMP RAX,RDI / 0x16530C JNZ
    # ->0x165319) with no end, no pop and no default relaunch. Replay the
    # compare, keep the original pop branch, and relaunch the default session
    # command when the stack is empty and reason != 3.
    #   RSI = mgr, R13D = reason, RAX = stack-top-or-0, RDI = cmd.
    $stub3 = $fixRaw2 + 0xA0
    WN $stub3          ([byte[]](0x48,0x3B,0xC7))                                           # cmp rax,rdi
    WN ($stub3 + 3)    ([byte[]](0x0F,0x84) + [BitConverter]::GetBytes([int](($ImageBase + 0x16530E) - ($caveVa2 + 0xA9))))  # je ->0x16530E (pop path)
    WN ($stub3 + 9)    ([byte[]](0x41,0x83,0xFD,0x03))                                      # cmp r13d,3
    WN ($stub3 + 0xD)  ([byte[]](0x0F,0x84) + [BitConverter]::GetBytes([int](($ImageBase + 0x165319) - ($caveVa2 + 0xB3))))  # je ->0x165319
    WN ($stub3 + 0x13) ([byte[]](0x48,0x83,0x7E,0x10,0x00))                                 # cmp qword [rsi+0x10],0 (session)
    WN ($stub3 + 0x18) ([byte[]](0x0F,0x84) + [BitConverter]::GetBytes([int](($ImageBase + 0x165319) - ($caveVa2 + 0xBE))))  # je ->0x165319
    WN ($stub3 + 0x1E) (FlagTest ($caveVa2 + 0xBE))                                         # cmp byte[flag],0
    WN ($stub3 + 0x25) ([byte[]](0x0F,0x85) + [BitConverter]::GetBytes([int](($ImageBase + 0x165319) - ($caveVa2 + 0xCB))))  # jne ->0x165319
    WN ($stub3 + 0x2B) ([byte[]](0x48,0x8B,0x4E,0x28))                                      # mov rcx,[rsi+0x28]
    WN ($stub3 + 0x2F) ([byte[]](0x48,0x39,0x4E,0x20))                                      # cmp [rsi+0x20],rcx
    WN ($stub3 + 0x33) ([byte[]](0x0F,0x85) + [BitConverter]::GetBytes([int](($ImageBase + 0x165319) - ($caveVa2 + 0xD9))))  # jne ->0x165319
    WN ($stub3 + 0x39) (FlagSet ($caveVa2 + 0xD9))                                          # mov byte[flag],1
    WN ($stub3 + 0x40) ([byte[]](0x48,0x8B,0xCE))                                           # mov rcx,rsi
    WN ($stub3 + 0x43) ([byte[]](0xE8) + (Rel32 ($caveVa2 + 0xE8) ($ImageBase + 0x165E30))) # call launchDefaultSessionCommand
    WN ($stub3 + 0x48) (FlagClr ($caveVa2 + 0xE8))                                          # mov byte[flag],0
    WN ($stub3 + 0x4F) ([byte[]](0xE9) + (Rel32 ($caveVa2 + 0xF4) ($ImageBase + 0x165319))) # jmp ->0x165319

    # site 0x165309: CMP RAX,RDI / JNZ 0x165319 (48 3B C7 75 0B) -> JMP stub3
    $rvaN3 = [Int64]0x165309; $oN3 = FoN $rvaN3
    $seq3 = [byte[]](0x48,0x3B,0xC7,0x75,0x0B)
    for ($i = 0; $i -lt $seq3.Length; $i++) {
        if ($nb2[$oN3 + $i] -ne $seq3[$i]) { throw "ABORT: bad pattern at NuBase10 0x165309" }
    }
    WN $oN3 ([byte[]](0xE9) + (Rel32 ($ImageBase + $rvaN3 + 5) ($caveVa2 + 0xA0)))

    # v10 stub5 @.fix+0xF0: destroyCommand early-return path. When cmd is found
    # in the +0x68 set (destroy already requested/in-flight) the function jumps
    # straight to the epilogue (0x16524A JNZ ->0x165331): no end, no pop, no
    # relaunch. CommandBase::destroy hits this for deferred teardown of tracked
    # commands (CommitCommand chain) and was the remaining path that left the
    # stack empty with no default command. If the stack is empty, reason != 3
    # and not reentrant, relaunch the default session command, then epilogue.
    #   RSI = mgr, R13D = reason. (v9's clearStackingCommands-exit stub4 was
    #   removed: it fired on EVERY clear incl. empty-stack no-ops, and a
    #   behavior==1 default command would recurse launchDef->push->clear->stub
    #   -> silent stack overflow.)
    $stub5 = $fixRaw2 + 0x140
    WN $stub5          ([byte[]](0x0F,0x84) + [BitConverter]::GetBytes([int](($ImageBase + 0x165250) - ($caveVa2 + 0x146)))) # je ->0x165250 (not found -> body)
    WN ($stub5 + 6)    ([byte[]](0x41,0x83,0xFD,0x03))                                      # cmp r13d,3
    WN ($stub5 + 0xA)  ([byte[]](0x0F,0x84) + [BitConverter]::GetBytes([int](($ImageBase + 0x165331) - ($caveVa2 + 0x150)))) # je ->0x165331
    WN ($stub5 + 0x10) ([byte[]](0x48,0x83,0x7E,0x10,0x00))                                 # cmp qword [rsi+0x10],0 (session)
    WN ($stub5 + 0x15) ([byte[]](0x0F,0x84) + [BitConverter]::GetBytes([int](($ImageBase + 0x165331) - ($caveVa2 + 0x15B)))) # je ->0x165331
    WN ($stub5 + 0x1B) (FlagTest ($caveVa2 + 0x15B))                                        # cmp byte[flag],0
    WN ($stub5 + 0x22) ([byte[]](0x0F,0x85) + [BitConverter]::GetBytes([int](($ImageBase + 0x165331) - ($caveVa2 + 0x168)))) # jne ->0x165331
    WN ($stub5 + 0x28) ([byte[]](0x48,0x8B,0x46,0x28))                                      # mov rax,[rsi+0x28]
    WN ($stub5 + 0x2C) ([byte[]](0x48,0x39,0x46,0x20))                                      # cmp [rsi+0x20],rax
    WN ($stub5 + 0x30) ([byte[]](0x0F,0x85) + [BitConverter]::GetBytes([int](($ImageBase + 0x165331) - ($caveVa2 + 0x176)))) # jne ->0x165331
    WN ($stub5 + 0x36) (FlagSet ($caveVa2 + 0x176))                                         # mov byte[flag],1
    WN ($stub5 + 0x3D) ([byte[]](0x48,0x8B,0xCE))                                           # mov rcx,rsi
    WN ($stub5 + 0x40) ([byte[]](0xE8) + (Rel32 ($caveVa2 + 0x185) ($ImageBase + 0x165E30))) # call launchDefaultSessionCommand
    WN ($stub5 + 0x45) (FlagClr ($caveVa2 + 0x185))                                         # mov byte[flag],0
    WN ($stub5 + 0x4C) ([byte[]](0xE9) + (Rel32 ($caveVa2 + 0x191) ($ImageBase + 0x165331))) # jmp ->0x165331

    # site 0x16524A: JNZ 0x165331 (0F 85 E1 00 00 00) -> JMP stub5 + NOP
    $rvaN4 = [Int64]0x16524A; $oN4 = FoN $rvaN4
    $seq4 = [byte[]](0x0F,0x85,0xE1,0x00,0x00,0x00)
    for ($i = 0; $i -lt $seq4.Length; $i++) {
        if ($nb2[$oN4 + $i] -ne $seq4[$i]) { throw "ABORT: bad pattern at NuBase10 0x16524A" }
    }
    WN $oN4 (([byte[]](0xE9) + (Rel32 ($ImageBase + $rvaN4 + 5) ($caveVa2 + 0x140))) + @(0x90))

    # v12: boost::lexical_cast<ulong> throw path -> return 0.
    # Sole caller is Nu::CommandContext::argumentAsPointer: an unparseable
    # pointer argument now returns NULL (= arg absent) instead of throwing
    # bad_lexical_cast through executeCommand, which leaked the reentrancy
    # counter (mgr+0xC) and froze the UI in the dead command's pick filter.
    $rvaN5 = [Int64]0x15C1A7; $oN5 = FoN $rvaN5
    $seq5 = [byte[]](0x48,0x8D,0x15,0xDA,0xB2,0x2B,0x00,0x48,0x8D,0x4C,0x24,0x20,0xFF,0x15,0x2F,0x39)
    for ($i = 0; $i -lt $seq5.Length; $i++) {
        if ($nb2[$oN5 + $i] -ne $seq5[$i]) { throw "ABORT: bad pattern at NuBase10 0x15C1A7" }
    }
    WN $oN5         ([byte[]](0x48,0x8D,0x4D,0xC0))                                          # lea rcx,[rbp-0x40] (streambuf)
    WN ($oN5 + 0x4) ([byte[]](0xFF,0x15) + [BitConverter]::GetBytes([int](0x3FF840 - 0x15C1B1)))  # call ~basic_streambuf
    WN ($oN5 + 0xA) ([byte[]](0x31,0xC0))                                                    # xor eax,eax
    WN ($oN5 + 0xC) ([byte[]](0xE9) + [BitConverter]::GetBytes([int](0x30)))                 # jmp ->0x15C1E8
    $padN5 = $oN5 + 0x11
    $endN5 = FoN 0x15C1E8
    while ($padN5 -lt $endN5) { WN $padN5 ([byte[]](0x90)); $padN5++ }
    [IO.File]::WriteAllBytes($nuBaseDst, $nb2)
    $nuBaseHash = Sha256 $nuBaseDst
    if ($nuBaseHash -ne $HASH_NUB_PATCHED) { throw "ABORT: NuBase10 output hash mismatch ($nuBaseHash)" }
    if ($OutputOnly) {
        Write-Output "Wrote patched NuBase10.dll: $nuBaseDst"
        Write-Output "SHA256: $nuBaseHash  [OK]"
    }
}

if ($OutputOnly) { return }

# ---------- INSTALL ----------
if (-not $uiDone) {
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
}

if ($nuBaseDst -and (Test-Path $nuBasePath)) {
    Assert-KnownNuBaseDll $nuBasePath
    if ((Sha256 $nuBasePath) -ne $HASH_NUB_PATCHED) {
        if (-not (Test-Path $nuBaseBakPath)) {
            Copy-Item $nuBasePath $nuBaseBakPath
            Write-Output "Backup created: $nuBaseBakPath"
        }
        Copy-Item $nuBaseDst $nuBasePath -Force
        $nuInstalledHash = Sha256 $nuBasePath
        if ($nuInstalledHash -ne $HASH_NUB_PATCHED) { throw "ABORT: installed NuBase10 hash mismatch ($nuInstalledHash)" }
        Write-Output "Installed patched NuBase10.dll: $nuBasePath"
        Write-Output "SHA256: $nuInstalledHash  [OK]"
    } else {
        Write-Output "NuBase10.dll already patched."
    }
}

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
