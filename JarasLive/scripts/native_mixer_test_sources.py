"""Compile the real native mixer in small AppKit regression executables.

Only project/audio services are substituted. Geometry, rendering, input routing
and the controls under test are read directly from production sources.
"""
from pathlib import Path


def native_mixer_sources(*, control_marker=True, timeline_rows=True, scroll_stub=True):
    s=Path('Apple/Shared/TrackMixerRow.swift').read_text()
    theme=Path('Apple/Shared/Theme.swift').read_text()
    parts=['import AppKit\nimport SwiftUI\nimport Combine\nimport UniformTypeIdentifiers\n', Path('Application/Transport/TransportFadeout.swift').read_text().split('extension ShowController {')[0], ('// App-owned typography.' + Path('Apple/Shared/Theme.swift').read_text().split('// App-owned typography.')[1])]
    display = '; '.join(line.strip() for line in theme.splitlines() if line.strip().startswith((
        'static let displayHex:', 'static let lightDarkBackgroundHex:', 'static let workspaceToolbar =', 'static let transportControlGroup =')))
    project=Path('Application/Project/ProjectModels.swift').read_text()
    parts.append(project[project.index('public enum TrackHeightGeometry'):project.index('public struct TrackLinkOriginal')])
    parts.append(theme[theme.index('enum JarasInterfaceTheme:'):theme.index('enum JarasTheme {')])
    parts.append(theme[theme.index('extension Color {'):theme.index('#if os(macOS)\nenum DesktopToolbarTone')])
    parts.append(theme[theme.index('private struct ToolbarIconSurfaceKey:'):theme.index('struct StageButtonStyle:')])
    selection = Path('Apple/Shared/GridSelectionInput.swift').read_text()
    drawing = selection.index('    static func drawValueTooltip(')
    parts.append('private enum GridSelectionHeaderControls {\n' + selection[drawing:selection.index('    static func phase(', drawing)] + '}')
    tooltip = s.index('@MainActor private final class CompactTrackValueTooltip')
    parts.append(s[tooltip:s.index('\n#endif', tooltip)])
    appearance = selection.index('enum TrackMixerButtonAppearance {')
    parts.append(selection[appearance:selection.index('\n}', appearance) + 2])
    # Exercise the real row equality gate, including the height-mode inputs supplied
    # by TimelineGridView. Omitting them from the fixture concealed boundary rebuilds.
    a=s.index('        #if os(macOS)', s.index('    static func ==', s.index('struct TrackMixerRow:')))
    b=s.index('        let sameSelection', a)
    parts.append('private struct FixtureHeightMode { let compactHeight: Bool; let minimalHeight: Bool }\n'
                 'private func productionHeightModesEqual(_ lhs: FixtureHeightMode, _ rhs: FixtureHeightMode) -> Bool {\n'
                 +s[a:b]+'return sameHeightMode\n}')
    for begin,end in [('struct TrackMixerHeightGeometry','\n#endif'),('struct CompactTrackButtonStyle:','private struct TrackPanKnob:'),('private struct DirectVolumeSlider:','\n#endif'),('private struct TrackDragTitle:','\n#endif')]:
     a=s.index(begin);parts.append(s[a:s.index(end,a)])
    a=s.index('enum MixerPanFace {');parts.append(s[a:s.index('#if os(macOS)',a)])
    a=s.index('enum MixerFaderThumbStyle {');parts.append(s[a:s.index('private struct TrackVolumeFader:',a)])
    a=s.index('func mixerPanText(');parts.append(s[a:s.index('\n}',a)+2])
    if control_marker:
     a=s.index('struct TrackControlSelectionExclusion:');parts.append(s[a:s.index('@MainActor final class TrackSelectionRouter',a)])
    c=Path('Apple/Shared/ControlMappings.swift').read_text();a=c.index('final class MappingClickView:');parts.append(c[a:c.index('\n#endif',a)])
    parts.append(Path('Apple/Shared/RightClickRouting.swift').read_text())
    m=Path('Apple/Shared/StemAudioPlayback.swift').read_text()
    a=m.index('@MainActor final class TrackMeterLevel');parts.append(m[a:m.index('/// Item edges',a)])
    a=m.index('/// Uses the existing stereo readings');parts.append(m[a:m.index('private final class PreparedSoundFont',a)])
    v=Path('Apple/Shared/TimelineGridView.swift').read_text()
    if timeline_rows:
     a=v.index('private struct TimelineTrackRowsContainer');parts.append(v[a:v.index('private struct TimelineMixerIdentity',a)])
    edge=Path('Apple/Shared/GridScrollView.swift').read_text()
    a=edge.index('@MainActor final class NativeDragEdgeScroll')
    parts.append(edge[a:edge.index('\n#endif',a)])
    if scroll_stub:
     parts.append('private class GridNativeScrollView: NSScrollView { func prepareSelectionScroll(to: CGPoint, horizontal: Bool) {} }')
    parts.append('''
    private enum AutomationTarget { enum Kind { case pan, volume } }
    @MainActor private final class ShowController: ObservableObject { let transportFadeout = TransportFadeout(); let multiLoopFaders = MultiLoopFaderPresentation(); var projectSessionID = UUID(); @Published var snapshot = 0; func automationPlaybackValue(_ track: UUID?, kind: AutomationTarget.Kind) -> Double? { nil } }
    private enum JarasLocalization { static func string(_ value:String)->String { value } }
    private enum JarasTheme { ''' + display + '''; static let green = Color.green; static let yellow = Color.yellow; static let text = Color.white; static let trackButton = Color(hex: 0x484848) }
    private struct TrackControlIdentity: Equatable { let project: UUID; let track: UUID? }
    private final class TrackReorderState: ObservableObject { var source: TrackDragSource?; func begin(track: UUID) {} ; func finish() {} }
    private final class TrackSelectionRouter { static let shared=TrackSelectionRouter(); var pinnedTracks = Set<UUID>(); weak var editingTitle: TrackDragTitleView?; func addTitle(_ view: TrackDragTitleView) {}; func moveRename(from source: TrackDragTitleView, direction: Int) {}; func addControl(_ view:NSView) {}; func handle(_ event: NSEvent) {} ; func perform(track:UUID,event:NSEvent,action:()->Void) { action() } }
    private enum Counts { static var origin=0; static var size=0; static var slotLayouts=0; static var update=0; static func reset(){origin=0;size=0;slotLayouts=0;update=0} }
    ''')
    # Count only calls from the actual native implementations, without changing behavior.
    for i,p in enumerate(parts):
     for klass in ['DirectVolumeSliderView','TrackDragTitleView','NativeVerticalTrackMeterView']:
      token='final class '+klass+': NSView {'
      p=p.replace(token,token+'''
        override func setFrameOrigin(_ origin: NSPoint) { if frame.origin != origin { Counts.origin += 1 }; super.setFrameOrigin(origin) }
    ''')
      if klass == 'DirectVolumeSliderView':
       p=p.replace('let resized = newSize != frame.size', 'let resized = newSize != frame.size\n        if resized { Counts.size += 1 }')
      else:
       p=p.replace(token,token+'\n        override func setFrameSize(_ size: NSSize) { if frame.size != size { Counts.size += 1 }; super.setFrameSize(size) }')
     p=p.replace('if view.snapshot !== snapshot {', 'if view.snapshot !== snapshot { Counts.update += 1')
     a=p.find('private final class TrackMixerControlHost: NSHostingView<AnyView> {')
     if a >= 0:
      b=p.index('/// Warm row slots', a)
      p=p[:a]+p[a:b].replace('        super.layout()', '        Counts.slotLayouts += 1; super.layout()')+p[b:]
     parts[i]=p
    return parts
