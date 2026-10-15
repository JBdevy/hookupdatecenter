param([string]$Executable,[string]$OutputDirectory,[string]$Project)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/native-ui-common.ps1"
Add-Type -AssemblyName System.Windows.Forms
$process=$null
function Focus-Test { [void][CatNativeUI]::SetForegroundWindow($script:main); Start-Sleep -Milliseconds 100; if([CatNativeUI]::GetForegroundWindow() -ne $script:main){Key 0x12;[void][CatNativeUI]::SetForegroundWindow($script:main);Start-Sleep -Milliseconds 200}; if([CatNativeUI]::GetForegroundWindow() -ne $script:main){throw 'Test window not foreground'} }
function Shot([string]$Name){$script:d=Capture $Name;return $script:d}
function Point-Local([double]$X,[double]$Y){$r=Rect $script:main;$s=($r.Right-$r.Left)/($script:d.logicalWidth+2);return @([int]($r.Left+($X+1)*$s),[int]($r.Top+($Y+1)*$s))}
function Tap-Control([string]$Name,[switch]$Modal){$b=if($Modal){$script:d.modalControls.$Name}else{$script:d.controls.$Name};if(!$b -or $b.width -le 0){throw "Missing control $Name"};$p=Point-Local ($b.x+$b.width/2) ($b.y+$b.height/2);Click $p[0] $p[1]}
function Text([string]$Value){[System.Windows.Forms.SendKeys]::SendWait($Value);Start-Sleep -Milliseconds 200}
function Projection-Test([string]$Control,[string]$Name){
 Focus-Test;Tap-Control $Control;Start-Sleep -Milliseconds 700
 $h=[CatNativeUI]::GetForegroundWindow();if($h -eq $script:main){throw "$Name did not open"}
 $r=Rect $h;ScreenCapture "$Name-windowed"
 $x=[int](($r.Left+$r.Right)/2);$y=[int](($r.Top+$r.Bottom)/2)
 Click $x $y;Click $x $y;Start-Sleep -Milliseconds 450
 $h=[CatNativeUI]::GetForegroundWindow();$full=Rect $h;ScreenCapture "$Name-fullscreen"
 $screen=[System.Windows.Forms.Screen]::FromHandle($h).Bounds
 if($full.Left -ne $screen.Left -or $full.Top -ne $screen.Top -or $full.Right -ne $screen.Right -or $full.Bottom -ne $screen.Bottom){throw "$Name did not fill monitor bounds"}
 Key 0x1b;Start-Sleep -Milliseconds 450
 $h=[CatNativeUI]::GetForegroundWindow();$restored=Rect $h;ScreenCapture "$Name-restored"
 if($restored.Top -ne $r.Top -or $restored.Bottom -ne $r.Bottom){throw "$Name did not restore its window"}
 Key 0x73 @(0x12);Focus-Test
}
try{
 $hash=(Get-FileHash -LiteralPath $Project).Hash
 $copyDir=Join-Path $OutputDirectory 'real-project';New-Item -ItemType Directory -Force $copyDir | Out-Null
 $copy=Join-Path $copyDir 'Validation.jl';Copy-Item -LiteralPath $Project -Destination $copy -Force
 if(!(Test-Path "$copyDir\Stems")){New-Item -ItemType Junction -Path "$copyDir\Stems" -Target (Join-Path (Split-Path $Project) 'Stems') | Out-Null}
 $arguments='--project-preview "'+$copy+'" --ui-scale 0.9 --appearance-file "'+$OutputDirectory+'\appearance.json"'
 $process=Start-Process -FilePath $Executable -ArgumentList $arguments -PassThru
 $deadline=[DateTime]::UtcNow.AddSeconds(35)
 do{Start-Sleep -Milliseconds 200;$process.Refresh();$script:main=$process.MainWindowHandle}while($script:main -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
 if($script:main -eq [IntPtr]::Zero){throw 'Preview failed to open'}
 Focus-Test;$r=Rect $script:main;Click ($r.Left+180) ($r.Top+125)
 $d=Shot 'initial'
 $p=Point-Local ($d.timeline.x+300) ($d.timeline.y+180);Wheel $p[0] $p[1] -480
 $d=Shot 'overview';$initial=$d
 # Clicking the empty lower part of a track must position the edit cursor.
 $gridX=250;$p=Point-Local ($d.timeline.x+$gridX) ($d.timeline.y+125);Click $p[0] $p[1]
 $d=Shot 'grid-cursor-selection';$expected=$initial.timeline.horizontal+$gridX/$initial.timeline.zoom
 if([Math]::Abs($d.editPosition-$expected) -gt 1){throw "Grid cursor mismatch: $($d.editPosition) expected $expected"}
 if(!$d.selectedTrack){throw 'Grid did not select track'}
 # Select another track from its header; the timeline band must repaint too.
 $p=Point-Local ($d.timeline.x-100) ($d.timeline.y+244);Click $p[0] $p[1]
 $d=Shot 'track-selected-grid'
 Tap-Control 'railKeyboard';$d=Shot 'keyboard-88-keys'
 if(!$d.keyboardVisible){throw 'Keyboard did not open'}
 # Press a key then release: retain screenshots for visual/highlight review.
 $p=Point-Local ($d.logicalWidth/2) ($d.logicalHeight-65)
 [void][CatNativeUI]::SetCursorPos($p[0],$p[1]);[CatNativeUI]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 200;ScreenCapture 'keyboard-held'
 [CatNativeUI]::mouse_event(4,0,0,0,[UIntPtr]::Zero);Start-Sleep -Milliseconds 200;ScreenCapture 'keyboard-released'
 Tap-Control 'railKeyboard';$d=Shot 'keyboard-closed'
 # Shift+M opens name/colour editor, commits once, and undoes as one step.
 Key 0x4d @(0x10);$d=Shot 'marker-editor'
 if(!$d.modalControls.nameColourName){throw 'Shift+M did not open marker editor'}
 Tap-Control 'nameColourName' -Modal;Text 'QA marker';Tap-Control 'nameColourSwatch12' -Modal
 $d=Shot 'marker-editor-colour';Tap-Control 'nameColourSave' -Modal
 $d=Shot 'marker-created';if($d.markerCount -ne $initial.markerCount+1){throw 'Marker not created'}
 Key 0x5a @(0x11);$d=Shot 'marker-undone';if($d.markerCount -ne $initial.markerCount){throw 'Marker undo failed'}
 # Edit the actual ABERTURA region in the copy, then cancel.
 $regionX=(35-$d.timeline.horizontal)*$d.timeline.zoom
 $p=Point-Local ($d.timeline.x+$regionX) ($d.timeline.y+8);Click $p[0] $p[1] -Right
 $d=Shot 'region-editor';if(!$d.modalControls.nameColourUppercase){throw 'Region editor missing uppercase setting'}
 Key 0x1b;$d=Shot 'region-cancelled'
 Tap-Control 'masterMono';$d=Shot 'master-mono-icon';Tap-Control 'masterMono';$d=Shot 'master-stereo'
 Projection-Test 'video' 'video'
 $d=Shot 'after-video'
 Projection-Test 'tp1' 'teleprompter'
 $d=Shot 'after-teleprompter'
 Key 0xbc @(0x11);$d=Shot 'settings';Tap-Control 'settingsTab6' -Modal
 $d=Shot 'account';Tap-Control 'settingsLogin' -Modal
 $d=Shot 'login-empty';if(!$d.modalControls.loginSubmit){throw 'Login not open'}
 Tap-Control 'loginEmail' -Modal;Text 'qa-login@example.invalid';Tap-Control 'loginCPF' -Modal;Text '00000000000'
 $d=Shot 'login-filled';if(!$d.modalControls.loginSubmit.enabled){throw 'Login not enabled with inputs'}
 Tap-Control 'loginSubmit' -Modal;Start-Sleep -Seconds 3
 $d=Shot 'login-response';$deadline=[DateTime]::UtcNow.AddSeconds(30)
 while($d.modalControls.loginSubmit.label -ne 'Entrar' -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Seconds 2;$d=Shot 'login-response'}
 if($d.modalControls.loginSubmit.label -ne 'Entrar'){throw 'Login did not leave busy state'}
 Tap-Control 'loginCPF' -Modal;Text '00000000000';$d=Shot 'login-retry-enabled'
 if(!$d.modalControls.loginSubmit.enabled){throw 'Login retry remains disabled'}
 Key 0x1b;Key 0x1b
 if((Get-FileHash -LiteralPath $Project).Hash -ne $hash){throw 'Original project changed'}
 @{success=$true;originalUnchanged=$true;document=$copy;keyboard=$true;gridCursor=$true;marker=$true;regionEditor=$true;video=$true;teleprompter=$true;loginRetry=$true} | ConvertTo-Json | Set-Content "$OutputDirectory/results.json" -Encoding utf8
}catch{$_ | Out-String | Set-Content "$OutputDirectory/failure.txt";$_.ScriptStackTrace | Set-Content "$OutputDirectory/stack.txt";throw}
finally{if($process -and !$process.HasExited){Stop-Process -Id $process.Id}}
