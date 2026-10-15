param([Parameter(Mandatory=$true)][string]$Executable,[string]$OutputDirectory=(Join-Path $env:LOCALAPPDATA 'CatLiveBuild/qa/remote'),[switch]$NetworkDiscovery)
. "$PSScriptRoot/native-ui-common.ps1"
if(Get-Process CatLive -ErrorAction SilentlyContinue){throw 'Close CatLive before native Remote verification.'}
$appearanceFile=Join-Path $OutputDirectory 'appearance.json'
$process=Start-Process -FilePath $Executable -ArgumentList ('--visual-test --appearance-file "'+$appearanceFile+'"') -WindowStyle Hidden -PassThru
try {
 Start-Sleep -Milliseconds 2200; $process.Refresh(); $handle=$process.MainWindowHandle
 [void][CatNativeUI]::SetForegroundWindow($handle)
 [void][CatNativeUI]::SetWindowPos($handle,[IntPtr]::Zero,12,12,1280,740,0x0040)
 $rect=Rect $handle; Click ($rect.Left+450) ($rect.Top+17)
 $initial=Capture 'remote-minimum-window'
 if($initial.overlappingTransport){throw 'Remote overlaps other transport controls at minimum width.'}
 $remote=$initial.controls.remote
 Click ($rect.Left+$remote.x+[int]($remote.width/2)) ($rect.Top+$remote.y+[int]($remote.height/2)) -Right
 $panel=Capture 'remote-settings'
 if($panel.modals -notcontains 'Remote'){throw 'Remote right-click did not open settings.'}
 $left=$rect.Left+[int]((1280-440)/2); $top=$rect.Top+[int]((740-592)/2)+44
 Click ($left+120) ($top+212); Key 0x41 @(0x11); Key 0x31;Key 0x32;Key 0x33;Key 0x34
 Click ($left+85) ($top+292)
 Click ($left+120) ($top+378); Key 0x41 @(0x11); Key 0x35;Key 0x36;Key 0x37;Key 0x38
 Click ($left+120) ($top+456)
 $saved=Capture 'remote-pins-saved'
 $preferences=Get-Content -LiteralPath $appearanceFile -Raw | ConvertFrom-Json
 if($preferences.'jaras.remote.directorPIN' -ne '1234' -or $preferences.'jaras.remote.noticesPIN' -ne '5678'){throw 'Remote PIN fields did not save the entered values.'}
 Key 0x1b
 $closed=Capture 'remote-settings-closed'
 if($closed.modals.Count -ne 0){throw 'Escape did not close Remote settings.'}
 if($NetworkDiscovery){
  Click ($rect.Left+$remote.x+[int]($remote.width/2)) ($rect.Top+$remote.y+[int]($remote.height/2))
  Start-Sleep -Milliseconds 2500
  [void][CatNativeUI]::SetForegroundWindow($handle)
  $enabled=Capture 'remote-enabled'
  if(-not $enabled.remote.enabled -or $enabled.remote.discoveryStatus -ne 0){throw ('Native Remote discovery failed: '+$enabled.remote.status+' code='+$enabled.remote.discoveryStatus)}
  Click ($rect.Left+$remote.x+[int]($remote.width/2)) ($rect.Top+$remote.y+[int]($remote.height/2))
  $disabled=Capture 'remote-disabled'
  if($disabled.remote.enabled){throw 'Remote did not stop on the second click.'}
 }
 Click ($rect.Right-26) ($rect.Top+17)
 if(-not $process.WaitForExit(5000)){throw 'Remote test application did not close.'}
 @{success=$true;networkDiscovery=[bool]$NetworkDiscovery;initial=$initial.remote;enabled=if($NetworkDiscovery){$enabled.remote}else{$null}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $OutputDirectory 'results.json') -Encoding utf8
 Write-Host "Native Remote panel, PIN fields, Escape and transport layout passed: $OutputDirectory"
} finally {
 $process.Refresh()
 if(-not $process.HasExited){[void]$process.CloseMainWindow();Start-Sleep -Milliseconds 300;$process.Refresh();if(-not $process.HasExited){Stop-Process -Id $process.Id -Force}}
}
