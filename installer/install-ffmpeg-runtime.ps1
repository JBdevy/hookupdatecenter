param(
  [Parameter(Mandatory = $true)]
  [string]$Archive,

  [Parameter(Mandatory = $true)]
  [string]$RuntimeRoot
)

$ErrorActionPreference = 'Stop'

$archivePath = [System.IO.Path]::GetFullPath($Archive)
$runtimeParent = [System.IO.Path]::GetFullPath($RuntimeRoot)
$target = [System.IO.Path]::GetFullPath((Join-Path $runtimeParent 'FFmpeg'))
$legacyVlc = [System.IO.Path]::GetFullPath((Join-Path $runtimeParent 'VLC'))

if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
  throw 'O pacote FFmpeg incluído na Hook Center não foi encontrado.'
}
if ((Split-Path -Parent $target) -ne $runtimeParent -or
    (Split-Path -Leaf $target) -ne 'FFmpeg' -or
    (Split-Path -Parent $legacyVlc) -ne $runtimeParent -or
    (Split-Path -Leaf $legacyVlc) -ne 'VLC') {
  throw 'A pasta de destino do runtime FFmpeg não pôde ser validada.'
}

function Test-CompleteFfmpeg([string]$Root) {
  return (
    (Test-Path -LiteralPath (Join-Path $Root 'avutil-60.dll') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $Root 'avcodec-62.dll') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $Root 'avformat-62.dll') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $Root 'swscale-9.dll') -PathType Leaf)
  )
}

if (Test-CompleteFfmpeg $target) {
  if (Test-Path -LiteralPath $legacyVlc -PathType Container) {
    Remove-Item -LiteralPath $legacyVlc -Recurse -Force
  }
  exit 0
}

New-Item -ItemType Directory -Path $runtimeParent -Force | Out-Null
$transactionId = [Guid]::NewGuid().ToString('N')
$stagingRoot = Join-Path $runtimeParent ".ffmpeg-staging-$transactionId"
$extracted = Join-Path $stagingRoot 'archive'
$prepared = Join-Path $stagingRoot 'FFmpeg'
$backup = Join-Path $runtimeParent ".ffmpeg-backup-$transactionId"

try {
  New-Item -ItemType Directory -Path $extracted -Force | Out-Null
  Expand-Archive -LiteralPath $archivePath -DestinationPath $extracted -Force
  $codecLibrary = Get-ChildItem -LiteralPath $extracted -Filter 'avcodec-62.dll' `
    -File -Recurse | Select-Object -First 1
  if (-not $codecLibrary) {
    throw 'O pacote FFmpeg não trouxe avcodec-62.dll.'
  }
  $sourceRoot = $codecLibrary.Directory.FullName
  foreach ($required in @('avutil-60.dll', 'avformat-62.dll', 'swscale-9.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $required) -PathType Leaf)) {
      throw "O pacote FFmpeg não trouxe $required."
    }
  }

  New-Item -ItemType Directory -Path $prepared -Force | Out-Null
  foreach ($libraryName in @(
    'avutil-60.dll',
    'swresample-6.dll',
    'avcodec-62.dll',
    'avformat-62.dll',
    'swscale-9.dll'
  )) {
    $libraryPath = Join-Path $sourceRoot $libraryName
    if (Test-Path -LiteralPath $libraryPath -PathType Leaf) {
      Copy-Item -LiteralPath $libraryPath -Destination $prepared -Force
    }
  }
  $licenseDirectory = Join-Path $prepared 'licenses'
  New-Item -ItemType Directory -Path $licenseDirectory -Force | Out-Null
  Get-ChildItem -LiteralPath $extracted -File -Recurse | Where-Object {
    $_.Name -match '^(?i:LICENSE|COPYING)'
  } | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName `
      -Destination (Join-Path $licenseDirectory $_.Name) -Force
  }
  @(
    'FFmpeg 8.1.2 - bibliotecas compartilhadas LGPL',
    'Código-fonte: https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz',
    'Build Windows: https://github.com/BtbN/FFmpeg-Builds'
  ) | Set-Content -LiteralPath (Join-Path $licenseDirectory 'SOURCE.txt') `
    -Encoding UTF8

  if (-not (Test-CompleteFfmpeg $prepared)) {
    throw 'A preparação temporária do FFmpeg ficou incompleta.'
  }
  if (Test-Path -LiteralPath $target) {
    Move-Item -LiteralPath $target -Destination $backup
  }
  Move-Item -LiteralPath $prepared -Destination $target
  if (-not (Test-CompleteFfmpeg $target)) {
    throw 'O runtime FFmpeg instalado não passou pela verificação final.'
  }
  if (Test-Path -LiteralPath $backup) {
    Remove-Item -LiteralPath $backup -Recurse -Force
  }
  # O FFmpeg ja foi confirmado antes de retirar o runtime antigo.
  if (Test-Path -LiteralPath $legacyVlc -PathType Container) {
    Remove-Item -LiteralPath $legacyVlc -Recurse -Force
  }
} catch {
  if (Test-Path -LiteralPath $target) {
    Remove-Item -LiteralPath $target -Recurse -Force
  }
  if (Test-Path -LiteralPath $backup) {
    Move-Item -LiteralPath $backup -Destination $target
  }
  throw
} finally {
  if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
  }
}
