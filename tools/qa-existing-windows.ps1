param(
    [string]$Source = 'build-source',
    [string]$Evidence = 'build-evidence'
)
$ErrorActionPreference = 'Stop'
$Source = (Resolve-Path $Source).Path
$Evidence = [IO.Path]::GetFullPath($Evidence)
New-Item -ItemType Directory -Path $Evidence -Force | Out-Null
foreach ($name in @('rust-version.log','cargo-version.log','fmt.log','build.log','original-build.log','original-planner-tests.log','skm-shell-tests.log','skm-preview-tests.log','portable-path-compile.log','portable-path-tests.log','portable-path-tests.exe','build-receipt.json')) {
    if (Test-Path -LiteralPath (Join-Path $Evidence $name)) { throw "Previous evidence exists: $name; refusing to overwrite" }
}
$script:Commands = @()
$env:CARGO_BUILD_JOBS = '2'
$env:CARGO_TARGET_DIR = Join-Path $Source 'target'
$env:CARGO_PROFILE_RELEASE_DEBUG = '0'
$env:CARGO_PROFILE_RELEASE_LTO = 'false'
$env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS = '-C target-feature=+crt-static'
Remove-Item Env:RUSTFLAGS -ErrorAction SilentlyContinue
Remove-Item Env:CARGO_ENCODED_RUSTFLAGS -ErrorAction SilentlyContinue

function Invoke-Logged([string]$Name, [string]$Program, [string[]]$Arguments) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Program
    $psi.WorkingDirectory = $Source
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
    Write-Host "==> $Name"
    $process = [Diagnostics.Process]::Start($psi)
    # Persist partial logs even if Actions cancels the step at its time limit.
    $stdoutPath = Join-Path $Evidence "$Name.stdout.log"
    $stderrPath = Join-Path $Evidence "$Name.stderr.log"
    $stdoutFile = [IO.File]::Open($stdoutPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $stderrFile = [IO.File]::Open($stderrPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $stdout = $process.StandardOutput.BaseStream.CopyToAsync($stdoutFile)
    $stderr = $process.StandardError.BaseStream.CopyToAsync($stderrFile)
    $nextUpdate = [DateTime]::UtcNow
    $stoppedForReserve = $false
    while (-not $process.WaitForExit(2000)) {
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Source))
        if ($drive.AvailableFreeSpace -lt 2GB) {
            $stoppedForReserve = $true
            $process.Kill($true)
            $process.WaitForExit()
            break
        }
        if ([DateTime]::UtcNow -ge $nextUpdate) {
            Write-Host "$Name running; free bytes $($drive.AvailableFreeSpace)"
            $nextUpdate = [DateTime]::UtcNow.AddSeconds(60)
        }
    }
    $null = $stdout.GetAwaiter().GetResult()
    $null = $stderr.GetAwaiter().GetResult()
    $stdoutFile.Dispose()
    $stderrFile.Dispose()
    $text = [IO.File]::ReadAllText($stdoutPath) + "`n" + [IO.File]::ReadAllText($stderrPath)
    [IO.File]::WriteAllText((Join-Path $Evidence "$Name.log"), $text)
    $text -split "`n" | Select-Object -Last 100 | ForEach-Object { Write-Host $_ }
    $exitCode = $process.ExitCode
    $process.Dispose()
    $script:Commands += @{ name=$Name; program=$Program; arguments=$Arguments; exit_code=$exitCode; stopped_for_reserve=$stoppedForReserve }
    if ($stoppedForReserve) { throw "$Name stopped to preserve the 2 GiB reserve" }
    if ($exitCode -ne 0) { throw "$Name failed, exit $exitCode" }
    return $text
}


