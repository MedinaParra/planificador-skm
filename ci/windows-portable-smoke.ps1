# Windows PowerShell 5.1. Isolated GUI QA, no control channel and no credentials.
# This script never changes ACLs, deletes existing folders, or touches source data.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Exe,
    [Parameter(Mandatory = $true)][string] $EvidenceDir,
    [int] $StartupTimeoutSeconds = 180
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows required' }
if ($StartupTimeoutSeconds -lt 30 -or $StartupTimeoutSeconds -gt 300) { throw 'Startup timeout must be 30..300 seconds' }
$Exe = (Resolve-Path -LiteralPath $Exe).Path
if (Test-Path -LiteralPath $EvidenceDir) { throw 'EvidenceDir must not already exist; preserve previous evidence' }
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Path $EvidenceDir | Out-Null
$ExeHash = (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash.ToLowerInvariant()

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public sealed class PortableSmokeCapture {
    private readonly object gate = new object();
    private readonly StringBuilder error = new StringBuilder(), output = new StringBuilder();
    private bool truncated;
    private void Append(StringBuilder target, string line) {
        if (line == null) return;
        lock(gate) {
            if (target.Length + line.Length < 8*1024*1024) target.AppendLine(line);
            else truncated = true;
        }
    }
    public PortableSmokeCapture(Process p) {
        p.ErrorDataReceived += (s,e) => Append(error,e.Data);
        p.OutputDataReceived += (s,e) => Append(output,e.Data);
        p.BeginErrorReadLine(); p.BeginOutputReadLine();
    }
    public string ErrorText { get { lock(gate) { return error.ToString(); } } }
    public string OutputText { get { lock(gate) { return output.ToString(); } } }
    public bool Truncated { get { lock(gate) { return truncated; } } }
}
public static class PortableSmokeNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    public static void Click(int x, int y) {
        if (!SetCursorPos(x,y)) throw new InvalidOperationException("cannot position pointer");
        System.Threading.Thread.Sleep(150);
        mouse_event(2,0,0,0,UIntPtr.Zero);
        System.Threading.Thread.Sleep(100);
        mouse_event(4,0,0,0,UIntPtr.Zero);
    }
}
'@

