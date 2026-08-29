[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Archive,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$RuntimeRoot
)

$ErrorActionPreference = 'Stop'

$archiveFile = [System.IO.Path]::GetFullPath($Archive)
$runtimeParent = [System.IO.Path]::GetFullPath($RuntimeRoot)
$target = [System.IO.Path]::GetFullPath((Join-Path $runtimeParent 'VLC'))

if (-not (Test-Path -LiteralPath $archiveFile -PathType Leaf)) {
  throw 'O pacote VLC incluído na Hook Center não foi encontrado.'
}

if ((Split-Path -Parent $target) -ne $runtimeParent -or
    (Split-Path -Leaf $target) -ne 'VLC') {
  throw 'A pasta de destino do runtime VLC não pôde ser validada.'
}

$installedPlugins = Join-Path $target 'plugins'
$runtimeIsComplete =
  (Test-Path -LiteralPath (Join-Path $target 'libvlc.dll') -PathType Leaf) -and
  (Test-Path -LiteralPath (Join-Path $target 'libvlccore.dll') -PathType Leaf) -and
  (Test-Path -LiteralPath $installedPlugins -PathType Container) -and
  ($null -ne (Get-ChildItem -LiteralPath $installedPlugins -Force |
      Select-Object -First 1))
if ($runtimeIsComplete) {
  return
}

New-Item -ItemType Directory -Path $runtimeParent -Force | Out-Null
$transactionId = [Guid]::NewGuid().ToString('N')
$stagingRoot = Join-Path $runtimeParent ".vlc-staging-$transactionId"
$extracted = Join-Path $stagingRoot 'extracted'
$prepared = Join-Path $stagingRoot 'prepared'
$backup = Join-Path $runtimeParent ".vlc-backup-$transactionId"
$movedExisting = $false

try {
  New-Item -ItemType Directory -Path $extracted -Force | Out-Null
  Expand-Archive -LiteralPath $archiveFile -DestinationPath $extracted -Force

  $library = Get-ChildItem -LiteralPath $extracted -Filter 'libvlc.dll' `
    -File -Recurse | Select-Object -First 1
  if ($null -eq $library) {
    throw 'O pacote VLC não trouxe libvlc.dll.'
  }

  $sourceRoot = $library.Directory.FullName
  if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'libvlccore.dll') -PathType Leaf) -or
      -not (Test-Path -LiteralPath (Join-Path $sourceRoot 'plugins') -PathType Container)) {
    throw 'O pacote VLC não trouxe todos os componentes necessários.'
  }

  Copy-Item -LiteralPath $sourceRoot -Destination $prepared -Recurse -Force
  if (Test-Path -LiteralPath $target) {
    Move-Item -LiteralPath $target -Destination $backup
    $movedExisting = $true
  }

  try {
    Move-Item -LiteralPath $prepared -Destination $target
  } catch {
    if ($movedExisting -and
        -not (Test-Path -LiteralPath $target) -and
        (Test-Path -LiteralPath $backup)) {
      Move-Item -LiteralPath $backup -Destination $target
    }
    throw
  }

  if ($movedExisting -and (Test-Path -LiteralPath $backup)) {
    Remove-Item -LiteralPath $backup -Recurse -Force
  }
} finally {
  if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
  }
}
