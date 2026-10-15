param([Parameter(Mandatory=$true)][string]$Executable,[string]$OutputDirectory=(Join-Path $env:LOCALAPPDATA 'CatLiveBuild/qa/native'),[switch]$DownloadInstrument,[switch]$HomePreview,[switch]$TextOnly)
. "$PSScriptRoot/native-ui-common.ps1"
if(Get-Process CatLive -ErrorAction SilentlyContinue | Where-Object Path -EQ ([IO.Path]::GetFullPath($Executable))){throw 'The test executable is already running.'}
$appearanceFile=Join-Path $OutputDirectory 'appearance.json'
$launchMode=if($HomePreview){'--home-preview'}else{'--visual-test'}
if($TextOnly){$launchMode+=' --audio-fixture'}
$process=Start-Process -FilePath $Executable -ArgumentList ($launchMode+' --appearance-file "'+$appearanceFile+'"') -WindowStyle Hidden -PassThru
try {
 Start-Sleep -Milliseconds 2200;$process.Refresh();$handle=$process.MainWindowHandle
 if($handle -eq [IntPtr]::Zero){throw 'The native CatLive window did not open.'}
 [void][CatNativeUI]::SetForegroundWindow($handle)
 if($HomePreview){$rect=Rect $handle;Click ($rect.Left+420) ($rect.Top+17);Start-Sleep -Milliseconds 500;ScreenCapture 'home-window'}
 $initial=Capture 'initial'
 if($HomePreview){
  if(-not $initial.projectBrowser){throw 'Home preview did not show the project browser.'}
  $rect=Rect $handle
  Click ($rect.Left+110) ($rect.Top+117);ScreenCapture 'home-create'
  Click ($rect.Left+370) ($rect.Top+171);Start-Sleep -Milliseconds 1400;ScreenCapture 'home-reaper';Key 0x1b;Start-Sleep -Milliseconds 700
  [void][CatNativeUI]::SetForegroundWindow($handle)
  Click ($rect.Left+510) ($rect.Top+171);Start-Sleep -Milliseconds 1400;ScreenCapture 'home-logic';Key 0x1b;Start-Sleep -Milliseconds 700
  [void][CatNativeUI]::SetForegroundWindow($handle)
  Click ($rect.Left+300) ($rect.Top+117);ScreenCapture 'home-add'
  Click ($rect.Left+490) ($rect.Top+117);ScreenCapture 'home-recent'
  Click ($rect.Right-26) ($rect.Top+17)
  if(-not $process.WaitForExit(5000)){throw 'Home preview did not close.'}
  @{success=$true;initial=$initial;home=$true}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $OutputDirectory 'results.json') -Encoding utf8
  Write-Host "Home, Create/Add/Recent, REAPER/Logic selectors and close passed: $OutputDirectory"
  return
 }
 if(-not $initial.uiRegressionPassed){throw 'Embedded editing regression did not complete.'}
 [void][CatNativeUI]::SetWindowPos($handle,[IntPtr]::Zero,12,12,1280,740,0x0040)
 Start-Sleep -Milliseconds 250;$rect=Rect $handle
 [void][CatNativeUI]::SetForegroundWindow($handle)
 Click ($rect.Left+450) ($rect.Top+17)
 $small=Capture '1280x740'
 if($small.overlappingTransport){throw 'Transport controls overlap at the minimum supported width.'}
 if(-not $TextOnly){
 Key 0x4e @(0x11)
 $projects=Capture 'projects-panel'
 if($projects.modals -notcontains 'Projetos' -or $projects.projectBrowser){throw 'Projects did not open as a sheet over the editor.'}
 $projectX=$rect.Left+[int](($rect.Right-$rect.Left-560)/2)
 $projectY=$rect.Top+[int](($rect.Bottom-$rect.Top-500)/2)+76
 Click ($projectX+100) ($projectY+78);ScreenCapture 'projects-create'
 Click ($projectX+280) ($projectY+78);ScreenCapture 'projects-add'
 Click ($projectX+450) ($projectY+78);ScreenCapture 'projects-recent'
 Key 0x1b
 $projectsClosed=Capture 'projects-closed'
 if(@($projectsClosed.modals).Count -ne 0){throw 'Projects did not return to the editor.'}
 Click ($rect.Left+203) ($rect.Top+195)
 $recordArm=Capture 'track-record-armed'
 if($recordArm.recordModes[0] -ne 1){throw 'Track REC did not arm.'}
 Click ($rect.Left+203) ($rect.Top+195)
 $recordAuto=Capture 'track-record-auto'
 if($recordAuto.recordModes[0] -ne 2){throw 'Track REC did not select automatic arming.'}
 Click ($rect.Left+203) ($rect.Top+195)
 Click ($rect.Left+203) ($rect.Top+195) -Right
 ScreenCapture 'track-record-context';Key 0x1b
 $padsButton=$small.controls.railSections
 Click ($rect.Left+$padsButton.x+14) ($rect.Top+$padsButton.y+14)
 $tuner=$small.tuner
 Click ($rect.Left+$tuner.x+106) ($rect.Top+$tuner.y+13)
 $tuned=Capture 'tuner-up'
 if($tuned.tunerPitch -ne 1){throw 'Tuner + did not transpose the selected region.'}
 Click ($rect.Left+$tuner.x+45) ($rect.Top+$tuner.y+13)
 $tuneReset=Capture 'tuner-reset'
 if($tuneReset.tunerPitch -ne 0){throw 'Tuner - did not restore the selected region.'}
 Click ($rect.Left+$tuner.x+72) ($rect.Top+$tuner.y+13) -Right
 ScreenCapture 'tuner-targets'
 Click ($rect.Left+700) ($rect.Top+570)
 $tunerCancel=Capture 'tuner-cancel'
 if(@($tunerCancel.modals).Count -ne 0){throw 'Tuner Cancel did not dismiss the target editor.'}
 $pads=Capture 'pads'
 if(-not $pads.partsVisible -or $pads.pads.current.count -ne 3){throw 'Pads did not expose the selected region and its sections.'}
 Click ($rect.Left+191) ($rect.Top+560)
 $padSeek=Capture 'pads-select-section'
 if([Math]::Abs($padSeek.editPosition-20) -gt .001){throw 'Pad selection did not seek to the section.'}
 Click ($rect.Left+90) ($rect.Top+560)
 $padStart=Capture 'pads-select-start'
 if([Math]::Abs($padStart.editPosition) -gt .001){throw 'Start pad did not return to the region start.'}
 Click ($rect.Left+$padsButton.x+14) ($rect.Top+$padsButton.y+14)
 $mixerButton=$small.controls.railMixer
 $partsButton=$small.setlist.partsButton
 Click ($rect.Left+$partsButton.x+20) ($rect.Top+$partsButton.y+10)
 $partsList=Capture 'parts-sidebar'
 if(-not $partsList.partsListVisible -or $partsList.partsVisible -or -not $partsList.partsSidebar.vertical){throw 'Setlist Parts did not open the vertical section list.'}
 $sectionBounds=$partsList.partsSidebarBounds
 Click ($rect.Left+$sectionBounds.x+40) ($rect.Top+$sectionBounds.y+140)
 $sectionSeek=Capture 'parts-sidebar-seek'
 if([Math]::Abs($sectionSeek.editPosition-20) -gt .001){throw 'Vertical section click did not seek.'}
 Click ($rect.Left+$sectionBounds.x+40) ($rect.Top+$sectionBounds.y+100)
 Click ($rect.Left+$sectionBounds.x+$sectionBounds.width-40) ($rect.Top+$sectionBounds.y+55)
 $sectionQueued=Capture 'parts-sidebar-queued'
 if(-not $sectionQueued.partsSidebar.secondaryTab){throw 'Queued sections tab did not open.'}
 $partsButton=$sectionQueued.setlist.partsButton
 Click ($rect.Left+$partsButton.x+20) ($rect.Top+$partsButton.y+10)
 $partsClosed=Capture 'parts-sidebar-closed'
 if($partsClosed.partsListVisible){throw 'Parts did not close the vertical section list.'}
 Click ($rect.Left+$mixerButton.x+14) ($rect.Top+$mixerButton.y+14)
 $mixerOpen=Capture 'mixer'
 if(-not $mixerOpen.mixerVisible){throw 'Lower mixer did not open.'}
 Wheel ($rect.Left+650) ($rect.Top+600) -480
 $mixerScrolled=Capture 'mixer-scrolled'
 if($mixerScrolled.mixerScroll -le 0){throw 'Lower mixer did not scroll horizontally.'}
 Click ($rect.Left+$mixerButton.x+14) ($rect.Top+$mixerButton.y+14)
 Click ($rect.Left+636) ($rect.Top+80)
 $tempoUp=Capture 'tempo-up'
 if($tempoUp.bpm -ne ($small.bpm+1)){throw 'Tempo + did not apply the timing change.'}
 Key 0x5a @(0x11)
 $metronome=$small.controls.metronome
 Click ($rect.Left+$metronome.x+14) ($rect.Top+$metronome.y+12) -Right
 ScreenCapture 'metronome-settings';Key 0x1b
 Click ($rect.Left+$metronome.x+14) ($rect.Top+$metronome.y+12)
 $metronomeOn=Capture 'metronome-on'
 if(-not $metronomeOn.metronomeEnabled){throw 'Metronome did not enable.'}
 Click ($rect.Left+$metronome.x+14) ($rect.Top+$metronome.y+12)
 Click ($rect.Left+1118) ($rect.Top+132)
 $playlistEditor=Capture 'playlist-create'
 if(-not $playlistEditor.setlist.playlistEditor){throw 'The inline playlist editor did not open.'}
 Click ($rect.Left+1000) ($rect.Top+178)
 foreach($letter in @(0x51,0x41)){Key $letter}
 Click ($rect.Left+1010) ($rect.Top+283)
 [CatNativeUI]::keybd_event(0x10,0,0,[UIntPtr]::Zero)
 Click ($rect.Left+1010) ($rect.Top+351)
 [CatNativeUI]::keybd_event(0x10,0,2,[UIntPtr]::Zero)
 ScreenCapture 'playlist-selection'
 Click ($rect.Left+1237) ($rect.Top+684)
 $created=Capture 'playlist-created'
 if($created.setlist.playlistEditor -or $created.setlist.playlistRegions -ne 3){throw 'Playlist selection was not saved as three regions.'}
 Click ($rect.Left+1020) ($rect.Top+174) -Right
 Key 0x28;Key 0x28;Key 0x28;Key 0x0d
 ScreenCapture 'region-editor';Key 0x1b
 Click ($rect.Left+1000) ($rect.Top+132)
 Key 0x26;Key 0x0d
 $allRegions=Capture 'playlist-all-regions'
 if($allRegions.setlist.playlist){throw 'Playlist menu did not return to all regions.'}
 Click ($rect.Left+180) ($rect.Top+233)
 Click ($rect.Left+180) ($rect.Top+233)
 ScreenCapture 'track-editor';Key 0x1b
 Click ($rect.Left+180) ($rect.Top+233) -Right
 ScreenCapture 'track-group-menu'
 for($menuIndex=0;$menuIndex -lt 8;$menuIndex++){Key 0x28}
 Key 0x0d;ScreenCapture 'track-group-name';Key 0x0d
 $group=Capture 'track-group-created'
 if($group.tracks -ne 33){throw 'Creating a track group did not preserve its child.'}
 Click ($rect.Left+78) ($rect.Top+195)
 $collapsed=Capture 'track-group-collapsed'
 if($collapsed.hiddenTracks -ne 1){throw 'Folder did not collapse its child.'}
 Click ($rect.Left+78) ($rect.Top+195)
 $expanded=Capture 'track-group-expanded'
 if($expanded.hiddenTracks -ne 0){throw 'Folder did not expand its child.'}
 Key 0x5a @(0x11)
 $ungrouped=Capture 'track-group-undo'
 if($ungrouped.tracks -ne 32){throw 'Group creation did not undo.'}
 Click ($rect.Left+110) ($rect.Top+195)
 ScreenCapture 'track-patch';Key 0x1b
 Click ($rect.Left+149) ($rect.Top+195)
 $envelopes=Capture 'envelope-lane'
 if($envelopes.envelopeLanes -ne 1){throw 'Env did not reveal the track volume envelope.'}
 Click ($rect.Left+149) ($rect.Top+195) -Right
 ScreenCapture 'envelope-settings';Key 0x73 @(0x12)
 [void][CatNativeUI]::SetForegroundWindow($handle)
 Click ($rect.Left+650) ($rect.Top+260)
 Click ($rect.Left+650) ($rect.Top+260)
 $points=Capture 'envelope-point'
 if($points.envelopePoints -ne 1){throw 'Double-click did not add an envelope point.'}
 Key 0x5a @(0x11)
 $undoEnvelope=Capture 'envelope-undo'
 if($undoEnvelope.envelopePoints -ne 0){throw 'Undo did not remove the envelope point.'}
 Key 0x5a @(0x11)
 $hiddenEnvelope=Capture 'envelope-hidden'
 if($hiddenEnvelope.envelopeLanes -ne 0){throw 'Undo did not restore hidden envelopes.'}
 # The mixer scrolls tracks; the grid wheel zooms, as on macOS.
 Wheel ($rect.Left+170) ($rect.Top+400) -480
 Wheel ($rect.Left+650) ($rect.Top+400) -240 0x10
 Wheel ($rect.Left+650) ($rect.Top+400) 120 0x11
 Wheel ($rect.Right-90) ($rect.Top+400) -720
 $scroll=Capture 'scrolled'
 if($scroll.timeline.vertical -le 0 -or $scroll.timeline.horizontal -le 0 -or $scroll.setlistScroll -le 0){throw 'One of the independent scroll areas failed.'}
 Click ($rect.Left+180) ($rect.Top+275) -Right;ScreenCapture 'track-context';Key 0x1b
 Click ($rect.Left+550) ($rect.Top+250) -Right;ScreenCapture 'clip-context';Key 0x1b
 Click ($rect.Left+550) ($rect.Top+140) -Right;ScreenCapture 'ruler-context';Key 0x1b
 Key 0x54 @(0x11);ScreenCapture 'create-track';Key 0x0d;$added=Capture 'shortcut-add'
 if($added.tracks -ne 33){throw 'Ctrl+T did not create a track through native keyboard input.'}
 Key 0x5a @(0x11);Key 0x5a @(0x11,0x10);Key 0x5a @(0x11)
 $keys=Capture 'shortcuts'
 if($keys.tracks -ne 32 -or $keys.contexts -lt 3 -or $keys.wheelEvents -lt 3){throw 'Keyboard or context-menu routing regression.'}
 $grandma=$keys.controls.grandma2
 Click ($rect.Left+$grandma.x+20) ($rect.Top+$grandma.y+12);Start-Sleep -Milliseconds 250;ScreenCapture 'grandma2';Key 0x1b
 foreach($panelName in @('resolume','masterFX','settings','video','export','advanced','tp1','tp2','notices')) {
  [void][CatNativeUI]::SetForegroundWindow($handle)
  $control=$keys.controls.$panelName
  Click ($rect.Left+$control.x+[int]($control.width/2)) ($rect.Top+$control.y+[int]($control.height/2))
  Start-Sleep -Milliseconds 220
  $floating=$panelName -in @('masterFX','video','tp1','tp2','notices')
  if($floating -and [CatNativeUI]::GetForegroundWindow() -eq $handle){throw "The $panelName window did not open."}
  ScreenCapture $panelName
  if($panelName -eq 'resolume') {
   $resolumeX=$rect.Left+[int](($rect.Right-$rect.Left-680)/2)
   $resolumeY=$rect.Top+[int](($rect.Bottom-$rect.Top-520)/2)+66
   Click ($resolumeX+493) ($resolumeY+31)
   Key 0x41 @(0x11)
   foreach($digit in @(0x38,0x30,0x39,0x39)){Key $digit}
   Click ($resolumeX+110) ($resolumeY+245)
   $map=Capture 'resolume-map'
   if($map.resolume.webPort -ne 8099 -or $map.resolume.regions -ne 28){throw 'Resolume map or Webserver settings were not saved.'}
   Click ($resolumeX+623) ($resolumeY+420)
   $resolumeApplied=Capture 'resolume-applied'
   if(@($resolumeApplied.modals).Count -ne 0){throw 'Resolume Apply did not close the panel.'}
  }
  if($panelName -eq 'export') {
   $exportX=$rect.Left+[int](($rect.Right-$rect.Left-860)/2)
   $exportY=$rect.Top+[int](($rect.Bottom-$rect.Top-554)/2)+44
   Click ($exportX+320) ($exportY+404)
   ScreenCapture 'export-secondary'
   Click ($exportX+467) ($exportY+404)
   Click ($exportX+125) ($exportY+441)
   Key 0x28;Key 0x28;Key 0x0d
   $exports=Capture 'export-secondary-mp3'
   if($exports.export.jobs -ne 2 -or -not $exports.export.secondary -or $exports.export.secondaryFormat -ne 'MP3'){throw 'Secondary export did not add the selected MP3 output.'}
  }
  if($panelName -eq 'masterFX') {
   $fxWindow=[CatNativeUI]::GetForegroundWindow()
   $fx=Rect $fxWindow
   foreach($effect in 1..6) {
    Click ($fx.Left+45) ($fx.Bottom-21)
    $insert=Rect ([CatNativeUI]::GetForegroundWindow())
    Click ($insert.Left+160) ($insert.Top+127)
    $choice=@(1,2,4,5,6,3)[$effect-1]
    if($choice -gt 1){foreach($step in 1..($choice-1)){Key 0x28}}
    Key 0x0d
    ScreenCapture ("fx-insert-"+$effect)
    Click ($insert.Right-60) ($insert.Bottom-45)
    Start-Sleep -Milliseconds 260
    [void][CatNativeUI]::SetForegroundWindow($fxWindow)
    ScreenCapture ("fx-"+$effect)
    if($effect -eq 1) {
     Click ($fx.Left+500) ($fx.Top+390) -Right
     Key 0x28;Key 0x0d
     ScreenCapture 'fx-eq-added-band'
    }
   }
   Click ($fx.Left+15) ($fx.Top+32+5*30+15)
   ScreenCapture 'fx-pitch-bypass'
   Click ($fx.Left+45) ($fx.Bottom-21)
   $insert=Rect ([CatNativeUI]::GetForegroundWindow())
   Click ($insert.Left+160) ($insert.Top+127)
   foreach($step in 1..6){Key 0x28}
   Key 0x0d
   $insert=Rect ([CatNativeUI]::GetForegroundWindow())
   foreach($category in 0..14){
    Click ($insert.Left+78+($category%4)*101) ($insert.Top+142+[int][Math]::Floor($category/4)*33)
    ScreenCapture ("instruments-category-"+$category)
   }
   if($DownloadInstrument){
    Click ($insert.Left+179) ($insert.Top+241)
    Wheel ($insert.Left+200) ($insert.Top+360) -12000
    ScreenCapture 'instrument-download-ready'
    $bank=Join-Path $env:APPDATA 'Hook Developer/CatLive/Instruments/sin-bell.sf2'
    if(-not (Test-Path -LiteralPath $bank)){
     Click ($insert.Right-70) ($insert.Top+279)
     $deadline=[DateTime]::UtcNow.AddSeconds(60)
     while(-not (Test-Path -LiteralPath $bank) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 250}
     if(-not (Test-Path -LiteralPath $bank)){ScreenCapture 'instrument-download-error';throw 'Instrument download did not complete.'}
    }
    Start-Sleep -Milliseconds 300
    Click ($insert.Left+100) ($insert.Top+279)
    ScreenCapture 'instrument-downloaded'
    Click ($insert.Right-60) ($insert.Bottom-28)
    Start-Sleep -Milliseconds 400
   }else{Click ($insert.Left+60) ($insert.Bottom-28)}
   [void][CatNativeUI]::SetForegroundWindow($fxWindow)
   if($DownloadInstrument){ScreenCapture 'instrument-inserted'}
  }
  if($panelName -eq 'tp1') {
   $projection=[CatNativeUI]::GetForegroundWindow()
   $bounds=Rect $projection
   Click ($bounds.Left+200) ($bounds.Top+200) -Right
   Key 0x28;Key 0x0d
   Start-Sleep -Milliseconds 250
   if([CatNativeUI]::GetForegroundWindow() -eq $projection){throw 'Teleprompter settings did not open from the context menu.'}
   $config=Rect ([CatNativeUI]::GetForegroundWindow())
   foreach($tab in 0..2){
    Click ($config.Left+260+$tab*120) ($config.Top+56)
    ScreenCapture ("teleprompter-settings-"+$tab)
    Wheel ($config.Left+500) ($config.Top+420) -1920
    ScreenCapture ("teleprompter-settings-"+$tab+"-scroll")
   }
   Click ($config.Left+90) ($config.Top+228)
   ScreenCapture 'notice-font-menu'
   Click ($config.Left+100) ($config.Top+252)
   Click ($config.Left+44) ($config.Top+293)
   Click ($config.Left+40) ($config.Top+430)
   Click ($config.Left+112) ($config.Top+462);Key 0x41 @(0x11);Key 0x31 @(0x10)
   Click ($config.Left+40) ($config.Top+496)
   ScreenCapture 'notice-appearance-edited'
   $noticePreferences=(Get-Content -LiteralPath $appearanceFile -Raw | ConvertFrom-Json).'jaras.notices.appearance'
   if($noticePreferences.font -ne 'Georgia' -or $noticePreferences.scale -ne 50 -or -not $noticePreferences.emojiEnabled -or $noticePreferences.emoji -ne '!' -or $noticePreferences.cleanDisplay){throw 'Notice font, scale, emoji or clean display did not persist.'}
   Key 0x73 @(0x12)
   [void][CatNativeUI]::SetForegroundWindow($projection)
  }
  if($panelName -eq 'notices') {
   $noticeWindow=[CatNativeUI]::GetForegroundWindow()
   $noticeRect=Rect ([CatNativeUI]::GetForegroundWindow())
   Click ($noticeRect.Left+100) ($noticeRect.Top+200)
   foreach($letter in @(0x54,0x45,0x53,0x54,0x45)){Key $letter}
   Key 0x0d @(0x11)
   ScreenCapture 'notice-sent'
   [void][CatNativeUI]::SetForegroundWindow($handle)
   $noticeState=Capture 'notice-state'
   if(-not $noticeState.noticeActive -or $noticeState.noticeText -ne '! TESTE !'){throw 'Ctrl+Enter did not send the configured notice.'}
   $tpButton=$keys.controls.tp1
   Click ($rect.Left+$tpButton.x+20) ($rect.Top+$tpButton.y+12)
   Start-Sleep -Milliseconds 1200;ScreenCapture 'notice-projection';Key 0x73 @(0x12)
   [void][CatNativeUI]::SetForegroundWindow($noticeWindow)
  }
  if($panelName -eq 'settings') {
   $settingsX=$rect.Left+[int](($rect.Right-$rect.Left-940)/2)
   $settingsY=$rect.Top+[int](($rect.Bottom-$rect.Top-540)/2)
   foreach($tab in 0..6){
    Click ($settingsX+64) ($settingsY+76+30+46*$tab)
    ScreenCapture ("settings-tab-"+$tab)
    if($tab -eq 3){
     foreach($category in 0..5){
      Click ($settingsX+145+24+55+122*$category) ($settingsY+76+70+15)
      ScreenCapture ("actions-category-"+$category)
      Wheel ($settingsX+550) ($settingsY+400) -720
      ScreenCapture ("actions-category-"+$category+"-scroll")
      Wheel ($settingsX+550) ($settingsY+400) 4800
      Click ($settingsX+145+24+164) ($settingsY+76+70+56)
      ScreenCapture ("actions-category-"+$category+"-midi")
      Wheel ($settingsX+550) ($settingsY+400) -720
      ScreenCapture ("actions-category-"+$category+"-midi-scroll")
      Click ($settingsX+145+24+90) ($settingsY+76+70+56)
     }
    }
   }
  }
  if($panelName -eq 'advanced') {
   $sheetX=$rect.Left+[int](($rect.Right-$rect.Left-760)/2)
   $sheetY=$rect.Top+[int](($rect.Bottom-$rect.Top-420)/2)
   foreach($tab in 0..5){
    Click ($sheetX+58) ($sheetY+44+28+42*$tab)
    ScreenCapture ("advanced-tab-"+$tab)
    if($tab -eq 1){
     Wheel ($sheetX+600) ($sheetY+270) -2400
     ScreenCapture 'advanced-timeline-cleanup'
     Click ($sheetX+137+544) ($sheetY+44+287)
     $cleanup=Capture 'media-cleanup-confirmation'
     if($cleanup.modals -notcontains 'Limpar arquivos removidos da timeline'){throw 'Timeline cleanup confirmation did not open.'}
     Key 0x1b
    }
   }
   Click ($sheetX+137+367) ($sheetY+44+113)
   Key 0x28;Key 0x28;Key 0x0d
   ScreenCapture 'advanced-bold-italic'
  }
  if($floating){Key 0x73 @(0x12)}else{Key 0x1b}
  if($panelName -eq 'notices'){
   [void][CatNativeUI]::SetForegroundWindow($handle)
   $noticeClosed=Capture 'notice-closed'
   if($noticeClosed.noticeActive){throw 'Closing notices did not withdraw the message.'}
  }
  if($panelName -eq 'masterFX'){
   [void][CatNativeUI]::SetForegroundWindow($handle)
   $effects=Capture 'effects-applied'
   $expectedChain='EQ,Compressor,Delay,Reverb,Limiter,Pitch'
   if($DownloadInstrument){$expectedChain+=',Instruments'}
   if(($effects.masterEffects -join ',') -ne $expectedChain){throw 'Native effect selection or chain order is incorrect.'}
   if($effects.masterEQBands -ne 6 -or $effects.masterPitchEnabled){throw 'EQ band addition or Pitch bypass did not persist.'}
  }
 }
 [void][CatNativeUI]::SetForegroundWindow($handle)
 $appearance=Capture 'setlist-bold-italic'
 if($appearance.setlist.fontStyle -ne 2 -or $appearance.setlist.fontFace -notmatch 'Italic'){throw 'Advanced Setlist did not apply the embedded bold italic face.'}
 $saved=Get-Content -LiteralPath $appearanceFile -Raw | ConvertFrom-Json
 if($saved.'jaras.setlist.fontStyle' -ne 2){throw 'Advanced Setlist font choice was not saved.'}
 }
 Key 0x24
 Key 0x54 @(0x11)
 $trackX=$rect.Left+[int](($rect.Right-$rect.Left-370)/2)
 $trackY=$rect.Top+[int](($rect.Bottom-$rect.Top-290)/2)
 Click ($trackX+130) ($trackY+72)
 Key 0x24;Key 0x28;Key 0x28;Key 0x0d
 Click ($trackX+314) ($trackY+252)
 $textTrack=Capture 'text-track-created'
 if($textTrack.trackRoles[0] -ne 'teleprompt'){throw 'Teleprompter track was not created at the top.'}
 Click ($rect.Left+180) ($rect.Top+233) -Right
 for($index=0;$index -lt 8;$index++){Key 0x28}
 Key 0x0d
 $notepad=Capture 'text-editor-empty'
 if($notepad.modals -notcontains 'Editor de texto'){throw 'Add text did not open the text editor.'}
 foreach($letter in @(0x51,0x41)){Key $letter}
 Key 0x0d
 foreach($letter in @(0x54,0x45,0x58,0x54)){Key $letter}
 $draft=Capture 'text-editor-draft'
 if($draft.textItems[0].text -ne ''){throw 'Text draft changed the project before Apply.'}
 Key 0x0d @(0x11)
 $textApplied=Capture 'text-editor-applied'
 if(@($textApplied.modals).Count -ne 0 -or $textApplied.textItems[0].text -notmatch '(?i)^qa\r?\ntext$'){throw 'Ctrl+Enter did not apply multiline text.'}
 Key 0x5a @(0x11)
 $textUndo=Capture 'text-editor-undo'
 if($textUndo.textItems[0].text -ne ''){throw 'Text change did not undo.'}
 Key 0x5a @(0x11,0x10)
 $textRedo=Capture 'text-editor-redo'
 if($textRedo.textItems[0].text -ne $textApplied.textItems[0].text){throw 'Text change did not redo.'}
 if($TextOnly){
  Click ($rect.Left+340) ($rect.Top+210);Click ($rect.Left+340) ($rect.Top+210)
  $reopened=Capture 'text-editor-reopened'
  if($reopened.modals -notcontains 'Editor de texto'){throw 'Double click did not reopen the text editor.'}
  Key 0x41 @(0x11);Key 0x44
  Key 0x1b
  $cancelled=Capture 'text-editor-cancelled'
  if(@($cancelled.modals).Count -ne 0 -or $cancelled.textItems[0].text -ne $textApplied.textItems[0].text){throw 'Cancel changed the saved text.'}
  $scale=$cancelled.timeline.zoom
  $rightEdge=$rect.Left+314+[int](10*$scale)-3
  Drag $rightEdge ($rect.Top+215) ($rightEdge+[int](2*$scale)) ($rect.Top+215) 0x10
  $extended=Capture 'text-item-extended'
  if([Math]::Abs($extended.textItems[0].duration-12) -gt .01){throw 'Dragging the right edge did not extend the text item.'}
  Key 0x5a @(0x11)
  $leftEdge=$rect.Left+315
  Drag $leftEdge ($rect.Top+215) ($leftEdge+[int](2*$scale)) ($rect.Top+215) 0x10
  $trimmed=Capture 'text-item-trimmed'
  if([Math]::Abs($trimmed.textItems[0].start-2) -gt .01 -or [Math]::Abs($trimmed.textItems[0].duration-8) -gt .01){throw 'Dragging the left edge did not trim the text item.'}
  Key 0x5a @(0x11)
  Drag ($rect.Left+350) ($rect.Top+275) ($rect.Left+350) ($rect.Top+339) 0x10
  $moved=Capture 'item-moved-between-tracks'
  if($moved.trackClipCounts[1] -ne 3 -or $moved.trackClipCounts[2] -ne 5){throw 'Vertical item drag did not transfer to the destination track.'}
  Key 0x5a @(0x11)
  $moveUndo=Capture 'item-move-undo'
  if($moveUndo.trackClipCounts[1] -ne 4 -or $moveUndo.trackClipCounts[2] -ne 4){throw 'Vertical item move did not undo.'}
  Click ($rect.Left+326) ($rect.Top+258)
  $itemMuted=Capture 'item-header-muted'
  if(-not $itemMuted.selectedItemMuted){throw 'Item header M did not mute the item.'}
  Key 0x5a @(0x11)
  $itemMuteUndo=Capture 'item-header-mute-undo'
  if($itemMuteUndo.selectedItemMuted){throw 'Item header mute did not undo.'}
  Click ($rect.Left+350) ($rect.Top+275) -Right
  ScreenCapture 'audio-item-menu'
  Key 0x28;Key 0x28;Key 0x0d
  $itemTuner=Capture 'item-tuner'
  if($itemTuner.modals -notcontains 'Tuner'){throw 'Item Tuner did not open.'}
  $tunerX=$rect.Left+[int](($rect.Right-$rect.Left-440)/2)
  $tunerY=$rect.Top+[int](($rect.Bottom-$rect.Top-164)/2)+44
  Click ($tunerX+390) ($tunerY+40)
  $itemPitch=Capture 'item-tuner-pitch'
  if($itemPitch.selectedItemPitch -ne 1){throw 'Item Tuner + did not apply transposition.'}
  Click ($tunerX+294) ($tunerY+40)
  Click ($tunerX+382) ($tunerY+91)
  $itemTunerClosed=Capture 'item-tuner-closed'
  if(@($itemTunerClosed.modals).Count -ne 0 -or $itemTunerClosed.selectedItemPitch -ne 0){throw 'Item Tuner did not reset and close.'}
  Click ($rect.Left+350) ($rect.Top+275) -Right
  Key 0x28;Key 0x28;Key 0x28;Key 0x0d
  $normalizer=Capture 'item-normalize'
  if($normalizer.modals -notcontains 'Normalizar'){throw 'Normalize did not open.'}
  $normalX=$rect.Left+[int](($rect.Right-$rect.Left-360)/2)
  $normalY=$rect.Top+[int](($rect.Bottom-$rect.Top-274)/2)+44
  foreach($modeIndex in 0..3){
   Click ($normalX+190) ($normalY+31);Key 0x24
   for($entry=0;$entry -lt $modeIndex;$entry++){Key 0x28}
   Key 0x0d;ScreenCapture ('item-normalize-mode-'+$modeIndex)
  }
  Click ($normalX+190) ($normalY+31);Key 0x24;Key 0x28;Key 0x28;Key 0x0d
  Click ($normalX+170) ($normalY+75);Key 0x41 @(0x11);Key 0x30
  Click ($normalX+290) ($normalY+195)
  Start-Sleep -Milliseconds 1000
  $normalized=Capture 'item-normalized'
  if(@($normalized.modals).Count -ne 0 -or [Math]::Abs($normalized.selectedItemNormalization-2) -gt .002){throw 'Peak normalization did not measure and apply the fixture gain.'}
  $preferences=Get-Content -LiteralPath $appearanceFile -Raw | ConvertFrom-Json
  if($preferences.'jaras.normalization.target.Peak' -ne 0){throw 'Normalization target was not saved.'}
  Key 0x5a @(0x11)
  $normalizeUndo=Capture 'item-normalize-undo'
  if($normalizeUndo.selectedItemNormalization -ne 1){throw 'Normalization did not undo.'}
  Key 0x4e
  $normalizerShortcut=Capture 'item-normalize-shortcut'
  if($normalizerShortcut.modals -notcontains 'Normalizar'){throw 'N did not open the same normalization panel as the item menu.'}
  Key 0x1b
  Click ($rect.Left+350) ($rect.Top+275) -Right
  Key 0x28;Key 0x28;Key 0x28;Key 0x28;Key 0x0d
  $mono=Capture 'item-mono-left'
  if($mono.selectedItemChannelMode -ne 1){throw 'Convert Mono - L did not persist the source channel.'}
  Key 0x5a @(0x11)
  Click ($rect.Left+350) ($rect.Top+275) -Right
  for($entry=0;$entry -lt 9;$entry++){Key 0x28}
  Key 0x0d
  $stem=Capture 'item-export'
  if($stem.export.source -ne 4 -or $stem.export.jobs -ne 1){throw 'Item Export did not select the clicked stem.'}
  Key 0x1b
 }
 Key 0x46
 $fit=Capture 'timeline-fit'
 if($fit.timeline.horizontal -ne 0 -or $fit.timeline.zoom -ge 2 -or $fit.timeline.zoom*1680 -gt $fit.timeline.width){throw 'Fit did not display the full 28-minute inspection timeline.'}
 [void][CatNativeUI]::SetForegroundWindow($handle)
 Click ($rect.Right-52) ($rect.Top+17)
 if(-not [CatNativeUI]::IsZoomed($handle)){throw 'Custom maximize button failed.'}
 $maximized=Rect $handle;ScreenCapture 'maximized'
 Click ($maximized.Right-52) ($maximized.Top+17)
 if([CatNativeUI]::IsZoomed($handle)){throw 'Custom restore button failed.'}
 $restored=Rect $handle
 Click ($restored.Right-78) ($restored.Top+17)
 if(-not [CatNativeUI]::IsIconic($handle)){throw 'Custom minimize button failed.'}
 [void][CatNativeUI]::ShowWindow($handle,9);[void][CatNativeUI]::SetForegroundWindow($handle)
 Start-Sleep -Milliseconds 180
 $restored=Rect $handle
 Click ($restored.Right-26) ($restored.Top+17)
 Start-Sleep -Milliseconds 250;$process.Refresh()
 if(-not $process.HasExited){
  $dialog=[Windows.Automation.AutomationElement]::FromHandle([CatNativeUI]::GetForegroundWindow())
  $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'Descartar')
  $discard=$dialog.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
  if($null -ne $discard){$discard.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
  if(-not $process.WaitForExit(5000)){throw 'Custom close button did not finish the closing logo sequence.'}
 }
 @{success=$true;textOnly=[bool]$TextOnly;initial=$initial;small=$small;scroll=$scroll;keys=$keys} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $OutputDirectory 'results.json') -Encoding utf8
 if($TextOnly){Write-Host "Native text creation, multiline Apply, Cancel, undo/redo and window buttons passed: $OutputDirectory"}
 else{Write-Host "Native mouse, wheel, shortcuts and context menus passed: $OutputDirectory"}
} finally {
 $process.Refresh()
 if(-not $process.HasExited){[void]$process.CloseMainWindow();if(-not $process.WaitForExit(1500)){Stop-Process -Id $process.Id -Force}}
}