# This job never builds a production application. Its sole app is the pinned run8 artifact.
$producerCommit = 'a8b6b6c6a3186b3b45a62183b4e5c149ba78346f'
$producerRun = 41052482314
$artifactId = 12981956564
$productionExeSha = 'a69b7a3e3261b0e1881d54f3c0ffb863208d2e66444c483a71216c20ff3e57ee'
function Assert-Hash([string]$Path, [string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) { throw "SHA-256 mismatch: $Path" }
}
if ($env:GITHUB_REPOSITORY -ne 'MedinaParra/planificador-skm' -or $env:GITHUB_REF -eq 'refs/heads/main') { throw 'Private candidate repository/branch required' }
$download = [IO.Path]::GetFullPath('reused-production')
if (Test-Path -LiteralPath $download) { throw 'Refusing to overwrite an existing production artifact' }
New-Item -ItemType Directory -Path $download | Out-Null
if (-not $env:GH_TOKEN) { throw 'Job-scoped actions:read token required' }
try {
    $headers = @{ Authorization="Bearer $env:GH_TOKEN"; Accept='application/vnd.github+json'; 'X-GitHub-Api-Version'='2022-11-28' }
    $url = "https://api.github.com/repos/MedinaParra/planificador-skm/actions/artifacts/$artifactId"
    $meta = Invoke-RestMethod -Uri $url -Headers $headers
    if ($meta.id -ne $artifactId -or $meta.expired -or $meta.workflow_run.id -ne $producerRun -or $meta.workflow_run.head_sha -ne $producerCommit) {
        throw 'Artifact identity, run, source commit or retention mismatch'
    }
    $archive = Join-Path $download 'producer-artifact.zip'
    # curl strips Authorization on cross-origin redirects; never use --location-trusted.
    & curl.exe --fail --silent --show-error --location --header "Authorization: Bearer $env:GH_TOKEN" --header 'Accept: application/vnd.github+json' --output $archive "$url/zip"
    if ($LASTEXITCODE -ne 0) { throw 'Pinned producer artifact download failed' }
} finally { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue; $headers = $null }
Assert-Hash $archive '293005370de3e2f30d626ecfd27f793d7c81a611228a87c0d5edcc87dea34161'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($archive, (Join-Path $download 'archive'))
$prior = Join-Path $download 'archive/build-evidence'
$intermediate = Join-Path $prior 'NO_QA-intermediate.zip'
Assert-Hash $intermediate '78cc0ecf07d10e05b7ce172d09c3c834bbdd5b3c82d8fe56abbb561985a7ec5f'
[IO.Compression.ZipFile]::ExtractToDirectory($intermediate, (Join-Path $download 'intermediate'))
$exe = Join-Path $download 'solidcraft.exe'
Copy-Item -LiteralPath (Join-Path $download 'intermediate/NO_QA-intermediate/solidcraft.exe') -Destination $exe
Assert-Hash $exe $productionExeSha
if ((Get-Item -LiteralPath $exe).Length -ne 138636288) { throw 'Producer EXE size mismatch' }
$priorHashes = @{
    'build.log'='836c3099527641304c6266311e6e224b02809e3f5e294c8c3c3ff8a6ef58f1ca'
    'planner-tests.log'='a05efd22ef0bae1b840b9991bc245247f1b040d21933597b5ca3fc31d44e4caa'
    'source-receipt.json'='9ad0a81ff9ee92d98ff0ec5c40819cf2604c6b1cbc83d2f72579c8db5fb68273'
    'rust-version.log'='946309c1bbb667d8825b23967ae820780c33f84c05bbe66631562dd82dacd8ad'
    'cargo-version.log'='5e7fd150b544183b4001238004d88aa7035a7b424b6dfc840a0dda6bd0272958'
}
foreach ($name in $priorHashes.Keys) {
    Assert-Hash (Join-Path $prior $name) $priorHashes[$name]
    Copy-Item -LiteralPath (Join-Path $prior $name) -Destination (Join-Path $Evidence "original-$name")
}
$build = [IO.File]::ReadAllText((Join-Path $prior 'build.log'))
if ($build -notmatch 'Finished `release` profile \[optimized\] target\(s\) in 40m 39s') { throw 'Original production build completion not verified' }
$tests = [IO.File]::ReadAllText((Join-Path $prior 'planner-tests.log'))
$results = [regex]::Matches($tests, 'test result: ok\. (\d+) passed; 0 failed; 0 ignored; 0 measured; 0 filtered out')
$counts = @($results | ForEach-Object { [int]$_.Groups[1].Value })
if ($counts.Count -ne 3 -or $counts -notcontains 51 -or $counts -notcontains 65 -or $counts -notcontains 4) { throw 'Original planner gates not verified' }
$producerSource = Get-Content -LiteralPath (Join-Path $prior 'source-receipt.json') -Raw | ConvertFrom-Json
if ($producerSource.status -ne 'PASS' -or $producerSource.reconstructed_tree_sha256 -ne '532f657d929d4d74dc38c991a22280354a464bfb258e5d0a4bc7d229f00a2083') { throw 'Producer source tree provenance mismatch' }
# Independently prove that the entire QA tree differs from the original only by this
# Unix-only unit-test guard and the pinned integration-test-only GPU capture fix.
# No production bytes or any other manifest row may differ.
$proof = @'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); rows=[]; changed=0
old=b'    #[test]\n    fn links_only_where_it_may() {'
new=b'    #[cfg(unix)]\n'+old
for p in sorted(root.rglob('*'), key=lambda p:p.relative_to(root).as_posix()):
    rel=p.relative_to(root)
    if rel.parts[0]=='.git': continue
    if p.is_symlink(): raise SystemExit('Unexpected source symlink')
    if not p.is_file(): continue
    data=p.read_bytes()
    if rel.as_posix()=='crates/ui-egui/src/cli_link.rs':
        if data.count(new)!=1: raise SystemExit('Missing exact test-only guard')
        data=data.replace(new,old,1); changed+=1
    digest=hashlib.sha256(data).hexdigest()
    if rel.as_posix()=='crates/ui-egui/tests/skm_preview.rs':
        assert digest=='25b8d1954ca7360f7c8e10f8c544727bdaa01e35b1a1aa6bc72cd653fe731299','Unexpected GPU integration test bytes'
        digest='050d322a894efaf9fad3673fc189fa0c5131c64c02c1bd92eaa7811da47b2dec'; changed+=1
    rows.append(digest+'  '+rel.as_posix()+'\n')
