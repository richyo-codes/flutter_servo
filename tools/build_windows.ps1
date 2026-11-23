#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [switch]$Run,
    [switch]$Probe,
    [switch]$Prebuilt
)
$ErrorActionPreference = 'Stop'
if (-not $Prebuilt) {
    & (Join-Path $PSScriptRoot 'setup_windows.ps1')
}
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$example = Join-Path $root 'packages/flutter_servo/example'
$logDirectory = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$buildLog = Join-Path $logDirectory "windows-$($Configuration.ToLowerInvariant()).log"
Push-Location $example
try {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
    & flutter build windows "--$($Configuration.ToLowerInvariant())" -v 2>&1 | Tee-Object -FilePath $buildLog
    if ($LASTEXITCODE -ne 0) { throw "Windows build failed. See $buildLog" }
    $bundle = Join-Path $example "build/windows/x64/runner/$Configuration"
    foreach ($file in @('flutter_servo_example.exe', 'flutter_windows.dll', 'flutter_servo_plugin.dll',
                         'rust_lib_flutter_servo.dll', 'libEGL.dll', 'libGLESv2.dll')) {
        if (-not (Test-Path (Join-Path $bundle $file))) { throw "Missing bundled file: $file" }
    }
    if ($Probe) {
        # Use the shipped DLLs, not a separately compiled Rust probe target.
        $probeExe = Join-Path $bundle 'windows_session_probe.exe'
        $probeSource = Join-Path $root 'tools/windows_session_probe.cpp'
        $bridgeSource = Join-Path $root 'packages/flutter_servo/windows/rust_bridge.cpp'
        $bridgeInclude = Join-Path $root 'packages/flutter_servo/windows'
        $probeBuild = Join-Path $example 'build/windows/probe'
        New-Item -ItemType Directory -Force -Path $probeBuild | Out-Null
        Push-Location $probeBuild
        try {
            & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /DNOMINMAX "/I$bridgeInclude" $probeSource $bridgeSource "/Fe:$probeExe" user32.lib
            if ($LASTEXITCODE -ne 0) { throw 'Native session probe compilation failed.' }
        } finally {
            Pop-Location
        }
        $probeLog = Join-Path $logDirectory 'windows-session-probe.log'
        $probeErrors = Join-Path $logDirectory 'windows-session-probe-errors.log'
        $process = Start-Process -FilePath $probeExe -WorkingDirectory $bundle -PassThru -NoNewWindow `
            -RedirectStandardOutput $probeLog -RedirectStandardError $probeErrors
        if (-not $process.WaitForExit(60000)) {
            Stop-Process -Id $process.Id -Force
            throw "Native probe timed out (including shutdown). See $probeErrors"
        }
        $process.Refresh()
        Get-Content $probeLog
        if ($process.ExitCode -ne 0) { throw "Native probe failed. See $probeErrors" }
    }
    Write-Host "Browser bundle: $bundle"
    if ($Run) { & (Join-Path $bundle 'flutter_servo_example.exe') }
} finally {
    Pop-Location
}
