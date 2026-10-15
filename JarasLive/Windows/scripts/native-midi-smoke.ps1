param([Parameter(Mandatory=$true)][string]$Executable,[string]$OutputDirectory=(Join-Path $env:LOCALAPPDATA 'CatLiveBuild/qa/midi'))
. "$PSScriptRoot/native-ui-common.ps1"
if(Get-Process CatLive -ErrorAction SilentlyContinue){throw 'Close CatLive before native MIDI verification.'}
$appearanceFile=Join-Path $OutputDirectory 'appearance.json'
$process=Start-Process -FilePath $Executable -ArgumentList ('--visual-test --appearance-file "'+$appearanceFile+'"') -WindowStyle Hidden -PassThru
try {
 Start-Sleep -Milliseconds 2200; $process.Refresh(); $handle=$process.MainWindowHandle
 [void][CatNativeUI]::SetForegroundWindow($handle)
 [void][CatNativeUI]::SetWindowPos($handle,[IntPtr]::Zero,12,12,1280,740,0x0040)
 $rect=Rect $handle
 Click ($rect.Left+450) ($rect.Top+17)
 Key 0x46
 $initial=Capture 'midi-initial'
 Click ($rect.Left+620) ($rect.Top+215) -Right
 ScreenCapture 'midi-create-menu'
 Key 0x28;Key 0x28;Key 0x28;Key 0x0d
 Start-Sleep -Milliseconds 350
 $piano=[CatNativeUI]::GetForegroundWindow()
 if($piano -eq $handle){throw 'Add MIDI did not open Piano Roll.'}
 $bounds=Rect $piano
 ScreenCapture 'midi-empty'
 function MIDIState([string]$Name) {
  [void][CatNativeUI]::SetForegroundWindow($handle)
  $state=Capture $Name
  [void][CatNativeUI]::SetForegroundWindow($piano)
  return $state
 }
 Drag ($bounds.Left+214) ($bounds.Top+353) ($bounds.Left+414) ($bounds.Top+353)
 Click ($bounds.Left+364) ($bounds.Top+317)
 $created=MIDIState 'midi-notes-created'
 if($created.selectedMIDINotes -ne 2 -or $created.midiNotes[0].length -lt 1.9){throw 'MIDI creation or note length failed.'}
 ScreenCapture 'midi-two-notes'
 Key 0x41 @(0x11)
 Drag ($bounds.Left+260) ($bounds.Top+353) ($bounds.Left+310) ($bounds.Top+335)
 $moved=MIDIState 'midi-chord-moved'
 if($moved.midiNotes[0].pitch -ne $created.midiNotes[0].pitch+1 -or [Math]::Abs($moved.midiNotes[1].start-$created.midiNotes[1].start-.5) -gt .001){throw 'MIDI multi-selection drag failed.'}
 Key 0x5a @(0x11)
 $undone=MIDIState 'midi-undo'
 if($undone.midiNotes[0].pitch -ne $created.midiNotes[0].pitch){throw 'MIDI undo failed.'}
 Key 0x5a @(0x11,0x10)
 $redone=MIDIState 'midi-redo'
 if($redone.midiNotes[0].pitch -ne $moved.midiNotes[0].pitch){throw 'MIDI redo failed.'}
 Drag ($bounds.Left+310) ($bounds.Top+335) ($bounds.Left+333) ($bounds.Top+335) 0x10
 $free=MIDIState 'midi-free-drag'
 if([Math]::Abs($free.midiNotes[0].start-2.23) -gt .001){throw 'Shift did not bypass MIDI snapping.'}
 Click ($bounds.Left+306) ($bounds.Top+95)
 ScreenCapture 'midi-quantize-options'
 $processCondition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$process.Id)
 $nameCondition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'Aplicar')
 $condition=[Windows.Automation.AndCondition]::new($processCondition,$nameCondition)
 $buttons=[Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Descendants,$condition)
 $quantizeButton=$null
 foreach($button in $buttons){if($button.Current.BoundingRectangle.Top -lt $bounds.Top+400){$quantizeButton=$button}}
 if($null -eq $quantizeButton){throw 'Quantize Apply button was not accessible.'}
 $quantizeButton.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
 Start-Sleep -Milliseconds 200
 $quantized=MIDIState 'midi-quantized'
 if([Math]::Abs($quantized.midiNotes[0].start-2.25) -gt .001 -or [Math]::Abs($quantized.midiNotes[1].start-3.75) -gt .001){throw 'MIDI quantization did not apply the selected grid.'}
 Click ($bounds.Left+608) ($bounds.Bottom-41)
 Key 0x41 @(0x11);Key 0x37;Key 0x35;Key 0x0d
 Click ($bounds.Left+710) ($bounds.Bottom-41)
 $velocity=MIDIState 'midi-velocity'
 if(@($velocity.midiNotes | Where-Object velocity -NE 75).Count -ne 0){throw 'MIDI velocity Apply did not update the selection.'}
 Click ($bounds.Left+30) ($bounds.Top+300)
 Key 0x41 @(0x11);Key 0x2e
 $deleted=MIDIState 'midi-delete'
 if($deleted.selectedMIDINotes -ne 0){throw 'Delete did not remove selected MIDI notes.'}
 Key 0x5a @(0x11)
 $restored=MIDIState 'midi-delete-undo'
 if($restored.selectedMIDINotes -ne 2){throw 'Deleted MIDI notes did not restore.'}
 Wheel ($bounds.Left+500) ($bounds.Top+300) -480
 ScreenCapture 'midi-vertical-scroll'
 Wheel ($bounds.Left+500) ($bounds.Top+300) -480 0x10
 ScreenCapture 'midi-horizontal-scroll'
 Key 0x73 @(0x12)
 [void][CatNativeUI]::SetForegroundWindow($handle)
 Click ($rect.Right-26) ($rect.Top+17)
 Start-Sleep -Milliseconds 250
 $dialog=[Windows.Automation.AutomationElement]::FromHandle([CatNativeUI]::GetForegroundWindow())
 $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'Descartar')
 $discard=$dialog.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
 if($null -ne $discard){$discard.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
 if(-not $process.WaitForExit(5000)){throw 'MIDI test application did not close.'}
 @{success=$true;created=$created.midiNotes;moved=$moved.midiNotes;velocity=$velocity.midiNotes}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $OutputDirectory 'results.json') -Encoding utf8
 Write-Host "Native MIDI creation, chord drag, undo/redo, velocity, delete and scrolling passed: $OutputDirectory"
} finally {
 $process.Refresh()
 if(-not $process.HasExited){[void]$process.CloseMainWindow();Start-Sleep -Milliseconds 250;$process.Refresh();if(-not $process.HasExited){Stop-Process -Id $process.Id -Force}}
}