assert changed==2 and len(rows)==3207
actual=hashlib.sha256(''.join(rows).encode()).hexdigest()
assert actual=='532f657d929d4d74dc38c991a22280354a464bfb258e5d0a4bc7d229f00a2083',actual
print('PASS: full QA tree equals producer tree after reversing only Unix test guard and the pinned GPU integration-test row')
'@
$null = Invoke-Logged 'qa-source-equivalence' 'python' @('-c', $proof, $Source)
if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Source)).AvailableFreeSpace -lt 8GB) { throw 'Less than 8 GiB free before QA compilation' }
$rustVersion = Invoke-Logged 'rust-version' 'rustc' @('+1.95.0','-vV')
$cargoVersion = Invoke-Logged 'cargo-version' 'cargo' @('+1.95.0','-V')
if ($rustVersion -notmatch 'rustc 1\.95\.0' -or $rustVersion -notmatch 'host: x86_64-pc-windows-msvc') { throw 'Unexpected QA toolchain' }
$null = Invoke-Logged 'fmt' 'cargo' @('+1.95.0','fmt','--all','--check')
# This compiles the full UI unit-test harness, but executes exactly the SKM shell tests.
# It remains a separate test invocation: no test-only trust reaches the production app.
$shellTests = Invoke-Logged 'skm-shell-tests' 'cargo' @(
    '+1.95.0', 'test', '--locked', '--release', '--target', 'x86_64-pc-windows-msvc',
    '-p', 'solidcraft-ui-egui', '--features', 'portable', '--lib', 'skm_workspace::',
    '--', '--test-threads=1', '--nocapture'
)
$shellResults = [regex]::Matches($shellTests, 'test result: ok\. (\d+) passed; 0 failed; 0 ignored; 0 measured; (\d+) filtered out')
if ($shellResults.Count -ne 1 -or [int]$shellResults[0].Groups[1].Value -ne 5) {
    throw 'Expected exactly five passing internal SKM shell tests'
}
$previewDir = Join-Path $Evidence 'skm-preview'
if (Test-Path -LiteralPath $previewDir) { throw 'Refusing stale SKM preview evidence' }
$env:SKM_PREVIEW_DIR = $previewDir
try {
    $previewTests = Invoke-Logged 'skm-preview-tests' 'cargo' @(
        '+1.95.0', 'test', '--locked', '--release', '--target', 'x86_64-pc-windows-msvc',
        '-p', 'solidcraft-ui-egui', '--features', 'portable', '--test', 'skm_preview',
        '--', '--test-threads=1', '--nocapture'
    )
} finally { Remove-Item Env:SKM_PREVIEW_DIR -ErrorAction SilentlyContinue }
if ($previewTests -notmatch 'test result: ok\. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out') {
    throw 'Full application GPU preview gate did not pass'
}
$previewHashes = @{}
$previewNames = @('skm-0-obra.png','skm-1-grua.png','skm-2-carga.png','skm-3-maniobra.png','skm-4-verificaciones.png','skm-5-informe.png')
if (@(Get-ChildItem -LiteralPath $previewDir -Filter '*.png' -File).Count -ne 6) { throw 'Exactly six SKM PNGs required' }
foreach ($name in $previewNames) {
    $path = Join-Path $previewDir $name
    $png = [IO.File]::ReadAllBytes($path)
    if ($png.Length -lt 33 -or [BitConverter]::ToString($png,0,8) -ne '89-50-4E-47-0D-0A-1A-0A' -or
        [BitConverter]::ToString($png,16,8) -ne '00-00-06-40-00-00-03-E8') {
        throw "Invalid 1600x1000 preview PNG: $name"
    }
    $previewHashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
$previewMetadata = Get-Content -LiteralPath (Join-Path $previewDir 'capture.json') -Raw | ConvertFrom-Json
if (-not $previewMetadata.adapter -or $previewMetadata.operational_validation -ne $false -or
    $previewMetadata.width -ne 1600 -or $previewMetadata.height -ne 1000 -or
    $previewMetadata.capture -notmatch 'production GPU viewport callbacks; single render target, no compositing') {
    throw 'Full application preview provenance missing'
}
# Require evidence for each fresh scene render, not merely six valid PNG headers.
function Assert-FiniteNumber($Value, [string]$Label) {
    if ($null -eq $Value -or -not ($Value -is [double] -or $Value -is [long] -or $Value -is [int] -or $Value -is [decimal]) -or
        [double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value)) { throw "Non-finite/non-numeric capture field: $Label" }
}
$areas = @('obra','grua','carga','maniobra','verificaciones','informe')
$captures = @($previewMetadata.captures)
if ($captures.Count -ne 6 -or $previewMetadata.fresh_capture_gate -notmatch 'every PNG has triangles > 0') { throw 'Six fresh geometry records required' }
if (@($previewMetadata.warmup | Where-Object { $_.triangles -gt 0 }).Count -lt 1) { throw 'Warmup never demonstrated actual geometry' }
$previewStatsHashes = @{}
for ($i=0; $i -lt 6; $i++) {
    $capture = $captures[$i]
    if ($capture.area -ne $areas[$i] -or $capture.bodies -ne 33 -or $capture.draw_calls -le 0 -or $capture.triangles -le 0 -or $capture.camera_zoom_factor -ne 1.001) {
        throw "Missing fresh model geometry in capture $i"
    }
    Assert-FiniteNumber $capture.camera_distance_before "camera-before-$i"
    Assert-FiniteNumber $capture.camera_distance_after "camera-after-$i"
    if ($capture.camera_distance_before -le 0 -or $capture.camera_distance_after -le $capture.camera_distance_before) { throw "Camera cache invalidation missing in capture $i" }
    if (@($capture.bounds.min).Count -ne 3 -or @($capture.bounds.max).Count -ne 3) { throw "Missing 3D bounds in capture $i" }
    for ($axis=0; $axis -lt 3; $axis++) {
        Assert-FiniteNumber $capture.bounds.min[$axis] "bounds-min-$i-$axis"
        Assert-FiniteNumber $capture.bounds.max[$axis] "bounds-max-$i-$axis"
        if ($capture.bounds.max[$axis] -le $capture.bounds.min[$axis]) { throw "Degenerate scene bounds in capture $i" }
    }
    $statsName = [IO.Path]::ChangeExtension($previewNames[$i], 'stats.json')
    $statsPath = Join-Path $previewDir $statsName
    $stats = Get-Content -LiteralPath $statsPath -Raw | ConvertFrom-Json
    if ($stats.status -ne 'FRESH_GEOMETRY_RENDER' -or $stats.draw_calls -ne $capture.draw_calls -or $stats.triangles -ne $capture.triangles -or $stats.camera_distance -ne $capture.camera_distance_after) {
        throw "Per-PNG draw evidence mismatch: $statsName"
    }
    $previewStatsHashes[$statsName] = (Get-FileHash -LiteralPath $statsPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $productionExeSha) {
    throw 'Production executable changed during tests; test artifacts cannot replace the app'
}

$stdExe = Join-Path $Evidence 'portable-path-tests.exe'
$null = Invoke-Logged 'portable-path-compile' 'rustc' @(
    '+1.95.0', '--edition=2024', '--test', 'crates/geom/src/portable.rs',
    '--cfg', 'feature="portable"', '-o', $stdExe
)
$pathTests = Invoke-Logged 'portable-path-tests' $stdExe @('--test-threads=1', '--nocapture')
if ($pathTests -notmatch 'test result: ok\. (\d+) passed; 0 failed; 0 ignored; 0 measured; 0 filtered out' -or [int]$Matches[1] -ne 8) {
    throw 'Portable path policy tests did not pass in full on Windows'
}
$pathCount = [int]$Matches[1]

$qaSource = Get-Content -LiteralPath (Join-Path $Evidence 'source-receipt.json') -Raw | ConvertFrom-Json
if ($qaSource.status -ne 'PASS' -or $qaSource.production_tree_sha256 -ne $producerSource.reconstructed_tree_sha256 -or -not $qaSource.qa_test_patch_sha256) { throw 'QA source receipt lacks original-tree/test-patch provenance' }
Assert-Hash $exe $productionExeSha
$receipt = [ordered]@{
    build_status='PASS'; engine_lift_plan='PASS'; ui_lift_plan='PASS'; portable_tests='PASS'
    build_and_planner_provenance='REUSED_VERIFIED_RUN8_EVIDENCE_NOT_RERUN'
    original_artifact_id=$artifactId; original_run_id=$producerRun
    original_artifact_sha256='293005370de3e2f30d626ecfd27f793d7c81a611228a87c0d5edcc87dea34161'
    original_log_sha256=$priorHashes; test_counts=$counts
    skm_shell_tests='PASS'; skm_shell_test_count=5
    skm_full_gpu_preview='PASS'; skm_preview_test_count=1
    skm_preview_png_sha256=$previewHashes; skm_preview_stats_sha256=$previewStatsHashes; skm_preview_adapter=$previewMetadata.adapter
    skm_preview_visual_review='PENDING_HUMAN_OR_ASSISTANT_IMAGE_INSPECTION'
    commands=$script:Commands; path_test_count=$pathCount
    base_commit=$producerSource.base_commit; delta_sha256=$producerSource.delta_sha256
    portable_patch_sha256=$producerSource.portable_patch_sha256; skm_patch_sha256=$producerSource.skm_patch_sha256
    source_commit=$producerCommit; producer_source_commit=$producerCommit; qa_commit=$env:GITHUB_SHA
    producer_tree_sha256=$producerSource.reconstructed_tree_sha256; skm_tree_sha256=$producerSource.skm_tree_sha256
    qa_tree_sha256=$qaSource.reconstructed_tree_sha256; qa_test_patch_sha256=$qaSource.qa_test_patch_sha256
    qa_source_difference='Only #[cfg(unix)] on inherited Unix symlink test and pinned skm_preview integration-test capture fix; inverse full production-tree hash verified'
    qa_preview_test_sha256='25b8d1954ca7360f7c8e10f8c544727bdaa01e35b1a1aa6bc72cd653fe731299'
    embedded_source_commit='unknown; cache trust disabled'
    target='x86_64-pc-windows-msvc'; toolchain=$rustVersion.Trim(); cargo_version=$cargoVersion.Trim()
    features=@('portable','raytrace-cpu','bundled-render-library')
    release_profile=@{debug=0;lto=$false;opt_level=3;jobs=2}
    build_command=@('cargo','+1.95.0','build','--locked','--release','--target','x86_64-pc-windows-msvc','-p','solidcraft','--features','portable')
    production_rebuilt=$false; exe_sha256=$productionExeSha; exe_bytes=(Get-Item -LiteralPath $exe).Length
    gui_status='NOT_YET_RUN'; rt750='NOT_VALIDATED'; log_sha256=@{}
    scope='Reused production EXE + verified prior planner gates; new shell/GPU/path QA. Not full CI or operational validation.'
}
foreach ($log in Get-ChildItem -LiteralPath $Evidence -Filter '*.log' -File) { $receipt.log_sha256[$log.Name]=(Get-FileHash -LiteralPath $log.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
$receipt | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $Evidence 'build-receipt.json')
