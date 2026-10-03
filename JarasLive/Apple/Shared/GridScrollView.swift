import SwiftUI
import Combine

/// Transient sidebar widths update only their layout scope. Publishing each
/// drag through MainView or the timeline editor also invalidated unrelated
/// transport controls, modal hosts and native input callbacks.
final class SidebarResizeState: ObservableObject {
    @Published private(set) var width: CGFloat?
    private var includesWidthReserve = false
    var limitsWidthToVisibleRows: Bool { width != nil && !includesWidthReserve }
    func update(_ width: CGFloat?) {
        guard self.width != width else { return }
        if self.width == nil || width == nil { includesWidthReserve = false }
        self.width = width
    }
    /// A vertical gesture during resize restores the usual warm widths once.
    /// Ordinary scrolling never publishes this sidebar state.
    @discardableResult func includeWidthReserve() -> Bool {
        guard limitsWidthToVisibleRows else { return false }
        objectWillChange.send()
        includesWidthReserve = true
        return true
    }
}
struct SidebarResizeLayer<Content: View>: View {
    @ObservedObject var state: SidebarResizeState
    @ViewBuilder let content: (CGFloat?) -> Content
    var body: some View { content(state.width) }
}

/// The grid owns these scroll views. SwiftUI cannot recreate scrollers or reserve gutters.
struct GridScrollView<Content: View>: View {
    let axis: Axis.Set
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    var fileDrop: (([URL], CGPoint) -> Bool)? = nil
    var fileDropPreview: ((CGPoint?) -> Void)? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        #if os(macOS)
        NativeGridScroll(horizontal: axis == .horizontal, contentWidth: contentWidth, contentHeight: contentHeight, fileDrop: fileDrop, fileDropPreview: fileDropPreview, content: content())
        #else
        ScrollView(axis, showsIndicators: false, content: content)
        #endif
    }
}
#if os(macOS)
import AppKit

/// Opt-in measurements of native layout boundaries. The disabled path creates
/// no timers, clocks or files; each host only checks its nil profile reference.
/// Layout duration is inclusive, so nested hosts must not be summed together.
enum TimelineLayoutDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["CATLIVE_PROFILE_LAYOUT"] == "1"
    static let logPath = "/tmp/catlive-layout-\(ProcessInfo.processInfo.processIdentifier).jsonl"
    private static let session = Session()

    static func make(_ role: String) -> Profile? {
        enabled ? Profile(role: role, session: session) : nil
    }
    static func flush() { if enabled { session.flush(wait: true) } }

    struct Record: Encodable {
        var event: String
        var host: Int
        var role: String
        var window: Int
        var timeMS: Double
        var frame: Int
        var frameSource: String
        var bucket60Hz: Int
        var width: Double
        var height: Double
        var durationMS: Double? = nil
        var inputTimestampMS: Double? = nil
        var deltaX: Double? = nil
        var deltaY: Double? = nil
        var modifiers: UInt? = nil
        var value: Double? = nil
        var layoutInFrame: Int? = nil
        var rootAssignments: Int
        var sizeChanges: Int
    }
    final class Profile {
        let role: String
        let id: Int
        private let session: Session
        private var roots = 0
        private var sizes = 0
        private var lastFrame: (Int, Int)?
        private var layoutsInFrame = 0
        fileprivate init(role: String, session: Session) {
            self.role = role; self.session = session
            id = session.nextID; session.nextID += 1
        }
        struct LayoutStart {
            fileprivate let time: Double
            fileprivate let record: Record
        }
        func beginLayout(_ view: NSView) -> LayoutStart {
            var record = makeRecord("layout", view)
            let key = (record.window, record.frame)
            if let lastFrame, lastFrame == key { layoutsInFrame += 1 }
            else { lastFrame = key; layoutsInFrame = 1 }
            record.layoutInFrame = layoutsInFrame
            return LayoutStart(time: ProcessInfo.processInfo.systemUptime, record: record)
        }
        func endLayout(_ start: LayoutStart) {
            var record = start.record
            record.durationMS = (ProcessInfo.processInfo.systemUptime - start.time) * 1000
            session.append(record)
        }
        func rootAssigned(_ view: NSView) {
            roots += 1
            session.append(makeRecord("root", view))
        }
        func sizeChanged(_ view: NSView, from old: NSSize, to new: NSSize) {
            guard old != new else { return }
            sizes += 1
            var record = makeRecord("size", view)
            record.width = Double(new.width); record.height = Double(new.height)
            session.append(record)
        }
        func event(_ name: String, view: NSView?, input: NSEvent? = nil, value: Double? = nil) {
            var record = makeRecord(name, view)
            if let input {
                record.inputTimestampMS = input.timestamp * 1000
                record.deltaX = Double(input.scrollingDeltaX); record.deltaY = Double(input.scrollingDeltaY)
                record.modifiers = input.modifierFlags.rawValue
            }
            record.value = value
            session.append(record)
        }
        private func makeRecord(_ event: String, _ view: NSView?) -> Record {
            let time = ProcessInfo.processInfo.systemUptime - session.start
            let clock = view.flatMap { session.clock(for: $0) }
            // A 60 Hz time bucket remains comparable across windows. The frame
            // field uses an actual display-link callback on macOS 14 and newer.
            return Record(event: event, host: id, role: role,
                          window: view?.window?.windowNumber ?? -1, timeMS: time * 1000,
                          frame: clock?.frame ?? Int(time * 60),
                          frameSource: clock?.source ?? "unattached-time60Hz",
                          bucket60Hz: Int(time * 60), width: Double(view?.frame.width ?? 0),
                          height: Double(view?.frame.height ?? 0), rootAssignments: roots,
                          sizeChanges: sizes)
        }
    }
    fileprivate final class FrameClock: NSObject {
        weak var window: NSWindow?
        var frame = 0
        var source = "timer60Hz"
        var cancel: (() -> Void)?
        init(view: NSView) {
            window = view.window
            super.init()
            if #available(macOS 14, *) {
                source = "displayLink"
                let link = (view.window?.contentView ?? view).displayLink(target: self, selector: #selector(tick))
                link.add(to: .main, forMode: .common)
                cancel = { link.invalidate() }
            } else {
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(timer, forMode: .common)
                cancel = { timer.invalidate() }
            }
        }
        @objc private func tick() {
            guard window != nil else { cancel?(); cancel = nil; return }
            frame += 1
        }
    }
    fileprivate final class Session {
        let start = ProcessInfo.processInfo.systemUptime
        var nextID = 1
        private var clocks: [Int: FrameClock] = [:]
        private var records: [Record] = []
        private var flushTimer: Timer?
        private let writer = DispatchQueue(label: "catlive.layout-diagnostics", qos: .utility)
        private var file: FileHandle?
        init() {
            flushTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.flush(wait: false) }
            RunLoop.main.add(flushTimer!, forMode: .common)
        }
        func clock(for view: NSView) -> FrameClock? {
            guard let window = view.window else { return nil }
            let key = window.windowNumber
            if let clock = clocks[key], clock.window === window { return clock }
            let clock = FrameClock(view: view)
            clocks[key] = clock
            return clock
        }
        func append(_ record: Record) { records.append(record) }
        func flush(wait: Bool) {
            let batch = records
            records.removeAll(keepingCapacity: true)
            if !batch.isEmpty {
                writer.async { [self] in
                    if file == nil {
                        _ = FileManager.default.createFile(atPath: logPath, contents: nil,
                                                       attributes: [.posixPermissions: 0o600])
                        file = FileHandle(forWritingAtPath: logPath)
                    }
                    guard let file else { return }
                    let encoder = JSONEncoder()
                    var data = Data()
                    for record in batch {
                        if let line = try? encoder.encode(record) { data.append(line); data.append(10) }
                    }
                    try? file.write(contentsOf: data)
                }
            }
            if wait { writer.sync {} }
        }
    }
}

