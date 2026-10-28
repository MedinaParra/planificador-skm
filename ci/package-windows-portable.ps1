# App-only ZIP packaging. Never invokes WiX/MSI, installs, launches, signs or publishes.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Exe,
    [Parameter(Mandatory = $true)][string] $SourceRoot,
    [Parameter(Mandatory = $true)][string] $BuildReceipt,
    [Parameter(Mandatory = $true)][string] $SmokeResult,
    [Parameter(Mandatory = $true)][string] $OutputDir
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows required' }
$Exe=(Resolve-Path -LiteralPath $Exe).Path
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path
$BuildReceipt=(Resolve-Path -LiteralPath $BuildReceipt).Path
$SmokeResult=(Resolve-Path -LiteralPath $SmokeResult).Path
if (Test-Path -LiteralPath $OutputDir) { throw 'OutputDir must be new; existing deliveries are preserved' }
$OutputDir=[IO.Path]::GetFullPath($OutputDir)
$build=Get-Content -LiteralPath $BuildReceipt -Raw -Encoding UTF8 | ConvertFrom-Json
$smoke=Get-Content -LiteralPath $SmokeResult -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($gate in @('build_status','engine_lift_plan','ui_lift_plan','portable_tests')) {
    if (-not $build.PSObject.Properties[$gate] -or $build.$gate -ne 'PASS') { throw "Required build receipt gate $gate is not PASS" }
}
foreach ($field in @('base_commit','delta_sha256','portable_patch_sha256','source_commit','toolchain','target','features','exe_sha256')) {
    if (-not $build.PSObject.Properties[$field] -or -not $build.$field) { throw "Build receipt field $field missing" }
}
if ($build.base_commit -ne '7770f8982de8bf00cabfe421b7f563b34c7af90f') { throw 'Unexpected base commit' }
if ($build.target -ne 'x86_64-pc-windows-msvc') { throw 'Build receipt target is not Windows x64 MSVC' }
if (@($build.features) -notcontains 'portable') { throw 'Mandatory portable feature absent' }
$exeSha=(Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash.ToLowerInvariant()
if ($build.exe_sha256 -ne $exeSha -or $smoke.exe_sha256 -ne $exeSha) { throw 'Receipts do not belong to this exact EXE' }
if ($smoke.status -ne 'PASS') { throw 'Native GUI smoke did not pass' }
foreach ($name in @('normal','safe-mode','moved-unicode','data-file-collision')) {
    $match=@($smoke.cases | Where-Object { $_.name -eq $name -and $_.status -eq 'PASS' })
    if ($match.Count -ne 1) { throw "Missing or duplicate passing smoke case $name" }
}
if ($smoke.rt750_status -ne 'NOT_VALIDATED') { throw 'Safety status missing' }

# Parse the real PE, checking bounds before every offset read.
$bytes=[IO.File]::ReadAllBytes($Exe)
function U16([long] $At) {
    if ($At -lt 0 -or $At+2 -gt $bytes.LongLength) { throw 'Truncated PE' }
    return [BitConverter]::ToUInt16($bytes,[int]$At)
}
function U32([long] $At) {
    if ($At -lt 0 -or $At+4 -gt $bytes.LongLength) { throw 'Truncated PE' }
    return [BitConverter]::ToUInt32($bytes,[int]$At)
}
if ((U16 0) -ne 0x5a4d) { throw 'EXE has no MZ signature' }
$pe=U32 0x3c
if ((U32 $pe) -ne 0x4550) { throw 'EXE has no PE signature' }
if ((U16 ($pe+4)) -ne 0x8664) { throw 'EXE is not x64' }
if ((U16 ($pe+24)) -ne 0x20b) { throw 'EXE is not PE32+' }
if ((U16 ($pe+0x5c)) -ne 2) { throw 'EXE is not Windows GUI subsystem' }
& (Join-Path $SourceRoot 'packaging/windows/check-icon.ps1') -Path $Exe

# Use the installed MSVC tool; do not download or install anything.
$dumpbin=Get-Command dumpbin.exe -ErrorAction SilentlyContinue
if ($dumpbin) { $dumpbinPath=$dumpbin.Source }
else {
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'MSVC dumpbin/vswhere not found' }
    $install=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $install) { throw 'Cannot locate MSVC installation' }
    $candidates=@(Get-ChildItem -Path (Join-Path $install 'VC/Tools/MSVC/*/bin/Hostx64/x64/dumpbin.exe') -File | Sort-Object FullName -Descending)
    if ($candidates.Count -eq 0) { throw 'MSVC dumpbin missing' }
    $dumpbinPath=$candidates[0].FullName
}
$depends=@(& $dumpbinPath /dependents $Exe 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'dumpbin /dependents failed' }
$imports=@($depends | ForEach-Object { if ("$_" -match '^\s+([A-Za-z0-9_.-]+\.(?:dll|drv))\s*$') { $Matches[1].ToLowerInvariant() } } | Sort-Object -Unique)
if ($imports.Count -eq 0) { throw 'No import dependencies parsed; cannot verify CRT policy' }
$crt=@($imports | Where-Object { $_ -match '^(vcruntime|msvcp|concrt|ucrtbase|msvcr|api-ms-win-crt)' })
if ($crt.Count) { throw "Dynamic CRT dependency found: $($crt -join ', ')" }
$systemDir=[Environment]::SystemDirectory
foreach ($name in $imports) {
    if ($name -match '^(api-ms-win-|ext-ms-win-)') { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $systemDir $name) -PathType Leaf)) { throw "Non-system dependency is not bundled: $name" }
}
$signature=Get-AuthenticodeSignature -LiteralPath $Exe
if ($signature.Status -ne 'NotSigned') { throw "Unexpected signing state: $($signature.Status); this pipeline does not sign" }

