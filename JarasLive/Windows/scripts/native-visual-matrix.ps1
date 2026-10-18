param(
    [Parameter(Mandatory=$true)][string]$Executable,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CatVisualDpi {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
}
'@
[void][CatVisualDpi]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms
. "$PSScriptRoot/native-ui-common.ps1"
$testArea = ([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.WorkingArea.Width * $_.WorkingArea.Height } -Descending | Select-Object -First 1).WorkingArea
$process = $null
$script:current = $null
$results = [System.Collections.Generic.List[object]]::new()

function Focus-TestWindow {
    $process.Refresh()
    [void][CatNativeUI]::SetForegroundWindow($process.MainWindowHandle)
    if([CatNativeUI]::GetForegroundWindow() -ne $process.MainWindowHandle) {
        throw 'Test window is not foreground; input cancelled.'
    }
}
function Snapshot([string]$Name) {
    Focus-TestWindow
    $script:current = Capture $Name
    return $script:current
}
function Click-Logical([double]$X, [double]$Y, [switch]$Right) {
    Focus-TestWindow
    $rect = Rect $process.MainWindowHandle
    # The JUCE document border is one logical unit on each side. Diagnostics
    # and component snapshots are logical; native mouse coordinates are pixels.
    $scale = ($rect.Right - $rect.Left) / ($script:current.logicalWidth + 2.0)
    Click ([int]($rect.Left + ($X + 1) * $scale)) ([int]($rect.Top + ($Y + 1) * $scale)) -Right:$Right
}
function Click-Control([string]$Name, [switch]$Modal) {
    $b = if($Modal){$script:current.modalControls.$Name}else{$script:current.controls.$Name}
    if(-not $b -or $b.width -le 0 -or $b.height -le 0){throw "Control has no bounds: $Name"}
    Click-Logical ($b.x + $b.width / 2) ($b.y + $b.height / 2)
}
function Check-Layout([string]$Name) {
    $d = Snapshot $Name
    if(-not $d.uiRegressionPassed){throw "Editing regression did not complete: $Name"}
    if($d.overlappingTransport -or $d.transportOutsideWindow){throw "Transport overlaps or leaves window: $Name"}
    if(@($d.clippedButtonLabels).Count -gt 0){throw "Transport label clipped: $Name / $($d.clippedButtonLabels -join ', ')"}
    if([Math]::Abs($d.fontPointHeight - (13*.9684564)) -gt .01){throw "Reference font metrics lost: $Name"}
    if(-not $d.grandMA2BeforeResolume){throw "Transport order changed: $Name"}
    $rect = Rect $process.MainWindowHandle
    $screen = [System.Windows.Forms.Screen]::FromHandle($process.MainWindowHandle).WorkingArea
    if($rect.Left -lt $screen.Left -or $rect.Top -lt $screen.Top -or $rect.Right -gt $screen.Right -or $rect.Bottom -gt $screen.Bottom){throw "Window exceeds the monitor work area: $Name"}
    $results.Add(@{name=$Name;width=$d.logicalWidth;height=$d.logicalHeight;transportHeight=$d.transportHeight;dpi=[CatVisualDpi]::GetDpiForWindow($process.MainWindowHandle)})
    return $d
}
function Stop-Fixture {
    if($script:process -and -not $script:process.HasExited) {
        [void]$script:process.CloseMainWindow()
        if(-not $script:process.WaitForExit(3000)){Stop-Process -Id $script:process.Id}
    }
    $script:process = $null
}
function Start-Fixture([string]$Scale='1') {
    $appearance = Join-Path $OutputDirectory 'appearance.json'
    $launchArguments = '--visual-test --ui-scale ' + $Scale + ' --appearance-file "' + $appearance + '"'
    $script:process = Start-Process -FilePath $Executable -ArgumentList $launchArguments -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {Start-Sleep -Milliseconds 200; $script:process.Refresh()} while($script:process.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
    if($script:process.MainWindowHandle -eq 0){throw 'CatLive did not open its test window.'}
    Start-Sleep -Milliseconds 1800
    Focus-TestWindow
}
try {
    Start-Fixture
    [void](Check-Layout 'main-native')
    foreach($size in @(@(1280,740),@(1100,700),@(960,540),@(900,500))) {
        [void][CatNativeUI]::SetWindowPos($process.MainWindowHandle,[IntPtr]::Zero,($testArea.Left+8),($testArea.Top+8),$size[0],$size[1],0x0040)
        Start-Sleep -Milliseconds 300
        [void](Check-Layout ("main-{0}x{1}" -f $size[0],$size[1]))
    }
    foreach($id in @('railMixer','railKeyboard')) {
        Click-Control $id
        [void](Snapshot ('dock-' + $id))
    }
    if(-not $script:current.dockScrollable){throw 'Lower panels did not scroll in a short window.'}
    ScreenCapture 'dock-short-window-screen'
    $rect = Rect $process.MainWindowHandle
    $scale = ($rect.Right - $rect.Left) / ($script:current.logicalWidth + 2.0)
    Wheel ([int]($rect.Right - 6 * $scale)) ([int]($rect.Bottom - ($script:current.footerHeight + $script:current.dockVisibleHeight / 2) * $scale)) -1200
    $d = Snapshot 'dock-scrolled'
    if($d.dockScrollY -le 0){throw 'Lower panel scrollbar did not move.'}
    ScreenCapture 'dock-scrolled-screen'
    foreach($id in @('railMixer','railKeyboard')) {
        Click-Control $id
        [void](Snapshot ('dock-close-' + $id))
    }
    [void][CatNativeUI]::SetWindowPos($process.MainWindowHandle,[IntPtr]::Zero,($testArea.Left+8),($testArea.Top+8),1280,740,0x0040)
    Start-Sleep -Milliseconds 250
    $partsBase = Snapshot 'panels-base'
    Click-Control 'railParts'
    $partsLeft = Snapshot 'parts-left-sidebar'
    if(-not $partsLeft.partsLeftVisible -or $partsLeft.partsRightVisible){throw 'The rail Parts button did not open only the left sidebar.'}
    if($partsLeft.mixerVisible -ne $partsBase.mixerVisible -or $partsLeft.keyboardVisible -ne $partsBase.keyboardVisible -or $partsLeft.dockVisibleHeight -ne $partsBase.dockVisibleHeight){throw 'Left Parts changed the lower docks.'}
    $button = $partsLeft.setlist.partsButton
    Click-Logical ($button.x + $button.width / 2) ($button.y + $button.height / 2)
    $partsBoth = Snapshot 'parts-both-sidebars'
    if(-not $partsBoth.partsLeftVisible -or -not $partsBoth.partsRightVisible){throw 'The two Parts sidebars did not remain open together.'}
    foreach($bounds in @($partsBoth.partsLeftBounds,$partsBoth.partsSidebarBounds)) {
        if($bounds.width -le 0 -or $bounds.height -le 0){throw 'A Parts sidebar has no visible area.'}
    }
    if($partsBoth.mixerVisible -ne $partsBase.mixerVisible -or $partsBoth.keyboardVisible -ne $partsBase.keyboardVisible -or $partsBoth.dockVisibleHeight -ne $partsBase.dockVisibleHeight){throw 'Right Parts changed the lower docks.'}
    $button = $partsBoth.setlist.partsButton
    Click-Logical ($button.x + $button.width / 2) ($button.y + $button.height / 2)
    $partsRightClosed = Snapshot 'parts-right-closed'
    if(-not $partsRightClosed.partsLeftVisible -or $partsRightClosed.partsRightVisible){throw 'Closing right Parts changed the left sidebar.'}
    Click-Control 'railParts'
    $partsClosed = Snapshot 'parts-sidebars-closed'
    if($partsClosed.partsLeftVisible -or $partsClosed.partsRightVisible){throw 'Left Parts did not close.'}
    Click-Control 'menu'
    $d = Snapshot 'navigation-open'
    if(-not $d.navigationVisible){throw 'Hamburger did not open the navigation drawer.'}
    Click-Logical 100 109
    $d = Snapshot 'navigation-live'
    if($d.navigationVisible -or @($d.modals).Count -ne 0){throw 'Live Session did not return to the editor.'}
    Click-Control 'menu'
    [void](Snapshot 'navigation-projects-before')
    Click-Logical 100 63
    $d = Snapshot 'navigation-projects'
    if($d.navigationVisible -or $d.modals -notcontains 'Projetos'){throw 'Navigation Projects did not open its sheet.'}
    Key 0x1b
    $d = Snapshot 'navigation-projects-closed'
    Click-Logical ($d.timeline.x + 200) ($d.timeline.y + 55)
    $before = Snapshot 'zoom-cursor-before'
    $anchor = $before.editPosition * $before.timeline.zoom - $before.timeline.horizontal
    $rect = Rect $process.MainWindowHandle
    $nativeScale = ($rect.Right - $rect.Left) / ($before.logicalWidth + 2.0)
    Wheel ([int]($rect.Left + ($before.timeline.x + 450) * $nativeScale)) ([int]($rect.Top + ($before.timeline.y + 100) * $nativeScale)) 120
    Start-Sleep -Milliseconds 700
    $after = Snapshot 'zoom-cursor-after'
    $newAnchor = $after.editPosition * $after.timeline.zoom - $after.timeline.horizontal
    if($after.timeline.zoom -le $before.timeline.zoom -or [Math]::Abs($newAnchor - $anchor) -gt 1){throw 'Mouse-wheel zoom did not stay on the edit cursor.'}

    foreach($panel in @(@{button='advanced';prefix='advancedTab';count=6},@{button='settings';prefix='settingsTab';count=7})) {
        Click-Control $panel.button
        [void](Snapshot ($panel.button + '-opened'))
        if(@($script:current.modals).Count -eq 0){throw "Panel did not open: $($panel.button)"}
        foreach($index in 0..($panel.count-1)) {
            $id = $panel.prefix + $index
            Click-Control $id -Modal
            $d = Snapshot ($panel.button + '-tab-' + $index)
            if(-not $d.modalControls.$id.selected){throw "Tab did not select: $id"}
        }
        Key 0x1b
        $d = Snapshot ($panel.button + '-closed')
        if(@($d.modals).Count -ne 0){throw 'Panel did not close.'}
    }
    Click-Logical 200 236 -Right
    ScreenCapture 'track-context'
    Key 0x1b
    Stop-Fixture
    foreach($scale in @('0.9','1.25','1.5','2')) {
        Start-Fixture $scale
        [void](Check-Layout ('scale-' + $scale))
        ScreenCapture ('scale-' + $scale + '-screen')
        $rect = Rect $process.MainWindowHandle
        $nativeScale = ($rect.Right - $rect.Left) / ($script:current.logicalWidth + 2.0)
        Click ([int]($rect.Right - 69 * $nativeScale)) ([int]($rect.Top + 17 * $nativeScale))
        if(-not [CatNativeUI]::IsZoomed($process.MainWindowHandle)){throw "Maximize failed at scale $scale"}
        [void](Check-Layout ('scale-' + $scale + '-maximized'))
        ScreenCapture ('scale-' + $scale + '-maximized-screen')
        $rect = Rect $process.MainWindowHandle
        Click ([int]($rect.Right - 69 * $nativeScale)) ([int]($rect.Top + 17 * $nativeScale))
        if([CatNativeUI]::IsZoomed($process.MainWindowHandle)){throw "Restore failed at scale $scale"}
        [void](Snapshot ('scale-' + $scale + '-restored'))

        foreach($panel in @('settings','advanced')) {
            Click-Control $panel
            [void](Snapshot ('scale-' + $scale + '-' + $panel))
            Key 0x1b
            [void](Snapshot ('scale-' + $scale + '-' + $panel + '-closed'))
        }
        Stop-Fixture
    }
    @{success=$true;scaleKind='JUCE application scale; monitor DPI recorded separately';layouts=@($results.ToArray())} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutputDirectory 'results.json') -Encoding utf8
} catch {
    $_ | Out-String | Set-Content (Join-Path $OutputDirectory 'failure.txt') -Encoding utf8
    throw
} finally {
    Stop-Fixture
}