protocol SidebarResizeLayoutBoundary: AnyObject {
    func commitSidebarResizeLayout()
}

private final class WorkspaceHostingView<Content: View>: NSHostingView<Content>, SidebarResizeLayoutBoundary {
    var layoutProfile: TimelineLayoutDiagnostics.Profile?
    override func layout() {
        guard let profile = layoutProfile else { super.layout(); return }
        let start = profile.beginLayout(self)
        super.layout()
        profile.endLayout(start)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    func commitSidebarResizeLayout() { layoutSubtreeIfNeeded() }
}

private struct WorkspaceHostingIdentity: Hashable {
    let content: AnyHashable
    let locale: String
    let colorScheme: ColorScheme
    let interactionBlocked: Bool
}

/// The workspace divider changes native sibling frames without publishing a
/// new MainView layout for every pointer event. Both hosting roots stay alive.
struct NativeWorkspaceSplit<Leading: View, Trailing: View>: NSViewRepresentable {
    let width: CGFloat
    let restoreWidth: CGFloat
    let minimum: CGFloat
    let scrollController: SidebarScrollController
    var contentIdentity: AnyHashable? = nil
    let onToggle: () -> Void
    let onEnd: (CGFloat) -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.openFX) private var openFX
    @Environment(\.openClipFXChain) private var openClipFXChain
    @Environment(\.editTextItem) private var editTextItem
    @Environment(\.editTrackDetails) private var editTrackDetails
    @Environment(\.gridInteractionBlocked) private var gridInteractionBlocked
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    private func hosted<Content: View>(_ content: Content, actions: GridHostedActions) -> GridHostedContent<Content> {
        GridHostedContent(content: content, gridInteractionBlocked: gridInteractionBlocked,
                          locale: locale, colorScheme: colorScheme, openFX: actions.openFX,
                          openClipFXChain: actions.openClipFX, editTextItem: actions.editText,
                          editTrackDetails: actions.editTrack)
    }
    private func updateActions(_ actions: GridHostedActions) {
        actions.fx = openFX; actions.clipFX = openClipFXChain
        actions.text = editTextItem; actions.trackDetails = editTrackDetails
    }
    func makeNSView(context: Context) -> NSView {
        let actions = GridHostedActions()
        updateActions(actions)
        let view = WorkspaceSplitView(actions: actions, leading: hosted(leading(), actions: actions),
                                      trailing: hosted(trailing(), actions: actions))
        view.configure(width: width, restoreWidth: restoreWidth, minimum: minimum,
                       scrollController: scrollController, onToggle: onToggle, onEnd: onEnd)
        return view
    }
    func updateNSView(_ native: NSView, context: Context) {
        guard let view = native as? WorkspaceSplitView<Leading, Trailing> else { return }
        updateActions(view.actions)
        let identity = contentIdentity.map { AnyHashable(WorkspaceHostingIdentity(content: $0,
            locale: locale.identifier, colorScheme: colorScheme, interactionBlocked: gridInteractionBlocked)) }
        view.updateContent(leading: hosted(leading(), actions: view.actions),
                           trailing: hosted(trailing(), actions: view.actions), identity: identity)
        view.configure(width: width, restoreWidth: restoreWidth, minimum: minimum,
                       scrollController: scrollController, onToggle: onToggle, onEnd: onEnd)
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? nsView.frame.height)
    }
}

