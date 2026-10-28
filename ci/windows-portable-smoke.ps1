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
        mouse_event(2,0,0,0,UIntPtr.Zero); mouse_event(4,0,0,0,UIntPtr.Zero);
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
function Open-Planner($Process, [string] $LogDir) {
    $root = Get-WindowRoot $Process
    $before = Uia-Names $root
    $before | Set-Content -LiteralPath (Join-Path $LogDir 'uia-before.txt') -Encoding UTF8
    $file = Find-Uia $root '^(File|Archivo)( menu)?$'
    if (-not $file) { throw 'File menu not exposed through UI Automation' }
    Click-Uia $Process $file
    Start-Sleep -Milliseconds 400
    $root = Get-WindowRoot $Process
    $item = Find-Uia $root '^(Lift study|Estudio de izaje)'
    if (-not $item) {
        Uia-Names $root | Set-Content -LiteralPath (Join-Path $LogDir 'uia-menu.txt') -Encoding UTF8
        throw 'Lift study menu entry not exposed through UI Automation'
    }
    Click-Uia $Process $item
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $names = @(Uia-Names (Get-WindowRoot $Process))
        $title = @($names | Where-Object { $_ -match '(Geometric lift study|Estudio geom)' })
        $warning = @($names | Where-Object { $_ -match '(NOT OPERATIONAL|NO OPERATIVO).*NOT_VALIDATED' })
    } while (($title.Count -eq 0 -or $warning.Count -eq 0) -and [DateTime]::UtcNow -lt $deadline)
    $names | Set-Content -LiteralPath (Join-Path $LogDir 'uia-planner.txt') -Encoding UTF8
    if ($title.Count -eq 0 -or $warning.Count -eq 0) { throw 'Planner title/NOT_VALIDATED warning not observed in native accessibility tree' }
    return @{ opened=$true; title_observed=$title; warning_observed=$warning }
}
function Start-App([string] $AppPath,[string] $CaseDir,[bool] $SafeMode) {
    $profile = Join-Path $CaseDir 'profile'
    foreach ($sub in @('home','roaming','local','temp','config','xdg-data','codex')) { New-Item -ItemType Directory -Path (Join-Path $profile $sub) | Out-Null }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$AppPath; $psi.Arguments=if ($SafeMode) { '--sample --safe-mode' } else { '--sample' }
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
    foreach ($case in @(@{name='normal';safe=$false;planner=$true},@{name='safe-mode';safe=$true;planner=$false},@{name='moved-unicode';safe=$false;planner=$true})) {
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
            if (-not $p.CloseMainWindow()) { throw 'Could not request clean window close' }
            if (-not $p.WaitForExit(30000)) { throw 'Application did not close cleanly within 30 seconds' }
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
        $script:CaseResults += @{ name=$case.name; arguments=if ($case.safe) { '--sample --safe-mode' } else { '--sample' }; status='PASS'; exit_code=$p.ExitCode; first_frame_presented=$true; portable_marker=$true; planner=$planner; screenshot=$shot; network_samples=$net; sandbox_profile_files=0; token_files=0; real_app_profile_unchanged=$true }
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
    $result=@{ schema=1; status=$Status; exe_sha256=$ExeHash; completed_utc=[DateTime]::UtcNow.ToString('o'); cases=$script:CaseResults; failure=$Failure; no_control_credentials_created_by_harness=$true; rt750_status='NOT_VALIDATED'; limits=@('Native GUI startup/panel evidence only; file-picker and study persistence flows are covered separately by headless tests, not claimed by this smoke.','Network checks are bounded samples, not continuous system-wide tracing.','Own app profile paths and sandbox profile checked; not a claim that Windows/drivers leave zero traces.','No signing or certification performed.') }
    Write-Json (Join-Path $EvidenceDir 'smoke-result.json') $result
}
if ($Status -ne 'PASS') { throw $Failure }
Write-Output "PASS: Windows portable native smoke; EXE SHA256 $ExeHash"
