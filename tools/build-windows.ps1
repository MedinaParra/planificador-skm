param(
    [string]$Source = 'build-source',
    [string]$Evidence = 'build-evidence'
)
$ErrorActionPreference = 'Stop'
$Source = (Resolve-Path $Source).Path
$Evidence = [IO.Path]::GetFullPath($Evidence)
New-Item -ItemType Directory -Path $Evidence -Force | Out-Null
foreach ($name in @('rust-version.log','cargo-version.log','fmt.log','build.log','planner-tests.log','portable-path-compile.log','portable-path-tests.log','portable-path-tests.exe','build-receipt.json')) {
    if (Test-Path -LiteralPath (Join-Path $Evidence $name)) { throw "Previous evidence exists: $name; refusing to overwrite" }
}
$script:Commands = @()
$env:CARGO_BUILD_JOBS = '1'
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
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $nextUpdate = [DateTime]::UtcNow
    $stoppedForReserve = $false
    while (-not $process.WaitForExit(2000)) {
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Source))
        if ($drive.AvailableFreeSpace -lt 1.5GB) {
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
    $text = $stdout.Result + "`n" + $stderr.Result
    [IO.File]::WriteAllText((Join-Path $Evidence "$Name.log"), $text)
    $text -split "`n" | Select-Object -Last 100 | ForEach-Object { Write-Host $_ }
    $exitCode = $process.ExitCode
    $process.Dispose()
    $script:Commands += @{ name=$Name; program=$Program; arguments=$Arguments; exit_code=$exitCode; stopped_for_reserve=$stoppedForReserve }
    if ($stoppedForReserve) { throw "$Name stopped to preserve the 1.5 GiB reserve" }
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
if ($counts.Count -ne 3 -or $counts -notcontains 40 -or $counts -notcontains 65 -or $counts -notcontains 4) {
    throw "Unexpected regression coverage; expected whole targets 40, 65 and 4, got $($counts -join ', ')"
}
$stdExe = Join-Path $Evidence 'portable-path-tests.exe'
$null = Invoke-Logged 'portable-path-compile' 'rustc' @(
    '+1.95.0', '--edition=2024', '--test', 'crates/geom/src/portable.rs',
    '--cfg', 'feature="portable"', '-o', $stdExe
)
$pathTests = Invoke-Logged 'portable-path-tests' $stdExe @('--test-threads=1', '--nocapture')
if ($pathTests -notmatch 'test result: ok\. (\d+) passed; 0 failed; 0 ignored; 0 measured; 0 filtered out' -or [int]$Matches[1] -lt 8) {
    throw 'Portable path policy tests did not pass in full on Windows'
}
$pathCount = [int]$Matches[1]
$lock = Get-Content -Raw (Join-Path $PSScriptRoot '../source-lock.json') | ConvertFrom-Json
$receipt = [ordered]@{
    build_status = 'PASS'
    engine_lift_plan = 'PASS'
    ui_lift_plan = 'PASS'
    portable_tests = 'PASS'
    test_counts = $counts
    commands = $script:Commands
    path_test_count = $pathCount
    base_commit = $lock.base_commit
    delta_sha256 = $lock.delta_sha256
    portable_patch_sha256 = $lock.portable_patch_sha256
    source_commit = $env:GITHUB_SHA
    embedded_source_commit = 'unknown; cache trust disabled'
    target = 'x86_64-pc-windows-msvc'
    toolchain = $rustVersion.Trim()
    cargo_version = $cargoVersion.Trim()
    log_sha256 = @{}
    features = @('portable', 'raytrace-cpu', 'bundled-render-library')
    release_profile = @{debug=0; lto=$false; opt_level=3; jobs=1}
    build_command = @('cargo') + $buildArgs
    exe_sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    exe_bytes = (Get-Item -LiteralPath $exe).Length
    gui_status = 'NOT_YET_RUN'
    scope = 'Focused planner and portable gates; not full workspace CI/Clippy/wasm or operational lift validation'
    rt750 = 'NOT_VALIDATED'
}

foreach ($log in Get-ChildItem -LiteralPath $Evidence -Filter '*.log' -File) { $receipt.log_sha256[$log.Name] = (Get-FileHash -LiteralPath $log.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
$receipt | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $Evidence 'build-receipt.json')
