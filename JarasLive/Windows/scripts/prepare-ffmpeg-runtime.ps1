param(
    [Parameter(Mandatory)][string]$BuildDirectory,
    [Parameter(Mandatory)][string]$PackageDirectory,
    [Parameter(Mandatory)][string]$SourceDirectory
)
$ErrorActionPreference='Stop'
$names=@('avutil-60.dll','swresample-6.dll','avcodec-62.dll','avformat-62.dll','swscale-9.dll')
$destination=Join-Path $PackageDirectory 'CatLiveRuntime/FFmpeg'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$existing=$env:CATLIVE_FFMPEG_RUNTIME
if($existing -and @($names|Where-Object { -not(Test-Path -LiteralPath (Join-Path $existing $_) -PathType Leaf) }).Count -eq 0) {
    foreach($name in $names){Copy-Item -LiteralPath (Join-Path $existing $name) -Destination $destination -Force}
} else {
    $archive=Join-Path $BuildDirectory 'ffmpeg-n8.1-win64-lgpl-shared.zip'
    if(-not(Test-Path -LiteralPath $archive) -or (Get-Item -LiteralPath $archive).Length -lt 50MB) {
        $url='https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n8.1-latest-win64-lgpl-shared-8.1.zip'
        Invoke-WebRequest -Uri $url -OutFile $archive -MaximumRedirection 8
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($archive)
    try {
        foreach($name in $names) {
            $entry=@($zip.Entries|Where-Object { $_.Name -eq $name -and $_.FullName -match '(^|/)bin/' }|Select-Object -First 1)
            if($entry.Count -ne 1 -or $entry[0].Length -eq 0){throw "FFmpeg runtime missing $name"}
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry[0],(Join-Path $destination $name),$true)
        }
    } finally {$zip.Dispose()}
}
foreach($name in $names){
    if(-not(Test-Path -LiteralPath (Join-Path $destination $name) -PathType Leaf) -or
       (Get-Item -LiteralPath (Join-Path $destination $name)).Length -eq 0) {
        throw "FFmpeg runtime incomplete: $name"
    }
}
$license=Join-Path $PackageDirectory 'Licenses/FFmpeg/COPYING.LGPLv2.1'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $license) | Out-Null
Copy-Item -LiteralPath (Join-Path $SourceDirectory 'ThirdParty/FFmpeg/COPYING.LGPLv2.1') -Destination $license -Force
