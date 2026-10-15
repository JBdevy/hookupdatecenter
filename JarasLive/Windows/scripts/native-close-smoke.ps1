param([Parameter(Mandatory=$true)][string]$Executable,[string]$OutputDirectory=(Join-Path $env:LOCALAPPDATA 'CatLiveBuild/qa/closing'))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class CatCloseUI {
 public delegate bool EnumCallback(IntPtr h, IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumCallback callback,IntPtr p);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint id);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder s,int count);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,int data,UIntPtr extra);
 [DllImport("user32.dll")] public static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 public struct RECT {public int Left,Top,Right,Bottom;}
 public static IntPtr Find(int process,string title) {
  IntPtr found=IntPtr.Zero;
  EnumWindows((h,p)=>{uint id;GetWindowThreadProcessId(h,out id);var s=new StringBuilder(512);GetWindowText(h,s,512);
   if(id==process && IsWindowVisible(h) && s.ToString()==title){found=h;return false;}return true;},IntPtr.Zero);
  return found;
 }
}
'@
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$script:testProcesses=[Collections.Generic.List[Diagnostics.Process]]::new()
function Key([byte]$Code,[byte[]]$Modifiers=@()) {
 foreach($modifier in $Modifiers){[CatCloseUI]::keybd_event($modifier,0,0,[UIntPtr]::Zero)}
 Start-Sleep -Milliseconds 35
 [CatCloseUI]::keybd_event($Code,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 35
 [CatCloseUI]::keybd_event($Code,0,2,[UIntPtr]::Zero)
 foreach($modifier in $Modifiers){[CatCloseUI]::keybd_event($modifier,0,2,[UIntPtr]::Zero)}
}
function Rect([IntPtr]$Handle) {$r=[CatCloseUI+RECT]::new();[void][CatCloseUI]::GetWindowRect($Handle,[ref]$r);return $r}
function Click([int]$X,[int]$Y) {
 [void][CatCloseUI]::SetCursorPos($X,$Y)
 [CatCloseUI]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[CatCloseUI]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
}
function Capture([IntPtr]$Handle,[string]$Name) {
 $r=Rect $Handle;$image=New-Object Drawing.Bitmap (($r.Right-$r.Left),($r.Bottom-$r.Top))
 $graphics=[Drawing.Graphics]::FromImage($image)
 try {$graphics.CopyFromScreen($r.Left,$r.Top,0,0,$image.Size);$image.Save((Join-Path $OutputDirectory ($Name+'.png')),[Drawing.Imaging.ImageFormat]::Png)}
 finally {$graphics.Dispose();$image.Dispose()}
}
function WaitLogo($Process,[IntPtr]$Main,[string]$Name) {
 $timer=[Diagnostics.Stopwatch]::StartNew();$logo=[IntPtr]::Zero
 while($timer.ElapsedMilliseconds -lt 2500){$logo=[CatCloseUI]::Find($Process.Id,'CatLiveClosingSplash');if($logo -ne [IntPtr]::Zero){break};Start-Sleep -Milliseconds 10}
 if($logo -eq [IntPtr]::Zero){
  $Process.Refresh()
  if(-not $Process.HasExited){Capture $Main ($Name+'-failure')}
  throw "Closing logo did not appear: $Name (exited=$($Process.HasExited), foreground=$([CatCloseUI]::GetForegroundWindow()), main=$Main)"
 }
 Start-Sleep -Milliseconds 60
 if([CatCloseUI]::IsWindowVisible($Main)){throw 'Editor remained visible behind the closing logo.'}
 Capture $logo $Name
 if(-not $Process.WaitForExit(10000)){throw "Closing did not finish: $Name"}
 if($Process.ExitCode -ne 0){throw "Closing returned $($Process.ExitCode): $Name"}
}
function StartApp([string]$Arguments) {
 $app=Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Normal -PassThru
 $script:testProcesses.Add($app)
 Start-Sleep -Milliseconds 2100
 $app.Refresh();if($app.HasExited){throw 'CatLive exited before the test.'}
 $handle=[CatCloseUI]::Find($app.Id,'CatLive')
 if($handle -eq [IntPtr]::Zero){throw 'CatLive main window not found.'}
 [void][CatCloseUI]::SetForegroundWindow($handle);Start-Sleep -Milliseconds 100
 $r=Rect $handle;Click ($r.Left+220) ($r.Top+17);Start-Sleep -Milliseconds 100
 return @{Process=$app;Handle=$handle}
}
function InvokeButton([string]$Name) {
 $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,$Name)
 $timer=[Diagnostics.Stopwatch]::StartNew();$button=$null
 while($timer.ElapsedMilliseconds -lt 2500){
  $foreground=[CatCloseUI]::GetForegroundWindow()
  if($foreground -ne [IntPtr]::Zero){
   $window=[Windows.Automation.AutomationElement]::FromHandle($foreground)
   $button=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
   if($null -ne $button){break}
  }
  Start-Sleep -Milliseconds 50
 }
 if($null -eq $button){throw "Dialog button not found: $Name"}
 $invoke=$button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
 $invoke.Invoke()
}
$results=@()
try {
foreach($gesture in @('close-button','alt-f4','ctrl-q')) {
 $test=StartApp '--home-preview';$app=$test.Process;$handle=$test.Handle
 if($gesture -eq 'close-button'){$r=Rect $handle;Click ($r.Right-26) ($r.Top+17)}
 if($gesture -eq 'alt-f4'){Key 0x73 @(0x12)}
 if($gesture -eq 'ctrl-q'){Key 0x51 @(0x11)}
 WaitLogo $app $handle $gesture
 $results+=@{scenario=$gesture;passed=$true}
}
# Exercise the actual dirty-project guard with a disposable inspection project.
$test=StartApp '--visual-test';$app=$test.Process;$handle=$test.Handle
Key 0x54 @(0x11);Start-Sleep -Milliseconds 150
$r=Rect $handle;Click ($r.Right-26) ($r.Top+17);Start-Sleep -Milliseconds 200
Capture ([CatCloseUI]::GetForegroundWindow()) 'unsaved-confirmation'
if([CatCloseUI]::Find($app.Id,'CatLiveClosingSplash') -ne [IntPtr]::Zero){throw 'Logo appeared before the save decision.'}
Key 0x1b;Start-Sleep -Milliseconds 180
if(-not [CatCloseUI]::IsWindowVisible($handle)){throw 'Cancel did not keep the editor open.'}
$results+=@{scenario='cancel-keeps-editor';passed=$true}
[void][CatCloseUI]::SetForegroundWindow($handle)
Click ($r.Right-26) ($r.Top+17);Start-Sleep -Milliseconds 180
InvokeButton 'Salvar'
$dialogTimer=[Diagnostics.Stopwatch]::StartNew();$saveDialog=[IntPtr]::Zero
while($dialogTimer.ElapsedMilliseconds -lt 5000){
 $candidate=[CatCloseUI]::GetForegroundWindow();$candidateRect=Rect $candidate
 if($candidate -ne $handle -and ($candidateRect.Right-$candidateRect.Left) -gt 500){$saveDialog=$candidate;break}
 Start-Sleep -Milliseconds 50
}
if($saveDialog -eq [IntPtr]::Zero){throw 'Save As did not open.'}
if([CatCloseUI]::Find($app.Id,'CatLiveClosingSplash') -ne [IntPtr]::Zero){throw 'Logo appeared before Save As completed.'}
Capture $saveDialog 'save-as-before-close'
[void][CatCloseUI]::SetForegroundWindow($saveDialog);Start-Sleep -Milliseconds 300
Key 0x1b;Start-Sleep -Milliseconds 750
if(-not [CatCloseUI]::IsWindowVisible($handle)){throw 'Cancelling Save As closed the editor.'}
$results+=@{scenario='cancel-save-as-keeps-editor';passed=$true}
[void][CatCloseUI]::SetForegroundWindow($handle)
Click ($r.Right-26) ($r.Top+17);Start-Sleep -Milliseconds 180
InvokeButton 'Descartar'
WaitLogo $app $handle 'discard-close'
$results+=@{scenario='discard-before-logo';passed=$true}
# Save-and-close on a previously saved disposable document, without the native Save As dialog.
$fixture=Join-Path $OutputDirectory 'save-on-close.jl'
$seed=Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $Executable))) 'test-results/fixture.jl'
if(-not (Test-Path -LiteralPath $seed)){throw "Run WindowsIntegration first to generate $seed"}
Copy-Item -LiteralPath $seed -Destination $fixture -Force
$before=(Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
$test=StartApp ('--home-preview "'+$fixture+'"');$app=$test.Process;$handle=$test.Handle
Key 0x54 @(0x11);Start-Sleep -Milliseconds 180
$r=Rect $handle;Click ($r.Right-26) ($r.Top+17);Start-Sleep -Milliseconds 180
InvokeButton 'Salvar'
WaitLogo $app $handle 'save-close'
if((Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash -eq $before){throw 'Save-and-close did not write the changed project.'}
$results+=@{scenario='save-before-logo';passed=$true}
# Remove only this test's own entry; preserve the user's real recent projects.
$recentFile=Join-Path $env:APPDATA 'Hook Developer/CatLive/recent-projects.json'
if(Test-Path -LiteralPath $recentFile){
 $remaining=@((Get-Content -LiteralPath $recentFile -Raw | ConvertFrom-Json) | Where-Object {$_ -ne $fixture})
 ConvertTo-Json -InputObject $remaining | Set-Content -LiteralPath $recentFile -Encoding utf8
}
@{success=$true;scenarios=$results} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'results.json') -Encoding utf8
Write-Host "Closing logo and unsaved-project guard passed: $OutputDirectory"
} finally {
 # These processes were created exclusively for disposable test projects by this invocation.
 foreach($testProcess in $script:testProcesses){
  $testProcess.Refresh()
  if(-not $testProcess.HasExited){Stop-Process -Id $testProcess.Id -ErrorAction SilentlyContinue}
 }
}