private final class WorkspaceSplitView<Leading: View, Trailing: View>: NSView {
    let actions: GridHostedActions
    private let leading: WorkspaceHostingView<GridHostedContent<Leading>>
    private let trailing: WorkspaceHostingView<GridHostedContent<Trailing>>
    private let divider = MixerDividerView()
    private var savedWidth: CGFloat = 0
    private var restoreWidth: CGFloat = 277
    private var minimum: CGFloat = 277
    private var liveWidth: CGFloat?
    private var pendingSavedWidth: CGFloat?
    private var resizing = false
    private var applyingFrames = false
    private var onEnd: (CGFloat) -> Void = { _ in }
    private let dividerWidth: CGFloat = 14

    init(actions: GridHostedActions, leading: GridHostedContent<Leading>, trailing: GridHostedContent<Trailing>) {
        self.actions = actions
        self.leading = WorkspaceHostingView(rootView: leading)
        self.trailing = WorkspaceHostingView(rootView: trailing)
        super.init(frame: .zero)
        wantsLayer = true
        autoresizesSubviews = false
        if #available(macOS 13, *) { self.leading.sizingOptions = []; self.trailing.sizingOptions = [] }
        // The outer window has already resolved the workspace content rect.
        if #available(macOS 13.3, *) { self.leading.safeAreaRegions = []; self.trailing.safeAreaRegions = [] }
        self.leading.layoutProfile = TimelineLayoutDiagnostics.make("workspace-timeline")
        self.trailing.layoutProfile = TimelineLayoutDiagnostics.make("workspace-setlist")
        self.leading.layoutProfile?.rootAssigned(self.leading)
        self.trailing.layoutProfile?.rootAssigned(self.trailing)
        self.leading.identifier = NSUserInterfaceItemIdentifier("workspace-timeline")
        self.trailing.identifier = NSUserInterfaceItemIdentifier("workspace-setlist")
        addSubview(self.leading); addSubview(divider); addSubview(self.trailing)
        divider.direction = -1
        divider.setAccessibilityElement(true)
        divider.setAccessibilityRole(.splitter)
        divider.setAccessibilityLabel("Resize setlist")
        divider.onStart = { [weak self] in self?.resizing = true }
        divider.onResize = { [weak self] width in
            guard let self else { return }
            self.liveWidth = width
            self.applyFrames(layoutHosts: false)
        }
        divider.onEnd = { [weak self] width in
            guard let self else { return }
            self.resizing = false
            self.pendingSavedWidth = width
            self.liveWidth = nil
            self.onEnd(width)
        }
        divider.resizeLayout = { [weak self] in self?.applyFrames(layoutHosts: true) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }

    private var mountedContentIdentity: AnyHashable?
    func updateContent(leading: GridHostedContent<Leading>, trailing: GridHostedContent<Trailing>, identity: AnyHashable? = nil) {
        // ObservedObject descendants receive mixer/transport updates themselves.
        // Replacing both roots on every parent publication forces AppKit to
        // traverse the entire window layout before handling the next gesture.
        if let identity, mountedContentIdentity == identity { return }
        mountedContentIdentity = identity
        self.leading.layoutProfile?.rootAssigned(self.leading)
        self.trailing.layoutProfile?.rootAssigned(self.trailing)
        self.leading.rootView = leading; self.trailing.rootView = trailing
    }
    func configure(width: CGFloat, restoreWidth: CGFloat, minimum: CGFloat,
                   scrollController: SidebarScrollController, onToggle: @escaping () -> Void,
                   onEnd: @escaping (CGFloat) -> Void) {
        // An unrelated parent update during tracking still carries the last
        // saved width. Only acknowledge the final value or a newer external edit.
        if let pendingSavedWidth, width == pendingSavedWidth || width != savedWidth { self.pendingSavedWidth = nil }
        savedWidth = width; self.restoreWidth = restoreWidth; self.minimum = minimum
        self.onEnd = onEnd
        divider.scrollController = scrollController; divider.onToggle = onToggle
        applyFrames(layoutHosts: false)
    }
    override func layout() {
        super.layout()
        applyFrames(layoutHosts: true)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { resizing = false; liveWidth = nil; pendingSavedWidth = nil }
    }
    private func applyFrames(layoutHosts: Bool) {
        guard !applyingFrames else { return }
        applyingFrames = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit(); applyingFrames = false }
        let available = bounds.size
        let maximum = max(0, min(486.5, available.width - 420))
        func bounded(_ width: CGFloat) -> CGFloat { width <= 0 ? 0 : min(maximum, max(minimum, width)) }
        let visibleWidth = bounded((resizing ? liveWidth : nil) ?? pendingSavedWidth ?? savedWidth)
        let leftWidth = max(0, available.width - visibleWidth - dividerWidth)
        let mountedWidth = visibleWidth > 0 ? visibleWidth : bounded(max(minimum, restoreWidth))
        divider.minimum = minimum; divider.maximum = maximum; divider.columnWidth = visibleWidth
        let leftFrame = CGRect(x: 0, y: 0, width: leftWidth, height: available.height)
        let barFrame = CGRect(x: leftWidth, y: 0, width: dividerWidth, height: available.height)
        let rightFrame = CGRect(x: leftWidth + dividerWidth, y: 0, width: mountedWidth, height: available.height)
        if leading.frame != leftFrame {
            leading.layoutProfile?.sizeChanged(leading, from: leading.frame.size, to: leftFrame.size)
            leading.frame = leftFrame
        }
        if divider.frame != barFrame { divider.frame = barFrame }
        if trailing.frame != rightFrame {
            trailing.layoutProfile?.sizeChanged(trailing, from: trailing.frame.size, to: rightFrame.size)
            trailing.frame = rightFrame
        }
        trailing.isHidden = visibleWidth <= 0
        if layoutHosts {
            leading.layoutSubtreeIfNeeded()
            if !trailing.isHidden { trailing.layoutSubtreeIfNeeded() }
        }
    }
}

