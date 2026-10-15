param(
 [Parameter(Mandatory=$true)][string]$Executable,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [Parameter(Mandatory=$true)][string]$Project
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/native-ui-common.ps1"
$env:CATLIVE_QA_NO_IMAGES=''
$process=$null
function Focus-Test { [void][CatNativeUI]::SetForegroundWindow($script:main);Key 0x12;[void][CatNativeUI]::SetForegroundWindow($script:main);Start-Sleep -Milliseconds 200;if([CatNativeUI]::GetForegroundWindow() -ne $script:main){throw 'Not foreground'} }
function Shot($name){$script:d=Capture $name;return $script:d}
function LocalClick($x,$y){$rect=Rect $script:main;$scale=($rect.Right-$rect.Left)/($script:d.logicalWidth+2);Click ([int]($rect.Left+($x+1)*$scale)) ([int]($rect.Top+($y+1)*$scale))}
function Tap($id){$b=$script:d.modalControls.$id;if(!$b){$b=$script:d.controls.$id};if(!$b){throw "Missing control $id"};LocalClick ($b.x+$b.width/2) ($b.y+$b.height/2)}
function Create-Click($name){
 Key 0x54 @(0x11);$null=Shot "$name-dialog";Tap 'createTrackType';1..5 | ForEach-Object {Key 0x28};Key 0x0d;$null=Shot "$name-selected"
 $watch=[Diagnostics.Stopwatch]::StartNew();Tap 'createTrackConfirm';$null=Shot "$name-created";$watch.Stop()
 if($script:d.trackRoles -notcontains 'generatedClick' -or $script:d.modals.Count -ne 0){throw "Click not created: $name"}
 if($script:d.streaming.primedSources -ne 0){throw 'Stopped creation primed audio'}
 return @{milliseconds=$watch.ElapsedMilliseconds;primeWaitMilliseconds=$script:d.streaming.primeWaitMilliseconds;tracks=$script:d.trackRoles.Count;device=$script:d.audioDevice;preparation=$script:d.audioPreparation}
}
try {
 if(Get-Process CatLive -ErrorAction SilentlyContinue){throw 'Close the existing CatLive before interactive validation'}
 $src=$Project
 $hash=(Get-FileHash -LiteralPath $src).Hash
 $dir="$OutputDirectory\project"; New-Item -ItemType Directory -Force $dir | Out-Null
 Copy-Item -LiteralPath $src -Destination "$dir\Validation.jl" -Force
 if(!(Test-Path "$dir\Stems")){New-Item -ItemType Junction -Path "$dir\Stems" -Target (Join-Path (Split-Path $src) 'Stems') | Out-Null}
 function Start-Preview([string]$extra){
  $script:process=Start-Process $Executable -ArgumentList ('--project-preview "'+$dir+'\Validation.jl" --ui-scale 0.9 '+$extra) -PassThru
  $script:process.Id | Set-Content "$OutputDirectory/pid.txt"
  $deadline=[DateTime]::UtcNow.AddSeconds(60)
  do{Start-Sleep -Milliseconds 300;$script:process.Refresh();$script:main=$script:process.MainWindowHandle}while($script:main -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
  if($script:main -eq [IntPtr]::Zero){throw 'No window'}
  Focus-Test;$rect=Rect $script:main;Click ($rect.Left+180) ($rect.Top+125)
  $null=Shot 'initial'
 }
 Start-Preview ''; $initial=$d
 $withoutDevice=Create-Click 'without-device';$withoutDevice | ConvertTo-Json -Depth 6 | Set-Content "$OutputDirectory/without-device-timing.json"
 Key 0x5a @(0x11);$null=Shot 'undo-without-device'
 if($d.trackRoles.Count -ne $initial.trackRoles.Count){throw 'Click undo failed'}
 Stop-Process -Id $process.Id
 Start-Preview '--inspect-audio'
 if(!$d.audioDevice){throw 'Audio device did not start automatically'}
 $null=Shot 'audio-active'
 $withDevice=Create-Click 'with-device';$withDevice | ConvertTo-Json -Depth 6 | Set-Content "$OutputDirectory/with-device-timing.json"
 Key 0x5a @(0x11);$null=Shot 'undo-with-device'
 if($d.trackRoles.Count -ne $initial.trackRoles.Count){throw 'Click undo with device failed'}
 # Real native key-down repeats must be consumed without firing Play/Stop again.
 $before=[int]$d.actionInvocations.playStop
 [CatNativeUI]::keybd_event(0x20,0,0,[UIntPtr]::Zero)
 1..20 | ForEach-Object {Start-Sleep -Milliseconds 45;[CatNativeUI]::keybd_event(0x20,0,0,[UIntPtr]::Zero)}
 $null=Shot 'space-held';$held=[int]$d.actionInvocations.playStop
 [CatNativeUI]::keybd_event(0x20,0,2,[UIntPtr]::Zero);Start-Sleep -Milliseconds 100
 if($held -ne $before+1){throw "Held Space invoked $($held-$before) times"}
 Key 0x20;$null=Shot 'space-repressed'
 if([int]$d.actionInvocations.playStop -ne $held+1){throw 'Released Space did not rearm'}
 $layoutResults=@()
 foreach($width in @(1280,1150,1100,900)){
  $rect=Rect $main
  [void][CatNativeUI]::SetWindowPos($main,[IntPtr]::Zero,$rect.Left,$rect.Top,$width,700,0x14)
  Start-Sleep -Milliseconds 300;$null=Shot "layout-$width"
  if($d.overlappingTransport -or $d.transportOutsideWindow -or $d.clippedButtonLabels.Count -gt 0){throw "Invalid layout $width : $($d.clippedButtonLabels)"}
  $layoutResults+=@{width=$width;logicalWidth=$d.logicalWidth;clipped=$d.clippedButtonLabels}
 }
 if((Get-FileHash -LiteralPath $src).Hash -ne $hash){throw 'Original modified'}
 @{success=$true;withoutDevice=$withoutDevice;withDevice=$withDevice;spaceHoldInvocations=($held-$before);spaceReleaseRearmed=$true;layouts=$layoutResults;originalUnchanged=$true} | ConvertTo-Json -Depth 8 | Set-Content "$OutputDirectory/result.json"
 'passed' | Set-Content "$OutputDirectory/status.txt"
} catch {$_ | Out-String | Set-Content "$OutputDirectory/failure.txt";$_.ScriptStackTrace | Set-Content "$OutputDirectory/stack.txt";'failed' | Set-Content "$OutputDirectory/status.txt";throw}
finally {
 [CatNativeUI]::keybd_event(0x20,0,2,[UIntPtr]::Zero)
 if($process -and !$process.HasExited){Stop-Process -Id $process.Id}
}
