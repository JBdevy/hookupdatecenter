param([string]$Executable,[string]$OutputDirectory,[string]$Project)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/native-ui-common.ps1"
$process=$null
function Focus-Test { [void][CatNativeUI]::SetForegroundWindow($script:main); Start-Sleep -Milliseconds 100; if([CatNativeUI]::GetForegroundWindow() -ne $script:main){Key 0x12; [void][CatNativeUI]::SetForegroundWindow($script:main); Start-Sleep -Milliseconds 200}; if([CatNativeUI]::GetForegroundWindow() -ne $script:main){ScreenCapture 'focus-failure'; throw "Test window not foreground: main=$script:main actual=$([CatNativeUI]::GetForegroundWindow()) pid=$($process.Id)"} }
function Shot([string]$Name) { Focus-Test; $r=Rect $script:main; Click ($r.Left+180) ($r.Top+125); $script:d=Capture $Name; return $script:d }
function Point-Control([string]$Name) { $b=$script:d.controls.$Name; if(!$b -or $b.width -le 0){throw "Missing $Name"}; $r=Rect $script:main; $s=($r.Right-$r.Left)/($script:d.logicalWidth+2); return @([int]($r.Left+($b.x+1+$b.width/2)*$s),[int]($r.Top+($b.y+1+$b.height/2)*$s)) }
function Resize-Control([string]$Name,[int]$X,[int]$Y) { Focus-Test; $p=Point-Control $Name; Drag $p[0] $p[1] ($p[0]+$X) ($p[1]+$Y) }
function Tap-Control([string]$Name,[switch]$Right) { Focus-Test; $p=Point-Control $Name; Click $p[0] $p[1] -Right:$Right }
try {
 Remove-Item "$OutputDirectory/appearance.json","$OutputDirectory/failure.txt" -ErrorAction SilentlyContinue
 $originalHash=(Get-FileHash -LiteralPath $Project).Hash
 $copyDir=Join-Path $OutputDirectory 'real-project'
 New-Item -ItemType Directory -Force $copyDir | Out-Null
 $copy=Join-Path $copyDir 'Validation.jl'
 Copy-Item -LiteralPath $Project -Destination $copy -Force
 $stems=Join-Path (Split-Path $Project) 'Stems'
 if(!(Test-Path "$copyDir\Stems")){New-Item -ItemType Junction -Path "$copyDir\Stems" -Target $stems | Out-Null}
 $args='--project-preview "'+$copy+'" --ui-scale 0.9 --appearance-file "'+$OutputDirectory+'\appearance.json"'
 $process=Start-Process -FilePath $Executable -ArgumentList $args -PassThru
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 do {Start-Sleep -Milliseconds 200;$process.Refresh();$script:main=$process.MainWindowHandle}while($script:main -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
 if($script:main -eq [IntPtr]::Zero){throw 'Preview failed to open'}
 Start-Sleep -Seconds 2
 Focus-Test
 $r=Rect $script:main
 Click ($r.Left+180) ($r.Top+125)
 $d=Shot 'real-initial'
 $r=Rect $script:main
 Wheel ($r.Left+650) ($r.Top+280) -480
 $d=Shot 'real-overview'
 $deadline=[DateTime]::UtcNow.AddSeconds(90)
 while(($d.timeline.waveforms.ready -lt 1 -or $d.timeline.waveforms.pending -gt 0) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Seconds 2;$d=Shot 'real-waveforms'}
 if($d.timeline.waveforms.ready -lt 1){throw 'No real waveforms generated'}
 if($d.timeline.horizontalScrollbarVisible){throw 'Timeline horizontal scrollbar visible'}
 if($d.document -ne $copy){throw 'Not using isolated project copy'}
 ScreenCapture 'real-waveforms-screen'
 $base=$d
 Resize-Control 'trackMixerDivider' 60 0
 $d=Shot 'track-mixer-wider'
 if($d.trackMixerWidth -le $base.trackMixerWidth+30){throw 'Track Mixer did not resize'}
 Resize-Control 'trackMixerDivider' -60 0
 $d=Shot 'track-mixer-restored'
 $before=$d
 Resize-Control 'setlistDivider' -60 0
 $d=Shot 'setlist-wider'
 if($d.setlistWidth -le $before.setlistWidth+30){throw 'Setlist did not resize'}
 Resize-Control 'setlistDivider' 60 0
 $d=Shot 'setlist-restored'
 Resize-Control 'footerHeightDivider' 0 -55
 $d=Shot 'footer-taller'
 if($d.footerHeight -le $base.footerHeight+30){throw 'Footer height did not resize'}
 Tap-Control 'railMixer'
 $d=Shot 'mixer-docked'
 if(!$d.mixerVisible){throw 'Mixer dock did not open'}
 $before=$d.mixerDockHeight
 Resize-Control 'mixerHeightDivider' 0 -45
 $d=Shot 'mixer-taller'
 if($d.mixerDockHeight -le $before+20){throw 'Mixer dock did not resize'}
 Tap-Control 'railMixer' -Right
 ScreenCapture 'mixer-context'
 Key 0x28; Key 0x0d
 Start-Sleep -Milliseconds 600
 ScreenCapture 'mixer-floating-screen'
 $d=Shot 'mixer-detached'
 if(!$d.mixerDetached -or $d.mixerVisible){throw 'Mixer did not detach'}
 Tap-Control 'railMixer' -Right
 Key 0x28;Key 0x0d
 $d=Shot 'mixer-redocked'
 if($d.mixerDetached -or !$d.mixerVisible){throw 'Mixer did not redock'}
 Tap-Control 'railMixer'
 Resize-Control 'footerHeightDivider' 0 55
 $d=Shot 'real-final'
 $sample=$d.resourceSamples
 Start-Sleep -Milliseconds 2100
 $d=Shot 'resource-sampling'
 if($d.resourceSamples -lt $sample+2 -or $d.resourceSamples -gt $sample+4){throw 'Resource sampling cadence mismatch'}
 if($d.resourceRAM -le 0 -or $null -eq $d.resourceCPU){throw 'Process resources unavailable'}
 Key 0x54 @(0x11)
 Key 0x0d
 $d=Shot 'close-dirty'
 if(!$d.dirty){throw 'Close test did not make the copy dirty'}
 Key 0x73 @(0x12)
 Start-Sleep -Milliseconds 300
 ScreenCapture 'close-confirmation'
 Key 0x1b
 $d=Shot 'close-cancelled'
 if(!$d.dirty){throw 'Cancel changed unsaved state'}
 Key 0x73 @(0x12)
 Start-Sleep -Milliseconds 300
 ScreenCapture 'close-discard-before'
 $r=Rect $script:main
 $scale=($r.Right-$r.Left)/($d.logicalWidth+2)
 Click ([int](($r.Left+$r.Right)/2)) ([int](($r.Top+$r.Bottom)/2+58*$scale))
 if(!$process.WaitForExit(10000)){throw 'Close without saving failed'}
 if((Get-FileHash -LiteralPath $copy).Hash -ne $originalHash){throw 'Discard saved the copy'}
 if((Get-FileHash -LiteralPath $Project).Hash -ne $originalHash){throw 'Original project changed'}
 @{success=$true;waveforms=$d.timeline.waveforms;resources=@{cpu=$d.resourceCPU;ram=$d.resourceRAM;interval=$d.resourceSampleIntervalSeconds};originalUnchanged=$true;document=$copy} | ConvertTo-Json -Depth 8 | Set-Content "$OutputDirectory/results.json" -Encoding utf8
} catch {$_.ScriptStackTrace | Set-Content "$OutputDirectory/stack.txt"; $_ | Out-String | Set-Content "$OutputDirectory/failure.txt"; throw}
finally {if($process -and !$process.HasExited){Stop-Process -Id $process.Id}}