/// Keep mixer controls and the zoomable timeline in separate SwiftUI graphs.
/// Both hosts remain children of the existing vertical scroll document.
struct NativeTimelineColumns<Mixer: View, Divider: View, Timeline: View, Identity: Equatable>: NSViewRepresentable {
    let mixerWidth: CGFloat
    let viewportWidth: CGFloat
    let height: CGFloat
    let dividerWidth: CGFloat
    let project: UUID
    let mixerIdentity: Identity
    @ViewBuilder let mixer: () -> Mixer
    @ViewBuilder let divider: () -> Divider
    @ViewBuilder let timeline: () -> Timeline
    @Environment(\.openFX) private var openFX
    @Environment(\.openClipFXChain) private var openClipFXChain
    @Environment(\.editTextItem) private var editTextItem
    @Environment(\.editTrackDetails) private var editTrackDetails
    @Environment(\.gridInteractionBlocked) private var gridInteractionBlocked
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    private func hosted<Content: View>(_ content: Content, actions: GridHostedActions) -> GridHostedContent<Content> {
        GridHostedContent(content: content, gridInteractionBlocked: gridInteractionBlocked,
            locale: locale, colorScheme: colorScheme, openFX: actions.openFX,
            openClipFXChain: actions.openClipFX, editTextItem: actions.editText,
            editTrackDetails: actions.editTrack)
    }
    private func updateActions(_ actions: GridHostedActions) {
        actions.fx = openFX; actions.clipFX = openClipFXChain
        actions.text = editTextItem; actions.trackDetails = editTrackDetails
    }
    private var identity: TimelineColumnsMixerIdentity<Identity> {
        TimelineColumnsMixerIdentity(content: mixerIdentity, project: project,
            locale: locale.identifier, colorScheme: colorScheme,
            interactionBlocked: gridInteractionBlocked, visible: mixerWidth > 0)
    }
    func makeNSView(context: Context) -> NSView {
        let actions = GridHostedActions()
        updateActions(actions)
        let view = TimelineColumnsNativeView(actions: actions,
            mixer: hosted(mixer(), actions: actions), divider: hosted(divider(), actions: actions),
            timeline: hosted(timeline(), actions: actions), identity: identity)
        view.configure(mixerWidth: mixerWidth, viewportWidth: viewportWidth, height: height, dividerWidth: dividerWidth)
        return view
    }
    func updateNSView(_ native: NSView, context: Context) {
        guard let view = native as? TimelineColumnsNativeView<Mixer, Divider, Timeline, Identity> else { return }
        updateActions(view.actions)
        view.updateContent(mixer: hosted(mixer(), actions: view.actions),
            divider: hosted(divider(), actions: view.actions), timeline: hosted(timeline(), actions: view.actions),
            identity: identity)
        view.configure(mixerWidth: mixerWidth, viewportWidth: viewportWidth, height: height, dividerWidth: dividerWidth)
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: viewportWidth, height: height)
    }
}

private struct TimelineColumnsMixerIdentity<Content: Equatable>: Equatable {
    let content: Content
    let project: UUID
    let locale: String
    let colorScheme: ColorScheme
    let interactionBlocked: Bool
    let visible: Bool
}

private final class TimelineColumnsNativeView<Mixer: View, Divider: View, Timeline: View, Identity: Equatable>: NSView {
    let actions: GridHostedActions
    let mixerHost: WorkspaceHostingView<GridHostedContent<Mixer>>
    let dividerHost: WorkspaceHostingView<GridHostedContent<Divider>>
    let timelineHost: WorkspaceHostingView<GridHostedContent<Timeline>>
    private var mixerIdentity: TimelineColumnsMixerIdentity<Identity>
    private var mixerWidth: CGFloat = 0
    private var viewportWidth: CGFloat = 0
    private var documentHeight: CGFloat = 0
    private var dividerWidth: CGFloat = 0

