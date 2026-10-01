# Read-only diagnostic. Never prints or changes the activation token or hardware ID.
$ErrorActionPreference = 'Stop'
function Normalize-Identity([string]$Value) { return ($Value.Trim().ToUpperInvariant() -replace '\s', '') }
function Fingerprint([string]$Anchor) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('VSHOOK_DEVICE_V1|win32|' + (Normalize-Identity $Anchor)))) -replace '-', '') }
    finally { $sha.Dispose() }
}
$shared = $env:PUBLIC
if (-not $shared) { $shared = $env:ALLUSERSPROFILE }
if (-not $shared) { $shared = 'C:\Users\Public' }
$tokenPath = Join-Path $shared 'vshook_license_v3.token'
$machinePath = Join-Path $shared 'vslive_machine_id.dat'
$report = [ordered]@{ TokenFilePresent = (Test-Path -LiteralPath $tokenPath); MachineFilePresent = (Test-Path -LiteralPath $machinePath) }
$base = $null; $key = $null; $anchor = ''
try {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $key = $base.OpenSubKey('SOFTWARE\Microsoft\Cryptography')
    if ($key -and $key.GetValueKind('MachineGuid') -eq [Microsoft.Win32.RegistryValueKind]::String) { $anchor = Normalize-Identity ([string]$key.GetValue('MachineGuid')) }
} catch { $anchor = '' }
finally { if ($key) { $key.Dispose() }; if ($base) { $base.Dispose() } }
$report.MachineGuidReadable = [bool]$anchor
$report.MachineGuidHasBraces = $anchor.Contains('{') -or $anchor.Contains('}')
if (-not $anchor) {
    $anchor = $env:COMPUTERNAME
    if (-not $anchor) { $anchor = $env:HOSTNAME }
    if (-not $anchor) { $anchor = 'UNKNOWNHOST' }
}
try {
    if ($report.TokenFilePresent) {
        $token = [IO.File]::ReadAllText($tokenPath).Trim()
        $parts = $token.Split('.')
        if ($parts.Length -ne 3) { throw 'Invalid token format' }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        $report.HardwareMatchesNativeExtension = ((Normalize-Identity ([string]$claims.f)) -ceq (Fingerprint $anchor))
        if ($report.MachineFilePresent) {
            $report.MachineMatchesSharedFile = ((Normalize-Identity ([string]$claims.m)) -ceq (Normalize-Identity ([IO.File]::ReadAllText($machinePath))))
        }
        $report.ClockStatePresent = Test-Path -LiteralPath (Join-Path $shared 'vshook_license_clock_v1.dat')
        $report.TokenReadable = $true
    }
} catch { $report.TokenReadable = $false }
$plugin = Join-Path $env:APPDATA 'REAPER\UserPlugins\reaper_VSHookExt.dll'
$report.ExtensionInNormalReaperFolder = Test-Path -LiteralPath $plugin
[pscustomobject]$report | Format-List
