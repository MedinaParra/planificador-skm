param(
    [string]$Source = 'build-source',
    [string]$Evidence = 'build-evidence'
)
$ErrorActionPreference = 'Stop'
$Source = (Resolve-Path $Source).Path
$Evidence = [IO.Path]::GetFullPath($Evidence)
New-Item -ItemType Directory -Path $Evidence -Force | Out-Null
foreach ($name in @('rust-version.log','cargo-version.log','fmt.log','build.log','planner-tests.log','skm-shell-tests.log','skm-preview-tests.log','portable-path-compile.log','portable-path-tests.log','portable-path-tests.exe','build-receipt.json')) {
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

if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Source)).AvailableFreeSpace -lt 8GB) {
    throw 'Less than 8 GiB free before Windows build; no build started'
}
$rustVersion = Invoke-Logged 'rust-version' 'rustc' @('+1.95.0', '-vV')
$cargoVersion = Invoke-Logged 'cargo-version' 'cargo' @('+1.95.0', '-V')
if ($rustVersion -notmatch 'rustc 1\.95\.0' -or $rustVersion -notmatch 'host: x86_64-pc-windows-msvc') {
    throw 'Unexpected Rust version or Windows host target'
}
$null = Invoke-Logged 'fmt' 'cargo' @('+1.95.0', 'fmt', '--all', '--check')
$buildArgs = @('+1.95.0', 'build', '--locked', '--release', '--target', 'x86_64-pc-windows-msvc', '-p', 'solidcraft', '--features', 'portable')
$null = Invoke-Logged 'build' 'cargo' $buildArgs
$exe = Join-Path $env:CARGO_TARGET_DIR 'x86_64-pc-windows-msvc/release/solidcraft.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'No desktop executable was produced' }

$productionExeSha = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()

# One Cargo invocation unifies the two test packages without changing the already-built app.
# Test-only trust features remain in test artifacts, never in the production build command.
$tests = Invoke-Logged 'planner-tests' 'cargo' @(
    '+1.95.0', 'test', '--locked', '--release', '--target', 'x86_64-pc-windows-msvc',
    '-p', 'solidcraft-engine', '-p', 'solidcraft-ui-egui', '--features', 'portable',
    '--test', 'lift_plan', '--test', 'lift_plan_ui', '--test', 'portable_policy',
    '--', '--test-threads=1', '--nocapture'
)
$results = [regex]::Matches($tests, 'test result: ok\. (\d+) passed; 0 failed; 0 ignored; 0 measured; 0 filtered out')
$counts = @($results | ForEach-Object { [int]$_.Groups[1].Value })
if ($counts.Count -ne 3 -or $counts -notcontains 51 -or $counts -notcontains 65 -or $counts -notcontains 4) {
    throw "Unexpected regression coverage; expected whole targets 51, 65 and 4, got $($counts -join ', ')"
}
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
$lock = Get-Content -Raw (Join-Path $PSScriptRoot '../source-lock.json') | ConvertFrom-Json
$receipt = [ordered]@{
    build_status = 'PASS'
    engine_lift_plan = 'PASS'
    ui_lift_plan = 'PASS'
    portable_tests = 'PASS'
    skm_shell_tests = 'PASS'
    skm_shell_test_count = 5
    skm_full_gpu_preview = 'PASS'
    skm_preview_test_count = 1
    skm_preview_png_sha256 = $previewHashes
    skm_preview_adapter = $previewMetadata.adapter
    skm_preview_visual_review = 'PENDING_HUMAN_OR_ASSISTANT_IMAGE_INSPECTION'
    test_counts = $counts
    commands = $script:Commands
    path_test_count = $pathCount
    base_commit = $lock.base_commit
    delta_sha256 = $lock.delta_sha256
    portable_patch_sha256 = $lock.portable_patch_sha256
    skm_patch_sha256 = $lock.skm_patch_sha256
    skm_tree_sha256 = $lock.skm_tree_sha256
    source_commit = $env:GITHUB_SHA
    embedded_source_commit = 'unknown; cache trust disabled'
    target = 'x86_64-pc-windows-msvc'
    toolchain = $rustVersion.Trim()
    cargo_version = $cargoVersion.Trim()
    log_sha256 = @{}
    features = @('portable', 'raytrace-cpu', 'bundled-render-library')
    release_profile = @{debug=0; lto=$false; opt_level=3; jobs=2}
    build_command = @('cargo') + $buildArgs
    exe_sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    exe_bytes = (Get-Item -LiteralPath $exe).Length
    gui_status = 'NOT_YET_RUN'
    scope = 'Focused planner and portable gates; not full workspace CI/Clippy/wasm or operational lift validation'
    rt750 = 'NOT_VALIDATED'
}

foreach ($log in Get-ChildItem -LiteralPath $Evidence -Filter '*.log' -File) { $receipt.log_sha256[$log.Name] = (Get-FileHash -LiteralPath $log.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
$receipt | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $Evidence 'build-receipt.json')