    init(actions: GridHostedActions, mixer: GridHostedContent<Mixer>, divider: GridHostedContent<Divider>,
         timeline: GridHostedContent<Timeline>, identity: TimelineColumnsMixerIdentity<Identity>) {
        self.actions = actions; mixerIdentity = identity
        mixerHost = WorkspaceHostingView(rootView: mixer)
        dividerHost = WorkspaceHostingView(rootView: divider)
        timelineHost = WorkspaceHostingView(rootView: timeline)
        super.init(frame: .zero)
        wantsLayer = true; autoresizesSubviews = false
        for (host, role) in [(mixerHost as NSView, "columns-mixer"), (dividerHost as NSView, "columns-divider"), (timelineHost as NSView, "columns-timeline")] {
            host.identifier = NSUserInterfaceItemIdentifier(role)
            addSubview(host)
        }
        if #available(macOS 13, *) {
            mixerHost.sizingOptions = []; dividerHost.sizingOptions = []; timelineHost.sizingOptions = []
        }
        if #available(macOS 13.3, *) {
            mixerHost.safeAreaRegions = []; dividerHost.safeAreaRegions = []; timelineHost.safeAreaRegions = []
        }
        mixerHost.layoutProfile = TimelineLayoutDiagnostics.make("columns-mixer")
        dividerHost.layoutProfile = TimelineLayoutDiagnostics.make("columns-divider")
        timelineHost.layoutProfile = TimelineLayoutDiagnostics.make("columns-timeline")
        mixerHost.layoutProfile?.rootAssigned(mixerHost)
        dividerHost.layoutProfile?.rootAssigned(dividerHost)
        timelineHost.layoutProfile?.rootAssigned(timelineHost)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { CGSize(width: viewportWidth, height: documentHeight) }

    func updateContent(mixer: GridHostedContent<Mixer>, divider: GridHostedContent<Divider>,
                       timeline: GridHostedContent<Timeline>, identity: TimelineColumnsMixerIdentity<Identity>) {
        if mixerIdentity != identity {
            mixerIdentity = identity
            mixerHost.layoutProfile?.rootAssigned(mixerHost)
            mixerHost.rootView = mixer
        }
        dividerHost.layoutProfile?.rootAssigned(dividerHost)
        dividerHost.rootView = divider
        timelineHost.layoutProfile?.rootAssigned(timelineHost)
        timelineHost.rootView = timeline
    }
    func configure(mixerWidth: CGFloat, viewportWidth: CGFloat, height: CGFloat, dividerWidth: CGFloat) {
        self.mixerWidth = mixerWidth; self.viewportWidth = viewportWidth
        documentHeight = height; self.dividerWidth = dividerWidth
        applyFrames()
    }
    override func layout() {
        super.layout()
        applyFrames()
    }
    private func applyFrames() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        func update<Content: View>(_ host: WorkspaceHostingView<Content>, frame: CGRect) {
            guard host.frame != frame else { return }
            host.layoutProfile?.sizeChanged(host, from: host.frame.size, to: frame.size)
            host.frame = frame
        }
        update(mixerHost, frame: CGRect(x: 0, y: 0, width: max(0, mixerWidth), height: documentHeight))
        update(dividerHost, frame: CGRect(x: mixerWidth, y: 0, width: dividerWidth, height: documentHeight))
        update(timelineHost, frame: CGRect(x: mixerWidth + dividerWidth, y: 0,
            width: max(0, viewportWidth - mixerWidth - dividerWidth), height: documentHeight))
        mixerHost.isHidden = mixerWidth <= 0
        // Do not synchronously lay out both sibling hosts here. A zoom changes
        // only the timeline's descendants; AppKit processes that dirty subtree.
    }
}