function Write-Json([string] $Path, $Value) {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Read-Log([string] $Path) {
    if (Test-Path -LiteralPath $Path) { return [IO.File]::ReadAllText($Path) }
    return ''
}
function Snapshot-Tree([string[]] $Roots) {
    $result = @()
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { $result += "$root|ABSENT"; continue }
        $result += "$root|EXISTS"
        foreach ($item in @(Get-ChildItem -LiteralPath $root -Force -Recurse -File -ErrorAction Stop | Sort-Object FullName)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refuse profile reparse point: $($item.FullName)" }
            $result += "$($item.FullName)|$($item.Length)|$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)"
        }
    }
    return @($result)
}
function Get-WindowRoot($Process) {
    $Process.Refresh()
    if ($Process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'No main window handle' }
    return [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
}
function Uia-Elements($Root) {
    return $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
}
function Uia-Names($Root) {
    $result = @()
    foreach ($element in (Uia-Elements $Root)) {
        if ($result.Count -ge 1500) { $result += '[TRUNCATED AT 1500 ELEMENTS]'; break }
        try {
            $name = $element.Current.Name
            if ($name) { $result += "$($element.Current.ControlType.ProgrammaticName)|$($name.Substring(0,[Math]::Min(240,$name.Length)))" }
        } catch [System.Windows.Automation.ElementNotAvailableException] { }
    }
    return @($result)
}
function Find-Uia($Root, [string] $Pattern) {
    foreach ($element in (Uia-Elements $Root)) {
        try {
            if ($element.Current.Name -match $Pattern -and -not $element.Current.IsOffscreen -and $element.Current.IsEnabled) { return $element }
        } catch [System.Windows.Automation.ElementNotAvailableException] { }
    }
    return $null
}
function Click-Uia($Process, $Element) {
    # Invoke the accessible action when implemented; no guessed coordinates.
    # A click fallback holds the press across a rendered frame instead of emitting
    # move/down/up in one instant, which egui can observe as a missed click.
    $invoke = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) {
        ([System.Windows.Automation.InvokePattern]$invoke).Invoke()
        Start-Sleep -Milliseconds 300
        return
    }
    $r = $Element.Current.BoundingRectangle
    $window = New-Object PortableSmokeNative+RECT
    if (-not [PortableSmokeNative]::GetWindowRect($Process.MainWindowHandle, [ref]$window)) { throw 'Cannot bound UI click' }
    $x = [int]($r.Left + $r.Width / 2); $y = [int]($r.Top + $r.Height / 2)
    if ($r.Width -le 0 -or $r.Height -le 0 -or $x -lt $window.Left -or $x -gt $window.Right -or $y -lt $window.Top -or $y -gt $window.Bottom) { throw 'UI target outside app window' }
    [void][PortableSmokeNative]::SetForegroundWindow($Process.MainWindowHandle)
    [PortableSmokeNative]::Click($x,$y)
}
function Capture-Window($Process, [string] $Path) {
    $Process.Refresh()
    [void][PortableSmokeNative]::ShowWindow($Process.MainWindowHandle,9)
    [void][PortableSmokeNative]::SetForegroundWindow($Process.MainWindowHandle)
    Start-Sleep -Milliseconds 300
    $r = New-Object PortableSmokeNative+RECT
    if (-not [PortableSmokeNative]::GetWindowRect($Process.MainWindowHandle,[ref]$r)) { throw 'Cannot read window rectangle' }
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $left = [Math]::Max($r.Left,$screen.Left); $top = [Math]::Max($r.Top,$screen.Top)
    $width = [Math]::Min($r.Right,$screen.Right)-$left; $height = [Math]::Min($r.Bottom,$screen.Bottom)-$top
    if ($width -lt 640 -or $height -lt 360) { throw "Window capture is too small: ${width}x${height}" }
    $bmp = New-Object System.Drawing.Bitmap($width,$height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.CopyFromScreen($left,$top,0,0,$bmp.Size)
        $colors = New-Object 'System.Collections.Generic.HashSet[int]'
        for ($y=20; $y -lt $height; $y+=37) { for ($x=20; $x -lt $width; $x+=37) { [void]$colors.Add($bmp.GetPixel($x,$y).ToArgb()) } }
        $bmp.Save($Path,[System.Drawing.Imaging.ImageFormat]::Png)
        if ($colors.Count -lt 8) { throw "Capture may be blank; only $($colors.Count) sampled colors" }
        return @{ width=$width; height=$height; sampled_distinct_colors=$colors.Count; file=[IO.Path]::GetFileName($Path); sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    } finally { $g.Dispose(); $bmp.Dispose() }
}
function Inspect-Process($Process) {
    $tcp = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.OwningProcess -eq $Process.Id })
    $udp = @(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object { $_.OwningProcess -eq $Process.Id })
    $children = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.ParentProcessId -eq $Process.Id })
    if ($tcp.Count -or $udp.Count -or $children.Count) { throw "Unexpected sockets/children: TCP=$($tcp.Count), UDP=$($udp.Count), children=$($children.Count)" }
    return @{ observed_utc=[DateTime]::UtcNow.ToString('o'); tcp=$tcp.Count; udp=$udp.Count; children=$children.Count }
}
function Require-Uia($Process, [string] $Pattern) {
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    do {
        $element=Find-Uia (Get-WindowRoot $Process) $Pattern
        if ($element) { return $element }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "SKM accessible element not observed: $Pattern"
}
function Assert-SkmShell($Process) {
    $null=Require-Uia $Process '^NO OPERATIVO / NOT_VALIDATED$'
    $root=Get-WindowRoot $Process
    if (Find-Uia $root '^(File|Archivo)( menu)?$') { throw 'Legacy CAD File appbar is present in SKM workspace' }
    foreach ($area in @('1\s+Obra','2\s+Grúa','3\s+Carga y aparejos','4\s+Maniobra','5\s+Verificaciones','6\s+Informe')) {
        if (-not (Find-Uia $root "^$area`$")) { throw "SKM workflow area missing: $area" }
    }
}
function Set-SkmLoadLength($Process, [double] $Value) {
    # Only an accessible editable numeric control with the expected label is accepted.
    # A static label is not evidence of an editable parameter.
    $target=$null
    foreach ($element in (Uia-Elements (Get-WindowRoot $Process))) {
        if ($element.Current.Name -match '^Largo de carga' -and -not $element.Current.IsOffscreen -and $element.Current.IsEnabled -and
            $element.Current.ControlType -in @([System.Windows.Automation.ControlType]::Spinner,[System.Windows.Automation.ControlType]::Edit)) { $target=$element; break }
    }
    if (-not $target) { throw 'Load-length numeric control has no accessible name/editable role' }
    $range=$null; $valuePattern=$null
    if ($target.TryGetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern,[ref]$range)) {
        ([System.Windows.Automation.RangeValuePattern]$range).SetValue($Value)
    } elseif ($target.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$valuePattern)) {
        ([System.Windows.Automation.ValuePattern]$valuePattern).SetValue($Value.ToString([Globalization.CultureInfo]::InvariantCulture))
    } else {
        # Native keyboard fallback is targeted by verified accessibility bounds, not guessed pixels.
        Click-Uia $Process $target
        Click-Uia $Process $target
        [System.Windows.Forms.SendKeys]::SendWait('^a')
        [System.Windows.Forms.SendKeys]::SendWait($Value.ToString([Globalization.CultureInfo]::InvariantCulture))
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    }
    $null=Require-Uia $Process '^Cambios geométricos sin aplicar$'
}
function Open-Planner($Process, [string] $LogDir) {
    Assert-SkmShell $Process
    Uia-Names (Get-WindowRoot $Process) | Set-Content -LiteralPath (Join-Path $LogDir 'uia-startup.txt') -Encoding UTF8
    $shots=@(Capture-Window $Process (Join-Path $LogDir 'skm-startup.png'))
    # Each click must reveal the unique inspector content, not merely another tab label.
    $areas=@(
        @{tab='^1\s+Obra$';content='^Terreno: no caracterizado$'},
        @{tab='^2\s+Grúa$';content='^Configuración geométrica$'},
        @{tab='^3\s+Carga y aparejos$';content='^Altura del gancho'},
        @{tab='^4\s+Maniobra$';content='^Pasos geométricos$'},
        @{tab='^5\s+Verificaciones$';content='^Capacidad OEM$'},
        @{tab='^6\s+Informe$';content='^Resumen geométrico$'})
    $index=0
    foreach ($area in $areas) {
        Click-Uia $Process (Require-Uia $Process $area.tab)
        $null=Require-Uia $Process $area.content
        Assert-SkmShell $Process
        Uia-Names (Get-WindowRoot $Process) | Set-Content -LiteralPath (Join-Path $LogDir "uia-area-$index.txt") -Encoding UTF8
        $shots+=Capture-Window $Process (Join-Path $LogDir "skm-area-$index.png")
        $index++
    }
    Click-Uia $Process (Require-Uia $Process '^05\s+Carga$')
    $null=Require-Uia $Process '^Volumen envolvente\.'
    Set-SkmLoadLength $Process 4.25
    $shots+=Capture-Window $Process (Join-Path $LogDir 'skm-load-draft.png')
    Click-Uia $Process (Require-Uia $Process '^Aplicar geometría$')
    Start-Sleep -Milliseconds 500
    if (Find-Uia (Get-WindowRoot $Process) '^Cambios geométricos sin aplicar$') { throw 'Applying load geometry left the draft pending' }
    Click-Uia $Process (Require-Uia $Process '^6\s+Informe$')
    # Native inspector report comes from skm.scene.inspect; this proves the committed
    # parameter, not GPU visibility or certified physical dimensions.
    $report=Require-Uia $Process '(?s)SKM.*ESTUDIO GEOMÉTRICO.*"load_length_m"\s*:\s*4\.25'
    $reportText=$report.Current.Name
    if ($reportText -notmatch '"operational_approval"\s*:\s*false' -or $reportText -notmatch '"managed_geometry_matches_parameters"\s*:\s*true') { throw 'Report does not attest current reference geometry and no operational approval' }
    $reportText | Set-Content -LiteralPath (Join-Path $LogDir 'committed-geometry-report.txt') -Encoding UTF8
    $shots+=Capture-Window $Process (Join-Path $LogDir 'skm-load-committed.png')
    Assert-SkmShell $Process
    return @{ opened_directly=$true; six_areas_interacted=$true; load_component_interacted=$true; accessible_parameter_edited=$true; committed_load_length_m=4.25; warning_observed=$true; legacy_file_appbar_absent=$true; screenshots=$shots; crane_pixels_verified=$false; visual_review_required=$true }
}
function Close-AppCleanly($Process) {
    if (-not $Process.CloseMainWindow()) { throw 'Could not request clean window close' }
    # A newly created reference scene and the test edit are deliberately unsaved.
    # Discard only this isolated QA document; never interact with a real user file.
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 200
        $Process.Refresh()
        if ($Process.HasExited) { return }
        $discard=Find-Uia (Get-WindowRoot $Process) "^(No guardar|Don't Save)$"
        if ($discard) { Click-Uia $Process $discard }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Application did not close cleanly within 30 seconds'
}
function Start-App([string] $AppPath,[string] $CaseDir,[bool] $SafeMode) {
    $profile = Join-Path $CaseDir 'profile'
    foreach ($sub in @('home','roaming','local','temp','config','xdg-data','codex')) { New-Item -ItemType Directory -Path (Join-Path $profile $sub) | Out-Null }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$AppPath; $psi.Arguments=if ($SafeMode) { '--safe-mode' } else { '' }
    $psi.WorkingDirectory=$CaseDir; $psi.UseShellExecute=$false
    $psi.RedirectStandardError=$true; $psi.RedirectStandardOutput=$true
    foreach ($key in @('SOLIDCRAFT_CONTROL_PORT','SOLIDCRAFT_CONTROL_TOKEN','SOLVECRAFT_CONTROL_PORT','SOLVECRAFT_CONTROL_TOKEN','CRAFT_CONTROL_PORT','CRAFT_CONTROL_TOKEN','SOLIDCRAFT_SAFE_MODE','SOLIDCRAFT_RENDERER','WGPU_BACKEND','WGPU_DX12_COMPILER')) { $psi.EnvironmentVariables.Remove($key) }
    $envs=@{ HOME='home'; USERPROFILE='home'; APPDATA='roaming'; LOCALAPPDATA='local'; TEMP='temp'; TMP='temp'; XDG_CONFIG_HOME='config'; XDG_DATA_HOME='xdg-data'; CODEX_HOME='codex' }
    foreach ($key in $envs.Keys) { $psi.EnvironmentVariables[$key]=Join-Path $profile $envs[$key] }
    $psi.EnvironmentVariables['SOLIDCRAFT_PROFILE_STARTUP']='1'
    # Deliberately hostile path overrides: portable builds must ignore these.
    $psi.EnvironmentVariables['SOLIDCRAFT_SETTINGS_DIR']=Join-Path $profile 'forbidden-settings'
    $psi.EnvironmentVariables['SOLIDCRAFT_RECOVERY_DIR']=Join-Path $profile 'forbidden-recovery'
    $psi.EnvironmentVariables['SOLIDCRAFT_CRASH_DIR']=Join-Path $profile 'forbidden-crashes'
    $p=[Diagnostics.Process]::Start($psi)
    $capture=New-Object PortableSmokeCapture($p)
    return @{ process=$p; capture=$capture; profile=$profile }
}

