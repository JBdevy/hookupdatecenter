param(
 [Parameter(Mandatory=$true)][string]$Executable,
 [Parameter(Mandatory=$true)][string]$Project,
 [string]$OutputDirectory=(Join-Path $env:LOCALAPPDATA 'CatLiveBuild/qa/gestures')
)
. "$PSScriptRoot/native-ui-common.ps1"
$originalHash=(Get-FileHash -LiteralPath $Project).Hash
# Inspection does not restore credentials, open an audio device, or save the project.
$process=Start-Process -FilePath $Executable -ArgumentList ('--home-preview "'+$Project+'"') -WindowStyle Hidden -PassThru
function EmitWheel([int]$Delta,[byte]$Modifier=0,[switch]$Horizontal) {
 [void][CatNativeUI]::SetCursorPos($mouseX,$mouseY)
 if($Modifier){[CatNativeUI]::keybd_event($Modifier,0,0,[UIntPtr]::Zero)}
 $flags=if($Horizontal){0x1000}else{0x800}
 [CatNativeUI]::mouse_event($flags,0,0,$Delta,[UIntPtr]::Zero)
 if($Modifier){Start-Sleep -Milliseconds 25;[CatNativeUI]::keybd_event($Modifier,0,2,[UIntPtr]::Zero)}
}
try {
 Start-Sleep -Seconds 5
 $process.Refresh();$handle=$process.MainWindowHandle
 if($handle -eq [IntPtr]::Zero){throw 'The inspection window did not open.'}
 Key 0x12
 [void][CatNativeUI]::ShowWindow($handle,9)
 [void][CatNativeUI]::SetForegroundWindow($handle)
 if([CatNativeUI]::GetForegroundWindow() -ne $handle){throw 'Could not focus the inspection window.'}
 $rect=Rect $handle
 Click ($rect.Left+600) ($rect.Bottom-15)
 $initial=Capture 'gesture-initial'
 if($initial.document -ne $Project -or $initial.dirty){throw 'Unexpected inspection project state.'}
 $snapshot=[Drawing.Image]::FromFile((Join-Path $OutputDirectory 'gesture-initial.png'))
 $borderX=[int](($rect.Right-$rect.Left-$snapshot.Width)/2)
 $borderY=[int](($rect.Bottom-$rect.Top-$snapshot.Height)/2)
 $snapshot.Dispose()
 $anchor=[int]($initial.timeline.width/2)
 $mouseX=$rect.Left+$borderX+$initial.timeline.x+$anchor
 $mouseY=$rect.Top+$borderY+$initial.timeline.y+200
 EmitWheel 120
 $zoomMoving=Capture 'zoom-moving'
 Start-Sleep -Milliseconds 750
 $zoomEnd=Capture 'zoom-end'
 if(-not $zoomMoving.timeline.gestureActive -or $zoomEnd.timeline.gestureActive){throw 'Zoom did not animate and settle.'}
 if($zoomMoving.timeline.zoom -le $initial.timeline.zoom -or $zoomEnd.timeline.zoom -le $zoomMoving.timeline.zoom){throw 'Zoom lost its deceleration tail.'}
 $timeBefore=($initial.timeline.horizontal+$anchor)/$initial.timeline.zoom
 $timeAfter=($zoomEnd.timeline.horizontal+$anchor)/$zoomEnd.timeline.zoom
 if([Math]::Abs($timeBefore-$timeAfter) -gt .001){throw 'Zoom moved the time under the cursor.'}
 EmitWheel 120 0x11
 $height=Capture 'ctrl-height'
 if($height.timeline.zoom -ne $zoomEnd.timeline.zoom -or $height.timeline.trackHeight -le $zoomEnd.timeline.trackHeight){throw 'Ctrl+wheel must change track height only.'}
 EmitWheel -360 0x10
 $panMoving=Capture 'pan-moving'
 Start-Sleep -Milliseconds 750
 $panEnd=Capture 'pan-end'
 if(-not $panMoving.timeline.gestureActive -or $panEnd.timeline.gestureActive){throw 'Horizontal movement did not animate and settle.'}
 if($panMoving.timeline.horizontal -le $height.timeline.horizontal -or $panEnd.timeline.horizontal -le $panMoving.timeline.horizontal -or $panEnd.timeline.zoom -ne $height.timeline.zoom){throw 'Horizontal deceleration or wheel mapping failed.'}
 EmitWheel -120 0x10
 $forward=Capture 'pan-forward'
 EmitWheel 120 0x10
 $reverse=Capture 'pan-reverse'
 Start-Sleep -Milliseconds 750
 $reverseEnd=Capture 'pan-reverse-end'
 if($reverse.timeline.horizontal -ge $forward.timeline.horizontal -or $reverseEnd.timeline.gestureActive){throw 'Reversing the gesture retained the previous direction.'}
 # Small native horizontal deltas model precision touchpad input.
 foreach($step in 1..5){EmitWheel -12 -Horizontal;Start-Sleep -Milliseconds 18}
 Start-Sleep -Milliseconds 750
 $precision=Capture 'precision-horizontal'
 if([Math]::Abs($precision.timeline.horizontal-$reverseEnd.timeline.horizontal) -lt 1 -or $precision.timeline.zoom -ne $reverseEnd.timeline.zoom -or $precision.timeline.gestureActive){throw 'Small horizontal deltas were lost or changed zoom.'}
 foreach($name in @('zoomIn','zoomOut','zoomFit')){
  $control=$precision.controls.$name
  Click ($rect.Left+$control.x+10) ($rect.Top+$control.y+10)
  $result=Capture $name
  if($name -eq 'zoomIn' -and $result.timeline.zoom -le $precision.timeline.zoom){throw 'Zoom + failed.'}
  if($name -eq 'zoomOut' -and [Math]::Abs($result.timeline.zoom-$precision.timeline.zoom) -gt .001){throw 'Zoom - failed.'}
  if($name -eq 'zoomFit' -and $result.timeline.horizontal -ne 0){throw 'Fit did not return to the timeline start.'}
 }
 if($result.dirty -or (Get-FileHash -LiteralPath $Project).Hash -ne $originalHash){throw 'Navigation modified the project.'}
 @{success=$true;initial=$initial.timeline;zoomMoving=$zoomMoving.timeline;zoomEnd=$zoomEnd.timeline;panMoving=$panMoving.timeline;panEnd=$panEnd.timeline;reverse=$reverse.timeline;precision=$precision.timeline;trackHeight=$height.timeline.trackHeight} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutputDirectory 'gesture-results.json') -Encoding utf8
 Write-Host "Native zoom, cursor anchor, Ctrl height, horizontal decay, reversal, precision deltas and buttons passed: $OutputDirectory"
} finally {
 $process.Refresh()
 if(-not $process.HasExited){
  # Only the isolated, unsaved inspection instance belongs to this test.
  [void]$process.CloseMainWindow()
  if(-not $process.WaitForExit(5000)){Stop-Process -Id $process.Id -Force}
 }
}
