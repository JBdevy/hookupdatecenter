$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CatNativeUI {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint x,uint y,int data,UIntPtr extra);
 [DllImport("user32.dll")] public static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int command);
 public struct RECT {public int Left,Top,Right,Bottom;}
}
'@
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
function Key([byte]$Key,[byte[]]$Modifiers=@()) {
 foreach($modifier in $Modifiers){[CatNativeUI]::keybd_event($modifier,0,0,[UIntPtr]::Zero)}
 Start-Sleep -Milliseconds 35
 [CatNativeUI]::keybd_event($Key,0,0,[UIntPtr]::Zero)
 [CatNativeUI]::keybd_event($Key,0,2,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 45
 foreach($modifier in $Modifiers){[CatNativeUI]::keybd_event($modifier,0,2,[UIntPtr]::Zero)}
 Start-Sleep -Milliseconds 140
}
function Rect([IntPtr]$Handle) {$rect=[CatNativeUI+RECT]::new();[void][CatNativeUI]::GetWindowRect($Handle,[ref]$rect);return $rect}
function Click([int]$X,[int]$Y,[switch]$Right) {
 [void][CatNativeUI]::SetCursorPos($X,$Y)
 Start-Sleep -Milliseconds 60
 if($Right){[CatNativeUI]::mouse_event(8,0,0,0,[UIntPtr]::Zero);[CatNativeUI]::mouse_event(16,0,0,0,[UIntPtr]::Zero)}
 else{[CatNativeUI]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[CatNativeUI]::mouse_event(4,0,0,0,[UIntPtr]::Zero)}
 Start-Sleep -Milliseconds 180
}
function Drag([int]$X,[int]$Y,[int]$ToX,[int]$ToY,[byte]$Modifier=0) {
 [void][CatNativeUI]::SetCursorPos($X,$Y)
 if($Modifier){[CatNativeUI]::keybd_event($Modifier,0,0,[UIntPtr]::Zero)}
 [CatNativeUI]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 80
 foreach($step in 1..10){[void][CatNativeUI]::SetCursorPos(($X+($ToX-$X)*$step/10),($Y+($ToY-$Y)*$step/10));Start-Sleep -Milliseconds 20}
 [CatNativeUI]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 60
 if($Modifier){[CatNativeUI]::keybd_event($Modifier,0,2,[UIntPtr]::Zero)}
 Start-Sleep -Milliseconds 250
}
function Wheel([int]$X,[int]$Y,[int]$Delta,[byte]$Modifier=0) {
 [void][CatNativeUI]::SetCursorPos($X,$Y)
 if($Modifier){[CatNativeUI]::keybd_event($Modifier,0,0,[UIntPtr]::Zero)}
 Start-Sleep -Milliseconds 45
 [CatNativeUI]::mouse_event(0x800,0,0,$Delta,[UIntPtr]::Zero)
 Start-Sleep -Milliseconds 85
 if($Modifier){[CatNativeUI]::keybd_event($Modifier,0,2,[UIntPtr]::Zero)}
 Start-Sleep -Milliseconds 180
}
function Capture([string]$Name) {
 $started=[DateTime]::UtcNow
 Key 0x7b
 $directory=Join-Path $env:APPDATA 'Hook Developer/CatLive/qa'
 $diagnostics=Join-Path $directory 'current.json'
 $deadline=[DateTime]::UtcNow.AddSeconds(3)
 while(((-not (Test-Path -LiteralPath $diagnostics)) -or (Get-Item -LiteralPath $diagnostics).LastWriteTimeUtc -lt $started) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
 if((-not (Test-Path -LiteralPath $diagnostics)) -or (Get-Item -LiteralPath $diagnostics).LastWriteTimeUtc -lt $started){ScreenCapture ($Name+'-no-diagnostics');throw "F12 did not produce fresh diagnostics: $Name"}
 Copy-Item -LiteralPath (Join-Path $directory 'current.png') -Destination (Join-Path $OutputDirectory "$Name.png") -Force
 Copy-Item -LiteralPath (Join-Path $directory 'current.json') -Destination (Join-Path $OutputDirectory "$Name.json") -Force
 return Get-Content -LiteralPath (Join-Path $directory 'current.json') -Raw -Encoding utf8 | ConvertFrom-Json
}
function ScreenCapture([string]$Name) {
 $rect=Rect ([CatNativeUI]::GetForegroundWindow())
 $image=New-Object Drawing.Bitmap (($rect.Right-$rect.Left),($rect.Bottom-$rect.Top))
 $graphics=[Drawing.Graphics]::FromImage($image)
 $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$image.Size)
 $image.Save((Join-Path $OutputDirectory "$Name.png"),[Drawing.Imaging.ImageFormat]::Png)
 $graphics.Dispose();$image.Dispose()
}
