param(
 [Parameter(Mandatory=$true)][string]$Executable,
 [string]$OutputDirectory=(Join-Path $env:LOCALAPPDATA 'CatLiveBuild/qa/selection-scroll')
)
. "$PSScriptRoot/native-ui-common.ps1"
$appearance=Join-Path $OutputDirectory 'isolated-appearance.json'
$process=Start-Process -FilePath $Executable -ArgumentList ('--visual-test --ui-scale 1 --appearance-file "'+$appearance+'"') -PassThru
try {
 Start-Sleep -Seconds 5
 $process.Refresh(); $handle=$process.MainWindowHandle
 if($handle -eq [IntPtr]::Zero){throw 'Inspection window did not open.'}
 Key 0x12
 [void][CatNativeUI]::ShowWindow($handle,9)
 [void][CatNativeUI]::SetForegroundWindow($handle)
 $initial=Capture 'selection-initial'
 $rect=Rect $handle
 $image=[Drawing.Image]::FromFile((Join-Path $OutputDirectory 'selection-initial.png'))
 $scale=$image.Width/$initial.logicalWidth
 $originX=$rect.Left+($rect.Right-$rect.Left-$image.Width)/2
 $originY=$rect.Top+($rect.Bottom-$rect.Top-$image.Height)/2
 $image.Dispose()
 function X([double]$v){return [int]($originX+$v*$scale)}
 function Y([double]$v){return [int]($originY+$v*$scale)}
 $first=$initial.timeline.visibleItems[0]
 $next=@($initial.timeline.visibleItems | Where-Object {$_.track -ne $first.track})[0]
 $footer=$first.bounds.y+$first.bounds.height+1
 Drag (X ($initial.timeline.x-60)) (Y $footer) (X ($initial.timeline.x-60)) (Y ($footer+45))
 $resized=Capture 'height-resized'
 $changed=@($resized.timeline.visibleItems | Where-Object {$_.id -eq $first.id})[0]
 $unchanged=@($resized.timeline.visibleItems | Where-Object {$_.id -eq $next.id})[0]
 if($changed.bounds.height -lt $first.bounds.height+40){throw 'Footer drag did not resize its own track.'}
 if($unchanged.bounds.height -ne $next.bounds.height){throw 'Footer drag changed a neighbouring track.'}
 $startX=X ($initial.timeline.x+100);$startY=Y ($initial.timeline.y+$initial.timeline.headerHeight+35)
 $endX=X ($initial.timeline.x+$initial.timeline.width-2);$endY=Y ($initial.footerTop-3)
 [void][CatNativeUI]::SetCursorPos($startX,$startY)
 [CatNativeUI]::mouse_event(8,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 70
 [void][CatNativeUI]::SetCursorPos($endX,$endY)
 Start-Sleep -Milliseconds 1200
 $held=Capture 'selection-held-edge'
 if($held.timeline.horizontal -le $resized.timeline.horizontal+100 -or $held.timeline.vertical -le $resized.timeline.vertical+100){throw 'Holding the right drag at the corner did not scroll both axes.'}
 if($held.selectedItems.Count -lt 2){throw 'Newly revealed items did not join the selection.'}
 [CatNativeUI]::mouse_event(16,0,0,0,[UIntPtr]::Zero)
 $released=Capture 'selection-released'
 Start-Sleep -Milliseconds 400
 $settled=Capture 'selection-settled'
 if($released.timeline.horizontal -ne $settled.timeline.horizontal -or $released.timeline.vertical -ne $settled.timeline.vertical){throw 'Auto-scroll continued after release.'}
 @{success=$true;beforeHeight=$first.bounds.height;afterHeight=$changed.bounds.height;horizontal=$held.timeline.horizontal;vertical=$held.timeline.vertical;selected=$held.selectedItems.Count} | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'results.json') -Encoding utf8
 Write-Host 'NATIVE_SELECTION_EDGE_SCROLL_AND_TRACK_FOOTER_RESIZE_OK'
} finally {
 [CatNativeUI]::mouse_event(16,0,0,0,[UIntPtr]::Zero)
 $process.Refresh()
 if(-not $process.HasExited){
  [void]$process.CloseMainWindow()
  if(-not $process.WaitForExit(1500)){Stop-Process -Id $process.Id -Force}
 }
}