New-Item -ItemType Directory -Path $OutputDir | Out-Null
$name='SolidCraft-Planificador-05C-windows-x64-portable'
$stage=Join-Path $OutputDir $name
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item -LiteralPath $Exe -Destination (Join-Path $stage 'solidcraft.exe')
foreach ($f in @('LICENSE-MIT','LICENSE-APACHE','NOTICE','THIRD-PARTY-LICENSES.txt','ATTRIBUTION.md')) {
    Copy-Item -LiteralPath (Join-Path $SourceRoot $f) -Destination (Join-Path $stage $f)
}
# Preserve attribution rows for planner additions not yet folded into the upstream table.
$pending=Join-Path $SourceRoot 'attribution/pending'
foreach ($f in @('lift-plan.md','lift-package-inspect.md','lift-step-units-inspect.md','portable-policy.md')) {
    $p=Join-Path $pending $f
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Planner attribution missing: $f" }
    Copy-Item -LiteralPath $p -Destination (Join-Path $stage ('ATTRIBUTION-'+$f))
}
Copy-Item -LiteralPath $BuildReceipt -Destination (Join-Path $stage 'BUILD-RECEIPT.json')
Copy-Item -LiteralPath $SmokeResult -Destination (Join-Path $stage 'GUI-SMOKE-RESULT.json')
$readme=@'
SolidCraft - Planificador de izaje 05C / Windows x64 portable experimental

NO OPERATIVO / NOT_VALIDATED. RT750 NOT_VALIDATED.
No datos OEM validados, capacidad de izaje ni aprobacion operacional.
La geometria CAD no certifica estabilidad, resistencia, suelo o despejes.

Extraiga todo el ZIP a una carpeta escribible y abra solidcraft.exe.
No se instala, no requiere un servidor web y no incluye CLI/MCP.
El estado de la aplicacion queda en data junto al ejecutable; no mueva
solo el EXE si desea conservar ese estado. Guarde sus proyectos a voluntad.
Para probar software rendering: solidcraft.exe --safe-mode

