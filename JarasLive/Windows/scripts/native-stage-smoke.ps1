param([Parameter(Mandatory=$true)][string]$Executable,[string]$OutputDirectory=(Join-Path $env:LOCALAPPDATA 'CatLiveBuild/qa/stage'))
. "$PSScriptRoot/native-ui-common.ps1"
if(Get-Process CatLive -ErrorAction SilentlyContinue){throw 'Close CatLive before native stage verification.'}
$appearanceFile=Join-Path $OutputDirectory 'appearance.json'
$process=Start-Process -FilePath $Executable -ArgumentList ('--visual-test --appearance-file "'+$appearanceFile+'"') -WindowStyle Hidden -PassThru
try {
 Start-Sleep -Milliseconds 2200; $process.Refresh(); $handle=$process.MainWindowHandle
 [void][CatNativeUI]::SetForegroundWindow($handle)
 $rect=Rect $handle;Click ($rect.Left+450) ($rect.Top+17)
 $initial=Capture 'stage-initial'
 $button=$initial.controls.tp1
 Click ($rect.Left+$button.x+20) ($rect.Top+$button.y+12)
 $projection=[CatNativeUI]::GetForegroundWindow();$bounds=Rect $projection
 Click ($bounds.Left+200) ($bounds.Top+200) -Right;Key 0x28;Key 0x0d
 $config=Rect ([CatNativeUI]::GetForegroundWindow())
 foreach($tab in 0..2){Click ($config.Left+260+$tab*120) ($config.Top+56);ScreenCapture ('stage-appearance-'+$tab);Wheel ($config.Left+500) ($config.Top+420) -1920;ScreenCapture ('stage-appearance-'+$tab+'-scroll')}
 Click ($config.Left+90) ($config.Top+228);Click ($config.Left+100) ($config.Top+252)
 Click ($config.Left+44) ($config.Top+293)
 Click ($config.Left+40) ($config.Top+430)
 Click ($config.Left+112) ($config.Top+462);Key 0x41 @(0x11);Key 0x31 @(0x10)
 Click ($config.Left+40) ($config.Top+496)
 ScreenCapture 'notice-appearance-edited'
 $settings=(Get-Content $appearanceFile -Raw|ConvertFrom-Json).'jaras.notices.appearance'
 if($settings.font -ne 'Georgia' -or $settings.scale -ne 50 -or $settings.emoji -ne '!' -or -not $settings.emojiEnabled -or $settings.cleanDisplay){throw 'Notice appearance controls did not persist.'}
 Key 0x73 @(0x12)
 [void][CatNativeUI]::SetForegroundWindow($projection);Key 0x73 @(0x12)
 [void][CatNativeUI]::SetForegroundWindow($handle)
 $button=$initial.controls.notices;Click ($rect.Left+$button.x+20) ($rect.Top+$button.y+12)
 $notice=[CatNativeUI]::GetForegroundWindow();$bounds=Rect $notice
 Click ($bounds.Left+100) ($bounds.Top+200)
 foreach($letter in @(0x54,0x45,0x53,0x54,0x45)){Key $letter}
 Key 0x0d @(0x11);ScreenCapture 'notice-sent'
 [void][CatNativeUI]::SetForegroundWindow($handle)
 $sent=Capture 'notice-state'
 if(-not $sent.noticeActive -or $sent.noticeText -ne '! TESTE !'){throw 'Ctrl+Enter did not send the configured notice.'}
 $button=$initial.controls.tp1;Click ($rect.Left+$button.x+20) ($rect.Top+$button.y+12)
 Start-Sleep -Milliseconds 1200;ScreenCapture 'notice-projection';Key 0x73 @(0x12)
 [void][CatNativeUI]::SetForegroundWindow($notice);Key 0x73 @(0x12)
 ScreenCapture 'notice-after-close'
 [void][CatNativeUI]::SetForegroundWindow($handle)
 $closed=Capture 'notice-closed'
 if($closed.noticeActive){throw 'Closing Recados did not withdraw the notice.'}
 @{success=$true;appearance=$settings;notice=$sent.noticeText}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $OutputDirectory 'results.json') -Encoding utf8
 Write-Host "Native stage appearance, Ctrl+A/Ctrl+Enter, projection and withdrawal passed: $OutputDirectory"
} finally {
 $process.Refresh();if(-not $process.HasExited){[void]$process.CloseMainWindow();if(-not $process.WaitForExit(1500)){Stop-Process -Id $process.Id -Force}}
}