$script:CaseResults=@()
$ActualAppRoots=@(
    (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'SolidCraft'),
    (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SolidCraft')
)
$ActualBefore=Snapshot-Tree $ActualAppRoots
$Status='FAIL'
$Failure=$null
try {
    $NormalApp=$null
    foreach ($case in @(@{name='normal';safe=$false;planner=$true},@{name='safe-mode';safe=$true;planner=$true},@{name='moved-unicode';safe=$false;planner=$true})) {
        $caseDir=Join-Path $EvidenceDir $case.name
        New-Item -ItemType Directory -Path $caseDir | Out-Null
        $folder=if ($case.name -eq 'moved-unicode') { 'moved folder ' + [char]0x00e1 + [char]0x00f1 } else { 'app' }
        $appDir=Join-Path $caseDir $folder
        if ($case.name -eq 'moved-unicode') { Copy-Item -LiteralPath $NormalApp -Destination $appDir -Recurse }
        else { New-Item -ItemType Directory -Path $appDir | Out-Null; Copy-Item -LiteralPath $Exe -Destination (Join-Path $appDir 'solidcraft.exe') }
        $appPath=Join-Path $appDir 'solidcraft.exe'
        if ((Get-FileHash -LiteralPath $appPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExeHash) { throw 'Copied executable differs' }
        $start=Start-App $appPath $caseDir $case.safe
        $p=$start.process
        $net=@(); $shot=$null; $planner=$null; $caseFailure=$null
        try {
            $deadline=[DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
            # The capture drains stdout/stderr in C# without a PowerShell background runspace.
            do { Start-Sleep -Milliseconds 300; $p.Refresh() } while (-not $p.HasExited -and ($p.MainWindowHandle -eq [IntPtr]::Zero -or -not $start.capture.ErrorText.Contains('second frame begins (first presented)')) -and [DateTime]::UtcNow -lt $deadline)
            if ($p.HasExited -or $p.MainWindowHandle -eq [IntPtr]::Zero -or -not $start.capture.ErrorText.Contains('second frame begins (first presented)')) { throw 'Application did not present a real first frame before timeout' }
            $net += Inspect-Process $p
            if ($case.planner) { $planner=Open-Planner $p $caseDir }
            $shot=Capture-Window $p (Join-Path $caseDir 'window.png')
            $net += Inspect-Process $p
            Close-AppCleanly $p
            $p.WaitForExit()
            if ($p.ExitCode -ne 0) { throw "Application exited with code $($p.ExitCode)" }
        } catch {
            $caseFailure=$_.Exception.Message
            if (-not $p.HasExited -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
                try { $null=Capture-Window $p (Join-Path $caseDir 'failure.png') } catch { }
            }
        }
        finally {
            if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }
            $p.WaitForExit()
            $err=$start.capture.ErrorText; $stdout=$start.capture.OutputText
            $err | Set-Content -LiteralPath (Join-Path $caseDir 'stderr.txt') -Encoding UTF8
            $stdout | Set-Content -LiteralPath (Join-Path $caseDir 'stdout.txt') -Encoding UTF8
        }
        if ($caseFailure) { throw "$($case.name): $caseFailure" }
        if ($start.capture.Truncated) { throw "$($case.name): process output exceeded the 8 MiB bound" }
        if (-not $err.Contains('second frame begins (first presented)')) { throw "$($case.name): no real first-presented frame marker" }
        if (-not $err.Contains('SolidCraft portable: isolated storage ready; integrations disabled')) { throw "$($case.name): portable mode marker missing" }
        if ($err -match '(control server listening|control token|MCP server listening)') { throw "$($case.name): forbidden integration startup in log" }
        $data=Join-Path $appDir 'data'
        if (-not (Test-Path -LiteralPath (Join-Path $data 'settings') -PathType Container)) { throw 'Portable settings directory missing' }
        $profileFiles=@(Get-ChildItem -LiteralPath $start.profile -Recurse -File -Force)
        if ($profileFiles.Count -ne 0) { throw "App wrote $($profileFiles.Count) files outside portable data into sandbox profile" }
        $tokens=@(Get-ChildItem -LiteralPath $caseDir -Filter '*.token' -Recurse -File -Force)
        if ($tokens.Count -ne 0) { throw 'A credential token file was created' }
        $crashes=@(Get-ChildItem -LiteralPath (Join-Path $data 'crashes') -Filter 'report.json' -Recurse -File -ErrorAction SilentlyContinue)
        if ($crashes.Count -ne 0) { throw 'Unexpected crash report generated' }
        $after=Snapshot-Tree $ActualAppRoots
        if (@(Compare-Object $ActualBefore $after).Count -ne 0) { throw 'Real runner SolidCraft profile state changed' }
        if ($case.name -eq 'normal') { $NormalApp=$appDir }
        $script:CaseResults += @{ name=$case.name; arguments=if ($case.safe) { '--safe-mode' } else { '' }; status='PASS'; exit_code=$p.ExitCode; first_frame_presented=$true; portable_marker=$true; planner=$planner; screenshot=$shot; network_samples=$net; sandbox_profile_files=0; token_files=0; real_app_profile_unchanged=$true }
    }
    # No ACL changes: a plain file named data exercises an unwritable storage shape.
    $collision=Join-Path $EvidenceDir 'data-file-collision'
    New-Item -ItemType Directory -Path $collision | Out-Null
    $app=Join-Path $collision 'app'; New-Item -ItemType Directory -Path $app | Out-Null
    Copy-Item -LiteralPath $Exe -Destination (Join-Path $app 'solidcraft.exe')
    [IO.File]::WriteAllText((Join-Path $app 'data'),'intentional QA collision; do not replace')
    $start=Start-App (Join-Path $app 'solidcraft.exe') $collision $false
    $p=$start.process
    try {
        if (-not $p.WaitForExit(30000)) { throw 'Data-file collision did not fail closed within 30 seconds' }
        if ($p.ExitCode -eq 0) { throw 'Data-file collision unexpectedly succeeded' }
    } finally {
        if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }
        $p.WaitForExit()
        $start.capture.ErrorText | Set-Content -LiteralPath (Join-Path $collision 'stderr.txt') -Encoding UTF8
        $start.capture.OutputText | Set-Content -LiteralPath (Join-Path $collision 'stdout.txt') -Encoding UTF8
    }
    $collisionError=$start.capture.ErrorText
    if (-not $collisionError.Contains('portable directory must be a real directory')) { throw 'Collision failed for an unverified reason, not the portable directory guard' }
    if ($collisionError.Contains('second frame begins (first presented)') -or $collisionError.Contains('isolated storage ready')) { throw 'Collision incorrectly passed startup isolation' }
    if (-not (Test-Path -LiteralPath (Join-Path $app 'data') -PathType Leaf)) { throw 'Data-file collision was replaced' }
    if (@(Get-ChildItem -LiteralPath $start.profile -Recurse -File -Force).Count -ne 0) { throw 'Collision fell back to profile storage' }
    if (@(Get-ChildItem -LiteralPath $collision -Filter '*.token' -Recurse -File -Force).Count -ne 0) { throw 'Collision generated a token file' }
    if (@(Compare-Object $ActualBefore (Snapshot-Tree $ActualAppRoots)).Count -ne 0) { throw 'Collision changed real runner SolidCraft profile' }
    $script:CaseResults += @{ name='data-file-collision'; status='PASS'; exit_code=$p.ExitCode; failed_closed=$true; portable_directory_guard_observed=$true; collision_preserved=$true; token_files=0; sandbox_profile_files=0; real_app_profile_unchanged=$true }
    $Status='PASS'
} catch {
    $Failure=$_.Exception.Message
} finally {
    $result=@{ schema=2; status=$Status; visual_release_gate='PENDING_GPU_OR_HUMAN_REVIEW'; exe_sha256=$ExeHash; completed_utc=[DateTime]::UtcNow.ToString('o'); cases=$script:CaseResults; failure=$Failure; no_control_credentials_created_by_harness=$true; rt750_status='NOT_VALIDATED'; limits=@('Native SKM startup, six-area navigation, accessible load edit and committed inspect report only. Screenshots and distinct-color checks do not verify crane pixels. GPU evidence or explicit human screenshot review remains required before release. File-picker and persistence are covered separately, not claimed here.','Network checks are bounded samples, not continuous system-wide tracing.','Own app profile paths and sandbox profile checked; not a claim that Windows/drivers leave zero traces.','No signing or certification performed.') }
    Write-Json (Join-Path $EvidenceDir 'smoke-result.json') $result
}
if ($Status -ne 'PASS') { throw $Failure }
Write-Output "PASS: Windows portable native smoke; EXE SHA256 $ExeHash"

