param([switch]$InspectOnly)
$ErrorActionPreference = 'Stop'
# A hosted runner can start at 1024x768. Native clicks are clipped to that
# desktop even when the application is assigned a larger window rectangle.
# Only CI may change resolution; inspection is safe on a developer machine.
if (-not $InspectOnly -and $env:GITHUB_ACTIONS -ne 'true') {
    throw 'Desktop resolution changes are restricted to GitHub Actions.'
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CatCIDisplay {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
 public struct Mode {
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string device;
  public ushort spec, driver, size, extra;
  public uint fields;
  public int x, y;
  public uint orientation, fixedOutput;
  public short color, duplex, yResolution, ttOption, collate;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string form;
  public ushort logPixels;
  public uint bits, width, height, flags, frequency;
  public uint icmMethod, icmIntent, media, dither, reserved1, reserved2, panWidth, panHeight;
 }
 [DllImport("user32.dll", CharSet=CharSet.Unicode)]
 public static extern bool EnumDisplaySettingsW(string device, int index, ref Mode mode);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)]
 public static extern int ChangeDisplaySettingsW(ref Mode mode, uint flags);
 public static Mode Read(int index) {
  Mode mode = new Mode(); mode.size = (ushort)Marshal.SizeOf(typeof(Mode));
  if (!EnumDisplaySettingsW(null, index, ref mode)) throw new Exception("Cannot read display mode.");
  return mode;
 }
}
'@
$before = [CatCIDisplay]::Read(-1)
Write-Host "Desktop before UI validation: $($before.width)x$($before.height)"
if ($InspectOnly) { return }
if ($before.width -lt 1920 -or $before.height -lt 1080) {
    $requested = $before
    $requested.width = 1920
    $requested.height = 1080
    $requested.fields = 0x180000 # DM_PELSWIDTH | DM_PELSHEIGHT
    # MSDN: flags 0 changes the current session without writing registry settings.
    # https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-changedisplaysettingsw
    $test = [CatCIDisplay]::ChangeDisplaySettingsW([ref]$requested, 2)
    if ($test -ne 0) { throw "CI desktop does not support 1920x1080 (code $test)." }
    $result = [CatCIDisplay]::ChangeDisplaySettingsW([ref]$requested, 0)
    if ($result -ne 0) { throw "Cannot resize CI desktop (code $result)." }
    Start-Sleep -Milliseconds 800
}
$after = [CatCIDisplay]::Read(-1)
if ($after.width -lt 1920 -or $after.height -lt 1080) { throw 'CI desktop is still too small for native UI validation.' }
Write-Host "Desktop ready: $($after.width)x$($after.height)"
