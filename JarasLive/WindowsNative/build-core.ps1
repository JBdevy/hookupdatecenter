param(
    [string]$BuildDirectory = (Join-Path $PSScriptRoot 'build'),
    [string]$SoundFontFixture = '',
    [string]$MP3Fixture = '',
    [string]$CMake = '',
    [switch]$ProbeAudio
)
$ErrorActionPreference = 'Stop'
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with code $LASTEXITCODE" }
}
# CMake's Visual Studio generator finds MSVC on its own, but Cargo also links
# C++/Windows SDK objects. Import the x64 developer environment before both.
$installation = ''
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0) { throw 'Could not locate the Visual Studio C++ installation.' }
}
if ($installation) {
    $vsDevCmd = Join-Path $installation 'Common7\Tools\VsDevCmd.bat'
    if (!(Test-Path $vsDevCmd)) { throw "Visual Studio developer environment not found: $vsDevCmd" }
    # A temporary batch file avoids nested cmd/PowerShell quoting of paths with
    # spaces. Only import NAME=value lines; do not evaluate command output.
    $environmentScript = Join-Path ([IO.Path]::GetTempPath()) ('catlive-msvc-' + [guid]::NewGuid().ToString('N') + '.cmd')
    try {
        @('@echo off', ('call "' + $vsDevCmd + '" -no_logo -arch=x64 -host_arch=x64 >nul'),
          'if errorlevel 1 exit /b %errorlevel%', 'set') | Set-Content -LiteralPath $environmentScript -Encoding Default
        $environment = & $env:ComSpec /d /c $environmentScript
        if ($LASTEXITCODE -ne 0) { throw 'Visual Studio could not initialize its x64 C++/Windows SDK environment.' }
        foreach ($entry in $environment) {
            $separator = $entry.IndexOf('=')
            if ($separator -gt 0) {
                [Environment]::SetEnvironmentVariable($entry.Substring(0, $separator), $entry.Substring($separator + 1), 'Process')
            }
        }
    } finally { Remove-Item -LiteralPath $environmentScript -Force -ErrorAction SilentlyContinue }
}
if (!(Get-Command cl.exe -ErrorAction SilentlyContinue) -or
    !(Get-Command link.exe -ErrorAction SilentlyContinue) -or
    $env:VSCMD_ARG_TGT_ARCH -ne 'x64' -or !$env:WindowsSdkDir) {
    throw 'Install Visual Studio C++ x64 tools and a Windows SDK, or run from an x64 Native Tools PowerShell.'
}
if (!$CMake) {
    $found = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if ($found) { $CMake = $found.Source }
    else {
        if (!$installation) { throw 'Install the Visual Studio C++ tools and CMake.' }
        $CMake = Join-Path $installation 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    }
}
$cmakeCommand = Get-Command $CMake -ErrorAction Stop
$CMake = $cmakeCommand.Source
$ctest = Join-Path (Split-Path $CMake) 'ctest.exe'
if (!(Test-Path $ctest)) { throw "CTest not found beside CMake: $ctest" }
$toolchain = Join-Path $env:USERPROFILE '.rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
$cargo = Join-Path $toolchain 'cargo.exe'
if (!(Test-Path $cargo)) {
    $found = Get-Command cargo.exe -ErrorAction SilentlyContinue
    if (!$found) { throw 'Install the Rust MSVC toolchain.' }
    $cargo = $found.Source
} else { $env:PATH = "$toolchain;$env:PATH" }
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)
New-Item -ItemType Directory -Force $BuildDirectory | Out-Null
$arguments = @('-S', $PSScriptRoot, '-B', (Join-Path $BuildDirectory 'cpp'), '-A', 'x64')
if ($SoundFontFixture) { $arguments += "-DCATLIVE_TEST_SF2=$SoundFontFixture" }
if ($MP3Fixture) { $arguments += "-DCATLIVE_TEST_MP3=$MP3Fixture" }
Invoke-Checked $CMake $arguments
Invoke-Checked $CMake @('--build', (Join-Path $BuildDirectory 'cpp'), '--config', 'Release', '--parallel', '4')
Invoke-Checked $ctest @('--test-dir', (Join-Path $BuildDirectory 'cpp'), '-C', 'Release', '--output-on-failure')
$previousTarget = $env:CARGO_TARGET_DIR
$previousIncremental = $env:CARGO_INCREMENTAL
try {
    $env:CARGO_TARGET_DIR = Join-Path $BuildDirectory 'rust'
    # External/test disks may not support hard links used by incremental Rust.
    $env:CARGO_INCREMENTAL = '0'
    Push-Location (Join-Path $PSScriptRoot 'src-tauri')
    try {
        Invoke-Checked $cargo @('test', '--locked')
        if ($ProbeAudio) { Invoke-Checked $cargo @('run', '--locked', '--example', 'audio_probe') }
    } finally { Pop-Location }
} finally {
    $env:CARGO_TARGET_DIR = $previousTarget
    $env:CARGO_INCREMENTAL = $previousIncremental
}
