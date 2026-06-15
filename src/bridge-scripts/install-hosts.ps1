$hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
$entries = @(
  '127.0.0.1 vshook.diretor',
  '127.0.0.1 vshook.musicos'
)

$content = ''
if (Test-Path $hostsPath) {
  $content = Get-Content -LiteralPath $hostsPath -Raw -ErrorAction SilentlyContinue
}

$normalized = $content
foreach ($entry in $entries) {
  if ($normalized -notmatch [Regex]::Escape($entry)) {
    if ($normalized.Length -gt 0 -and -not $normalized.EndsWith("`r`n")) {
      $normalized += "`r`n"
    }
    $normalized += $entry + "`r`n"
  }
}

Set-Content -LiteralPath $hostsPath -Value $normalized -Encoding ASCII
Write-Host 'Hosts atualizado com os links do VS Hook.'
