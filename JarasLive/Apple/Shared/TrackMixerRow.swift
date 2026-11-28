import SwiftUI
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

// Modifier handling belongs to mouse controls, not MIDI/remote commands.
@MainActor private extension ShowController {
    func sendTrackMixerButton(_ command: ShowCommand, target: UUID?) {
        #if os(macOS)
        let clear = target != nil && (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.command)
        #else
        let clear = false
        #endif
        sendMixerControl(command, target: target, clearAll: clear)
    }
}

private struct TrackFXButton: View {
    let show: ShowController
    let track: UUID?
    let settings: NativeFXSettings
    @Environment(\.openFX) private var openFX
    var body: some View {
        Button("FX") { openFX(track, "Chain") }
            .jarasHelp("Track effects")
            .foregroundStyle(TrackMixerButtonAppearance.fxText(hasEffects: !settings.inserted.isEmpty, bypassed: settings.allBypassed))
            #if os(macOS)
            .overlay {
                if !settings.inserted.isEmpty {
                    TrackFXContext(bypassed: settings.allBypassed,
                        bypass: { show.changeMixerFX(track) }, remove: { show.changeMixerFX(track, remove: true) })
                }
            }
            #endif
    }
}

#if os(macOS)
private struct TrackFXContext: NSViewRepresentable {
    let bypassed: Bool
    let bypass: () -> Void
    let remove: () -> Void
    func makeNSView(context: Context) -> TrackFXContextView { TrackFXContextView() }
    func updateNSView(_ view: TrackFXContextView, context: Context) {
        view.bypassed = bypassed; view.shiftClick = bypass; view.optionClick = remove
        view.action = { [weak view] in view?.openMenu() }
    }
}
private final class TrackFXContextView: RightClickTargetView {
    override var priority: Int { 2 }
    var bypassed = false
    func openMenu() {
        guard let event = NSApp.currentEvent else { return }
        let menu = NSMenu()
        let action = TrackMenuAction { [weak self] in self?.shiftClick?() }
        let item = NSMenuItem(title: "Bypass", action: #selector(TrackMenuAction.invoke), keyEquivalent: "")
        item.state = bypassed ? .on : .off; item.target = action; menu.addItem(item)
        withExtendedLifetime(action) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
#endif

private struct TrackEnvelopeButton: View {
    let show: ShowController
    let track: UUID
    let visible: Bool
    var body: some View {
        Button {
            show.toggleAutomationLanes(track)
        } label: {
            ControlIcon(name: "automationLanes", active: visible, size: 16)
        }.buttonStyle(CompactTrackButtonStyle(activeColor: visible ? JarasTheme.green : nil, width: 28))
            .accessibilityLabel("Envelopes").accessibilityAddTraits(visible ? .isSelected : [])
            .jarasHelp("Envelopes")
            .contextMenu {
                #if os(macOS)
                Button("Envelope settings") { AutomationWindows.open(show: show, track: track) }
                #endif
            }
    }
}

/// Sidebar rows align with the editable curves below the track's audio lanes.
struct TrackAutomationLaneHeaders: View {
    let show: ShowController
    let track: Track
    let height: CGFloat
    private func edit(_ id: UUID, _ action: (inout TrackEnvelope) -> Void) {
        var settings = show.automation(track.id)
        guard let index = settings.envelopes.firstIndex(where: { $0.id == id }) else { return }
        action(&settings.envelopes[index]); show.setAutomation(track.id, settings: settings)
    }
    var body: some View {
        VStack(spacing: 0) {
            ForEach(track.automation?.visibleEnvelopes ?? []) { envelope in
                HStack(spacing: 5) {
                    Text(verbatim: envelope.name).font(.jarasSystem(size: min(11, max(7, height - 4)), weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { edit(envelope.id) { $0.enabled.toggle() } } label: {
                        Image(systemName: "power").foregroundStyle(envelope.enabled ? JarasTheme.green : .red)
                            .frame(width: 16, height: min(18, height)).contentShape(Rectangle())
                    }.buttonStyle(.plain).jarasHelp("Automation enabled")
                    Button { edit(envelope.id) { $0.armed.toggle() } } label: {
                        Image(systemName: "record.circle").foregroundStyle(envelope.armed ? .red : .gray)
                            .frame(width: 16, height: min(18, height)).contentShape(Rectangle())
                    }.buttonStyle(.plain).jarasHelp("Arm")
                    #if os(macOS)
                    Button { AutomationWindows.open(show: show, track: track.id) } label: {
                        Image(systemName: "slider.horizontal.3").frame(width: 16, height: min(18, height)).contentShape(Rectangle())
                    }.buttonStyle(.plain).jarasHelp("Envelope settings")
                    #endif
                    Button { edit(envelope.id) { $0.visible = false } } label: {
                        Image(systemName: "xmark").frame(width: 16, height: min(18, height)).contentShape(Rectangle())
                    }.buttonStyle(.plain).jarasHelp("Hide envelope")
                }.font(.jarasSystem(size: min(11, max(7, height - 4))))
                    .padding(.horizontal, 8).frame(height: height).clipped()
                    .background(Color.black.opacity(0.22))
                    .overlay(alignment: .bottom) { Color.gray.opacity(0.3).frame(height: 1) }
            }
        }.foregroundStyle(.white)
    }
}

private func trackShowsMuteSolo(_ kind: TrackKind?) -> Bool {
    guard let kind else { return true } // Master
    return kind == .standard || kind == .timecode || kind == .click
}

private func trackShowsMeterReadouts(_ kind: TrackKind?) -> Bool {
    guard let kind else { return true } // Master
    return kind != .chords && kind != .timecode
}

#if os(macOS)
/// One stable set of controls moves between the thin strip and expanded mixer.
/// No native fader, title or meter is mounted/unmounted at height thresholds.
struct TrackMixerHeightGeometry {
    private static let minimumTitleRowHeight = CGFloat(TrackHeightGeometry.minimumLaneHeight)
    private static let folderControlsInset: CGFloat = 51
    static func fittedButtonsWidth(_ idealWidth: CGFloat, in width: CGFloat, folder: Bool) -> CGFloat {
        min(idealWidth, max(0, width - (folder ? folderControlsInset : 0) - 4))
    }
    static func volumeControls(_ volume: CGRect, hasPhase: Bool, minimumFaderStart: CGFloat = 8) -> (fader: CGRect, gain: CGRect, reclaimsPeakSpace: Bool) {
        let phaseWidth: CGFloat = hasPhase ? 23 : 0
        let gain = CGRect(x: volume.maxX - 4 - phaseWidth - 34, y: volume.minY, width: 34, height: volume.height)
        let right = gain.minX - 3
        let regularStart = volume.minX + 4
        let faderStart = max(minimumFaderStart, max(right - 186, min(regularStart, max(8, right - 136))))
        let fader = CGRect(x: faderStart, y: volume.minY, width: max(0, right - faderStart), height: volume.height)
        return (fader, gain, faderStart < regularStart)
    }
    static func peakFrame(below volume: CGRect) -> CGRect {
        CGRect(x: volume.maxX - 34, y: volume.maxY + 1, width: 34, height: 12)
    }
    static func controlTop(height: CGFloat, groupHeight: CGFloat) -> CGFloat {
        let titleTop = height - titleHeight(height) - 1
        return max(0, min((height - groupHeight) / 2, titleTop - groupHeight))
    }
    static func progress(_ height: CGFloat) -> CGFloat {
        // Track faders keep the same visibility threshold in either style.
        height >= 64 ? 1 : 0
    }
    static func titleHeight(_ height: CGFloat) -> CGFloat { 21 - 5 * progress(height) }
    static func frames(width: CGFloat, height: CGFloat, meterWidth: CGFloat, standard: Bool,
                       lowerTitle: Bool, controlsWidth: CGFloat, folder: Bool = false) -> [CGRect] {
        let p = progress(height)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        let audioWidth = mix(min(10, meterWidth), meterWidth)
        let bodyX = mix(audioWidth + 4, max(meterWidth, standard ? 18 : 0) + 4)
        let meterTop: CGFloat = mix(2, 4)
        let bodyWidth = max(0, width - bodyX - 4)
        let centeredY = max(0, (height - 21) / 2)
        // Name/number and folder stay anchored to the meter side of the row.
        // Only the right-hand controls follow the sidebar's changing width.
        let controlsX = max(folder ? folderControlsInset : 0, width - controlsWidth - 4)
        let titleX: CGFloat = 4
        let titleHeight = Self.titleHeight(height)
        let titleY = max(0, height - titleHeight - 1)
        let groupHeight: CGFloat = lowerTitle ? 44 : 53
        let controlsY = mix(height <= minimumTitleRowHeight ? titleY : centeredY, controlTop(height: height, groupHeight: groupHeight))
        let controlsHeight = mix(21, 24)
        let volumeTop = controlsY + controlsHeight
        let volumeHeight = min(20, max(0, titleY - volumeTop)) * p
        let controlsBottom = lowerTitle ? volumeTop : max(volumeTop, 56 * p)
        let clear = min(1, max(0, (titleY - controlsBottom) / 8))
        let thinWidth = max(0, width - controlsWidth - 8 - titleX)
        let titleWidth = thinWidth + (max(0, width - titleX - 4) - thinWidth) * clear
        return [
            CGRect(x: 0, y: meterTop, width: audioWidth, height: max(0, height - meterTop * 2)),
            .zero,
            CGRect(x: titleX, y: titleY, width: titleWidth, height: titleHeight),
            CGRect(x: controlsX, y: controlsY, width: controlsWidth, height: controlsHeight),
            CGRect(x: bodyX, y: volumeTop, width: bodyWidth, height: volumeHeight),
            CGRect(x: folder ? 20 : bodyX, y: folder ? controlsY + (controlsHeight - 20) / 2 : controlsY + 1, width: 28 * p, height: 20 * p),
            CGRect(x: controlsX, y: controlsY + 29, width: controlsWidth, height: 24 * p)
        ]
    }
}
private struct LegacyMixerHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 64 }
private struct LegacyControlsWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private extension EnvironmentValues {
    var legacyMixerHeight: CGFloat {
        get { self[LegacyMixerHeightKey.self] }
        set { self[LegacyMixerHeightKey.self] = newValue }
    }
}
private struct LegacyControlsWidth: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 13, *), !JarasDrawingCompatibility.forceLegacy { content }
        else {
            content.fixedSize(horizontal: true, vertical: false)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: LegacyControlsWidthKey.self, value: geometry.size.width)
                })
        }
    }
}
private struct TrackMixerContinuousContainer<Content: View>: View {
    let meterWidth: CGFloat
    let standard: Bool
    let lowerTitle: Bool
    var folder = false
    @ViewBuilder let content: () -> Content
    @State private var controlsWidth: CGFloat = 142
    var body: some View {
        if #available(macOS 13, *), !JarasDrawingCompatibility.forceLegacy {
            TrackMixerContinuousLayout(meterWidth: meterWidth, standard: standard, lowerTitle: lowerTitle, folder: folder) { content() }
        } else {
            // The row's native frame supplies its live height. Only the older
            // OS needs this reader; all seven controls remain mounted.
            GeometryReader { geometry in
                JarasFixedPlacement(size: geometry.size,
                    frames: TrackMixerHeightGeometry.frames(width: geometry.size.width, height: geometry.size.height,
                        meterWidth: meterWidth, standard: standard, lowerTitle: lowerTitle, controlsWidth: controlsWidth, folder: folder), content: content)
                    // Only the expanded/compact mode affects the buttons;
                    // keep continuous height local to the seven slot frames.
                    .environment(\.legacyMixerHeight, geometry.size.height >= 64 ? 64 : 24)
                    .onPreferenceChange(LegacyControlsWidthKey.self) { width in
                        if width > 0, abs(controlsWidth - width) > 0.01 { controlsWidth = width }
                    }
            }
        }
    }
}
private struct TrackMixerButtonsContainer<Content: View>: View {
    let standard: Bool
    let showsFader: Bool
    var customComponents = false
    @ViewBuilder let content: () -> Content
    @Environment(\.legacyMixerHeight) private var height
    var body: some View {
        if customComponents {
            HStack(spacing: 3, content: content).environment(\.jarasPlacementFrames, [])
        } else if #available(macOS 13, *), !JarasDrawingCompatibility.forceLegacy {
            let layout = standard ? AnyLayout(TrackMixerButtonsLayout(showsFader: showsFader, expanded: height >= 64)) : AnyLayout(HStackLayout(spacing: 3))
            layout { content() }
        } else if standard {
            let expanded = height >= 64
            let controlHeight: CGFloat = expanded ? 24 : 21
            let widths: [CGFloat] = [expanded ? 34 : 0, expanded ? 28 : 0, 22, 47, 22, 22, 22, expanded ? 0 : 22]
            let visibleCount = widths.filter { $0 > 0 }.count
            let width = widths.reduce(0, +) + CGFloat(max(0, visibleCount - 1)) * 3
            let order = [0,1,7,2,3,4,5,6]
            let frames: [CGRect] = {
                var frames = Array(repeating: CGRect.zero, count: 8), x: CGFloat = 0
                for index in order where widths[index] > 0 {
                    frames[index] = CGRect(x: x, y: 0, width: widths[index], height: controlHeight)
                    x += widths[index] + 3
                }
                return frames
            }()
            JarasFixedPlacement(size: CGSize(width: width, height: controlHeight), frames: frames, content: content)
        } else {
            HStack(spacing: 3, content: content).environment(\.jarasPlacementFrames, [])
        }
    }
}
@available(macOS 13, *)
struct TrackMixerContinuousLayout: Layout {
    var height: CGFloat? = nil
    let meterWidth: CGFloat
    let standard: Bool
    let lowerTitle: Bool
    var folder = false
    // These containers use explicit frames, not their children's alignment guides.
    // The default Layout implementation walks every control to merge guides.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 248, height: height ?? proposal.height ?? 64)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 7 else { return }
        let height = self.height ?? bounds.height
        let controlsWidth = subviews[3].sizeThatFits(ProposedViewSize(width: nil, height: height >= 64 ? 24 : 21)).width
        let frames = TrackMixerHeightGeometry.frames(width: bounds.width, height: height, meterWidth: meterWidth,
            standard: standard, lowerTitle: lowerTitle, controlsWidth: controlsWidth, folder: folder)
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: frame.width <= 0 || frame.height <= 0 ? bounds.maxX + 1024 : bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(frame.size))
        }
    }
}
/// Patch and Env stay mounted but occupy no space in a collapsed strip.
/// FX remains immediately before REC at every track height.
@available(macOS 13, *)
struct TrackMixerButtonsLayout: Layout {
    let showsFader: Bool
    var expanded = true
    private static let controlWidths: [CGFloat] = [34,28,22,47,22,22,22,22]
    private var order: [Int] { [0,1,7,2,3,4,5,6] }
    private func visible(_ i: Int) -> Bool {
        if i == 7 { return !expanded }
        return expanded || i >= 2
    }
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    private func slot(_ index: Int, _ subviews: Subviews) -> Int {
        let value = subviews[index][JarasLayoutSlot.self]
        return value >= 0 ? value : index
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let slots = subviews.indices.map { slot($0, subviews) }.filter { Self.controlWidths.indices.contains($0) && visible($0) }
        return CGSize(width: slots.reduce(CGFloat(0)) { $0 + Self.controlWidths[$1] } + CGFloat(max(0, slots.count - 1))*3, height: expanded ? 24 : 21)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for target in order {
            guard let i = subviews.indices.first(where: { slot($0, subviews) == target }) else { continue }
            let hidden = !visible(target), width = Self.controlWidths[target]
            subviews[i].place(at: CGPoint(x: hidden ? bounds.maxX + 1024 : x, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: width, height: expanded ? 24 : 21))
            if !hidden { x += width + 3 }
        }
    }
}

/// Content and environment change independently from the row's live geometry.
/// A height update repositions three native groups without reassigning their roots.
private final class TrackMixerNativeContent {
    var panel: TrackMixerNativePanelContent?
    let controls: AnyView
    init(controls: AnyView) { self.controls = controls }
}
/// Forward the values these controls actually use across the native hosting
/// boundary. Copying EnvironmentValues also copies SwiftUI's layout/placement
/// inputs, which change when a window resizes even if this row does not.
private struct TrackMixerHostedContent<Content: View>: View {
    let content: Content
    let locale: Locale
    let colorScheme: ColorScheme
    let isEnabled: Bool
    let layoutDirection: LayoutDirection
    let displayScale: CGFloat
    let font: Font?
    let controlSize: ControlSize
    let dynamicTypeSize: DynamicTypeSize
    var body: some View {
        content.environment(\.locale, locale).environment(\.colorScheme, colorScheme)
            .workspaceControlsAppearActive()
            .environment(\.isEnabled, isEnabled)
            .environment(\.layoutDirection, layoutDirection).environment(\.displayScale, displayScale)
            .environment(\.font, font).environment(\.controlSize, controlSize)
            .environment(\.dynamicTypeSize, dynamicTypeSize).foregroundStyle(JarasTheme.text)
    }
}
private struct TrackMixerButtonContentKey: Equatable {
    let controller: ObjectIdentifier
    let project: UUID
    let session: UUID
    let track: Track
    let componentMask: Int
    let theme: JarasInterfaceTheme
}
private struct TrackMixerButtonEnvironment: Equatable {
    let locale: Locale
    let colorScheme: ColorScheme
    let isEnabled: Bool
    let layoutDirection: LayoutDirection
    let displayScale: CGFloat
    let font: Font?
    let controlSize: ControlSize
    let dynamicTypeSize: DynamicTypeSize
}
private struct NativeTrackMixerControls<Controls: View>: View {
    let track: UUID
    let meterWidth: CGFloat
    let standard: Bool
    let meter: TrackMeterLevel
    let hasFaderRail: Bool
    let hasAudioMeter: Bool
    var showScale = true
    var foreground: Color = .white
    var peakOnly = true
    @ViewBuilder var controls: () -> Controls
    var nativePanel: TrackMixerNativePanelContent? = nil
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale
    @Environment(\.font) private var font
    @Environment(\.controlSize) private var controlSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private func hosted<Content: View>(_ content: Content) -> AnyView {
        AnyView(TrackMixerHostedContent(content: content, locale: locale,
            colorScheme: colorScheme, isEnabled: isEnabled,
            layoutDirection: layoutDirection, displayScale: displayScale, font: font,
            controlSize: controlSize, dynamicTypeSize: dynamicTypeSize))
    }
    var body: some View {
        // Geometry changes only propose native frames; model/environment
        // changes create fresh content for the same retained hosts.
        // Row actions are supplied by the current content closures, including
        // the grid's stable FX/text relays. Only geometry reuses this snapshot;
        // model/action or supported environment changes replace its content.
        let snapshot = TrackMixerNativeContent(controls: nativePanel == nil ? hosted(controls()) : AnyView(Color.clear))
        let environment = TrackMixerButtonEnvironment(locale: locale, colorScheme: colorScheme,
            isEnabled: isEnabled, layoutDirection: layoutDirection, displayScale: displayScale,
            font: font, controlSize: controlSize, dynamicTypeSize: dynamicTypeSize)
        snapshot.panel = nativePanel?.hosted(environment: environment) { hosted($0) }
        let bridge = NativeTrackMixerControlsBridge(track: track, meterWidth: meterWidth, standard: standard, snapshot: snapshot, isEnabled: isEnabled, meterState: meter, hasFaderRail: hasFaderRail, hasAudioMeter: hasAudioMeter, showScale: showScale, foreground: NSColor(foreground), peakOnly: peakOnly)
        return Group {
            if #available(macOS 13, *), !JarasDrawingCompatibility.forceLegacy {
                bridge.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Monterey has no representable sizeThatFits. Give AppKit the
                // explicit row frame while retaining this content snapshot.
                GeometryReader { geometry in bridge.frame(width: geometry.size.width, height: geometry.size.height) }
            }
        }
    }
}
private struct NativeTrackMixerControlsBridge: NSViewRepresentable {
    let track: UUID
    let meterWidth: CGFloat
    let standard: Bool
    let snapshot: TrackMixerNativeContent
    let isEnabled: Bool
    let meterState: TrackMeterLevel
    let hasFaderRail: Bool
    let hasAudioMeter: Bool
    let showScale: Bool
    let foreground: NSColor
    let peakOnly: Bool
    func makeNSView(context: Context) -> TrackMixerNativeControlView {
        let view = TrackMixerNativeControlView(); updateNSView(view, context: context); return view
    }
    func updateNSView(_ view: TrackMixerNativeControlView, context: Context) {
        view.track = track
        view.meterWidth = meterWidth; view.standard = standard
        view.hasFaderRail = hasFaderRail; view.hasAudioMeter = hasAudioMeter
        view.meter.bind(meterState, showScale: showScale, foreground: foreground, peakOnly: peakOnly)
        if view.snapshot !== snapshot {
            view.snapshot = snapshot
            view.controls.update(snapshot, meterWidth: meterWidth, enabled: isEnabled)
        }
        view.place()
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TrackMixerNativeControlView, context: Context) -> CGSize? {
        // Adopt this layout pass directly. A GeometryReader plus the previous
        // native fittingSize feeds the old height back into the next row and
        // leaves its controls centered/clipped inside the new frame.
        let size = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 248, height: 64))
        nsView.logicalSize = size
        return size
    }
}
/// The title and volume are already AppKit controls. Mount them directly so
/// changing the sidebar width does not lay out a SwiftUI graph around them.
/// Buttons, menus and group dialogs retain their existing SwiftUI content.
private struct TrackMixerNativePanelContent {
    let title: TrackDragTitle
    let slider: DirectVolumeSlider
    let buttons: AnyView
    let compactButtons: AnyView
    let compactButtonsWidth: CGFloat
    let allowsCompactHeight: Bool
    var fullHeightCompactButtons = false
    let phase: TrackMixerNativePhase?
    let showsVolume: Bool
    let expandedButtonsWidth: CGFloat
    var mapVolume: (() -> Void)? = nil
    var customComponents = false
    var compactComponents = false
    var fitsButtonsToAvailableWidth = false
    var buttonContentKey: TrackMixerButtonContentKey? = nil
    var buttonEnvironment: TrackMixerButtonEnvironment? = nil
    func hosted(environment: TrackMixerButtonEnvironment, _ wrap: (AnyView) -> AnyView) -> Self {
        Self(title: title, slider: slider, buttons: wrap(buttons), compactButtons: wrap(compactButtons),
             compactButtonsWidth: compactButtonsWidth, allowsCompactHeight: allowsCompactHeight,
             fullHeightCompactButtons: fullHeightCompactButtons,
             phase: phase, showsVolume: showsVolume,
             expandedButtonsWidth: expandedButtonsWidth, mapVolume: mapVolume, customComponents: customComponents,
             compactComponents: compactComponents, fitsButtonsToAvailableWidth: fitsButtonsToAvailableWidth,
             buttonContentKey: buttonContentKey, buttonEnvironment: environment)
    }
}
private struct TrackMixerNativePhase {
    let inverted: Bool
    let action: () -> Void
}
/// Fixed-size phase control; resizing the row only changes its native origin.
private final class TrackMixerNativePhaseButton: NSButton {
    private var invoke: (() -> Void)?
    private static func glyph(inverted: Bool) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            (inverted ? NSColor(JarasTheme.yellow) : NSColor.white.withAlphaComponent(0.08)).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 16, height: 16), xRadius: 3, yRadius: 3).fill()
            let rect = NSRect(x: 4, y: 4, width: 12, height: 12)
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.18))
            path.move(to: NSPoint(x: rect.minX + rect.width * 0.07, y: rect.maxY - rect.height * 0.07))
            path.line(to: NSPoint(x: rect.maxX - rect.width * 0.07, y: rect.minY + rect.height * 0.07))
            path.lineWidth = 1.1; path.lineCapStyle = .round
            (inverted ? NSColor.black : NSColor.white).setStroke(); path.stroke()
            return true
        }
    }
    private static let normalImage = glyph(inverted: false), invertedImage = glyph(inverted: true)
    override init(frame: NSRect) {
        super.init(frame: frame); title = ""; isBordered = false
        setButtonType(.momentaryPushIn); imagePosition = .imageOnly; imageScaling = .scaleNone
        target = self; action = #selector(pressed); focusRingType = .none
        setAccessibilityLabel("Invert polarity")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ content: TrackMixerNativePhase?, enabled: Bool) {
        invoke = content?.action; isEnabled = enabled && content != nil
        let inverted = content?.inverted == true
        image = inverted ? Self.invertedImage : Self.normalImage
        setAccessibilityValue(inverted ? "On" : "Off")
        toolTip = JarasLocalization.string(inverted ? "Phase inverted — restore phase" : "Invert polarity")
    }
    @objc private func pressed() { guard isEnabled else { return }; invoke?() }
}

private final class TrackMixerControlPlane: NSView {
    private var fallback: TrackMixerControlHost?
    private var panel: TrackMixerNativePanelView?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    override init(frame: NSRect) { super.init(frame: frame); autoresizesSubviews = false }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ content: TrackMixerNativeContent, meterWidth: CGFloat, enabled: Bool) {
        if let native = content.panel {
            fallback?.removeFromSuperview(); fallback = nil
            if panel == nil { let view = TrackMixerNativePanelView(); panel = view; addSubview(view) }
            panel?.update(native, meterWidth: meterWidth, enabled: enabled)
        } else {
            panel?.removeFromSuperview(); panel = nil
            if fallback == nil {
                let host = TrackMixerControlHost(rootView: content.controls)
                if #available(macOS 13, *) { host.sizingOptions = [] }
                if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
                fallback = host; addSubview(host)
            } else { fallback?.updateContent(content.controls) }
        }
        needsLayout = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local), visibleRect.contains(local) else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    override func layout() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        super.layout()
        if let view = (panel as NSView?) ?? fallback, view.frame != bounds { view.frame = bounds }
    }
}
private final class TrackMixerNativePanelView: NSView {
    private final class Box: NSView { override var isFlipped: Bool { true } }
    private let title = TrackDragTitleView()
    private let slider = DirectVolumeSliderView()
    private let readout = TrackMixerNativeGainLabel()
    private let expandedButtons = TrackMixerControlHost(rootView: AnyView(Color.clear))
    private let compactButtons = TrackMixerControlHost(rootView: AnyView(Color.clear))
    private let phase = TrackMixerNativePhaseButton()
    private let phaseArea = TrackControlSelectionExclusionView()
    private let buttonBox = Box(), volumeBox = Box()
    private let sliderArea = TrackControlSelectionExclusionView()
    private let labelArea = TrackControlSelectionExclusionView()
    private let titleArea = TrackControlSelectionExclusionView()
    private let mapping = MappingClickView()
    private var configuration: TrackMixerNativePanelContent?
    private var meterWidth: CGFloat = 52
    private var enabled = true
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    override init(frame: NSRect) {
        super.init(frame: frame); autoresizesSubviews = false
        buttonBox.autoresizesSubviews = false; buttonBox.wantsLayer = true; buttonBox.layer?.masksToBounds = true
        for host in [expandedButtons, compactButtons] {
            if #available(macOS 13, *) { host.sizingOptions = [] }
            if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
            buttonBox.addSubview(host)
        }
        compactButtons.isHidden = true
        addSubview(buttonBox)
        volumeBox.autoresizesSubviews = false; volumeBox.wantsLayer = true; volumeBox.layer?.masksToBounds = true
        volumeBox.addSubview(slider)
        for view in [title, titleArea, sliderArea, labelArea, mapping, volumeBox, readout, phaseArea, phase] as [NSView] { addSubview(view) }
        titleArea.selectsTrack = true
        labelArea.selectsTrack = true
        mapping.hitHeight = 16
        slider.valueDidChange = { [weak readout, weak slider] value in
            readout?.value = value
            slider?.setAccessibilityValue(value <= -60 ? "−∞ dB" : String(format: "%.1f dB", value))
        }
        readout.reset = { [weak slider] in guard let slider, slider.isEnabled else { return }; slider.resetToUnity() }
        slider.setAccessibilityElement(true); slider.setAccessibilityRole(.slider)
        slider.setAccessibilityLabel("Track volume")
        slider.toolTip = JarasLocalization.string("Double-click to reset to 0 dB")
        readout.toolTip = slider.toolTip
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ content: TrackMixerNativePanelContent, meterWidth: CGFloat, enabled: Bool) {
        let buttonsChanged = content.buttonContentKey == nil || configuration?.buttonContentKey != content.buttonContentKey ||
            configuration?.buttonEnvironment != content.buttonEnvironment
        configuration = content; self.meterWidth = meterWidth; self.enabled = enabled
        content.title.configure(title)
        title.interactionEnabled = enabled; slider.isEnabled = enabled
        content.slider.configure(slider)
        readout.value = slider.doubleValue
        mapping.action = enabled ? content.mapVolume : nil
        if buttonsChanged {
            expandedButtons.updateContent(AnyView(content.buttons.environment(\.legacyMixerHeight, 64)))
            let compact = content.allowsCompactHeight ? content.compactButtons : content.buttons
            compactButtons.updateContent(AnyView(compact.environment(\.legacyMixerHeight, content.allowsCompactHeight ? 64 : 24)))
        }
        phase.configure(content.phase, enabled: enabled)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let configuration else { return }
        let expanded = bounds.height >= 64
        let heightCompact = !expanded && configuration.allowsCompactHeight
        let compactSide = min(22, max(1, bounds.height - (configuration.fullHeightCompactButtons ? 0 : 4)))
        let buttonsWidth = heightCompact ? configuration.compactButtonsWidth :
            (expanded || configuration.customComponents) ? configuration.expandedButtonsWidth : (configuration.phase == nil ? 122 : 147)
        let fittedWidth = TrackMixerHeightGeometry.fittedButtonsWidth(buttonsWidth, in: bounds.width, folder: false)
        var frames = TrackMixerHeightGeometry.frames(width: bounds.width, height: bounds.height,
            meterWidth: meterWidth, standard: true, lowerTitle: true,
            controlsWidth: fittedWidth)
        let disabled = CATransaction.disableActions(); CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        func place(_ view: NSView, _ rect: CGRect, visible: Bool = true) {
            let hidden = !visible || rect.width <= 0 || rect.height <= 0
            if view.isHidden != hidden { view.isHidden = hidden }
            if !hidden, view.frame != rect { view.frame = rect }
        }
        if heightCompact {
            let end = bounds.width - (configuration.showsVolume ? 24 : 4)
            let width = min(buttonsWidth * (compactSide / 22), max(0, end - 55))
            let top = max(0, (bounds.height - compactSide) / 2)
            frames[3] = CGRect(x: end - width, y: top, width: width, height: compactSide)
            let titleStart: CGFloat = 28
            frames[2] = CGRect(x: titleStart, y: top, width: max(0, end - width - titleStart - 4), height: compactSide)
            frames[4] = .zero
        } else if configuration.compactComponents {
            let start = max(48, bounds.width - 227 - fittedWidth)
            let top = TrackMixerHeightGeometry.controlTop(height: bounds.height, groupHeight: 22)
            frames[3] = CGRect(x: start, y: top, width: fittedWidth, height: 22)
            let volumeStart = frames[3].maxX + 4
            frames[4] = CGRect(x: volumeStart, y: top + 1, width: max(0, bounds.width-volumeStart-3), height: 20)
            frames[2] = CGRect(x: 4, y: max(25, bounds.height-17), width: max(0,bounds.width-42), height: 16)
        }
        let volume = frames[4]
        let (fader, label, _) = TrackMixerHeightGeometry.volumeControls(volume, hasPhase: configuration.phase != nil,
            minimumFaderStart: configuration.compactComponents ? volume.minX : 49)
        let visible = configuration.showsVolume && volume.height > 0
        var titleFrame = frames[2]
        let peakFrame = TrackMixerHeightGeometry.peakFrame(below: volume)
        if visible && meterWidth > 21 && titleFrame.intersects(peakFrame) {
            titleFrame.size.width = max(0, peakFrame.minX - titleFrame.minX - 3)
        }
        place(title, titleFrame)
        place(titleArea, titleFrame)
        place(buttonBox, frames[3])
        if !buttonBox.isHidden {
            let scale = heightCompact ? compactSide / 22 : 1
            let hostedWidth = configuration.fitsButtonsToAvailableWidth ? frames[3].width / scale : buttonsWidth
            let naturalBounds = CGRect(x: 0, y: 0, width: hostedWidth, height: frames[3].height / scale)
            // Keep the same controls mounted while the sidebar width changes.
            if buttonBox.bounds != naturalBounds { buttonBox.bounds = naturalBounds }
            // Crossing the compact height switches between retained controls
            // instead of reconstructing the row and its hosting root.
            let active = expanded ? expandedButtons : compactButtons
            let inactive = expanded ? compactButtons : expandedButtons
            if !inactive.isHidden { inactive.isHidden = true }
            if active.frame != naturalBounds { active.frame = naturalBounds }
            if active.isHidden { active.isHidden = false }
        }
        place(readout, label, visible: visible); place(labelArea, label, visible: visible)
        place(volumeBox, fader, visible: visible)
        place(slider, CGRect(origin: .zero, size: fader.size), visible: visible)
        place(sliderArea, fader, visible: visible)
        place(mapping, fader, visible: visible && enabled && configuration.mapVolume != nil)
        let phaseRect = CGRect(x: volume.maxX - 24, y: volume.minY, width: 20, height: volume.height)
        place(phase, phaseRect, visible: visible && configuration.phase != nil)
        place(phaseArea, phaseRect, visible: visible && configuration.phase != nil)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard enabled else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

}
private final class TrackMixerNativeGainLabel: NSView {
    private let screenDrawing = NativeScreenDrawing()
    var reset: (() -> Void)?
    var value: Double = 0 {
        didSet {
            guard value != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(value <= -60 ? "−∞ dB" : String(format: "%.1f dB", value))
        }
    }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel("Track volume")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let string = value <= -60 ? "−∞" : String(format: "%+.1f", value)
        let text = NSAttributedString(string: string, attributes: [.font: NSFont.jarasMonospacedSystemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.white])
        screenDrawing.draw(in: self) {
            text.draw(at: NSPoint(x: max(0, (bounds.width - text.size().width) / 2), y: max(0, (bounds.height - text.size().height) / 2)))
        }
    }
    override func mouseDown(with event: NSEvent) { if event.clickCount >= 2 { reset?() } }
}

private final class TrackMixerControlHost: NSHostingView<AnyView> {
    private var contentRevision: UInt64 = 0
    private var laidOutRevision: UInt64?
    private var laidOutBounds: CGRect?
    func updateContent(_ content: AnyView) {
        contentRevision &+= 1
        rootView = AnyView(content.workspaceControlsAppearActive())
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); laidOutBounds = nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local), visibleRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
    override func layout() {
        // Keep retained controls out of Ventura's layout passes while their
        // row is hidden. The same controls are laid out when it returns.
        guard !isHiddenOrHasHiddenAncestor else { return }
        NativeSidebarResizeActivity.shared.recordLayout("control", view: self,
            sameBounds: laidOutBounds == bounds, sameContent: laidOutRevision == contentRevision)
        if laidOutBounds == bounds, laidOutRevision == contentRevision,
           NativeSidebarResizeActivity.shared.deferUnchangedLayout(self, duringScroll: true) { return }
        let revision = contentRevision, geometry = bounds
        super.layout()
        laidOutRevision = revision; laidOutBounds = geometry
    }
    override func viewDidUnhide() {
        super.viewDidUnhide(); laidOutBounds = nil
        needsLayout = true
    }
}
/// Warm row slots retain their controls, but only nearby rows attach those
/// controls to AppKit's window-wide tracking/layout/accessibility walks.
/// One observer per vertical clip keeps visibility independent of SwiftUI and
/// of the horizontal timeline's continuously moving bounds.
@MainActor private final class TrackMixerClipVisibility {
    private static let observers = NSMapTable<NSClipView, TrackMixerClipVisibility>.weakToStrongObjects()
    private let views = NSHashTable<TrackMixerNativeControlView>.weakObjects()
    private var tokens: [NSObjectProtocol] = []
    private var accessibilityObservations: [NSKeyValueObservation] = []
    private var idleDetachment: DispatchWorkItem?
    private var preparedBounds: CGRect?
    private var preparedHeight: CGFloat = 0
    private(set) var defersHostDetachment = false
    private(set) var retainsAccessibilityControls = false
    static func forClip(_ clip: NSClipView) -> TrackMixerClipVisibility {
        if let value = observers.object(forKey: clip) { return value }
        let value = TrackMixerClipVisibility(clip)
        observers.setObject(value, forKey: clip)
        return value
    }
    private init(_ clip: NSClipView) {
        updateAccessibility()
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self, weak clip] _ in
                MainActor.assumeIsolated {
                    guard let self, let clip else { return }
                    let bounds = self.controlBounds(in: clip)
                    if name == NSView.boundsDidChangeNotification, self.preparedBounds?.origin != bounds.origin {
                        self.deferDetachmentUntilScrollSettles()
                    }
                    // AppKit can report the same viewport through both notifications.
                    if self.preparedBounds == bounds { return }
                    self.preparedBounds = bounds
                    self.refresh()
                }
            })
        }
        if let document = clip.documentView {
            document.postsFrameChangedNotifications = true
            tokens.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Command-wheel changes the document height while rows
                    // cross the warm viewport. Keep their hidden controls
                    // attached until that gesture rests, just like scrolling.
                    self?.deferDetachmentUntilScrollSettles()
                    self?.refresh()
                }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasRetaining = self.retainsAccessibilityControls
                self.updateAccessibility()
                if wasRetaining != self.retainsAccessibilityControls { self.refresh() }
            }
        })
        accessibilityObservations = [\NSWorkspace.isVoiceOverEnabled, \NSWorkspace.isSwitchControlEnabled].map { key in
            NSWorkspace.shared.observe(key, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateAccessibility(); self?.refresh() }
            }
        }
    }
    func add(_ view: TrackMixerNativeControlView) { views.add(view) }
    func remove(_ view: TrackMixerNativeControlView) { views.remove(view) }
    func controlBounds(in clip: NSClipView) -> CGRect {
        var bounds = clip.bounds
        // A docked preview crops the same rows. Keep at most one window of
        // controls ready so closing the preview does not remount them.
        let limit = clip.window?.contentView?.bounds.height ?? bounds.height
        preparedHeight = max(bounds.height, min(limit, preparedHeight))
        if !clip.isFlipped { bounds.origin.y -= preparedHeight - bounds.height }
        bounds.size.height = preparedHeight
        return bounds
    }
    private func deferDetachmentUntilScrollSettles() {
        // Detaching a retained NSHostingView invalidates its SwiftUI window
        // environment. During fast wheel reversals that used to rebuild the
        // same three roots on every reserve-boundary crossing. Hide immediately
        // and detach once the gesture rests; the bounded row pool remains warm.
        defersHostDetachment = true
        idleDetachment?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.idleDetachment = nil
            self.defersHostDetachment = false
            self.updateAccessibility()
            self.refresh()
        }
        idleDetachment = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }
    private func updateAccessibility() {
        retainsAccessibilityControls = NSApp.isFullKeyboardAccessEnabled ||
            NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    }
    private func refresh() {
        // Accessibility is refreshed by its notifications and once at rest,
        // rather than querying system preferences for every scroll pixel.
        for view in views.allObjects { view.refreshViewportVisibility() }
    }
    deinit { idleDetachment?.cancel(); tokens.forEach(NotificationCenter.default.removeObserver) }
}
private final class TrackMixerNativeControlView: NSView, NativeTimelineControlInput {
    let meter = NativeVerticalTrackMeterView()
    var hasFaderRail = true
    var hasAudioMeter = true
    let controls = TrackMixerControlPlane()
    var meterWidth: CGFloat = 40
    var standard = true
    var logicalSize: CGSize? {
        didSet { if oldValue != logicalSize { needsLayout = true } }
    }
    var snapshot: TrackMixerNativeContent?
    var track: UUID?
    private weak var visibilityClip: NSClipView?
    private weak var visibilityObserver: TrackMixerClipVisibility?
    private var frameObserverAncestors: [ObjectIdentifier] = []
    private var frameObservers: [NSObjectProtocol] = []
    private let controlAreas = NSHashTable<NSView>.weakObjects()
    private var updatingHostAttachment = false
    private var hostsAttached = true
    private var registeredInputActive: Bool?
    private lazy var inputRegistration = NativeTimelineControlInputRegistration(self)
    fileprivate func addControlArea(_ view: NSView) { controlAreas.add(view) }
    fileprivate func removeControlArea(_ view: NSView) { controlAreas.remove(view) }
    func hitTestTimelineControl(atWindowPoint point: NSPoint) -> NSView? {
        let local = convert(point, from: nil)
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local), visibleRect.contains(local) else { return nil }
        if let peak = hitTestMeterPeak(local) { return peak }
        guard controlAreas.allObjects.contains(where: { area in
                  let location = area.convert(point, from: nil)
                  return area.window === window && !area.isHiddenOrHasHiddenAncestor &&
                      area.isDescendant(of: controls) && area.bounds.contains(location) && area.visibleRect.contains(location)
              }) else { return nil }
        return controls.hitTest(local)
    }
    private func hitTestMeterPeak(_ point: NSPoint) -> NSView? {
        guard !meter.isHidden, meter.frame.contains(point) else { return nil }
        return meter.hitTest(point)
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.masksToBounds = true; autoresizesSubviews = false
        for host: NSView in [meter, controls] {
            host.wantsLayer = true; host.layer?.masksToBounds = true
            if #available(macOS 13, *), let host = host as? TrackMixerControlHost { host.sizingOptions = [] }
            if #available(macOS 13.3, *), let host = host as? TrackMixerControlHost { host.safeAreaRegions = [] }
            addSubview(host)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeViewport()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeViewport()
    }
    private func observeViewport() {
        registeredInputActive = nil // Reparenting can change the input host.
        let next = window == nil ? nil : enclosingScrollView?.contentView
        if visibilityClip !== next {
            visibilityObserver?.remove(self)
            visibilityClip = next
            visibilityObserver = next.map { TrackMixerClipVisibility.forClip($0) }
            visibilityObserver?.add(self)
        }
        // SwiftUI positions a row by moving its native wrappers, without
        // resizing this view or the document. Observe only those row wrappers;
        // the shared clip observer already owns viewport/document geometry.
        var ancestors: [NSView] = []
        var ancestor = window == nil ? nil : superview
        while let view = ancestor, view !== next, view !== next?.documentView,
              view.identifier?.rawValue != "columns-mixer" {
            ancestors.append(view)
            ancestor = view.superview
        }
        let identities = ancestors.map(ObjectIdentifier.init)
        if identities != frameObserverAncestors {
            frameObservers.forEach(NotificationCenter.default.removeObserver)
            frameObserverAncestors = identities
            frameObservers = ancestors.map { view in
                view.postsFrameChangedNotifications = true
                return NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshViewportVisibility() }
                }
            }
        }
        refreshViewportVisibility()
    }
    fileprivate func refreshViewportVisibility() {
        defer {
            let active = !isHidden && window != nil
            if registeredInputActive != active {
                inputRegistration.update(active: active)
                registeredInputActive = active
            }
        }
        guard let clip = visibilityClip, window != nil else {
            setHostsAttached(true)
            if isHidden { isHidden = false }
            return
        }
        // Retain keyboard/assistive traversal and an in-flight control/menu
        // even when scrolling carries its row beyond the warm visible band.
        let coverage = visibilityObserver?.controlBounds(in: clip) ?? clip.bounds
        let nearby = convert(bounds, to: clip).intersects(coverage.insetBy(dx: 0, dy: isHidden ? -256 : -512))
        let hidden = !nearby && visibilityObserver?.retainsAccessibilityControls != true &&
            track.map { TrackSelectionRouter.shared.pinnedTracks.contains($0) } != true &&
            (window?.firstResponder as? NSView).map { $0 === self || $0.isDescendant(of: self) } != true
        if hidden {
            if !isHidden { isHidden = true }
            if visibilityObserver?.defersHostDetachment != true { setHostsAttached(false) }
        } else {
            // Reattach while the owner is still hidden, before entering the
            // viewport. The same roots keep SwiftUI state and current actions.
            setHostsAttached(true)
            if isHidden {
                isHidden = false
                // A hidden control plane may have consumed a layout request
                // while row height changed. Replay its geometry on reveal,
                // including when its hosts stayed mounted during the gesture.
                controls.needsLayout = true
            }
        }
    }
    private func setHostsAttached(_ attached: Bool) {
        guard !updatingHostAttachment, hostsAttached != attached else { return }
        updatingHostAttachment = true
        hostsAttached = attached
        defer { updatingHostAttachment = false }
        // Reverse insertion below the first child restores the original
        // meter and controls order without disturbing other row children.
        // The row owner and its clip observer always stay mounted. Its normal
        // snapshot updates also reach these retained hosts while detached.
        for host: NSView in [controls, meter] {
            if attached {
                if host.superview !== self { addSubview(host, positioned: .below, relativeTo: subviews.first) }
            } else if host.superview === self {
                host.removeFromSuperview()
            }
        }
    }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); place() }
    override func setFrameOrigin(_ origin: NSPoint) { super.setFrameOrigin(origin); refreshViewportVisibility() }
    override func layout() { super.layout(); place() }
    private var placing = false
    func place() {
        guard !placing else { return }; placing = true
        defer { placing = false }
        // AppKit pixel rounding can turn 63.9 into 64; use the committed SwiftUI
        // size for the mode boundary, and actual bounds for independent native resizes.
        let height = logicalSize.flatMap { abs($0.height - bounds.height) <= 1 ? $0.height : nil } ?? bounds.height
        let frames = TrackMixerHeightGeometry.frames(width: bounds.width, height: height, meterWidth: meterWidth, standard: standard, lowerTitle: true, controlsWidth: 145)
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        func update(_ host: NSView, _ frame: CGRect) {
            let hidden = frame.width <= 0 || frame.height <= 0
            if host.isHidden != hidden { host.isHidden = hidden }
            if host.frame != frame {
                let resized = host.frame.size != frame.size
                host.frame = frame
                // Commit all row frames before AppKit lays out their controls.
                // Forcing a nested SwiftUI layout here repeats window-wide work
                // for every row at the compact boundary, including detached rows.
                // Moving a compact strip alone does not change its own layout.
                if resized { host.needsLayout = true; host.needsDisplay = true }
            }
        }
        let compact = snapshot?.panel?.compactComponents == true
        let underFader = compact || frames[4].height > 0
        let heightCompact = height < TrackHeightGeometry.compactControlHeight && snapshot?.panel?.allowsCompactHeight == true
        meter.presentation = heightCompact ? .dot : underFader ? .peakLabel : .peak
        let meterFrame = heightCompact ? CGRect(x: bounds.width - 18, y: (height - 12) / 2, width: 12, height: 12)
            : compact ? CGRect(x: bounds.width - 37, y: TrackMixerHeightGeometry.controlTop(height: height, groupHeight: 22) + 22, width: 34, height: 12)
            : underFader ? TrackMixerHeightGeometry.peakFrame(below: frames[4]) : frames[0]
        update(meter, hasAudioMeter && hasFaderRail ? meterFrame : .zero)
        update(controls, CGRect(x: 0, y: 0, width: bounds.width, height: height))
        // Row geometry changes keep the same responder chain and frame observers.
        // Rebind when a retained row first acquires its scroll view or moves docks.
        if visibilityClip !== (window == nil ? nil : enclosingScrollView?.contentView) {
            observeViewport()
        } else {
            refreshViewportVisibility()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local), visibleRect.contains(local) else { return nil }
        if let peak = hitTestMeterPeak(local) { return peak }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    deinit { frameObservers.forEach(NotificationCenter.default.removeObserver) }
}

#endif

private struct TrackPanelTarget: Identifiable {
    let project: UUID
    let track: UUID
    let targets: [UUID?]
    var id: UUID { track }
}

#if os(macOS)
private struct NativeMixerKnob: NSViewRepresentable {
    let show: ShowController
    let track: UUID?
    let value: Double
    let pan: Bool
    private let project: UUID
    private let session: UUID
    @Environment(\.isEnabled) private var enabled
    init(show: ShowController, track: UUID?, value: Double, pan: Bool = false) {
        self.show = show; self.track = track; self.value = value; self.pan = pan
        project = show.snapshot.project.id
        session = show.projectSessionID
    }
    func makeNSView(context: Context) -> NativeMixerKnobView { NativeMixerKnobView() }
    func updateNSView(_ view: NativeMixerKnobView, context: Context) {
        view.bind(project: project, session: session, track: track, pan: pan, value: value)
        view.isEnabled = enabled
        if !enabled { view.cancelGesture() }
        view.changed = { value, preview in
            guard show.snapshot.project.id == project, show.projectSessionID == session else { return }
            let commandValue = pan ? value : value <= -60 ? 0 : pow(10, value / 20)
            show.sendMixerControl(pan ? .pan : .volume, target: track, value: commandValue, preview: preview)
        }
    }
}
private final class NativeMixerKnobView: NSSlider {
    var changed: ((Double, Bool) -> Void)?
    private(set) var dragging = false
    private(set) var boundSession: UUID?
    var boundProject: UUID? { identity?.project }
    private var dragOrigin: (y: CGFloat, value: Double)?
    private var tracking: NSTrackingArea?
    private var identity: TrackControlIdentity?
    private var pan = false
    func bind(project: UUID, session: UUID, track: UUID?, pan: Bool, value: Double, maximumVolumeDB: Double = 12) {
        let next = TrackControlIdentity(project: project, track: track)
        let upperBound = pan ? 1 : maximumVolumeDB
        if identity != next || boundSession != session || self.pan != pan || maxValue != upperBound {
            cancelGesture()
            identity = next; boundSession = session
            self.pan = pan
            minValue = pan ? -1 : -60
            maxValue = upperBound
            setAccessibilityLabel(JarasLocalization.string(pan ? "Pan" : "Track volume"))
        }
        if !dragging { doubleValue = pan ? min(1, max(-1, value)) : value <= 0 ? -60 : min(upperBound, max(-60, 20 * log10(value))) }
        refreshLabel()
    }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        minValue = -60; maxValue = 12; sliderType = .circular; controlSize = .small
        target = self; action = #selector(adjustValue)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func adjustValue() { changed?(doubleValue, false); refreshLabel() }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if pan {
            MixerPanFace.draw(value: doubleValue, in: bounds, context: context)
            return
        }
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: 1.5, y: 1.5)
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        GridSelectionHeaderControls.knob(in: bounds, position: (doubleValue - minValue) / (maxValue - minValue), pan: pan, context: context)
        context.restoreGState()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect,.activeInActiveApp,.mouseEnteredAndExited,.mouseMoved], owner: self)
        addTrackingArea(tracking); self.tracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { showValue(event); NSCursor.resizeUpDown.set() }
    override func mouseMoved(with event: NSEvent) { showValue(event) }
    override func mouseExited(with event: NSEvent) { if !dragging { CompactTrackValueTooltip.shared.hide(for: self) } }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, window != nil else { return }
        if event.clickCount == 2 {
            cancelGesture()
            doubleValue = 0; changed?(0, false); refreshLabel(); showValue(event)
            return
        }
        dragOrigin = (event.locationInWindow.y, doubleValue)
        dragging = true
        showValue(event)
    }
    override func mouseDragged(with event: NSEvent) { apply(event, finished: false) }
    override func mouseUp(with event: NSEvent) { apply(event, finished: true) }
    private func apply(_ event: NSEvent, finished: Bool) {
        guard let dragOrigin, isEnabled, window != nil else { return }
        let value = min(maxValue, max(minValue,
            dragOrigin.value + (event.locationInWindow.y - dragOrigin.y) * (maxValue - minValue) / 120))
        doubleValue = value
        if finished { cancelGesture() }
        changed?(value, !finished)
        refreshLabel(); showValue(event)
    }
    func cancelGesture() { dragOrigin = nil; dragging = false }
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelGesture(); CompactTrackValueTooltip.shared.hide(for: self) }
    }
    private var valueLabel: String {
        if pan { return mixerPanText(doubleValue) }
        return doubleValue <= -60 ? "−∞ dB" : String(format: "%+.1f dB", doubleValue)
    }
    private func showValue(_ event: NSEvent) {
        let label = pan ? valueLabel : JarasLocalization.string("Volume") + " " + valueLabel
        CompactTrackValueTooltip.shared.show(label, owner: self, point: event.locationInWindow)
    }
    func refreshLabel() { toolTip = pan ? valueLabel : nil; setAccessibilityValue(valueLabel); needsDisplay = true }
}
@MainActor private final class CompactTrackValueTooltip {
    static let shared = CompactTrackValueTooltip()
    private final class Bubble: NSView {
        var text = "" { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { GridSelectionHeaderControls.drawValueTooltip(text, in: bounds.insetBy(dx: 0.5, dy: 0.5)) }
    }
    private let bubble = Bubble()
    private let panel: NSPanel
    private weak var owner: NSView?
    private var closing: NSObjectProtocol?
    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = bubble; panel.backgroundColor = .clear; panel.isOpaque = false
        panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = true
        panel.level = .popUpMenu; panel.animationBehavior = .none
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { if let self, let window = note.object as? NSWindow, self.owner?.window === window { self.panel.orderOut(nil) } }
        }
    }
    func show(_ text: String, owner: NSView, point: CGPoint) {
        guard NSApp.isActive, let window = owner.window else { return }
        self.owner = owner; bubble.text = text
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let width = max(96, ceil((text as NSString).size(withAttributes: [.font: font]).width)+18)
        let anchor = window.convertPoint(toScreen: point)
        let screen = window.screen?.visibleFrame ?? window.frame
        let frame = NSRect(x: min(max(screen.minX+4,anchor.x+12),screen.maxX-width-4),
                           y: min(max(screen.minY+4,anchor.y+8),screen.maxY-26),width: width,height: 22)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if !panel.isVisible { panel.orderFront(nil) }
    }
    func hide(for owner: NSView) { if self.owner === owner { panel.orderOut(nil); self.owner = nil } }
}

#endif

private struct TrackControlIdentity: Equatable {
    let project: UUID
    let track: UUID?
}

enum TrackMixerComponentsPreset {
    static let maskKey = "jaras.trackMixer.componentsPreset.mask"
    static let activeKey = "jaras.trackMixer.componentsPreset.active"
    static let defaultMask = TrackMixerComponent.compactMask | TrackMixerComponent.phase.rawValue
}

enum TrackMixerVU {
    static let preferenceKey = "jaras.trackMixer.vuVisible"
    static let styleKey = "jaras.mixer.vuStyle"
    static let columnWidth: CGFloat = 68
    static let stripHeight: CGFloat = 38

    enum Style: Int, CaseIterable {
        case amber = 1, purple
        var title: String { "VU \(rawValue)" }
        var dialColors: [Color] {
            self == .amber ? [Color(hex: 0xffde87), Color(hex: 0xe3a644)]
                : [Color(hex: 0x512d72), Color(hex: 0x241632)]
        }
        var rim: Color { Color(hex: self == .amber ? 0x9b6934 : 0x80659a) }
        var legend: Color { Color(hex: self == .amber ? 0x332318 : 0xd0b3eb) }
        var needle: Color { Color(hex: self == .amber ? 0x261a12 : 0xf2e9ff) }
        func tick(_ value: Int) -> Color {
            self == .amber ? Color(hex: value > 0 ? 0xa52519 : 0x332318) : JarasTheme.green
        }
    }
}

struct TrackMixerVUButton: View {
    var size: CGFloat = 24
    @AppStorage(TrackMixerVU.preferenceKey) private var visible = false
    @WorkspacePreference(TrackMixerVU.styleKey) private var style = TrackMixerVU.Style.purple

    var body: some View {
        Button { visible.toggle() } label: {
            TransportControlIcon(name: "vuMeter", size: 16)
                .frame(width: size, height: size).contentShape(Rectangle())
                .foregroundStyle(visible ? JarasTheme.green : JarasTheme.secondary)
        }.buttonStyle(.plain)
            .accessibilityLabel("VU Meter")
            .accessibilityIdentifier("track-mixer-vu")
            .accessibilityAddTraits(visible ? .isSelected : [])
            .contextMenu {
                Picker("VU Meter", selection: $style) {
                    ForEach(TrackMixerVU.Style.allCases, id: \.self) { choice in
                        Text(verbatim: choice.title).tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .jarasHelp("Show/hide track VU meters")
    }
}

struct ClassicVUMeter: View {
    let meter: TrackMeterLevel?
    @WorkspacePreference(TrackMixerVU.styleKey) private var style = TrackMixerVU.Style.purple
    private static let marks = [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3]
    @State private var level = -20.0

    private static func angle(_ vu: Double) -> Double {
        let amplitude = pow(10, vu / 20)
        let fraction = (amplitude - 0.1) / (pow(10, 3.0 / 20) - 0.1)
        return (-55 + 110 * min(1, max(0, fraction))) * Double.pi / 180
    }

    private static func dialPoint(_ vu: Double, radius: CGFloat) -> CGPoint {
        let angle = angle(vu)
        return CGPoint(x: 48 + radius * sin(angle), y: 41 - radius * cos(angle))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = min(size.width / 96, size.height / 45)
            ZStack {
                Canvas { context, _ in
                    context.fill(Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: 95, height: 44), cornerRadius: 5),
                        with: .linearGradient(Gradient(colors: style.dialColors),
                            startPoint: .zero, endPoint: CGPoint(x: 0, y: 45)))
                    let casing = Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: 95, height: 44), cornerRadius: 5)
                    context.stroke(casing, with: .color(style.rim), lineWidth: 1)
                    for value in Self.marks {
                        var tick = Path()
                        tick.move(to: Self.dialPoint(Double(value), radius: 26))
                        tick.addLine(to: Self.dialPoint(Double(value), radius: 31))
                        let ink = style.tick(value)
                        context.stroke(tick, with: .color(ink), lineWidth: value == 0 ? 1.2 : 0.75)
                        if [-20, -10, -5, 0, 3].contains(value) {
                            context.draw(Text(verbatim: value > 0 ? "+\(value)" : "\(value)")
                                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                                .foregroundColor(ink), at: Self.dialPoint(Double(value), radius: 38))
                        }
                    }
                    context.draw(Text(verbatim: "VU").font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundColor(style.legend), at: CGPoint(x: 48, y: 29))
                }
                Path { path in
                    path.move(to: CGPoint(x: 48, y: 41))
                    path.addLine(to: Self.dialPoint(level, radius: 32))
                }.stroke(style.needle, style: StrokeStyle(lineWidth: 1.15, lineCap: .round))
                Circle().fill(style.needle).frame(width: 4, height: 4).position(x: 48, y: 41)
            }.frame(width: 96, height: 45)
                .scaleEffect(scale).frame(width: size.width, height: size.height)
        }
        .onReceive((meter?.vuChanges ?? Empty<Double, Never>().eraseToAnyPublisher())) { level = $0 }
        .onAppear { level = meter?.vuLevel ?? -20 }
        .onChange(of: meter.map(ObjectIdentifier.init)) { _ in level = meter?.vuLevel ?? -20 }
        .allowsHitTesting(false)
        .accessibilityLabel("VU Meter")
    }
}

struct TrackMixerVURow<Content: View>: View {
    let meter: TrackMeterLevel?
    let visible: Bool
    var showsMeter = true
    @ViewBuilder var content: Content
    @AppStorage(TrackMixerComponentsPreset.activeKey) private var presetActive = false
    @AppStorage(TrackMixerComponentsPreset.maskKey) private var presetMask = TrackMixerComponentsPreset.defaultMask

    var body: some View {
        HStack(spacing: 0) {
            content.frame(maxWidth: .infinity)
            if visible {
                ZStack {
                    if showsMeter && (!presetActive || presetMask & TrackMixerComponent.vuMeter.rawValue == 0) {
                        ClassicVUMeter(meter: meter).frame(maxHeight: 31).padding(.horizontal, 4)
                    }
                }
                    .frame(width: TrackMixerVU.columnWidth, alignment: .center)
                    .frame(maxHeight: .infinity)
                    .background(JarasTheme.display)
            }
        }
    }
}

struct TrackMixerComponentsPresetButton: View {
    var size: CGFloat = 24
    @AppStorage(TrackMixerComponentsPreset.activeKey) private var active = false
    @AppStorage(TrackMixerComponentsPreset.maskKey) private var mask = TrackMixerComponentsPreset.defaultMask
    #if os(iOS)
    @State private var choosingComponents = false
    #endif

    private func hides(_ component: TrackMixerComponent) -> Bool { mask & component.rawValue != 0 }
    private func toggle(_ component: TrackMixerComponent) { mask ^= component.rawValue }

    var body: some View {
        Button { active.toggle() } label: {
            ControlIcon(name: "trackMixer", active: active, size: 15)
                .foregroundStyle(active ? JarasTheme.green : JarasTheme.text)
                .frame(width: size, height: size).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Preset Components View"))
            .accessibilityIdentifier("track-components-preset")
            .accessibilityAddTraits(active ? .isSelected : [])
            .help(Text(verbatim: "Preset Components View"))
            #if os(macOS)
            .overlay { TrackMixerPresetMenu(isChecked: hides, toggle: toggle) }
            #else
            .overlay { IpadTapHoldTouchSurface(tap: { active.toggle() }, hold: { choosingComponents = true }) }
            .popover(isPresented: $choosingComponents) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(TrackMixerComponent.allCases, id: \.self) { component in
                        Button { toggle(component) } label: {
                            Label(LocalizedStringKey(component.title), systemImage: hides(component) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(JarasTheme.text)
                                .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(hides(component) ? .isSelected : [])
                    }
                }
                .font(.jarasSystem(size: 13, weight: .medium)).frame(width: 160).padding(12)
            }
            #endif
    }
}

#if os(macOS)
private struct TrackMixerPresetMenu: NSViewRepresentable {
    let isChecked: (TrackMixerComponent) -> Bool
    let toggle: (TrackMixerComponent) -> Void

    func makeNSView(context: Context) -> RightClickTargetView { RightClickTargetView() }
    func updateNSView(_ view: RightClickTargetView, context: Context) {
        view.action = { [weak view] in
            guard let view, let event = NSApp.currentEvent else { return }
            let menu = NSMenu()
            menu.addItem(trackComponentCheckboxes(isChecked: isChecked, toggle: toggle))
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }
}

@MainActor private func trackComponentCheckboxes(components: [TrackMixerComponent] = TrackMixerComponent.allCases,
                                                  isChecked: @escaping (TrackMixerComponent) -> Bool,
                                                  toggle: @escaping (TrackMixerComponent) -> Void) -> NSMenuItem {
    let checks = NSView(frame: CGRect(x: 0, y: 0, width: 156, height: 8 + components.count * 22))
    var actions: [TrackMenuAction] = []
    for (index, component) in components.enumerated() {
        let button = NSButton(checkboxWithTitle: JarasLocalization.string(component.title), target: nil, action: nil)
        button.frame = CGRect(x: 8, y: 4 + (components.count - index - 1) * 22, width: 142, height: 22)
        button.state = isChecked(component) ? .on : .off
        let target = TrackMenuAction { [weak button] in
            toggle(component)
            button?.state = isChecked(component) ? .on : .off
        }
        actions.append(target)
        button.target = target; button.action = #selector(TrackMenuAction.invoke)
        checks.addSubview(button)
    }
    let item = NSMenuItem()
    item.view = checks
    item.representedObject = actions
    return item
}
#endif

struct TrackMixerRow: View, Equatable {
    @MainActor static func resetProjectSession() {
        TrackReorderState.shared.finish()
        #if os(macOS)
        TrackSelectionRouter.shared.resetProjectSession()
        #endif
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        #if os(macOS)
        // Native/legacy layout already hides and repositions the retained
        // controls from its proposed height. These iPad-only content inputs
        // must not rebuild every hosted root when crossing 64 or 56 points.
        let sameHeightMode = true
        #else
        let sameHeightMode = lhs.compactHeight == rhs.compactHeight && lhs.minimalHeight == rhs.minimalHeight
        #endif
        let sameSelection = lhs.trackSelection == rhs.trackSelection ||
            (!lhs.trackSelection.contains(lhs.track.id) && !rhs.trackSelection.contains(rhs.track.id))
        return lhs.show === rhs.show && lhs.projectID == rhs.projectID && sameSelection && lhs.track == rhs.track && lhs.nextTrack == rhs.nextTrack && lhs.number == rhs.number && lhs.selected == rhs.selected && lhs.silenced == rhs.silenced && lhs.showsMeterScale == rhs.showsMeterScale && lhs.showsFader == rhs.showsFader && lhs.projectDirectory == rhs.projectDirectory && sameHeightMode && lhs.isFolder == rhs.isFolder && lhs.groupDepth == rhs.groupDepth && lhs.groupColor == rhs.groupColor && lhs.lastChild == rhs.lastChild && (lhs.groupSelection != nil) == (rhs.groupSelection != nil) && (lhs.deleteTracks != nil) == (rhs.deleteTracks != nil)
    }
    @Environment(\.openFX) private var openFX
    @Environment(\.editTextItem) private var editTextItem
    @Environment(\.addFullLyrics) private var addFullLyrics
    @AppStorage(TrackMixerComponentsPreset.activeKey) private var componentsPresetActive = false
    @AppStorage(TrackMixerComponentsPreset.maskKey) private var componentsPresetMask = TrackMixerComponentsPreset.defaultMask
    let show: ShowController
    let projectID: UUID
    let track: Track
    private var mixerComponentMask: Int {
        let preset = componentsPresetActive ? track.applicableMixerComponentMask(componentsPresetMask) : 0
        return (track.mixerComponentMask | preset) & ~TrackMixerComponent.vuMeter.rawValue
    }
    private func showsComponent(_ component: TrackMixerComponent) -> Bool {
        mixerComponentMask & component.rawValue == 0
    }
    private var compactMixerControls: Bool {
        mixerComponentMask & TrackMixerComponent.compactMask == TrackMixerComponent.compactMask
    }
    let trackSelection: Set<UUID>
    let nextTrack: UUID?
    let number: Int
    let selected: Bool
    let silenced: Bool
    let showsMeterScale: Bool
    private var showsTrackMeterScale: Bool { showsMeterScale && trackShowsMeterReadouts(track.kind) }
    private var meterTextColor: Color {
        Color(hex: nameColor)
    }
    let showsFader: Bool
    var compactHeight = false
    var minimalHeight = false
    let isFolder: Bool
    var groupDepth: Int = 0
    var groupColor: UInt32? = nil
    let lastChild: Bool
    let groupSelection: (() -> Void)?
    let select: () -> Void
    var importVideo: () -> Void = {}
    var projectDirectory: URL?
    var deleteTracks: ((Set<UUID>) -> Void)? = nil
    @State private var clickSoundPresented = false
    #if !os(macOS)
    @State private var patchTarget: TrackPanelTarget?
    #endif
    private var targets: [UUID?] {
        #if os(macOS)
        let selection = show.mixerTrackSelection
        #else
        let selection = trackSelection
        #endif
        guard track.kind == .standard, selection.contains(track.id) else { return [track.id] }
        return (show.current?.tracks ?? []).filter { $0.kind == .standard && selection.contains($0.id) }.map { Optional($0.id) }
    }
    private var deletionTargets: Set<UUID> {
        trackSelection.contains(track.id) ? trackSelection : [track.id]
    }
    private var duplicateSelection: (() -> Void)? {
        guard track.role.rawValue != "vinhetas", track.kind == .standard else { return nil }
        let project = projectID, song = show.current?.id, ids = deletionTargets
        return {
            guard show.snapshot.project.id == project, show.current?.id == song else { return }
            show.duplicateTracks(ids)
        }
    }
    private var toggleSelectedEnvelopes: (() -> Void)? {
        let ids = deletionTargets
        guard track.kind == .standard || (ids.count > 1 && show.current?.tracks.contains(where: {
            ids.contains($0.id) && $0.kind == .standard
        }) == true) else { return nil }
        let project = projectID, song = show.current?.id
        return {
            guard show.snapshot.project.id == project, show.current?.id == song else { return }
            show.toggleAutomationLanes(ids)
        }
    }
    private var deleteSelection: (() -> Void)? {
        guard let deleteTracks else { return nil }
        let project = projectID, ids = deletionTargets
        return {
            guard show.snapshot.project.id == project else { return }
            deleteTracks(ids)
        }
    }
    @Environment(\.editTrackDetails) private var editTrackDetails
    @ObservedObject private var dragState = TrackReorderState.shared
    private var dropSide: Bool? { dragState.target == track.id ? dragState.after : nil }
    private func openPatch(project: UUID) {
        guard show.snapshot.project.id == project else { return }
        #if os(macOS)
        WorkspaceToolWindows.openPatch(show: show, track: track.id, targets: targets)
        #else
        patchTarget = TrackPanelTarget(project: project, track: track.id, targets: targets)
        #endif
    }
    @WorkspacePreference(JarasInterfaceTheme.preferenceKey) private var interfaceTheme = JarasInterfaceTheme.defaultTheme
    @AppStorage(MixerTrackStyle.trackMixerKey) private var trackStyle = MixerTrackStyle.defaultStyle
    private var usesStripe: Bool { trackStyle == .stripeOnly }
    private var stripeWidth: CGFloat { usesStripe ? MixerTrackStyle.trackStripeWidth : 0 }
    private var nameColor: UInt32 {
        usesStripe ? MixerTrackStyle.surfaceTextHex : JarasTheme.trackNameHex(track, emphasized: selected, silenced: silenced)
    }

    private var canLink: Bool { trackSelection.contains(track.id) && show.current?.linkableTracks(trackSelection) != nil }
    private func linkSelectedTracks() {
        guard let song = show.current, let indices = song.linkableTracks(trackSelection) else { return }
        let top = song.tracks[indices[0]]
        show.linkTracks(trackSelection, defaultInput: TrackRecording.shared.defaultInputPatch.firstChannel, color: top.color ?? JarasTheme.roleHex(top.role))
    }
    @ViewBuilder var body: some View {
        if track.kind == .programChange {
            ProgramChangeTrackRow(show: show, track: track, number: number, selected: selected, select: select, randomColor: { [ids = deletionTargets, project = projectID] in show.randomizeTrackColors(ids, project: project) }, deleteTrack: deleteSelection)
        } else { regularBody }
    }
    @ViewBuilder private var regularBody: some View {
        let project = projectID
        let colorTargets = deletionTargets
        let randomizeColors = { show.randomizeTrackColors(colorTargets, project: project) }
        let editTargets = Set(targets.compactMap { $0 })
        let details = TrackDetailsEditRequest(project: project, tracks: editTargets,
            name: track.name, color: track.color ?? JarasTheme.roleHex(track.role),
            instrumentIcon: track.instrumentIcon)
        let title = (number < 10 ? "0" : "") + String(number) + "  " + track.name
        let titleColor = nameColor
        HStack(spacing: 4) {
            if track.parentTrackID != nil {
                if groupDepth > 1 { Color.clear.frame(width: CGFloat(min(4, groupDepth - 1)) * 8) }
                GroupTrackConnector(last: lastChild).stroke(groupColor.map(Color.init(hex:)) ?? JarasTheme.green, lineWidth: 1)
                    .frame(width: 12).allowsHitTesting(false)
            }
            #if os(macOS)
            continuousControls(title: title, color: titleColor, project: project)
                .overlay(alignment: .topLeading) {
                    if let icon = track.instrumentIcon, TrackIconCatalog.contains(icon), showsFader {
                        GeometryReader { geometry in
                            let volume = TrackMixerHeightGeometry.frames(width: geometry.size.width, height: geometry.size.height,
                                meterWidth: showsTrackMeterScale ? 52 : 12, standard: track.kind == .standard,
                                lowerTitle: true, controlsWidth: 145)[4]
                            if track.allowsCompactMixerHeight && geometry.size.height < TrackHeightGeometry.compactControlHeight {
                                TrackIconDisplay(id: icon).foregroundStyle(.white)
                                    .frame(width: min(20, geometry.size.height - 2), height: min(20, geometry.size.height - 2)).position(x: 14, y: geometry.size.height / 2)
                            } else if compactMixerControls {
                                TrackIconDisplay(id: icon).foregroundStyle(.white).frame(width: 24, height: 22).position(x: 22, y: TrackMixerHeightGeometry.controlTop(height: geometry.size.height, groupHeight: 22) + 11)
                            } else if volume.height > 0 {
                                TrackIconDisplay(id: icon).foregroundStyle(.white)
                                    .frame(width: 32, height: 32).position(x: 24, y: max(16, volume.midY - 8))
                            }
                        }.allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .padding(.leading, stripeWidth)
            #else
            if minimalHeight {
                HStack(spacing: 3) {
                    #if os(macOS)
                    if track.kind == .standard {
                        TrackDragTitle(title: title, foreground: titleColor, project: project, track: track.id, state: dragState, select: select)
                            .frame(maxWidth: .infinity).frame(height: 21)
                    } else {
                        Text(title).font(.jarasSystem(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: titleColor)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    #else
                    Text(title).font(.jarasSystem(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: titleColor)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    #endif
                    HStack(spacing: 3) {
                        if track.kind == .standard {
                            Button("Patch") { openPatch(project: project) }
                                .buttonStyle(CompactTrackButtonStyle(width: 34)).jarasHelp("Patch")
                            TrackEnvelopeButton(show: show, track: track.id, visible: !(track.automation?.visibleEnvelopes.isEmpty ?? true))
                            TrackFXButton(show: show, track: track.id, settings: track.fx ?? NativeFXSettings())
                                .buttonStyle(CompactTrackButtonStyle()).jarasHelp("Insert effect")
                            TrackRecordButton(show: show, track: track).buttonStyle(CompactTrackButtonStyle())
                            TrackInputMonitorButton(show: show, track: track)
                        } else if track.kind == .click {
                            Button("Patch") { openPatch(project: project) }
                                .buttonStyle(CompactTrackButtonStyle(width: 34)).fixedSize(horizontal: true, vertical: false)
                            Button("Insert") { show.insertClickItems(track: track.id) }
                                .buttonStyle(CompactTrackButtonStyle(width: 47)).fixedSize(horizontal: true, vertical: false)
                        }
                        if trackShowsMuteSolo(track.kind) {
                            Button("M") { show.sendTrackMixerButton(.mute, target: track.id) }
                                .modifier(MappingRightClick(track: track.id, command: "mute"))
                                .buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil)).jarasHelp("Mute")
                            Button("S") { show.sendTrackMixerButton(.solo, target: track.id) }
                                .modifier(MappingRightClick(track: track.id, command: "solo"))
                                .buttonStyle(CompactTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil)).jarasHelp("Solo")
                        }
                    }.trackControlSelectionExclusion()
                }.padding(.horizontal, 4)
            } else {
            if !showsFader {
                CompactMixerMeter(meter: StemAudioPlayback.shared.meter(for: track.id))
                    .frame(width: 10).padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if track.kind != .standard && track.kind != .video && track.kind != .timecode && track.kind != .click {
                        Text(title).font(.jarasSystem(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: titleColor))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }
                HStack(spacing: 3) {
                    if track.kind == .standard {
                    if showsFader {
                        Button("Patch") { openPatch(project: project) }
                            .buttonStyle(CompactTrackButtonStyle(width: 34)).jarasHelp("Patch")
                        TrackEnvelopeButton(show: show, track: track.id, visible: !(track.automation?.visibleEnvelopes.isEmpty ?? true))
                        TrackFXButton(show: show, track: track.id, settings: track.fx ?? NativeFXSettings()).jarasHelp("Track")
                    }
                    TrackRecordButton(show: show, track: track).buttonStyle(CompactTrackButtonStyle())
                            TrackInputMonitorButton(show: show, track: track)
                    Button("M") { show.sendTrackMixerButton(.mute, target: track.id) }.modifier(MappingRightClick(track: track.id, command: "mute")).buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil)).jarasHelp("Mute")
                    Button("S") { show.sendTrackMixerButton(.solo, target: track.id) }.modifier(MappingRightClick(track: track.id, command: "solo")).buttonStyle(CompactTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil)).jarasHelp("Solo")
                    } else if track.kind == .click {
                        Button("Patch") { openPatch(project: project) }
                            .buttonStyle(CompactTrackButtonStyle(width: 34)).fixedSize(horizontal: true, vertical: false)
                            .trackControlSelectionExclusion()
                        Button("Insert") { show.insertClickItems(track: track.id) }.buttonStyle(TrackControlButtonStyle())
                            .fixedSize(horizontal: true, vertical: false)
                        Button("M") { show.sendTrackMixerButton(.mute, target: track.id) }.buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil))
                        Button("S") { show.sendTrackMixerButton(.solo, target: track.id) }.buttonStyle(CompactTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil))
                    } else if track.kind == .timecode {
                        HStack(spacing: 3) {
                            Button { openPatch(project: project) } label: { Image(systemName: "gearshape") }
                            ForEach(["mtc","ltc"], id: \.self) { mode in
                                let active = (track.timecode?.mode ?? "mtc") == mode
                                Button(mode.uppercased()) { var settings = track.timecode ?? TimecodeSettings(); settings.mode = mode; show.setTimecode(track.id, settings: settings) }
                                    .foregroundStyle(active ? .black : .white)
                                    .buttonStyle(TrackControlButtonStyle(activeColor: active ? JarasTheme.green : nil))
                            }
                        }.buttonStyle(TrackControlButtonStyle()).fixedSize(horizontal: true, vertical: false)
                        Button("M") { show.sendTrackMixerButton(.mute, target: track.id) }.buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil)).jarasHelp("Mute")
                        Button("S") { show.sendTrackMixerButton(.solo, target: track.id) }.buttonStyle(CompactTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil)).jarasHelp("Solo")
                    } else if track.kind == .video {
                        Button("Add media", action: importVideo).buttonStyle(TrackControlButtonStyle())
                        Button("M") { show.sendTrackMixerButton(.mute, target: track.id) }.buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil)).jarasHelp("Mute")
                        Button("S") { show.sendTrackMixerButton(.solo, target: track.id) }.buttonStyle(CompactTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil)).jarasHelp("Solo")
                    } else if track.kind.isText {
                        VStack(alignment: .leading, spacing: 3) {
                            Button { if let item = show.addTextItem(track: track.id) { editTextItem(item) } } label: {
                                TeleprompterTrackButtons.addTextLabel(for: track.kind).lineLimit(1).frame(width: 86)
                            }
                            if track.kind.isTeleprompter {
                                Button { addFullLyrics(track.id) } label: { Text(verbatim: TeleprompterTrackButtons.lyricsTitle).lineLimit(1).frame(width: 86) }
                            }
                        }.buttonStyle(TrackControlButtonStyle())
                    }
                }.buttonStyle(CompactTrackButtonStyle()).trackControlSelectionExclusion()
                }.frame(height: track.kind.isTeleprompter ? 48 : compactHeight ? 21 : 24)
                HStack(spacing: 3) {
                    if showsFader && (track.kind == .standard || track.kind == .video || track.kind == .timecode || track.kind == .click) {
                        if let icon = track.instrumentIcon, TrackIconCatalog.contains(icon) {
                            TrackIconDisplay(id: icon).foregroundStyle(.white).frame(width: 40, height: 40).allowsHitTesting(false)
                        }
                        TrackVolumeFader(show: show, track: track.id, volume: track.volume, phaseInverted: track.phaseInverted == true, compact: true, showsPhase: track.kind != .timecode && track.kind != .click && track.role.rawValue != "vinhetas")
                    }
                }.buttonStyle(TrackControlButtonStyle()).frame(height: track.kind == .standard || track.kind == .video || track.kind == .timecode || track.kind == .click ? 20 : 4)
                if track.kind == .standard || track.kind == .video || track.kind == .timecode || track.kind == .click {
                    HStack(spacing: 4) {
                        #if os(macOS)
                        if track.kind == .standard {
                        TrackDragTitle(title: title, foreground: titleColor, project: project, track: track.id, state: dragState, select: select)
                            .frame(maxWidth: .infinity).frame(height: compactHeight ? 14 : 16)
                        } else { Text(title).font(.jarasSystem(size: 11, weight: .semibold)).foregroundStyle(Color(hex: titleColor)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
                        #else
                        Text(title).font(.jarasSystem(size: 11, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(Color(hex: titleColor))
                            .contentShape(Rectangle()).onDrag { dragState.begin(track: track.id); select(); return TrackReorderState.provider(track.id) }
                        #endif
                    }.frame(height: compactHeight ? 14 : 16)
                }
                Spacer(minLength: 1)
            }.padding(.top, compactHeight ? 0 : 3).padding(.trailing, 4)
            }
            #endif
        }.frame(maxHeight: .infinity).clipped()
            .background { HStack(spacing: 0) {
                if track.parentTrackID != nil { JarasTheme.mixer.frame(width: 16) }
                if usesStripe {
                    MixerTrackSurface(selected: selected)
                        .overlay(alignment: .leading) {
                            JarasTheme.track(track).frame(width: MixerTrackStyle.trackStripeWidth)
                        }
                } else {
                    JarasTheme.track(track, emphasized: selected).opacity(selected ? 0.65 : 0.50).saturation(silenced ? 0 : 1)
                }
            }.allowsHitTesting(false) }
            .overlay(alignment: .bottom) { Rectangle().fill(JarasTheme.line).frame(height: 1).padding(.leading, track.parentTrackID == nil ? 0 : 16) }
            .background { GeometryReader { geometry in
                if track.kind == .standard { Color.clear.onDrop(of: [TrackReorderState.type], delegate: TrackInsertionDrop(show: show, track: track.id, nextTrack: nextTrack, height: geometry.size.height, state: dragState)) }
            } }
            #if !os(macOS)
            .modifier(LibraryTrackEffectDrop(show: show, track: track.kind == .standard ? track.id : nil))
            #endif
            .overlay(alignment: dropSide == true ? .bottom : .top) {
                if dropSide != nil { Rectangle().fill(dragState.indicatorColor).frame(height: 3).shadow(color: dragState.indicatorColor, radius: 4).allowsHitTesting(false) }
            }
            .overlay { if dragState.blockedTarget == track.id { TrackDropBlockedBadge() } }
            #if os(macOS)
            .overlay(TrackRightClickInput(project: project, track: track.id, kind: track.kind, dragName: track.name, selected: selected, select: select, patch: { openPatch(project: project) }, fx: { openFX(track.id, "Chain") }, edit: { editTrackDetails(details) }, randomColor: randomizeColors, icon: { editTrackDetails(details.iconRequest) }, group: show.canCreateTrackGroup(track.id) ? { show.createTrackGroup(track.id) } : nil, ungroup: isFolder ? { show.ungroupTrack(track.id) } : nil, removeFromGroup: track.parentTrackID != nil ? { show.removeTrackFromGroup(track.id) } : nil, link: canLink ? { linkSelectedTracks() } : nil, unlink: track.stereoLink != nil ? { show.unlinkTracks(track.id) } : nil, soundDesigner: track.kind == .click ? { clickSoundPresented = true } : nil, createMIDI: track.kind == .standard && track.role.rawValue != "vinhetas" ? {
                let range = TimelineAreaSelection.shared.range
                let valid = range?.song == show.current?.id
                show.addMIDIItem(track: track.id, start: valid ? range?.start : nil, duration: valid ? range.map { $0.end - $0.start } : nil)
            } : nil, duplicateTracks: duplicateSelection, deleteTracks: deleteSelection, deleteTrackCount: deletionTargets.count,
                cursorMix: { tool in tool.apply(to: track.id, show: show) }, envelope: toggleSelectedEnvelopes,
                stemLayout: track.stackedStems, organizeStems: { mode in if show.snapshot.project.id == project { show.setStemLayout(mode, tracks: deletionTargets) } },
                componentMask: { show.hiddenTrackMixerComponents(deletionTargets) },
                componentChoices: track.availableMixerComponents,
                toggleComponent: { component in
                    guard show.snapshot.project.id == project else { return }
                    show.toggleTrackMixerComponents(deletionTargets, mask: component.rawValue, showWhenMixed: true)
                }))
            #else
            .onTapGesture(perform: select)
            .contextMenu {
                Button("Patch") { openPatch(project: project) }
                if track.kind == .standard { Button("FX") { openFX(track.id, "Chain") } }
                if let toggleSelectedEnvelopes { Button("Envelope", action: toggleSelectedEnvelopes) }
                Menu("Organize Stems") {
                    Picker("Organize Stems", selection: Binding(get: { track.stackedStems }, set: { show.setStemLayout($0, tracks: deletionTargets) })) {
                        Text(verbatim: "Default").tag(nil as Bool?)
                        Text(verbatim: "Crossfader").tag(Optional(true))
                        Text("Separated").tag(Optional(false))
                    }
                }
                Button("Set Track Color") { editTrackDetails(details) }
                Button("Set Random Color", action: randomizeColors)
                Button("Set Track Icon") { editTrackDetails(details.iconRequest) }
                if let duplicateSelection {
                    Button(LocalizedStringKey(deletionTargets.count > 1 ? "Duplicate tracks" : "Duplicate track"), action: duplicateSelection)
                }
                if canLink { Button("Link tracks") { linkSelectedTracks() } }
                if isFolder { Button("Ungroup") { show.ungroupTrack(track.id) } }
                if track.parentTrackID != nil { Button("Remove from group") { show.removeTrackFromGroup(track.id) } }
                if track.stereoLink != nil { Button("Unlink tracks") { show.unlinkTracks(track.id) } }
                if let deleteSelection {
                    Divider()
                    Button(role: .destructive, action: deleteSelection) {
                        Text(LocalizedStringKey(deletionTargets.count > 1 ? "Delete tracks" : "Delete track"))
                    }
                }
            }
            #endif
            #if os(macOS)
            .workspaceEditor("Sound Designer", isPresented: $clickSoundPresented) {
                ClickSoundDesigner(show: show, track: track.id, directory: projectDirectory) { clickSoundPresented = false }
            }
            .onChange(of: projectID) { _ in clickSoundPresented = false }
            #else
            .workspaceEditor("Patch", item: $patchTarget, scrolls: false, size: PatchEditor.windowSize, activates: false) { target in
                VStack { PatchEditor(show: show, track: target.track, targets: target.targets); Button("Close") { patchTarget = nil }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .onChange(of: projectID) { _ in patchTarget = nil; clickSoundPresented = false }
            #endif

    }
    private func teleprompterButtons(project: UUID) -> some View {
        TeleprompterTrackButtons(openPatch: { openPatch(project: project) },
            addText: { if let item = show.addTextItem(track: track.id) { editTextItem(item) } },
            addLyrics: { addFullLyrics(track.id) })
            .trackControlSelectionExclusion()
    }
    #if os(macOS)
    @ViewBuilder private func continuousControls(title: String, color: UInt32, project: UUID) -> some View {
        let usesNativeFader = track.kind == .standard || track.kind == .click || track.kind == .timecode || track.kind.isTeleprompter
        NativeTrackMixerControls(track: track.id, meterWidth: showsTrackMeterScale ? 52 : 12, standard: track.kind == .standard,
            meter: StemAudioPlayback.shared.meter(for: track.id), hasFaderRail: showsFader,
            hasAudioMeter: !track.kind.isText && track.kind != .programChange,
            showScale: showsTrackMeterScale, foreground: meterTextColor, peakOnly: trackShowsMeterReadouts(track.kind), controls: {
                continuousControlSlots(title: title, color: color, project: project)
            }, nativePanel: usesNativeFader ? nativePanel(title: title, color: color, project: project) : nil)
    }
    private func continuousButtons(project: UUID, compact: Bool = false) -> some View {
        TrackMixerButtonsContainer(standard: track.kind == .standard, showsFader: showsFader, customComponents: compact || mixerComponentMask != 0) {
            if track.kind == .standard {
                if !compact && showsComponent(.patch) {
                Button("Patch") { openPatch(project: project) }
                    .buttonStyle(CompactTrackButtonStyle(width: 34)).jarasHelp("Patch")
                    .frame(width: 34).trackControlSelectionExclusion().jarasPlaced(at: 0)
                }
                if !compact && showsComponent(.envelope) {
                TrackEnvelopeButton(show: show, track: track.id, visible: !(track.automation?.visibleEnvelopes.isEmpty ?? true))
                    .frame(width: 28).trackControlSelectionExclusion().jarasPlaced(at: 1)
                }
                if !compact && showsComponent(.fx) {
                TrackFXButton(show: show, track: track.id, settings: track.fx ?? NativeFXSettings()).jarasHelp("Track")
                    .frame(width: 22).trackControlSelectionExclusion().jarasPlaced(at: 2)
                }
                let showsRecord = showsComponent(.rec)
                let showsInput = track.role.rawValue != "vinhetas" && showsComponent(.inputMonitor)
                if showsRecord || showsInput {
                    HStack(spacing: 3) {
                        if showsRecord { TrackRecordButton(show: show, track: track, fillsRow: compact) }
                        if showsInput { TrackInputMonitorButton(show: show, track: track, fillsRow: compact) }
                    }.frame(width: showsRecord && showsInput ? 47 : 22)
                        .trackControlSelectionExclusion().jarasPlaced(at: 3)
                }
            } else if track.kind == .click && !compact {
                Button("Patch") { openPatch(project: project) }
                    .buttonStyle(CompactTrackButtonStyle(width: 34)).fixedSize(horizontal: true, vertical: false)
                    .trackControlSelectionExclusion()
                Button("Insert") { show.insertClickItems(track: track.id) }
                    .buttonStyle(CompactTrackButtonStyle(width: 47))
                    .fixedSize(horizontal: true, vertical: false).trackControlSelectionExclusion().jarasHelp("Insert click items in regions without a click")
            } else if track.kind.isTeleprompter {
                teleprompterButtons(project: project)
            } else {
                HStack(spacing: 3) {
                    if track.kind == .timecode {
                        Button { openPatch(project: project) } label: { Image(systemName: "gearshape") }
                        ForEach(["mtc", "ltc"], id: \.self) { mode in
                            let active = (track.timecode?.mode ?? "mtc") == mode
                            Button(mode.uppercased()) { var settings = track.timecode ?? TimecodeSettings(); settings.mode = mode; show.setTimecode(track.id, settings: settings) }
                                .foregroundStyle(active ? .black : .white)
                                .buttonStyle(TrackControlButtonStyle(activeColor: active ? JarasTheme.green : nil))
                        }
                    } else if track.kind == .video {
                        Button("Add media", action: importVideo)
                    } else if track.kind.isText {
                        Button { if let item = show.addTextItem(track: track.id) { editTextItem(item) } } label: {
                            Text("Add text").lineLimit(1).frame(width: 86)
                        }
                    }
                }.buttonStyle(TrackControlButtonStyle())
                    .fixedSize().trackControlSelectionExclusion()
            }
            if !compact && track.kind == .standard && showsComponent(.pan) {
                TrackPanKnob(show: show, track: track.id, pan: track.pan, showsTooltip: true)
                    .frame(width: 22, height: 21).trackControlSelectionExclusion().jarasPlaced(at: 4)
            }
            if trackShowsMuteSolo(track.kind) {
                if showsComponent(.mute) {
                Button("M") { show.sendTrackMixerButton(.mute, target: track.id) }
                    .modifier(MappingRightClick(track: track.id, command: "mute"))
                    .buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil, fillsRow: compact)).jarasHelp("Mute")
                    .frame(width: 22).trackControlSelectionExclusion().jarasPlaced(at: 5)
                }
                if showsComponent(.solo) {
                Button("S") { show.sendTrackMixerButton(.solo, target: track.id) }
                    .modifier(MappingRightClick(track: track.id, command: "solo"))
                    .buttonStyle(CompactTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil, fillsRow: compact)).jarasHelp("Solo")
                    .frame(width: 22).trackControlSelectionExclusion().jarasPlaced(at: 6)
                }
            }
        }.buttonStyle(CompactTrackButtonStyle()).clipped()
            .modifier(LegacyControlsWidth()).environment(\.openFX, openFX)
    }
    private func nativePanel(title: String, color: UInt32, project: UUID) -> TrackMixerNativePanelContent {
        let identity = TrackControlIdentity(project: project, track: track.id)
        let id = track.id
        let slider = DirectVolumeSlider(show: show, groupValues: { show.mixerPreviewValues }, identity: identity,
            value: track.volume <= 0 ? -60 : min(12, max(-59.9, 20 * log10(track.volume))),
            linkedTrack: track.stereoLink?.partner,
            railTheme: interfaceTheme, meter: StemAudioPlayback.shared.meter(for: id), changed: { value in
                guard show.snapshot.project.id == project else { return }
                show.sendMixerControl(.volume, target: id, value: value <= -60 ? 0 : pow(10, value / 20), preview: true)
            }, editingChanged: { editing, value in
                guard !editing, show.snapshot.project.id == project else { return }
                show.sendMixerControl(.volume, target: id, value: value <= -60 ? 0 : pow(10, value / 20))
            })
        let vinhetas = track.role.rawValue == "vinhetas"
        let draggable = track.kind == .standard, teleprompter = track.kind.isTeleprompter
        let controls: [(TrackMixerComponent, CGFloat)] = [(.patch,34),(.envelope,28),(.fx,22),(.rec,22),(.inputMonitor,22),(.pan,22),(.mute,22),(.solo,22)]
        let widths = controls.filter { showsComponent($0.0) && (!vinhetas || $0.0 != .inputMonitor) }.map { $0.1 }
        let width: CGFloat
        switch track.kind {
        case .click: width = 134
        case .teleprompt, .teleprompt2: width = 201
        case .timecode: width = 158
        default: width = widths.reduce(0, +) + CGFloat(max(0, widths.filter { $0 > 0 }.count - 1)) * 3
        }
        let compactCount = draggable ? [TrackMixerComponent.rec, .inputMonitor, .mute, .solo].filter { showsComponent($0) && (!vinhetas || $0 != .inputMonitor) }.count : 2
        let compactWidth = teleprompter ? 172 : CGFloat(max(0, compactCount * 25 - 3))
        return TrackMixerNativePanelContent(
            title: TrackDragTitle(title: title, foreground: color, project: project, track: id, state: draggable ? dragState : nil, select: select,
                editableName: draggable && !vinhetas ? track.name : nil, rename: {
                    show.renameMixerTrack(id, name: $0, project: project)
                }),
            slider: slider, buttons: AnyView(continuousButtons(project: project)),
            compactButtons: AnyView(continuousButtons(project: project, compact: true)),
            compactButtonsWidth: compactWidth, allowsCompactHeight: track.allowsCompactMixerHeight,
            fullHeightCompactButtons: draggable || track.kind == .click,
            phase: vinhetas || !draggable || compactMixerControls || !showsComponent(.phase) ? nil : TrackMixerNativePhase(inverted: track.phaseInverted == true) {
                guard show.snapshot.project.id == project else { return }; show.sendMixerControl(.phase, target: id)
            },
            showsVolume: showsFader, expandedButtonsWidth: width,
            mapVolume: { guard show.snapshot.project.id == project else { return }; ControlMappings.shared.begin(track: id, command: "volume") },
            customComponents: mixerComponentMask != 0,
            compactComponents: compactMixerControls,
            fitsButtonsToAvailableWidth: teleprompter,
            buttonContentKey: TrackMixerButtonContentKey(controller: ObjectIdentifier(show), project: project,
                session: show.projectSessionID, track: track, componentMask: mixerComponentMask, theme: interfaceTheme))
    }
    private func continuousControlSlots(title: String, color: UInt32, project: UUID) -> some View {
            let lowerTitle = track.kind == .standard || track.kind == .video || track.kind == .timecode || track.kind == .click
            return TrackMixerContinuousContainer(meterWidth: showsTrackMeterScale ? 52 : 12,
                                       standard: track.kind == .standard, lowerTitle: lowerTitle) {
                Color.clear.jarasPlaced(at: 0)
                Color.clear.jarasPlaced(at: 1)
                Group {
                    if track.kind == .standard {
                        TrackDragTitle(title: title, foreground: color, project: project, track: track.id, state: dragState, select: select)
                    } else {
                        Text(title).font(.jarasSystem(size: 11, weight: .semibold)).foregroundStyle(Color(hex: color))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .jarasPlaced(at: 2)
                continuousButtons(project: project).jarasPlaced(at: 3)
                Group {
                    if showsFader && lowerTitle {
                        TrackVolumeFader(show: show, track: track.id, volume: track.volume, phaseInverted: track.phaseInverted == true, compact: true, showsPhase: track.kind != .timecode && track.kind != .click && track.role.rawValue != "vinhetas")
                    } else { Color.clear }
                }.clipped().jarasPlaced(at: 4)
                Color.clear.jarasPlaced(at: 5)
                Color.clear.jarasPlaced(at: 6)
            }
    }
    #endif

}
struct GroupTrackConnector: Shape {
    let last: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 5, y: 0))
        path.addLine(to: CGPoint(x: 5, y: last ? 17 : rect.height))
        path.move(to: CGPoint(x: 5, y: 17)); path.addLine(to: CGPoint(x: rect.maxX, y: 17))
        return path
    }
}
private struct MasterTrackContextMenu: View {
    let show: ShowController
    let patch: () -> Void
    let fx: () -> Void
    var masterRight = false
    var moveMaster: (() -> Void)? = nil
    var body: some View {
        Button("Patch", action: patch)
        Button("FX", action: fx)
        #if os(macOS)
        Button("Env") { AutomationWindows.open(show: show, track: nil) }
        #endif
        if let moveMaster {
            Divider()
            Button(LocalizedStringKey(masterRight ? "Mostrar Main à esquerda" : "Mostrar Main à direita"), action: moveMaster)
        }
    }
}

#if os(iOS)
extension View {
    func mainMonoConfirmation(isPresented: Binding<Bool>, mono: Bool, apply: @escaping () -> Void) -> some View {
        alert(LocalizedStringKey(mono ? "Switch Main to Stereo?" : "Switch Main to Mono?"), isPresented: isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Confirm", action: apply)
        }.onChange(of: mono) { _ in isPresented.wrappedValue = false }
    }
}
#endif

struct MasterStrip: View {
    @Environment(\.openFX) private var openFX
    let show: ShowController
    let workspaceButtons: AnyView?
    let footerButtons: AnyView?
    @ObservedObject private var updates: ShowProjectPresentation
    init(show: ShowController, workspaceButtons: AnyView? = nil, footerButtons: AnyView? = nil) {
        self.show = show
        self.workspaceButtons = workspaceButtons
        self.footerButtons = footerButtons
        _updates = ObservedObject(wrappedValue: show.projectPresentation)
    }
    private var foreground: Color { workspaceButtons == nil ? MixerTrackStyle.surfaceText : JarasTheme.text }

    @State private var patchPresented = false
    #if os(iOS)
    @State private var confirmingMainMono = false
    #endif
    var body: some View {
        HStack(spacing: 4) {
            VStack(spacing: 0) {
                if let workspaceButtons {
                    HStack(spacing: 6) {
                        workspaceButtons
                        mainLabel.fixedSize()
                        volumeFader
                    }.frame(height: 27)
                    Spacer(minLength: 0)
                    footerButtons?.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 4) {
                        routingButtons
                        TrackPanKnob(show: show, track: nil, pan: show.snapshot.project.masterPan ?? 0).frame(width: 22, height: 24)
                        Button("M") { show.send(.mute) }.frame(width: 26, height: 24).modifier(MappingRightClick(track: nil, command: "mute")).buttonStyle(CompactTrackButtonStyle(activeColor: show.snapshot.project.masterMute == true ? .red : nil, idleColor: workspaceButtons == nil ? nil : Color(hex: 0x292929))).jarasHelp("Mute")
                        Button("S") { show.send(.solo) }.frame(width: 26, height: 24).modifier(MappingRightClick(track: nil, command: "solo")).buttonStyle(CompactTrackButtonStyle(activeColor: show.snapshot.project.masterSolo == true ? JarasTheme.yellow : nil, idleColor: workspaceButtons == nil ? nil : Color(hex: 0x292929))).jarasHelp("Solo")
                    }.font(.jarasSystem(size: 10, weight: .semibold)).buttonStyle(.bordered).controlSize(.small).frame(height: 24)
                        .frame(maxWidth: .infinity, alignment: workspaceButtons == nil ? .center : .leading)
                    mainLabel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .trailing) { peakReadout.padding(.trailing, 4) }
                    volumeFader
                }
            }.padding(.top, workspaceButtons == nil ? 4 : 1)
                .padding(.bottom, workspaceButtons == nil ? 4 : 9)
        }.padding(.horizontal, workspaceButtons == nil ? 6 : 2)
            .frame(maxWidth: .infinity).frame(height: workspaceButtons == nil ? 70 : nil)
            .background {
                if workspaceButtons == nil { MixerTrackSurface().cornerRadius(6) }
            }
            .contentShape(Rectangle())
            .modifier(MasterMuteIndicator(muted: workspaceButtons == nil && show.snapshot.project.masterMute == true))
            .contextMenu {
                MasterTrackContextMenu(show: show, patch: openPatch,
                    fx: { openFX(nil, "Chain") })
            }
            #if !os(macOS)
            .workspaceEditor("Patch", isPresented: $patchPresented, scrolls: false, size: PatchEditor.windowSize, activates: false) {
                VStack { PatchEditor(show: show, track: nil, targets: [nil]); Button("Close") { patchPresented = false }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            #endif
    }
    private var mainLabel: some View {
        Text("Main").font(.jarasSystem(size: 11, weight: .semibold)).foregroundStyle(foreground)
    }
    private var peakReadout: some View {
        TrackPeakReadout(peak: StemAudioPlayback.shared.masterMeter.peakHold, compact: true, foreground: foreground)
    }
    private var volumeFader: some View {
        TrackVolumeFader(show: show, track: nil, volume: show.snapshot.project.masterVolume ?? 1,
                         phaseInverted: show.snapshot.project.masterPhaseInverted == true, compact: true,
                         showsValue: false,
                         railThickness: MixerMeterStyle.railThickness + (workspaceButtons == nil ? 0 : 3))
            .frame(height: 20)
    }
    @ViewBuilder private var routingButtons: some View {
        Button {
            #if os(iOS)
            confirmingMainMono = true
            #else
            show.send(.masterMono)
            #endif
        } label: {
            ZStack {
                Text("Stereo").lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .opacity(show.snapshot.project.masterMono == true ? 0 : 1)
                if show.snapshot.project.masterMono == true {
                    ZStack {
                        Circle().stroke(lineWidth: 1.3).frame(width: 11, height: 11).offset(x: -3.5)
                        Circle().stroke(lineWidth: 1.3).frame(width: 11, height: 11).offset(x: 3.5)
                    }.accessibilityHidden(true)
                }
            }.frame(minWidth: 40, minHeight: 14)
        }
            .fixedSize(horizontal: true, vertical: false)
            #if os(macOS)
            .buttonStyle(CompactTrackButtonStyle(width: 49))
            #endif
            .foregroundStyle(show.snapshot.project.masterMono == true ? JarasTheme.green : JarasTheme.text)
            .jarasHelp(show.snapshot.project.masterMono == true ? "Mono — switch to Stereo" : "Stereo — switch to Mono").accessibilityLabel("Main Stereo/Mono")
            .accessibilityValue(show.snapshot.project.masterMono == true ? "Mono" : "Stereo")
            #if os(iOS)
            .mainMonoConfirmation(isPresented: $confirmingMainMono, mono: show.snapshot.project.masterMono == true) {
                show.send(.masterMono)
            }
            .onChange(of: show.snapshot.project.id) { _ in confirmingMainMono = false }
            #endif
        #if os(macOS)
        Button("Patch", action: openPatch)
            .buttonStyle(CompactTrackButtonStyle(width: 40))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Main Patch")
        #endif
        if workspaceButtons == nil {
            TrackFXButton(show: show, track: nil, settings: show.snapshot.project.masterFX ?? NativeFXSettings()).jarasHelp("Track")
                #if os(macOS)
                .buttonStyle(CompactTrackButtonStyle(width: 26))
                .fixedSize(horizontal: true, vertical: false)
                #endif
        }
    }
    private func openPatch() {
        #if os(macOS)
        WorkspaceToolWindows.openPatch(show: show, track: nil, targets: [nil])
        #else
        patchPresented = true
        #endif
    }
}
struct PatchButton: View {
    let show: ShowController
    let track: UUID?
    let patch: OutputPatch
    var label = "Patch"
    @State private var presented = false
    var body: some View {
        Button(LocalizedStringKey(label)) {
            #if os(macOS)
            WorkspaceToolWindows.openPatch(show: show, track: track, targets: [track])
            #else
            presented = true
            #endif
        }.jarasHelp("Audio input and output")
        #if !os(macOS)
        .workspaceEditor("Patch", isPresented: $presented, scrolls: false, size: PatchEditor.windowSize, activates: false) {
            PatchEditor(show: show, track: track, targets: [track])
        }
        #endif
    }
}

struct PatchOutputControls: View {
    let outputs: [OutputPatch]
    let outputChoices: [OutputPatch]
    var canAdd = true
    let edit: ((inout [OutputPatch]) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output").font(.jarasSubheadline.bold())
                Spacer()
                Button { edit { $0.append(.none) } } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add output").disabled(!canAdd)
            }
            ForEach(Array(outputs.enumerated()), id: \.offset) { entry in
                let slot = entry.offset
                HStack {
                    Picker("Output", selection: Binding(get: { outputs.indices.contains(slot) ? outputs[slot] : .none }, set: { value in edit { if $0.indices.contains(slot) { $0[slot] = value } } })) {
                        if !outputChoices.contains(entry.element) { Text(entry.element.title + " — " + JarasLocalization.string("Unavailable")).tag(entry.element) }
                        ForEach(outputChoices, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden()
                    Button { edit { if $0.indices.contains(slot) { $0.remove(at: slot) } } } label: { Image(systemName: "minus.circle") }
                        .accessibilityLabel("Remove output")
                }.id("patch-output-\(slot)")
            }
        }
    }
}

private struct PatchSendGainKnob: View {
    let show: ShowController
    let edge: TrackConnection
    let gain: Double
    let enabled: Bool
    let accessibilityName: String
    @State private var previewing = false

    var body: some View {
        knob
            .frame(width: 26, height: 24)
            .disabled(!enabled).allowsHitTesting(enabled).opacity(enabled ? 1 : 0.42)
            .accessibilityLabel(Text(LocalizedStringKey(accessibilityName)))
            .onDisappear {
                if previewing { show.restoreTrackSendGain(edge) }
            }
    }
    @ViewBuilder private var knob: some View {
        #if os(macOS)
        PatchSendGainInput(show: show, edge: edge, gain: gain, accessibilityName: accessibilityName, change: adjust)
        #else
        IpadMixerKnob(value: gain, trackID: edge.source, maximumVolumeDB: 0, preview: { adjust($0, preview: true) }) {
            previewing = false
            show.setTrackSendGain(edge, gain: $0)
        }
        #endif
    }
    private func adjust(_ db: Double, preview: Bool) {
        previewing = preview
        show.setTrackSendGain(edge, gain: db <= -60 ? 0 : pow(10, db / 20), preview: preview)
    }
}

#if os(macOS)
private struct PatchSendGainInput: NSViewRepresentable {
    let show: ShowController
    let edge: TrackConnection
    let gain: Double
    let accessibilityName: String
    let change: (Double, Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> NativeMixerKnobView { NativeMixerKnobView() }
    func updateNSView(_ view: NativeMixerKnobView, context: Context) {
        let project = show.snapshot.project.id, session = show.projectSessionID
        view.bind(project: project, session: session, track: edge.source, pan: false, value: gain, maximumVolumeDB: 0)
        view.setAccessibilityLabel(JarasLocalization.string(accessibilityName))
        view.isEnabled = enabled
        if !enabled { view.cancelGesture() }
        view.changed = { [weak view] db, preview in
            guard view?.isEnabled == true, show.snapshot.project.id == project, show.projectSessionID == session else { return }
            change(db, preview)
        }
    }
}
#endif

struct PatchEditor: View {
    static let windowSize = CGSize(width: 360, height: 520)
    let show: ShowController
    @ObservedObject private var project: ShowProjectPresentation
    @ObservedObject private var recorder = TrackRecording.shared
    let track: UUID?
    let targets: [UUID?]
    @State private var displayedOutputCount = 0
    @ObservedObject private var audio = AudioDeviceSettings.shared
    init(show: ShowController, track: UUID?, targets: [UUID?]) {
        self.show = show
        self.track = track
        self.targets = targets
        _project = ObservedObject(wrappedValue: show.projectPresentation)
    }
    private var settings: Track? {
        guard let track else { return nil }
        return show.current?.tracks.first(where: { $0.id == track })
            ?? show.snapshot.project.songs.lazy.flatMap(\.tracks).first(where: { $0.id == track })
    }
    private var outputs: [OutputPatch] { settings?.outputPatches ?? show.snapshot.project.masterOutputPatches }
    private func routes(_ receive: Bool) -> [UUID?] {
        guard let routing = settings?.routing else { return [] }
        guard receive else { return routing.transmitters }
        return routing.receives.enumerated().map { offset, source in
            offset == routing.mainReceiveSlot ? MultiLoopTrack.masterID : source
        }
    }
    @ViewBuilder private func routeControls(receive: Bool, slot: Int) -> some View {
        if let track, let other = routes(receive)[slot], other != MultiLoopTrack.masterID,
           let song = show.current,
           let source = song.tracks.first(where: { $0.id == (receive ? other : track) }) {
            let destination = receive ? track : other
            let edge = TrackConnection(source: source.id, destination: destination)
            let tap = source.routing?.sendTap(to: destination) ?? .postFader
            Button(tap.isPreFader ? "Pre" : "Pos") {
                show.setTrackSendTap(source.id, destination: destination, tap: tap.isPreFader ? .postFader : .preFader)
            }
            .buttonStyle(CompactTrackButtonStyle(width: 36))
            .jarasHelp(tap.isPreFader ? "Pre-Fader" : "Post-Fader")
            PatchSendGainKnob(show: show, edge: edge, gain: tap.isPreFader ? source.routing?.sendGain(to: destination) ?? 1 : 1,
                              enabled: tap.isPreFader, accessibilityName: receive ? "Receive volume" : "Send volume")
                .id(edge)
        }
    }

    private var outputChoices: [OutputPatch] {
        let allInGroup = !targets.isEmpty && targets.allSatisfy { id in
            id.flatMap { track in show.current?.tracks.first { $0.id == track }?.parentTrackID } != nil
        }
        return OutputPatch.choices(channels: audio.channels, includeMaster: track != nil &&
            (settings?.kind == .standard || settings?.kind == .click || settings?.kind.isTeleprompter == true),
            includeGroup: allInGroup, includeNone: true)
    }
    var body: some View {
        Group {
            if targets.count > 1 && settings?.role.rawValue != "vinhetas" { BatchPatchEditor(show: show, targets: targets.compactMap { $0 }) }
            else { singlePatch }
        }
        #if os(macOS)
        .background(PatchEditorWindowTitle(title: targets.count > 1 ? JarasLocalization.string("Patch") :
            JarasLocalization.string(settings?.kind == .timecode ? "Timecode" : "Patch") + " · " + (settings?.name ?? "Main")))
        #endif
    }
    private var singlePatch: some View {
        let settings = settings
        return ScrollViewReader { scroll in
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: JarasLocalization.string(settings?.kind == .timecode ? "Timecode" : "Patch") + " · " + (settings?.name ?? "Main")).font(.jarasHeadline)
                    if let settings, settings.kind == .timecode { TimecodeOptions(show: show, track: settings) }
                    Text(audio.deviceName).font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                    if let settings, settings.kind == .standard && settings.role.rawValue != "vinhetas" {
                        let input = settings.inputPatch ?? TrackRecording.shared.defaultInputPatch
                        let choices = OutputPatch.choices(channels: TrackRecording.shared.inputChannels, includeMaster: false, includeNone: true).filter { choice in
                            guard let link = settings.stereoLink, choice != .none else { return true }
                            return choice.channelCount == 1 && (link.left ? choice.firstChannel < TrackRecording.shared.inputChannels : choice.firstChannel > 1)
                        }
                        Picker("Input", selection: Binding(get: { input }, set: { applyInput($0) })) {
                            if !choices.contains(input) { Text(input.title + " — " + JarasLocalization.string("Unavailable")).tag(input) }
                            ForEach(choices, id: \.self) { choice in Text(choice.title).tag(choice) }
                        }.disabled(recorder.recording)
                    }
                    if let settings, settings.kind == .standard && settings.role.rawValue != "vinhetas" {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("MIDI input")
                                Picker("MIDI input", selection: Binding(get: { settings.midiInput ?? 0 }, set: { applyMIDI($0) })) {
                                    Text("None").tag(0)
                                    ForEach(0..<6, id: \.self) { slot in Text(audio.midiSlotTitle(slot)).tag(slot + 1) }
                                }.labelsHidden()
                            }.frame(maxWidth: .infinity)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("MIDI channel")
                                Picker("MIDI channel", selection: Binding(get: { settings.midiChannel ?? 0 }, set: { channel in
                                    for id in targets.compactMap({ $0 }) { show.setMIDIChannel(id, channel: channel) }
                                })) {
                                    Text("All channels").tag(0)
                                    ForEach(1...16, id: \.self) { Text(String($0)).tag($0) }
                                }.labelsHidden()
                            }.frame(width: 90)
                        }
                        #if os(macOS)
                        .frame(width: 290)
                        #else
                        .frame(maxWidth: .infinity)
                        #endif
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        PatchOutputControls(outputs: outputs, outputChoices: outputChoices, edit: editOutputs)
                        if settings?.kind == .standard && settings?.role.rawValue != "vinhetas" {
                            ForEach([false, true], id: \.self) { receive in
                                Divider()
                                HStack {
                                    Text(receive ? "Bus" : "Sends").font(.jarasSubheadline.bold())
                                    Spacer()
                                    Button { show.addTrackRoute(Set(targets.compactMap { $0 }), receive: receive) } label: { Image(systemName: "plus") }
                                        .accessibilityLabel(receive ? "Add receive" : "Add transmitter")
                                }
                                ForEach(routes(receive).indices, id: \.self) { slot in
                                    HStack {
                                        Picker(receive ? "Bus" : "Sends", selection: Binding<UUID?>(
                                            get: { routes(receive).indices.contains(slot) ? routes(receive)[slot] : nil },
                                            set: { show.setTrackRouting(Set(targets.compactMap { $0 }), receive: receive, slot: slot, other: $0) })) {
                                            Text("None").tag(Optional<UUID>.none)
                                            if receive { Text(verbatim: "Main").tag(Optional(MultiLoopTrack.masterID)) }
                                            ForEach(show.current?.tracks.filter { $0.kind == .standard && !targets.contains($0.id) } ?? []) { candidate in
                                                Text(verbatim: candidate.name).tag(Optional(candidate.id))
                                            }
                                        }.labelsHidden().disabled(receive && recorder.recording)
                                        routeControls(receive: receive, slot: slot)
                                        Button { show.removeTrackRoute(Set(targets.compactMap { $0 }), receive: receive, slot: slot) } label: { Image(systemName: "minus.circle") }
                                            .accessibilityLabel(receive ? "Remove receive" : "Remove transmitter")
                                    }
                                }
                            }
                        }
                    }
                        #if os(macOS)
                        .frame(width: 290)
                        #else
                        .frame(maxWidth: .infinity)
                        #endif

                }.padding(18).foregroundStyle(JarasTheme.text)
            }
            .onAppear { displayedOutputCount = outputs.count }
            .onChange(of: outputs.count) { count in
                if count > displayedOutputCount { scroll.scrollTo("patch-output-\(count - 1)", anchor: .bottom) }
                displayedOutputCount = count
            }
        }.frame(maxHeight: 560)
        #if os(iOS)
        .background(JarasTheme.background)
        .pickerStyle(.menu).tint(JarasTheme.green)
        #endif
    }
    private func applyInput(_ input: OutputPatch) {
        for id in targets.compactMap({ $0 }) {
            show.setRecordingInput(id, input: input)
        }
    }
    private func applyMIDI(_ slot: Int) { for id in targets.compactMap({ $0 }) { show.setMIDIInput(id, slot: slot) } }
    private func editOutputs(_ change: (inout [OutputPatch]) -> Void) {
        let outputTargets = settings?.role.rawValue == "vinhetas" ? [track] : targets
        for id in outputTargets {
            var values = id.flatMap { id in show.current?.tracks.first { $0.id == id }?.outputPatches } ?? show.snapshot.project.masterOutputPatches
            change(&values); show.setOutputPatches(track: id, patches: values)
        }
    }
}

struct CompactTrackButtonStyle: ButtonStyle {
    var activeColor: Color? = nil
    var width: CGFloat = 22
    var idleColor: Color? = nil
    var fillsRow = false
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if activeColor != nil { configuration.label.foregroundStyle(Color.black) }
            else { configuration.label }
        }.font(.jarasSystem(size: 10, weight: .semibold))
            .frame(width: width, height: fillsRow ? nil : 21)
            .frame(maxHeight: fillsRow ? .infinity : nil)
            .background((activeColor ?? idleColor).map { $0.opacity(configuration.isPressed ? 0.75 : 1) }
                ?? (configuration.isPressed ? Color(hex: 0x282828) : TrackMixerButtonAppearance.trackControl))
            .clipShape(RoundedRectangle(cornerRadius: TrackMixerButtonAppearance.radius)).contentShape(Rectangle())
    }
}
struct TrackControlButtonStyle: ButtonStyle {
    var activeColor: Color? = nil
    var height: CGFloat = 24
    var width: CGFloat? = nil
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.jarasSystem(size: 12, weight: .semibold))
            .padding(.horizontal, 7)
            .frame(minWidth: width ?? 30, maxWidth: width, minHeight: height)
            .background(activeColor.map { $0.opacity(configuration.isPressed ? 0.75 : 1) } ?? JarasTheme.text.opacity(configuration.isPressed ? 0.24 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(JarasTheme.text.opacity(0.18)))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct TeleprompterTrackButtons: View {
    static let textTitle = "Add Text"
    static let lyricsTitle = "Add Lyrics"
    static func addTextLabel(for kind: TrackKind) -> Text {
        kind.isTeleprompter ? Text(verbatim: textTitle) : Text("Add text")
    }
    let openPatch: (() -> Void)?
    let addText: (() -> Void)?
    let addLyrics: (() -> Void)?

    var body: some View {
        GeometryReader { bounds in
            let count = (addText == nil ? 0 : 1) + (addLyrics == nil ? 0 : 1)
            let patchWidth: CGFloat = openPatch == nil ? 0 : 34
            let spacing = CGFloat(max(0, count + (openPatch == nil ? 0 : 1) - 1)) * 3
            let labelWidth = min(100, max(0, (bounds.size.width - patchWidth - spacing) / CGFloat(max(1, count))))
            HStack(spacing: 3) {
                if let openPatch {
                    Button(action: openPatch) { Text("Patch").lineLimit(1).minimumScaleFactor(0.8) }
                        .buttonStyle(CompactTrackButtonStyle(width: patchWidth))
                        .layoutPriority(1)
                }
                if let addText { textButton(Self.textTitle, width: labelWidth, action: addText) }
                if let addLyrics { textButton(Self.lyricsTitle, width: labelWidth, action: addLyrics) }
            }.frame(width: bounds.size.width, height: bounds.size.height, alignment: .trailing)
        }.frame(height: 22)
    }

    private func textButton(_ title: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).lineLimit(1).minimumScaleFactor(0.58)
        }.buttonStyle(TrackControlButtonStyle(height: 22, width: width))
            .frame(width: width).clipped()
    }
}

private struct TrackPanKnob: View {
    private let show: ShowController
    private let track: UUID?
    private let pan: Double
    private let showsTooltip: Bool
    init(show: ShowController, track: UUID?, pan: Double, showsTooltip: Bool = false) {
        self.show = show; self.track = track; self.pan = pan; self.showsTooltip = showsTooltip
    }
    var body: some View {
        #if os(macOS)
        let partner = track.flatMap { id in show.current?.tracks.first { $0.id == id }?.stereoLink?.partner }
        FooterMixerControl(show: show, track: track, value: pan, pan: true, linked: partner, showsPanTooltip: showsTooltip)
        #else
        IpadMixerKnob(value: pan, trackID: track, pan: true, usesMixerPanFace: true, showsPanTooltip: showsTooltip,
            preview: { show.sendMixerControl(.pan, target: track, value: $0, preview: true) }) {
            show.sendMixerControl(.pan, target: track, value: $0)
        }
        #endif
    }
}

enum MixerFaderThumbStyle {
    static let faceTop: UInt32 = 0x513553
    static let faceBottom: UInt32 = 0x402346
    static let rim: UInt32 = 0x9565A0
    static let mark: UInt32 = 0xFFF9FF
    static let outlineWidth: CGFloat = 0.85
    private static let points: [CGPoint] = [
        CGPoint(x: -0.35, y: -0.5), CGPoint(x: 0.35, y: -0.5),
        CGPoint(x: 0.5, y: -0.39), CGPoint(x: 0.29, y: 0),
        CGPoint(x: 0.5, y: 0.39), CGPoint(x: 0.35, y: 0.5),
        CGPoint(x: -0.35, y: 0.5), CGPoint(x: -0.5, y: 0.39),
        CGPoint(x: -0.29, y: 0), CGPoint(x: -0.5, y: -0.39)
    ]

    static func size(vertical: Bool) -> CGSize {
        vertical ? CGSize(width: 18, height: 11) : CGSize(width: 11, height: 18)
    }

    static func markSize(vertical: Bool) -> CGSize {
        vertical ? CGSize(width: 9, height: 1.5) : CGSize(width: 1.5, height: 9)
    }

    static func outline(in bounds: CGRect, vertical: Bool) -> CGPath {
        let face = bounds.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2)
        let polygon = points.map { point in
            CGPoint(x: face.midX + (vertical ? -point.y : point.x) * face.width,
                    y: face.midY + (vertical ? point.x : point.y) * face.height)
        }
        let path = CGMutablePath()
        path.addLines(between: polygon)
        path.closeSubpath()
        return path
    }
}

struct MixerFaderThumb: View {
    let vertical: Bool
    var selected = false

    var body: some View {
        let size = MixerFaderThumbStyle.size(vertical: vertical)
        let mark = MixerFaderThumbStyle.markSize(vertical: vertical)
        let shape = Path(MixerFaderThumbStyle.outline(in: CGRect(origin: .zero, size: size), vertical: vertical))
        shape.fill(LinearGradient(colors: selected ? [JarasTheme.yellow, Color(hex: 0xc99622)]
                                  : [Color(hex: MixerFaderThumbStyle.faceTop), Color(hex: MixerFaderThumbStyle.faceBottom)],
                                  startPoint: .top, endPoint: .bottom))
            .overlay(shape.stroke(selected ? Color(hex: 0xffec9c) : Color(hex: MixerFaderThumbStyle.rim),
                                  style: StrokeStyle(lineWidth: MixerFaderThumbStyle.outlineWidth, lineJoin: .round)))
            .overlay {
                Rectangle().fill(selected ? Color(hex: 0x42310b)
                                 : Color(hex: MixerFaderThumbStyle.mark))
                    .frame(width: mark.width, height: mark.height)
            }
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
    }
}

private struct TrackVolumeFader: View {
    @ObservedObject private var fadeout: TransportFadeout
    @ObservedObject private var loopFaders: MultiLoopFaderPresentation
    let show: ShowController
    let track: UUID?
    let volume: Double
    let phaseInverted: Bool
    var compact = false
    var showsPhase = true
    var showsValue = true
    let railThickness: CGFloat
    // The Master can keep the same gain/pan across documents. Store its
    // project identity as a view input so SwiftUI rebinds the native callbacks
    // even when the ShowController reference and those scalar values match.
    private let controlIdentity: TrackControlIdentity
    init(show: ShowController, track: UUID?, volume: Double, phaseInverted: Bool, compact: Bool = false, showsPhase: Bool = true, showsValue: Bool = true,
         railThickness: CGFloat = MixerMeterStyle.railThickness) {
        self.show = show; self.track = track; self.volume = volume
        self.railThickness = railThickness
        _fadeout = ObservedObject(wrappedValue: show.transportFadeout)
        _loopFaders = ObservedObject(wrappedValue: show.multiLoopFaders)
        self.phaseInverted = phaseInverted; self.compact = compact; self.showsPhase = showsPhase; self.showsValue = showsValue
        controlIdentity = TrackControlIdentity(project: show.snapshot.project.id, track: track)
    }
    private var meter: TrackMeterLevel {
        track.map { StemAudioPlayback.shared.meter(for: $0) } ?? StemAudioPlayback.shared.masterMeter
    }
    @State private var decibels = 0.0
    @State private var dragging = false
    @State private var editingIdentity: TrackControlIdentity?
    @State private var editingSession: UUID?
    private var gain: Double { decibels <= -60 ? 0 : pow(10, decibels / 20) }
    private var displayedDB: Double {
        if dragging && editingIdentity == controlIdentity { return decibels }
        let base = show.automationPlaybackValue(track, kind: .volume).map(TrackEnvelope.gain) ?? volume
        let gain = (loopFaders.frame?.gain(base, project: controlIdentity.project, track: track) ?? base) * fadeout.multiplier(for: track)
        return gain <= 0 ? -60 : min(12, max(-59.9, 20 * log10(gain)))
    }
    var body: some View {
        return HStack(spacing: compact ? 3 : 6) {
            if track == nil && showsValue { gainReadout }
            volumeControl.trackControlSelectionExclusion()
                .frame(height: compact ? 20 : 27)
                .modifier(MappingRightClick(track: track, command: "volume", hitHeight: max(16, railThickness)))
                .frame(maxWidth: .infinity)
                .jarasHelp("Double-click to reset to 0 dB")
                .accessibilityLabel(track == nil ? "Main volume" : "Track volume")
                .accessibilityValue(displayedDB <= -60 ? "−∞ dB" : String(format: "%.1f dB", displayedDB))
            if track != nil && showsValue { gainReadout }
            if let track, showsPhase { PhaseInvertButton(show: show, track: track, inverted: phaseInverted).trackControlSelectionExclusion() }
        }.frame(height: compact ? 20 : 27).padding(.horizontal, 4)
            .onAppear { synchronize() }
            .onChange(of: volume) { _ in if !dragging { synchronize() } }
            .onChange(of: controlIdentity) { identity in
                if editingIdentity != identity { dragging = false; editingSession = nil; synchronize() }
            }
    }
    private var gainReadout: some View {
        Text(displayedDB <= -60 ? "−∞" : String(format: "%+.1f", displayedDB))
            .font(.jarasSystem(size: compact ? 9 : 10, weight: .medium, design: .monospaced))
            .foregroundStyle(JarasTheme.text).frame(width: compact ? 34 : 40, alignment: .leading)
            .contentShape(Rectangle()).onTapGesture(count: 2) { decibels = 0; show.sendMixerControl(.volume, target: track, value: 1) }
            .jarasHelp("Double-click to reset to 0 dB").trackControlSelectionExclusion(selectsTrack: true)
    }
    private var volumeBinding: Binding<Double> {
        Binding(get: { displayedDB }, set: {
            decibels = $0
            show.sendMixerControl(.volume, target: track, value: gain, preview: true)
            if !dragging { show.sendMixerControl(.volume, target: track, value: gain) }
        })
    }
    private func editingChanged(_ editing: Bool) {
        editingIdentity = controlIdentity
        dragging = editing
        if !editing { show.sendMixerControl(.volume, target: track, value: gain) }
    }
    @ViewBuilder private var volumeControl: some View {
        #if os(macOS)
        let identity = controlIdentity
        let session = UUID()
        DirectVolumeSlider(show: show, groupValues: { show.mixerPreviewValues }, identity: identity, value: volume <= 0 ? -60 : min(12, max(-59.9, 20 * log10(volume))), linkedTrack: show.current?.tracks.first(where: { $0.id == track })?.stereoLink?.partner, meter: meter, railThickness: railThickness, changed: { value in
            guard show.snapshot.project.id == identity.project else { return }
            if editingSession == session { decibels = value }
            show.sendMixerControl(.volume, target: track, value: value <= -60 ? 0 : pow(10, value / 20), preview: true)
        }, editingChanged: { editing, value in
            guard show.snapshot.project.id == identity.project else { return }
            if editing {
                editingIdentity = identity; editingSession = session
                decibels = value; dragging = true
            } else {
                if editingSession == session { decibels = value; dragging = false; editingSession = nil }
                show.sendMixerControl(.volume, target: track, value: value <= -60 ? 0 : pow(10, value / 20))
            }
        })
        #else
        NativeTrackVolumeSlider(value: volumeBinding, editingChanged: editingChanged)
            .simultaneousGesture(TapGesture(count: 2).onEnded { decibels = 0; show.sendMixerControl(.volume, target: track, value: 1) })
        #endif
    }
    private func synchronize() { decibels = volume <= 0 ? -60 : min(12, max(-59.9, 20 * log10(volume))) }
}

#if os(iOS)
/// Colour both halves of the rail: Monitor Off remains visible at any gain.
private struct NativeTrackVolumeSlider: UIViewRepresentable {
    @Binding var value: Double
    let editingChanged: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = -60; slider.maximumValue = 12
        slider.addTarget(context.coordinator, action: #selector(Coordinator.begin), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.end), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.parent = self
        if !slider.isTracking { slider.value = Float(value) }
        slider.minimumTrackTintColor = UIColor(JarasTheme.green)
        slider.maximumTrackTintColor = .systemGray4
    }
    final class Coordinator: NSObject {
        var parent: NativeTrackVolumeSlider
        init(_ parent: NativeTrackVolumeSlider) { self.parent = parent }
        @objc func begin() { parent.editingChanged(true) }
        @objc func changed(_ slider: UISlider) { parent.value = Double(slider.value) }
        @objc func end() { parent.editingChanged(false) }
    }
}
#endif

enum MixerPanFace {
    static func draw(value: Double, in bounds: CGRect, context: CGContext) {
        let diameter = max(1, min(18, min(bounds.width, bounds.height) - 2))
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                            width: diameter, height: diameter)
        let angle = (min(1, max(-1, value)) * 135 - 90) * .pi / 180
        let length = diameter * 0.4

        context.saveGState()
        context.setShouldAntialias(true)
        context.setFillColor(gray: 0.18, alpha: 1)
        context.fillEllipse(in: circle)
        context.setStrokeColor(gray: 1, alpha: 0.35)
        context.setLineWidth(1)
        context.strokeEllipse(in: circle)
        context.setStrokeColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        context.setLineWidth(2)
        context.move(to: center)
        context.addLine(to: CGPoint(x: center.x + cos(angle) * length,
                                    y: center.y + sin(angle) * length))
        context.strokePath()
        context.restoreGState()
    }
}

#if os(macOS)
import AppKit
private struct DirectVolumeSlider: NSViewRepresentable {
    @WorkspacePreference(JarasInterfaceTheme.preferenceKey) private var interfaceTheme = JarasInterfaceTheme.defaultTheme
    var show: ShowController? = nil
    var groupValues: (() -> [UUID: Double])? = nil
    let identity: TrackControlIdentity
    let value: Double
    var minimum = -60.0
    var maximum = 12.0
    var mini = false
    var vertical = false
    var rotary = false
    var showsPanTooltip = false
    var linkedTrack: UUID? = nil
    var railTheme: JarasInterfaceTheme? = nil
    var meter: TrackMeterLevel? = nil
    var railThickness = MixerMeterStyle.railThickness
    let changed: (Double) -> Void
    let editingChanged: (Bool, Double) -> Void
    func makeNSView(context: Context) -> DirectVolumeSliderView {
        let slider = DirectVolumeSliderView()
        slider.minValue = minimum; slider.maxValue = maximum
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: DirectVolumeSliderView, context: Context) {
        configure(slider)
    }
    func configure(_ slider: DirectVolumeSliderView) {
        let session = show?.projectSessionID
        slider.rebind(project: identity.project, track: identity.track, session: session)
        slider.minValue = minimum; slider.maxValue = maximum; slider.mini = mini
        slider.vertical = vertical; slider.rotary = rotary
        slider.showsPanTooltip = showsPanTooltip
        slider.linkedTrack = linkedTrack
        slider.railTheme = railTheme ?? interfaceTheme
        slider.railThickness = railThickness
        slider.groupValues = groupValues
        slider.synchronizeModel(value)
        slider.changed = { value in
            guard session == nil || show?.projectSessionID == session else { return }
            changed(value)
        }
        slider.editingChanged = { editing, value in
            guard session == nil || show?.projectSessionID == session else { return }
            editingChanged(editing, value)
        }
        slider.bindAutomation(show)
        slider.bindMeter(meter)
        slider.updateFaderLayers()
    }

    static func dismantleNSView(_ slider: DirectVolumeSliderView, coordinator: ()) {
        slider.finishPointerEditing(deferred: true)
        slider.bindAutomation(nil)
        slider.bindMeter(nil)
    }
}
/// The footer value follows the existing fader mirror path, without publishing
/// a new SwiftUI row or polling the audio meter while the user drags.
private struct FooterMixerGainReadout: NSViewRepresentable {
    let show: ShowController
    let identity: TrackControlIdentity
    let gain: Double
    func makeNSView(context: Context) -> FooterMixerGainLabel { FooterMixerGainLabel() }
    func updateNSView(_ view: FooterMixerGainLabel, context: Context) { view.bind(identity: identity, gain: gain, show: show) }
}
private final class FooterMixerGainLabel: NSView {
    private let screenDrawing = NativeScreenDrawing()
    fileprivate var identity: TrackControlIdentity?
    private var modelGain: Double?
    private var fadeSubscription: AnyCancellable?
    private weak var fadeShow: ShowController?
    private var loopSubscription: AnyCancellable?
    private var automationSubscription: AnyCancellable?
    private var automationActive = false
    private var loopFrame: MultiLoopFaderPresentation.Frame?
    private var fadeRun: TransportFadeout.Run?
    private(set) var stringValue = ""
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.jarasMonospacedSystemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: NSColor.white
    ]
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel("Track volume")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let text = NSMutableAttributedString(string: stringValue, attributes: Self.attributes)
        if text.length >= 3 {
            text.addAttributes([.font: NSFont.jarasSystemFont(ofSize: 7.5, weight: .medium),
                .foregroundColor: NSColor(Color(hex: 0xA1AAB4))], range: NSRange(location: text.length - 3, length: 3))
        }
        screenDrawing.draw(in: self) {
            text.draw(at: NSPoint(x: max(0, (bounds.width - text.size().width) / 2),
                                 y: max(0, (bounds.height - text.size().height) / 2)))
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { VolumeDoubleClickRouter.shared.removeGainLabel(self) }
        else { VolumeDoubleClickRouter.shared.addGainLabel(self) }
    }
    func bind(identity: TrackControlIdentity, gain: Double, show: ShowController? = nil) {
        let active = show?.automationPlaybackValue(identity.track, kind: .volume) != nil
        let rebind = self.identity != identity || fadeShow !== show || automationActive != active
        self.identity = identity
        guard modelGain != gain || rebind else { return }
        modelGain = gain
        if rebind {
            fadeShow = show; automationActive = active
            fadeRun = show?.transportFadeout.run; loopFrame = show?.multiLoopFaders.frame
            fadeSubscription = show?.transportFadeout.$run.sink { [weak self] run in
                self?.fadeRun = run; self?.updateGain()
            }
            loopSubscription = show?.multiLoopFaders.$frame.sink { [weak self] frame in
                self?.loopFrame = frame; self?.updateGain()
            }
            automationSubscription = active ? show?.$snapshot.sink { [weak self] _ in self?.updateGain() } : nil
        }
        updateGain()
    }
    private func updateGain() {
        guard let identity else { return }
        let normalized = fadeShow?.automationPlaybackValue(identity.track, kind: .volume)
        let gain = normalized.map { $0 <= 0 ? 0 : pow(10, (-96 + $0*108)/20) } ?? modelGain ?? 1
        let run = fadeRun?.project == identity.project ? fadeRun : nil
        let factor = identity.track.flatMap { run?.originalVolumes[$0] } == nil ? 1 : run!.fraction
        let displayed = (loopFrame?.gain(gain, project: identity.project, track: identity.track) ?? gain) * factor
        setDecibels(displayed > 0 ? min(12, max(-60, 20 * log10(displayed))) : -60)
    }
    fileprivate func setDecibels(_ value: Double) {
        let text = value <= -60 ? "−∞" : String(format: "%+.1f", value)
        let next = text + " dB"
        if stringValue != next { stringValue = next; needsDisplay = true; setAccessibilityValue(text + " dB") }
    }
}
/// Pan uses the same direct updates as the knob, so dragging does not rebuild
/// the mixer strip just to change its percentage label.
private struct FooterMixerPanReadout: NSViewRepresentable {
    let identity: TrackControlIdentity
    let pan: Double
    let linkedTrack: UUID?
    func makeNSView(context: Context) -> FooterMixerPanLabel { FooterMixerPanLabel() }
    func updateNSView(_ view: FooterMixerPanLabel, context: Context) {
        view.linkedTrack = linkedTrack
        view.bind(identity: identity, pan: pan)
    }
}
private final class FooterMixerPanLabel: NSView {
    private let screenDrawing = NativeScreenDrawing()
    fileprivate var identity: TrackControlIdentity?
    fileprivate var linkedTrack: UUID?
    private var modelPan: Double?
    private(set) var stringValue = ""
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.jarasMonospacedSystemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.white
    ]
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel("Pan")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let text = NSAttributedString(string: stringValue, attributes: Self.attributes)
        screenDrawing.draw(in: self) {
            text.draw(at: NSPoint(x: max(0, (bounds.width - text.size().width) / 2),
                                 y: max(0, (bounds.height - text.size().height) / 2)))
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { VolumeDoubleClickRouter.shared.removePanLabel(self) }
        else { VolumeDoubleClickRouter.shared.addPanLabel(self) }
    }
    func bind(identity: TrackControlIdentity, pan: Double) {
        guard self.identity != identity || modelPan != pan else { return }
        self.identity = identity; modelPan = pan
        setPan(pan)
    }
    fileprivate func setPan(_ value: Double) {
        let next = mixerPanText(value)
        if stringValue != next { stringValue = next; needsDisplay = true; setAccessibilityValue(next) }
    }
}
private final class DirectVolumeSliderView: NSView {
    var railThickness = MixerMeterStyle.railThickness
    private var mainFaderTracking: NSTrackingArea?
    private weak var meter: TrackMeterLevel?
    private var meterSubscription: AnyCancellable?
    private var reductionSubscription: AnyCancellable?
    private var gainReduction = 0.0
    private var levels = SIMD2<Double>.zero
    private lazy var fader = RetainedFaderLayers()

    func bindMeter(_ next: TrackMeterLevel?) {
        let observesReduction = vertical && next != nil
        guard meter !== next || (reductionSubscription != nil) != observesReduction else { return }
        meter = next
        levels = next?.levels ?? .zero
        gainReduction = next?.gainReduction ?? 0
        reductionSubscription = (observesReduction ? next : nil)?.$gainReduction.sink { [weak self] reduction in
            guard let self else { return }
            self.gainReduction = reduction ?? 0
            self.fader.updateReduction(self.gainReduction)
        }
        meterSubscription = next?.$levels.sink { [weak self] levels in
            guard let self else { return }
            self.levels = levels
            self.fader.updateLevels(levels)
        }
        updateFaderLayers()
    }

    private var usesFixedUpperSpan: Bool {
        boundTrack != nil && !vertical && !mini && !rotary && minValue == -60 && maxValue == 12
    }
    fileprivate func updateFaderLayers() {
        guard let layer else { return }
        guard !mini, !rotary else { fader.root.removeFromSuperlayer(); return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        if fader.root.superlayer !== layer { layer.addSublayer(fader.root) }
        let thickness = railThickness
        let rail = vertical
            ? NSRect(x: bounds.midX - thickness / 2, y: 8, width: thickness, height: max(1, bounds.height - 16))
            : NSRect(x: 8, y: bounds.midY - thickness / 2, width: max(1, bounds.width - 16), height: thickness)
        let aligned = backingAlignedRect(rail, options: .alignAllEdgesNearest)
        let normalized = CGFloat(min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))))
        let fraction = usesFixedUpperSpan
            ? HorizontalTrackFaderScale.fraction(decibels: doubleValue, travel: aligned.width) : normalized
        let point = vertical
            ? CGPoint(x: aligned.midX, y: aligned.maxY - fraction * aligned.height)
            : CGPoint(x: aligned.minX + fraction * aligned.width, y: aligned.midY)
        let thumb = MixerFaderThumbStyle.size(vertical: vertical)
        let alignment: AlignmentOptions = .alignAllEdgesNearest
        let frame = backingAlignedRect(CGRect(x: point.x - thumb.width / 2, y: point.y - thumb.height / 2,
                                                width: thumb.width, height: thumb.height), options: alignment)
        let mark = MixerFaderThumbStyle.markSize(vertical: vertical)
        let markFrame = backingAlignedRect(CGRect(x: frame.midX - mark.width / 2, y: frame.midY - mark.height / 2,
                                                    width: mark.width, height: mark.height), options: alignment)
        fader.update(bounds: bounds, rail: aligned, levels: levels, vertical: vertical, fixedUpperSpan: usesFixedUpperSpan,
            theme: railTheme, linked: linkedTrack != nil, scale: window?.backingScaleFactor ?? 1,
            thumb: frame, mark: markFrame, reduction: gainReduction)
    }

    // Meter movement changes retained layer geometry. The fader is no longer
    // rasterized to a new 2× bitmap on every position or meter sample.
    private final class RetainedFaderLayers {
        let root = CALayer()
        private let rail = MixerRailLayers(flipped: true)
        private let reductionRail = CALayer()
        private let reductionFill = CALayer()
        private let rim = CAShapeLayer()
        private let face = CAGradientLayer()
        private let faceMask = CAShapeLayer()
        private let markLayer = CALayer()
        init() {
            root.addSublayer(rail.layer)
            reductionRail.backgroundColor = CGColor(gray: 0, alpha: 0.6)
            reductionRail.cornerRadius = 1
            reductionRail.masksToBounds = true
            reductionFill.backgroundColor = MixerMeterStyle.clippingColor
            reductionFill.cornerRadius = 1
            reductionFill.actions = ["bounds": NSNull(), "position": NSNull()]
            reductionRail.addSublayer(reductionFill)
            root.addSublayer(reductionRail)
            face.colors = [MixerMeterStyle.cgColor(MixerFaderThumbStyle.faceBottom),
                           MixerMeterStyle.cgColor(MixerFaderThumbStyle.faceTop)]
            face.mask = faceMask
            rim.fillColor = nil
            rim.strokeColor = MixerMeterStyle.cgColor(MixerFaderThumbStyle.rim)
            rim.lineWidth = MixerFaderThumbStyle.outlineWidth
            rim.lineJoin = .round
            markLayer.backgroundColor = MixerMeterStyle.cgColor(MixerFaderThumbStyle.mark)
            root.addSublayer(face)
            root.addSublayer(rim)
            root.addSublayer(markLayer)
        }

        // Meter samples move only the channel fills. AppKit commits the layer
        // changes for all tracks together at the next display update.
        func updateLevels(_ levels: SIMD2<Double>) { rail.updateLevels(levels) }
        func updateReduction(_ reduction: Double) {
            let fill = MixerMeterStyle.gainReductionFill(in: reductionRail.bounds, db: reduction)
            if reductionFill.frame != fill { reductionFill.frame = fill }
        }
        func update(bounds: CGRect, rail frame: CGRect, levels: SIMD2<Double>, vertical: Bool, fixedUpperSpan: Bool,
                    theme: JarasInterfaceTheme, linked: Bool, scale: CGFloat, thumb: CGRect, mark: CGRect, reduction: Double) {
            let actionsDisabled = CATransaction.disableActions()
            CATransaction.setDisableActions(true)
            defer { CATransaction.setDisableActions(actionsDisabled) }
            if root.frame != bounds { root.frame = bounds }
            rail.update(size: frame.size, levels: levels, linked: linked, theme: theme,
                        fixedUpperSpan: fixedUpperSpan, vertical: vertical)
            if rail.layer.frame != frame { rail.layer.frame = frame }
            let border = 1 / scale
            rail.layer.borderWidth = border
            reductionRail.isHidden = !vertical
            if vertical {
                let rect = MixerMeterStyle.gainReductionRail(in: bounds, near: frame, vertical: true)
                if reductionRail.frame != rect { reductionRail.frame = rect }
                updateReduction(reduction)
            }
            if rim.bounds.size != thumb.size {
                let path = MixerFaderThumbStyle.outline(in: CGRect(origin: .zero, size: thumb.size), vertical: vertical)
                rim.path = path
                faceMask.frame = CGRect(origin: .zero, size: thumb.size)
                faceMask.path = path
            }
            if rim.frame != thumb { rim.frame = thumb; face.frame = thumb }
            if rim.contentsScale != scale { rim.contentsScale = scale; faceMask.contentsScale = scale }
            if markLayer.frame != mark { markLayer.frame = mark }
        }
    }

    private var automationSubscription: AnyCancellable?
    private var fadeSubscription: AnyCancellable?
    private var loopSubscription: AnyCancellable?
    private var loopFrame: MultiLoopFaderPresentation.Frame?
    private var fadeRun: TransportFadeout.Run?
    private var showingPlaybackGain = false
    private weak var automationShow: ShowController?
    private var automationKey = ""
    func bindAutomation(_ show: ShowController?) {
        let kind: AutomationTarget.Kind = mini ? .pan : .volume
        let active = show?.automationPlaybackValue(boundTrack, kind: kind) != nil
        let key = "\(boundProject?.uuidString ?? "")/\(boundTrack?.uuidString ?? "master")/\(mini)/\(active)"
        guard automationShow !== show || automationKey != key else {
            updatePlaybackGain(); return
        }
        automationSubscription = nil; fadeSubscription = nil; loopSubscription = nil
        automationShow = show; automationKey = key
        fadeRun = show?.transportFadeout.run; loopFrame = show?.multiLoopFaders.frame
        if let show, !mini {
            fadeSubscription = show.transportFadeout.$run.sink { [weak self] run in
                self?.fadeRun = run; self?.updatePlaybackGain()
            }
            loopSubscription = show.multiLoopFaders.$frame.sink { [weak self] frame in
                self?.loopFrame = frame; self?.updatePlaybackGain()
            }
        }
        guard active, let show else { return }
        automationSubscription = show.$snapshot.sink { [weak self, weak show] _ in
            guard let self, let show, !self.trackingPointer,
                  let normalized = show.automationPlaybackValue(self.boundTrack, kind: kind) else { return }
            if !self.mini { self.updatePlaybackGain(); return }
            let value = normalized*2-1
            guard abs(value-self.doubleValue) > 0.00001 else { return }
            self.pendingModelValue = nil; self.lastModelValue = nil
            self.doubleValue = value
            if !show.transportFadeout.active { VolumeDoubleClickRouter.shared.mirror(self) }
        }
    }
    private func updatePlaybackGain() {
        guard !mini, !trackingPointer, mirroredSource?.trackingPointer != true,
              let show = automationShow, let project = boundProject else { return }
        let run = fadeRun?.project == project ? fadeRun : nil
        let selected = boundTrack.flatMap { run?.originalVolumes[$0] } != nil
        let loopSelected = loopFrame?.project == project && loopFrame?.targets[boundTrack] != nil
        let normalized = show.automationPlaybackValue(boundTrack, kind: .volume)
        guard selected || loopSelected || showingPlaybackGain || normalized != nil else { return }
        showingPlaybackGain = selected || loopSelected || normalized != nil
        let baseline = committedModelValue ?? 0
        let manual = normalized.map { $0 <= 0 ? 0 : pow(10, (-96 + $0*108)/20) } ?? (baseline <= -60 ? 0 : pow(10, baseline/20))
        let gain = (loopFrame?.gain(manual, project: project, track: boundTrack) ?? manual) * (selected ? run!.fraction : 1)
        let value = gain <= 0 ? -60 : min(12, max(-59.9, 20 * log10(gain)))
        if abs(value - doubleValue) > 0.000001 { doubleValue = value }
    }
    var groupValues: (() -> [UUID: Double])?
    var mini = false { didSet { updatePanAccessibilityHelp() } }
    var vertical = false
    var rotary = false
    private var rotaryOrigin = NSPoint.zero
    private var rotaryValue = 0.0
    var minValue = -60.0
    var maxValue = 12.0
    var isEnabled = true
    private var committedModelValue: Double?
    private var lastModelValue: Double?
    private var pendingModelValue: Double?
    private var pendingModelDeadline = 0.0
    fileprivate var boundProject: UUID?
    fileprivate var boundTrack: UUID?
    fileprivate var boundSession: UUID?
    var linkedTrack: UUID?
    var railTheme = JarasInterfaceTheme.defaultTheme
    fileprivate weak var mirroredSource: DirectVolumeSliderView?
    func rebind(project: UUID, track: UUID?, session: UUID? = nil) {
        guard boundProject != project || boundTrack != track || boundSession != session else { return }
        finishPointerEditing(deferred: true)
        boundProject = project; boundTrack = track; boundSession = session
        lastModelValue = nil; pendingModelValue = nil; mirroredSource = nil
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }
    // A SwiftUI redraw carrying the same committed value is not a new volume
    // command. Preserve the pointer value until a genuinely new model arrives.
    func synchronizeModel(_ value: Double) {
        committedModelValue = value
        guard !trackingPointer, mirroredSource?.trackingPointer != true else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let pendingModelValue {
            if abs(value - pendingModelValue) <= 0.000001 { self.pendingModelValue = nil }
            else if now < pendingModelDeadline { return }
            else { self.pendingModelValue = nil }
        }
        if let source = mirroredSource, source.pendingModelValue != nil,
           now < source.pendingModelDeadline, abs(value - doubleValue) > 0.000001 { return }
        guard value != lastModelValue else { return }
        lastModelValue = value
        doubleValue = value
    }
    var valueDidChange: ((Double) -> Void)?
    var showsPanTooltip = false
    var doubleValue = 0.0 {
        didSet {
            if mini || rotary { needsDisplay = true }
            else { updateFaderLayers() }
            updatePanAccessibilityHelp(); valueDidChange?(doubleValue)
        }
    }
    private func updatePanAccessibilityHelp() {
        let value = mini ? mixerPanText(doubleValue) : nil
        setAccessibilityHelp(value)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: vertical ? NSView.noIntrinsicMetric : (rotary ? 24 : 27)) }
    override var wantsUpdateLayer: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized {
            if mini || rotary { needsDisplay = true }
            else { updateFaderLayers() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)
        if rotary { MixerPanFace.draw(value: doubleValue, in: bounds, context: context); return }
        guard mini else { updateFaderLayers(); return }
        let normalized = min(1, max(0, (doubleValue - minValue) / (maxValue - minValue)))
        let rail = NSRect(x: 5, y: bounds.midY - 1.5, width: max(1, bounds.width - 10), height: 3)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rail, xRadius: 1.5, yRadius: 1.5).fill()
        NSColor.white.withAlphaComponent(0.45).setFill()
        NSRect(x: bounds.midX - 0.5, y: bounds.midY - 5, width: 1, height: 10).fill()
        let x = rail.minX + CGFloat(normalized) * rail.width
        NSColor(white: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - 5, y: bounds.midY - 7, width: 10, height: 14), xRadius: 2, yRadius: 2).fill()
        NSColor(white: 0.6, alpha: 1).setFill()
        NSRect(x: x - 0.5, y: bounds.midY - 5, width: 1, height: 10).fill()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if mini || rotary { needsDisplay = true }
        else { updateFaderLayers() }
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.keyCode == 123 || event.keyCode == 124 {
            beginPointerEditing()
            doubleValue = min(maxValue, max(minValue, doubleValue + (event.keyCode == 124 ? 1 : -1) * (mini ? 0.05 : 0.5)))
            publishPointerValue(); finishPointerEditing()
        } else { super.keyDown(with: event) }
    }
    var changed: ((Double) -> Void)?
    var editingChanged: ((Bool, Double) -> Void)?
    private var pointerChanged: ((Double) -> Void)?
    private var pointerEditingChanged: ((Bool, Double) -> Void)?
    private(set) var trackingPointer = false
    private func beginPointerEditing() {
        guard !trackingPointer else { return }
        pendingModelValue = nil
        trackingPointer = true
        pointerChanged = changed
        pointerEditingChanged = editingChanged
        pointerEditingChanged?(true, doubleValue)
    }
    func finishPointerEditing(deferred: Bool = false) {
        guard trackingPointer else { return }
        // Capture the original target and actual pointer value before SwiftUI
        // dismantles or reuses the view. Never publish during its layout pass.
        let completion = pointerEditingChanged, value = doubleValue
        pendingModelValue = value
        pendingModelDeadline = ProcessInfo.processInfo.systemUptime + 2
        trackingPointer = false
        pointerChanged = nil; pointerEditingChanged = nil
        if deferred { DispatchQueue.main.async { completion?(false, value) } }
        else { completion?(false, value) }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil && newWindow !== window { finishPointerEditing(deferred: true) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { VolumeDoubleClickRouter.shared.add(self) }
        else { CompactTrackValueTooltip.shared.hide(for: self) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mainFaderTracking { removeTrackingArea(mainFaderTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        mainFaderTracking = area
    }
    override func mouseEntered(with event: NSEvent) { showControlValue(event) }
    override func mouseMoved(with event: NSEvent) { showControlValue(event) }
    override func mouseExited(with event: NSEvent) {
        if !trackingPointer { CompactTrackValueTooltip.shared.hide(for: self) }
    }
    fileprivate func showControlValue(_ event: NSEvent) {
        let value: String
        if mini && showsPanTooltip {
            value = mixerPanText(doubleValue)
        } else if boundTrack == nil && !vertical && !mini && !rotary {
            value = doubleValue <= -60 ? "−∞ dB" : String(format: "%+.1f dB", doubleValue)
        } else { return }
        CompactTrackValueTooltip.shared.show(value, owner: self, point: event.locationInWindow)
    }
    func resetToUnity() {
        beginPointerEditing()
        doubleValue = 0
        publishPointerValue()
        finishPointerEditing()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            resetToUnity()
        } else {
            beginPointerEditing()
            rotaryOrigin = convert(event.locationInWindow, from: nil); rotaryValue = doubleValue
            move(to: event)
        }
        showControlValue(event)
    }
    override func mouseDragged(with event: NSEvent) {
        if trackingPointer { move(to: event); showControlValue(event) }
    }
    override func mouseUp(with event: NSEvent) {
        finishPointerEditing()
        if !bounds.contains(convert(event.locationInWindow, from: nil)) { CompactTrackValueTooltip.shared.hide(for: self) }
    }
    private func publishPointerValue() {
        pointerChanged?(doubleValue)
        VolumeDoubleClickRouter.shared.mirror(self)
    }
    private func move(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let knobWidth: CGFloat = mini ? 10 : 16
        let inset = knobWidth / 2
        if rotary {
            doubleValue = min(maxValue, max(minValue, rotaryValue + Double(rotaryOrigin.y - point.y + point.x - rotaryOrigin.x) * (maxValue - minValue) / 160))
            publishPointerValue(); return
        }
        let fraction = vertical
            ? min(1, max(0, 1 - (point.y - inset) / max(1, bounds.height - knobWidth)))
            : min(1, max(0, (point.x - inset) / max(1, bounds.width - knobWidth)))
        doubleValue = usesFixedUpperSpan
            ? HorizontalTrackFaderScale.decibels(fraction: fraction, travel: bounds.width - knobWidth)
            : minValue + Double(fraction) * (maxValue - minValue)
        publishPointerValue()
        needsDisplay = true
    }
}
@MainActor private final class VolumeDoubleClickRouter {
    static let shared = VolumeDoubleClickRouter()
    private let sliders = NSHashTable<DirectVolumeSliderView>.weakObjects()
    private let gainLabels = NSHashTable<FooterMixerGainLabel>.weakObjects()
    private let panLabels = NSHashTable<FooterMixerPanLabel>.weakObjects()
    private var monitor: Any?
    func addGainLabel(_ label: FooterMixerGainLabel) { gainLabels.add(label) }
    func removeGainLabel(_ label: FooterMixerGainLabel) { gainLabels.remove(label) }
    func addPanLabel(_ label: FooterMixerPanLabel) { panLabels.add(label) }
    func removePanLabel(_ label: FooterMixerPanLabel) { panLabels.remove(label) }
    func mirror(_ source: DirectVolumeSliderView) {
        let group = source.groupValues?() ?? [:]
        for target in sliders.allObjects where target !== source && target.window != nil &&
            target.boundProject == source.boundProject && target.boundSession == source.boundSession && target.mini == source.mini && !target.trackingPointer {
            let same = target.boundTrack == source.boundTrack
            let partner = source.linkedTrack != nil && target.boundTrack == source.linkedTrack && target.linkedTrack == source.boundTrack
            let grouped = target.boundTrack.flatMap { group[$0] }
            guard same || partner || grouped != nil else { continue }
            target.mirroredSource = source
            if let grouped {
                target.doubleValue = source.mini ? grouped : (grouped <= 0 ? -60 : min(12, max(-59.9, 20 * log10(grouped))))
            } else { target.doubleValue = partner && source.mini ? -source.doubleValue : source.doubleValue }
            target.displayIfNeeded()
        }
        if source.mini {
            for label in panLabels.allObjects where label.window != nil && label.identity?.project == source.boundProject {
                let grouped = label.identity?.track.flatMap { group[$0] }
                let partner = source.linkedTrack != nil && label.identity?.track == source.linkedTrack && label.linkedTrack == source.boundTrack
                if let grouped { label.setPan(grouped) }
                else if label.identity?.track == source.boundTrack { label.setPan(source.doubleValue) }
                else if partner { label.setPan(-source.doubleValue) }
            }
        } else {
            for label in gainLabels.allObjects where label.window != nil && label.identity?.project == source.boundProject {
                let grouped = label.identity?.track.flatMap { group[$0] }
                if let grouped { label.setDecibels(grouped > 0 ? min(12, max(-60, 20 * log10(grouped))) : -60) }
                else if label.identity?.track == source.boundTrack { label.setDecibels(source.doubleValue) }
            }
        }
    }

    func add(_ slider: DirectVolumeSliderView) {
        sliders.add(slider)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard event.clickCount >= 2, !event.modifierFlags.contains(.control),
                  let window = event.window, window.attachedSheet == nil,
                  let slider = self?.sliders.allObjects.first(where: {
                      $0.window === window && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor &&
                      $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) &&
                      $0.visibleRect.contains($0.convert(event.locationInWindow, from: nil))
                  }) else { return event }
            slider.resetToUnity()
            slider.showControlValue(event)
            return nil
        }
    }
}

#endif

/// One insertion indicator for the entire drag, including cancellation outside a row.
private final class TrackReorderState: ObservableObject {
    static let shared = TrackReorderState()
    static let type = UTType.text
    static func provider(_ id: UUID) -> NSItemProvider {
        NSItemProvider(object: ("jaras-track:" + id.uuidString) as NSString)
    }
    @Published var target: UUID?
    @Published var blockedTarget: UUID?
    @Published var after = false
    @Published private(set) var joinsGroup = false
    private(set) var hoveredTrack: UUID?
    var indicatorColor: Color { joinsGroup ? JarasTheme.yellow : JarasTheme.green }
    @Published private(set) var active = false
    #if os(macOS)
    var source: TrackDragSource?
    #endif
    private(set) var draggedTrack: UUID?
    func begin(track: UUID) { finish(); draggedTrack = track; active = true }
    func indicate(_ id: UUID, after: Bool, joinsGroup: Bool, hoveredTrack: UUID? = nil) {
        guard active else { return }
        self.hoveredTrack = hoveredTrack ?? id
        if blockedTarget != nil { blockedTarget = nil }
        if target != id { target = id }
        if self.after != after { self.after = after }
        if self.joinsGroup != joinsGroup { self.joinsGroup = joinsGroup }
    }
    func reject(_ id: UUID) { hoveredTrack = id; target = nil; blockedTarget = id }
    func leave(_ id: UUID) {
        guard hoveredTrack == id else { return }
        target = nil; blockedTarget = nil; hoveredTrack = nil
    }
    func finish() {
        active = false; target = nil; blockedTarget = nil; draggedTrack = nil; hoveredTrack = nil
        #if os(macOS)
        source = nil
        #endif
    }
}

private struct TrackInsertionDrop: DropDelegate {
    let show: ShowController
    let track: UUID
    let nextTrack: UUID?
    let height: CGFloat
    let state: TrackReorderState
    var horizontal = false
    private func after(_ info: DropInfo) -> Bool { (horizontal ? info.location.x : info.location.y) > height / 2 }
    // The existing indentation gutter chooses an insertion outside the folder.
    // In the horizontal mixer the equivalent gutter is the top of the strip.
    private func outsideGroup(_ info: DropInfo) -> Bool { (horizontal ? info.location.y : info.location.x) < 16 }
    func validateDrop(info: DropInfo) -> Bool { state.active && info.hasItemsConforming(to: [TrackReorderState.type]) }
    private func allowed(_ info: DropInfo) -> Bool { state.draggedTrack.map { show.canDropTrack($0, on: track, after: after(info)) } ?? false }
    private func indicate(_ info: DropInfo) {
        let outside = outsideGroup(info)
        let joins = state.draggedTrack.map { show.trackDropJoinsGroup($0, on: track, after: after(info), outsideGroup: outside) } ?? false
        let destination = state.draggedTrack.flatMap {
            show.current?.normalTrackDropDestination($0, on: track, after: after(info), outsideGroup: outside)
        }
        state.indicate(destination?.indicatorTrack ?? track, after: destination?.after ?? after(info), joinsGroup: joins, hoveredTrack: track)
    }
    func dropEntered(info: DropInfo) {
        if allowed(info) { indicate(info) }
        else { state.reject(track) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard state.active && allowed(info) else { state.reject(track); return DropProposal(operation: .forbidden) }
        indicate(info); return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {
        state.leave(track)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard state.active, allowed(info), let id = state.draggedTrack,
              info.hasItemsConforming(to: [TrackReorderState.type]) else { state.finish(); return false }
        let before = after(info) ? nextTrack : track
        let outside = outsideGroup(info)
        // This is an internal drag: its validated track is already available.
        // Loading a String asynchronously from AppKit's pasteboard can fail
        // silently after the drag source has been released, leaving an accepted
        // insertion indicator with no model edit.
        // Commit in this event, before clearing the local drag session.
        defer { state.finish() }
        show.dropTrack(id, on: track, before: before, outsideGroup: outside)
        return true
    }
}
/// Keep a visible rejection badge even on systems whose native drag cursor
/// displays only an arrow for a forbidden SwiftUI drop.
private struct TrackDropBlockedBadge: View {
    var body: some View {
        Image(systemName: "nosign").font(.jarasSystem(size: 18, weight: .bold))
            .foregroundStyle(Color.red).padding(5).background(Color.black.opacity(0.85), in: Circle())
            .allowsHitTesting(false).accessibilityLabel("Drop not allowed")
    }
}
/// Shares the Track Mixer drag session; FX slots keep their own drop handlers.
private struct FooterTrackInsertion: ViewModifier {
    let show: ShowController
    let track: UUID?
    @ObservedObject private var state = TrackReorderState.shared
    @ViewBuilder func body(content: Content) -> some View {
        if let track {
            let tracks = (show.current?.tracks ?? []).filter { $0.kind == .standard }
            let next = tracks.firstIndex(where: { $0.id == track }).flatMap { index in
                index + 1 < tracks.count ? tracks[index + 1].id : nil
            }
            content
                #if os(macOS)
                // Drop geometry depends on window coordinates. Register it only
                // during a track drag, not on every ordinary horizontal scroll.
                // Keep the controls' identity stable when the receiver appears.
                .background {
                    if state.active {
                        Color.clear.onDrop(of: [TrackReorderState.type], delegate: TrackInsertionDrop(show: show,
                            track: track, nextTrack: next, height: FooterMixerMetrics.width, state: state, horizontal: true))
                    }
                }
                #else
                .onDrop(of: [TrackReorderState.type], delegate: TrackInsertionDrop(show: show,
                    track: track, nextTrack: next, height: FooterMixerMetrics.width, state: state, horizontal: true))
                #endif
                .overlay(alignment: state.after ? .trailing : .leading) {
                    if state.target == track {
                        Rectangle().fill(state.indicatorColor).frame(width: 3)
                            .shadow(color: state.indicatorColor, radius: 4).allowsHitTesting(false)
                    }
                }
                .overlay { if state.blockedTarget == track { TrackDropBlockedBadge() } }
        } else { content }
    }

}
private extension View {
    @ViewBuilder func trackControlSelectionExclusion(selectsTrack: Bool = false) -> some View {
        #if os(macOS)
        background(TrackControlSelectionExclusion(selectsTrack: selectsTrack))
        #else
        self
        #endif
    }
}
#if os(macOS)
private struct TrackRightClickInput: NSViewRepresentable {
    @Environment(\.gridInteractionBlocked) private var interactionBlocked
    let project: UUID
    let track: UUID
    let kind: TrackKind
    var dragName = ""
    var selected = false
    let select: () -> Void
    let patch: () -> Void
    let fx: () -> Void
    var edit: (() -> Void)?
    var randomColor: (() -> Void)? = nil
    var icon: (() -> Void)? = nil
    let group: (() -> Void)?
    let ungroup: (() -> Void)?
    var removeFromGroup: (() -> Void)? = nil
    var link: (() -> Void)? = nil
    var unlink: (() -> Void)? = nil
    var soundDesigner: (() -> Void)? = nil
    var createMIDI: (() -> Void)? = nil
    var duplicateTracks: (() -> Void)? = nil
    var deleteTracks: (() -> Void)? = nil
    var deleteTrackCount = 1
    var cursorMix: ((ProGridTool) -> Void)? = nil
    var envelope: (() -> Void)? = nil
    var stemLayout: Bool? = nil
    var organizeStems: ((Bool?) -> Void)? = nil
    var componentMask: (() -> Int)? = nil
    var componentChoices = TrackMixerComponent.allCases
    var toggleComponent: ((TrackMixerComponent) -> Void)? = nil
    var cancelScan: (() -> Void)? = nil
    var hozComponentMask: (() -> Int)? = nil
    var toggleHozComponent: ((HozMixerComponent) -> Void)? = nil
    func makeNSView(context: Context) -> TrackRightClickView { TrackRightClickView() }
    func updateNSView(_ view: TrackRightClickView, context: Context) {
        view.interactionBlocked = interactionBlocked; view.project = project; view.track = track; view.kind = kind; view.dragName = dragName; view.selected = selected; view.select = select; view.patch = patch; view.fx = fx; view.edit = edit; view.icon = icon; view.group = group; view.ungroup = ungroup; view.removeFromGroup = removeFromGroup; view.link = link; view.unlink = unlink; view.soundDesigner = soundDesigner; view.createMIDI = createMIDI; view.duplicateTracks = duplicateTracks; view.deleteTracks = deleteTracks; view.deleteTrackCount = deleteTrackCount
        view.randomColor = randomColor
        view.stemLayout = stemLayout; view.organizeStems = organizeStems
        view.cursorMix = cursorMix; view.envelope = envelope; view.componentMask = componentMask; view.componentChoices = componentChoices; view.toggleComponent = toggleComponent; view.cancelScan = cancelScan
        view.hozComponentMask = hozComponentMask; view.toggleHozComponent = toggleHozComponent
        view.action = { [weak view] in view?.openMenu() }
    }
}
/// Resolve one row per click, including after native scroll hosting recycles rows.
/// The title also calls this route directly, so selecting it never relies solely
/// on a passive event monitor. Both paths share the event to avoid double toggles.
struct TrackControlSelectionExclusion: NSViewRepresentable {
    var selectsTrack = false
    func makeNSView(context: Context) -> TrackControlSelectionExclusionView { TrackControlSelectionExclusionView() }
    func updateNSView(_ view: TrackControlSelectionExclusionView, context: Context) { view.selectsTrack = selectsTrack }
}
final class TrackControlSelectionExclusionView: NSView, NativeTimelineInputObserver {
    var selectsTrack = false
    private weak var mixerInput: TrackMixerNativeControlView?
    private weak var defaultCursorHost: NSView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() {
        guard let window, window.attachedSheet == nil, !NativeTimelineInputGate.shared.isBlocked(window),
              !isHiddenOrHasHiddenAncestor else { return }
        let rect = bounds.intersection(visibleRect)
        guard !rect.isEmpty else { return }
        // The workspace already supplies this default. Rebuilding an arrow
        // for each control during unrelated timeline scrolling repeats AppKit
        // cursor-area registrations. Standalone mixers retain their own area.
        if let host = defaultCursorHost, host.window === window, isDescendant(of: host),
           host.bounds.intersection(host.visibleRect).contains(host.convert(rect, from: self)) { return }
        defaultCursorHost = nil
        var ancestor = superview
        while let view = ancestor {
            if view is NativeTimelineDefaultCursorHost,
               view.bounds.intersection(view.visibleRect).contains(view.convert(rect, from: self)) {
                // Recheck ancestry and live coverage on every reset, but avoid
                // repeating Swift protocol discovery through the hosting tree.
                defaultCursorHost = view
                return
            }
            ancestor = view.superview
        }
        addCursorRect(rect, cursor: .arrow)
    }
    func timelineInputGateChanged(blocked: Bool) {
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            TrackSelectionRouter.shared.addControl(self)
            NativeTimelineInputGate.shared.add(self)
        }
        updateMixerInput()
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); updateMixerInput() }
    private func updateMixerInput() {
        var ancestor = window == nil ? nil : superview
        while let view = ancestor, !(view is TrackMixerNativeControlView) { ancestor = view.superview }
        let next = ancestor as? TrackMixerNativeControlView
        guard mixerInput !== next else { return }
        mixerInput?.removeControlArea(self)
        mixerInput = next
        mixerInput?.addControlArea(self)
    }
}
@MainActor final class TrackSelectionRouter {
    static let shared = TrackSelectionRouter()
    private let rows = NSHashTable<TrackRightClickView>.weakObjects()
    private let controls = NSHashTable<NSView>.weakObjects()
    private let titles = NSHashTable<TrackDragTitleView>.weakObjects()
    fileprivate weak var editingTitle: TrackDragTitleView?
    private var monitor: Any?
    private var lastEventTime: TimeInterval?
    private var pressedTrack: UUID?
    private var pendingSelection: (() -> Void)?
    private var pointerMoved = false
    private var handledDownTime: TimeInterval?
    private weak var dragRow: TrackRightClickView?
    private var dragStart: NSPoint?
    private var dragProject: UUID?
    private var menuTracks = Set<UUID>()
    private var sessionGeneration: UInt64 = 0
    func resetProjectSession() {
        editingTitle?.finishRename(save: false)
        sessionGeneration &+= 1
        lastEventTime = nil; pressedTrack = nil; dragRow = nil; dragStart = nil; dragProject = nil
        menuTracks.removeAll(); selectionModifiers = nil; pendingSelection = nil; handledDownTime = nil
    }
    /// A reused row must retain the track that owns an in-flight button press.
    var pinnedTracks: Set<UUID> { menuTracks.union(pressedTrack.map { [$0] } ?? []) }
    private(set) var selectionModifiers: NSEvent.ModifierFlags?
    func addControl(_ view: NSView) { controls.add(view) }
    fileprivate func addTitle(_ view: TrackDragTitleView) { titles.add(view); startMonitoring() }
    fileprivate func add(_ row: TrackRightClickView) {
        rows.add(row)
        startMonitoring()
    }
    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                self?.editingTitle?.finishRenameIfOutside(event)
            }
            if event.type == .leftMouseDown, event.clickCount == 2, self?.renameTitle(at: event) == true { return nil }
            if event.type == .leftMouseDragged, self?.beginEmptyAreaDrag(event) == true { return nil }
            self?.handle(event)
            return event
        }
    }
    fileprivate func moveRename(from source: TrackDragTitleView, direction: Int) {
        guard let window = source.window, let scroll = source.enclosingScrollView else { return }
        func position(_ view: TrackDragTitleView) -> CGFloat {
            let point = view.convert(view.bounds.origin, to: nil)
            return source.compact ? point.x : -point.y
        }
        let origin = position(source)
        var nearest: (title: TrackDragTitleView, distance: CGFloat)?
        for title in titles.allObjects {
            guard title.window === window, title.compact == source.compact,
                  title.project == source.project, title.track != source.track, title.interactionEnabled,
                  title.editableName != nil, title.rename != nil,
                  !title.isHiddenOrHasHiddenAncestor, title.enclosingScrollView === scroll else { continue }
            let distance = (position(title) - origin) * CGFloat(direction)
            if distance > 0.5 && distance < (nearest?.distance ?? .infinity) {
                nearest = (title, distance)
            }
        }
        guard let next = nearest?.title else { return }
        source.finishRename(save: true)
        if !next.visibleRect.contains(next.bounds) { next.scrollToVisible(next.bounds) }
        next.select?()
        _ = next.beginRename()
    }
    private func renameTitle(at event: NSEvent) -> Bool {
        guard let window = event.window, let root = window.contentView,
              !NativeTimelineInputGate.shared.isBlocked(window), ControlMappings.shared.editing == nil,
              NativeTimelineOverlayInputRegistration.pinnedRoot(in: root, point: event.locationInWindow) == nil else { return false }
        for title in titles.allObjects where title.window === window && !title.isHiddenOrHasHiddenAncestor {
            let point = title.convert(event.locationInWindow, from: nil)
            if title.visibleRect.contains(point), title.beginRename(with: event) { return true }
        }
        return false
    }
    func handle(_ event: NSEvent) {
        if event.type == .leftMouseDragged { pointerMoved = true; pendingSelection = nil; return }
        if event.type == .leftMouseUp {
            let selection = pendingSelection
            pendingSelection = nil
            if !pointerMoved && !TrackReorderState.shared.active { selection?() }
            pressedTrack = nil; dragRow = nil; dragStart = nil; return
        }
        guard event.type == .leftMouseDown, handledDownTime != event.timestamp else { return }
        handledDownTime = event.timestamp; pendingSelection = nil; pointerMoved = false
        pressedTrack = nil; dragRow = nil; dragStart = nil
        guard !TimelineTrackHeightResizeView.handlesPointer(event) else { return }
        guard !RightClickRouter.shared.handlesModifiedLeftClick(event) else { return }
        guard let window = event.window, window.attachedSheet == nil,
              !NativeTimelineInputGate.shared.isBlocked(window),
              !event.modifierFlags.contains(.control), ControlMappings.shared.editing == nil else { return }
        if let root = window.contentView,
           NativeTimelineOverlayInputRegistration.pinnedRoot(in: root, point: event.locationInWindow) != nil { return }
        let matches = rows.allObjects.filter { row in
            guard row.window === window, !row.interactionBlocked, !row.isHiddenOrHasHiddenAncestor else { return false }
            let point = row.convert(event.locationInWindow, from: nil)
            return row.bounds.contains(point) && row.visibleRect.contains(point)
        }
        guard let row = matches.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return }
        pressedTrack = row.track
        let tool = ProGridTool.current
        let cursorMix = tool.appliesToTrack ? row.cursorMix : nil
        if controls.allObjects.contains(where: { button in
            if cursorMix == nil, (button as? TrackControlSelectionExclusionView)?.selectsTrack == true { return false }
            let point = button.convert(event.locationInWindow, from: nil)
            return button.window === window && !button.isHiddenOrHasHiddenAncestor &&
                button.bounds.contains(point) && button.visibleRect.contains(point)
        }) { return }
        if let cursorMix {
            let track = row.track
            pendingSelection = { [weak row] in
                guard let row, row.track == track, row.window === window else { return }
                cursorMix(tool)
            }
            return
        }
        // The title already owns its native drag source. All other unoccupied
        // space uses this row, while registered controls retain their gestures.
        if let root = window.contentView {
            // Inspect native geometry only. SwiftUI's root hit test also runs
            // layout/graph resolution and delayed selection on Ventura.
            func nativeTarget(in view: NSView) -> NSView? {
                guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
                let local = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(local), view.visibleRect.contains(local) else { return nil }
                if view is TrackDragTitleView { return view }
                if view is NativeVerticalTrackMeterView {
                    return view.hitTest(view.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
                }
                for child in view.subviews.reversed() { if let target = nativeTarget(in: child) { return target } }
                return nil
            }
            let hit = nativeTarget(in: root)
            if hit is NativeVerticalTrackMeterView { return }
            if !(hit is TrackDragTitleView) && row.kind == .standard { dragRow = row; dragStart = event.locationInWindow; dragProject = row.project }
        }

        // A recycled slot may target another row before this callback runs.
        // Preserve the click's original track/action and project generation.
        let track = row.track, project = row.project, select = row.select, generation = sessionGeneration
        let action = { [weak self, weak row] in
            guard let self, let row, row.window === window, row.project == project,
                  self.sessionGeneration == generation else { return }
            self.perform(track: track, event: event) { select?() }
        }
        if row.selected && event.modifierFlags.intersection([.command, .shift]).isEmpty {
            pendingSelection = action
        } else { action() }
    }
    private func beginEmptyAreaDrag(_ event: NSEvent) -> Bool {
        guard !TrackReorderState.shared.active, let row = dragRow, let start = dragStart,
              row.window === event.window, row.project == dragProject, row.track == pressedTrack,
              !row.interactionBlocked, !NativeTimelineInputGate.shared.isBlocked(event.window),
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return false }
        dragRow = nil; dragStart = nil; pendingSelection = nil; pointerMoved = true
        let state = TrackReorderState.shared
        state.begin(track: row.track)
        let source = TrackDragSource(); source.state = state
        source.edgeScroll.begin(from: row)
        source.onEnd = { [weak self] in self?.pressedTrack = nil }
        state.source = source
        let item = NSDraggingItem(pasteboardWriter: ("jaras-track:" + row.track.uuidString) as NSString)
        let size = NSSize(width: min(240, max(80, row.bounds.width)), height: 28)
        let label = NSAttributedString(string: row.dragName, attributes: [.font: NSFont.jarasSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            label.draw(in: rect.insetBy(dx: 4, dy: 7)); return true
        }
        let point = row.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - 14, width: size.width, height: 28), contents: image)
        let session = row.beginDraggingSession(with: [item], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = false
        return true
    }
    func withPinnedTrack<T>(_ track: UUID, _ action: () -> T) -> T {
        let inserted = menuTracks.insert(track).inserted
        defer { if inserted { menuTracks.remove(track) } }
        return action()
    }
    func perform(track: UUID, event: NSEvent, action: () -> Void) {
        guard lastEventTime != event.timestamp else { return }
        lastEventTime = event.timestamp
        selectionModifiers = event.modifierFlags
        // Track selection owns editing keys immediately, even if a field or an
        // envelope editor was the previous AppKit first responder.
        if let window = event.window {
            NativeTimelineKeyboardFocus.activate(window: window, responder: nil)
            EditorSelectionRouter.shared.activate(.tracks, in: window)
        }
        defer { selectionModifiers = nil }
        action()
    }
}
private final class TrackRightClickView: RightClickTargetView {
    var selected = false
    var dragName = ""
    var kind = TrackKind.standard
    var project = UUID()
    var track = UUID()
    var select: (() -> Void)?
    var cursorMix: ((ProGridTool) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { TrackSelectionRouter.shared.add(self) }
    }
    var patch: (() -> Void)?
    var fx: (() -> Void)?
    var envelope: (() -> Void)?
    var edit: (() -> Void)?
    var randomColor: (() -> Void)? = nil
    var icon: (() -> Void)?
    var group: (() -> Void)?
    var ungroup: (() -> Void)?
    var removeFromGroup: (() -> Void)?
    var link: (() -> Void)?
    var unlink: (() -> Void)?
    var soundDesigner: (() -> Void)?
    var createMIDI: (() -> Void)?
    var duplicateTracks: (() -> Void)?
    var deleteTracks: (() -> Void)?
    var deleteTrackCount = 1
    var stemLayout: Bool? = nil
    var organizeStems: ((Bool?) -> Void)? = nil
    var componentMask: (() -> Int)?
    var componentChoices = TrackMixerComponent.allCases
    var cancelScan: (() -> Void)?
    var toggleComponent: ((TrackMixerComponent) -> Void)?
    var hozComponentMask: (() -> Int)?
    var toggleHozComponent: ((HozMixerComponent) -> Void)?
    func makeMenu() -> (menu: NSMenu, actions: [TrackMenuAction]) {
        let menu = NSMenu()
        var actions: [TrackMenuAction] = []
        func append(_ title: String, _ action: (() -> Void)?) {
            guard let action else { return }
            let target = TrackMenuAction(action)
            actions.append(target)
            let item = NSMenuItem(title: title, action: #selector(TrackMenuAction.invoke), keyEquivalent: "")
            item.target = target; menu.addItem(item)
        }
        if kind == .standard || kind == .timecode || kind == .video || kind == .click || kind == .programChange || kind.isTeleprompter { append("Patch", patch) }
        append(JarasLocalization.string("Cancel"), cancelScan)
        if kind == .click { append("Sound Designer", soundDesigner) }
        append(JarasLocalization.string("Envelope"), envelope)
        if let organizeStems {
            let parent = menu.addItem(withTitle: "Organize Stems", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (title, mode) in [("Default", nil as Bool?), ("Crossfader", true), (JarasLocalization.string("Separated"), false)] {
                let target = TrackMenuAction { organizeStems(mode) }
                actions.append(target)
                let choice = submenu.addItem(withTitle: title, action: #selector(TrackMenuAction.invoke), keyEquivalent: "")
                choice.target = target; choice.state = stemLayout == mode ? .on : .off
            }
            parent.submenu = submenu
        }
        if kind == .standard { append("FX", fx); append("Criar item MIDI", createMIDI); if createMIDI != nil && componentMask != nil { menu.addItem(.separator()) }; append(JarasLocalization.string("Create group"), group) }
        append(JarasLocalization.string("Ungroup"), ungroup)
        append(JarasLocalization.string("Remove from group"), removeFromGroup)
        append(JarasLocalization.string("Link tracks"), link)
        append(JarasLocalization.string("Unlink tracks"), unlink)
        append(JarasLocalization.string("Set Track Color"), edit)
        append(JarasLocalization.string("Set Random Color"), randomColor)
        append(JarasLocalization.string("Set Track Icon"), icon)
        append(JarasLocalization.string(deleteTrackCount > 1 ? "Duplicate tracks" : "Duplicate track"), duplicateTracks)
        if let componentMask, let toggleComponent {
            menu.addItem(.separator())
            let submenu = NSMenu()
            submenu.addItem(trackComponentCheckboxes(components: componentChoices, isChecked: { componentMask() & $0.rawValue == 0 }, toggle: toggleComponent))
            let item = NSMenuItem(); item.title = "Components View"; item.submenu = submenu; menu.addItem(item)
        }
        if let hozComponentMask, let toggleHozComponent {
            menu.addItem(.separator())
            let submenu = NSMenu()
            let mask = hozComponentMask()
            for component in HozMixerComponent.allCases {
                let target = TrackMenuAction { toggleHozComponent(component) }
                actions.append(target)
                let item = submenu.addItem(withTitle: JarasLocalization.string(component.title),
                    action: #selector(TrackMenuAction.invoke), keyEquivalent: "")
                item.target = target
                item.state = mask & component.bit == 0 ? .on : .off
            }
            menu.addItem(withTitle: "Components View", action: nil, keyEquivalent: "").submenu = submenu
        }
        if deleteTracks != nil {
            menu.addItem(.separator())
            append(JarasLocalization.string(deleteTrackCount > 1 ? "Delete tracks" : "Delete track"), deleteTracks)
        }
        return (menu, actions)
    }
    func openMenu() {
        guard let event = NSApp.currentEvent else { return }
        let snapshot = makeMenu()
        TrackSelectionRouter.shared.withPinnedTrack(track) {
            withExtendedLifetime(snapshot.actions) { NSMenu.popUpContextMenu(snapshot.menu, with: event, for: self) }
        }
    }
}
final class TrackMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }

}

#endif

#if os(macOS)
private struct TrackDragTitle: NSViewRepresentable {
    let title: String
    let foreground: UInt32
    let project: UUID
    let track: UUID
    let state: TrackReorderState?
    let select: () -> Void
    var compact = false
    var editableName: String? = nil
    var rename: ((String) -> Void)? = nil
    func makeNSView(context: Context) -> TrackDragTitleView { TrackDragTitleView() }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TrackDragTitleView, context: Context) -> CGSize? {
        CGSize(width: max(0, proposal.width ?? 0), height: max(0, proposal.height ?? 16))
    }
    func updateNSView(_ view: TrackDragTitleView, context: Context) { configure(view) }
    func configure(_ view: TrackDragTitleView) {
        view.compact = compact; view.title = title; view.foreground = foreground; view.project = project; view.track = track; view.state = state; view.select = select
        view.editableName = editableName; view.rename = rename
    }
}
@MainActor private final class TrackDragSource: NSObject, NSDraggingSource {
    let edgeScroll = NativeDragEdgeScroll()
    weak var state: TrackReorderState?
    var onEnd: (() -> Void)?
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { edgeScroll.stop(); state?.finish(); onEnd?() }
}
private final class TrackDragTitleView: NSView, NSTextFieldDelegate {
    var interactionEnabled = true
    var compact = false { didSet { if compact != oldValue { cachedLabel = nil; needsDisplay = true } } }
    var title = "" {
        didSet {
            guard title != oldValue else { return }
            cachedLabel = nil
            needsDisplay = true
        }
    }
    var foreground: UInt32 = 0xffffff {
        didSet {
            guard foreground != oldValue else { return }
            cachedLabel = nil
            needsDisplay = true
        }
    }
    var project = UUID() { didSet { if project != oldValue { down = nil; finishRename(save: false) } } }
    var track = UUID() { didSet { if track != oldValue { down = nil; finishRename(save: false) } } }
    weak var state: TrackReorderState?
    var select: (() -> Void)?
    var editableName: String?
    var rename: ((String) -> Void)?
    private var nameField: NSTextField?
    private var down: NSPoint?
    private let screenDrawing = NativeScreenDrawing()
    private var cachedLabel: NSAttributedString?
    private static let labelAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.jarasSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph.copy() as! NSParagraphStyle]
    }()
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            NativeTimelineOverlayInputRegistration.add(self)
            TrackSelectionRouter.shared.addTitle(self)
        } else {
            finishRename(save: false)
        }
    }
    override func layout() {
        super.layout()
        if let field = nameField { field.frame = renameFrame(name: editableName ?? field.stringValue, font: field.font) }
    }
    private func renameFrame(name: String, font: NSFont?) -> CGRect {
        let width = min(bounds.width, max(84, (name as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11)]).width + 36))
        return CGRect(x: compact ? (bounds.width - width) / 2 : 0, y: 0, width: width, height: bounds.height)
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }
    private func label() -> NSAttributedString {
        if let cachedLabel { return cachedLabel }
        var attributes = Self.labelAttributes
        attributes[.foregroundColor] = foreground == 0 ? NSColor.black : NSColor.white
        if compact {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
            attributes[.paragraphStyle] = paragraph
            attributes[.font] = NSFont.jarasSystemFont(ofSize: 10, weight: .semibold)
        }
        let label = NSAttributedString(string: title, attributes: attributes)
        cachedLabel = label
        return label
    }
    override func draw(_ dirtyRect: NSRect) {
        guard nameField == nil else { return }
        screenDrawing.draw(in: self) {
            label().draw(in: compact ? bounds : NSRect(x: 0, y: (bounds.height - 14) / 2, width: bounds.width, height: 14))
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        if event.clickCount == 2, beginRename(with: event) { return }
        down = event.locationInWindow
        TrackSelectionRouter.shared.handle(event)
    }
    private func nameContains(_ event: NSEvent, name: String) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let text = label()
        if compact {
            let size = text.boundingRect(with: bounds.size, options: .usesLineFragmentOrigin).size
            return CGRect(x: (bounds.width - size.width) / 2, y: 0,
                          width: size.width, height: size.height).intersection(bounds).contains(point)
        }
        let prefixLength = title.hasSuffix(name) ? title.utf16.count - name.utf16.count : 0
        let start = text.attributedSubstring(from: NSRange(location: 0, length: prefixLength)).size().width
        return CGRect(x: start, y: (bounds.height - 14) / 2,
                      width: max(0, min(bounds.width, text.size().width) - start), height: 14).contains(point)
    }
    func beginRename(with event: NSEvent? = nil) -> Bool {
        guard interactionEnabled, nameField == nil,
              (event?.modifierFlags.intersection([.command, .shift, .control, .option]) ?? []).isEmpty,
              let editableName, rename != nil, let window, window.attachedSheet == nil,
              !NativeTimelineInputGate.shared.isBlocked(window) else { return false }
        if let event, !nameContains(event, name: editableName) { return false }
        down = nil
        let field = NSTextField(string: editableName)
        field.font = NSFont.jarasSystemFont(ofSize: compact ? 10 : 11, weight: .semibold)
        field.frame = renameFrame(name: editableName, font: field.font)
        field.textColor = .white; field.backgroundColor = NSColor(white: 0.10, alpha: 1)
        field.isBezeled = true; field.focusRingType = .none
        field.alignment = compact ? .center : .left
        field.setAccessibilityLabel("Track name")
        field.delegate = self
        TrackSelectionRouter.shared.editingTitle?.finishRename(save: true)
        TrackSelectionRouter.shared.editingTitle = self
        nameField = field; addSubview(field)
        needsDisplay = true
        let focus = { [weak self, weak field] in
            guard let self, let field, self.nameField === field,
                  NativeTimelineKeyboardFocus.activate(window: self.window, responder: field) else { return }
            (field.currentEditor() as? NSTextView)?.selectAll(nil)
        }
        if event == nil { focus() }
        else {
            // Finish the mouse event before changing focus after a double-click.
            DispatchQueue.main.async(execute: focus)
        }
        return true
    }
    func controlTextDidEndEditing(_ notification: Notification) { finishRename(save: true) }
    func finishRenameIfOutside(_ click: NSEvent) {
        guard let field = nameField else { return }
        if click.window !== field.window || !field.visibleRect.contains(field.convert(click.locationInWindow, from: nil)) {
            finishRename(save: true)
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { finishRename(save: false); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { finishRename(save: true); return true }
        if selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveDown(_:)) {
            TrackSelectionRouter.shared.moveRename(from: self, direction: selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)
            return true
        }
        return false
    }
    fileprivate func finishRename(save: Bool) {
        guard let field = nameField else { return }
        let value = field.currentEditor()?.string ?? field.stringValue
        let commit = rename
        nameField = nil; field.delegate = nil
        if TrackSelectionRouter.shared.editingTitle === self { TrackSelectionRouter.shared.editingTitle = nil }
        if let editor = field.currentEditor(), window?.firstResponder === editor { window?.makeFirstResponder(nil) }
        field.removeFromSuperview(); needsDisplay = true
        if save { commit?(value) }
    }
    override func mouseUp(with event: NSEvent) { down = nil }
    override func mouseDragged(with event: NSEvent) {
        guard interactionEnabled, let down, let state, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) >= 4 else { return }
        self.down = nil
        state.begin(track: track)
        let source = TrackDragSource(); source.state = state; state.source = source
        source.edgeScroll.begin(from: self)
        let item = NSDraggingItem(pasteboardWriter: ("jaras-track:" + track.uuidString) as NSString)
        let size = NSSize(width: max(1, bounds.width), height: 28)
        // The drag preview has its own native background rather than the
        // track's color, so retain its matching system label color.
        let text = NSAttributedString(string: title, attributes: Self.labelAttributes)
        let preview = NSImage(size: size, flipped: true) { rect in
            NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            text.draw(in: rect.insetBy(dx: 4, dy: 7)); return true
        }
        item.setDraggingFrame(bounds, contents: preview)
        let session = beginDraggingSession(with: [item], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }
}
#endif

struct FooterMixerPanel: View {
    let show: ShowController
    let active: Bool
    let maximumHeight: CGFloat
    var resizeCoordinator: FooterVerticalResizeCoordinator? = nil
    @WorkspacePreference("jaras.footerMixerHeight", store: WorkspaceLayoutPreferences.storage) private var storedHeight = Double(FooterHorizontalMixer.minimumDockHeight)
    @State private var resizeStart: CGFloat?
    @State private var resizeHeight: CGFloat?
    @State private var hovering = false
    private var heightLimit: CGFloat { min(723.55859375, maximumHeight) }
    private var minimum: CGFloat { FooterHorizontalMixer.minimumDockHeight }
    private var height: CGFloat { min(heightLimit, max(minimum, resizeHeight ?? storedHeight)) }
    var body: some View {
        #if os(macOS)
        FooterNativeHeightHost(storedHeight: CGFloat(storedHeight), minimum: minimum, maximum: heightLimit,
            active: active, identity: AnyHashable(ObjectIdentifier(show)),
            role: .mixer, resizeCoordinator: resizeCoordinator) {
            VStack(spacing: 0) {
                FooterMixerResizeInput(height: height, minimum: minimum, maximum: heightLimit, changed: { _ in }, ended: { storedHeight = $0 })
                    .frame(height: 8).jarasHelp("Drag to resize mixer")
                // Keep the controls and meters mounted when the panel is hidden.
                FooterHorizontalMixer(show: show).frame(maxHeight: .infinity)
            }
        }.clipped().allowsHitTesting(active).accessibilityHidden(!active)
        #else
        VStack(spacing: 0) {
            ZStack {
                Color.white.opacity(hovering ? 0.12 : 0.04)
                Capsule().fill(hovering ? JarasTheme.green : JarasTheme.secondary).frame(width: 48, height: 2)
            }.frame(height: 8).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
                    if resizeStart == nil { resizeStart = height }
                    resizeHeight = min(heightLimit, max(minimum, (resizeStart ?? height) - value.translation.height))
                }.onEnded { _ in
                    if let resizeHeight { storedHeight = resizeHeight }
                    resizeHeight = nil; resizeStart = nil
                })
                .onHover { inside in
                    hovering = inside
                    #if os(macOS)
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    #endif
                }
                .jarasHelp("Drag to resize mixer")
            FooterHorizontalMixer(show: show, active: active).frame(maxHeight: .infinity)
        }.frame(height: height)
            .frame(height: active ? height : 0, alignment: .top).clipped()
            .allowsHitTesting(active).accessibilityHidden(!active)
        #endif
    }
}

private enum FooterMixerMetrics {
    static let width: CGFloat = 83
    static let masterWidth: CGFloat = width * 1.25
    static let toolbarHeight: CGFloat = 30
}

private enum HozMixerComponent: Int, CaseIterable {
    case patch, fx, envelope, rec, inputMonitor, pan, mute, solo, phase
    case vu, fader, peak, sends, outputs, icon, insert

    var bit: Int { 1 << rawValue }
    var title: String {
        TrackMixerComponent(rawValue: bit)?.title ?? [
            "VU Meter", "Fader", "Peak", "Sends", "Output", "Track Icon", "Insert"
        ][rawValue - Self.vu.rawValue]
    }
    static let globalKey = "catlive.barMixer.hiddenComponents"
    static let tracksKey = "catlive.barMixer.trackComponents"
    static func overrides(_ data: Data) -> [UUID: Int] {
        (try? JSONDecoder().decode([UUID: Int].self, from: data)) ?? [:]
    }
    static func mask(global: Int, override: Int) -> Int {
        let chosen = override >> 16
        return (global & ~chosen) | (override & chosen)
    }
    static func toggled(_ bit: Int, global: Int, override: Int) -> Int {
        let value = mask(global: global, override: override) ^ bit
        guard (value & bit) != (global & bit) else { return override & ~(bit | (bit << 16)) }
        return (override & ~bit) | (value & bit) | (bit << 16)
    }
}

private struct FooterMixerStripLayout {
    static let contentInset: CGFloat = 4
    static let labelHeight: CGFloat = 40
    static let titleHeight: CGFloat = 22
    static let numberHeight: CGFloat = 13
    static let stripeTitleInset: CGFloat = 2
    static let colorFooterHeight = labelHeight - titleHeight - numberHeight - stripeTitleInset - 1 + contentInset
    let controlsHeight: CGFloat
    let slotsHeight: CGFloat
    init(height: CGFloat, iconHeight: CGFloat = 0) {
        let innerHeight = max(0, height - 2 * Self.contentInset - iconHeight)
        // The fixed footer keeps the two-line name above a separate number row.
        controlsHeight = min(205, max(100, innerHeight - Self.labelHeight))
        slotsHeight = max(0, innerHeight - controlsHeight - Self.labelHeight)
    }
}

private struct FooterSlotSectionsLayout {
    let pluginsHeight: CGFloat
    let outputsHeight: CGFloat
    let dividerHeight: CGFloat
    static let bypassRowHeight: CGFloat = 26
    static let sessionRowHeight: CGFloat = 21
    static let routingDividerHeight: CGFloat = 9

    init(height: CGFloat, hasRouting: Bool, main: Bool, separatedRouting: Bool) {
        let available = max(0, height)
        let rowHeight = Self.bypassRowHeight
        guard available >= rowHeight + 19 else {
            pluginsHeight = available
            dividerHeight = 0
            outputsHeight = 0
            return
        }
        let afterBypass = available - rowHeight - Self.sessionRowHeight
        let extra = separatedRouting && afterBypass >= 38 ? Self.routingDividerHeight : 0
        let midpoint = max(19, ((available - rowHeight) / 2).rounded(.down) - extra)
        let preferredRouting = separatedRouting ? 21 + extra + 19 : 19
        let minimumRouting = afterBypass >= 19 + preferredRouting ? preferredRouting : 19
        pluginsHeight = afterBypass >= 38 ? min(midpoint, afterBypass - minimumRouting) : midpoint
        let spaceBelow = available - pluginsHeight - rowHeight
        let sessionHeight = main && spaceBelow >= Self.sessionRowHeight ? Self.sessionRowHeight : 0
        dividerHeight = rowHeight + sessionHeight
        // Reserve the Main session row in every column so Sends shares one baseline.
        let routingSpace = max(0, spaceBelow - (spaceBelow >= Self.sessionRowHeight ? Self.sessionRowHeight : 0))
        outputsHeight = hasRouting ? routingSpace : 0
    }
}

private struct FooterRoutingChannel: Equatable, Identifiable {
    let id: UUID?
    let number: Int?
    let name: String
    var label: String { number.map { "Ch - \($0)" } ?? name }
}

private struct FooterMixerRenderState: Equatable {
    let project: UUID
    var tracks: [Track]
    let masterFX: NativeFXSettings?
    let masterVolume: Double
    let masterPan: Double
    let masterMute: Bool
    let masterSolo: Bool
    let masterMono: Bool
    let selection: Set<UUID>
    var masterOutputs: [OutputPatch] = []
    var mainSends: [UUID] = []
    var mainSendTargets: [UUID: FooterRoutingChannel] = [:]
    var masterRight = false
    var revealTrack: UUID? = nil
    var revealRequest: UUID? = nil
    var trackNumbers: [UUID: Int] = [:]
    var wideTracks = false
    var hiddenComponents = 0
    var componentOverrides: [UUID: Int] = [:]
    var busSources: [UUID: [FooterRoutingChannel]] = [:]
    var sendTargets: [UUID: [UUID: FooterRoutingChannel]] = [:]
    var showsInstrumentIcons: Bool { tracks.contains { TrackIconCatalog.contains($0.instrumentIcon) } }
}
@MainActor extension ShowController {
    func addDefaultMixerTrack() -> UUID? {
        guard let song = current else { return nil }
        let existingNames = Set(song.tracks.map(\.name))
        var number = song.tracks.count + 1
        var name = String(format: JarasLocalization.string("Track %lld"), Int64(number))
        while existingNames.contains(name) {
            number += 1
            name = String(format: JarasLocalization.string("Track %lld"), Int64(number))
        }
        let channels = TrackRecording.shared.inputChannels
        let inputs = channels > 0 ? [OutputPatch(firstChannel: 1, channelCount: min(2, channels))] : []
        return addTracks(name: name, role: .other, count: 1, inputPatches: inputs).first
    }
}

func mixerPanText(_ value: Double) -> String {
    let percent = Int((min(1, abs(value.isFinite ? value : 0)) * 100).rounded())
    return percent == 0 ? "Center" : "\(percent)%\(value < 0 ? "L" : "R")"
}

struct FooterHorizontalMixer: View {
    @WorkspacePreference(JarasInterfaceTheme.preferenceKey) private var interfaceTheme = JarasInterfaceTheme.defaultTheme
    @WorkspacePreference("catlive.barMixer.masterRight") private var masterRight = false
    @WorkspacePreference("catlive.barMixer.wideTracks") private var wideTracks = false
    @WorkspacePreference("catlive.barMixer.trackScope") private var scope = HozMixerTrackScope.all
    @WorkspacePreference("catlive.barMixer.signalFilters") private var signalFilters = 0
    @WorkspacePreference(HozMixerComponent.globalKey) private var hiddenComponents = 0
    @WorkspacePreference(HozMixerComponent.tracksKey) private var componentOverrides = Data()
    #if os(macOS)
    static let minimumDockHeight: CGFloat = 360.57421875
    #else
    static let minimumDockHeight: CGFloat = 303
    #endif
    static func focusWidth(hasSelectedTrack: Bool) -> CGFloat {
        FooterMixerMetrics.masterWidth * (hasSelectedTrack ? 2 : 1) + 12
    }
    static func hasFocusSelection(in show: ShowController) -> Bool {
        guard let id = show.selectedTrackForActions else { return false }
        return show.current?.tracks.contains { $0.id == id } == true
    }
    let show: ShowController
    @ObservedObject private var updates: ShowProjectPresentation
    @ObservedObject private var selectionUpdates: ShowTrackSelectionPresentation
    @ObservedObject private var trackVisibility = TrackVisibilityPreferences.shared
    let active: Bool
    let focused: Bool
    init(show: ShowController, active: Bool = true, focused: Bool = false) {
        self.show = show; self.active = active; self.focused = focused
        _updates = ObservedObject(wrappedValue: show.projectPresentation)
        _selectionUpdates = ObservedObject(wrappedValue: show.trackSelectionPresentation)
    }
    var body: some View {
        let project = show.snapshot.project
        let visibility = trackVisibility.state(for: project.id)
        let available = show.current?.tracks ?? []
        let channels = focused ? available.first { $0.id == show.selectedTrackForActions }.map { [$0] } ?? []
            : visibility.visibleTracks(in: available, area: .barMixer).filter { $0.kind == .standard || $0.kind == .click }
        let signals = Set(HozMixerSignal.allCases.enumerated().compactMap { index, signal in signalFilters & (1 << index) == 0 ? nil : signal })
        let displayed = focused ? channels : show.current?.hozMixerTracks(channels, scope: scope, signals: signals) ?? channels
        let tracks = displayed.map { track in
            var presentation = track; presentation.clips = []; return presentation
        }
        let receivers = available.filter(\.receivesMain).sorted {
            ($0.routing?.mainSendOrder ?? -1) < ($1.routing?.mainSendOrder ?? -1)
        }
        let (trackNumbers, routingChannels) = routingLabels(in: available, selected: tracks.first)
        let sendTargets = Dictionary(uniqueKeysWithValues: tracks.compactMap { track -> (UUID, [UUID: FooterRoutingChannel])? in
            let destinations = track.routing?.transmitters.compactMap { $0 } ?? []
            let channels = destinations.compactMap { id in routingChannels[id].map { (id, $0) } }
            guard !channels.isEmpty else { return nil }
            return (track.id, Dictionary(channels, uniquingKeysWith: { first, _ in first }))
        })
        let incoming = focused ? [:] : show.current?.hozMixerBusSources ?? [:]
        let busSources = Dictionary(uniqueKeysWithValues: tracks.compactMap { track -> (UUID, [FooterRoutingChannel])? in
            guard !focused else { return nil }
            var sources = (incoming[track.id] ?? []).compactMap { routingChannels[$0] }
            if track.receivesMain { sources.insert(FooterRoutingChannel(id: nil, number: nil, name: "Main"), at: 0) }
            return sources.isEmpty ? nil : (track.id, sources)
        })
        let state = FooterMixerRenderState(project: project.id, tracks: tracks,
            masterFX: project.masterFX, masterVolume: project.masterVolume ?? 1, masterPan: project.masterPan ?? 0,
            masterMute: project.masterMute == true, masterSolo: project.masterSolo == true, masterMono: project.masterMono == true, selection: show.mixerTrackSelection.intersection(tracks.map(\.id)), masterOutputs: project.masterOutputPatches, mainSends: receivers.map(\.id),
            mainSendTargets: Dictionary(uniqueKeysWithValues: receivers.compactMap { track in
                routingChannels[track.id].map { (track.id, $0) }
            }), masterRight: masterRight, revealTrack: show.trackSelectionRequest?.track, revealRequest: show.trackSelectionRequest?.id,
            trackNumbers: trackNumbers,
            wideTracks: !focused && wideTracks, hiddenComponents: focused ? 0 : hiddenComponents,
            componentOverrides: focused ? [:] : HozMixerComponent.overrides(componentOverrides), busSources: busSources, sendTargets: sendTargets)
        Group {
            if focused { FocusMixerStrips(show: show, state: state) }
            else {
                VStack(spacing: 0) {
                    toolbar
                    FooterMixerContent(show: show, active: active, state: state).equatable()
                }
                    #if os(macOS)
                    .background(EditorSelectionArea(scope: .tracks) {
                        let selectable = tracks.filter { $0.kind == .standard }
                        show.setMixerTrackSelection(Set(selectable.map(\.id)), anchor: selectable.first?.id)
                        return !selectable.isEmpty
                    })
                    #endif
            }
        }
    }

    private func routingLabels(in available: [Track], selected: Track?) -> ([UUID: Int], [UUID: FooterRoutingChannel]) {
        // The inspector renders the selected channel and Main. Only their send
        // destinations need labels, including Main receivers on hidden tracks.
        let focusedDestinations = focused ? Set((selected?.routing?.transmitters ?? []).compactMap { $0 }) : []
        var trackNumbers: [UUID: Int] = [:]
        var routingChannels: [UUID: FooterRoutingChannel] = [:]
        for (index, track) in available.enumerated() {
            if !focused || track.id == selected?.id { trackNumbers[track.id] = index + 1 }
            if !focused || track.receivesMain || focusedDestinations.contains(track.id) {
                routingChannels[track.id] = FooterRoutingChannel(id: track.id, number: index + 1, name: track.name)
            }
        }
        return (trackNumbers, routingChannels)
    }

    private var toolbar: some View {
        let buttonBackground = Color(hex: interfaceTheme == .dark ? 0x292929 : 0x393939)
        let toolbarBackground = interfaceTheme.panel.opacity(0.65)
        return HStack(spacing: 6) {
            #if os(iOS)
            componentsSelector(background: buttonBackground).padding(.trailing, 14)
            #endif
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    #if os(macOS)
                    componentsSelector(background: buttonBackground).padding(.trailing, 20)
                    #endif
                    HStack(spacing: 2) {
                        ForEach(HozMixerTrackScope.allCases, id: \.self) { value in
                            toolbarButton(selected: scope == value, action: { scope = value }) {
                                Text(LocalizedStringKey(value.label)).padding(.horizontal, 8)
                            }
                        }
                    }.padding(2).background(buttonBackground, in: RoundedRectangle(cornerRadius: 6))
                    Spacer(minLength: 16)
                    HStack(spacing: 2) {
                        ForEach(Array(HozMixerSignal.allCases.enumerated()), id: \.element) { index, signal in
                            let bit = 1 << index
                            toolbarButton(selected: signalFilters & bit != 0, action: { signalFilters ^= bit }) {
                                Text(LocalizedStringKey(signal.rawValue)).padding(.horizontal, 8)
                            }
                        }
                    }.padding(2).background(buttonBackground, in: RoundedRectangle(cornerRadius: 6))
                }
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
            }
            HStack(spacing: 2) {
                widthButton(wide: false)
                widthButton(wide: true)
            }.padding(2).background(buttonBackground, in: RoundedRectangle(cornerRadius: 6))
        }.font(.jarasSystem(size: 11, weight: .semibold))
            .padding(.horizontal, 6).frame(height: FooterMixerMetrics.toolbarHeight)
            .background(toolbarBackground)
            #if os(iOS)
            .background(interfaceTheme.background)
            #endif
    }

    private func componentsSelector(background: Color) -> some View {
        HozMixerComponentsPicker(hiddenComponents: $hiddenComponents)
            .padding(2).background(background, in: RoundedRectangle(cornerRadius: 6))
    }

    private func toolbarButton<Label: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label().frame(height: 23)
                .foregroundStyle(selected ? Color.black : Color.white)
                .background(selected ? JarasTheme.green : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func widthButton(wide: Bool) -> some View {
        toolbarButton(selected: wideTracks == wide, action: { wideTracks = wide }) {
            Canvas { context, size in
                let rect = CGRect(x: 8, y: 5, width: 16, height: 13)
                var icon = Path(roundedRect: rect, cornerRadius: 1.5)
                let divisions = wide ? 2 : 3
                for index in 1..<divisions {
                    let x = rect.minX + rect.width * CGFloat(index) / CGFloat(divisions)
                    icon.move(to: CGPoint(x: x, y: rect.minY))
                    icon.addLine(to: CGPoint(x: x, y: rect.maxY))
                }
                context.stroke(icon, with: .foreground, lineWidth: 1.1)
            }.frame(width: 32, height: 23)
        }.accessibilityLabel(wide ? "Wide channels" : "Standard channels")
            .jarasHelp(wide ? "Wide channels" : "Standard channels")
    }
}

private struct HozMixerComponentsPicker: View {
    @Binding var hiddenComponents: Int
    #if os(macOS)
    @State private var presented = false
    #endif

    var body: some View {
        #if os(iOS)
        label.frame(width: 104).accessibilityHidden(true)
            .overlay { HozMixerNativeComponentsButton(hiddenComponents: $hiddenComponents) }
        #else
        Button { presented.toggle() } label: { label }
            .buttonStyle(.plain)
            .popover(isPresented: $presented, arrowEdge: .bottom) { componentOptions }
            .fixedSize()
        #endif
    }

    private var label: some View {
        HStack(spacing: 4) {
            Text(verbatim: "Components")
            Image(systemName: "chevron.down").font(.jarasSystem(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 8).frame(height: 23).contentShape(Rectangle())
    }

    #if os(macOS)
    private var componentOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(HozMixerComponent.allCases, id: \.self) { component in
                let visible = hiddenComponents & component.bit == 0
                Button { hiddenComponents ^= component.bit } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").opacity(visible ? 1 : 0).frame(width: 13)
                            .foregroundStyle(JarasTheme.green)
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(component.title))
                        Spacer()
                    }.padding(5)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(visible ? .isSelected : [])
            }
        }.font(.jarasSystem(size: 12)).padding(6).frame(width: 164)
    }
    #endif
}

#if os(iOS)
private struct HozMixerNativeComponentsButton: UIViewRepresentable {
    @Binding var hiddenComponents: Int

    func makeCoordinator() -> Coordinator { Coordinator(mask: $hiddenComponents) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityLabel = "Components"
        button.accessibilityIdentifier = "hoz-mixer-components"
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        let coordinator = context.coordinator
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak button, weak coordinator] completion in
            guard let button, let coordinator else { completion([]); return }
            completion(coordinator.actions(for: button))
        }])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.mask = $hiddenComponents
    }

    @MainActor final class Coordinator {
        var mask: Binding<Int>
        init(mask: Binding<Int>) { self.mask = mask }

        func actions(for button: UIButton) -> [UIAction] {
            HozMixerComponent.allCases.map { component in
                UIAction(title: JarasLocalization.string(component.title), attributes: .keepsMenuPresented,
                         state: mask.wrappedValue & component.bit == 0 ? .on : .off) { [weak self, weak button] _ in
                    guard let self, let button else { return }
                    self.mask.wrappedValue ^= component.bit
                    button.contextMenuInteraction?.updateVisibleMenu { menu in
                        menu.replacingChildren(self.actions(for: button))
                    }
                }
            }
        }
    }
}
#endif

private struct FocusMixerStrips: View {
    @WorkspacePreference(JarasInterfaceTheme.preferenceKey) private var theme = JarasInterfaceTheme.defaultTheme
    let show: ShowController
    let state: FooterMixerRenderState

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                HStack(spacing: 0) {
                    if let track = state.tracks.first {
                        FooterMixerStrip(show: show, track: track, selection: state.selection,
                            active: true, number: state.trackNumbers[track.id], focused: true,
                            sendTargets: state.sendTargets[track.id] ?? [:])
                            .id(track.id)
                    }
                    FooterMixerStrip(masterState: state, show: show, track: nil, selection: [],
                        active: true, focused: true)
                }
                .frame(height: max(352, geometry.size.height - 12))
                .padding(6)
            }
            .jarasHideScrollIndicators()
        }
        .background(theme.panel)
        .accessibilityIdentifier("focus-mixer")
    }
}
/// Scalar edits replace only their own native hosting root. Track presentations
/// contain no clips; comparing them never walks waveform or item storage.
private final class FooterMixerStripVersions {
    private var previous: FooterMixerRenderState?
    private var previousActive: Bool?
    private var previousLocale: String?
    private var versions: [UInt64] = []
    private var counter: UInt64 = 0
    private(set) var masterVersion: UInt64 = 0
    func update(_ state: FooterMixerRenderState, active: Bool, locale: String) -> [UInt64] {
        let commonChanged = previous?.project != state.project || previous?.showsInstrumentIcons != state.showsInstrumentIcons ||
            previousActive != active || previousLocale != locale
        if previous?.project != state.project || previousActive != active || previousLocale != locale ||
            previous?.masterFX != state.masterFX || previous?.masterVolume != state.masterVolume ||
            previous?.masterPan != state.masterPan || previous?.masterMute != state.masterMute ||
            previous?.masterSolo != state.masterSolo || previous?.masterMono != state.masterMono ||
            previous?.mainSends != state.mainSends || previous?.mainSendTargets != state.mainSendTargets ||
            previous?.masterOutputs != state.masterOutputs || previous?.masterRight != state.masterRight || previous?.showsInstrumentIcons != state.showsInstrumentIcons {
            counter &+= 1; masterVersion = counter
        }
        let previousIndices = Dictionary(uniqueKeysWithValues: (previous?.tracks ?? []).enumerated().map { ($0.element.id, $0.offset) })
        let next = state.tracks.map { track -> UInt64 in
            if !commonChanged, let previous, let index = previousIndices[track.id],
               index < versions.count, previous.tracks[index] == track,
               previous.trackNumbers[track.id] == state.trackNumbers[track.id],
               previous.hiddenComponents == state.hiddenComponents,
               previous.componentOverrides[track.id] == state.componentOverrides[track.id],
               previous.busSources[track.id] == state.busSources[track.id],
               previous.sendTargets[track.id] == state.sendTargets[track.id],
               (previous.selection == state.selection || (!previous.selection.contains(track.id) && !state.selection.contains(track.id))) { return versions[index] }
            counter &+= 1; return counter
        }
        previous = state; previousActive = active; previousLocale = locale; versions = next
        return next
    }
}
private struct FooterMixerContent: View, Equatable {
    @WorkspacePreference(JarasInterfaceTheme.preferenceKey) private var interfaceTheme = JarasInterfaceTheme.defaultTheme
    let show: ShowController
    let active: Bool
    let state: FooterMixerRenderState
    @Environment(\.openFX) private var openFX
    @Environment(\.locale) private var locale
    @Environment(\.editTrackDetails) private var editTrackDetails
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.show === rhs.show && lhs.active == rhs.active && lhs.state == rhs.state }
    @State private var stripVersions = FooterMixerStripVersions()
    private var count: Int { state.tracks.count }
    private var stride: CGFloat { (state.wideTracks ? FooterMixerMetrics.masterWidth : FooterMixerMetrics.width) + 3 }
    private func strip(_ track: Track) -> some View {
        FooterMixerStrip(show: show, track: track, selection: state.selection, active: active,
            showsInstrumentIcons: state.showsInstrumentIcons, number: state.trackNumbers[track.id],
            wide: state.wideTracks, componentMask: HozMixerComponent.mask(
                global: state.hiddenComponents, override: state.componentOverrides[track.id] ?? 0),
            busSources: state.busSources[track.id] ?? [], sendTargets: state.sendTargets[track.id] ?? [:]).equatable()
    }
    private func strips(_ range: Range<Int>, order: [Track]) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(range.map { order[$0] }) { track in strip(track) }
            }
        }.padding(5)
            .environment(\.openFX, openFX).environment(\.locale, locale).environment(\.editTrackDetails, editTrackDetails)
    }
    private var masterStrip: some View {
        FooterMixerStrip(masterState: state, show: show, track: nil, selection: [], active: active,
            showsInstrumentIcons: state.showsInstrumentIcons)
            .padding(5)
    }
    var body: some View {
        scrollingMixer.background(interfaceTheme.mixerPanelBackground).overlay(alignment: .top) { Divider() }
    }
    private func addTrackInEmptySpace() {
        #if os(macOS)
        guard ControlMappings.shared.editing == nil else { return }
        #endif
        guard active, let id = show.addDefaultMixerTrack() else { return }
        show.setMixerTrackSelection([id], anchor: id)
    }
    private var scrollingMixer: some View {
        Group {
            #if os(macOS)
            let ordered = state.tracks
            let versions = stripVersions.update(state, active: active, locale: locale.identifier + "/" + interfaceTheme.rawValue)
            let occupiedWidth = CGFloat(count) * stride + 7
            FooterMixerScroll(usesChannelGeometry: true, contentWidth: occupiedWidth + stride * 1.5,
                occupiedWidth: occupiedWidth, scrollRailHex: interfaceTheme.scrollRailHex, stride: stride, count: count, active: active,
                masterWidth: FooterMixerMetrics.masterWidth, masterRight: state.masterRight, masterVersion: stripVersions.masterVersion,
                masterContent: AnyView(FooterMixerStrip(masterState: state, show: show, track: nil, selection: [], active: active, showsInstrumentIcons: state.showsInstrumentIcons).equatable().padding(5)
                    .environment(\.openFX, openFX).environment(\.locale, locale).environment(\.editTrackDetails, editTrackDetails)),
                versions: versions, identifiers: ordered.map(\.id), project: state.project,
                trackExists: { state.trackNumbers[$0] != nil }, revealTrack: state.revealTrack, revealRequest: state.revealRequest, retainStrip: { index in
                    ordered.indices.contains(index) && TrackSelectionRouter.shared.pinnedTracks.contains(ordered[index].id)
                }, addTrack: addTrackInEmptySpace) { range in AnyView(strips(range, order: ordered)) }
            #else
            HStack(spacing: 0) {
                if !state.masterRight { masterStrip }
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 3) {
                                ForEach(state.tracks) { track in strip(track).id(track.id) }
                                let emptyWidth = max(stride * 1.5, geometry.size.width - CGFloat(count) * stride - 10)
                                Color.clear.frame(width: emptyWidth, height: max(0, geometry.size.height - 10))
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2, perform: addTrackInEmptySpace)
                            }.padding(5)
                        }.scrollIndicators(.visible)
                        .onChange(of: state.revealRequest) { _ in
                            if active, let id = state.revealTrack, state.tracks.contains(where: { $0.id == id }) {
                                proxy.scrollTo(id)
                            }
                        }
                    }
                }
                if state.masterRight { masterStrip }
            }
            #endif
        }
    }
}

#if os(macOS)
private struct FooterMixerScroll: NSViewRepresentable {
    var usesChannelGeometry = false
    let contentWidth: CGFloat
    var occupiedWidth: CGFloat? = nil
    var scrollRailHex: UInt32 = 0x1f1f1f
    let stride: CGFloat
    let count: Int
    let active: Bool
    let masterWidth: CGFloat
    let masterRight: Bool
    let masterVersion: UInt64
    let masterContent: AnyView
    var versions: [UInt64]? = nil
    var identifiers: [UUID]? = nil
    var project: UUID?
    var trackExists: (UUID) -> Bool = { _ in false }
    var revealTrack: UUID? = nil
    var revealRequest: UUID? = nil
    var retainStrip: (Int) -> Bool = { _ in false }
    var addTrack: () -> Void = {}
    let makeContent: (Range<Int>) -> AnyView
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FooterMixerScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? max(1, nsView.frame.width), height: proposal.height ?? 242)
    }
    func makeNSView(context: Context) -> FooterMixerScrollView {
        let view = FooterMixerScrollView()
        view.usesChannelGeometry = usesChannelGeometry
        return view
    }
    func updateNSView(_ view: FooterMixerScrollView, context: Context) {
        if view.isHidden == active { view.isHidden = !active }
        view.configureEmptyArea(trackWidth: occupiedWidth ?? contentWidth, addTrack: addTrack)
        view.setScrollRailColor(NSColor(Color(hex: scrollRailHex)))
        view.updateMaster(content: masterContent, width: masterWidth, version: masterVersion, right: masterRight)
        view.update(width: contentWidth, stride: stride, count: count, versions: versions, identifiers: identifiers,
                    project: project, trackExists: trackExists, retainStrip: retainStrip, makeContent: makeContent)
        if active { view.revealTrack(revealTrack, request: revealRequest) }
    }
}
private final class FooterMixerDocumentView: NSView {
    override var isFlipped: Bool { true }
    var occupiedWidth: CGFloat = 0
    var addTrack: () -> Void = {}
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2,
              event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty,
              let window, window.attachedSheet == nil, !NativeTimelineInputGate.shared.isBlocked(window),
              convert(event.locationInWindow, from: nil).x >= occupiedWidth else {
            super.mouseDown(with: event); return
        }
        addTrack()
    }
}
private final class FooterMixerHostingView: NSHostingView<AnyView> {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    var usesChannelGeometry = false
    private weak var channelGeometry: FooterMixerStripGeometryView?
    private var channelViewport: NSRect?
    private var channelRootNeedsLayout = true
    private(set) var channelPrepared = false
    func setChannelContent(_ content: AnyView) {
        channelGeometry = nil
        channelRootNeedsLayout = true
        rootView = AnyView(content.workspaceControlsAppearActive()); channelPrepared = false
    }
    func registerChannelGeometry(_ geometry: FooterMixerStripGeometryView) {
        channelGeometry = geometry
        if let channelViewport { geometry.setViewportHeight(max(0, channelViewport.height - 10)) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { channelPrepared = false; channelRootNeedsLayout = true }
    }
    @discardableResult func setChannelFrame(_ viewport: NSRect) -> Bool {
        channelViewport = viewport
        if channelGeometry == nil, !usesChannelGeometry || !channelRootNeedsLayout {
            func find(_ view: NSView) -> FooterMixerStripGeometryView? {
                if let geometry = view as? FooterMixerStripGeometryView { return geometry }
                for child in view.subviews { if let found = find(child) { return found } }
                return nil
            }
            channelGeometry = find(self)
        }
        var hosted = viewport
        if usesChannelGeometry || channelGeometry != nil {
            // The native channel owns its visible geometry. Keep the outer
            // SwiftUI decorations at one proposal instead of re-laying out its
            // context menus, sheets and overlays on every vertical pixel.
            hosted.size.height = max(724, viewport.height)
            channelGeometry?.setViewportHeight(max(0, viewport.height - 10))
        }
        let changedProposal = frame.size != hosted.size
        if changedProposal { channelRootNeedsLayout = true; channelPrepared = false }
        if frame != hosted { frame = hosted }
        return changedProposal
    }
    override func layout() {
        // Cached channels retain their window and controls. Ventura still
        // requests layout for hidden roots as the surrounding clip moves;
        // defer their SwiftUI work until this channel is visible again.
        guard !isHiddenOrHasHiddenAncestor else { return }
        if channelGeometry != nil, !channelRootNeedsLayout,
           NativeSidebarResizeActivity.shared.canRetainTimelineHeight(in: window),
           NativeSidebarResizeActivity.shared.deferUnchangedLayout(self) { return }
        channelRootNeedsLayout = false
        super.layout()
        // A hosting view can first materialize its representable only after
        // joining a window. Reconcile that first geometry without a wheel event.
        if let channelViewport { setChannelFrame(channelViewport) }
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        needsLayout = true
    }
    @discardableResult func prepareChannelContent() -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor, let channelViewport,
              channelViewport.width > 0, channelViewport.height > 0 else { return false }
        if channelRootNeedsLayout || channelGeometry == nil {
            layoutSubtreeIfNeeded()
            channelRootNeedsLayout = false
        }
        // The first SwiftUI pass creates the native channel geometry. Apply
        // its real viewport now, then commit the nested control/slot hosts
        // before exposing this channel. Ventura otherwise leaves those hosts
        // empty until a later display cycle while the clip is already moving.
        setChannelFrame(channelViewport)
        if let channelGeometry {
            // Its own viewport drives the controls. Re-running the entire outer
            // SwiftUI tree after setting that viewport duplicates the cold
            // channel layout work during wheel input on Ventura.
            channelGeometry.prepareForDisplay()
        }
        channelPrepared = true
        return true
    }
}
/// Only the FX viewport changes size during a mixer height drag. The lower
/// controls retain their SwiftUI proposal and move as one native rectangle.
private struct FooterMixerStripContentKey: Equatable {
    let controller: ObjectIdentifier
    let session: UUID
    let track: Track
    let number: Int?
    let active: Bool
    let focused: Bool
    let includesIcon: Bool
    let stripe: Bool
    let locale: Locale
    let colorScheme: ColorScheme
    var componentMask = 0
    var busSources: [FooterRoutingChannel] = []
    var sendTargets: [UUID: FooterRoutingChannel] = [:]
}
private struct FooterMixerStripGeometry: NSViewRepresentable {
    let iconHeight: CGFloat
    let selected: Bool
    var footerStripe: NSColor? = nil
    let slots: AnyView
    var contentKey: FooterMixerStripContentKey? = nil
    let libraryDrop: NativeLibraryTrackDrop?
    let footer: (CGFloat) -> AnyView
    func makeNSView(context: Context) -> FooterMixerStripGeometryView { FooterMixerStripGeometryView() }
    func updateNSView(_ view: FooterMixerStripGeometryView, context: Context) {
        view.libraryDrop = libraryDrop
        view.update(iconHeight: iconHeight, slots: slots, selected: selected, footerStripe: footerStripe,
                    contentKey: contentKey, footer: footer)
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FooterMixerStripGeometryView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? nsView.frame.height)
    }
}
private final class FooterMixerStripGeometryView: NSView {
    private var slots: FooterMixerHostingView?
    private var pendingSlots: AnyView?
    private let footer = FooterMixerHostingView(rootView: AnyView(EmptyView()))
    private var iconHeight: CGFloat = 0
    private var makeFooter: ((CGFloat) -> AnyView)?
    private var controlsHeight: CGFloat?
    private var viewportHeight: CGFloat?
    private var selected = false
    private var contentKey: FooterMixerStripContentKey?
    private let footerBand = CALayer()
    private let bottomSelection = CALayer()
    var libraryDrop: NativeLibraryTrackDrop?
    func setViewportHeight(_ height: CGFloat) {
        guard viewportHeight != height else { return }
        viewportHeight = height; needsLayout = true
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([NativeLibraryTrackDrop.type])
        wantsLayer = true
        footerBand.name = "track-color-footer"
        footerBand.cornerRadius = 5
        footerBand.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        footerBand.isHidden = true
        layer?.addSublayer(footerBand)
        bottomSelection.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
        layer?.addSublayer(bottomSelection)
        configureHost(footer)
        addSubview(footer)
    }
    required init?(coder: NSCoder) { fatalError() }
    private func configureHost(_ view: FooterMixerHostingView) {
        if #available(macOS 13, *) { view.sizingOptions = [] }
        if #available(macOS 13.3, *) { view.safeAreaRegions = [] }
        view.autoresizingMask = []; view.wantsLayer = true; view.clipsToBounds = true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        libraryDrop?.operation(for: sender, in: self) ?? []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        libraryDrop?.perform(sender, in: self) ?? false
    }
    private func registerWithChannelHost() {
        var ancestor = superview
        while let view = ancestor {
            if let channel = view as? FooterMixerHostingView {
                channel.registerChannelGeometry(self)
                return
            }
            ancestor = view.superview
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWithChannelHost()
    }
    func update(iconHeight: CGFloat, slots: AnyView, selected: Bool = false, footerStripe: NSColor? = nil,
                contentKey: FooterMixerStripContentKey? = nil, footer: @escaping (CGFloat) -> AnyView) {
        let stripeColor = footerStripe?.cgColor
        if self.selected != selected || footerBand.backgroundColor != stripeColor {
            self.selected = selected
            CATransaction.begin(); CATransaction.setDisableActions(true)
            footerBand.backgroundColor = stripeColor
            CATransaction.commit()
            updateDecorationFrames()
        }
        guard contentKey == nil || self.contentKey != contentKey || self.iconHeight != iconHeight else { return }
        self.contentKey = contentKey
        self.iconHeight = iconHeight; makeFooter = footer
        pendingSlots = slots; controlsHeight = nil; needsLayout = true
    }
    func prepareForDisplay() {
        layoutSubtreeIfNeeded()
        if let slots, !slots.isHidden { slots.layoutSubtreeIfNeeded() }
        footer.layoutSubtreeIfNeeded()
    }
    override func layout() {
        // A track reorder or project change can replace this representable
        // while retaining the outer hosting view. The new geometry must adopt
        // that host's real viewport before placing its lower controls.
        registerWithChannelHost()
        super.layout()
        let layout = FooterMixerStripLayout(height: viewportHeight ?? bounds.height, iconHeight: iconHeight)
        if controlsHeight != layout.controlsHeight {
            controlsHeight = layout.controlsHeight
            if let makeFooter { footer.rootView = AnyView(makeFooter(layout.controlsHeight).workspaceControlsAppearActive()) }
        }
        let inset = FooterMixerStripLayout.contentInset
        let width = max(0, bounds.width - 2 * inset)
        let top = NSRect(x: inset, y: inset, width: width, height: layout.slotsHeight)
        let bottom = NSRect(x: inset, y: top.maxY, width: width, height: layout.controlsHeight + FooterMixerStripLayout.labelHeight + iconHeight)
        // Compact channels have no room for FX or sends. Install their nested
        // controls the first time they can be seen and keep focus on later resizes.
        let showsSlots = top.height > 0 && top.width > 0
        if showsSlots, let pendingSlots {
            let content = AnyView(pendingSlots.workspaceControlsAppearActive())
            if let slots {
                slots.rootView = content
            } else {
                let view = FooterMixerHostingView(rootView: content)
                configureHost(view)
                view.frame = top
                addSubview(view, positioned: .below, relativeTo: footer)
                slots = view
            }
            self.pendingSlots = nil
        }
        if let slots {
            if slots.isHidden == showsSlots { slots.isHidden = !showsSlots }
            if slots.frame != top { slots.frame = top }
        }
        if footer.frame != bottom { footer.frame = bottom }
        updateDecorationFrames()
    }
    private func updateDecorationFrames() {
        let height = max(0, viewportHeight ?? bounds.height)
        let bandHeight = min(height, FooterMixerStripLayout.colorFooterHeight)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        footerBand.isHidden = footerBand.backgroundColor == nil
        // The host keeps its full proposal while the channel scroll view clips
        // to the actual mixer height. Anchor the color to the visible footer.
        footerBand.frame = NSRect(x: 0, y: height - bandHeight, width: bounds.width, height: bandHeight)
        bottomSelection.isHidden = !selected || viewportHeight == nil
        bottomSelection.frame = NSRect(x: 0, y: max(0, height - 0.5), width: bounds.width, height: 0.5)
        CATransaction.commit()
    }
}
/// Fixed FX document: changing its viewport height never proposes a new
/// size to every slot button and native context target.
private final class FooterEffectSlotsViewport: NSView {
    private let scroll = NSScrollView()
    private let document = FooterMixerDocumentView()
    private let host = FooterMixerHostingView(rootView: AnyView(EmptyView()))
    private let track = CALayer(), thumb = CALayer()
    private var contentHeight: CGFloat = 0
    private var boundsObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        if #available(macOS 13, *) { host.sizingOptions = [] }
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        document.addSubview(host); scroll.documentView = document; addSubview(scroll)
        track.backgroundColor = NSColor(calibratedRed: 84.0/255, green: 1, blue: 147.0/255, alpha: 0.15).cgColor
        thumb.backgroundColor = NSColor(calibratedRed: 84.0/255, green: 1, blue: 147.0/255, alpha: 1).cgColor
        track.cornerRadius = 1; thumb.cornerRadius = 1; layer?.addSublayer(track); layer?.addSublayer(thumb)
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.updateThumb() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    func update(content: AnyView, height: CGFloat) {
        host.rootView = AnyView(content.workspaceControlsAppearActive()); contentHeight = max(0, height); needsLayout = true
    }
    override func layout() {
        super.layout()
        if scroll.frame != bounds { scroll.frame = bounds }
        let frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: contentHeight)
        if host.frame != frame { host.frame = frame }
        if document.frame != frame { document.frame = frame }
        updateThumb()
    }
    private func updateThumb() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let height = bounds.height, visible = contentHeight > height + 1 && height > 0
        track.isHidden = !visible; thumb.isHidden = !visible
        guard visible else { return }
        let length = min(height, max(12, height * height / contentHeight))
        let fraction = min(1, max(0, scroll.contentView.bounds.minY / (contentHeight - height)))
        track.frame = NSRect(x: max(0, bounds.width - 2), y: 0, width: 2, height: height)
        thumb.frame = NSRect(x: track.frame.minX, y: (height - length) * fraction, width: 2, height: length)
    }
}
/// Height changes partition two existing native viewports. Their fixed slot
/// documents and button roots only update when the parent supplies new content.
private struct FooterSlotSectionsNative: NSViewRepresentable {
    let plugins: AnyView
    let pluginsHeight: CGFloat
    let outputs: AnyView
    let header: AnyView?
    let outputsHeight: CGFloat
    let bypass: AnyView
    let main: Bool
    let separatedRouting: Bool
    func makeNSView(context: Context) -> FooterSlotSectionsView { FooterSlotSectionsView() }
    func updateNSView(_ view: FooterSlotSectionsView, context: Context) {
        view.update(plugins: plugins, pluginsHeight: pluginsHeight, outputs: outputs, outputsHeight: outputsHeight,
                    bypass: bypass, main: main, header: header, separatedRouting: separatedRouting)
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FooterSlotSectionsView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? nsView.frame.height)
    }
}
private final class FooterSlotSectionsView: NSView {
    private let plugins = FooterEffectSlotsViewport()
    private var outputs: FooterEffectSlotsViewport?
    private var sendHost: NSHostingView<AnyView>?
    private var bypassHost: NSHostingView<AnyView>?
    private var pendingOutputs: AnyView?
    private var pendingHeader: AnyView?
    private var pendingBypass: AnyView?
    private var hasHeader = false
    private var main = false
    private var outputsHeight: CGFloat = 0
    private var separatedRouting = false
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.masksToBounds = true; autoresizesSubviews = false
        addSubview(plugins)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(plugins: AnyView, pluginsHeight: CGFloat, outputs: AnyView, outputsHeight: CGFloat,
                bypass: AnyView, main: Bool, header: AnyView?, separatedRouting: Bool) {
        hasHeader = header != nil
        pendingHeader = header; pendingBypass = bypass
        pendingOutputs = outputsHeight > 0 ? outputs : nil
        self.main = main; self.outputsHeight = outputsHeight; self.separatedRouting = separatedRouting
        self.plugins.update(content: plugins, height: pluginsHeight)
        needsLayout = true
    }
    private func place(_ host: NSHostingView<AnyView>?, content: AnyView?, frame: NSRect) -> NSHostingView<AnyView>? {
        guard frame.height > 0 && frame.width > 0 else {
            if let host, !host.isHidden { host.isHidden = true }
            return host
        }
        if let host {
            if let content { host.rootView = content }
            if host.frame != frame { host.frame = frame }
            if host.isHidden { host.isHidden = false }
            return host
        }
        guard let content else { return nil }
        let view = NSHostingView(rootView: content)
        if #available(macOS 13, *) { view.sizingOptions = [] }
        if #available(macOS 13.3, *) { view.safeAreaRegions = [] }
        view.frame = frame; addSubview(view)
        return view
    }
    override func layout() {
        super.layout()
        let sections = FooterSlotSectionsLayout(height: bounds.height, hasRouting: outputsHeight > 0 || hasHeader,
                                                main: main, separatedRouting: separatedRouting)
        let pluginsFrame = NSRect(x: 0, y: 0, width: bounds.width, height: sections.pluginsHeight)
        if plugins.frame != pluginsFrame { plugins.frame = pluginsFrame }
        let routingY = bounds.height - sections.outputsHeight
        let headerHeight = hasHeader ? min(21, sections.outputsHeight) : 0
        let headerFrame = NSRect(x: 0, y: routingY, width: bounds.width, height: headerHeight >= 19 ? 19 : 0)
        sendHost = place(sendHost, content: pendingHeader, frame: headerFrame)
        if sendHost?.isHidden == false { pendingHeader = nil }
        let middle = NSRect(x: 0, y: sections.pluginsHeight, width: bounds.width, height: sections.dividerHeight)
        bypassHost = place(bypassHost, content: pendingBypass, frame: middle)
        if bypassHost?.isHidden == false { pendingBypass = nil }

        let outputsFrame = NSRect(x: 0, y: routingY + headerHeight, width: bounds.width,
                                  height: max(0, sections.outputsHeight - headerHeight))
        if outputsHeight > 0 && !outputsFrame.isEmpty {
            if outputs == nil { let view = FooterEffectSlotsViewport(); addSubview(view); outputs = view }
            if let outputs {
                if let pendingOutputs { outputs.update(content: pendingOutputs, height: outputsHeight); self.pendingOutputs = nil }
                if outputs.frame != outputsFrame { outputs.frame = outputsFrame }
                if outputs.isHidden { outputs.isHidden = false }
            }
        } else if let outputs, !outputs.isHidden { outputs.isHidden = true }
    }
}
private final class FooterMixerScrollView: NSView {
    var usesChannelGeometry = false
    private var lastRevealRequest: UUID?
    private var pendingReveal: (track: UUID, request: UUID)?
    private var wheelVelocity = NativeMixerScrollVelocity()
    private let scroll = NSScrollView()
    private let bar = GridNativeScrollView.GreenScroller(frame: NSRect(x: 0, y: 0, width: 200, height: 14))
    private let host = FooterMixerDocumentView()
    private var master: FooterMixerHostingView?
    private var masterWidth: CGFloat = 0
    private var masterRight = false
    private var masterVersion: UInt64?
    private var strips: [Int: FooterMixerHostingView] = [:]
    private var identifiers: [UUID]?
    private var versions: [UInt64]?
    private var mountedVersions: [Int: UInt64] = [:]
    private var cachedStrips: [Int: (view: FooterMixerHostingView, version: UInt64?)] = [:]
    private var cachedStripOrder: [Int] = []
    private var project: UUID?
    private var filteredStrips: [(id: UUID, view: FooterMixerHostingView)] = []
    private var contentWidth: CGFloat = 1
    private var makeContent: ((Range<Int>) -> AnyView)?
    private var retainStrip: (Int) -> Bool = { _ in false }
    private var reserveRange = 0..<0
    private var prefersLeadingReserve = false
    private var preparedRange: Range<Int> = 0..<0
    private var trackCount = 1
    private var trackStride: CGFloat = 153
    private var preparing = false
    private var pendingStripLayout: Set<Int> = []
    private var layoutWarmup: DispatchWorkItem?
    private var wheelMonitor: Any?
    func setScrollRailColor(_ color: NSColor) {
        if bar.slotColor != color { bar.slotColor = color }
    }
    func configureEmptyArea(trackWidth: CGFloat, addTrack: @escaping () -> Void) {
        host.occupiedWidth = trackWidth
        host.addTrack = addTrack
    }
    private var coastTimer: Timer?
    private weak var coastTarget: NSScrollView?
    private var coastHorizontal = true
    private var coastRemaining: CGFloat = 0
    private var coastFrame = 0.0
    private var boundsObserver: NSObjectProtocol?
    private var movingClip = false
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 242) }
    override var fittingSize: NSSize { frame.size }
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        host.wantsLayer = true
        scroll.documentView = host; addSubview(scroll); addSubview(bar)
        bar.scrollerStyle = .legacy; bar.controlSize = .small; bar.target = self; bar.action = #selector(moveBar)
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.movingClip else { return }
                self.prepare(at: self.scroll.contentView.bounds.minX)
                self.syncBar()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        coastTimer?.invalidate(); layoutWarmup?.cancel()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }
    override func viewDidHide() {
        super.viewDidHide()
        stopCoast()
        layoutWarmup?.cancel(); layoutWarmup = nil
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        needsLayout = true
        scheduleStripWarmup()
    }
    func updateMaster(content: AnyView, width: CGFloat, version: UInt64, right: Bool = false) {
        if let master {
            if masterVersion != version { master.setChannelContent(content) }
        } else {
            let view = FooterMixerHostingView(rootView: AnyView(content.workspaceControlsAppearActive()))
            view.usesChannelGeometry = usesChannelGeometry
            if #available(macOS 13, *) { view.sizingOptions = [] }
            if #available(macOS 13.3, *) { view.safeAreaRegions = [] }
            view.wantsLayer = true; view.clipsToBounds = true; master = view; addSubview(view, positioned: .below, relativeTo: scroll)
        }
        masterVersion = version
        if masterWidth != width || masterRight != right {
            masterWidth = width; masterRight = right; needsLayout = true
        }
    }
    func update(content: AnyView, width: CGFloat) {
        update(width: width, stride: width, count: 1, makeContent: { _ in content })
    }
    func update(width: CGFloat, stride: CGFloat, count: Int, versions: [UInt64]? = nil, identifiers: [UUID]? = nil,
                project: UUID? = nil, trackExists: (UUID) -> Bool = { _ in false },
                retainStrip: @escaping (Int) -> Bool = { _ in false }, makeContent: @escaping (Range<Int>) -> AnyView) {
        let sameProject = self.project == project
        self.project = project
        filteredStrips.removeAll { channel in
            if sameProject && trackExists(channel.id) { return false }
            channel.view.removeFromSuperview()
            return true
        }
        if let old = self.identifiers, let identifiers, old != identifiers {
            // Inserting a copied track shifts indices, not the identity of all
            // following channels. Move their retained hosts to the new slots.
            let positions = Dictionary(uniqueKeysWithValues: identifiers.enumerated().map { ($0.element, $0.offset) })
            func destination(_ index: Int) -> Int? { old.indices.contains(index) ? positions[old[index]] : nil }
            // Switching signal filters can temporarily hide the entire viewport.
            // Reuse those controls on return and let their new render version refresh them.
            let filterLimit = min(24, max(1, Int(ceil(scroll.contentSize.width / max(1, stride))) + 2))
            func hideFiltered(_ view: FooterMixerHostingView, at index: Int) {
                guard sameProject, old.indices.contains(index), trackExists(old[index]) else {
                    view.removeFromSuperview()
                    return
                }
                if let responder = window?.firstResponder as? NSView, responder === view || responder.isDescendant(of: view) {
                    window?.makeFirstResponder(nil)
                }
                view.isHidden = true
                filteredStrips.append((old[index], view))
            }
            var next: [Int: FooterMixerHostingView] = [:]
            for (index, view) in strips {
                if let target = destination(index) { next[target] = view } else { hideFiltered(view, at: index) }
            }
            strips = next
            mountedVersions = Dictionary(uniqueKeysWithValues: mountedVersions.compactMap { index, value in destination(index).map { ($0, value) } })
            var cached: [Int: (view: FooterMixerHostingView, version: UInt64?)] = [:]
            for (index, entry) in cachedStrips {
                if let target = destination(index) { cached[target] = entry } else { entry.view.removeFromSuperview() }
            }
            cachedStrips = cached
            cachedStripOrder = cachedStripOrder.compactMap(destination)
            filteredStrips.removeAll { channel in
                guard let index = positions[channel.id] else { return false }
                cachedStrips[index] = (channel.view, nil)
                cachedStripOrder.append(index)
                return true
            }
            while filteredStrips.count > filterLimit { filteredStrips.removeFirst().view.removeFromSuperview() }
            pendingStripLayout = Set(pendingStripLayout.compactMap(destination))
        }
        self.identifiers = identifiers
        let geometryChanged = contentWidth != width || trackStride != stride || trackCount != count
        contentWidth = width; trackStride = stride; trackCount = count; self.versions = versions; self.makeContent = makeContent
        self.retainStrip = retainStrip
        for index in cachedStripOrder where index >= count {
            cachedStrips.removeValue(forKey: index)?.view.removeFromSuperview()
        }
        cachedStripOrder.removeAll { $0 >= count }
        prepare(at: scroll.contentView.bounds.minX, force: true)
        if geometryChanged { needsLayout = true }
    }
    private func releaseUnusedStrips() {
        let focused = window?.firstResponder as? NSView
        for index in Array(strips.keys) where !preparedRange.contains(index) {
            guard let strip = strips[index] else { continue }
            let ownsFocus = focused.map { $0 === strip || $0.isDescendant(of: strip) } ?? false
            if index < trackCount && (ownsFocus || retainStrip(index)) { continue }
            strips.removeValue(forKey: index)
            let version = mountedVersions.removeValue(forKey: index)
            pendingStripLayout.remove(index)
            if index < trackCount {
                // Keep recently visited channels in their existing hierarchy.
                // Reparenting NSHostingView can detach its nested controls even
                // when the new parent belongs to the same window.
                strip.isHidden = true
                cachedStrips[index] = (strip, version)
                cachedStripOrder.removeAll { $0 == index }; cachedStripOrder.append(index)
            } else { strip.removeFromSuperview() }
        }
        let cacheLimit = max(0, min(64, max(24, preparedRange.count * 3)) - filteredStrips.count)
        while cachedStripOrder.count > cacheLimit {
            // A reversal caches the old viewport before mounting the new
            // one. Never evict a cached destination strip in that interval.
            guard let victim = cachedStripOrder.firstIndex(where: { !preparedRange.contains($0) }) else { break }
            cachedStrips.removeValue(forKey: cachedStripOrder.remove(at: victim))?.view.removeFromSuperview()
        }
    }
    private func prepare(at x: CGFloat, force: Bool = false, beforeScroll: Bool = false, warmReserve: Bool = false) {
        guard !preparing, let makeContent else { return }
        let viewportWidth = max(1, scroll.contentSize.width > 0 ? scroll.contentSize.width : bounds.width)
        let first = max(0, min(trackCount - 1, Int(max(0, x) / trackStride)))
        let last = min(trackCount, Int(ceil((max(0, x) + viewportWidth) / trackStride)))
        reserveRange = max(0, first - 2)..<min(trackCount, last + 2)
        if beforeScroll && x != scroll.contentView.bounds.minX {
            prefersLeadingReserve = x < scroll.contentView.bounds.minX
        }
        // Mount the destination before scrolling. Keep the nearby channels that
        // already exist, and fill spare positions one at a time between events.
        let retained = preparedRange.clamped(to: reserveRange)
        var lower = retained.isEmpty ? first : min(first, retained.lowerBound)
        var upper = retained.isEmpty ? last : max(last, retained.upperBound)
        if warmReserve {
            if lower > reserveRange.lowerBound && (prefersLeadingReserve || upper == reserveRange.upperBound) { lower -= 1 }
            else if upper < reserveRange.upperBound { upper += 1 }
        }
        let next = lower..<upper
        if !force && next == preparedRange {
            if strips.count > preparedRange.count { releaseUnusedStrips() }
            if beforeScroll { layoutVisibleStrips(in: first..<last) }
            scheduleStripWarmup()
            return
        }
        preparedRange = next
        preparing = true
        releaseUnusedStrips()
        for index in preparedRange {
            let strip: FooterMixerHostingView
            let version = versions.flatMap { index < $0.count ? $0[index] : nil }
            var changed = false
            if let cached = strips[index] {
                strip = cached
                if force && (version == nil || mountedVersions[index] != version) {
                    // Scalar edits keep this channel's bounds. Let AppKit coalesce
                    // its normal layout pass instead of forcing one per autofader tick.
                    strip.setChannelContent(makeContent(index..<(index + 1)))
                }
            } else if let cached = cachedStrips.removeValue(forKey: index) {
                cachedStripOrder.removeAll { $0 == index }
                strip = cached.view
                // Edits/reorders/visibility changes can happen while detached.
                // Always validate the version here, including normal scrolling.
                if version == nil || cached.version != version {
                    strip.setChannelContent(makeContent(index..<(index + 1)))
                }
                strips[index] = strip
                if strip.superview !== host { host.addSubview(strip) }
                strip.isHidden = false
                changed = !strip.channelPrepared
            } else {
                strip = FooterMixerHostingView(rootView: AnyView(makeContent(index..<(index + 1)).workspaceControlsAppearActive()))
                if #available(macOS 13, *) { strip.sizingOptions = [] }; strip.wantsLayer = true
                strip.clipsToBounds = true
                // The scroll container supplies an explicit channel rectangle;
                // window safe-area changes must not remeasure every channel.
                if #available(macOS 13.3, *) { strip.safeAreaRegions = [] }
                strip.usesChannelGeometry = usesChannelGeometry
                strips[index] = strip; changed = true
            }
            mountedVersions[index] = version
            let frame = stripFrame(index, height: scroll.contentSize.height)
            if strip.setChannelFrame(frame) { changed = true }
            if strip.superview !== host { host.addSubview(strip) }
            if changed || (!strip.channelPrepared && (strip.window == nil || strip.isHiddenOrHasHiddenAncestor)) { pendingStripLayout.insert(index) }
        }
        preparing = false
        // Static opening and resizing already have an AppKit layout pass.
        // Flush the destination here only when the scroll origin will move
        // before that pass, so an uncached strip cannot flash in empty.
        if beforeScroll { layoutVisibleStrips(in: first..<last) }
        scheduleStripWarmup()
    }
    private func stripFrame(_ index: Int, height: CGFloat) -> NSRect {
        NSRect(x: CGFloat(index) * trackStride, y: 0, width: trackStride + 7, height: height)
    }
    private func layoutVisibleStrips(in range: Range<Int>) {
        guard !pendingStripLayout.isEmpty else { return }
        for index in range where pendingStripLayout.contains(index) {
            if strips[index]?.prepareChannelContent() == true { pendingStripLayout.remove(index) }
        }
    }
    private func scheduleStripWarmup() {
        guard layoutWarmup == nil, window != nil,
              !pendingStripLayout.isEmpty || preparedRange != reserveRange else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.layoutWarmup = nil
            guard self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return }
            if let index = self.pendingStripLayout.min() {
                if self.strips[index]?.prepareChannelContent() == true {
                    self.pendingStripLayout.remove(index)
                    self.scheduleStripWarmup()
                }
            } else if self.preparedRange != self.reserveRange {
                self.prepare(at: self.scroll.contentView.bounds.minX, warmReserve: true)
            }
        }
        layoutWarmup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: work)
    }

    override func layout() {
        super.layout()
        let reserved = master == nil ? 0 : masterWidth + 3
        let trackStart = masterRight ? 0 : reserved
        let trackWidth = max(0, bounds.width - reserved)
        let barFrame = NSRect(x: trackStart + 4, y: 1, width: max(0, trackWidth - 8), height: 14)
        let scrollFrame = NSRect(x: trackStart, y: 16, width: trackWidth, height: max(0, bounds.height - 16))
        if let master {
            let frame = NSRect(x: masterRight ? max(0, bounds.width - masterWidth - 10) : 0,
                               y: 16, width: masterWidth + 10, height: scrollFrame.height)
            master.setChannelFrame(frame)
        }
        if bar.frame != barFrame { bar.frame = barFrame }
        if scroll.frame != scrollFrame {
            movingClip = true
            scroll.frame = scrollFrame
            movingClip = false
        }
        let viewport = scroll.contentSize
        let hostFrame = NSRect(x: 0, y: 0, width: max(viewport.width, contentWidth), height: viewport.height)
        if host.frame != hostFrame { host.frame = hostFrame }
        // Hidden cached channels receive their current height when remounted.
        // Resizing them here reflows up to 64 offscreen SwiftUI trees per pixel.
        for (index, strip) in strips {
            strip.setChannelFrame(stripFrame(index, height: viewport.height))
        }
        move(to: scroll.contentView.bounds.minX)
        if let pendingReveal {
            revealTrack(pendingReveal.track, request: pendingReveal.request, geometryReady: true)
        }
        NativeVerticalTrackMeterView.refreshVisibleMeters(in: scroll.contentView)
    }
    private func syncBar() {
        let range = max(0, host.frame.width - scroll.contentSize.width)
        let enabled = range > 0
        let proportion = min(1, scroll.contentSize.width / max(1, host.frame.width))
        let value = range > 0 ? scroll.contentView.bounds.minX / range : 0
        if bar.isEnabled != enabled { bar.isEnabled = enabled }
        if bar.knobProportion != proportion { bar.knobProportion = proportion }
        if bar.doubleValue != value { bar.doubleValue = value }
    }

    func revealTrack(_ track: UUID?, request: UUID?, geometryReady: Bool = false) {
        guard let request, request != lastRevealRequest, let track,
              let index = identifiers?.firstIndex(of: track) else { return }
        guard !isHiddenOrHasHiddenAncestor, bounds.width > 0 else {
            pendingReveal = (track, request)
            return
        }
        // A selection of an existing channel uses the current native viewport.
        // Force layout only when a new track changed the document dimensions.
        let width = scroll.contentSize.width
        if !geometryReady && (width <= 0 || host.frame.width != max(width, contentWidth)) {
            layoutSubtreeIfNeeded()
        }
        guard scroll.contentSize.width > 0 else { return }
        pendingReveal = nil
        lastRevealRequest = request
        stopCoast()
        let left = CGFloat(index) * trackStride, right = left + trackStride
        let visible = scroll.contentView.bounds
        if left < visible.minX { move(to: left) }
        else if right > visible.maxX { move(to: right - visible.width) }
    }
    private func move(to x: CGFloat) {
        let target = min(max(0, x), max(0, host.frame.width - scroll.contentSize.width))
        let origin = NSPoint(x: target, y: 0)
        let movesClip = scroll.contentView.bounds.origin != origin
        prepare(at: target, beforeScroll: movesClip)
        // One preparation per frame. Scrolling posts a synchronous bounds
        // notification; that notification used to prepare the same strips again.
        if movesClip {
            movingClip = true
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            movingClip = false
        }
        syncBar()
    }
    @objc private func moveBar() {
        stopCoast()
        let range = max(0, host.frame.width - scroll.contentSize.width)
        switch bar.hitPart {
        case .decrementPage: move(to: scroll.contentView.bounds.minX - scroll.contentSize.width * 0.85)
        case .incrementPage: move(to: scroll.contentView.bounds.minX + scroll.contentSize.width * 0.85)
        case .decrementLine: move(to: scroll.contentView.bounds.minX - 40)
        case .incrementLine: move(to: scroll.contentView.bounds.minX + 40)
        default: move(to: bar.doubleValue * range)
        }
    }
    private func stopCoast() { coastTimer?.invalidate(); coastTimer = nil; coastRemaining = 0; coastTarget = nil }
    private func scrollBy(_ distance: CGFloat, target: NSScrollView, horizontal: Bool) {
        if horizontal { move(to: scroll.contentView.bounds.minX - distance); return }
        guard let document = target.documentView else { return }
        let clip = target.contentView
        let range = max(0, clip.documentRect.height - clip.bounds.height)
        let offset = clip.bounds.minY - clip.documentRect.minY
        let y = min(range, max(0, offset + (document.isFlipped ? -distance : distance))) + clip.documentRect.minY
        clip.scroll(to: NSPoint(x: 0, y: y)); target.reflectScrolledClipView(clip)
    }
    private func smoothWheel(_ distance: CGFloat, target: NSScrollView, horizontal: Bool) {
        if coastTarget !== target || coastHorizontal != horizontal || coastRemaining * distance < 0 { stopCoast() }
        coastTarget = target; coastHorizontal = horizontal
        // Respond immediately, then distribute the remaining part of this same
        // wheel step over frames. No extra travel is added after release.
        scrollBy(distance * 0.35, target: target, horizontal: horizontal)
        coastRemaining = min(180, max(-180, coastRemaining + distance * 0.65))
        guard coastTimer == nil else { return }
        coastFrame = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, let target = self.coastTarget, self.window != nil, target.window === self.window,
                  self.window?.attachedSheet == nil, abs(self.coastRemaining) > 0.1 else { self?.stopCoast(); return }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = min(0.05, max(0, now - self.coastFrame)); self.coastFrame = now
            let step = self.coastRemaining * (1 - exp(-elapsed / 0.055)); self.coastRemaining -= step
            self.scrollBy(step, target: target, horizontal: self.coastHorizontal)
        }
        coastTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor); self.wheelMonitor = nil }
        stopCoast()
        layoutWarmup?.cancel(); layoutWarmup = nil
        guard window != nil else { return }
        needsLayout = true // Retry roots first encountered before attachment.
        scheduleStripWarmup()
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.routeWheel(event) == true ? nil : event
        }
    }
    private func effectScroll(at point: NSPoint) -> NSScrollView? {
        func find(in view: NSView) -> NSScrollView? {
            guard !view.isHiddenOrHasHiddenAncestor,
                  view.visibleRect.contains(view.convert(point, from: nil)) else { return nil }
            if let candidate = view as? NSScrollView, candidate !== scroll,
               candidate.contentView.bounds.contains(candidate.contentView.convert(point, from: nil)),
               candidate.contentView.documentRect.height > candidate.contentView.bounds.height + 1 {
                return candidate
            }
            for child in view.subviews { if let found = find(in: child) { return found } }
            return nil
        }
        if let master, let found = find(in: master) { return found }
        for strip in strips.values { if let found = find(in: strip) { return found } }
        return nil
    }
    private func routeWheel(_ event: NSEvent) -> Bool {
        guard window != nil, event.window === window, window?.attachedSheet == nil,
              !isHiddenOrHasHiddenAncestor, !NativeTimelineInputGate.shared.isBlocked(window),
              visibleRect.contains(convert(event.locationInWindow, from: nil)),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            wheelVelocity.reset(); stopCoast(); return false
        }
        if event.phase.contains(.began) { wheelVelocity.reset() }
        // nextEvent inside a monitor pumps nested layout/tracking on Ventura.
        // Native input remains ordered; drawing coalesces in the normal loop.
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        if !horizontal, let target = effectScroll(at: event.locationInWindow) {
            // A slot list only owns vertical scrolling inside its clipped viewport.
            // Consume the event here so AppKit never pans its document sideways.
            wheelVelocity.reset()
            target.horizontalScrollElasticity = .none
            if event.hasPreciseScrollingDeltas {
                stopCoast(); scrollBy(delta, target: target, horizontal: false)
            } else { smoothWheel(delta * 16, target: target, horizontal: false) }
        } else if event.hasPreciseScrollingDeltas {
            stopCoast()
            let movement = wheelVelocity.limit(delta, timestamp: event.timestamp, viewport: scroll.contentSize.width, precise: true)
            move(to: scroll.contentView.bounds.minX - movement)
        } else {
            let movement = wheelVelocity.limit(delta * 16, timestamp: event.timestamp, viewport: scroll.contentSize.width, precise: false)
            smoothWheel(movement, target: scroll, horizontal: true)
        }
        return true
    }


}
#endif

private struct FooterMixerStrip: View, Equatable {
    var masterState: FooterMixerRenderState? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        let sameSelection = lhs.selection == rhs.selection ||
            (lhs.track.map { !lhs.selection.contains($0.id) } ?? true) &&
            (rhs.track.map { !rhs.selection.contains($0.id) } ?? true)
        return lhs.show === rhs.show && lhs.track == rhs.track && sameSelection && lhs.active == rhs.active && lhs.masterState == rhs.masterState && lhs.showsInstrumentIcons == rhs.showsInstrumentIcons && lhs.number == rhs.number && lhs.focused == rhs.focused && lhs.wide == rhs.wide && lhs.componentMask == rhs.componentMask && lhs.busSources == rhs.busSources && lhs.sendTargets == rhs.sendTargets
    }
    let show: ShowController
    let track: Track?
    let selection: Set<UUID>
    let active: Bool
    var showsInstrumentIcons = false
    var number: Int? = nil
    var focused = false
    var wide = false
    var componentMask = 0
    var busSources: [FooterRoutingChannel] = []
    var sendTargets: [UUID: FooterRoutingChannel] = [:]
    private func shows(_ component: HozMixerComponent) -> Bool { track == nil || focused || componentMask & component.bit == 0 }
    private func trackComponentMask() -> Int {
        guard let id else { return 0 }
        return HozMixerComponent.mask(global: UserDefaults.standard.integer(forKey: HozMixerComponent.globalKey),
            override: HozMixerComponent.overrides(UserDefaults.standard.data(forKey: HozMixerComponent.tracksKey) ?? Data())[id] ?? 0)
    }
    private func toggleComponent(_ component: HozMixerComponent) {
        guard let id else { return }
        let defaults = UserDefaults.standard
        var overrides = HozMixerComponent.overrides(defaults.data(forKey: HozMixerComponent.tracksKey) ?? Data())
        let updated = HozMixerComponent.toggled(component.bit, global: defaults.integer(forKey: HozMixerComponent.globalKey),
                                                override: overrides[id] ?? 0)
        overrides[id] = updated == 0 ? nil : updated
        if let data = try? JSONEncoder().encode(overrides) { defaults.set(data, forKey: HozMixerComponent.tracksKey) }
    }
    private var stripWidth: CGFloat? {
        #if os(macOS)
        // The scroll view already sizes each track host to the channel stride.
        // Keep its fader and menus mounted when the width button is pressed.
        if !focused && track != nil { return nil }
        #endif
        return focused || wide || track == nil ? FooterMixerMetrics.masterWidth : FooterMixerMetrics.width
    }
    @WorkspacePreference(MixerTrackStyle.hozMixerKey) private var trackStyle = MixerTrackStyle.defaultStyle
    private var usesStripe: Bool { track != nil && trackStyle == .stripeOnly }
    private var usesNeutralSurface: Bool { track == nil || usesStripe }
    private var nameInk: UInt32 { usesNeutralSurface ? MixerTrackStyle.surfaceTextHex : 0xffffff }
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.editTrackDetails) private var editTrackDetails
    @State private var patchPresented = false
    @StateObject private var sendPicker = FooterSendPresentation()
    @StateObject private var busPicker = FooterSendPresentation()
    @State private var deletion: (project: UUID, song: UUID, tracks: Set<UUID>)?
    #if os(iOS)
    @Environment(\.ipadMixerDialogs) private var ipadMixerDialogs
    @State private var confirmingMainMono = false
    #endif
    private var selected: Bool { id.map { selection.contains($0) } == true }
    private var targets: [UUID?] {
        #if os(macOS)
        let selection = show.mixerTrackSelection
        guard let id, !focused, selection.contains(id), hasStandardControls, let song = show.current else { return [id] }
        let visible = TrackVisibilityPreferences.shared.state(for: show.snapshot.project.id)
            .visibleTracks(in: song.tracks, area: .barMixer)
        return visible.filter { selection.contains($0.id) && $0.kind == .standard }.map { Optional($0.id) }
        #else
        guard selected, hasStandardControls else { return [id] }
        return (show.current?.tracks ?? []).filter { selection.contains($0.id) && $0.kind == .standard }.map { Optional($0.id) }
        #endif
    }
    private var canLink: Bool { selected && show.current?.linkableTracks(selection) != nil }
    private var isFolder: Bool { id.map { id in show.current?.tracks.contains(where: { $0.parentTrackID == id }) == true } == true }
    private var canGroup: Bool { id.map { show.canCreateTrackGroup($0) } == true }
    private func select() {
        guard let track, let song = show.current else { return }
        defer { show.revealSelectedMixerTrack(track.id) }
        // Unselected channels retain their controls across other selections.
        // Read current targets when the click arrives, including a rapid Cmd-click.
        var ids = show.mixerTrackSelection
        #if os(macOS)
        let flags = TrackSelectionRouter.shared.selectionModifiers ?? NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = show.selectedTrackForActions,
           let start = song.tracks.firstIndex(where: { $0.id == anchor }), let end = song.tracks.firstIndex(where: { $0.id == track.id }) {
            let hidden = TrackVisibilityPreferences.shared.state(for: show.snapshot.project.id).effectiveHidden(in: song.tracks, area: .barMixer)
            ids = Set(song.tracks[min(start, end)...max(start, end)].filter { !hidden.contains($0.id) }.map(\.id))
            show.setMixerTrackSelection(ids, anchor: anchor); return
        }
        if flags.contains(.command) || flags.contains(.control) {
            if ids.contains(track.id) { ids.remove(track.id) } else { ids.insert(track.id) }
        } else { ids = [track.id] }
        #else
        ids = [track.id]
        #endif
        show.setMixerTrackSelection(ids, anchor: track.id)
    }
    private func edit() { editDetails(iconOnly: false) }
    private func editIcon() { editDetails(iconOnly: true) }
    private func openPatch() {
        #if os(macOS)
        WorkspaceToolWindows.openPatch(show: show, track: id, targets: targets)
        #else
        if let ipadMixerDialogs {
            ipadMixerDialogs.openPatch(id, targets)
            return
        }
        patchPresented = true
        #endif
    }
    private func editDetails(iconOnly: Bool) {
        guard let track else { return }
        let ids = Set(targets.compactMap { $0 })
        editTrackDetails(TrackDetailsEditRequest(project: show.snapshot.project.id, tracks: ids,
            name: track.name, color: track.color ?? JarasTheme.roleHex(track.role), instrumentIcon: track.instrumentIcon, iconOnly: iconOnly))
    }
    private func link() {
        guard let song = show.current, let indices = song.linkableTracks(selection) else { return }
        let top = song.tracks[indices[0]]
        show.linkTracks(selection, defaultInput: TrackRecording.shared.defaultInputPatch.firstChannel, color: top.color ?? JarasTheme.roleHex(top.role))
    }
    private var deletionTargets: Set<UUID> {
        guard let track else { return [] }
        let ids = selection.contains(track.id) ? selection : [track.id]
        return ids.intersection((show.current?.tracks ?? []).map(\.id))
    }
    private var duplicateSelection: (() -> Void)? {
        guard track?.role.rawValue != "vinhetas", track?.kind == .standard else { return nil }
        let project = show.snapshot.project.id, song = show.current?.id, ids = deletionTargets
        return {
            guard show.snapshot.project.id == project, show.current?.id == song else { return }
            show.duplicateTracks(ids)
        }
    }
    private func requestDeletion(_ ids: Set<UUID>, project: UUID) {
        guard project == show.snapshot.project.id, let song = show.current else { return }
        let valid = ids.intersection(song.tracks.map(\.id))
        guard !valid.isEmpty else { return }
        if show.snapshot.project.tracksContainItems(valid) {
            deletion = (project, song.id, valid)
        } else { deleteTracks(valid) }
    }
    private func deleteTracks(_ ids: Set<UUID>) {
        show.deleteTracks(ids)
        let remaining = show.mixerTrackSelection.intersection((show.current?.tracks ?? []).map(\.id))
        show.setMixerTrackSelection(remaining, anchor: show.selectedTrackForActions)
    }
    @Environment(\.openFX) private var openFX
    private var id: UUID? { track?.id }
    private var settings: NativeFXSettings { track?.fx ?? masterState?.masterFX ?? NativeFXSettings() }
    private var color: Color { Color(hex: track.map { $0.color ?? JarasTheme.roleHex($0.role) } ?? Project.defaultMasterColor) }
    #if os(iOS)
    @Environment(\.trackMixFeedback) private var trackMixFeedback
    #endif
    private func toggleMixerSwitch(_ command: ShowCommand) {
        show.sendTrackMixerButton(command, target: id)
        #if os(iOS)
        if let track {
            let muted = command == .mute
            trackMixFeedback?.show(track: track.id, name: track.name, control: muted ? .mute : .solo,
                                   value: (muted ? track.mute : track.solo) ? 0 : 1)
        }
        #endif
    }
    private var hasStandardControls: Bool { track == nil || track?.kind == .standard }
    private var showsPhase: Bool { track?.kind == .standard && track?.role.rawValue != "vinhetas" && shows(.phase) }
    private var vuHeight: CGFloat { !focused && shows(.vu) ? TrackMixerVU.stripHeight + 2 : 0 }
    private func buttons(spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            if hasStandardControls && shows(.fx) {
                TrackFXButton(show: show, track: id, settings: settings).jarasHelp("Track")
            }
            if trackShowsMuteSolo(track?.kind) {
                if shows(.mute) {
                Button("M") { toggleMixerSwitch(.mute) }
                    .buttonStyle(CompactTrackButtonStyle(activeColor: (track?.mute ?? (show.snapshot.project.masterMute == true)) ? .red : nil))
                    .modifier(MappingRightClick(track: id, command: "mute")).jarasHelp("Mute")
                }
                if shows(.solo) {
                Button("S") { toggleMixerSwitch(.solo) }
                    .buttonStyle(CompactTrackButtonStyle(activeColor: (track?.solo ?? (show.snapshot.project.masterSolo == true)) ? JarasTheme.yellow : nil))
                    .modifier(MappingRightClick(track: id, command: "solo")).jarasHelp("Solo")
                }
            }
            if track == nil {
                Button {
                    #if os(iOS)
                    confirmingMainMono = true
                    #else
                    show.send(.masterMono)
                    #endif
                } label: {
                    ZStack {
                        Circle().stroke(lineWidth: 1.3).frame(width: 11, height: 11).offset(x: -3.5)
                        Circle().stroke(lineWidth: 1.3).frame(width: 11, height: 11).offset(x: 3.5)
                    }.frame(width: 22, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .foregroundStyle(masterState?.masterMono == true ? JarasTheme.green : JarasTheme.text)
                    .accessibilityLabel("Master Stereo/Mono").accessibilityValue(masterState?.masterMono == true ? "Mono" : "Stereo")
                    .jarasHelp(masterState?.masterMono == true ? "Mono — switch to Stereo" : "Stereo — switch to Mono")
                    #if os(iOS)
                    .mainMonoConfirmation(isPresented: $confirmingMainMono, mono: masterState?.masterMono == true) {
                        show.send(.masterMono)
                    }
                    .onChange(of: masterState?.project) { _ in confirmingMainMono = false }
                    #endif
            }
            if let track, track.kind == .standard {
                if shows(.rec) { TrackRecordButton(show: show, track: track) }
                if shows(.inputMonitor) { TrackInputMonitorButton(show: show, track: track) }
                if showsPhase {
                    PhaseInvertButton(show: show, track: track.id, inverted: track.phaseInverted == true)
                }
            }
            Spacer(minLength: 0)
        }.frame(width: 22).buttonStyle(CompactTrackButtonStyle()).font(.jarasSystem(size: 10, weight: .bold))
    }
    private var peakReadout: some View {
        TrackPeakReadout(peak: id.map { StemAudioPlayback.shared.meter(for: $0).peakHold } ?? StemAudioPlayback.shared.masterMeter.peakHold,
                         compact: true, foreground: .white)
    }
    @ViewBuilder private var slots: some View {
        let outputs = shows(.outputs) ? (track?.outputPatches ?? masterState?.masterOutputs ?? show.snapshot.project.masterOutputPatches) : []
        let destinations = shows(.sends) ? sendSlots : []
        let busRows = showsBus ? busSources.count + 1 : 0
        let rows = max(0, destinations.count - 1) + busRows + outputs.count
        let outputsHeight = max(0, CGFloat(rows) * 21 - 2) + (showsBus ? FooterSlotSectionsLayout.routingDividerHeight : 0)
        let hasRouting = rows > 0 || !destinations.isEmpty
        #if os(macOS)
        GeometryReader { geometry in
            let height = geometry.size.height
            let sections = FooterSlotSectionsLayout(height: height, hasRouting: hasRouting, main: track == nil, separatedRouting: !focused)
            let pluginsHeight = shows(.fx) ? CGFloat(max(3, settings.effectKeys.count + 1)) * 21 - 2 : 0
            let headerHeight = destinations.isEmpty ? CGFloat.zero : min(21, sections.outputsHeight)
            if height > 0 {
                if pluginsHeight <= sections.pluginsHeight && outputsHeight <= sections.outputsHeight - headerHeight {
                    // All rows fit. Keep the channel in a single hosting tree;
                    // wheel input outside an overflowing slot list belongs to the mixer.
                    VStack(spacing: 0) {
                        pluginSlotContent.frame(height: sections.pluginsHeight, alignment: .top)
                        if sections.dividerHeight > 0 { bypassControls.frame(height: sections.dividerHeight) }
                        Spacer(minLength: 0)
                        if let add = destinations.first, headerHeight >= 19 {
                            sendHeader(slot: add.slot).frame(height: headerHeight, alignment: .top)
                        }
                        outputSlotContent(outputs, sends: destinations)
                            .frame(height: max(0, sections.outputsHeight - headerHeight), alignment: .top)
                    }.frame(height: height, alignment: .top)
                } else {
                    FooterSlotSectionsNative(plugins: AnyView(pluginSlotContent.environment(\.openFX, openFX)
                        .environment(\.locale, locale).environment(\.colorScheme, colorScheme)),
                        pluginsHeight: pluginsHeight,
                        outputs: AnyView(outputSlotContent(outputs, sends: destinations).environment(\.locale, locale).environment(\.colorScheme, colorScheme)),
                        header: destinations.first.map { AnyView(sendHeader(slot: $0.slot)) }, outputsHeight: outputsHeight,
                        bypass: AnyView(bypassControls), main: track == nil, separatedRouting: !focused)
                }
            }
        }.clipped()
        #else
        GeometryReader { geometry in
            let sections = FooterSlotSectionsLayout(height: geometry.size.height, hasRouting: hasRouting,
                                                    main: track == nil, separatedRouting: !focused)
            VStack(spacing: 0) {
                if shows(.fx) && sections.pluginsHeight >= 19 {
                    pluginSlots.frame(height: sections.pluginsHeight).clipped()
                }
                if sections.dividerHeight > 0 { bypassControls.frame(height: sections.dividerHeight) }
                Spacer(minLength: 0)
                if sections.outputsHeight > 0 {
                    let headerHeight = destinations.isEmpty ? CGFloat.zero : min(21, sections.outputsHeight)
                    if let add = destinations.first, headerHeight >= 19 {
                        sendHeader(slot: add.slot).frame(height: headerHeight, alignment: .top)
                    }
                    FooterEffectSlotsScroll(contentHeight: outputsHeight) {
                        outputSlotContent(outputs, sends: destinations)
                    }.frame(height: max(0, sections.outputsHeight - headerHeight)).clipped()
                }
            }.frame(height: geometry.size.height, alignment: .top).clipped()
        }.clipped()
        #endif
    }
    private var bypassControls: some View {
        GeometryReader { geometry in
            if shows(.fx) {
            VStack(spacing: 0) {
                Rectangle().fill(JarasTheme.line).frame(height: 1)
                bypassButton("By All Fx", active: settings.mixerBypassRestore != nil) {
                    show.toggleStripFXBypass(id)
                }.padding(.top, 2).padding(.bottom, 3)
                Rectangle().fill(JarasTheme.line).frame(height: 1)
                if track == nil && geometry.size.height >= FooterSlotSectionsLayout.bypassRowHeight + FooterSlotSectionsLayout.sessionRowHeight {
                    bypassButton("By Fx Session", active: settings.sessionFXBypassed == true) {
                        show.toggleStripFXBypass(nil, sessionWide: true)
                    }.padding(.top, 1)
                    Rectangle().fill(JarasTheme.line).frame(height: 1)
                }
            }
            }
        }
    }
    private func bypassButton(_ name: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(verbatim: name) }
            .buttonStyle(FooterSlotButtonStyle(tone: active ? .bypassActive : .routed))
            .accessibilityAddTraits(active ? .isSelected : [])
    }
    private var pluginSlots: some View {
        FooterEffectSlotsScroll(contentHeight: CGFloat(max(3, settings.effectKeys.count + 1)) * 21 - 2) {
            pluginSlotContent
        }
    }
    @ViewBuilder private var pluginSlotContent: some View {
        if shows(.fx) { VStack(spacing: 2) {
            ForEach(settings.effectKeys, id: \.self) { effect in
                FooterEffectSlot(show: show, track: id, effect: effect, settings: settings)
            }
            ForEach(0..<max(1, 3 - settings.effectKeys.count), id: \.self) { _ in
                FooterEffectSlot(show: show, track: id, effect: nil, settings: settings)
            }
        } }
    }
    private var sendSlots: [(slot: Int, destination: UUID?)] {
        guard let track else {
            let routes = masterState?.mainSends ?? []
            return [(routes.count, nil)] + routes.enumerated().map { ($0.offset, Optional($0.element)) }
        }
        guard track.kind == .standard else { return [] }
        let routes = track.routing?.transmitters ?? []
        let populated = routes.enumerated().compactMap { slot, destination in
            destination.map { (slot: slot, destination: Optional($0)) }
        }
        return [((populated.last?.slot ?? -1) + 1, nil)] + populated
    }
    @ViewBuilder private func sendMenu(slot: Int, destination: UUID) -> some View {
        if let track {
            ForEach(TrackSendTap.allCases, id: \.self) { tap in
                Button {
                    show.setTrackSendTap(track.id, destination: destination, tap: tap)
                } label: {
                    if tap == (track.routing?.sendTap(to: destination) ?? .postFader) {
                        Label(tap.title, systemImage: "checkmark")
                    } else { Text(tap.title) }
                }
            }
        }
        Button("Remove send") {
            if let track { show.setTrackRouting([track.id], receive: false, slot: slot, other: nil) }
            else if !TrackRecording.shared.recording { show.setMainSend(from: destination, to: nil) }
        }
        Button("Change destination") { showSendPicker(slot: slot, destination: destination) }
    }
    private var showsBus: Bool {
        !focused && shows(.sends) && track?.kind == .standard && track?.role.rawValue != "vinhetas"
    }
    private func showSendPicker(slot: Int, destination: UUID?) {
        openRoutePicker(receive: false, slot: slot, current: destination)
    }
    private func showBusPicker() {
        guard let track = id, let song = show.current,
              let row = song.tracks.first(where: { $0.id == track }) else { return }
        let receives = row.routing?.receives ?? []
        let main = row.routing?.mainReceiveSlot
        let slot = receives.indices.first { receives[$0] == nil && $0 != main } ?? receives.count
        openRoutePicker(receive: true, slot: slot, current: nil)
    }
    private func openRoutePicker(receive: Bool, slot: Int, current: UUID?) {
        guard let song = show.current, id != nil || !TrackRecording.shared.recording else { return }
        let routed: Set<UUID>
        if let id {
            routed = Set(song.trackConnections.compactMap { edge in
                if receive && edge.destination == id { return edge.source }
                if !receive && edge.source == id { return edge.destination }
                return nil
            })
        } else { routed = Set(song.tracks.filter(\.receivesMain).map(\.id)) }
        let request = FooterSendPicker.Request(project: show.snapshot.project.id, song: song.id,
            owner: id, receive: receive, slot: slot, current: current, rows: song.tracks.map { target in
            .init(id: target.id, name: target.name, enabled: target.kind == .standard && target.id != id &&
                  (!routed.contains(target.id) || target.id == current))
        })
        #if os(iOS)
        if let ipadMixerDialogs {
            ipadMixerDialogs.openSends(request) { selectRoute($0, request: request) }
            return
        }
        #endif
        (receive ? busPicker : sendPicker).request = request
    }
    private func selectRoute(_ other: UUID, request: FooterSendPicker.Request) {
        (request.receive ? busPicker : sendPicker).request = nil
        guard request.project == show.snapshot.project.id, let song = show.current, song.id == request.song,
              song.tracks.contains(where: { $0.id == other && $0.kind == .standard }) else { return }
        guard let owner = request.owner else {
            if !TrackRecording.shared.recording { show.setMainSend(from: request.current, to: other) }
            return
        }
        guard let row = song.tracks.first(where: { $0.id == owner }), other != owner else { return }
        let slots = (request.receive ? row.routing?.receives : row.routing?.transmitters) ?? []
        let edge = TrackConnection(source: request.receive ? other : owner, destination: request.receive ? owner : other)
        let current = slots.indices.contains(request.slot) ? slots[request.slot] : nil
        guard current == request.current, current != other, !song.trackConnections.contains(edge),
              !request.receive || row.routing?.mainReceiveSlot != request.slot else { return }
        show.setTrackRouting([owner], receive: request.receive, slot: request.slot, other: other)
    }
    private func sendHeader(slot: Int) -> some View {
        FooterRoutingHeader(picker: sendPicker, openPatch: openPatch,
                            chooseTrack: { showSendPicker(slot: slot, destination: nil) }, select: selectRoute) {
            sendSlotLabel("Sends", routed: false)
        }
    }
    private var busHeader: some View {
        FooterRoutingHeader(picker: busPicker, openPatch: openPatch, chooseTrack: showBusPicker, select: selectRoute) {
            sendSlotLabel("Bus", routed: false)
        }
    }
    private func sendSlotLabel(_ name: String, routed: Bool) -> some View {
        Text(verbatim: name).lineLimit(1).font(.jarasSystem(size: 9, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 19, maxHeight: 19)
            .background(RoundedRectangle(cornerRadius: 5).fill(routed ? Color.white.opacity(0.11) : Color.black.opacity(0.18)))
            .contentShape(Rectangle())
    }
    private func outputSlotContent(_ outputs: [OutputPatch], sends: [(slot: Int, destination: UUID?)]) -> some View {
        VStack(spacing: 2) {
            ForEach(sends.dropFirst(), id: \.slot) { row in
                if let destination = row.destination {
                    let channel = masterState?.mainSendTargets[destination] ?? sendTargets[destination]
                    Button(action: openPatch) {
                        sendSlotLabel(channel?.label ?? "—", routed: true)
                    }.buttonStyle(.plain)
                        .contextMenu { sendMenu(slot: row.slot, destination: destination) }
                        .accessibilityLabel(Text(verbatim: "Sends: " + (channel?.name ?? "—")))
                        .jarasHelp(channel?.name ?? "")
                }
            }
            if showsBus {
                Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1)
                    .frame(height: FooterSlotSectionsLayout.routingDividerHeight - 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
                busHeader
                ForEach(busSources) { source in
                    Button(action: openPatch) {
                        HStack(spacing: 3) {
                            Text(verbatim: source.label).lineLimit(1).frame(maxWidth: .infinity)
                            Image(systemName: "arrow.turn.down.left").foregroundStyle(JarasTheme.green)
                                .accessibilityHidden(true)
                        }.font(.jarasSystem(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).frame(height: 19)
                            .background(Color.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "Bus: " + source.name))
                        .jarasHelp("Bus: " + source.name)
                }
            }
            ForEach(Array(outputs.enumerated()), id: \.offset) { _, output in
                Button(action: openPatch) {
                    Text(verbatim: output.firstChannel == -2 ? "M-group" : output.title)
                }.buttonStyle(FooterSlotButtonStyle(tone: output.firstChannel == -1 ? .empty : .routed))
                    .accessibilityLabel("Output: " + output.title)
            }
        }
    }
    private var panAndFader: some View {
        VStack(spacing: 1) {
            let pan = track?.pan ?? masterState?.masterPan ?? 0
            if hasStandardControls && shows(.pan) {
                VStack(spacing: 1) {
                    #if os(macOS)
                    FooterMixerPanReadout(identity: TrackControlIdentity(project: show.snapshot.project.id, track: id),
                                          pan: pan, linkedTrack: track?.stereoLink?.partner)
                        .frame(width: 50, height: 10)
                    #else
                    Text(verbatim: mixerPanText(pan))
                        .font(.jarasSystem(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                        .frame(width: 50, height: 10)
                    #endif
                    FooterMixerControl(show: show, track: id, value: pan, pan: true, linked: track?.stereoLink?.partner)
                        .frame(width: 24, height: 24)
                }
            }
            let gain = track?.volume ?? show.snapshot.project.masterVolume ?? 1
            let faderOffset: CGFloat = hasStandardControls ? 7 : 2
            if shows(.peak) && trackShowsMeterReadouts(track?.kind) {
                peakReadout.frame(width: 50, height: 12).offset(x: faderOffset)
            }
            if shows(.fader) {
            #if os(macOS)
            FooterMixerGainReadout(show: show, identity: TrackControlIdentity(project: show.snapshot.project.id, track: id), gain: gain)
                .frame(width: 50, height: 11).offset(x: faderOffset)
            #else
            MixerPlaybackGain(show: show, track: id, manual: gain) { displayed in
                Text(verbatim: (displayed <= 0 ? "−∞" : String(format: "%+.1f", min(12, max(-60, 20 * log10(displayed))))) + " dB")
                    .font(.jarasSystem(size: 7.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                    .frame(width: 50, height: 11).offset(x: faderOffset)
            }
            #endif
            FooterMixerControl(show: show, track: id, value: gain, pan: false, linked: track?.stereoLink?.partner,
                meter: active ? (id.map { StemAudioPlayback.shared.meter(for: $0) } ?? StemAudioPlayback.shared.masterMeter) : nil)
                .frame(width: 29)
                .background(alignment: .leading) {
                    MixerFaderDecibelScale()
                        .frame(width: 24)
                        .offset(x: (29 - MixerMeterStyle.railThickness) / 2 - 25)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                .offset(x: faderOffset)
                .jarasHelp("Double-click to reset to 0 dB")
            }
        }.frame(width: 50)
    }
    @ViewBuilder private func fixedFooter(controlsHeight: CGFloat) -> some View {
        let icon = showsInstrumentIcons && shows(.icon) ? track?.instrumentIcon : nil
        let spacing: CGFloat = showsPhase && icon != nil ? 2 : 5
        let maxIconSide: CGFloat = focused ? 40 : 24
        let iconLeading: CGFloat = focused ? 6 : 2
        let iconTop = max(controlsHeight - maxIconSide - 8, showsPhase ? 6 * 21 + spacing * 5 + 3 : 120)
        let iconSize = min(maxIconSide, controlsHeight - iconTop - 3)
        VStack(spacing: 0) {
            if vuHeight > 0 {
                ClassicVUMeter(meter: active ? (id.map { StemAudioPlayback.shared.meter(for: $0) } ?? StemAudioPlayback.shared.masterMeter) : nil)
                    .frame(height: TrackMixerVU.stripHeight).padding(.bottom, 2)
            }
            ZStack(alignment: .topLeading) {
                VStack(spacing: 4) {
                    if let track, track.kind == .click || (track.kind == .standard && !focused) {
                        if shows(.patch) || (track.kind == .click ? shows(.insert) : shows(.envelope)) {
                        HStack(spacing: 3) {
                            if shows(.patch) { Button("Patch", action: openPatch).buttonStyle(CompactTrackButtonStyle(width: 34)) }
                            if track.kind == .click && shows(.insert) {
                                Button("Insert") { show.insertClickItems(track: track.id) }
                                    .buttonStyle(CompactTrackButtonStyle(width: 47))
                                    .jarasHelp("Insert click items in regions without a click")
                            } else if track.kind == .standard && shows(.envelope) {
                                TrackEnvelopeButton(show: show, track: track.id, visible: !(track.automation?.visibleEnvelopes.isEmpty ?? true))
                            }
                        }
                        }
                    }
                    HStack(spacing: 3) {
                        buttons(spacing: spacing)
                        panAndFader.frame(maxHeight: .infinity)
                    }.frame(maxWidth: .infinity)
                }
                if let icon, iconSize >= 16 {
                    TrackIconDisplay(id: icon).foregroundStyle(.white).frame(width: iconSize, height: iconSize)
                        .position(x: iconLeading + iconSize / 2, y: iconTop + iconSize / 2).allowsHitTesting(false).accessibilityHidden(true)
                }
            }.frame(height: controlsHeight).trackControlSelectionExclusion()
            Group {
                #if os(macOS)
                if let track {
                    TrackDragTitle(title: track.name, foreground: nameInk, project: show.snapshot.project.id,
                        track: track.id, state: TrackReorderState.shared, select: select, compact: true,
                        editableName: track.fixedName == nil && track.role.rawValue != "vinhetas" ? track.name : nil,
                        rename: { [project = show.snapshot.project.id] in show.renameMixerTrack(track.id, name: $0, project: project) })
                } else { Text("Main").font(.jarasSystem(size: 10, weight: .semibold)) }
                #else
                if let track {
                    let mayRename = track.fixedName == nil && track.role.rawValue != "vinhetas"
                    let project = show.snapshot.project.id
                    InlineMixerTrackName(name: track.name, compact: true, editable: mayRename,
                        select: select, commit: { show.renameMixerTrack(track.id, name: $0, project: project) }) {
                            TrackReorderState.shared.begin(track: track.id); select()
                            return TrackReorderState.provider(track.id)
                        }
                } else {
                    Text("Main").font(.jarasSystem(size: 10, weight: .semibold))
                }
                #endif
            }.frame(maxWidth: .infinity).frame(height: FooterMixerStripLayout.titleHeight)
                .padding(.top, usesStripe ? FooterMixerStripLayout.stripeTitleInset : 4)
                .foregroundStyle(Color(hex: nameInk)).accessibilityHint(Text(verbatim: track?.name ?? "Main"))
            Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1).allowsHitTesting(false)
            Text(verbatim: number.map { String(format: "%02d", $0) } ?? "")
                .font(.jarasSystem(size: 11, weight: .semibold))
                .foregroundStyle(usesStripe ? MixerTrackStyle.surfaceText : .white.opacity(0.8))
                .frame(maxWidth: .infinity).frame(height: FooterMixerStripLayout.numberHeight)
                .accessibilityLabel("Track number")
            if usesStripe {
                Group {
                    if focused { Capsule().fill(color) }
                    else { Color.clear }
                }.frame(height: MixerTrackStyle.hozStripeHeight).allowsHitTesting(false)
            }
        }
    }
    var body: some View {
        let deleteIDs = deletionTargets, deleteProject = show.snapshot.project.id
        let randomizeColors = { show.randomizeTrackColors(deleteIDs, project: deleteProject) }
        Group {
            #if os(macOS)
            FooterMixerStripGeometry(iconHeight: vuHeight, selected: selected,
                footerStripe: usesStripe && !focused ? NSColor(color) : nil,
                slots: AnyView(Group {
                    if hasStandardControls { slots.trackControlSelectionExclusion() }
                    else { Color.clear }
                }.environment(\.openFX, openFX).environment(\.locale, locale).environment(\.colorScheme, colorScheme)),
                contentKey: track.map { FooterMixerStripContentKey(controller: ObjectIdentifier(show),
                    session: show.projectSessionID, track: $0, number: number, active: active, focused: focused,
                    includesIcon: showsInstrumentIcons, stripe: usesStripe, locale: locale, colorScheme: colorScheme,
                    componentMask: componentMask, busSources: busSources, sendTargets: sendTargets) },
                libraryDrop: hasStandardControls ? NativeLibraryTrackDrop(show: show, track: id) : nil,
                footer: { AnyView(fixedFooter(controlsHeight: $0)
                    .environment(\.openFX, openFX).environment(\.editTrackDetails, editTrackDetails)
                    .environment(\.locale, locale).environment(\.colorScheme, colorScheme)) })
            #else
            GeometryReader { geometry in
                let layout = FooterMixerStripLayout(height: geometry.size.height, iconHeight: vuHeight)
                VStack(spacing: 0) {
                    if hasStandardControls && layout.slotsHeight >= 19 {
                        slots.frame(height: layout.slotsHeight).clipped()
                            .trackControlSelectionExclusion()
                    } else { Color.clear.frame(height: layout.slotsHeight) }
                    fixedFooter(controlsHeight: layout.controlsHeight)
                }.padding(FooterMixerStripLayout.contentInset).frame(height: geometry.size.height, alignment: .top).clipped()
            }.clipped()
            #endif
        }.frame(width: stripWidth).frame(maxHeight: .infinity)
            .background {
                if usesNeutralSurface {
                    MixerTrackSurface(selected: selected).clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(color.opacity(selected ? 0.38 : 0.24))
                }
            }
            .overlay(alignment: .top) {
                if !usesNeutralSurface {
                    Capsule().fill(color).frame(height: 2).padding(.horizontal, 2).allowsHitTesting(false)
                }
            }
            #if !os(macOS)
            .overlay {
                if usesStripe && !focused {
                    RoundedRectangle(cornerRadius: 5).fill(color)
                        .mask(alignment: .bottom) {
                            Rectangle().frame(height: FooterMixerStripLayout.colorFooterHeight)
                        }
                        .allowsHitTesting(false)
                }
            }
            #endif
            .modifier(MasterMuteIndicator(muted: track == nil && (masterState?.masterMute ?? (show.snapshot.project.masterMute == true))))
            #if os(macOS)
            .overlay {
                if let track {
                    TrackRightClickInput(project: show.snapshot.project.id, track: track.id, kind: track.kind, dragName: track.name, selected: selected, select: select,
                        patch: openPatch, fx: { openFX(id, "Chain") }, edit: edit, randomColor: randomizeColors, icon: editIcon,
                        group: canGroup ? { show.createTrackGroup(track.id) } : nil,
                        ungroup: isFolder ? { show.ungroupTrack(track.id) } : nil, removeFromGroup: track.parentTrackID != nil ? { show.removeTrackFromGroup(track.id) } : nil,
                        link: canLink ? link : nil, unlink: track.stereoLink != nil ? { show.unlinkTracks(track.id) } : nil,
                        duplicateTracks: duplicateSelection, deleteTracks: { requestDeletion(deleteIDs, project: deleteProject) }, deleteTrackCount: deleteIDs.count,
                        stemLayout: track.stackedStems, organizeStems: { mode in if show.snapshot.project.id == deleteProject { show.setStemLayout(mode, tracks: deleteIDs) } },
                        hozComponentMask: focused ? nil : trackComponentMask, toggleHozComponent: focused ? nil : toggleComponent)
                }
            }
            #else
            .onTapGesture(perform: select)
            .modifier(LibraryTrackEffectDrop(show: hasStandardControls ? show : nil, track: id, acceptsMaster: true))
            #endif
            .modifier(FooterTrackInsertion(show: show, track: id))
            .contextMenu {
                if track == nil {
                    MasterTrackContextMenu(show: show, patch: openPatch,
                        fx: { openFX(id, "Chain") }, masterRight: masterState?.masterRight == true,
                        moveMaster: focused ? nil : { UserDefaults.standard.set(masterState?.masterRight != true, forKey: "catlive.barMixer.masterRight") })
                } else {
                    Button("Patch", action: openPatch)
                    if hasStandardControls { Button("FX") { openFX(id, "Chain") } }
                    Button("Set Track Color", action: edit)
                    Button("Set Random Color", action: randomizeColors)
                    Button("Set Track Icon", action: editIcon)
                    if let duplicateSelection {
                        Button(LocalizedStringKey(deleteIDs.count > 1 ? "Duplicate tracks" : "Duplicate track"), action: duplicateSelection)
                    }
                    if canGroup, let id { Button("Create group") { show.createTrackGroup(id) } }
                    if let id, isFolder { Button("Ungroup") { show.ungroupTrack(id) } }
                    if let track, track.parentTrackID != nil { Button("Remove from group") { show.removeTrackFromGroup(track.id) } }
                    if canLink { Button("Link tracks", action: link) }
                    if let track, track.stereoLink != nil { Button("Unlink tracks") { show.unlinkTracks(track.id) } }
                    if !focused {
                        Menu("Components View") {
                            ForEach(HozMixerComponent.allCases, id: \.self) { component in
                                Button { toggleComponent(component) } label: {
                                    if shows(component) { Label(LocalizedStringKey(component.title), systemImage: "checkmark") }
                                    else { Text(LocalizedStringKey(component.title)) }
                                }
                            }
                        }
                    }
                    if track != nil {
                        Divider()
                        Button(role: .destructive) { requestDeletion(deleteIDs, project: deleteProject) } label: {
                            Text(LocalizedStringKey(deleteIDs.count > 1 ? "Delete tracks" : "Delete track"))
                        }
                    }
                }
            }
            .alert("Delete selected tracks and their items?", isPresented: Binding(
                get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { request in
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    guard request.project == show.snapshot.project.id, request.song == show.current?.id else { return }
                    deleteTracks(request.tracks)
                }
            }
            #if !os(macOS)
            .workspaceEditor("Patch", isPresented: $patchPresented, scrolls: false, size: PatchEditor.windowSize, activates: false) {
                VStack { PatchEditor(show: show, track: id, targets: targets); Button("Close") { patchPresented = false }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            #endif

    }
}

private final class FooterSendPresentation: ObservableObject {
    @Published var request: FooterSendPicker.Request?
}

private struct FooterRoutingHeader<Content: View>: View {
    @ObservedObject var picker: FooterSendPresentation
    let openPatch: () -> Void
    let chooseTrack: () -> Void
    let select: (UUID, FooterSendPicker.Request) -> Void
    @ViewBuilder let label: () -> Content
    var body: some View {
        Button(action: openPatch, label: label).buttonStyle(.plain)
        #if os(macOS)
            .overlay(FooterSendRightClick(open: chooseTrack))
        #else
            .overlay { IpadTapHoldTouchSurface(tap: openPatch, hold: chooseTrack) }
        #endif
            .accessibilityAction(named: Text("Choose track"), chooseTrack)
            .popover(item: $picker.request) { request in
                let content = FooterSendPicker(request: request, select: { select($0, request) })
                    .frame(width: request.size.width, height: request.size.height)
                if #available(iOS 16.4, macOS 13.3, *) {
                    content.presentationCompactAdaptation(.popover).presentationBackground(JarasInterfaceTheme.lightDark.panel)
                } else { content }
            }
    }
}

#if os(iOS)
struct IpadMixerDialogs {
    let openPatch: (UUID?, [UUID?]) -> Void
    let openSends: (FooterSendPicker.Request, @escaping (UUID) -> Void) -> Void
}

private struct IpadMixerDialogsKey: EnvironmentKey {
    static let defaultValue: IpadMixerDialogs? = nil
}

extension EnvironmentValues {
    var ipadMixerDialogs: IpadMixerDialogs? {
        get { self[IpadMixerDialogsKey.self] }
        set { self[IpadMixerDialogsKey.self] = newValue }
    }
}
#endif

struct FooterSendPicker: View {
    struct Destination: Identifiable {
        let id: UUID
        let name: String
        let enabled: Bool
    }
    struct Request: Identifiable {
        let project: UUID
        let song: UUID
        let owner: UUID?
        let receive: Bool
        let slot: Int
        let current: UUID?
        let rows: [Destination]
        var id: Int { slot }
        var count: Int { (rows.count + 19) / 20 }
        @MainActor var size: CGSize {
            var size = CGSize(width: CGFloat(max(1, min(3, count))) * 210 + 26,
                              height: CGFloat(max(1, min(20, rows.count))) * 21 + 68)
            #if os(iOS)
            if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
                size.width = min(size.width, max(1, window.bounds.width - 44))
                size.height = min(size.height, max(1, window.bounds.height - 72))
            }
            #endif
            return size
        }
    }
    let request: Request
    let select: (UUID) -> Void
    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let columns = max(1, min(3, request.count, Int((geometry.size.width + 8) / 180)))
                let width = (geometry.size.width - 8 * CGFloat(columns - 1)) / CGFloat(columns)
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(0..<request.count, id: \.self) { block in
                            let start = block * 20, end = min(start + 20, request.rows.count)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: "\(start + 1)–\(end)").font(.jarasSystem(size: 12, weight: .bold))
                                    .padding(.horizontal, 8).frame(height: 26)
                                ForEach(start..<end, id: \.self) { index in
                                    let target = request.rows[index]
                                    Button { select(target.id) } label: {
                                        HStack(spacing: 8) {
                                            Text(verbatim: String(format: "%02d", index + 1)).monospacedDigit().foregroundStyle(JarasTheme.secondary)
                                            Text(verbatim: target.name).lineLimit(1)
                                            Spacer(minLength: 0)
                                            if target.id == request.current { Image(systemName: "checkmark") }
                                        }.font(.jarasSystem(size: 11, weight: .medium)).padding(.horizontal, 8)
                                            .frame(height: 21).contentShape(Rectangle())
                                    }.buttonStyle(.plain).disabled(!target.enabled)
                                        .background(index.isMultiple(of: 2) ? JarasInterfaceTheme.lightDark.panel : Color.clear)
                                }
                            }.frame(width: max(1, width), alignment: .leading)
                                .background(JarasInterfaceTheme.lightDark.display, in: RoundedRectangle(cornerRadius: 5)).clipped()
                        }
                    }.padding(.bottom, 13)
                }
            }
        }.padding(12).frame(idealWidth: request.size.width, idealHeight: request.size.height)
            .background(JarasInterfaceTheme.lightDark.panel).foregroundStyle(JarasTheme.text)
    }
}

#if os(macOS)
private struct FooterSendRightClick: NSViewRepresentable {
    let open: () -> Void
    final class Target: RightClickTargetView { override var priority: Int { 3 } }
    func makeNSView(context: Context) -> Target { Target() }
    func updateNSView(_ view: Target, context: Context) { view.action = open }
}
#endif

struct FooterEffectTransfer: Codable {
    static let type = UTType(exportedAs: "com.catlive.mixer-effect", conformingTo: .data)
    static let libraryType = UTType(exportedAs: "com.catlive.library-effect", conformingTo: .data)
    let project: UUID
    let source: UUID?
    let effect: String
    var library = false
    var presetID: String?
    var contentType: UTType { library ? Self.libraryType : Self.type }
    var provider: NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: contentType.identifier, visibility: .ownProcess) { completion in
            completion(data, nil); return nil
        }
        return provider
    }
    @MainActor func apply(to track: UUID?, before target: String?, show: ShowController) -> Bool {
        guard project == show.snapshot.project.id else { return false }
        if library { return LibraryEffectInsertion.apply(identity: effect, presetID: presetID, to: track, before: target, show: show) != nil }
        if source == track {
            guard show.canControl(), show.fxSettings(track).inserted.contains(effect) else { return false }
            show.reorderFX(track, effect: effect, before: target)
            return true
        }
        return show.copyFX(from: source, effect: effect, to: track, before: target) != nil
    }
}
#if os(macOS)
@MainActor struct NativeLibraryTrackDrop {
    static let type = NSPasteboard.PasteboardType(FooterEffectTransfer.libraryType.identifier)
    private let show: ShowController
    private let track: UUID?
    private let project: UUID
    private let session: UUID

    init(show: ShowController, track: UUID?) {
        self.show = show
        self.track = track
        project = show.snapshot.project.id
        session = show.projectSessionID
    }

    private func transfer(from sender: NSDraggingInfo, in view: NSView) -> FooterEffectTransfer? {
        guard let window = view.window, window.attachedSheet == nil,
              !NativeTimelineInputGate.shared.isBlocked(window), !TrackReorderState.shared.active,
              show.snapshot.project.id == project, show.projectSessionID == session,
              view.visibleRect.contains(view.convert(sender.draggingLocation, from: nil)),
              let data = sender.draggingPasteboard.data(forType: Self.type),
              let payload = try? JSONDecoder().decode(FooterEffectTransfer.self, from: data),
              payload.library, payload.project == project else { return nil }
        return payload
    }

    func operation(for sender: NSDraggingInfo, in view: NSView) -> NSDragOperation {
        transfer(from: sender, in: view) == nil ? [] : .copy
    }

    func perform(_ sender: NSDraggingInfo, in view: NSView) -> Bool {
        guard let effect = transfer(from: sender, in: view), effect.apply(to: track, before: nil, show: show) else { return false }
        if effect.effect == "native:" + NativeFXSettings.waveLFOName {
            NativeTimelineKeyboardFocus.activate(window: view.window, responder: nil)
        }
        return true
    }
}
#endif
struct LibraryTrackEffectDrop: ViewModifier {
    let show: ShowController?
    let track: UUID?
    var acceptsMaster = false
    @State private var targeted = false
    @ViewBuilder func body(content: Content) -> some View {
        if let show, track != nil || acceptsMaster {
            content
                .contentShape(Rectangle())
                .overlay { if targeted { Rectangle().fill(JarasTheme.green.opacity(0.18)).allowsHitTesting(false) } }
                .onDrop(of: [FooterEffectTransfer.libraryType], delegate: FooterEffectDrop(show: show, track: track,
                    effect: nil, targeted: $targeted, libraryOnly: true))
        } else { content }
    }
}
struct LibraryItemEffectDrop: ViewModifier {
    let show: ShowController
    let clip: UUID
    @Binding var selected: String?
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .overlay { if targeted { RoundedRectangle(cornerRadius: 4).strokeBorder(JarasTheme.green).allowsHitTesting(false) } }
            .onDrop(of: [FooterEffectTransfer.libraryType], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                let project = show.snapshot.project.id, session = show.projectSessionID
                _ = provider.loadDataRepresentation(forTypeIdentifier: FooterEffectTransfer.libraryType.identifier) { data, _ in
                    guard let data, let transfer = try? JSONDecoder().decode(FooterEffectTransfer.self, from: data),
                          transfer.library, transfer.project == project else { return }
                    Task { @MainActor in
                        guard show.snapshot.project.id == project, show.projectSessionID == session else { return }
                        if let key = LibraryEffectInsertion.apply(identity: transfer.effect, presetID: transfer.presetID,
                                                                  to: nil, clip: clip, show: show) { selected = key }
                    }
                }
                return true
            }
    }
}
private struct FooterEffectScrollBounds: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
private struct FooterEffectSlotsScroll<Content: View>: View {
    let contentHeight: CGFloat
    #if os(macOS)
    @Environment(\.openFX) private var openFX
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    #endif
    @ViewBuilder let content: () -> Content
    @State private var documentBounds: CGRect = .zero
    var body: some View {
        #if os(macOS)
        FooterEffectSlotsNative(content: AnyView(content().environment(\.openFX, openFX)
            .environment(\.locale, locale).environment(\.colorScheme, colorScheme)), height: contentHeight)
        #else
        GeometryReader { viewport in
            ScrollView(.vertical, showsIndicators: false) {
                content().frame(width: viewport.size.width, height: contentHeight, alignment: .top).background(GeometryReader { geometry in
                    Color.clear.preference(key: FooterEffectScrollBounds.self,
                        value: geometry.frame(in: .named("footerFXSlots")))
                })
            }
            .clipped()
            .coordinateSpace(name: "footerFXSlots")
            .onPreferenceChange(FooterEffectScrollBounds.self) { documentBounds = $0 }
            .overlay(alignment: .topTrailing) {
                if documentBounds.height > viewport.size.height + 1, viewport.size.height > 0 {
                    let height = viewport.size.height
                    let thumb = min(height, max(12, height * height / documentBounds.height))
                    let offset = min(1, max(0, -documentBounds.minY / (documentBounds.height - height)))
                    ZStack(alignment: .top) {
                        Capsule().fill(JarasTheme.green.opacity(0.15))
                        Capsule().fill(JarasTheme.green).frame(height: thumb).offset(y: (height - thumb) * offset)
                    }.frame(width: 2, height: height).allowsHitTesting(false)
                }
            }
        }
        #endif
    }
}
#if os(macOS)
private struct FooterEffectSlotsNative: NSViewRepresentable {
    let content: AnyView
    let height: CGFloat
    func makeNSView(context: Context) -> FooterEffectSlotsViewport { FooterEffectSlotsViewport() }
    func updateNSView(_ view: FooterEffectSlotsViewport, context: Context) { view.update(content: content, height: height) }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FooterEffectSlotsViewport, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? nsView.frame.height)
    }
}
#endif
private struct FooterSlotSurface: View {
    enum Tone { case empty, routed, effectEnabled, effectBypassed, bypassActive }
    static let radius: CGFloat = 5
    static let height: CGFloat = 19
    static let powerWidth: CGFloat = 19
    let tone: Tone
    @WorkspacePreference(JarasInterfaceTheme.preferenceKey) private var theme = JarasInterfaceTheme.defaultTheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius)
        let colors = palette
        shape.fill(LinearGradient(colors: [colors.top, colors.bottom], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(colors.border, lineWidth: 0.75))
    }

    private var palette: (top: Color, bottom: Color, border: Color) {
        switch tone {
        case .bypassActive: return (Color(hex: 0xffdf61), Color(hex: 0xe2ae25), Color(hex: 0xffe990))
        case .effectEnabled: return (Color(hex: 0x26503b), Color(hex: 0x163b2a), Color(hex: 0x438a60))
        case .effectBypassed: return (Color(hex: 0x693235), Color(hex: 0x4c2023), Color(hex: 0xa35357))
        case .empty, .routed:
            let level = Int(MixerTrackStyle.surfaceHex(for: theme) & 255) - (tone == .empty ? 11 : 0)
            func gray(_ value: Int) -> Color { Color(hex: UInt32(value) * 0x010101) }
            return (gray(level + 6), gray(level - 6), gray(level + 18))
        }
    }
}

private struct FooterSlotButtonStyle: ButtonStyle {
    let tone: FooterSlotSurface.Tone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.jarasSystem(size: 10, weight: .semibold))
            .foregroundStyle(tone == .bypassActive ? Color.black : Color(hex: 0xf4f4f4))
            .lineLimit(1).padding(.horizontal, 5).frame(maxWidth: .infinity)
            .frame(height: FooterSlotSurface.height)
            .background { FooterSlotSurface(tone: tone) }
            .overlay {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: FooterSlotSurface.radius).fill(.black.opacity(0.18)).allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
    }
}

private struct FooterEffectSlot: View {
    let show: ShowController
    let track: UUID?
    let effect: String?
    let settings: NativeFXSettings
    @Environment(\.openFX) private var openFX
    @State private var targeted = false
    @State private var hovered = false
    private var title: String {
        guard let effect else { return "" }
        if settings.kind(of: effect) == "Instruments" { return InstrumentLibrary.displayName(settings.settings(for: effect).instrumentID) }
        return settings.externalPlugins?.first(where: { $0.effectKey == effect })?.name ?? settings.kind(of: effect)
    }
    private func insertPlugin(_ identity: String) {
        FooterEffectTransfer(project: show.snapshot.project.id, source: nil, effect: identity, library: true)
            .apply(to: track, before: effect, show: show)
    }
    #if !os(macOS)
    @ViewBuilder private var slotMenu: some View {
        let groups = WorkspaceLibrary.mixerPluginGroups()
        ForEach(groups, id: \.title) { group in
            Menu(LocalizedStringKey(group.title)) {
                ForEach(group.entries, id: \.identity) { plugin in
                    Button(plugin.name) { insertPlugin(plugin.identity) }
                }
            }
        }
        if let effect {
            Divider()
            Button("Bypass") { show.toggleFXBypass(track, effect: effect) }
            Button("Remove") { show.removeFX(track, effect: effect) }
        }
    }
    #endif
    var body: some View {
        Group {
            if let effect {
                let enabled = settings.isEnabled(effect)
                HStack(spacing: 0) {
                    Button { show.toggleFXBypass(track, effect: effect) } label: {
                        Image(systemName: "power").font(.jarasSystem(size: 9, weight: .semibold))
                            .frame(width: 13, height: 15)
                            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 3))
                            .frame(width: FooterSlotSurface.powerWidth, height: FooterSlotSurface.height)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: JarasLocalization.string(enabled ? "Bypass effect" : "Enable effect") + " " + title))
                        .accessibilityValue(Text(enabled ? "Enabled" : "Bypass"))
                    Button { openFX(track, effect) } label: {
                        Text(verbatim: title).font(.jarasSystem(size: 10, weight: .semibold))
                            .lineLimit(1).padding(.horizontal, 3).frame(maxWidth: .infinity)
                            .frame(height: FooterSlotSurface.height).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    #if !os(macOS)
                    .onDrag { FooterEffectTransfer(project: show.snapshot.project.id, source: track, effect: effect).provider }
                    #endif
                }.foregroundStyle(Color(hex: 0xf4f4f4))
                    .background { FooterSlotSurface(tone: enabled ? .effectEnabled : .effectBypassed) }
            } else {
                Button { openFX(track, "Library") } label: {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }.buttonStyle(FooterSlotButtonStyle(tone: .empty)).accessibilityLabel("Library")
            }
        }
            #if !os(macOS)
            .overlay {
                if targeted || hovered {
                    RoundedRectangle(cornerRadius: FooterSlotSurface.radius)
                        .fill(targeted ? JarasTheme.green.opacity(0.3) : Color.white.opacity(0.09))
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovered = $0 }
            #endif
            .contentShape(Rectangle())
            .jarasHelp(effect == nil ? "Library" : title)
            #if os(macOS)
            .overlay(FooterEffectContext(bypass: { if let effect { show.toggleFXBypass(track, effect: effect) } },
                remove: { if let effect { show.removeFX(track, effect: effect) } },
                open: { openFX(track, effect ?? "Library") },
                transfer: effect.map { FooterEffectTransfer(project: show.snapshot.project.id, source: track, effect: $0) },
                title: title, project: show.snapshot.project.id, dragEnabled: true, choose: insertPlugin, drop: { transfer in
                    transfer.apply(to: track, before: effect, show: show)
                }))
            #else
            .contextMenu { slotMenu }
            .onDrop(of: [FooterEffectTransfer.type, FooterEffectTransfer.libraryType], delegate: FooterEffectDrop(show: show, track: track,
                effect: effect, targeted: $targeted))
            #endif
            .trackControlSelectionExclusion()
    }
}
private struct FooterEffectDrop: DropDelegate {
    let show: ShowController
    let track: UUID?
    let effect: String?
    @Binding var targeted: Bool
    var libraryOnly = false
    private var acceptedTypes: [UTType] {
        libraryOnly ? [FooterEffectTransfer.libraryType] : [FooterEffectTransfer.libraryType, FooterEffectTransfer.type]
    }
    func validateDrop(info: DropInfo) -> Bool { !TrackReorderState.shared.active && info.hasItemsConforming(to: acceptedTypes) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard !TrackReorderState.shared.active,
              let type = acceptedTypes.first(where: { info.hasItemsConforming(to: [$0]) }),
              let provider = info.itemProviders(for: [type]).first else { return false }
        let project = show.snapshot.project.id, session = show.projectSessionID
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let transfer = try? JSONDecoder().decode(FooterEffectTransfer.self, from: data), transfer.project == project else { return }
            Task { @MainActor in
                guard show.snapshot.project.id == project, show.projectSessionID == session else { return }
                _ = transfer.apply(to: track, before: effect, show: show)
            }
        }
        return true
    }
}


#if os(iOS)
private struct MixerPlaybackGain<Content: View>: View {
    @ObservedObject private var fadeout: TransportFadeout
    @ObservedObject private var loopFaders: MultiLoopFaderPresentation
    let show: ShowController
    let track: UUID?
    let manual: Double
    let project: UUID
    let content: (Double) -> Content
    init(show: ShowController, track: UUID?, manual: Double, @ViewBuilder content: @escaping (Double) -> Content) {
        self.show = show; self.track = track; self.manual = manual; self.content = content
        project = show.snapshot.project.id
        _fadeout = ObservedObject(wrappedValue: show.transportFadeout)
        _loopFaders = ObservedObject(wrappedValue: show.multiLoopFaders)
    }
    var body: some View {
        let base = show.automationPlaybackValue(track, kind: .volume).map(TrackEnvelope.gain) ?? manual
        content((loopFaders.frame?.gain(base, project: project, track: track) ?? base) * fadeout.multiplier(for: track))
    }
}
#endif

// The thumb travels linearly in decibels, from +12 to the mute end at −60.
struct MixerFaderDecibelScale: View {
    static let labelPriority = [0, -60, 12, -24, -40, -12, -6, -18, -30, -50, 6, -3, -9, -15, -21, -35, -45]
    static func fraction(_ db: Int) -> CGFloat { 1 - MixerMeterStyle.fraction(decibels: Double(db)) }

    static func labels(travel: CGFloat) -> [Int] {
        var visible: [Int] = []
        for level in labelPriority where visible.allSatisfy({ abs(fraction($0) - fraction(level)) * travel >= 9.5 }) {
            visible.append(level)
        }
        return visible
    }

    var body: some View {
        Canvas { context, size in
            let travel = size.height - 16
            guard travel >= 12 else { return }
            let visible = Self.labels(travel: travel)
            let minorStep = travel >= 216 ? 1 : travel >= 72 ? 3 : 6
            for db in -60...12 {
                let labelled = visible.contains(db)
                guard labelled || db.isMultiple(of: minorStep) else { continue }
                let y = 8 + Self.fraction(db) * travel
                let length: CGFloat = db == 0 ? 6 : (labelled ? 4 : 2)
                context.fill(Path(CGRect(x: size.width - length, y: y - 0.5, width: length, height: 1)),
                             with: .color(.white.opacity(labelled ? 0.63 : 0.32)))
                if labelled {
                    let text = db == -60 ? "−∞" : db > 0 ? "+\(db)" : String(abs(db))
                    context.draw(Text(verbatim: text).font(.system(size: 8, weight: .regular).monospacedDigit())
                        .foregroundColor(.white.opacity(0.82)), at: CGPoint(x: size.width - 7, y: y), anchor: .trailing)
                }
            }
        }
    }
}

private struct FooterMixerControl: View {
    let show: ShowController
    let track: UUID?
    let value: Double
    let pan: Bool
    let linked: UUID?
    var meter: TrackMeterLevel? = nil
    var showsPanTooltip = false
    #if os(iOS)
    @State private var faderSelected = false
    #endif
    @State private var pointerPosition: Double?
    private var position: Double { pan ? value : (value <= 0 ? -60 : min(12, max(-60, 20 * log10(value)))) }
    private func gain(_ value: Double) -> Double { value <= -60 ? 0 : pow(10, value / 20) }
    var body: some View {
        #if os(macOS)
        let identity = TrackControlIdentity(project: show.snapshot.project.id, track: track)
        DirectVolumeSlider(show: show, groupValues: { show.mixerPreviewValues }, identity: identity, value: position, minimum: pan ? -1 : -60, maximum: pan ? 1 : 12,
            mini: pan, vertical: !pan, rotary: pan, showsPanTooltip: showsPanTooltip, linkedTrack: linked, meter: meter,
            changed: { newValue in
                guard show.snapshot.project.id == identity.project else { return }
                if pan { show.sendMixerControl(.pan, target: track, value: newValue, preview: true) }
                else { show.sendMixerControl(.volume, target: track, value: gain(newValue), preview: true) }
            }, editingChanged: { editing, newValue in
                guard !editing, show.snapshot.project.id == identity.project else { return }
                show.sendMixerControl(pan ? .pan : .volume, target: track, value: pan ? newValue : gain(newValue))
            })
            .modifier(MappingRightClick(track: track, command: pan ? "pan" : "volume"))
            .accessibilityLabel(pan ? "Pan" : "Track volume")
        #else
        if pan {
            TrackPanKnob(show: show, track: track, pan: value)
        }
        else {
            MixerPlaybackGain(show: show, track: track, manual: value) { displayed in
                touchFader(position: displayed <= 0 ? -60 : min(12, max(-60, 20 * log10(displayed))))
            }
        }
        #endif
    }
    #if os(iOS)
    private func touchFader(position: Double) -> some View {
        GeometryReader { geometry in
            let inset: CGFloat = 8
            let travel = max(1, geometry.size.height - 2 * inset)
            let fraction = ((pointerPosition ?? position) + 60) / 72
            let thumbY = (1 - fraction) * travel + inset
            let positionAt: (CGFloat) -> Double = { y in -60 + 72 * Double(min(1, max(0, 1 - (y - inset) / travel))) }
            ZStack {
                if let meter {
                    MixerFaderMeter(meter: meter, vertical: true, linked: linked != nil)
                        .frame(width: MixerMeterStyle.railThickness).padding(.vertical, inset)
                } else {
                    Capsule().fill(.white.opacity(0.2)).frame(width: 5)
                }
                MixerFaderThumb(vertical: true, selected: faderSelected)
                    .position(x: geometry.size.width / 2, y: thumbY)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .overlay(RemoteSliderTouchInput(locksScrolling: true, trackID: track, axis: .vertical,
                    selectionScope: show.current?.id, nativeFader: true, thumbPosition: thumbY, selectionChanged: { faderSelected = $0 },
                    changed: { y in
                        let next = positionAt(y)
                        pointerPosition = next
                        show.sendMixerControl(.volume, target: track, value: gain(next), preview: true)
                    }, ended: { y in
                        show.sendMixerControl(.volume, target: track, value: gain(positionAt(y)))
                        pointerPosition = nil
                    }, reset: { show.sendMixerControl(.volume, target: track, value: 1); pointerPosition = nil }))
        }
    }
    #endif
}

#if os(macOS)
private struct FooterEffectContext: NSViewRepresentable {
    let bypass: () -> Void
    let remove: () -> Void
    let open: () -> Void
    let transfer: FooterEffectTransfer?
    let title: String
    let project: UUID
    let dragEnabled: Bool
    let choose: (String) -> Void
    let drop: (FooterEffectTransfer) -> Bool
    func makeNSView(context: Context) -> FooterEffectContextView { FooterEffectContextView() }
    func updateNSView(_ view: FooterEffectContextView, context: Context) {
        view.bypass = bypass; view.remove = remove; view.open = open; view.transfer = transfer; view.title = title; view.project = project; view.drop = drop; view.dragEnabled = dragEnabled
        view.choose = choose
        view.optionClick = { [weak view] in
            guard let view else { return }
            if let event = NSApp.currentEvent, view.isPowerClick(event) { view.bypass?() }
            else { view.remove?() }
        }
        view.shiftClick = bypass; view.action = { [weak view] in view?.openMenu() }
    }
}
@MainActor private final class FooterPluginSubmenu: NSObject, NSMenuDelegate {
    private let entries: [(identity: String, name: String)]
    private let choose: (String) -> Void

    init(entries: [(identity: String, name: String)], choose: @escaping (String) -> Void) {
        self.entries = entries
        self.choose = choose
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.isEmpty else { return }
        for entry in entries {
            let item = NSMenuItem(title: entry.name, action: #selector(selectPlugin(_:)), keyEquivalent: "")
            item.representedObject = entry.identity
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func selectPlugin(_ item: NSMenuItem) {
        if let identity = item.representedObject as? String { choose(identity) }
    }
}

private final class FooterEffectContextView: RightClickTargetView, NSDraggingSource {
    override var priority: Int { 2 }
    var bypass: (() -> Void)?
    var remove: (() -> Void)?
    var open: (() -> Void)?
    var choose: ((String) -> Void)?
    var transfer: FooterEffectTransfer?
    var dragEnabled = true
    var title = ""
    private var pressed: NSEvent?
    private var dragging = false
    var project: UUID?
    var drop: ((FooterEffectTransfer) -> Bool)?
    private var hover = false
    private var receiving = false
    private var tracking: NSTrackingArea?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([FooterEffectTransfer.type, FooterEffectTransfer.libraryType].map { NSPasteboard.PasteboardType($0.identifier) })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // AppKit maintains an inVisibleRect area as its ancestors scroll.
        // Replacing it on every clip change rebuilds tracking across all FX slots.
        guard tracking == nil else { return }
        let area=NSTrackingArea(rect: .zero,options: [.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner: self)
        addTrackingArea(area);tracking=area
    }
    override func mouseEntered(with event: NSEvent) { hover=true;needsDisplay=true }
    override func mouseExited(with event: NSEvent) { hover=false;needsDisplay=true }
    override func draw(_ dirtyRect: NSRect) {
        guard receiving || hover else { return }
        (receiving ? NSColor.systemGreen.withAlphaComponent(0.3) : NSColor.white.withAlphaComponent(0.09)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: FooterSlotSurface.radius, yRadius: FooterSlotSurface.radius).fill()
    }
    private func payload(_ sender: NSDraggingInfo) -> FooterEffectTransfer? {
        guard !interactionBlocked, !TrackReorderState.shared.active else { return nil }
        let types = dragEnabled ? [FooterEffectTransfer.libraryType, FooterEffectTransfer.type] : [FooterEffectTransfer.libraryType]
        for type in types {
            guard let data = sender.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)),
                  let value = try? JSONDecoder().decode(FooterEffectTransfer.self, from: data), value.project == project else { continue }
            return value
        }
        return nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        receiving=payload(sender) != nil;needsDisplay=true;return receiving ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { receiving=false;needsDisplay=true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { payload(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        receiving=false;needsDisplay=true
        guard let value=payload(sender) else { return false }
        return drop?(value) ?? false
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { receiving=false;needsDisplay=true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    func isPowerClick(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return transfer != nil && bounds.contains(point) && point.x < bounds.minX + FooterSlotSurface.powerWidth
    }
    override func mouseDown(with event: NSEvent) { pressed = event; dragging = false }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; dragging = false }
        guard let pressed, !dragging, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        let power = isPowerClick(pressed)
        guard power == isPowerClick(event) else { return }
        if power { bypass?() }
        else if event.modifierFlags.contains(.option) { remove?() }
        else if event.modifierFlags.contains(.shift) { bypass?() }
        else { open?() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragEnabled, let pressed, !dragging, !isPowerClick(pressed), let transfer,
              hypot(event.locationInWindow.x - pressed.locationInWindow.x, event.locationInWindow.y - pressed.locationInWindow.y) >= 4,
              let data = try? JSONEncoder().encode(transfer) else { return }
        dragging = true
        let pasteboard = NSPasteboardItem()
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(FooterEffectTransfer.type.identifier))
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let label = NSAttributedString(string: title, attributes: [.font: NSFont.jarasSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white])
        let size = NSSize(width: max(30, min(240, label.size().width + 10)), height: 20)
        let image = NSImage(size: size, flipped: true) { rect in label.draw(at: NSPoint(x: 5, y: 4)); return true }
        item.setDraggingFrame(NSRect(origin: convert(pressed.locationInWindow, from: nil), size: size), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { pressed = nil; dragging = false }
    func openMenu() {
        guard let event = NSApp.currentEvent else { return }
        if transfer != nil && event.modifierFlags.contains(.option) { remove?(); return }
        let menu = NSMenu()
        var actions: [TrackMenuAction] = []
        func add(_ title: String, to submenu: NSMenu, perform: @escaping () -> Void) {
            let action = TrackMenuAction(perform)
            let item = NSMenuItem(title: title, action: #selector(TrackMenuAction.invoke), keyEquivalent: "")
            item.target = action; submenu.addItem(item); actions.append(action)
        }
        for group in WorkspaceLibrary.mixerPluginGroups() {
            let title = JarasLocalization.string(group.title)
            let category = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            let source = FooterPluginSubmenu(entries: group.entries) { [weak self] in self?.choose?($0) }
            category.representedObject = source
            submenu.delegate = source
            menu.addItem(category); menu.setSubmenu(submenu, for: category)
        }
        if transfer != nil {
            menu.addItem(.separator())
            add(JarasLocalization.string("Bypass"), to: menu) { [weak self] in self?.bypass?() }
            add(JarasLocalization.string("Remove"), to: menu) { [weak self] in self?.remove?() }
        }
        withExtendedLifetime(actions) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
#endif

private struct PhaseInvertButton: View {
    let show: ShowController
    let track: UUID?
    let inverted: Bool
    var body: some View {
        Button { show.sendMixerControl(.phase, target: track) } label: {
            PhaseInvertGlyph().stroke(inverted ? Color.black : JarasTheme.text, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                .frame(width: 12, height: 12).frame(width: 16, height: 16)
                .background(inverted ? JarasTheme.yellow : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }.buttonStyle(.plain).jarasHelp(inverted ? "Phase inverted — restore phase" : "Invert polarity").accessibilityLabel("Invert polarity")
            .accessibilityValue(inverted ? "On" : "Off")
    }
}
private struct PhaseInvertGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.18))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.07, y: rect.maxY - rect.height * 0.07))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.07, y: rect.minY + rect.height * 0.07))
        return path
    }
}

#if os(macOS)
@MainActor final class DetachedMixerWindow: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isDetached = false
    @Published private(set) var isVisible = false
    private func remember(detached: Bool, visible: Bool) {
        WorkspaceLayoutPreferences.storage.set(detached, forKey: "jaras.layout.mixer.detached")
        WorkspaceLayoutPreferences.storage.set(visible, forKey: "jaras.layout.mixer.visible")
    }
    private(set) var window: NSWindow?
    func open(show: ShowController, openFX: @escaping (UUID?, String) -> Void, editTrack: @escaping (TrackDetailsEditRequest) -> Void) {
        remember(detached: true, visible: true)
        if let window { if window.isMiniaturized { window.deminiaturize(nil) }; ProjectionWindow.presentWorkspaceWindow(window, activates: false); isVisible = true; return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 370),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "CatLive · Hoz-Mixer"
        panel.animationBehavior = .none
        panel.contentMinSize = NSSize(width: 360, height: FooterHorizontalMixer.minimumDockHeight)
        panel.isReleasedWhenClosed = false; panel.delegate = self
        let host = NSHostingView(rootView: DetachedMixerContent(show: show, owner: self, openFX: openFX, editTrack: editTrack).interfaceScaled())
        if #available(macOS 13, *) { host.sizingOptions = [] }
        panel.contentView = host
        InterfaceScaling.shared.register(panel)
        if !panel.setFrameUsingName("CatLiveDetachedMixer", force: true) { panel.center() }
        panel.setFrameAutosaveName("CatLiveDetachedMixer")
        ProjectionWindow.followWorkspaceWindow(panel, independent: true)
        window = panel; isDetached = true; isVisible = true
        ensureMinimumHeight()
        ProjectionWindow.presentWorkspaceWindow(panel, activates: false)
    }
    private func ensureMinimumHeight() {
        guard let window else { return }
        let minimum = FooterHorizontalMixer.minimumDockHeight
        window.contentMinSize = NSSize(width: window.contentMinSize.width, height: minimum)
        let current = window.contentRect(forFrameRect: window.frame)
        if current.height < minimum { window.setContentSize(NSSize(width: current.width, height: minimum)) }
    }
    private func savePlacement() { window?.saveFrame(usingName: "CatLiveDetachedMixer") }
    func windowDidMove(_ notification: Notification) { savePlacement() }
    func windowDidResize(_ notification: Notification) {
        // AppKit calls this for every pixel of live resizing. Save the final
        // placement once, while retaining programmatic/maximize changes.
        if window?.inLiveResize != true { savePlacement() }
    }
    func windowDidEndLiveResize(_ notification: Notification) { savePlacement() }
    func hide() { remember(detached: true, visible: false); savePlacement(); window?.orderOut(nil); isVisible = false }
    func close(preserveState: Bool = false) {
        if !preserveState { remember(detached: false, visible: false) }
        savePlacement()
        window?.delegate = nil; window?.close(); window?.contentView = nil; window = nil
        isVisible = false; isDetached = false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func windowDidMiniaturize(_ notification: Notification) { isVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { isVisible = true }
}
private struct DetachedMixerContent: View {
    let show: ShowController
    @ObservedObject var owner: DetachedMixerWindow
    let openFX: (UUID?, String) -> Void
    let editTrack: (TrackDetailsEditRequest) -> Void
    @AppStorage("jaras.language") private var language = "en"
    var body: some View {
        FooterHorizontalMixer(show: show, active: owner.isVisible)
            .environment(\.openFX, openFX).environment(\.editTrackDetails, editTrack)
            .environment(\.locale, Locale(identifier: language))
            .preferredColorScheme(.dark).background(JarasTheme.background)
    }
}
#endif

/// Batch routing deliberately changes only the selected category; untouched
/// audio/MIDI inputs and output routes retain their individual settings.
private struct BatchPatchEditor: View {
    let show: ShowController
    @ObservedObject private var project: ShowProjectPresentation
    @ObservedObject private var recorder = TrackRecording.shared
    let targets: [UUID]
    @ObservedObject private var audio = AudioDeviceSettings.shared
    @State private var category = 0
    @State private var input = OutputPatch.stereo
    @State private var output = OutputPatch.master
    @State private var midi = 0
    @State private var midiChannel = 0
    @State private var applied = false
    init(show: ShowController, targets: [UUID]) {
        self.show = show
        self.targets = targets
        _project = ObservedObject(wrappedValue: show.projectPresentation)
    }
    private var tracks: [Track] { show.snapshot.project.songs.flatMap(\.tracks).filter { targets.contains($0.id) } }
    private var outputOnly: Bool { tracks.contains { $0.role.rawValue == "vinhetas" } }
    private var inputs: [OutputPatch] {
        OutputPatch.choices(channels: TrackRecording.shared.inputChannels, includeMaster: false, includeNone: true)
            .filter { choice in tracks.allSatisfy { track in
                guard let link = track.stereoLink, choice != .none else { return true }
                return choice.channelCount == 1 && (link.left ? choice.firstChannel < TrackRecording.shared.inputChannels : choice.firstChannel > 1)
            } }
    }
    private var outputs: [OutputPatch] {
        OutputPatch.choices(channels: audio.channels, includeMaster: tracks.allSatisfy { $0.kind == .standard },
            includeGroup: tracks.allSatisfy { $0.parentTrackID != nil }, includeNone: true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Patch · Selected tracks").font(.jarasHeadline)
            Text(tracks.map(\.name).joined(separator: ", ")).font(.jarasCaption).lineLimit(3)
            Picker("Patch", selection: $category) {
                if !outputOnly {
                    Text("Input").tag(0)
                    #if os(macOS)
                    Text("MIDI input").tag(1)
                    #endif
                    Text("MIDI channel").tag(3)
                }
                Text("Output").tag(2)
            }.pickerStyle(.segmented)
            if category == 0 && !outputOnly {
                Picker("Input", selection: $input) { ForEach(inputs, id: \.self) { Text($0.title).tag($0) } }
            } else if category == 1 && !outputOnly {
                Picker("MIDI input", selection: $midi) {
                    Text("None").tag(0)
                    ForEach(0..<6, id: \.self) { Text(audio.midiSlotTitle($0)).tag($0 + 1) }
                }
                Picker("MIDI channel", selection: $midiChannel) {
                    Text("All").tag(0)
                    ForEach(1...16, id: \.self) { Text(verbatim: String($0)).tag($0) }
                }
            } else if category == 3 && !outputOnly {
                Picker("MIDI channel", selection: $midiChannel) {
                    Text("All").tag(0)
                    ForEach(1...16, id: \.self) { Text(verbatim: String($0)).tag($0) }
                }
            } else {
                Picker("Output", selection: $output) { ForEach(outputs, id: \.self) { Text($0.title).tag($0) } }
            }
            Button("Apply to selected tracks") {
                for track in tracks {
                    switch outputOnly ? 2 : category {
                    case 0: show.setRecordingInput(track.id, input: input)
                    case 1: show.setMIDIInput(track.id, slot: midi); show.setMIDIChannel(track.id, channel: midiChannel)
                    case 3: show.setMIDIChannel(track.id, channel: midiChannel)
                    default: show.setOutputPatches(track: track.id, patches: [output])
                    }
                }
                applied = true
            }.buttonStyle(.borderedProminent).tint(JarasTheme.green)
                .disabled(tracks.isEmpty || (category == 0 && !inputs.contains(input)) || (category != 2 && (recorder.recording || tracks.contains { $0.kind != .standard })) || (category == 2 && !outputs.contains(output)))
            if applied { Label("Applied", systemImage: "checkmark.circle.fill").foregroundStyle(JarasTheme.green) }
        }.padding(18).frame(minWidth: 320, maxWidth: 480)
            .onAppear { if outputOnly { category = 2 } }
            .onChange(of: category) { _ in applied = false }
            .onChange(of: input) { _ in applied = false }
            .onChange(of: output) { _ in applied = false }
            .onChange(of: midi) { _ in applied = false }
            .onChange(of: midiChannel) { _ in applied = false }
    }
}

#if os(macOS)
/// Command-A follows the last panel clicked, independently of selections that
/// remain highlighted in another panel. Weak registrations also cover detached mixers.
struct EditorSelectionArea: NSViewRepresentable {
    enum Scope: Int { case grid, tracks, setlist }
    let scope: Scope
    var moveCursor: ((Int) -> Bool)? = nil
    let selectAll: () -> Bool
    func makeNSView(context: Context) -> EditorSelectionAreaView { EditorSelectionAreaView() }
    func updateNSView(_ view: EditorSelectionAreaView, context: Context) {
        view.scope = scope; view.selectAll = selectAll; view.moveCursor = moveCursor
    }
}
final class EditorSelectionAreaView: NSView {
    var scope = EditorSelectionArea.Scope.grid
    var selectAll: (() -> Bool)?
    var moveCursor: ((Int) -> Bool)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { EditorSelectionRouter.shared.add(self) }
    }
}
@MainActor final class EditorSelectionRouter {
    static let shared = EditorSelectionRouter()
    private let areas = NSHashTable<EditorSelectionAreaView>.weakObjects()
    private let focus = NSMapTable<NSWindow, EditorSelectionAreaView>.weakToWeakObjects()
    private let scopes = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
    private var monitor: Any?
    func add(_ view: EditorSelectionAreaView) {
        areas.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown { return (self.moveCursor(event) || self.selectAll(event)) ? nil : event }
            self.handlePointer(event)
            return event
        }
    }
    func handlePointer(_ event: NSEvent) {
            guard let window = event.window, window.attachedSheet == nil,
                  !NativeTimelineInputGate.shared.isBlocked(window) else { return }
            let candidates = areas.allObjects.filter {
                let point = $0.convert(event.locationInWindow, from: nil)
                return $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.contains(point) && $0.visibleRect.contains(point)
            }
            if let area = candidates.sorted(by: {
                if $0.scope.rawValue != $1.scope.rawValue { return $0.scope.rawValue > $1.scope.rawValue }
                return $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
            }).first { focus.setObject(area, forKey: window); scopes.setObject(NSNumber(value: area.scope.rawValue), forKey: window) }

    }
    func activate(_ scope: EditorSelectionArea.Scope, in window: NSWindow) {
        scopes.setObject(NSNumber(value: scope.rawValue), forKey: window)
        if let area = areas.allObjects.first(where: { $0.window === window && $0.scope == scope && !$0.isHiddenOrHasHiddenAncestor }) {
            focus.setObject(area, forKey: window)
        }
    }
    private func activeArea(in window: NSWindow) -> EditorSelectionAreaView? {
        guard let raw = scopes.object(forKey: window), let scope = EditorSelectionArea.Scope(rawValue: raw.intValue) else { return nil }
        if let area = focus.object(forKey: window), area.window === window, area.scope == scope, !area.isHiddenOrHasHiddenAncestor { return area }
        // SwiftUI recycles hosts. Preserve the last clicked area across that
        // replacement instead of falling back to stale item selections.
        return areas.allObjects.first { $0.window === window && $0.scope == scope && !$0.isHiddenOrHasHiddenAncestor }
    }
    func activeScope(in window: NSWindow?) -> EditorSelectionArea.Scope? {
        guard let window else { return nil }
        return activeArea(in: window)?.scope
    }
    func moveCursor(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 123 || event.keyCode == 124,
              event.modifierFlags.intersection([.command, .control, .shift, .option]).isEmpty,
              let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
              window.sheetParent == nil, NSApp.modalWindow == nil, ControlMappings.shared.editing == nil,
              !NativeTimelineInputGate.shared.isBlocked(window),
              !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
              let area = activeArea(in: window), area.scope == .grid,
              area.window === window, !area.isHiddenOrHasHiddenAncestor else { return false }
        return area.moveCursor?(event.keyCode == 123 ? -1 : 1) ?? false
    }
    func selectAll(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .shift, .option])
        guard event.type == .keyDown, flags == .command || flags == .control,
              event.charactersIgnoringModifiers?.lowercased() == "a", let window = event.window,
              window.isKeyWindow, window.attachedSheet == nil, window.sheetParent == nil,
              NSApp.modalWindow == nil, ControlMappings.shared.editing == nil,
              !NativeTimelineInputGate.shared.isBlocked(window),
              !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return false }
        if event.isARepeat { return activeArea(in: window) != nil }
        return selectAll(in: window)
    }
    func selectAll(in window: NSWindow) -> Bool {
        guard let area = activeArea(in: window) else { return false }
        return area.selectAll?() ?? false
    }
}
#endif

struct TrackVisibilityEditor: View {
    let show: ShowController
    let close: () -> Void
    @ObservedObject private var preferences = TrackVisibilityPreferences.shared
    @State private var area: TrackVisibilityArea = .trackMixer
    var body: some View {
        let project = show.snapshot.project.id
        let tracks = show.current?.tracks ?? []
        let state = preferences.state(for: project)
        let ownHidden = state.hidden(in: area)
        let effectiveHidden = state.effectiveHidden(in: tracks, area: area)
        let hierarchy = TrackHierarchy(tracks)
        let listed = tracks.filter { area == .trackMixer || $0.kind == .standard || $0.kind == .click }
        VStack(spacing: 12) {
            HStack {
                Text("Visibilidade das pistas").font(.jarasHeadline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Fechar").keyboardShortcut(.cancelAction)
            }
            Picker("Painel", selection: $area) {
                Text(verbatim: "Track Mixer").tag(TrackVisibilityArea.trackMixer)
                Text("Hoz-Mixer").tag(TrackVisibilityArea.barMixer)
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(listed) { track in
                        let inherited = hierarchy.ancestors(of: track.id).contains(where: ownHidden.contains)
                        Toggle(isOn: Binding(get: { !effectiveHidden.contains(track.id) }, set: { visible in
                            preferences.setVisible(visible, track: track.id, in: area, project: project)
                            if !visible {
                                let hidden = preferences.state(for: project).effectiveHidden(in: tracks, area: area)
                                let selection = show.mixerTrackSelection.subtracting(hidden)
                                let anchor = show.selectedTrackForActions.flatMap { selection.contains($0) ? $0 : nil }
                                show.setMixerTrackSelection(selection, anchor: anchor ?? selection.first)
                            }
                        })) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(Color(hex: track.color ?? JarasTheme.roleHex(track.role)))
                                    .frame(width: 5, height: 18)
                                Text(verbatim: track.name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #else
                        .toggleStyle(TrackVisibilityCheckboxStyle())
                        #endif
                        .disabled(inherited)
                        .opacity(inherited ? 0.45 : 1)
                        .padding(.leading, CGFloat(hierarchy.ancestors(of: track.id).count) * 12)
                        .padding(.horizontal, 8).frame(minHeight: 30)
                    }
                }
            }.background(JarasTheme.background).clipShape(RoundedRectangle(cornerRadius: 6))
        }.padding(16).font(.jarasSystem(size: 12)).foregroundStyle(JarasTheme.text).background(JarasTheme.panel)
            #if os(macOS)
            .interfaceScaledFrame(width: 390, height: 440)
            #else
            .frame(width: 390, height: 440)
            #endif
    }
}

#if os(iOS)
private struct TrackVisibilityCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(configuration.isOn ? JarasTheme.green : JarasTheme.secondary)
                    .accessibilityHidden(true)
                configuration.label
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
#endif

struct ProgramChangeTrackRow: View {
    @ObservedObject var show: ShowController
    let track: Track
    var number: Int? = nil
    var selected = false
    var select: () -> Void = {}
    var randomColor: (() -> Void)?
    var deleteTrack: (() -> Void)?
    @ObservedObject private var mappings = ControlMappings.shared
    @AppStorage(MixerTrackStyle.trackMixerKey) private var trackStyle = MixerTrackStyle.defaultStyle
    private var usesStripe: Bool { trackStyle == .stripeOnly }
    @State private var patch = false
    @State private var naming = false
    @State private var pending: (program: Int, channel: Int, position: Double, project: UUID, output: Int?)?
    private var scanning: Bool { mappings.programChangeScanTrack == track.id }
    private var copyReady: Bool { show.programChangePasteReady || show.selectedProgramChange != nil }
    private var controls: some View {
        HStack(spacing: 3) {
            Button("Patch") { patch = true }.buttonStyle(CompactTrackButtonStyle(width: 36))
            Button(LocalizedStringKey(show.programChangePasteReady ? "Paste" : "Copy")) {
                if show.programChangePasteReady { show.pasteProgramChange() }
                else { show.copyProgramChange() }
            }.buttonStyle(CompactTrackButtonStyle(activeColor: copyReady ? JarasTheme.green : nil, width: 46))
                .disabled(!copyReady)
                .opacity(copyReady ? 1 : 0.4)
            TimelineView(.periodic(from: .now, by: 0.45)) { context in
                Button(LocalizedStringKey(scanning ? "Apply" : "Scan")) {
                    if let value = mappings.scanProgramChange(track.id) {
                        pending = (value.program, value.channel, show.snapshot.transport.editPosition ?? 0, show.snapshot.project.id, track.midiOutput ?? 0)
                        naming = true
                    }
                }
                    .buttonStyle(CompactTrackButtonStyle(activeColor: scanning ? JarasTheme.green : nil, width: 50))
                    .opacity(scanning && Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0 ? 0.5 : 1)
            }.fixedSize()
            Button("M") { show.sendTrackMixerButton(.mute, target: track.id) }
                .buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil))
            Button("S") { show.sendTrackMixerButton(.solo, target: track.id) }
                .buttonStyle(CompactTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil))
        }.trackControlSelectionExclusion()
    }

    private var title: some View {
        let prefix = number.map { String(format: "%02d  ", $0) } ?? ""
        return (Text(verbatim: prefix) + Text("Program Change"))
            .font(.jarasSystem(size: 11, weight: .semibold))
            .foregroundStyle(usesStripe ? MixerTrackStyle.surfaceText : .white)
            .lineLimit(1).minimumScaleFactor(0.75)
    }

    var body: some View {
        let stripe = usesStripe ? MixerTrackStyle.trackStripeWidth : 0
        GeometryReader { geometry in
            if geometry.size.height < 40 {
                HStack(spacing: 3) {
                    title.frame(maxWidth: .infinity, alignment: .leading)
                    controls
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    controls.frame(maxWidth: .infinity, alignment: .trailing)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        title
                        Spacer(minLength: 6)
                        if scanning, let last = mappings.scannedProgramChange {
                            Text(verbatim: "PC \(last.program + 1) · CH \(last.channel)").font(.jarasSystem(size: 10))
                        }
                    }.lineLimit(1)
                }.padding(.top, 2)
            }
        }.padding(.horizontal, 5).padding(.leading, stripe).padding(.bottom, 1)
            .foregroundStyle(.white)
            .background {
                let color = Color(hex: track.color ?? track.kind.defaultColor ?? 0x91a8ff)
                if usesStripe {
                    MixerTrackSurface(selected: selected).overlay(alignment: .leading) {
                        color.frame(width: MixerTrackStyle.trackStripeWidth)
                    }
                } else {
                    color.opacity(track.mute ? 0.15 : selected ? 0.65 : 0.45)
                }
            }
            .overlay(alignment: .bottom) { JarasTheme.line.frame(height: 1) }
            .clipped()
            .accessibilityAddTraits(selected ? .isSelected : [])
            #if os(macOS)
            .overlay(TrackRightClickInput(project: show.snapshot.project.id, track: track.id, kind: .programChange,
                selected: selected, select: select, patch: { patch = true }, fx: {}, randomColor: randomColor,
                group: nil, ungroup: nil, deleteTracks: deleteTrack,
                cursorMix: { tool in tool.apply(to: track.id, show: show) },
                cancelScan: scanning ? { mappings.cancelProgramChangeScan() } : nil))
            .workspaceEditor("Patch", isPresented: $patch, scrolls: false) { patchEditor }
            .workspaceEditor("Program Change", isPresented: $naming) { nameEditor }
            #else
            .contentShape(Rectangle()).onTapGesture(perform: select)
            .contextMenu {
                Button("Patch") { patch = true }
                if let randomColor { Button("Set Random Color", action: randomColor) }
                if scanning { Button("Cancel") { mappings.cancelProgramChangeScan() } }
                if let deleteTrack { Button("Delete track", role: .destructive, action: deleteTrack) }
            }
            .popover(isPresented: $patch) { patchEditor }
            .sheet(isPresented: $naming) { nameEditor }
            #endif
    }
    private var nameEditor: some View {
        ProgramChangeNameEditor(cancel: { naming = false }, apply: { name in
            guard let value = pending, value.project == show.snapshot.project.id else { naming = false; return }
            if show.applyProgramChange(track.id, program: value.program, channel: value.channel, name: name, position: value.position, output: value.output) {
                naming = false; pending = nil; mappings.cancelProgramChangeScan()
            }
        })
    }
    private var patchEditor: some View {
        VStack(spacing: 14) {
            ProgramChangePatch(show: show, track: track.id)
            Button("Close") { patch = false }.keyboardShortcut(.cancelAction)
        }.padding(20).foregroundStyle(JarasTheme.text).background(JarasTheme.panel)
    }
}
struct ProgramChangePatch: View {
    @ObservedObject var show: ShowController
    let track: UUID
    @ObservedObject private var audio = AudioDeviceSettings.shared
    private var settings: Track? { show.current?.tracks.first { $0.id == track } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Patch").font(.jarasHeadline)
            Picker("MIDI input", selection: Binding(get: { settings?.midiInput ?? 0 }, set: {
                ControlMappings.shared.cancelProgramChangeScan(); show.setProgramChangeRouting(track, input: $0)
            })) {
                Text("All").tag(-1)
                Text("None").tag(0)
                ForEach(0..<6, id: \.self) { slot in Text(audio.midiSlotTitle(slot)).tag(slot + 1) }
            }
            Picker("MIDI output", selection: Binding(get: { settings?.midiOutput ?? 0 }, set: { show.setProgramChangeRouting(track, output: $0) })) {
                Text("None").tag(0)
                ForEach(0..<6, id: \.self) { slot in Text(audio.midiOutputSlotTitle(slot)).tag(slot + 1) }
            }
        }.frame(minWidth: 300)
    }
}
struct ProgramChangeNameEditor: View {
    var cancel: () -> Void
    var apply: (String) -> Void
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Program Change").font(.jarasHeadline)
            TextField("Name (up to 12 characters)", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { if $0.count > 12 { name = String($0.prefix(12)) } }
                .onSubmit { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { apply(name) } }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { apply(name) }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 360).foregroundStyle(JarasTheme.text).background(JarasTheme.panel)
    }
}
struct ProgramChangeMarkerLane: View {
    @ObservedObject var show: ShowController
    let track: Track
    let pixelsPerSecond: Double
    let height: CGFloat
    var start: Double = 0
    private func headWidth(_ marker: ProgramChangeMarker) -> CGFloat {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        #else
        let font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        #endif
        let natural = ceil((marker.title as NSString).size(withAttributes: [.font: font]).width) + 10
        return CGFloat(show.current?.programChangeHeadWidth(at: marker.position,
            naturalWidth: Double(natural), scale: pixelsPerSecond) ?? Double(natural))
    }
    var body: some View {
        let layout = ProgramChangeLayout(track.programChanges ?? [])
        ZStack(alignment: .topLeading) {
            ForEach(track.programChanges ?? []) { marker in
                let width = headWidth(marker)
                VStack(alignment: .leading, spacing: 0) {
                    if width > 0 {
                    Text(verbatim: marker.title)
                        .font(.jarasSystem(size: 10, weight: .semibold)).foregroundStyle(.black)
                        .lineLimit(1)
                        .padding(.horizontal, 5).frame(width: width, height: 20, alignment: .leading)
                        .clipped()
                        .background(show.selectedProgramChangeID == marker.id ? JarasTheme.green : Color(hex: 0x91a8ff), in: RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                        #if os(macOS)
                        .overlay(ProgramChangeHeadInput(select: { show.selectProgramChange(marker.id) },
                            copy: { show.selectProgramChange(marker.id); show.copyProgramChange() },
                            paste: show.hasProgramChangeClipboard ? { show.pasteProgramChange() } : nil,
                            remove: { show.removeProgramChange(track: track.id, marker: marker.id) }))
                        #else
                        .background(ProgramChangeHeadAnchor())
                        .onTapGesture { show.selectProgramChange(marker.id) }
                        .contextMenu {
                            Button("Copy") { show.selectProgramChange(marker.id); show.copyProgramChange() }
                            Button("Paste") { show.pasteProgramChange() }.disabled(!show.hasProgramChangeClipboard)
                            Button("Delete", role: .destructive) { show.removeProgramChange(track: track.id, marker: marker.id) }
                        }
                        #endif
                    } else {
                        Color.clear.frame(width: 1, height: 20).allowsHitTesting(false)
                    }
                    Color(hex: 0x91a8ff).frame(width: 1, height: max(0, height - 20 - CGFloat(layout.lanes[marker.id] ?? 0) * 24)).allowsHitTesting(false)
                }.offset(x: (marker.position - start) * pixelsPerSecond, y: CGFloat(layout.lanes[marker.id] ?? 0) * 24)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
    }
}

#if os(macOS)
struct ChordMarkerLane: View {
    let show: ShowController
    let track: Track
    let song: Song
    let pixelsPerSecond: Double
    let height: CGFloat

    var body: some View {
        let regions = Dictionary(uniqueKeysWithValues: song.parts.map { ($0.id, $0) })
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let color = Color(hex: 0x529eff)
        ZStack(alignment: .topLeading) {
            ForEach(track.chordMarkers ?? []) { marker in
                if let region = regions[marker.regionID], marker.offset < region.endTime - region.startTime {
                    let position = region.startTime + marker.offset
                    let natural = ceil((marker.name as NSString).size(withAttributes: [.font: font]).width) + 10
                    let width = min(natural, (region.endTime - position) * pixelsPerSecond)
                    VStack(alignment: .leading, spacing: 0) {
                        if width >= 18 {
                            Text(verbatim: marker.name)
                                .font(.jarasSystem(size: 10, weight: .semibold)).foregroundStyle(.black)
                                .lineLimit(1).padding(.horizontal, 5).frame(width: width, height: 20, alignment: .leading)
                                .clipped().background(color, in: RoundedRectangle(cornerRadius: 3))
                                .overlay(ProgramChangeHeadInput(remove: { show.removeChord(track: track.id, marker: marker.id) }))
                        }
                        color.frame(width: 1, height: max(0, height - (width >= 18 ? 20 : 0))).allowsHitTesting(false)
                    }.offset(x: position * pixelsPerSecond)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
    }
}

private struct ProgramChangeHeadInput: NSViewRepresentable {
    var select: () -> Void = {}
    var copy: (() -> Void)? = nil
    var paste: (() -> Void)? = nil
    let remove: () -> Void
    func makeNSView(context: Context) -> ProgramChangeHeadInputView { ProgramChangeHeadInputView() }
    func updateNSView(_ view: ProgramChangeHeadInputView, context: Context) {
        view.select = select; view.copyMarker = copy; view.pasteMarker = paste; view.remove = remove
    }
}
final class ProgramChangeHeadInputView: NSView, TimelineGridKeyboardTarget {
    var select: () -> Void = {}
    var copyMarker: (() -> Void)?
    var pasteMarker: (() -> Void)?
    var remove: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { NativeTimelineOverlayInputRegistration.add(self) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        window?.makeFirstResponder(self); select()
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); select()
        NSMenu.popUpContextMenu(markerContextMenu(), with: event, for: self)
    }
    func markerContextMenu() -> NSMenu {
        let menu = NSMenu()
        let actions = copyMarker == nil ? [(3, "Delete")] : [(1, "Copy"), (2, "Paste"), (3, "Delete")]
        for (tag,key) in actions {
            let item = NSMenuItem(title: JarasLocalization.string(key), action: #selector(runMenu(_:)), keyEquivalent: "")
            item.target = self; item.tag = tag; item.isEnabled = tag != 2 || pasteMarker != nil; menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }
    @objc private func runMenu(_ item: NSMenuItem) {
        if item.tag == 1 { copyMarker?() } else if item.tag == 2 { pasteMarker?() } else { remove() }
    }
}
#else
private struct ProgramChangeHeadAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> ProgramChangeHeadAnchorView { ProgramChangeHeadAnchorView() }
    func updateUIView(_ view: ProgramChangeHeadAnchorView, context: Context) {}
}
final class ProgramChangeHeadAnchorView: UIView {
    private static let heads = NSHashTable<ProgramChangeHeadAnchorView>.weakObjects()
    override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { Self.heads.add(self) } }
    static func contains(_ touch: UITouch) -> Bool {
        heads.allObjects.contains { $0.window === touch.window && !$0.isHidden && $0.bounds.contains(touch.location(in: $0)) }
    }
}
#endif

#if os(macOS)
private struct PatchEditorWindowTitle: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.title = title; view.updateTitle() }
    final class TitleView: NSView {
        var title = ""
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTitle() }
        func updateTitle() {
            guard let window, window is NSPanel, window.title != title else { return }
            window.title = title
        }
    }
}
#endif