private struct NativeGridScroll<Content: View>: NSViewRepresentable {
    final class Coordinator {
        let actions = GridHostedActions()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    let horizontal: Bool
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let fileDrop: (([URL], CGPoint) -> Bool)?
    let fileDropPreview: ((CGPoint?) -> Void)?
    let content: Content
    @Environment(\.openFX) private var openFX
    @Environment(\.openClipFXChain) private var openClipFXChain
    @Environment(\.editTextItem) private var editTextItem
    @Environment(\.editTrackDetails) private var editTrackDetails
    @Environment(\.gridInteractionBlocked) private var gridInteractionBlocked
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    private func hosted(_ coordinator: Coordinator) -> GridHostedContent<Content> {
        coordinator.actions.fx = openFX; coordinator.actions.clipFX = openClipFXChain; coordinator.actions.text = editTextItem
        coordinator.actions.trackDetails = editTrackDetails
        return GridHostedContent(content: content, gridInteractionBlocked: gridInteractionBlocked,
                                 locale: locale, colorScheme: colorScheme, openFX: coordinator.actions.openFX,
                                 openClipFXChain: coordinator.actions.openClipFX,
                                 editTextItem: coordinator.actions.editText,
                                 editTrackDetails: coordinator.actions.editTrack)
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GridNativeScrollView, context: Context) -> CGSize? {
        // The parent supplies the viewport. Asking AppKit to measure the entire
        // document during every zoom tick also remeasures all mixer controls.
        CGSize(width: proposal.width ?? contentWidth, height: proposal.height ?? contentHeight)
    }
    func makeNSView(context: Context) -> GridNativeScrollView {
        let scroll = GridNativeScrollView()
        scroll.wantsLayer = true
        scroll.contentView = TimelineClipView()
        if horizontal { scroll.registerForDraggedTypes([.fileURL]) }
        scroll.fileDrop = fileDrop
        scroll.fileDropPreview = fileDropPreview
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        // The timeline has an explicit document size; do not let hosting intrinsic
        // sizing temporarily collapse it while SwiftUI updates zoom or playback.
        let host = GridHostingView(rootView: hosted(context.coordinator))
        host.layoutProfile = TimelineLayoutDiagnostics.make(horizontal ? "horizontal" : "vertical")
        host.layoutProfile?.rootAssigned(host)
        host.layoutProfile?.sizeChanged(host, from: host.frame.size, to: NSSize(width: contentWidth, height: contentHeight))
        host.didLayout = { [weak scroll] in scroll?.applyZoomAnchor() }
        if #available(macOS 13, *) { host.sizingOptions = [] }
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        host.setFrameSize(NSSize(width: contentWidth, height: contentHeight))
        scroll.contentView.wantsLayer = true
        let document = GridDocumentView(frame: host.frame)
        document.wantsLayer = true
        document.autoresizesSubviews = false
        document.host = host; document.addSubview(host)
        scroll.documentView = document
        return scroll
    }
    func updateNSView(_ scroll: GridNativeScrollView, context: Context) {
        guard let document = scroll.documentView as? GridDocumentView, let host = document.host as? GridHostingView<GridHostedContent<Content>> else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        scroll.fileDrop = fileDrop
        scroll.fileDropPreview = fileDropPreview
        // Update the existing, typed hosting root directly so SwiftUI can diff
        // unchanged descendants. An ObservableObject relay invalidated the
        // entire hosted root again on every parent layout/resize transaction.
        host.layoutProfile?.rootAssigned(host)
        host.rootView = hosted(context.coordinator)
        let size = NSSize(width: contentWidth, height: contentHeight)
        if host.frame.size != size {
            host.layoutProfile?.sizeChanged(host, from: host.frame.size, to: size)
            document.setFrameSize(size)
            host.setFrameSize(size)
            host.needsLayout = true
            // SwiftUI invalidates the changed Canvas tiles. Forcing the whole
            // hosting document and clip to redraw discards their backing reuse.
        }
        // Commit the viewport after the hosting view has laid out this scale.
        // Scrolling here exposed old item geometry at the next scale's origin.
        if scroll.zoomAnchor != nil { host.needsLayout = true }
    }
}
/// Stable environment actions prevent a document-size change from invalidating
/// every menu/button that reads these actions. The handlers still stay current.
private final class GridHostedActions {
    var fx: (UUID?, String) -> Void = { _, _ in }
    var clipFX: (UUID) -> Void = { _ in }
    var text: (UUID) -> Void = { _ in }
    var trackDetails: (TrackDetailsEditRequest) -> Void = { _ in }
    lazy var openFX: (UUID?, String) -> Void = { [weak self] in self?.fx($0, $1) }
    lazy var openClipFX: (UUID) -> Void = { [weak self] in self?.clipFX($0) }
    lazy var editText: (UUID) -> Void = { [weak self] in self?.text($0) }
    lazy var editTrack: (TrackDetailsEditRequest) -> Void = { [weak self] in self?.trackDetails($0) }
}
private struct GridHostedContent<Content: View>: View {
    let content: Content
    let gridInteractionBlocked: Bool
    let locale: Locale
    let colorScheme: ColorScheme
    let openFX: (UUID?, String) -> Void
    let openClipFXChain: (UUID) -> Void
    let editTextItem: (UUID) -> Void
    let editTrackDetails: (TrackDetailsEditRequest) -> Void
    var body: some View {
        content.environment(\.openFX, openFX).environment(\.openClipFXChain, openClipFXChain)
            .environment(\.editTextItem, editTextItem)
            .environment(\.editTrackDetails, editTrackDetails)
            .environment(\.gridInteractionBlocked, gridInteractionBlocked)
            .environment(\.locale, locale).environment(\.colorScheme, colorScheme)
    }
}
/// Explicit document geometry terminates AppKit fitting-size propagation here.
/// Rescaling the timeline must not ask the track controls and meters for sizes.
private final class GridDocumentView: NSView {
    var host: NSView?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
}
private final class GridHostingView<Content: View>: NSHostingView<Content> {
    var didLayout: (() -> Void)?
    var layoutProfile: TimelineLayoutDiagnostics.Profile?
    override func layout() {
        guard let profile = layoutProfile else { super.layout(); didLayout?(); return }
        let start = profile.beginLayout(self)
        super.layout()
        didLayout?()
        profile.endLayout(start)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
}
final class GridNativeScrollView: NSScrollView {
    private let layoutProfile = TimelineLayoutDiagnostics.make("zoom-native")
    override func scrollWheel(with event: NSEvent) {
        layoutProfile?.event("scroll-input", view: self, input: event)
        super.scrollWheel(with: event)
    }
    /// The destination bucket must exist before AppKit reveals its pixels.
    /// Only the horizontal timeline installs this callback.
    var prepareHorizontalScroll: ((CGFloat) -> Bool)?
    private var preparingHorizontalScroll = false
    func prepareHorizontalViewport(at x: CGFloat) {
        guard !preparingHorizontalScroll, zoomAnchor == nil, let document = documentView,
              let prepareHorizontalScroll else { return }
        preparingHorizontalScroll = true
        defer { preparingHorizontalScroll = false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if prepareHorizontalScroll(x) { document.layoutSubtreeIfNeeded() }
    }
    var fileDrop: (([URL], CGPoint) -> Bool)?
    var fileDropPreview: ((CGPoint?) -> Void)?
    var fileDropModifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    private var lastFileDropPreview: CGPoint?
    private var lastFileDropModifierFlags: NSEvent.ModifierFlags = []
    private func updateFileDropPreview(_ point: CGPoint?) {
        // Shift changes magnetic snapping even when the dragged file has not moved.
        let modifiers: NSEvent.ModifierFlags = point == nil ? [] : fileDropModifierFlags()
        guard point != lastFileDropPreview || (point != nil && modifiers != lastFileDropModifierFlags) else { return }
        lastFileDropPreview = point
        lastFileDropModifierFlags = modifiers
        fileDropPreview?(point)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileDrop != nil, let documentView,
              sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            updateFileDropPreview(nil)
            return []
        }
        updateFileDropPreview(documentView.convert(sender.draggingLocation, from: nil))
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { updateFileDropPreview(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { updateFileDropPreview(nil) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { updateFileDropPreview(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { updateFileDropPreview(nil) }
        guard let documentView, let fileDrop,
              sender.draggingSourceOperationMask.contains(.copy),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        return fileDrop(urls, documentView.convert(sender.draggingLocation, from: nil))
    }

    var zoomAnchor: (fraction: Double, screenX: CGFloat, width: CGFloat)?
    func applyZoomAnchor() {
        guard let anchor = zoomAnchor, let document = documentView else { return }
        var origin = contentView.bounds.origin
        origin.x = min(max(0, CGFloat(anchor.fraction) * document.frame.width - anchor.screenX),
                       max(0, document.frame.width - contentView.bounds.width))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        // SwiftUI may commit an intermediate scale after a newer wheel event.
        // Center that actual frame too, retaining the target for the next layout.
        // Fractional zoom steps can be smaller than one point. A two-point
        // tolerance acknowledged the previous layout as the new one, leaving
        // the final cursor/waveform scale with its previous viewport origin.
        let tolerance = max(1e-7, abs(anchor.width).ulp * 8)
        if abs(document.frame.width - anchor.width) <= tolerance {
            layoutProfile?.event("geometry-commit", view: self, value: Double(document.frame.width))
            zoomAnchor = nil
        }
    }

    override var hasHorizontalScroller: Bool {
        get { false }
        set { super.hasHorizontalScroller = false }
    }
    override var hasVerticalScroller: Bool {
        get { false }
        set { super.hasVerticalScroller = false }
    }
    override func tile() {
        super.tile()
        // No border, scroller, or accessory area: the clip fills the entire viewport.
        if contentView.frame != bounds { contentView.frame = bounds }
    }
}
#endif

#if os(macOS)
/// Keep the document inside the viewport on both axes, including momentum scroll.
private final class TimelineClipView: NSClipView {
    private func boundedOrigin(_ origin: NSPoint) -> NSPoint {
        var result = origin
        let maximum = max(0, (documentView?.frame.width ?? 0) - bounds.width)
        result.x = min(maximum, max(0, origin.x))
        let maximumY = max(0, (documentView?.frame.height ?? 0) - bounds.height)
        result.y = min(maximumY, max(0, origin.y))
        return result
    }
    // Momentum scrolling can update bounds directly, bypassing the proposed
    // rectangle constraint. Enforce time zero on both AppKit entry points.
    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        let origin = boundedOrigin(newOrigin)
        if origin.x != bounds.minX { (superview as? GridNativeScrollView)?.prepareHorizontalViewport(at: origin.x) }
        super.setBoundsOrigin(origin)
    }
    override func scroll(to newOrigin: NSPoint) {
        let origin = boundedOrigin(newOrigin)
        if origin.x != bounds.minX { (superview as? GridNativeScrollView)?.prepareHorizontalViewport(at: origin.x) }
        super.scroll(to: origin)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        let maximum = max(0, (documentView?.frame.width ?? 0) - proposedBounds.width)
        constrained.origin.x = min(max(0, proposedBounds.minX), maximum)
        let maximumY = max(0, (documentView?.frame.height ?? 0) - proposedBounds.height)
        constrained.origin.y = min(max(0, proposedBounds.minY), maximumY)
        return constrained
    }
}
#endif

#if os(macOS)
struct NativeTimelinePinnedLayer<Content: View>: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    var pinHorizontally = false
    let content: Content
    @Environment(\.locale) private var locale
    func makeNSView(context: Context) -> NativeTimelinePinnedView {
        NativeTimelinePinnedView()
    }
    func updateNSView(_ view: NativeTimelinePinnedView, context: Context) {
        view.pinHorizontally = pinHorizontally
        let root = AnyView(content.environment(\.locale, locale))
        if let host = view.host as? GridHostingView<AnyView> {
            host.layoutProfile?.rootAssigned(host)
            host.rootView = root
        } else {
            let host = GridHostingView(rootView: root)
            host.layoutProfile = TimelineLayoutDiagnostics.make(pinHorizontally ? "pinned-horizontal" : "pinned-vertical")
            host.layoutProfile?.rootAssigned(host)
            if #available(macOS 13, *) { host.sizingOptions = [] }
            if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
            view.host?.removeFromSuperview()
            view.host = host
            view.addSubview(host)
        }
        if let host = view.host as? GridHostingView<AnyView> {
            host.layoutProfile?.sizeChanged(host, from: host.frame.size, to: NSSize(width: width, height: height))
        }
        view.host?.setFrameSize(NSSize(width: width, height: height))
        view.observeScroll()
    }
}
final class NativeTimelinePinnedView: NSView {
    var host: NSView?
    var pinHorizontally = false
    private weak var clip: NSClipView?
    private weak var horizontalClip: NSClipView?
    private var observer: NSObjectProtocol?
    private var horizontalObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === host ? nil : hit
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScroll()
    }
    func observeScroll() {
        var parent = superview
        var outer: NSScrollView?
        var inner: NSScrollView?
        while let view = parent {
            if let scroll = view as? GridNativeScrollView {
                if inner == nil { inner = scroll }
                outer = scroll
            }
            parent = view.superview
        }
        guard let next = outer?.contentView else { return }
        if clip !== next {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            clip = next
            next.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: next, queue: .main) { [weak self] _ in
                self?.pin()
            }
        }
        let nextHorizontal = pinHorizontally && inner !== outer ? inner?.contentView : nil
        if horizontalClip !== nextHorizontal {
            if let horizontalObserver { NotificationCenter.default.removeObserver(horizontalObserver) }
            horizontalObserver = nil
            horizontalClip = nextHorizontal
            if let nextHorizontal {
                nextHorizontal.postsBoundsChangedNotifications = true
                horizontalObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: nextHorizontal, queue: .main) { [weak self] _ in
                    self?.pin()
                }
            }
        }
        pin()
    }
    private func pin() {
        guard let host, let clip else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let origin = NSPoint(x: max(0, horizontalClip?.bounds.minX ?? 0), y: max(0, clip.bounds.minY))
        if host.frame.origin != origin { host.setFrameOrigin(origin) }
        CATransaction.commit()
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let horizontalObserver { NotificationCenter.default.removeObserver(horizontalObserver) }
    }
}
#endif

#if os(macOS)
/// A native scroll binding for the two sidebar dividers. Bounds changes update
/// only their small thumbs; they never publish a new SwiftUI layout transaction.
struct SidebarScrollMetrics: Equatable {
    var documentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var offset: CGFloat = 0
    var maximumOffset: CGFloat { max(0, documentHeight - viewportHeight) }
    var canScroll: Bool { maximumOffset > 0.5 && viewportHeight > 0 }
}
@MainActor final class SidebarScrollController {
    /// Returns true only when a different destination tile/row bucket needs
    /// layout. The timeline publishes that destination before the clip moves.
    var prepareScroll: ((CGFloat) -> Bool)?
    private(set) weak var scrollView: NSScrollView?
    private weak var attachmentOwner: NSView?
    private weak var observedDocument: NSView?
    private var notifications: [NSObjectProtocol] = []
    private var documentNotification: NSObjectProtocol?
    private var listeners: [UUID: () -> Void] = [:]
    private(set) var metrics = SidebarScrollMetrics()

