$hostsPath = "$env:WINDIR\System32\drivers\etc\hosts"
if (-not (Test-Path $hostsPath)) {
  exit 0
}

$lines = Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue
$filtered = @()
foreach ($line in $lines) {
  $trimmed = $line.Trim().ToLower()
  if ($trimmed -eq '127.0.0.1 vshook.diretor' -or $trimmed -eq '127.0.0.1 vshook.musicos') {
    continue
  }
  $filtered += $line
}
Set-Content -LiteralPath $hostsPath -Value $filtered -Encoding ASCII
Write-Host 'Links do VS Hook removidos do hosts.'
