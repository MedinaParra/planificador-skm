# Run this before any long build. Syntax-only: never invokes the checked scripts.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$failed=$false
foreach ($name in @('windows-portable-smoke.ps1','package-windows-portable.ps1','test-script-syntax.ps1','../tools/build-windows.ps1')) {
    $path=Join-Path $PSScriptRoot $name
    $tokens=$null; $parseErrors=$null
    $null=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count -ne 0) {
        $failed=$true
        foreach ($error in $parseErrors) { Write-Output "$name : $($error.Extent.StartLineNumber):$($error.Extent.StartColumnNumber) $($error.Message)" }
    } else { Write-Output "PASS syntax: $name" }
}
if ($failed) { throw 'PowerShell syntax gate failed' }
