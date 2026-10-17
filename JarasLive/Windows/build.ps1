param(
    [ValidateSet('Debug','Release')][string]$Configuration='Release',
    [ValidatePattern('^[0-9]+\.[0-9]{2}$')][string]$Version='1.02',
    [string]$BuildDirectory=(Join-Path $env:LOCALAPPDATA 'CatLiveBuild/windows'),
    [switch]$SkipTests,
    [switch]$Installer,
    [switch]$Run
)
$ErrorActionPreference='Stop'
$sourceDirectory=$PSScriptRoot
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$cmakeCommand=Get-Command cmake -ErrorAction SilentlyContinue
if ($cmakeCommand) { $catCmake=$cmakeCommand.Source }
elseif (Test-Path $vswhere) {
    $visualStudio=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $catCmake=Join-Path $visualStudio 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
}
if (-not $catCmake -or -not (Test-Path $catCmake)) { throw 'Instale Visual Studio 2022/2026 com Desenvolvimento para desktop com C++ e CMake.' }
$cmakeArgs=@('-S',$sourceDirectory,'-B',$BuildDirectory,'-A','x64',"-DCATLIVE_VERSION=$Version")
$juceCache=Join-Path $env:LOCALAPPDATA 'CatLiveBuild/JUCE-8.0.15'
if (Test-Path (Join-Path $juceCache 'CMakeLists.txt')) { $cmakeArgs+="-DCATLIVE_JUCE_SOURCE=$juceCache" }
& $catCmake @cmakeArgs
if ($LASTEXITCODE) { throw 'Falha na configuração do CMake.' }
& $catCmake --build $BuildDirectory --config $Configuration --parallel 4
if ($LASTEXITCODE) { throw 'Falha na compilação do CatLive.' }
if (-not $SkipTests) {
    $catCtest=Join-Path (Split-Path $catCmake) 'ctest.exe'
    & $catCtest --test-dir $BuildDirectory -C $Configuration --output-on-failure
    if ($LASTEXITCODE) { throw 'Os testes falharam. O pacote não foi gerado.' }
}
$binary=Join-Path $BuildDirectory "CatLive_artefacts/$Configuration/CatLive.exe"
if ($Configuration -eq 'Release') {
    $applicationOutput=(Get-Content -LiteralPath (Join-Path $BuildDirectory 'CMakeCache.txt') |
        Where-Object { $_ -match '^CATLIVE_APP_OUTPUT_DIRECTORY:[^=]*=' } |
        Select-Object -First 1) -replace '^[^=]*=',''
    if ($applicationOutput) {
        if (-not [IO.Path]::IsPathRooted($applicationOutput)) { $applicationOutput=Join-Path $BuildDirectory $applicationOutput }
        $binary=Join-Path $applicationOutput 'CatLive.exe'
    }
}
$packageDirectory=Join-Path $BuildDirectory "package/CatLive-Windows-x64"
New-Item -ItemType Directory -Force $packageDirectory | Out-Null
Copy-Item -LiteralPath $binary -Destination (Join-Path $packageDirectory 'CatLive.exe') -Force
# The encoder is a replaceable shared library. Package the runtime and its
# complete rebuild materials from the same tested build output as CatLive.exe.
$runtimeDirectory=Split-Path -Parent $binary
$requiredRuntimeFiles=@(
    'CatLiveLame.dll',
    'Licenses/LAME/COPYING',
    'Licenses/LAME/lame-3.100-source.tar.gz',
    'Licenses/LAME/config.h',
    'Licenses/LAME/BUILD.txt',
    'Licenses/dr_libs/LICENSE'
)
foreach ($relativePath in $requiredRuntimeFiles) {
    $runtimeFile=Join-Path $runtimeDirectory $relativePath
    if (-not (Test-Path -LiteralPath $runtimeFile -PathType Leaf) -or (Get-Item -LiteralPath $runtimeFile).Length -eq 0) {
        throw "Runtime incompleto: $runtimeFile. O pacote nao foi gerado."
    }
    $packageFile=Join-Path $packageDirectory $relativePath
    New-Item -ItemType Directory -Force (Split-Path -Parent $packageFile) | Out-Null
    Copy-Item -LiteralPath $runtimeFile -Destination $packageFile -Force
}
& (Join-Path $sourceDirectory 'scripts/prepare-ffmpeg-runtime.ps1') -BuildDirectory $BuildDirectory -PackageDirectory $packageDirectory -SourceDirectory $sourceDirectory
if($LASTEXITCODE){throw 'Falha ao preparar o runtime FFmpeg do vídeo.'}
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'README.txt') -Destination $packageDirectory -Force
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'THIRD-PARTY-NOTICES.txt') -Destination $packageDirectory -Force
Remove-Item -LiteralPath (Join-Path $packageDirectory 'Figtree-LICENSE.txt') -ErrorAction SilentlyContinue
foreach($obsoleteFont in @('SourceSans3-LICENSE.txt','JetBrainsMono-LICENSE.txt')) { Remove-Item -LiteralPath (Join-Path $packageDirectory $obsoleteFont) -Force -ErrorAction SilentlyContinue }
Copy-Item -LiteralPath (Join-Path $sourceDirectory '../Resources/Fonts/Inter/LICENSE.txt') -Destination (Join-Path $packageDirectory 'Inter-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'ThirdParty/Signalsmith/LICENSE-stretch.txt') -Destination (Join-Path $packageDirectory 'Signalsmith-Stretch-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'ThirdParty/Signalsmith/LICENSE-linear.txt') -Destination (Join-Path $packageDirectory 'Signalsmith-Linear-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'ThirdParty/Monocypher/LICENCE.md') -Destination (Join-Path $packageDirectory 'Monocypher-LICENSE.md') -Force
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'ThirdParty/QRCode/LICENSE.txt') -Destination (Join-Path $packageDirectory 'QRCode-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $sourceDirectory '../Core/ThirdParty/TinySoundFont/TinySoundFont-LICENSE.txt') -Destination (Join-Path $packageDirectory 'TinySoundFont-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $sourceDirectory '../Core/ThirdParty/EBUR128/EBUR128-LICENSE.txt') -Destination (Join-Path $packageDirectory 'EBUR128-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'ThirdParty/EBUR128-QUEUE-LICENSE.txt') -Destination $packageDirectory -Force
$juceSource=(Get-Content -LiteralPath (Join-Path $BuildDirectory 'CMakeCache.txt') | Where-Object { $_ -match '^CATLIVE_JUCE_SOURCE:[^=]*=' } | Select-Object -First 1) -replace '^[^=]*=',''
if (-not $juceSource) { $juceSource=Join-Path $BuildDirectory '_deps/juce-src' }
Copy-Item -LiteralPath (Join-Path $juceSource 'LICENSE.md') -Destination (Join-Path $packageDirectory 'JUCE-LICENSE.md') -Force
Copy-Item -LiteralPath (Join-Path $sourceDirectory 'validation-status.txt') -Destination $packageDirectory -Force
$zip=Join-Path (Split-Path $packageDirectory) "CatLive-$Version-Windows-x64.zip"
Compress-Archive -LiteralPath $packageDirectory -DestinationPath $zip -Force
if ($Installer) {
    $innoCommand=Get-Command ISCC.exe -ErrorAction SilentlyContinue
    $innoCompiler=if($innoCommand){$innoCommand.Source}else{Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'}
    $innoCache=Join-Path $env:LOCALAPPDATA 'CatLiveBuild/tools/InnoSetup6/ISCC.exe'
    if(-not (Test-Path -LiteralPath $innoCompiler) -and (Test-Path -LiteralPath $innoCache)){$innoCompiler=$innoCache}
    if(-not (Test-Path -LiteralPath $innoCompiler)){throw 'Inno Setup 6 não encontrado. O ZIP foi gerado, mas o instalador não foi criado.'}
    $installerDirectory=Join-Path $BuildDirectory 'installer'
    & $innoCompiler "/DAppVersion=$Version" "/DPackageDirectory=$packageDirectory" "/DOutputDirectory=$installerDirectory" (Join-Path $sourceDirectory 'installer/CatLive.iss')
    if($LASTEXITCODE){throw 'Falha ao criar o instalador Windows.'}
    Get-ChildItem -LiteralPath $installerDirectory -Filter '*.exe' | ForEach-Object {
        $digest=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText(($_.FullName+'.sha256'),($digest+'  '+$_.Name+"`n"),[Text.Encoding]::ASCII)
    }
}
Write-Host "Executável: $binary"
Write-Host "Pacote: $zip"
if ($Run) { Start-Process -FilePath $binary -WindowStyle Normal }
