[CmdletBinding()]
param(
    [string]$DependencyDirectory = (Join-Path $PSScriptRoot '../.dart_tool/windows-deps')
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Windows setup must run on Windows.'
}
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'The initial Windows backend targets x64.'
}
foreach ($tool in @('cl.exe', 'cmake', 'rustup', 'flutter', 'uv')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Missing $tool. See docs/windows.md; use Developer PowerShell for VS 2022."
    }
}
if (-not $env:LIBCLANG_PATH) {
    $clang = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
    if ($clang) {
        $env:LIBCLANG_PATH = Split-Path $clang.Source
    } else {
        $env:LIBCLANG_PATH = Join-Path $env:ProgramFiles 'LLVM/bin'
    }
}
if (-not (Test-Path (Join-Path $env:LIBCLANG_PATH 'libclang.dll'))) {
    throw 'Install LLVM with libclang.dll and set LIBCLANG_PATH to its bin directory.'
}

$DependencyDirectory = [IO.Path]::GetFullPath($DependencyDirectory)
New-Item -ItemType Directory -Force -Path $DependencyDirectory | Out-Null
if (-not $env:MOZTOOLS_PATH) {
    $moztools = Join-Path $DependencyDirectory 'moztools-4.0'
    if (-not (Test-Path (Join-Path $moztools 'msys2/usr/bin/bash.exe'))) {
        $archive = Join-Path $DependencyDirectory 'moztools-4.0.zip'
        Invoke-WebRequest -Uri 'https://github.com/servo/servo-build-deps/releases/download/msvc-deps/moztools-4.0.zip' -OutFile $archive
        Expand-Archive -Path $archive -DestinationPath $DependencyDirectory -Force
    }
    $env:MOZTOOLS_PATH = $moztools
}
if (-not (Test-Path (Join-Path $env:MOZTOOLS_PATH 'msys2/usr/bin/bash.exe'))) {
    throw "MOZTOOLS_PATH does not contain msys2/usr/bin/bash.exe: $env:MOZTOOLS_PATH"
}
& uv python install 3.11
if ($LASTEXITCODE -ne 0) { throw 'Python 3.11 installation failed.' }
$toolchainFile = Join-Path $PSScriptRoot '../packages/flutter_servo/rust/rust-toolchain.toml'
$toolchain = [regex]::Match((Get-Content -Raw $toolchainFile), 'channel\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $toolchain) { throw 'Cannot read the package Rust toolchain.' }
& rustup toolchain install $toolchain --profile minimal
if ($LASTEXITCODE -ne 0) { throw 'Rust toolchain installation failed.' }
if (-not $env:CARGO_BUILD_JOBS) { $env:CARGO_BUILD_JOBS = '2' }
$env:CARGO_INCREMENTAL = '0'
$env:RUST_BACKTRACE = '1'
Write-Host 'Windows dependencies configured for this PowerShell session.'
