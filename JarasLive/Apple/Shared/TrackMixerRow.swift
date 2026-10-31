import SwiftUI
import Combine
import UniformTypeIdentifiers

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
    var opensChain = false
    @Environment(\.openFX) private var openFX
    var body: some View {
        Button("FX") { openFX(track, opensChain ? "Chain" : settings.effectKeys.first ?? "Chain") }
            .jarasHelp("Track effects")
            .foregroundStyle(settings.inserted.isEmpty ? JarasTheme.text : settings.allBypassed ? Color.red : JarasTheme.green)
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
        Button("Env") {
            show.toggleAutomationLanes(track)
        }.buttonStyle(CompactTrackButtonStyle(activeColor: visible ? JarasTheme.green : JarasTheme.yellow, width: 28))
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
    return !kind.isText && kind != .timecode
}

#if os(macOS)
/// One stable set of controls moves between the thin strip and expanded mixer.
/// No native fader, title or meter is mounted/unmounted at height thresholds.
struct TrackMixerHeightGeometry {
    static func progress(_ height: CGFloat) -> CGFloat {
        // Controls change mode once; they do not stretch/fade while resizing.
        height >= 64 ? 1 : 0
    }
    static func titleY(_ height: CGFloat) -> CGFloat {
        let centered = max(0, (height - 21) / 2)
        return min(max(0, height - titleHeight(height) - 1), centered + (47 - centered) * progress(height))
    }
    static func titleHeight(_ height: CGFloat) -> CGFloat { 21 - 5 * progress(height) }
    static func volumeHeight(_ height: CGFloat) -> CGFloat {
        min(20, max(0, titleY(height) - 27)) * progress(height)
    }
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
        let controlsX = max(folder ? 51 : 0, width - controlsWidth - 4)
        let titleX: CGFloat = standard ? 22 : 14
        let titleY = lowerTitle ? Self.titleY(height) : mix(centeredY, 3)
        let controlsY = mix(centeredY, 3), controlsHeight = mix(21, 24)
        let clear = lowerTitle ? min(1, max(0, (titleY - controlsY - controlsHeight) / 8)) : 0
        let thinWidth = max(0, width - controlsWidth - 8 - titleX)
        let titleWidth = thinWidth + (max(0, width - titleX - 4) - thinWidth) * clear
        return [
            CGRect(x: 0, y: meterTop, width: audioWidth, height: max(0, height - meterTop * 2)),
            CGRect(x: 14 * p, y: meterTop, width: standard ? 4 * p : 0, height: max(0, height - meterTop - 4)),
            CGRect(x: titleX, y: titleY, width: titleWidth, height: titleHeight(height)),
            CGRect(x: controlsX, y: controlsY, width: controlsWidth, height: controlsHeight),
            CGRect(x: bodyX, y: 27, width: bodyWidth, height: volumeHeight(height)),
            CGRect(x: folder ? 20 : bodyX, y: folder ? controlsY + (controlsHeight - 20) / 2 : 4, width: 28 * p, height: 20 * p),
            CGRect(x: max(bodyX, width - 90), y: 32, width: min(86, bodyWidth), height: 24 * p)
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
    var vinhetas = false
    @ViewBuilder let content: () -> Content
    @Environment(\.legacyMixerHeight) private var height
    var body: some View {
        if #available(macOS 13, *), !JarasDrawingCompatibility.forceLegacy {
            let layout = standard ? AnyLayout(TrackMixerButtonsLayout(showsFader: showsFader, vinhetas: vinhetas)) : AnyLayout(HStackLayout(spacing: 3))
            layout { content() }
        } else if standard {
            let expanded = height >= 64
            let controlHeight: CGFloat = expanded ? 24 : 21
            let widths: [CGFloat] = [expanded ? 34 : 0, expanded && !vinhetas ? 28 : 0, expanded && showsFader ? 22 : 0, 22, expanded && !vinhetas ? 42 : 0, 22, 22]
            let visibleCount = widths.filter { $0 > 0 }.count
            let width = widths.reduce(0, +) + CGFloat(max(0, visibleCount - 1)) * 3
            let frames = widths.indices.map { index in
                CGRect(x: widths.prefix(index).reduce(0, +) + CGFloat(widths.prefix(index).filter { $0 > 0 }.count) * 3,
                       y: 0, width: widths[index], height: controlHeight)
            }
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
/// Patch, Env, FX and pan stay mounted but occupy no space in a collapsed strip.
@available(macOS 13, *)
struct TrackMixerButtonsLayout: Layout {
    let showsFader: Bool
    var vinhetas = false
    // Standard-track controls have explicit widths: Patch, Env, FX, REC, pan, M, S.
    // Reuse those metrics without querying every control on each resize.
    private static let controlWidths: [CGFloat] = [34, 28, 22, 22, 42, 22, 22]
    // These containers use explicit frames, not their children's alignment guides.
    // The default Layout implementation walks every control to merge guides.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let expanded = (proposal.height ?? 24) >= 24
        let visible = subviews.indices.filter { !(!expanded && ($0 < 3 || $0 == 4)) && !($0 == 2 && expanded && !showsFader) && !(vinhetas && ($0 == 1 || $0 == 4)) }
        return CGSize(width: visible.reduce(CGFloat(0)) { $0 + Self.controlWidths[$1] } + CGFloat(max(0, visible.count - 1)) * 3, height: expanded ? 24 : 21)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let expanded = bounds.height >= 24
        var x = bounds.minX
        for i in subviews.indices {
            let hidden = (!expanded && (i < 3 || i == 4)) || (i == 2 && expanded && !showsFader) || (vinhetas && (i == 1 || i == 4))
            let width = Self.controlWidths[i]
            subviews[i].place(at: CGPoint(x: hidden ? bounds.maxX + 1024 : x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: bounds.height))
            if !hidden { x += width + 3 }
        }
    }
}

/// Content and environment change independently from the row's live geometry.
/// A height update repositions three native groups without reassigning their roots.
private final class TrackMixerNativeContent {
    let meter: AnyView, activity: AnyView, controls: AnyView
    init(meter: AnyView, activity: AnyView, controls: AnyView) {
        self.meter = meter; self.activity = activity; self.controls = controls
    }
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
            .environment(\.isEnabled, isEnabled)
            .environment(\.layoutDirection, layoutDirection).environment(\.displayScale, displayScale)
            .environment(\.font, font).environment(\.controlSize, controlSize)
            .environment(\.dynamicTypeSize, dynamicTypeSize).foregroundStyle(JarasTheme.text)
    }
}
private struct NativeTrackMixerControls<Meter: View, Activity: View, Controls: View>: View {
    let track: UUID
    let meterWidth: CGFloat
    let standard: Bool
    @ViewBuilder var meter: () -> Meter
    @ViewBuilder var activity: () -> Activity
    @ViewBuilder var controls: () -> Controls
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
        let snapshot = TrackMixerNativeContent(meter: hosted(meter()),
            activity: hosted(activity()), controls: hosted(controls()))
        return NativeTrackMixerControlsBridge(track: track, meterWidth: meterWidth, standard: standard, snapshot: snapshot)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
private struct NativeTrackMixerControlsBridge: NSViewRepresentable {
    let track: UUID
    let meterWidth: CGFloat
    let standard: Bool
    let snapshot: TrackMixerNativeContent
    func makeNSView(context: Context) -> TrackMixerNativeControlView {
        let view = TrackMixerNativeControlView(); updateNSView(view, context: context); return view
    }
    func updateNSView(_ view: TrackMixerNativeControlView, context: Context) {
        view.track = track
        view.meterWidth = meterWidth; view.standard = standard
        if view.snapshot !== snapshot {
            view.snapshot = snapshot
            view.meter.rootView = snapshot.meter; view.activity.rootView = snapshot.activity; view.controls.rootView = snapshot.controls
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
private final class TrackMixerControlHost: NSHostingView<AnyView> {
    var passThrough = false
    var peakOnly = false
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !passThrough else { return nil }
        let hit = super.hitTest(point)
        return peakOnly && !(hit is NativeVerticalTrackMeterView) ? nil : hit
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
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSView.boundsDidChangeNotification { self?.deferDetachmentUntilScrollSettles() }
                    self?.refresh()
                }
            })
        }
        if let document = clip.documentView {
            document.postsFrameChangedNotifications = true
            tokens.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        accessibilityObservations = [\NSWorkspace.isVoiceOverEnabled, \NSWorkspace.isSwitchControlEnabled].map { key in
            NSWorkspace.shared.observe(key, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }
    func add(_ view: TrackMixerNativeControlView) { views.add(view) }
    func remove(_ view: TrackMixerNativeControlView) { views.remove(view) }
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
        updateAccessibility()
        for view in views.allObjects { view.refreshViewportVisibility() }
    }
    deinit { idleDetachment?.cancel(); tokens.forEach(NotificationCenter.default.removeObserver) }
}
private final class TrackMixerNativeControlView: NSView, NativeTimelineControlInput {
    let meter = TrackMixerControlHost(rootView: AnyView(Color.clear))
    let activity = TrackMixerControlHost(rootView: AnyView(Color.clear))
    let controls = TrackMixerControlHost(rootView: AnyView(Color.clear))
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
        for host in [meter, activity, controls] {
            host.wantsLayer = true; host.layer?.masksToBounds = true
            if #available(macOS 13, *) { host.sizingOptions = [] }
            if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
            addSubview(host)
        }
        meter.peakOnly = true; activity.passThrough = true
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
        defer { inputRegistration.update(active: !isHidden && window != nil) }
        guard let clip = visibilityClip, window != nil else {
            setHostsAttached(true)
            if isHidden { isHidden = false }
            return
        }
        // Retain keyboard/assistive traversal and an in-flight control/menu
        // even when scrolling carries its row beyond the warm visible band.
        let focused = (window?.firstResponder as? NSView).map { $0 === self || $0.isDescendant(of: self) } ?? false
        let retained = focused || track.map { TrackSelectionRouter.shared.pinnedTracks.contains($0) } == true ||
            visibilityObserver?.retainsAccessibilityControls == true
        let nearby = convert(bounds, to: clip).intersects(clip.bounds.insetBy(dx: 0, dy: -256))
        let hidden = !retained && !nearby
        if hidden {
            if !isHidden { isHidden = true }
            if visibilityObserver?.defersHostDetachment != true { setHostsAttached(false) }
        } else {
            // Reattach while the owner is still hidden, before entering the
            // viewport. The same roots keep SwiftUI state and current actions.
            setHostsAttached(true)
            if isHidden { isHidden = false }
        }
    }
    private func setHostsAttached(_ attached: Bool) {
        guard !updatingHostAttachment else { return }
        updatingHostAttachment = true
        defer { updatingHostAttachment = false }
        // Reverse insertion below the first child restores the original
        // meter/activity/controls order without disturbing other row children.
        // The row owner and its clip observer always stay mounted. Its normal
        // snapshot updates also reach these retained hosts while detached.
        for host in [controls, activity, meter] {
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
        let expanded = height >= 64
        let frames = TrackMixerHeightGeometry.frames(width: bounds.width, height: height, meterWidth: meterWidth, standard: standard, lowerTitle: true, controlsWidth: 145)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        func update(_ host: NSView, _ frame: CGRect) {
            host.isHidden = frame.width <= 0 || frame.height <= 0
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
        update(meter, frames[0]); update(activity, frames[1])
        update(controls, CGRect(x: 0, y: expanded ? 0 : (height - 24) / 2, width: bounds.width, height: expanded ? 64 : 24))
        observeViewport()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !isHiddenOrHasHiddenAncestor, bounds.contains(local), visibleRect.contains(local),
           let peak = hitTestMeterPeak(local) { return peak }
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

private struct TrackControlIdentity: Equatable {
    let project: UUID
    let track: UUID?
}

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
        return lhs.show === rhs.show && lhs.projectID == rhs.projectID && lhs.trackSelection == rhs.trackSelection && lhs.track == rhs.track && lhs.nextTrack == rhs.nextTrack && lhs.number == rhs.number && lhs.selected == rhs.selected && lhs.silenced == rhs.silenced && lhs.showsMeterScale == rhs.showsMeterScale && lhs.showsFader == rhs.showsFader && lhs.showsInstrumentIcons == rhs.showsInstrumentIcons && lhs.projectDirectory == rhs.projectDirectory && sameHeightMode && lhs.isFolder == rhs.isFolder && lhs.groupDepth == rhs.groupDepth && lhs.lastChild == rhs.lastChild && (lhs.groupSelection != nil) == (rhs.groupSelection != nil) && (lhs.deleteTracks != nil) == (rhs.deleteTracks != nil)
    }
    @Environment(\.openFX) private var openFX
    @Environment(\.editTextItem) private var editTextItem
    let show: ShowController
    let projectID: UUID
    let track: Track
    let trackSelection: Set<UUID>
    let nextTrack: UUID?
    let number: Int
    let selected: Bool
    let silenced: Bool
    let showsMeterScale: Bool
    private var showsTrackMeterScale: Bool { showsMeterScale && trackShowsMeterReadouts(track.kind) }
    private var meterTextColor: Color {
        Color(hex: JarasTheme.trackNameHex(track, emphasized: selected, silenced: silenced))
    }
    let showsFader: Bool
    var showsInstrumentIcons = false
    var compactHeight = false
    var minimalHeight = false
    let isFolder: Bool
    var groupDepth: Int = 0
    let lastChild: Bool
    let groupSelection: (() -> Void)?
    let select: () -> Void
    var importVideo: () -> Void = {}
    var projectDirectory: URL?
    var deleteTracks: ((Set<UUID>) -> Void)? = nil
    @State private var clickSoundPresented = false
    @State private var patchTarget: TrackPanelTarget?
    @State private var fxTarget: TrackPanelTarget?
    private var targets: [UUID?] {
        guard track.kind == .standard, trackSelection.contains(track.id) else { return [track.id] }
        return (show.current?.tracks ?? []).filter { $0.kind == .standard && trackSelection.contains($0.id) }.map { Optional($0.id) }
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
    private func editorTarget(project: UUID) -> TrackPanelTarget? {
        guard show.snapshot.project.id == project else { return nil }
        return TrackPanelTarget(project: project, track: track.id, targets: targets)
    }
    private var canLink: Bool { trackSelection.contains(track.id) && show.current?.linkableTracks(trackSelection) != nil }
    private func linkSelectedTracks() {
        guard let song = show.current, let indices = song.linkableTracks(trackSelection) else { return }
        let top = song.tracks[indices[0]]
        show.linkTracks(trackSelection, defaultInput: TrackRecording.shared.defaultInputPatch.firstChannel, color: top.color ?? JarasTheme.roleHex(top.role))
    }
    @ViewBuilder var body: some View {
        if track.kind == .programChange {
            ProgramChangeTrackRow(show: show, track: track, deleteTrack: deleteSelection)
        } else { regularBody }
    }
    @ViewBuilder private var regularBody: some View {
        let project = projectID
        let editTargets = Set(targets.compactMap { $0 })
        let details = TrackDetailsEditRequest(project: project, tracks: editTargets,
            name: track.name, color: track.color ?? JarasTheme.roleHex(track.role),
            nameEditable: editTargets.count == 1 && track.kind == .standard && track.role.rawValue != "vinhetas", instrumentIcon: track.instrumentIcon)
        let title = (number < 10 ? "0" : "") + String(number) + "  " + track.name
        let titleColor = JarasTheme.trackNameHex(track, emphasized: selected, silenced: silenced)
        HStack(spacing: 4) {
            if track.parentTrackID != nil {
                if groupDepth > 1 { Color.clear.frame(width: CGFloat(min(4, groupDepth - 1)) * 8) }
                GroupTrackConnector(last: lastChild).stroke(JarasTheme.green.opacity(0.7), lineWidth: 1)
                    .frame(width: 12).allowsHitTesting(false)
            }
            #if os(macOS)
            continuousControls(title: title, color: titleColor, project: project)
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
                            Button("Patch") { patchTarget = editorTarget(project: project) }
                                .buttonStyle(CompactTrackButtonStyle(width: 34)).jarasHelp("Patch")
                            TrackEnvelopeButton(show: show, track: track.id, visible: !(track.automation?.visibleEnvelopes.isEmpty ?? true))
                            TrackFXButton(show: show, track: track.id, settings: track.fx ?? NativeFXSettings())
                                .buttonStyle(CompactTrackButtonStyle()).jarasHelp("Insert effect")
                            TrackRecordButton(show: show, track: track).buttonStyle(CompactTrackButtonStyle())
                        } else if track.kind == .click {
                            Button("Patch") { patchTarget = editorTarget(project: project) }
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
            VerticalTrackMeter(meter: StemAudioPlayback.shared.meter(for: track.id), showScale: showsTrackMeterScale,
                               foreground: meterTextColor, peakOnly: trackShowsMeterReadouts(track.kind))
                .frame(width: showsMeterScale ? 40 : 12).padding(.vertical, 4)
            if track.kind == .standard && track.role.rawValue != "vinhetas" {
                TrackMIDIIndicator(state: InstrumentKeyboardState.shared.activity(track.id))
                    .frame(width: 4).padding(.vertical, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if track.kind != .standard && track.kind != .video && track.kind != .timecode && track.kind != .click {
                        Text(title).font(.jarasSystem(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: titleColor))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        if isFolder { TrackGroupButton(show: show, project: project, track: track.id, parent: track.parentTrackID) }
                        Spacer(minLength: 0)
                    }
                HStack(spacing: 3) {
                    if track.kind == .standard {
                    if showsFader {
                        Button("Patch") { patchTarget = editorTarget(project: project) }
                            .buttonStyle(CompactTrackButtonStyle(width: 34)).jarasHelp("Patch")
                        TrackEnvelopeButton(show: show, track: track.id, visible: !(track.automation?.visibleEnvelopes.isEmpty ?? true))
                        TrackFXButton(show: show, track: track.id, settings: track.fx ?? NativeFXSettings()).jarasHelp("Insert effect")
                    }
                    TrackRecordButton(show: show, track: track).buttonStyle(CompactTrackButtonStyle())
                    TrackPanFader(show: show, track: track.id, pan: track.pan, compact: compactHeight).frame(width: 42, height: compactHeight ? 22 : 24)
                    Button("M") { show.sendTrackMixerButton(.mute, target: track.id) }.modifier(MappingRightClick(track: track.id, command: "mute")).buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil)).jarasHelp("Mute")
                    Button("S") { show.sendTrackMixerButton(.solo, target: track.id) }.modifier(MappingRightClick(track: track.id, command: "solo")).buttonStyle(CompactTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil)).jarasHelp("Solo")
                    } else if track.kind == .click {
                        Button("Patch") { patchTarget = editorTarget(project: project) }
                            .buttonStyle(CompactTrackButtonStyle(width: 34)).fixedSize(horizontal: true, vertical: false)
                            .trackControlSelectionExclusion()
                        Button("Insert") { show.insertClickItems(track: track.id) }.buttonStyle(TrackControlButtonStyle())
                            .fixedSize(horizontal: true, vertical: false)
                        Button("M") { show.sendTrackMixerButton(.mute, target: track.id) }.buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil))
                        Button("S") { show.sendTrackMixerButton(.solo, target: track.id) }.buttonStyle(CompactTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil))
                    } else if track.kind == .timecode {
                        HStack(spacing: 3) {
                            Button { patchTarget = editorTarget(project: project) } label: { Image(systemName: "gearshape") }
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
                        Button("Add text") {
                            if let item = show.addTextItem(track: track.id) { editTextItem(item) }
                        }.buttonStyle(TrackControlButtonStyle())
                    }
                }.buttonStyle(CompactTrackButtonStyle()).trackControlSelectionExclusion()
                }.frame(height: compactHeight ? 21 : 24)
                HStack(spacing: 3) {
                    if showsFader && (track.kind == .standard || track.kind == .video || track.kind == .timecode || track.kind == .click) {
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
            if showsInstrumentIcons {
                GeometryReader { geometry in
                    ZStack {
                        JarasTheme.mixer
                        if let raw = track.instrumentIcon, let icon = TrackInstrumentIcon(rawValue: raw) {
                            TrackInstrumentIconView(icon: icon)
                                .frame(width: min(32, max(0, geometry.size.height - 4)),
                                       height: min(32, max(0, geometry.size.height - 4)))
                                .foregroundStyle(.white)
                        }
                    }.overlay(alignment: .leading) { Color.white.opacity(0.14).frame(width: 1) }
                }.frame(width: TrackMixerColumnGeometry.iconWidth).allowsHitTesting(false)
            }
        }.frame(maxHeight: .infinity).clipped()
            .background { HStack(spacing: 0) {
                if track.parentTrackID != nil { JarasTheme.mixer.frame(width: 16) }
                JarasTheme.track(track, emphasized: selected).opacity(selected ? 0.65 : 0.50).saturation(silenced ? 0 : 1)
            }.allowsHitTesting(false) }
            .overlay { Rectangle().stroke(selected ? Color.white.opacity(0.65) : .clear, lineWidth: 1).padding(.leading, track.parentTrackID == nil ? 0 : 16).padding(.trailing, showsInstrumentIcons ? 40 : 0).allowsHitTesting(false) }
            .overlay(alignment: .bottom) { Rectangle().fill(JarasTheme.line).frame(height: 1).padding(.leading, track.parentTrackID == nil ? 0 : 16).padding(.trailing, showsInstrumentIcons ? 40 : 0) }
            .background { GeometryReader { geometry in
                if track.kind == .standard { Color.clear.onDrop(of: [TrackReorderState.type], delegate: TrackInsertionDrop(show: show, track: track.id, nextTrack: nextTrack, height: geometry.size.height, state: dragState)) }
            } }
            .overlay(alignment: dropSide == true ? .bottom : .top) {
                if dropSide != nil { Rectangle().fill(dragState.indicatorColor).frame(height: 3).shadow(color: dragState.indicatorColor, radius: 4).padding(.trailing, showsInstrumentIcons ? 40 : 0).allowsHitTesting(false) }
            }
            .overlay { if dragState.blockedTarget == track.id { TrackDropBlockedBadge() } }
            #if os(macOS)
            .overlay(TrackRightClickInput(project: project, track: track.id, kind: track.kind, dragName: track.name, selected: selected, select: select, patch: { patchTarget = editorTarget(project: project) }, fx: { fxTarget = editorTarget(project: project) }, edit: { editTrackDetails(details) }, icon: { editTrackDetails(details.iconRequest) }, group: show.current?.canCreateTrackGroup(track.id) == true ? { show.createTrackGroup(track.id) } : nil, ungroup: isFolder ? { show.ungroupTrack(track.id) } : nil, removeFromGroup: track.parentTrackID != nil ? { show.removeTrackFromGroup(track.id) } : nil, link: canLink ? { linkSelectedTracks() } : nil, unlink: track.stereoLink != nil ? { show.unlinkTracks(track.id) } : nil, soundDesigner: track.kind == .click ? { clickSoundPresented = true } : nil, createMIDI: track.kind == .standard && track.role.rawValue != "vinhetas" ? {
                let range = TimelineAreaSelection.shared.range
                let valid = range?.song == show.current?.id
                if let id = show.addMIDIItem(track: track.id, start: valid ? range?.start : nil, duration: valid ? range.map { $0.end - $0.start } : nil) { MIDIEditorWindows.shared.open(show: show, item: id) }
            } : nil, duplicateTracks: duplicateSelection, deleteTracks: deleteSelection, deleteTrackCount: deletionTargets.count))
            #else
            .onTapGesture(perform: select)
            .contextMenu {
                Button("Patch") { patchTarget = editorTarget(project: project) }
                if track.kind == .standard { Button("FX") { fxTarget = editorTarget(project: project) } }
                Button("Editar pista") { editTrackDetails(details) }
                Button("Ícone da pista") { editTrackDetails(details.iconRequest) }
                if let duplicateSelection {
                    Button(LocalizedStringKey(deletionTargets.count > 1 ? "Duplicate tracks" : "Duplicate track"), action: duplicateSelection)
                }
                if canLink { Button("Link tracks") { linkSelectedTracks() } }
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
            .workspaceEditor("Patch", item: $patchTarget, scrolls: false) { target in
                VStack { PatchEditor(show: show, track: target.track, targets: target.targets); Button("Close") { patchTarget = nil }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .workspaceEditor("FX", item: $fxTarget) { target in
                FXInsertEditor(show: show, track: target.track, targets: target.targets) { fxTarget = nil }
            }
            #if os(macOS)
            .workspaceEditor("Sound Designer", isPresented: $clickSoundPresented) {
                ClickSoundDesigner(show: show, track: track.id, directory: projectDirectory) { clickSoundPresented = false }
            }
            #endif
            .onChange(of: projectID) { _ in patchTarget = nil; fxTarget = nil; clickSoundPresented = false }

    }
    #if os(macOS)
    @ViewBuilder private func continuousControls(title: String, color: UInt32, project: UUID) -> some View {
        if #available(macOS 13, *), !JarasDrawingCompatibility.forceLegacy {
            NativeTrackMixerControls(track: track.id, meterWidth: showsTrackMeterScale ? 52 : 12, standard: track.kind == .standard,
                meter: { continuousMeter }, activity: { continuousMIDIIndicator }, controls: {
                    continuousControlSlots(title: title, color: color, project: project, separateMeters: true)
                })
        } else {
            continuousControlSlots(title: title, color: color, project: project, separateMeters: false)
        }
    }
    private var continuousMeter: some View {
        VerticalTrackMeter(meter: StemAudioPlayback.shared.meter(for: track.id), showScale: showsTrackMeterScale,
                           foreground: meterTextColor, peakOnly: trackShowsMeterReadouts(track.kind))
            .clipped()
    }
    private var continuousMIDIIndicator: some View {
        Group {
            if track.kind == .standard && track.role.rawValue != "vinhetas" { TrackMIDIIndicator(state: InstrumentKeyboardState.shared.activity(track.id)) }
            else { Color.clear }
        }.allowsHitTesting(false)
    }
    private func continuousControlSlots(title: String, color: UInt32, project: UUID, separateMeters: Bool) -> some View {
            let lowerTitle = track.kind == .standard || track.kind == .video || track.kind == .timecode || track.kind == .click
            return TrackMixerContinuousContainer(meterWidth: showsTrackMeterScale ? 52 : 12,
                                       standard: track.kind == .standard, lowerTitle: lowerTitle, folder: isFolder) {
                Group {
                    if separateMeters { Color.clear } else { continuousMeter }
                }.jarasPlaced(at: 0)
                Group {
                    if separateMeters { Color.clear } else { continuousMIDIIndicator }
                }.jarasPlaced(at: 1)
                Group {
                    if track.kind == .standard {
                        TrackDragTitle(title: title, foreground: color, project: project, track: track.id, state: dragState, select: select)
                    } else {
                        Text(title).font(.jarasSystem(size: 11, weight: .semibold)).foregroundStyle(Color(hex: color))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .jarasPlaced(at: 2)
                TrackMixerButtonsContainer(standard: track.kind == .standard, showsFader: showsFader, vinhetas: track.role.rawValue == "vinhetas") {
                    if track.kind == .standard {
                        Button("Patch") { patchTarget = editorTarget(project: project) }
                            .buttonStyle(CompactTrackButtonStyle(width: 34)).jarasHelp("Patch")
                            .frame(width: 34).trackControlSelectionExclusion().jarasPlaced(at: 0)
                        TrackEnvelopeButton(show: show, track: track.id, visible: !(track.automation?.visibleEnvelopes.isEmpty ?? true))
                            .frame(width: 28).trackControlSelectionExclusion().jarasPlaced(at: 1)
                        TrackFXButton(show: show, track: track.id, settings: track.fx ?? NativeFXSettings()).jarasHelp("Insert effect")
                            .frame(width: 22).trackControlSelectionExclusion().jarasPlaced(at: 2)
                        TrackRecordButton(show: show, track: track).trackControlSelectionExclusion().jarasPlaced(at: 3)
                        TrackPanFader(show: show, track: track.id, pan: track.pan)
                            .frame(width: 42, height: 24).clipped().trackControlSelectionExclusion().jarasPlaced(at: 4)
                    } else if track.kind == .click {
                        Button("Patch") { patchTarget = editorTarget(project: project) }
                            .buttonStyle(CompactTrackButtonStyle(width: 34)).fixedSize(horizontal: true, vertical: false)
                            .trackControlSelectionExclusion()
                        Button("Insert") { show.insertClickItems(track: track.id) }
                            .buttonStyle(CompactTrackButtonStyle(width: 47))
                            .fixedSize(horizontal: true, vertical: false).trackControlSelectionExclusion().jarasHelp("Insert click items in regions without a click")
                    } else {
                        HStack(spacing: 3) {
                            if track.kind == .timecode {
                                Button { patchTarget = editorTarget(project: project) } label: { Image(systemName: "gearshape") }
                                ForEach(["mtc", "ltc"], id: \.self) { mode in
                                    let active = (track.timecode?.mode ?? "mtc") == mode
                                    Button(mode.uppercased()) { var settings = track.timecode ?? TimecodeSettings(); settings.mode = mode; show.setTimecode(track.id, settings: settings) }
                                        .foregroundStyle(active ? .black : .white)
                                        .buttonStyle(TrackControlButtonStyle(activeColor: active ? JarasTheme.green : nil))
                                }
                            } else if track.kind == .video {
                                Button("Add media", action: importVideo)
                            } else if track.kind.isText {
                                Button("Add text") { if let item = show.addTextItem(track: track.id) { editTextItem(item) } }
                            }
                        }.buttonStyle(TrackControlButtonStyle())
                            .fixedSize().trackControlSelectionExclusion()
                    }
                    if trackShowsMuteSolo(track.kind) {
                        Button("M") { show.sendTrackMixerButton(.mute, target: track.id) }
                            .modifier(MappingRightClick(track: track.id, command: "mute"))
                            .buttonStyle(CompactTrackButtonStyle(activeColor: track.mute ? .red : nil)).jarasHelp("Mute")
                            .frame(width: 22).trackControlSelectionExclusion().jarasPlaced(at: 5)
                        Button("S") { show.sendTrackMixerButton(.solo, target: track.id) }
                            .modifier(MappingRightClick(track: track.id, command: "solo"))
                            .buttonStyle(CompactTrackButtonStyle(activeColor: track.solo ? JarasTheme.yellow : nil)).jarasHelp("Solo")
                            .frame(width: 22).trackControlSelectionExclusion().jarasPlaced(at: 6)
                    }
                }.buttonStyle(CompactTrackButtonStyle()).clipped()
                    .modifier(LegacyControlsWidth()).jarasPlaced(at: 3)
                Group {
                    if showsFader && lowerTitle {
                        TrackVolumeFader(show: show, track: track.id, volume: track.volume, phaseInverted: track.phaseInverted == true, compact: true, showsPhase: track.kind != .timecode && track.kind != .click && track.role.rawValue != "vinhetas")
                    } else { Color.clear }
                }.clipped().jarasPlaced(at: 4)
                Group {
                    if isFolder { TrackGroupButton(show: show, project: project, track: track.id, parent: track.parentTrackID) }
                    else { Color.clear }
                }.jarasPlaced(at: 5)
                Color.clear.jarasPlaced(at: 6)
            }
    }
    #endif

}
struct TrackGroupSymbol: View {
    let nested: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            if nested { Image(systemName: "folder.fill").font(.jarasSystem(size: 8)) }
            Image(systemName: "folder.fill").font(.jarasSystem(size: 12))
                .overlay { if nested { Image(systemName: "minus").font(.jarasSystem(size: 7, weight: .heavy)).foregroundStyle(Color.black).offset(y: 1) } }
        }.foregroundStyle(JarasTheme.green)
    }
}
struct TrackGroupButton: View {
    let show: ShowController
    let project: UUID
    let track: UUID
    let parent: UUID?
    var height: CGFloat = 20
    private struct Request { let project: UUID; let track: UUID; let parent: UUID? }
    @State private var request: Request?
    @State private var confirming = false
    @State private var hovering = false
    var body: some View {
        Button { request = Request(project: project, track: track, parent: parent); confirming = true } label: {
            TrackGroupSymbol(nested: parent != nil).frame(width: 28, height: height)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(hovering ? 0.24 : 0)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).trackControlSelectionExclusion()
            #if os(macOS)
            .onHover { hovering = $0 }
            #endif
            .accessibilityLabel(parent == nil ? "Ungroup" : "Remove from group")
            .jarasHelp(parent == nil ? "Ungroup" : "Remove from group")
            .alert(Text(LocalizedStringKey(request?.parent == nil ? "Dissolve this track group?" : "Move this group out of its parent group?")),
                   isPresented: $confirming) {
                Button("Cancel", role: .cancel) { request = nil }
                Button("Confirm", role: .destructive) {
                    guard let pending = request else { return }
                    request = nil
                    guard show.snapshot.project.id == pending.project,
                          let row = show.current?.tracks.first(where: { $0.id == pending.track }),
                          row.parentTrackID == pending.parent else { return }
                    if pending.parent == nil { show.ungroupTrack(pending.track) }
                    else { show.removeTrackFromGroup(pending.track) }
                }
            }
    }
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
    let edit: () -> Void
    var masterRight = false
    var moveMaster: (() -> Void)? = nil
    var body: some View {
        Button("Patch", action: patch)
        Button("FX", action: fx)
        #if os(macOS)
        Button("Env") { AutomationWindows.open(show: show, track: nil) }
        #endif
        Button("Editar pista", action: edit)
        if let moveMaster {
            Divider()
            Button(LocalizedStringKey(masterRight ? "Mostrar Master à esquerda" : "Mostrar Master à direita"), action: moveMaster)
        }
    }
}

struct MasterStrip: View {
    @Environment(\.openFX) private var openFX
    let show: ShowController
    @ObservedObject private var updates: ShowProjectPresentation
    init(show: ShowController) {
        self.show = show
        _updates = ObservedObject(wrappedValue: show.projectPresentation)
    }
    @State private var patchPresented = false
    @State private var fxPresented = false
    @State private var colorPresented = false
    var body: some View {
        HStack(spacing: 4) {
            VerticalTrackMeter(meter: StemAudioPlayback.shared.masterMeter, showScale: false)
                .frame(width: 12).padding(.vertical, 4)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Button { show.send(.masterMono) } label: {
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
                        .jarasHelp(show.snapshot.project.masterMono == true ? "Mono — switch to Stereo" : "Stereo — switch to Mono").accessibilityLabel("Master Stereo/Mono")
                        .accessibilityValue(show.snapshot.project.masterMono == true ? "Mono" : "Stereo")
                    #if os(macOS)
                    Button("Patch") { patchPresented = true }
                        .buttonStyle(CompactTrackButtonStyle(width: 40))
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("Master Patch")
                    #endif
                    Spacer(minLength: 2)
                    TrackPanFader(show: show, track: nil, pan: show.snapshot.project.masterPan ?? 0, compact: true).frame(width: 42, height: 24)
                    TrackFXButton(show: show, track: nil, settings: show.snapshot.project.masterFX ?? NativeFXSettings()).jarasHelp("Insert effect")
                        #if os(macOS)
                        .buttonStyle(CompactTrackButtonStyle(width: 26))
                        .fixedSize(horizontal: true, vertical: false)
                        #endif
                    Button("M") { show.send(.mute) }.frame(width: 26, height: 24).modifier(MappingRightClick(track: nil, command: "mute")).buttonStyle(CompactTrackButtonStyle(activeColor: show.snapshot.project.masterMute == true ? .red : nil)).jarasHelp("Mute")
                    Button("S") { show.send(.solo) }.frame(width: 26, height: 24).modifier(MappingRightClick(track: nil, command: "solo")).buttonStyle(CompactTrackButtonStyle(activeColor: show.snapshot.project.masterSolo == true ? JarasTheme.yellow : nil)).jarasHelp("Solo")
                }.font(.jarasSystem(size: 10, weight: .semibold)).buttonStyle(.bordered).controlSize(.small).frame(height: 24)
                    Text("Master").font(.jarasSystem(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: JarasTheme.masterNameHex(show.snapshot.project.masterColor ?? 0x414141)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                TrackVolumeFader(show: show, track: nil, volume: show.snapshot.project.masterVolume ?? 1, phaseInverted: show.snapshot.project.masterPhaseInverted == true, compact: true)
                    .frame(height: 20)
            }.padding(.vertical, 4)
        }.padding(.horizontal, 6).frame(minWidth: 230, maxWidth: .infinity).frame(height: 70)
            .background(Color(hex: show.snapshot.project.masterColor ?? 0x414141).opacity(0.5)).cornerRadius(6)
            .contextMenu {
                MasterTrackContextMenu(show: show, patch: { patchPresented = true },
                    fx: { fxPresented = true }, edit: { colorPresented = true })
            }
            .workspaceEditor("Patch", isPresented: $patchPresented, scrolls: false) {
                VStack { PatchEditor(show: show, track: nil, targets: [nil]); Button("Close") { patchPresented = false }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .workspaceEditor("FX", isPresented: $fxPresented) {
                FXInsertEditor(show: show, track: nil, targets: [nil]) { fxPresented = false }
            }
            .workspaceEditor("Editar pista", isPresented: $colorPresented) {
                NameColorEditor(title: "Editar pista", initialName: "Master", initialColor: show.snapshot.project.masterColor ?? 0x414141,
                    save: { _, color in show.editMasterColor(color) }, nameEditable: false, showsName: false)
            }
    }
}
struct PatchButton: View {
    let show: ShowController
    let track: UUID?
    let patch: OutputPatch
    var label = "Patch"
    @State private var presented = false
    var body: some View {
        Button(LocalizedStringKey(label)) { presented = true }.jarasHelp("Audio input and output")
            .workspaceEditor("Patch", isPresented: $presented, scrolls: false) {
                PatchEditor(show: show, track: track, targets: [track])
            }
    }
}
struct PatchEditor: View {
    @ObservedObject var show: ShowController
    let track: UUID?
    let targets: [UUID?]
    @State private var displayedOutputCount = 0
    @ObservedObject private var audio = AudioDeviceSettings.shared
    private var settings: Track? { track.flatMap { id in show.current?.tracks.first { $0.id == id } } }
    private var outputs: [OutputPatch] { settings?.outputPatches ?? show.snapshot.project.masterOutputPatches }
    private func routes(_ receive: Bool) -> [UUID?] { receive ? settings?.routing?.receives ?? [] : settings?.routing?.transmitters ?? [] }
    private var outputChoices: [OutputPatch] {
        let allInGroup = !targets.isEmpty && targets.allSatisfy { id in
            id.flatMap { track in show.current?.tracks.first { $0.id == track }?.parentTrackID } != nil
        }
        return OutputPatch.choices(channels: audio.channels, includeMaster: track != nil && (settings?.kind == .standard || settings?.kind == .click), includeGroup: allInGroup, includeNone: true)
    }
    var body: some View {
        if targets.count > 1 && settings?.role.rawValue != "vinhetas" { BatchPatchEditor(show: show, targets: targets.compactMap { $0 }) }
        else { singlePatch }
    }
    private var singlePatch: some View {
        ScrollViewReader { scroll in
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(settings?.kind == .timecode ? "Timecode" : "Patch").font(.jarasHeadline)
                    if let settings, settings.kind == .timecode { TimecodeOptions(show: show, track: settings) }
                    Text(audio.deviceName).font(.jarasCaption).foregroundStyle(JarasTheme.secondary)
                    if let track, let settings = show.snapshot.project.songs.flatMap(\.tracks).first(where: { $0.id == track }), settings.kind == .standard && settings.role.rawValue != "vinhetas" {
                        let input = settings.inputPatch ?? TrackRecording.shared.defaultInputPatch
                        let choices = OutputPatch.choices(channels: TrackRecording.shared.inputChannels, includeMaster: false).filter { choice in
                            guard let link = settings.stereoLink else { return true }
                            return choice.channelCount == 1 && (link.left ? choice.firstChannel < TrackRecording.shared.inputChannels : choice.firstChannel > 1)
                        }
                        Picker("Input", selection: Binding(get: { input }, set: { applyInput($0) })) {
                            if !choices.contains(input) { Text(input.title + " — " + JarasLocalization.string("Unavailable")).tag(input) }
                            ForEach(choices, id: \.self) { choice in Text(choice.title).tag(choice) }
                        }.disabled(TrackRecording.shared.recording)
                    }
                    if let track, let settings = show.snapshot.project.songs.flatMap(\.tracks).first(where: { $0.id == track }), settings.kind == .standard {
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
                        HStack {
                            Text("Output").font(.jarasSubheadline.bold())
                            Spacer()
                            Button { editOutputs { $0.append(.none) } } label: { Image(systemName: "plus") }
                                .accessibilityLabel("Add output")
                        }
                        ForEach(Array(outputs.enumerated()), id: \.offset) { entry in
                            let slot = entry.offset
                            HStack {
                                Picker("Output", selection: Binding(get: { outputs.indices.contains(slot) ? outputs[slot] : .none }, set: { value in editOutputs { if $0.indices.contains(slot) { $0[slot] = value } } })) {
                                    if !outputChoices.contains(entry.element) { Text(entry.element.title + " — " + JarasLocalization.string("Unavailable")).tag(entry.element) }
                                    ForEach(outputChoices, id: \.self) { Text($0.title).tag($0) }
                                }.labelsHidden()
                                Button { editOutputs { if $0.indices.contains(slot) { $0.remove(at: slot) } } } label: { Image(systemName: "minus.circle") }
                                    .accessibilityLabel("Remove output")
                            }.id("patch-output-\(slot)")
                        }
                        if settings?.kind == .standard && settings?.role.rawValue != "vinhetas" {
                            ForEach([true, false], id: \.self) { receive in
                                Divider()
                                HStack {
                                    Text(receive ? "Receive" : "Transmitter").font(.jarasSubheadline.bold())
                                    Spacer()
                                    Button { show.addTrackRoute(Set(targets.compactMap { $0 }), receive: receive) } label: { Image(systemName: "plus") }
                                        .accessibilityLabel(receive ? "Add receive" : "Add transmitter")
                                }
                                ForEach(routes(receive).indices, id: \.self) { slot in
                                    HStack {
                                        Picker(receive ? "Receive" : "Transmitter", selection: Binding<UUID?>(
                                            get: { routes(receive).indices.contains(slot) ? routes(receive)[slot] : nil },
                                            set: { show.setTrackRouting(Set(targets.compactMap { $0 }), receive: receive, slot: slot, other: $0) })) {
                                            Text("None").tag(Optional<UUID>.none)
                                            ForEach(show.current?.tracks.filter { $0.kind == .standard && !targets.contains($0.id) } ?? []) { candidate in
                                                Text(verbatim: candidate.name).tag(Optional(candidate.id))
                                            }
                                        }.labelsHidden()
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

private struct CompactTrackButtonStyle: ButtonStyle {
    var activeColor: Color? = nil
    var width: CGFloat = 22
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if activeColor != nil { configuration.label.foregroundStyle(Color.black) }
            else { configuration.label }
        }.font(.jarasSystem(size: 10, weight: .semibold))
            .frame(width: width, height: 21)
            .background(activeColor.map { $0.opacity(configuration.isPressed ? 0.75 : 1) } ?? (configuration.isPressed ? Color(hex: 0x565656) : JarasTheme.trackButton))
            .clipShape(RoundedRectangle(cornerRadius: 3)).contentShape(Rectangle())
    }
}
private struct TrackControlButtonStyle: ButtonStyle {
    var activeColor: Color? = nil
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.jarasSystem(size: 12, weight: .semibold))
            .padding(.horizontal, 7)
            .frame(minWidth: 30, minHeight: 24)
            .background(activeColor.map { $0.opacity(configuration.isPressed ? 0.75 : 1) } ?? JarasTheme.text.opacity(configuration.isPressed ? 0.24 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(JarasTheme.text.opacity(0.18)))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct TrackPanFader: View {
    let show: ShowController
    let track: UUID?
    let pan: Double
    var compact = false
    private let controlIdentity: TrackControlIdentity
    init(show: ShowController, track: UUID?, pan: Double, compact: Bool = false) {
        self.show = show; self.track = track; self.pan = pan; self.compact = compact
        controlIdentity = TrackControlIdentity(project: show.snapshot.project.id, track: track)
    }
    @State private var dragging = false
    @State private var dragValue = 0.0
    @State private var editingIdentity: TrackControlIdentity?
    @State private var editingSession: UUID?
    private var valueLabel: String {
        let value = dragging && editingIdentity == controlIdentity ? dragValue : pan
        let percent = Int((min(1, abs(value)) * 100).rounded())
        return percent == 0 ? "Center" : "\(percent)% \(value < 0 ? "L" : "R")"
    }
    var body: some View {
        let identity = controlIdentity
        let session = UUID()
        VStack(spacing: 0) {
            #if os(macOS)
            DirectVolumeSlider(show: show, groupValues: { show.mixerPreviewValues }, identity: identity, value: pan, minimum: -1, maximum: 1, mini: true, linkedTrack: show.current?.tracks.first(where: { $0.id == track })?.stereoLink?.partner, changed: { value in
                guard show.snapshot.project.id == identity.project else { return }
                if editingSession == session { dragValue = value }
                show.sendMixerControl(.pan, target: track, value: value, preview: true)
            }, editingChanged: { editing, value in
                guard show.snapshot.project.id == identity.project else { return }
                if editing {
                    editingIdentity = identity; editingSession = session
                    dragValue = value; dragging = true
                } else {
                    if editingSession == session { dragValue = value; dragging = false; editingSession = nil }
                    show.sendMixerControl(.pan, target: track, value: value)
                }
            }).frame(height: 14)
                .accessibilityLabel("Pan").accessibilityValue(valueLabel)
                .jarasHelp("Pan · Double-click to center")
            #else
            Slider(value: Binding(get: { pan }, set: { show.sendMixerControl(.pan, target: track, value: $0) }), in: -1...1)
                .frame(height: 13)
                .simultaneousGesture(TapGesture(count: 2).onEnded { show.sendMixerControl(.pan, target: track, value: 0) })
            #endif
            Text(verbatim: valueLabel).font(.jarasSystem(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(JarasTheme.text).lineLimit(1).frame(height: compact ? 8 : 10).allowsHitTesting(false)
        }
    }
}

private struct TrackVolumeFader: View {
    @ObservedObject private var fadeout: TransportFadeout
    let show: ShowController
    let track: UUID?
    let volume: Double
    let phaseInverted: Bool
    var compact = false
    var showsPhase = true
    // The Master can keep the same gain/pan across documents. Store its
    // project identity as a view input so SwiftUI rebinds the native callbacks
    // even when the ShowController reference and those scalar values match.
    private let controlIdentity: TrackControlIdentity
    init(show: ShowController, track: UUID?, volume: Double, phaseInverted: Bool, compact: Bool = false, showsPhase: Bool = true) {
        self.show = show; self.track = track; self.volume = volume
        _fadeout = ObservedObject(wrappedValue: show.transportFadeout)
        self.phaseInverted = phaseInverted; self.compact = compact; self.showsPhase = showsPhase
        controlIdentity = TrackControlIdentity(project: show.snapshot.project.id, track: track)
    }
    @State private var decibels = 0.0
    @State private var dragging = false
    @State private var editingIdentity: TrackControlIdentity?
    @State private var editingSession: UUID?
    private var gain: Double { decibels <= -60 ? 0 : pow(10, decibels / 20) }
    var body: some View {
        let baseGain = fadeout.active ? show.automationPlaybackValue(track, kind: .volume).map(TrackEnvelope.gain) ?? volume : volume
        let displayedGain = baseGain * fadeout.multiplier(for: track)
        let displayedDB = dragging && editingIdentity == controlIdentity ? decibels : (displayedGain <= 0 ? -60 : min(12, max(-59.9, 20 * log10(displayedGain))))
        return HStack(spacing: compact ? 3 : 6) {
            Text(displayedDB <= -60 ? "−∞" : String(format: "%+.1f", displayedDB))
                .font(.jarasSystem(size: compact ? 9 : 10, weight: .medium, design: .monospaced))
                .foregroundStyle(JarasTheme.text).frame(width: compact ? 34 : 40, alignment: .leading)
                .contentShape(Rectangle()).onTapGesture(count: 2) { decibels = 0; show.sendMixerControl(.volume, target: track, value: 1) }
                .jarasHelp("Double-click to reset to 0 dB").trackControlSelectionExclusion(selectsTrack: true)
            volumeControl.trackControlSelectionExclusion()
                .frame(height: compact ? 20 : 27)
                .modifier(MappingRightClick(track: track, command: "volume", hitHeight: 16))
                .frame(maxWidth: .infinity)
                .jarasHelp("Double-click to reset to 0 dB")
                .accessibilityLabel(track == nil ? "Master volume" : "Track volume")
                .accessibilityValue(displayedDB <= -60 ? "−∞ dB" : String(format: "%.1f dB", displayedDB))
            if let track, showsPhase { PhaseInvertButton(show: show, track: track, inverted: phaseInverted).trackControlSelectionExclusion() }
        }.frame(height: compact ? 20 : 27).padding(.horizontal, 4)
            .onAppear { synchronize() }
            .onChange(of: volume) { _ in if !dragging { synchronize() } }
            .onChange(of: controlIdentity) { identity in
                if editingIdentity != identity { dragging = false; editingSession = nil; synchronize() }
            }
    }
    private var volumeBinding: Binding<Double> {
        Binding(get: { decibels }, set: {
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
        DirectVolumeSlider(show: show, groupValues: { show.mixerPreviewValues }, identity: identity, value: volume <= 0 ? -60 : min(12, max(-59.9, 20 * log10(volume))), linkedTrack: show.current?.tracks.first(where: { $0.id == track })?.stereoLink?.partner, changed: { value in
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
        Slider(value: volumeBinding, in: -60...12, onEditingChanged: editingChanged)
            .tint(JarasTheme.green)
            .simultaneousGesture(TapGesture(count: 2).onEnded { decibels = 0; show.sendMixerControl(.volume, target: track, value: 1) })
        #endif
    }
    private func synchronize() { decibels = volume <= 0 ? -60 : min(12, max(-59.9, 20 * log10(volume))) }
}

#if os(macOS)
import AppKit
private struct DirectVolumeSlider: NSViewRepresentable {
    var show: ShowController? = nil
    var groupValues: (() -> [UUID: Double])? = nil
    let identity: TrackControlIdentity
    let value: Double
    var minimum = -60.0
    var maximum = 12.0
    var mini = false
    var vertical = false
    var rotary = false
    var linkedTrack: UUID? = nil
    let changed: (Double) -> Void
    let editingChanged: (Bool, Double) -> Void
    func makeNSView(context: Context) -> DirectVolumeSliderView {
        let slider = DirectVolumeSliderView()
        slider.minValue = minimum; slider.maxValue = maximum
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: DirectVolumeSliderView, context: Context) {
        let session = show?.projectSessionID
        slider.rebind(project: identity.project, track: identity.track, session: session)
        slider.minValue = minimum; slider.maxValue = maximum; slider.mini = mini
        slider.vertical = vertical; slider.rotary = rotary
        slider.linkedTrack = linkedTrack
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
    }
    static func dismantleNSView(_ slider: DirectVolumeSliderView, coordinator: ()) {
        slider.finishPointerEditing(deferred: true)
        slider.bindAutomation(nil)
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
    fileprivate var identity: TrackControlIdentity?
    private var modelGain: Double?
    private var fadeSubscription: AnyCancellable?
    private weak var fadeShow: ShowController?
    private(set) var stringValue = ""
    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.jarasMonospacedSystemFont(ofSize: 8, weight: .semibold), .foregroundColor: NSColor.white
    ]
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel("Track volume")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let text = NSAttributedString(string: stringValue, attributes: Self.attributes)
        text.draw(at: NSPoint(x: max(0, (bounds.width - text.size().width) / 2),
                             y: max(0, (bounds.height - text.size().height) / 2)))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { VolumeDoubleClickRouter.shared.removeGainLabel(self) }
        else { VolumeDoubleClickRouter.shared.addGainLabel(self) }
    }
    func bind(identity: TrackControlIdentity, gain: Double, show: ShowController? = nil) {
        let rebind = self.identity != identity || fadeShow !== show
        self.identity = identity
        if rebind {
            fadeShow = show
            fadeSubscription = show?.transportFadeout.$run.sink { [weak self] run in self?.updateFade(run) }
        }
        guard modelGain != gain || rebind else { return }
        modelGain = gain; updateFade(show?.transportFadeout.run)
    }
    private func updateFade(_ run: TransportFadeout.Run?) {
        guard let identity else { return }
        let normalized = run == nil ? nil : fadeShow?.automationPlaybackValue(identity.track, kind: .volume)
        let gain = normalized.map { $0 <= 0 ? 0 : pow(10, (-96 + $0*108)/20) } ?? modelGain ?? 1
        let factor = identity.track.flatMap { run?.originalVolumes[$0] } == nil ? 1 : run!.fraction
        let displayed = gain * factor
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
        text.draw(at: NSPoint(x: max(0, (bounds.width - text.size().width) / 2),
                             y: max(0, (bounds.height - text.size().height) / 2)))
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
        let percent = Int((min(1, abs(value.isFinite ? value : 0)) * 100).rounded())
        let next = percent == 0 ? "Center" : "\(value < 0 ? "L" : "R")-\(percent)%"
        if stringValue != next { stringValue = next; needsDisplay = true; setAccessibilityValue(next) }
    }
}
private final class DirectVolumeSliderView: NSView {
    private var automationSubscription: AnyCancellable?
    private var fadeSubscription: AnyCancellable?
    private var showingFade = false
    private weak var automationShow: ShowController?
    private var automationKey = ""
    func bindAutomation(_ show: ShowController?) {
        let kind: AutomationTarget.Kind = mini ? .pan : .volume
        let active = show?.automationPlaybackValue(boundTrack, kind: kind) != nil
        let key = "\(boundProject?.uuidString ?? "")/\(boundTrack?.uuidString ?? "master")/\(mini)/\(active)"
        guard automationShow !== show || automationKey != key else {
            updateFade(show?.transportFadeout.run); return
        }
        automationSubscription = nil; fadeSubscription = nil; automationShow = show; automationKey = key
        if let show, !mini {
            fadeSubscription = show.transportFadeout.$run.sink { [weak self] run in self?.updateFade(run) }
        }
        guard active, let show else { return }
        automationSubscription = show.$snapshot.sink { [weak self, weak show] _ in
            guard let self, let show, !self.trackingPointer,
                  let normalized = show.automationPlaybackValue(self.boundTrack, kind: kind) else { return }
            let factor = self.mini ? 1 : show.transportFadeout.multiplier(for: self.boundTrack)
            let value = self.mini ? normalized*2-1 : factor <= 0 ? -60 : max(-60, -96+normalized*108 + 20 * log10(factor))
            guard abs(value-self.doubleValue) > 0.00001 else { return }
            self.pendingModelValue = nil; self.lastModelValue = nil
            self.doubleValue = value
            if !show.transportFadeout.active { VolumeDoubleClickRouter.shared.mirror(self) }
        }
    }
    private func updateFade(_ run: TransportFadeout.Run?) {
        guard !mini, let show = automationShow, let id = boundTrack else { return }
        let selected = run?.originalVolumes[id] != nil
        guard selected || showingFade else { return }
        showingFade = selected
        let baseline = committedModelValue ?? 0
        let manual = show.automationPlaybackValue(id, kind: .volume).map { $0 <= 0 ? 0 : pow(10, (-96 + $0*108)/20) } ?? (baseline <= -60 ? 0 : pow(10, baseline/20))
        let gain = manual * (selected ? run!.fraction : 1)
        doubleValue = gain <= 0 ? -60 : min(12, max(-59.9, 20 * log10(gain)))
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
    var linkedTrack: UUID? { didSet { if oldValue != linkedTrack { needsDisplay = true } } }
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
    var doubleValue = 0.0 { didSet { needsDisplay = true; updatePanAccessibilityHelp() } }
    private func updatePanAccessibilityHelp() {
        guard mini else { setAccessibilityHelp(nil); return }
        let percent = Int((min(1, abs(doubleValue)) * 100).rounded())
        setAccessibilityHelp("Pan · " + (percent == 0 ? "Center" : "\(percent)% \(doubleValue < 0 ? "L" : "R")"))
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: vertical ? NSView.noIntrinsicMetric : (rotary ? 24 : 27)) }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        let normalized = min(1, max(0, (doubleValue - minValue) / (maxValue - minValue)))
        if rotary {
            let diameter = max(1, min(bounds.width, bounds.height) - 6)
            let circle = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
            NSColor(white: 0.18, alpha: 1).setFill(); NSBezierPath(ovalIn: circle).fill()
            NSColor.white.withAlphaComponent(0.35).setStroke(); NSBezierPath(ovalIn: circle).stroke()
            let angle = (normalized * 270 - 225) * Double.pi / 180
            let radius = min(circle.width, circle.height) * 0.4
            let path = NSBezierPath(); path.move(to: NSPoint(x: bounds.midX, y: bounds.midY))
            path.line(to: NSPoint(x: bounds.midX + cos(angle) * radius, y: bounds.midY + sin(angle) * radius))
            NSColor.systemGreen.setStroke(); path.lineWidth = 2; path.stroke(); return
        }
        if vertical {
            let rail = NSRect(x: bounds.midX - 3, y: 8, width: 6, height: max(1, bounds.height - 16))
            (linkedTrack != nil ? NSColor(JarasTheme.yellow) : NSColor.white.withAlphaComponent(0.22)).setFill()
            NSBezierPath(roundedRect: rail, xRadius: 3, yRadius: 3).fill()
            let y = 8 + (1 - normalized) * max(1, bounds.height - 16)
            (linkedTrack != nil ? NSColor(JarasTheme.green) : NSColor(white: 0.88, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 11, y: y - 6, width: 22, height: 12), xRadius: 2, yRadius: 2).fill()
            NSColor.darkGray.setFill(); NSRect(x: bounds.midX - 8, y: y - 0.5, width: 16, height: 1).fill(); return
        }
        let radius: CGFloat = mini ? 5 : 8
        let railHeight: CGFloat = mini ? 3 : 6
        let rail = NSRect(x: radius, y: bounds.midY - railHeight / 2, width: max(1, bounds.width - radius * 2), height: railHeight)
        (linkedTrack != nil && !mini ? NSColor(JarasTheme.yellow) : NSColor.white.withAlphaComponent(0.22)).setFill()
        NSBezierPath(roundedRect: rail, xRadius: 3, yRadius: 3).fill()
        let fraction = min(1, max(0, (doubleValue - minValue) / (maxValue - minValue)))
        let x = radius + CGFloat(fraction) * max(1, bounds.width - radius * 2)
        if mini {
            NSColor.white.withAlphaComponent(0.45).setFill()
            NSRect(x: bounds.midX - 0.5, y: bounds.midY - 5, width: 1, height: 10).fill()
        }
        (linkedTrack != nil && !mini ? NSColor(JarasTheme.green) : NSColor(white: 0.88, alpha: 1)).setFill()
        if mini {
            NSBezierPath(roundedRect: NSRect(x: x - 5, y: bounds.midY - 7, width: 10, height: 14), xRadius: 2, yRadius: 2).fill()
            NSColor(white: 0.6, alpha: 1).setFill()
            NSRect(x: x - 0.5, y: bounds.midY - 5, width: 1, height: 10).fill()
        } else {
            NSBezierPath(roundedRect: NSRect(x: x - 6, y: bounds.midY - 9, width: 12, height: 18), xRadius: 2, yRadius: 2).fill()
            NSColor.darkGray.setFill(); NSRect(x: x - 0.5, y: bounds.midY - 6, width: 1, height: 12).fill()
        }
    }
    override func keyDown(with event: NSEvent) {
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
    }
    override func mouseDragged(with event: NSEvent) {
        if trackingPointer { move(to: event) }
    }
    override func mouseUp(with event: NSEvent) {
        finishPointerEditing()
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
        doubleValue = minValue + Double(fraction) * (maxValue - minValue)
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
    let edit: () -> Void
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
    func makeNSView(context: Context) -> TrackRightClickView { TrackRightClickView() }
    func updateNSView(_ view: TrackRightClickView, context: Context) { view.interactionBlocked = interactionBlocked; view.project = project; view.track = track; view.kind = kind; view.dragName = dragName; view.selected = selected; view.select = select; view.patch = patch; view.fx = fx; view.edit = edit; view.icon = icon; view.group = group; view.ungroup = ungroup; view.removeFromGroup = removeFromGroup; view.link = link; view.unlink = unlink; view.soundDesigner = soundDesigner; view.createMIDI = createMIDI; view.duplicateTracks = duplicateTracks; view.deleteTracks = deleteTracks; view.deleteTrackCount = deleteTrackCount; view.action = { [weak view] in view?.openMenu() } }
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
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() {
        guard let window, window.attachedSheet == nil, !NativeTimelineInputGate.shared.isBlocked(window),
              !isHiddenOrHasHiddenAncestor else { return }
        let rect = bounds.intersection(visibleRect)
        guard !rect.isEmpty else { return }
        // The workspace already supplies this default. Rebuilding an arrow
        // for each control during unrelated timeline scrolling repeats AppKit
        // cursor-area registrations. Standalone mixers retain their own area.
        var ancestor = superview
        while let view = ancestor {
            if view is NativeTimelineDefaultCursorHost,
               view.bounds.intersection(view.visibleRect).contains(view.convert(rect, from: self)) { return }
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
        sessionGeneration &+= 1
        lastEventTime = nil; pressedTrack = nil; dragRow = nil; dragStart = nil; dragProject = nil
        menuTracks.removeAll(); selectionModifiers = nil; pendingSelection = nil; handledDownTime = nil
    }
    /// A reused row must retain the track that owns an in-flight button press.
    var pinnedTracks: Set<UUID> { menuTracks.union(pressedTrack.map { [$0] } ?? []) }
    private(set) var selectionModifiers: NSEvent.ModifierFlags?
    func addControl(_ view: NSView) { controls.add(view) }
    fileprivate func add(_ row: TrackRightClickView) {
        rows.add(row)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            if event.type == .leftMouseDragged, self?.beginEmptyAreaDrag(event) == true { return nil }
            self?.handle(event)
            return event
        }
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
              !RightClickRouter.shared.interactionBlocked,
              !event.modifierFlags.contains(.control), ControlMappings.shared.editing == nil else { return }
        let matches = rows.allObjects.filter { row in
            let point = row.convert(event.locationInWindow, from: nil)
            return !row.interactionBlocked && row.window === window && !row.isHiddenOrHasHiddenAncestor &&
                row.bounds.contains(point) && row.visibleRect.contains(point)
        }
        guard let row = matches.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return }
        pressedTrack = row.track
        if controls.allObjects.contains(where: { button in
            if (button as? TrackControlSelectionExclusionView)?.selectsTrack == true { return false }
            let point = button.convert(event.locationInWindow, from: nil)
            return button.window === window && !button.isHiddenOrHasHiddenAncestor &&
                button.bounds.contains(point) && button.visibleRect.contains(point)
        }) { return }
        // The title already owns its native drag source. All other unoccupied
        // space uses this row, while registered controls retain their gestures.
        if let root = window.contentView {
            var hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
            var isTitle = false
            while let view = hit {
                // Native meters only hit-test their peak readout. Resetting it
                // is a control action, not a track selection or drag gesture.
                if view is NativeVerticalTrackMeterView { return }
                if view is TrackDragTitleView { isTitle = true; break }
                hit = view.superview
            }
            if !isTitle && row.kind == .standard { dragRow = row; dragStart = event.locationInWindow; dragProject = row.project }
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
              !row.interactionBlocked, !RightClickRouter.shared.interactionBlocked,
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
            window.makeFirstResponder(nil)
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
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { TrackSelectionRouter.shared.add(self) }
    }
    var patch: (() -> Void)?
    var fx: (() -> Void)?
    var edit: (() -> Void)?
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
        if kind == .standard || kind == .timecode || kind == .video || kind == .click { append("Patch", patch) }
        if kind == .click { append("Sound Designer", soundDesigner) }
        if kind == .standard { append("FX", fx); append("Criar item MIDI", createMIDI); append(JarasLocalization.string("Create group"), group) }
        append(JarasLocalization.string("Ungroup"), ungroup)
        append(JarasLocalization.string("Remove from group"), removeFromGroup)
        append(JarasLocalization.string("Link tracks"), link)
        append(JarasLocalization.string("Unlink tracks"), unlink)
        append(JarasLocalization.string("Editar pista"), edit)
        append(JarasLocalization.string("Ícone da pista"), icon)
        append(JarasLocalization.string(deleteTrackCount > 1 ? "Duplicate tracks" : "Duplicate track"), duplicateTracks)
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
private final class TrackMenuAction: NSObject {
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
    let state: TrackReorderState
    let select: () -> Void
    var compact = false
    func makeNSView(context: Context) -> TrackDragTitleView { TrackDragTitleView() }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TrackDragTitleView, context: Context) -> CGSize? {
        CGSize(width: max(0, proposal.width ?? 0), height: max(0, proposal.height ?? 16))
    }
    func updateNSView(_ view: TrackDragTitleView, context: Context) {
        view.compact = compact; view.title = title; view.foreground = foreground; view.project = project; view.track = track; view.state = state; view.select = select
    }
}
@MainActor private final class TrackDragSource: NSObject, NSDraggingSource {
    let edgeScroll = NativeDragEdgeScroll()
    weak var state: TrackReorderState?
    var onEnd: (() -> Void)?
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { edgeScroll.stop(); state?.finish(); onEnd?() }
}
private final class TrackDragTitleView: NSView {
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
    var project = UUID() { didSet { if project != oldValue { down = nil } } }
    var track = UUID() { didSet { if track != oldValue { down = nil } } }
    weak var state: TrackReorderState?
    var select: (() -> Void)?
    private var down: NSPoint?
    private var cachedLabel: NSAttributedString?
    private static let labelAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.jarasSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph.copy() as! NSParagraphStyle]
    }()
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
    override func draw(_ dirtyRect: NSRect) { label().draw(in: compact ? bounds : NSRect(x: 0, y: (bounds.height - 14) / 2, width: bounds.width, height: 14)) }
    override func mouseDown(with event: NSEvent) {
        down = event.locationInWindow
        TrackSelectionRouter.shared.handle(event)
    }
    override func mouseUp(with event: NSEvent) { down = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let down, let state, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) >= 4 else { return }
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

struct TrackMIDIIndicator: View {
    @ObservedObject var state: TrackMIDIActivity
    var body: some View {
        GeometryReader { geometry in
            Rectangle().fill(Color.black.opacity(0.4))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(JarasTheme.green).frame(height: geometry.size.height * state.level)
                }
        }.allowsHitTesting(false).accessibilityLabel("MIDI activity")
    }
}

struct FooterMixerPanel: View {
    let show: ShowController
    let active: Bool
    let maximumHeight: CGFloat
    var resizeCoordinator: FooterVerticalResizeCoordinator? = nil
    @AppStorage("jaras.footerMixerHeight") private var storedHeight = 273.0
    @State private var resizeStart: CGFloat?
    @State private var resizeHeight: CGFloat?
    @State private var hovering = false
    private var heightLimit: CGFloat { min(723.55859375, maximumHeight) }
    private var height: CGFloat { min(heightLimit, max(273, resizeHeight ?? storedHeight)) }
    var body: some View {
        #if os(macOS)
        FooterNativeHeightHost(storedHeight: CGFloat(storedHeight), minimum: 273, maximum: heightLimit,
            active: active, identity: AnyHashable(ObjectIdentifier(show)),
            role: .mixer, resizeCoordinator: resizeCoordinator) {
            VStack(spacing: 0) {
                FooterMixerResizeInput(height: height, maximum: heightLimit, changed: { _ in }, ended: { storedHeight = $0 })
                    .frame(height: 8).jarasHelp("Drag to resize mixer")
                // The native container owns visibility. Keep its controls and meters mounted;
                // toggling active rebuilt every visible channel twice on each open/close.
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
                    resizeHeight = min(heightLimit, max(273, (resizeStart ?? height) - value.translation.height))
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
    static let stride: CGFloat = width + 3
}

private struct FooterMixerStripLayout {
    let controlsHeight: CGFloat
    let slotsHeight: CGFloat
    init(height: CGFloat, slotsOnly: Bool, iconHeight: CGFloat = 0) {
        let innerHeight = max(0, height - 8 - iconHeight)
        // Keep the normal mixer unchanged. The compact mode gives everything
        // above the fixed lower name row to the existing FX/instrument slots.
        controlsHeight = slotsOnly ? 0 : min(187, max(100, innerHeight - 26))
        slotsHeight = max(0, innerHeight - controlsHeight - 26)
    }
}

private struct FooterMixerRenderState: Equatable {
    let project: UUID
    let tracks: [Track]
    let masterFX: NativeFXSettings?
    let masterVolume: Double
    let masterPan: Double
    let masterMute: Bool
    let masterSolo: Bool
    let masterMono: Bool
    let masterColor: UInt32?
    let selection: Set<UUID>
    var masterRight = false
    var slotsOnly = false
    var showsInstrumentIcons: Bool { tracks.contains { $0.instrumentIcon.flatMap(TrackInstrumentIcon.init(rawValue:)) != nil } }
}
struct FooterHorizontalMixer: View {
    @AppStorage("catlive.barMixer.masterRight") private var masterRight = false
    @AppStorage("catlive.hozMixer.slotsOnly") private var slotsOnly = false
    let show: ShowController
    @ObservedObject private var updates: ShowProjectPresentation
    @ObservedObject private var trackVisibility = TrackVisibilityPreferences.shared
    var active = true
    init(show: ShowController, active: Bool = true) {
        self.show = show; self.active = active
        _updates = ObservedObject(wrappedValue: show.projectPresentation)
    }
    var body: some View {
        let project = show.snapshot.project
        let tracks = trackVisibility.state(for: project.id).visibleTracks(in: show.current?.tracks ?? [], area: .barMixer)
            .filter { $0.kind == .standard || $0.kind == .click }.map { track in
            var presentation = track; presentation.clips = []; return presentation
        }
        FooterMixerContent(show: show, active: active, state: FooterMixerRenderState(project: project.id, tracks: tracks,
            masterFX: project.masterFX, masterVolume: project.masterVolume ?? 1, masterPan: project.masterPan ?? 0,
            masterMute: project.masterMute == true, masterSolo: project.masterSolo == true, masterMono: project.masterMono == true, masterColor: project.masterColor, selection: show.mixerTrackSelection.intersection(tracks.map(\.id)), masterRight: masterRight, slotsOnly: slotsOnly)).equatable()
            #if os(macOS)
            .background(EditorSelectionArea(scope: .tracks) {
                let selectable = tracks.filter { $0.kind == .standard }
                show.setMixerTrackSelection(Set(selectable.map(\.id)), anchor: selectable.first?.id)
                return !selectable.isEmpty
            })
            #endif
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
        let commonChanged = previous?.project != state.project || previous?.selection != state.selection || previous?.slotsOnly != state.slotsOnly || previous?.showsInstrumentIcons != state.showsInstrumentIcons || previousActive != active || previousLocale != locale
        if previous?.project != state.project || previousActive != active || previousLocale != locale ||
            previous?.masterFX != state.masterFX || previous?.masterVolume != state.masterVolume ||
            previous?.masterPan != state.masterPan || previous?.masterMute != state.masterMute ||
            previous?.masterSolo != state.masterSolo || previous?.masterMono != state.masterMono ||
            previous?.masterColor != state.masterColor || previous?.masterRight != state.masterRight || previous?.slotsOnly != state.slotsOnly || previous?.showsInstrumentIcons != state.showsInstrumentIcons {
            counter &+= 1; masterVersion = counter
        }
        let next = state.tracks.enumerated().map { index, track -> UInt64 in
            if !commonChanged, let previous, index < previous.tracks.count,
               index < versions.count, previous.tracks[index] == track { return versions[index] }
            counter &+= 1; return counter
        }
        previous = state; previousActive = active; previousLocale = locale; versions = next
        return next
    }
}
private struct FooterMixerContent: View, Equatable {
    let show: ShowController
    let active: Bool
    let state: FooterMixerRenderState
    @Environment(\.openFX) private var openFX
    @Environment(\.locale) private var locale
    @Environment(\.editTrackDetails) private var editTrackDetails
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.show === rhs.show && lhs.active == rhs.active && lhs.state == rhs.state }
    @State private var stripVersions = FooterMixerStripVersions()
    private var count: Int { state.tracks.count }
    private func strips(_ range: Range<Int>) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(Array(range), id: \.self) { index in
                    FooterMixerStrip(show: show, track: state.tracks[index], selection: state.selection, active: active, slotsOnly: state.slotsOnly, showsInstrumentIcons: state.showsInstrumentIcons).equatable()
                        .id(state.tracks[index].id)
                }
            }
        }.padding(5)
            .environment(\.openFX, openFX).environment(\.locale, locale).environment(\.editTrackDetails, editTrackDetails)
    }
    var body: some View {
        Group {
            #if os(macOS)
            let versions = stripVersions.update(state, active: active, locale: locale.identifier)
            FooterMixerScroll(contentWidth: CGFloat(count) * FooterMixerMetrics.stride + 7, stride: FooterMixerMetrics.stride, count: count, active: active,
                masterWidth: FooterMixerMetrics.masterWidth, masterRight: state.masterRight, masterVersion: stripVersions.masterVersion,
                masterContent: AnyView(FooterMixerStrip(masterState: state, show: show, track: nil, selection: [], active: active, slotsOnly: state.slotsOnly, showsInstrumentIcons: state.showsInstrumentIcons).equatable().padding(5)
                    .environment(\.openFX, openFX).environment(\.locale, locale).environment(\.editTrackDetails, editTrackDetails)),
                versions: versions, retainStrip: { index in
                    state.tracks.indices.contains(index) && TrackSelectionRouter.shared.pinnedTracks.contains(state.tracks[index].id)
                }) { range in AnyView(strips(range)) }
            #else
            ScrollView(.horizontal) {
                LazyHStack(spacing: 3) {
                    ForEach(state.tracks) { FooterMixerStrip(show: show, track: $0, selection: state.selection, active: active, slotsOnly: state.slotsOnly, showsInstrumentIcons: state.showsInstrumentIcons) }
                }.padding(5)
            }.scrollIndicators(.visible)
            #endif
        }.background(JarasTheme.panel).overlay(alignment: .top) { Divider() }
    }
}

#if os(macOS)
private struct FooterMixerScroll: NSViewRepresentable {
    let contentWidth: CGFloat
    let stride: CGFloat
    let count: Int
    let active: Bool
    let masterWidth: CGFloat
    let masterRight: Bool
    let masterVersion: UInt64
    let masterContent: AnyView
    var versions: [UInt64]? = nil
    var retainStrip: (Int) -> Bool = { _ in false }
    let makeContent: (Range<Int>) -> AnyView
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FooterMixerScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? max(1, nsView.frame.width), height: proposal.height ?? 242)
    }
    func makeNSView(context: Context) -> FooterMixerScrollView { FooterMixerScrollView() }
    func updateNSView(_ view: FooterMixerScrollView, context: Context) {
        view.isHidden = !active
        view.setSlotsOnly = { UserDefaults.standard.set($0, forKey: "catlive.hozMixer.slotsOnly") }
        view.updateMaster(content: masterContent, width: masterWidth, version: masterVersion, right: masterRight)
        view.update(width: contentWidth, stride: stride, count: count, versions: versions, retainStrip: retainStrip, makeContent: makeContent)
    }
}
private final class FooterMixerGreenScroller: NSScroller {
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: slotRect.minX, y: bounds.midY - 3, width: slotRect.width, height: 6), xRadius: 3, yRadius: 3).fill()
    }
    override func drawKnob() {
        NSColor(calibratedRed: 84.0 / 255, green: 1, blue: 147.0 / 255, alpha: 1).setFill()
        let knob = rect(for: .knob)
        NSBezierPath(roundedRect: NSRect(x: knob.minX, y: bounds.midY - 3, width: knob.width, height: 6), xRadius: 3, yRadius: 3).fill()
    }
}
/// Deliberate Shift-wheel mode change; a single notch or accelerated spike
/// cannot hide mixer controls. No preference write occurs until the threshold.
private struct FooterMixerModeGesture {
    private var direction = 0
    private var accumulated: CGFloat = 0
    private var lastTime: TimeInterval?
    private var triggered = false
    private var lastAction: TimeInterval?
    mutating func reset() { direction = 0; accumulated = 0; lastTime = nil; triggered = false }
    mutating func consume(delta: CGFloat, precise: Bool, timestamp: TimeInterval, momentum: Bool) -> Bool? {
        guard !momentum else { return nil }
        guard delta.isFinite, timestamp.isFinite, delta != 0 else { return nil }
        let nextDirection = delta > 0 ? 1 : -1
        if nextDirection != direction || lastTime.map({ timestamp < $0 || timestamp - $0 > 0.6 }) == true { reset() }
        direction = nextDirection; lastTime = timestamp
        guard !triggered else { return nil }
        if let lastAction, timestamp >= lastAction, timestamp - lastAction < 0.6 { return nil }
        accumulated += min(40, abs(delta) * (precise ? 1 : 40))
        guard accumulated >= 60 else { return nil }
        triggered = true; lastAction = timestamp
        return direction > 0
    }
}
private final class FooterMixerDocumentView: NSView {
    override var isFlipped: Bool { true }
}
private final class FooterMixerHostingView: NSHostingView<AnyView> {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    private weak var channelGeometry: FooterMixerStripGeometryView?
    func setChannelFrame(_ viewport: NSRect) {
        if channelGeometry == nil {
            func find(_ view: NSView) -> FooterMixerStripGeometryView? {
                if let geometry = view as? FooterMixerStripGeometryView { return geometry }
                for child in view.subviews { if let found = find(child) { return found } }
                return nil
            }
            channelGeometry = find(self)
        }
        var hosted = viewport
        if let channelGeometry {
            // The native channel owns its visible geometry. Keep the outer
            // SwiftUI decorations at one proposal instead of re-laying out its
            // context menus, sheets and overlays on every vertical pixel.
            hosted.size.height = max(724, viewport.height)
            channelGeometry.setViewportHeight(max(0, viewport.height - 10))
        }
        if frame != hosted { frame = hosted }
    }
}
/// Only the FX viewport changes size during a mixer height drag. The lower
/// controls retain their SwiftUI proposal and move as one native rectangle.
private struct FooterMixerStripGeometry: NSViewRepresentable {
    let slotsOnly: Bool
    let iconHeight: CGFloat
    let selected: Bool
    let slots: AnyView
    let footer: (CGFloat) -> AnyView
    func makeNSView(context: Context) -> FooterMixerStripGeometryView { FooterMixerStripGeometryView() }
    func updateNSView(_ view: FooterMixerStripGeometryView, context: Context) {
        view.update(slotsOnly: slotsOnly, iconHeight: iconHeight, slots: slots, selected: selected, footer: footer)
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FooterMixerStripGeometryView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? nsView.frame.height)
    }
}
private final class FooterMixerStripGeometryView: NSView {
    private let slots = FooterMixerHostingView(rootView: AnyView(EmptyView()))
    private let footer = FooterMixerHostingView(rootView: AnyView(EmptyView()))
    private var slotsOnly = false
    private var iconHeight: CGFloat = 0
    private var makeFooter: ((CGFloat) -> AnyView)?
    private var controlsHeight: CGFloat?
    private var viewportHeight: CGFloat?
    private var selected = false
    private let bottomSelection = CALayer()
    func setViewportHeight(_ height: CGFloat) {
        guard viewportHeight != height else { return }
        viewportHeight = height; needsLayout = true
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bottomSelection.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
        layer?.addSublayer(bottomSelection)
        for view in [slots, footer] {
            if #available(macOS 13, *) { view.sizingOptions = [] }
            if #available(macOS 13.3, *) { view.safeAreaRegions = [] }
            view.autoresizingMask = []; view.wantsLayer = true; view.clipsToBounds = true
            addSubview(view)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(slotsOnly: Bool, iconHeight: CGFloat, slots: AnyView, selected: Bool = false, footer: @escaping (CGFloat) -> AnyView) {
        self.slotsOnly = slotsOnly; self.iconHeight = iconHeight; self.selected = selected; makeFooter = footer
        self.slots.rootView = slots; controlsHeight = nil; needsLayout = true
    }
    override func layout() {
        super.layout()
        let layout = FooterMixerStripLayout(height: viewportHeight ?? bounds.height, slotsOnly: slotsOnly, iconHeight: iconHeight)
        if controlsHeight != layout.controlsHeight {
            controlsHeight = layout.controlsHeight
            if let makeFooter { footer.rootView = makeFooter(layout.controlsHeight) }
        }
        let width = max(0, bounds.width - 8)
        let top = NSRect(x: 4, y: 4, width: width, height: layout.slotsHeight)
        let bottom = NSRect(x: 4, y: top.maxY, width: width, height: layout.controlsHeight + 26 + iconHeight)
        slots.isHidden = top.height <= 0
        if slots.frame != top { slots.frame = top }
        if footer.frame != bottom { footer.frame = bottom }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bottomSelection.isHidden = !selected || viewportHeight == nil
        bottomSelection.frame = NSRect(x: 0, y: max(0, (viewportHeight ?? bounds.height) - 0.5), width: bounds.width, height: 0.5)
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
        host.rootView = content; contentHeight = max(0, height); needsLayout = true
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
private final class FooterMixerScrollView: NSView {
    private let scroll = NSScrollView()
    private let bar = FooterMixerGreenScroller(frame: NSRect(x: 0, y: 0, width: 200, height: 14))
    private let host = FooterMixerDocumentView()
    private var master: FooterMixerHostingView?
    private var masterWidth: CGFloat = 0
    private var masterRight = false
    private var masterVersion: UInt64?
    private var strips: [Int: FooterMixerHostingView] = [:]
    private var versions: [UInt64]?
    private var mountedVersions: [Int: UInt64] = [:]
    private var cachedStrips: [Int: (view: FooterMixerHostingView, version: UInt64?)] = [:]
    private var cachedStripOrder: [Int] = []
    private var contentWidth: CGFloat = 1
    private var makeContent: ((Range<Int>) -> AnyView)?
    private var retainStrip: (Int) -> Bool = { _ in false }
    private var preparedRange: Range<Int> = 0..<0
    private var trackCount = 1
    private var trackStride: CGFloat = 153
    private var preparing = false
    private var pendingStripLayout: Set<Int> = []
    private var layoutWarmup: DispatchWorkItem?
    private var wheelMonitor: Any?
    private var modeGesture = FooterMixerModeGesture()
    var setSlotsOnly: (Bool) -> Void = { _ in }
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
    func updateMaster(content: AnyView, width: CGFloat, version: UInt64, right: Bool = false) {
        if let master {
            if masterVersion != version { master.rootView = content }
        } else {
            let view = FooterMixerHostingView(rootView: content)
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
    func update(width: CGFloat, stride: CGFloat, count: Int, versions: [UInt64]? = nil,
                retainStrip: @escaping (Int) -> Bool = { _ in false }, makeContent: @escaping (Range<Int>) -> AnyView) {
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
                // Detaching/re-attaching NSHostingView invalidates its SwiftUI
                // environment and triggers window-wide layout on every reversal.
                // These frames remain outside the clip; meters already skip
                // drawing when visibleRect is empty. Bound retention for large projects.
                strip.isHidden = true
                cachedStrips[index] = (strip, version)
                cachedStripOrder.removeAll { $0 == index }; cachedStripOrder.append(index)
            } else { strip.removeFromSuperview() }
        }
        let cacheLimit = min(64, max(24, preparedRange.count * 3))
        while cachedStripOrder.count > cacheLimit {
            // A reversal caches the old viewport before mounting the new
            // one. Never evict a cached destination strip in that interval.
            guard let victim = cachedStripOrder.firstIndex(where: { !preparedRange.contains($0) }) else { break }
            cachedStrips.removeValue(forKey: cachedStripOrder.remove(at: victim))?.view.removeFromSuperview()
        }
    }
    private func prepare(at x: CGFloat, force: Bool = false) {
        guard !preparing, let makeContent else { return }
        let viewportWidth = max(1, scroll.contentSize.width > 0 ? scroll.contentSize.width : bounds.width)
        let first = max(0, min(trackCount - 1, Int(max(0, x) / trackStride)))
        let last = min(trackCount, Int(ceil((max(0, x) + viewportWidth) / trackStride)))
        let margin = 2
        // A narrowed window must release channels from its former wide viewport.
        // Retain the usual scroll reserve, but never keep an arbitrarily larger
        // set of SwiftUI roots in every later window layout pass.
        if !force && preparedRange.lowerBound <= first && preparedRange.upperBound >= last,
           preparedRange.count <= last - first + margin * 2 {
            // A menu or fader may have finished since the preceding scroll.
            releaseUnusedStrips()
            layoutVisibleStrips(in: first..<last)
            scheduleStripWarmup()
            return
        }
        // Keep each channel's hosting tree stable. Scrolling must not diff and
        // relayout an entire screen of controls at every virtualization boundary.
        preparedRange = max(0, first - margin)..<min(trackCount, last + margin)
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
                    strip.rootView = makeContent(index..<(index + 1))
                }
            } else if let cached = cachedStrips.removeValue(forKey: index) {
                cachedStripOrder.removeAll { $0 == index }
                strip = cached.view
                // Edits/reorders/visibility changes can happen while detached.
                // Always validate the version here, including normal scrolling.
                if version == nil || cached.version != version {
                    strip.rootView = makeContent(index..<(index + 1))
                }
                strips[index] = strip
                if strip.superview !== host { host.addSubview(strip) }
                strip.isHidden = false
                changed = true
            } else {
                strip = FooterMixerHostingView(rootView: makeContent(index..<(index + 1)))
                if #available(macOS 13, *) { strip.sizingOptions = [] }; strip.wantsLayer = true
                strip.clipsToBounds = true
                // The scroll container supplies an explicit channel rectangle;
                // window safe-area changes must not remeasure every channel.
                if #available(macOS 13.3, *) { strip.safeAreaRegions = [] }
                strips[index] = strip; host.addSubview(strip); changed = true
            }
            mountedVersions[index] = version
            let frame = NSRect(x: CGFloat(index) * trackStride, y: 0,
                               width: trackStride + 7, height: scroll.contentSize.height)
            if strip.frame.size.width != frame.width { changed = true }
            strip.setChannelFrame(frame)
            if changed { pendingStripLayout.insert(index) }
        }
        preparing = false
        // Only the actual destination must be ready before the clip moves.
        // Overscan roots used to force SwiftUI layout inside every wheel event.
        layoutVisibleStrips(in: first..<last)
        scheduleStripWarmup()
    }
    private func layoutVisibleStrips(in range: Range<Int>) {
        for index in range where pendingStripLayout.remove(index) != nil {
            strips[index]?.layoutSubtreeIfNeeded()
        }
    }
    private func scheduleStripWarmup() {
        guard layoutWarmup == nil, window != nil, !pendingStripLayout.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.layoutWarmup = nil
            guard self.window != nil, !self.isHiddenOrHasHiddenAncestor,
                  let index = self.pendingStripLayout.min() else { return }
            self.pendingStripLayout.remove(index)
            self.strips[index]?.layoutSubtreeIfNeeded()
            self.scheduleStripWarmup()
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
            let previousSize = master.frame.size
            master.setChannelFrame(frame)
            if previousSize != master.frame.size { master.layoutSubtreeIfNeeded() }
        }
        if bar.frame != barFrame { bar.frame = barFrame }
        if scroll.frame != scrollFrame { scroll.frame = scrollFrame }
        let hostFrame = NSRect(x: 0, y: 0, width: max(scroll.contentSize.width, contentWidth), height: scroll.contentSize.height)
        if host.frame != hostFrame { host.frame = hostFrame }
        // Hidden cached channels receive their current height when remounted.
        // Resizing them here reflows up to 64 offscreen SwiftUI trees per pixel.
        for strip in strips.values where strip.frame.height != scroll.contentSize.height {
            var frame = strip.frame; frame.size.height = scroll.contentSize.height
            strip.setChannelFrame(frame)
        }
        move(to: scroll.contentView.bounds.minX)
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

    private func move(to x: CGFloat) {
        let target = min(max(0, x), max(0, host.frame.width - scroll.contentSize.width))
        prepare(at: target)
        // One preparation per frame. Scrolling posts a synchronous bounds
        // notification; that notification used to prepare the same strips again.
        if scroll.contentView.bounds.origin != NSPoint(x: target, y: 0) {
            movingClip = true
            scroll.contentView.scroll(to: NSPoint(x: target, y: 0))
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
        stopCoast(); modeGesture.reset()
        layoutWarmup?.cancel(); layoutWarmup = nil
        guard window != nil else { return }
        scheduleStripWarmup()
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .flagsChanged]) { [weak self] event in
            if event.type == .flagsChanged {
                if !event.modifierFlags.contains(.shift) { self?.modeGesture.reset() }
                return event
            }
            return self?.routeWheel(event) == true ? nil : event
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
              !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(event.locationInWindow, from: nil)),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            modeGesture.reset(); return false
        }
        if event.modifierFlags.contains(.shift) {
            stopCoast()
            if event.phase.contains(.began) { modeGesture.reset() }
            // AppKit may map a shifted physical wheel onto the horizontal axis.
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            if let slotsOnly = modeGesture.consume(delta: delta, precise: event.hasPreciseScrollingDeltas,
                                                    timestamp: event.timestamp, momentum: !event.momentumPhase.isEmpty) {
                setSlotsOnly(slotsOnly)
            }
            if !event.phase.intersection([.ended, .cancelled]).isEmpty { modeGesture.reset() }
            // Consume every Shift-wheel event, including the pre-threshold steps,
            // so faders, knobs and slot scroll views cannot alter their values.
            return true
        }
        modeGesture.reset()
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let delta = horizontal && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        if !horizontal, let target = effectScroll(at: event.locationInWindow) {
            // A slot list only owns vertical scrolling inside its clipped viewport.
            // Consume the event here so AppKit never pans its document sideways.
            target.horizontalScrollElasticity = .none
            if event.hasPreciseScrollingDeltas {
                stopCoast(); scrollBy(delta, target: target, horizontal: false)
            } else { smoothWheel(delta * 16, target: target, horizontal: false) }
        } else if event.hasPreciseScrollingDeltas {
            stopCoast(); move(to: scroll.contentView.bounds.minX - delta)
        } else { smoothWheel(delta * 16, target: scroll, horizontal: true) }
        return true
    }


}
#endif

private struct FooterMixerStrip: View, Equatable {
    var masterState: FooterMixerRenderState? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.show === rhs.show && lhs.track == rhs.track && lhs.selection == rhs.selection && lhs.active == rhs.active && lhs.masterState == rhs.masterState && lhs.slotsOnly == rhs.slotsOnly && lhs.showsInstrumentIcons == rhs.showsInstrumentIcons
    }
    let show: ShowController
    let track: Track?
    let selection: Set<UUID>
    let active: Bool
    var slotsOnly = false
    var showsInstrumentIcons = false
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.editTrackDetails) private var editTrackDetails
    @State private var patchPresented = false
    @State private var fxPresented = false
    @State private var colorPresented = false
    @State private var deletion: (project: UUID, song: UUID, tracks: Set<UUID>)?
    private var selected: Bool { track?.kind == .standard && id.map { selection.contains($0) } == true }
    private var targets: [UUID?] {
        guard selected else { return [id] }
        return (show.current?.tracks ?? []).filter { selection.contains($0.id) && $0.kind == .standard }.map { Optional($0.id) }
    }
    private var canLink: Bool { selected && show.current?.linkableTracks(selection) != nil }
    private var isFolder: Bool { id.map { id in show.current?.tracks.contains(where: { $0.parentTrackID == id }) == true } == true }
    private var canGroup: Bool { id.map { show.current?.canCreateTrackGroup($0) == true } == true }
    private func select() {
        guard let track, track.kind == .standard, let song = show.current else { return }
        var ids = selection
        #if os(macOS)
        let flags = TrackSelectionRouter.shared.selectionModifiers ?? NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = show.selectedTrackForActions,
           let start = song.tracks.firstIndex(where: { $0.id == anchor }), let end = song.tracks.firstIndex(where: { $0.id == track.id }) {
            let hidden = TrackVisibilityPreferences.shared.state(for: show.snapshot.project.id).effectiveHidden(in: song.tracks, area: .barMixer)
            ids = Set(song.tracks[min(start, end)...max(start, end)].filter { $0.kind == .standard && !hidden.contains($0.id) }.map(\.id))
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
    private func editDetails(iconOnly: Bool) {
        guard let track else { colorPresented = true; return }
        let ids = Set(targets.compactMap { $0 })
        editTrackDetails(TrackDetailsEditRequest(project: show.snapshot.project.id, tracks: ids,
            name: track.name, color: track.color ?? JarasTheme.roleHex(track.role), nameEditable: ids.count == 1 && track.kind == .standard && track.role.rawValue != "vinhetas", instrumentIcon: track.instrumentIcon, iconOnly: iconOnly))
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
    private var color: Color { Color(hex: track.map { $0.color ?? JarasTheme.roleHex($0.role) } ?? show.snapshot.project.masterColor ?? 0x414141) }
    private var hasStandardControls: Bool { track == nil || track?.kind == .standard }
    private var buttons: some View {
        VStack(spacing: 5) {
            if hasStandardControls {
                TrackFXButton(show: show, track: id, settings: settings, opensChain: true).jarasHelp("FX Manager")
            }
            if trackShowsMuteSolo(track?.kind) {
                Button("M") { show.sendTrackMixerButton(.mute, target: id) }
                    .buttonStyle(CompactTrackButtonStyle(activeColor: (track?.mute ?? (show.snapshot.project.masterMute == true)) ? .red : nil))
                    .modifier(MappingRightClick(track: id, command: "mute")).jarasHelp("Mute")
                Button("S") { show.sendTrackMixerButton(.solo, target: id) }
                    .buttonStyle(CompactTrackButtonStyle(activeColor: (track?.solo ?? (show.snapshot.project.masterSolo == true)) ? JarasTheme.yellow : nil))
                    .modifier(MappingRightClick(track: id, command: "solo")).jarasHelp("Solo")
            }
            if track == nil {
                Button { show.send(.masterMono) } label: {
                    ZStack {
                        Circle().stroke(lineWidth: 1.3).frame(width: 11, height: 11).offset(x: -3.5)
                        Circle().stroke(lineWidth: 1.3).frame(width: 11, height: 11).offset(x: 3.5)
                    }.frame(width: 22, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .foregroundStyle(masterState?.masterMono == true ? JarasTheme.green : JarasTheme.text)
                    .accessibilityLabel("Master Stereo/Mono").accessibilityValue(masterState?.masterMono == true ? "Mono" : "Stereo")
                    .jarasHelp(masterState?.masterMono == true ? "Mono — switch to Stereo" : "Stereo — switch to Mono")
            }
            if let track, track.kind == .standard { TrackRecordButton(show: show, track: track) }
            if let track, track.kind != .timecode && track.kind != .click && track.role.rawValue != "vinhetas" {
                PhaseInvertButton(show: show, track: track.id, inverted: track.phaseInverted == true)
            }
            if trackShowsMeterReadouts(track?.kind) {
                TrackPeakReadout(peak: id.map { StemAudioPlayback.shared.meter(for: $0).peakHold } ?? StemAudioPlayback.shared.masterMeter.peakHold,
                                 compact: true, foreground: .white)
                    .frame(width: 22, height: 12)
            }
            Spacer(minLength: 0)
        }.frame(width: 22).buttonStyle(CompactTrackButtonStyle()).font(.jarasSystem(size: 10, weight: .bold))
    }
    private var slots: some View {
        FooterEffectSlotsScroll(contentHeight: CGFloat(max(3, settings.effectKeys.count + 1)) * 21 - 2) {
            VStack(spacing: 2) {
                ForEach(settings.effectKeys, id: \.self) { effect in
                    FooterEffectSlot(show: show, track: id, effect: effect, settings: settings)
                }
                ForEach(0..<max(1, 3 - settings.effectKeys.count), id: \.self) { _ in
                    FooterEffectSlot(show: show, track: id, effect: nil, settings: settings)
                }
            }
        }
    }
    private var panAndFader: some View {
        VStack(spacing: 1) {
            let pan = track?.pan ?? masterState?.masterPan ?? 0
            if hasStandardControls && track?.role.rawValue != "vinhetas" {
                VStack(spacing: 1) {
                    #if os(macOS)
                    FooterMixerPanReadout(identity: TrackControlIdentity(project: show.snapshot.project.id, track: id),
                                          pan: pan, linkedTrack: track?.stereoLink?.partner)
                        .frame(width: 50, height: 10)
                    #else
                    let percent = Int((min(1, abs(pan)) * 100).rounded())
                    Text(verbatim: percent == 0 ? "Center" : "\(pan < 0 ? "L" : "R")-\(percent)%")
                        .font(.jarasSystem(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                        .frame(width: 50, height: 10)
                    #endif
                    FooterMixerControl(show: show, track: id, value: pan, pan: true, linked: track?.stereoLink?.partner)
                        .frame(width: 24, height: 24).jarasHelp("Pan · Double-click to center")
                }
            }
            let gain = track?.volume ?? show.snapshot.project.masterVolume ?? 1
            #if os(macOS)
            FooterMixerGainReadout(show: show, identity: TrackControlIdentity(project: show.snapshot.project.id, track: id), gain: gain)
                .frame(width: 50, height: 12)
            #else
            Text(verbatim: (gain <= 0 ? "−∞" : String(format: "%+.1f", min(12, max(-60, 20 * log10(gain))))) + " dB")
                .font(.jarasSystem(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                .frame(width: 50, height: 12)
            #endif
            HStack(spacing: 2) {
                FooterMixerControl(show: show, track: id, value: track?.volume ?? show.snapshot.project.masterVolume ?? 1, pan: false, linked: track?.stereoLink?.partner)
                    .frame(width: 27).jarasHelp("Double-click to reset to 0 dB")
                if active {
                    VerticalTrackMeter(meter: id.map { StemAudioPlayback.shared.meter(for: $0) } ?? StemAudioPlayback.shared.masterMeter, showScale: false)
                        .frame(width: 8)
                } else { Color.clear.frame(width: 8) }
                if active, let track, track.kind == .standard && track.role.rawValue != "vinhetas" {
                    TrackMIDIIndicator(state: InstrumentKeyboardState.shared.activity(track.id)).frame(width: 3).padding(.vertical, 4)
                }
            }
        }.frame(width: 50)
    }
    @ViewBuilder private func fixedFooter(controlsHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if !slotsOnly {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 4) {
                        if let track, track.kind == .click {
                            HStack(spacing: 3) {
                                Button("Patch") { patchPresented = true }.buttonStyle(CompactTrackButtonStyle(width: 34))
                                Button("Insert") { show.insertClickItems(track: track.id) }
                                    .buttonStyle(CompactTrackButtonStyle(width: 47))
                                    .jarasHelp("Insert click items in regions without a click")
                            }
                        }
                        HStack(spacing: 3) {
                            buttons
                            panAndFader.frame(maxHeight: .infinity)
                        }.frame(maxWidth: .infinity)
                    }
                }.frame(height: controlsHeight).trackControlSelectionExclusion()
            }
            Group {
                #if os(macOS)
                if let track {
                    TrackDragTitle(title: track.name, foreground: 0xffffff, project: show.snapshot.project.id,
                        track: track.id, state: TrackReorderState.shared, select: select, compact: true)
                } else { Text("Master").font(.jarasSystem(size: 10, weight: .semibold)) }
                #else
                Text(verbatim: track?.name ?? "Master").font(.jarasSystem(size: 10, weight: .semibold))
                    .lineLimit(2).multilineTextAlignment(.center)
                    .contentShape(Rectangle()).onDrag {
                        guard let track else { return NSItemProvider() }
                        TrackReorderState.shared.begin(track: track.id); select()
                        return TrackReorderState.provider(track.id)
                    }
                #endif
            }.frame(maxWidth: .infinity).frame(height: 22).padding(.top, 4)
                .foregroundStyle(.white).accessibilityHint(Text(verbatim: track?.name ?? "Master"))
            if showsInstrumentIcons {
                Group {
                    if let raw = track?.instrumentIcon, let icon = TrackInstrumentIcon(rawValue: raw) {
                        TrackInstrumentIconView(icon: icon).foregroundStyle(.white)
                    } else { Color.clear }
                }.frame(height: 28).padding(.top, 2).allowsHitTesting(false)
            }
        }
    }
    var body: some View {
        let deleteIDs = deletionTargets, deleteProject = show.snapshot.project.id
        Group {
            #if os(macOS)
            FooterMixerStripGeometry(slotsOnly: slotsOnly, iconHeight: showsInstrumentIcons ? 30 : 0, selected: selected,
                slots: AnyView(Group {
                    if hasStandardControls { slots.trackControlSelectionExclusion() }
                    else { Color.clear }
                }.environment(\.openFX, openFX).environment(\.locale, locale).environment(\.colorScheme, colorScheme)),
                footer: { AnyView(fixedFooter(controlsHeight: $0)
                    .environment(\.openFX, openFX).environment(\.editTrackDetails, editTrackDetails)
                    .environment(\.locale, locale).environment(\.colorScheme, colorScheme)) })
            #else
            GeometryReader { geometry in
                let layout = FooterMixerStripLayout(height: geometry.size.height, slotsOnly: slotsOnly, iconHeight: showsInstrumentIcons ? 30 : 0)
                VStack(spacing: 0) {
                    if hasStandardControls {
                        slots.frame(height: layout.slotsHeight).clipped().opacity(layout.slotsHeight > 0 ? 1 : 0).allowsHitTesting(layout.slotsHeight > 0)
                            .trackControlSelectionExclusion()
                    } else { Color.clear.frame(height: layout.slotsHeight) }
                    fixedFooter(controlsHeight: layout.controlsHeight)
                }.padding(4)
            }
            #endif
        }.frame(width: track == nil ? FooterMixerMetrics.masterWidth : FooterMixerMetrics.width).frame(maxHeight: .infinity)
            .background(color.opacity(selected ? 0.38 : 0.24)).overlay(alignment: .top) { color.frame(height: 3) }
            .overlay { if selected { Rectangle().stroke(Color.white.opacity(0.65), lineWidth: 1).allowsHitTesting(false) } }
            #if os(macOS)
            .overlay {
                if let track {
                    TrackRightClickInput(project: show.snapshot.project.id, track: track.id, kind: track.kind, dragName: track.name, selected: selected, select: select,
                        patch: { patchPresented = true }, fx: { fxPresented = true }, edit: edit, icon: editIcon,
                        group: canGroup ? { show.createTrackGroup(track.id) } : nil,
                        ungroup: isFolder ? { show.ungroupTrack(track.id) } : nil, removeFromGroup: track.parentTrackID != nil ? { show.removeTrackFromGroup(track.id) } : nil,
                        link: canLink ? link : nil, unlink: track.stereoLink != nil ? { show.unlinkTracks(track.id) } : nil,
                        duplicateTracks: duplicateSelection, deleteTracks: { requestDeletion(deleteIDs, project: deleteProject) }, deleteTrackCount: deleteIDs.count)
                }
            }
            #else
            .onTapGesture(perform: select)
            #endif
            .modifier(FooterTrackInsertion(show: show, track: id))
            .contextMenu {
                if track == nil {
                    MasterTrackContextMenu(show: show, patch: { patchPresented = true },
                        fx: { fxPresented = true }, edit: edit, masterRight: masterState?.masterRight == true,
                        moveMaster: { UserDefaults.standard.set(masterState?.masterRight != true, forKey: "catlive.barMixer.masterRight") })
                } else {
                    Button("Patch") { patchPresented = true }
                    if hasStandardControls { Button("FX") { fxPresented = true } }
                    Button("Editar pista", action: edit)
                    Button("Ícone da pista", action: editIcon)
                    if let duplicateSelection {
                        Button(LocalizedStringKey(deleteIDs.count > 1 ? "Duplicate tracks" : "Duplicate track"), action: duplicateSelection)
                    }
                    if canGroup, let id { Button("Create group") { show.createTrackGroup(id) } }
                    if let id, isFolder { Button("Ungroup") { show.ungroupTrack(id) } }
                    if let track, track.parentTrackID != nil { Button("Remove from group") { show.removeTrackFromGroup(track.id) } }
                    if canLink { Button("Link tracks", action: link) }
                    if let track, track.stereoLink != nil { Button("Unlink tracks") { show.unlinkTracks(track.id) } }
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
            .workspaceEditor("Patch", isPresented: $patchPresented, scrolls: false) {
                VStack { PatchEditor(show: show, track: id, targets: targets); Button("Close") { patchPresented = false }.keyboardShortcut(.cancelAction) }.padding(12)
            }
            .workspaceEditor("FX", isPresented: $fxPresented) {
                FXInsertEditor(show: show, track: id, targets: targets) { fxPresented = false }
            }
            .workspaceEditor("Editar pista", isPresented: $colorPresented) {
                NameColorEditor(title: "Editar pista", initialName: "Master", initialColor: show.snapshot.project.masterColor ?? 0x414141,
                    save: { _, color in show.editMasterColor(color) }, nameEditable: false, showsName: false)
            }
    }
}

private struct FooterEffectTransfer: Codable {
    static let type = UTType(exportedAs: "com.catlive.mixer-effect", conformingTo: .data)
    let project: UUID
    let source: UUID?
    let effect: String
    var provider: NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil); return nil
        }
        return provider
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
                content().frame(width: viewport.size.width).background(GeometryReader { geometry in
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
    var body: some View {
        Group {
            if let effect {
                Button { openFX(track, effect) } label: {
                    Text(verbatim: title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                    .foregroundStyle(settings.isEnabled(effect) ? Color(hex: 0x00ff00) : Color(hex: 0xff0000))
                    #if !os(macOS)
                    .onDrag { FooterEffectTransfer(project: show.snapshot.project.id, source: track, effect: effect).provider }
                    .contextMenu {
                        Button("By") { show.toggleFXBypass(track, effect: effect) }
                        Button("Remove") { show.removeFX(track, effect: effect) }
                    }
                    #endif
            } else {
                Button { openFX(track, "Chain") } label: {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("FX Manager")
            }
        }.font(.jarasSystem(size: 10, weight: .medium)).padding(.horizontal, 5).frame(height: 19)
            .background(Color.black.opacity(0.28))
            #if !os(macOS)
            .overlay { if targeted || hovered { (targeted ? JarasTheme.green.opacity(0.3) : Color.white.opacity(0.09)).allowsHitTesting(false) } }
            .onHover { hovered = $0 }
            #endif
            .contentShape(Rectangle())
            .jarasHelp(effect == nil ? "Click to open FX Manager" : "Click: open this plugin in FX Manager. Option/Alt + click: remove plugin. Shift + click: toggle bypass (red slot).")
            #if os(macOS)
            .overlay(FooterEffectContext(bypass: { if let effect { show.toggleFXBypass(track, effect: effect) } },
                remove: { if let effect { show.removeFX(track, effect: effect) } },
                open: { openFX(track, effect ?? "Chain") },
                transfer: effect.map { FooterEffectTransfer(project: show.snapshot.project.id, source: track, effect: $0) },
                title: title, project: show.snapshot.project.id, dragEnabled: track != nil, drop: { transfer in
                    guard track != nil, transfer.project == show.snapshot.project.id else { return false }
                    show.copyFX(from: transfer.source, effect: transfer.effect, to: track, before: effect)
                    return true
                }))
            #else
            .onDrop(of: [FooterEffectTransfer.type], delegate: FooterEffectDrop(show: show, track: track,
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
    func validateDrop(info: DropInfo) -> Bool { !TrackReorderState.shared.active && info.hasItemsConforming(to: [FooterEffectTransfer.type]) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard !TrackReorderState.shared.active, let provider = info.itemProviders(for: [FooterEffectTransfer.type]).first else { return false }
        let project = show.snapshot.project.id, session = show.projectSessionID
        _ = provider.loadDataRepresentation(forTypeIdentifier: FooterEffectTransfer.type.identifier) { data, _ in
            guard let data, let transfer = try? JSONDecoder().decode(FooterEffectTransfer.self, from: data), transfer.project == project else { return }
            Task { @MainActor in
                guard show.snapshot.project.id == project, show.projectSessionID == session else { return }
                show.copyFX(from: transfer.source, effect: transfer.effect, to: track, before: effect)
            }
        }
        return true
    }
}


private struct FooterMixerControl: View {
    let show: ShowController
    let track: UUID?
    let value: Double
    let pan: Bool
    let linked: UUID?
    private var position: Double { pan ? value : (value <= 0 ? -60 : min(12, max(-60, 20 * log10(value)))) }
    private func gain(_ value: Double) -> Double { value <= -60 ? 0 : pow(10, value / 20) }
    var body: some View {
        #if os(macOS)
        let identity = TrackControlIdentity(project: show.snapshot.project.id, track: track)
        DirectVolumeSlider(show: show, groupValues: { show.mixerPreviewValues }, identity: identity, value: position, minimum: pan ? -1 : -60, maximum: pan ? 1 : 12,
            mini: pan, vertical: !pan, rotary: pan, linkedTrack: linked,
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
        GeometryReader { geometry in
            let fraction = (position - (pan ? -1 : -60)) / (pan ? 2 : 72)
            ZStack {
                Capsule().fill(.white.opacity(0.2)).frame(width: 5)
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 24, height: 10)
                    .position(x: geometry.size.width / 2, y: (1 - fraction) * max(1, geometry.size.height - 10) + 5)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    let fraction = min(1, max(0, 1 - event.location.y / max(1, geometry.size.height)))
                    let next = (pan ? -1.0 : -60.0) + fraction * (pan ? 2 : 72)
                    show.sendMixerControl(pan ? .pan : .volume, target: track, value: pan ? next : gain(next))
                })
                .onTapGesture(count: 2) { show.sendMixerControl(pan ? .pan : .volume, target: track, value: pan ? 0 : 1) }
        }
        #endif
    }
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
    let drop: (FooterEffectTransfer) -> Bool
    func makeNSView(context: Context) -> FooterEffectContextView { FooterEffectContextView() }
    func updateNSView(_ view: FooterEffectContextView, context: Context) {
        view.bypass = bypass; view.remove = remove; view.open = open; view.transfer = transfer; view.title = title; view.project = project; view.drop = drop; view.dragEnabled = dragEnabled
        view.optionClick = remove; view.shiftClick = bypass; view.action = { [weak view] in view?.openMenu() }
    }
}
private final class FooterEffectContextView: RightClickTargetView, NSDraggingSource {
    override var priority: Int { 2 }
    var bypass: (() -> Void)?
    var remove: (() -> Void)?
    var open: (() -> Void)?
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
        registerForDraggedTypes([NSPasteboard.PasteboardType(FooterEffectTransfer.type.identifier)])
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
        if receiving { NSColor.systemGreen.withAlphaComponent(0.3).setFill();bounds.fill() }
        else if hover { NSColor.white.withAlphaComponent(0.09).setFill();bounds.fill() }
    }
    private func payload(_ sender: NSDraggingInfo) -> FooterEffectTransfer? {
        guard dragEnabled, !interactionBlocked, !TrackReorderState.shared.active,
              let data=sender.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(FooterEffectTransfer.type.identifier)),
              let value=try? JSONDecoder().decode(FooterEffectTransfer.self,from:data), value.project==project else { return nil }
        return value
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
    override func mouseDown(with event: NSEvent) { pressed = event; dragging = false }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; dragging = false }
        guard pressed != nil, !dragging else { return }
        if event.modifierFlags.contains(.option) { remove?() }
        else if event.modifierFlags.contains(.shift) { bypass?() }
        else { open?() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragEnabled, let pressed, !dragging, let transfer,
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
        guard transfer != nil, let event = NSApp.currentEvent else { return }
        if event.modifierFlags.contains(.option) { remove?(); return }
        let menu = NSMenu()
        let actions = [TrackMenuAction { [weak self] in self?.bypass?() }, TrackMenuAction { [weak self] in self?.remove?() }]
        for (index, title) in ["By", JarasLocalization.string("Remove")].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(TrackMenuAction.invoke), keyEquivalent: "")
            item.target = actions[index]; menu.addItem(item)
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
        UserDefaults.standard.set(detached, forKey: "jaras.layout.mixer.detached")
        UserDefaults.standard.set(visible, forKey: "jaras.layout.mixer.visible")
    }
    private(set) var window: NSWindow?
    func open(show: ShowController, openFX: @escaping (UUID?, String) -> Void, editTrack: @escaping (TrackDetailsEditRequest) -> Void) {
        remember(detached: true, visible: true)
        if let window { if window.isMiniaturized { window.deminiaturize(nil) }; window.makeKeyAndOrderFront(nil); isVisible = true; return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 370),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "CatLive · Hoz-Mixer"
        panel.contentMinSize = NSSize(width: 360, height: 273)
        panel.isReleasedWhenClosed = false; panel.delegate = self
        let host = NSHostingView(rootView: DetachedMixerContent(show: show, owner: self, openFX: openFX, editTrack: editTrack).interfaceScaled())
        if #available(macOS 13, *) { host.sizingOptions = [] }
        panel.contentView = host
        InterfaceScaling.shared.register(panel)
        if !panel.setFrameUsingName("CatLiveDetachedMixer", force: true) { panel.center() }
        panel.setFrameAutosaveName("CatLiveDetachedMixer")
        window = panel; isDetached = true; isVisible = true
        panel.makeKeyAndOrderFront(nil)
    }
    private func savePlacement() { window?.saveFrame(usingName: "CatLiveDetachedMixer") }
    func windowDidMove(_ notification: Notification) { savePlacement() }
    func windowDidResize(_ notification: Notification) { savePlacement() }
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
    @ObservedObject var show: ShowController
    let targets: [UUID]
    @ObservedObject private var audio = AudioDeviceSettings.shared
    @State private var category = 0
    @State private var input = OutputPatch.stereo
    @State private var output = OutputPatch.master
    @State private var midi = 0
    @State private var applied = false
    private var tracks: [Track] { show.snapshot.project.songs.flatMap(\.tracks).filter { targets.contains($0.id) } }
    private var outputOnly: Bool { tracks.contains { $0.role.rawValue == "vinhetas" } }
    private var inputs: [OutputPatch] {
        OutputPatch.choices(channels: TrackRecording.shared.inputChannels, includeMaster: false)
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
            } else {
                Picker("Output", selection: $output) { ForEach(outputs, id: \.self) { Text($0.title).tag($0) } }
            }
            Button("Apply to selected tracks") {
                for track in tracks {
                    switch outputOnly ? 2 : category {
                    case 0: show.setRecordingInput(track.id, input: input)
                    case 1: show.setMIDIInput(track.id, slot: midi)
                    default: show.setOutputPatches(track: track.id, patches: [output])
                    }
                }
                applied = true
            }.buttonStyle(.borderedProminent).tint(JarasTheme.green)
                .disabled(tracks.isEmpty || (category == 0 && !inputs.contains(input)) || (category != 2 && (TrackRecording.shared.recording || tracks.contains { $0.kind != .standard })) || (category == 2 && !outputs.contains(output)))
            if applied { Label("Applied", systemImage: "checkmark.circle.fill").foregroundStyle(JarasTheme.green) }
        }.padding(18).frame(minWidth: 320, maxWidth: 480)
            .onAppear { if outputOnly { category = 2 } }
            .onChange(of: category) { _ in applied = false }
            .onChange(of: input) { _ in applied = false }
            .onChange(of: output) { _ in applied = false }
            .onChange(of: midi) { _ in applied = false }
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
            if let window = event.window {
                NotificationCenter.default.post(name: Notification.Name("catlive.workspacePointerDown"), object: window)
            }
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
              !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
              let area = activeArea(in: window), area.window === window, !area.isHiddenOrHasHiddenAncestor else { return false }
        if event.isARepeat { return true }
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

struct ProgramChangeTrackRow: View {
    @ObservedObject var show: ShowController
    let track: Track
    var deleteTrack: (() -> Void)?
    @ObservedObject private var mappings = ControlMappings.shared
    @State private var patch = false
    @State private var naming = false
    @State private var pending: (program: Int, channel: Int, position: Double, project: UUID, output: Int?)?
    private var scanning: Bool { mappings.programChangeScanTrack == track.id }
    private var copyReady: Bool { show.programChangePasteReady || show.selectedProgramChange != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Spacer(minLength: 0)
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
            }
            HStack(spacing: 6) {
                Text("Program Change").font(.jarasSystem(size: 11, weight: .semibold))
                Spacer(minLength: 6)
                if scanning, let last = mappings.scannedProgramChange {
                    Text(verbatim: "PC \(last.program + 1) · CH \(last.channel)").font(.jarasSystem(size: 10))
                }
            }.lineLimit(1)
        }.padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(.white).background(Color(hex: track.kind.defaultColor ?? 0x91a8ff).opacity(track.mute ? 0.15 : 0.45))
            .overlay(alignment: .bottom) { JarasTheme.line.frame(height: 1) }
            .clipped()
            .contextMenu {
                Button("Patch") { patch = true }
                if scanning { Button("Cancel") { mappings.cancelProgramChangeScan() } }
                if let deleteTrack { Button("Delete track", role: .destructive, action: deleteTrack) }
            }
            #if os(macOS)
            .workspaceEditor("Patch", isPresented: $patch, scrolls: false) { patchEditor }
            .workspaceEditor("Program Change", isPresented: $naming) { nameEditor }
            #else
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
private struct ProgramChangeHeadInput: NSViewRepresentable {
    let select: () -> Void
    let copy: () -> Void
    let paste: (() -> Void)?
    let remove: () -> Void
    func makeNSView(context: Context) -> ProgramChangeHeadInputView { ProgramChangeHeadInputView() }
    func updateNSView(_ view: ProgramChangeHeadInputView, context: Context) {
        view.select = select; view.copyMarker = copy; view.pasteMarker = paste; view.remove = remove
    }
}
final class ProgramChangeHeadInputView: NSView, TimelineGridKeyboardTarget {
    var select: () -> Void = {}
    var copyMarker: () -> Void = {}
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
        for (tag,key) in [(1,"Copy"),(2,"Paste"),(3,"Delete")] {
            let item = NSMenuItem(title: JarasLocalization.string(key), action: #selector(runMenu(_:)), keyEquivalent: "")
            item.target = self; item.tag = tag; item.isEnabled = tag != 2 || pasteMarker != nil; menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }
    @objc private func runMenu(_ item: NSMenuItem) {
        if item.tag == 1 { copyMarker() } else if item.tag == 2 { pasteMarker?() } else { remove() }
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