    private var wheelMonitor: Any?
    @discardableResult func handleWheel(_ event: NSEvent) -> Bool {
        guard let scroll = scrollView, event.window === scroll.window, scroll.window?.attachedSheet == nil,
              !scroll.isHiddenOrHasHiddenAncestor,
              scroll.contentView.visibleRect.contains(scroll.contentView.convert(event.locationInWindow, from: nil)) else { return false }
        // Trackpad/modified wheel events belong to the timeline or native scroll.
        // Reject them before traversing the entire SwiftUI document for hit testing.
        guard !event.hasPreciseScrollingDeltas,
              event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty else { return false }
        var hit = scroll.contentView.hitTest(scroll.convert(event.locationInWindow, from: nil))
        var nearest: NSScrollView?
        while let current = hit {
            if let candidate = current as? NSScrollView { nearest = candidate; break }
            hit = current.superview
        }
        guard nearest === scroll else { return false }
        let movement = -event.scrollingDeltaY * 16
        guard movement != 0 else { return false }
        refresh()
        // Physical wheels have no native momentum. Apply their complete step
        // now, as Logic does; trackpads retain AppKit's own scrolling behavior.
        applyScroll(to: metrics.offset + movement)
        return true
    }
    func attach(_ scroll: NSScrollView?, owner: NSView? = nil) {
        attachmentOwner = owner
        guard scrollView !== scroll else { refresh(); return }
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor); self.wheelMonitor = nil }
        if scroll != nil {
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                if event.type != .scrollWheel { return event }
                return self.handleWheel(event) ? nil : event
            }
        }
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        if let documentNotification { NotificationCenter.default.removeObserver(documentNotification) }
        documentNotification = nil; observedDocument = nil
        scrollView = scroll
        if let clip = scroll?.contentView {
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                notifications.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
        }
        refresh()
    }
    func detach(owner: NSView) {
        if attachmentOwner === owner { prepareScroll = nil; attach(nil) }
    }
    @discardableResult func observe(_ changed: @escaping () -> Void) -> UUID {
        let id = UUID(); listeners[id] = changed; return id
    }
    func removeObserver(_ id: UUID) { listeners[id] = nil }
    func refresh() {
        let document = scrollView?.documentView
        if observedDocument !== document {
            if let documentNotification { NotificationCenter.default.removeObserver(documentNotification) }
            documentNotification = nil
            observedDocument = document
            if let document {
                document.postsFrameChangedNotifications = true
                documentNotification = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
        }
        var next = SidebarScrollMetrics()
        if let scroll = scrollView, let document {
            let clip = scroll.contentView
            let rect = clip.documentRect
            next.documentHeight = max(0, rect.height)
            next.viewportHeight = max(0, clip.bounds.height)
            let raw = clip.bounds.minY - rect.minY
            next.offset = min(next.maximumOffset, max(0, document.isFlipped ? raw : next.maximumOffset - raw))
        }
        guard next != metrics else { return }
        metrics = next
        for changed in Array(listeners.values) { changed() }
    }
    func scroll(to offset: CGFloat) { applyScroll(to: offset) }
    private func applyScroll(to offset: CGFloat) {
        guard offset.isFinite, let scroll = scrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let maximum = max(0, clip.documentRect.height - clip.bounds.height)
        let bounded = min(maximum, max(0, offset))
        var origin = clip.bounds.origin
        origin.y = clip.documentRect.minY + (document.isFlipped ? bounded : maximum - bounded)
        guard abs(origin.y - clip.bounds.minY) > 0.001 else { return }
        let largeUnpreparedJump = prepareScroll == nil && abs(origin.y - clip.bounds.minY) > clip.bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // A thumb can jump farther than the existing tile overscan in one
        // event. Mount its actual destination before revealing that viewport.
        if prepareScroll?(bounded) == true { document.layoutSubtreeIfNeeded() }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        // Native SwiftUI ScrollView supplies its own lazy-content state after
        // the clip notification. Resolve large jumps in this same transaction.
        if largeUnpreparedJump { document.layoutSubtreeIfNeeded() }
        refresh()
    }
    deinit {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        notifications.forEach(NotificationCenter.default.removeObserver)
        if let documentNotification { NotificationCenter.default.removeObserver(documentNotification) }
    }
}
struct SidebarScrollProbe: NSViewRepresentable {
    let controller: SidebarScrollController
    var prepareScroll: ((CGFloat) -> Bool)? = nil
    func makeNSView(context: Context) -> SidebarScrollProbeView { SidebarScrollProbeView() }
    func updateNSView(_ view: SidebarScrollProbeView, context: Context) {
        if view.controller !== controller { view.controller?.detach(owner: view) }
        view.controller = controller
        view.prepareScroll = prepareScroll
        view.attach()
    }
    static func dismantleNSView(_ view: SidebarScrollProbeView, coordinator: Void) { view.controller?.detach(owner: view) }
}
final class SidebarScrollProbeView: NSView {
    weak var controller: SidebarScrollController?
    var prepareScroll: ((CGFloat) -> Bool)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller?.detach(owner: self) } else { attach() }
    }
    func attach() {
        var parent = superview
        while let view = parent {
            if let scroll = view as? NSScrollView {
                controller?.prepareScroll = prepareScroll
                controller?.attach(scroll, owner: self)
                return
            }
            parent = view.superview
        }
    }
}
#endif