Las integraciones automaticas de IA, control localhost, tokens y actualizaciones
estan deshabilitadas en esta compilacion portable. No se adoptan preferencias
de instalaciones anteriores. Si data no se puede usar, el inicio falla cerrado.

Aplicacion sin firma digital. Windows puede mostrar un aviso de confianza.
No desactive protecciones para abrir archivos de procedencia desconocida.
Compruebe SHA256SUMS y el recibo entregado por separado.

Esta entrega fue sometida a los gates consignados en BUILD-RECEIPT.json y
GUI-SMOKE-RESULT.json. No es certificacion de izaje ni garantia de compatibilidad
con toda version de Windows o driver. La captura y comprobacion de red son
evidencia acotada del runner, no una promesa de cero rastros del sistema operativo.
'@
[IO.File]::WriteAllText((Join-Path $stage 'LEEME.txt'),$readme,(New-Object Text.UTF8Encoding($false)))
$peReceipt=@{ schema=1; exe_sha256=$exeSha; machine='0x8664'; pe_format='PE32+'; subsystem=2; icon_check='PASS'; imports=$imports; dynamic_crt_imports=@(); imports_present_on_tested_runner=$true; signed=$false; authenticode_status=[string]$signature.Status; dynamic_load_dependencies_exhaustively_audited=$false }
$peReceipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage 'PE-DEPENDENCIES.json') -Encoding UTF8
$depends | Set-Content -LiteralPath (Join-Path $OutputDir 'dumpbin-dependents.txt') -Encoding UTF8
$files=@(Get-ChildItem -LiteralPath $stage -File | Sort-Object Name)
$sums=@($files | ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(),$_.Name })
[IO.File]::WriteAllLines((Join-Path $stage 'SHA256SUMS'),$sums,(New-Object Text.UTF8Encoding($false)))
$zip=Join-Path $OutputDir ($name+'.zip')
Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal
if ((Get-Item -LiteralPath $zip).Length -gt 250MB) { throw 'Portable ZIP exceeds the 250 MiB artifact cap; do not upload' }

# Reopen and hash every member in memory; never extract over an existing tree.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::OpenRead($zip)
try {
    $expected=@(Get-ChildItem -LiteralPath $stage -File)
    $actual=@($archive.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
    if ($actual.Count -ne $expected.Count) { throw 'ZIP inventory count mismatch' }
    foreach ($file in $expected) {
        $entries=@($actual | Where-Object { $_.FullName.Replace('\','/') -eq ($name+'/'+$file.Name) })
        if ($entries.Count -ne 1) { throw "ZIP member missing or duplicated: $($file.Name)" }
        $entry=$entries[0]
        $stream=$entry.Open(); $hasher=[Security.Cryptography.SHA256]::Create()
        try { $got=([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $hasher.Dispose(); $stream.Dispose() }
        if ($got -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()) { throw "ZIP member hash mismatch: $($file.Name)" }
    }
} finally { $archive.Dispose() }
$receipt=@{ schema=1; status='PASS'; filename=[IO.Path]::GetFileName($zip); zip_sha256=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant(); size_bytes=(Get-Item -LiteralPath $zip).Length; exe_sha256=$exeSha; file_count=$expected.Count; zip_inventory_and_hashes='PASS'; base_commit=$build.base_commit; source_commit=$build.source_commit; delta_sha256=$build.delta_sha256; portable_patch_sha256=$build.portable_patch_sha256; rt750_status='NOT_VALIDATED'; created_utc=[DateTime]::UtcNow.ToString('o'); signing='NOT_SIGNED'; installation='NONE'; cli_or_mcp_included=$false }
$receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDir 'package-result.json') -Encoding UTF8
Write-Output "PASS: $zip ($($receipt.size_bytes) bytes), SHA256 $($receipt.zip_sha256)"
