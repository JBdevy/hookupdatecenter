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
    /// A horizontal timeline may keep its hosting geometry at the viewport
    /// width while the native document retains the full scrollable extent.
    var viewportWidth: CGFloat? = nil
    var fileDrop: (([URL], CGPoint) -> Bool)? = nil
    var fileDropPreview: (([URL], CGPoint?) -> Void)? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        #if os(macOS)
        NativeGridScroll(horizontal: axis == .horizontal, contentWidth: contentWidth, contentHeight: contentHeight, viewportWidth: viewportWidth, fileDrop: fileDrop, fileDropPreview: fileDropPreview, content: content())
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

/// Opt-in structural snapshot for profiling. The ordinary path schedules no
/// work and the dump contains geometry/class names, never control text.
private enum TimelineViewTreeDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["CATLIVE_PROFILE_VIEW_TREE"] == "1"
    private static var scheduled = false
    static func schedule(from view: NSView) {
        guard enabled, !scheduled, let window = view.window else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak window] in
            guard let root = window?.contentView else { return }
            func record(_ view: NSView) -> [String: Any] {
                ["class": NSStringFromClass(type(of: view)), "frame": NSStringFromRect(view.frame),
                 "bounds": NSStringFromRect(view.bounds), "hidden": view.isHidden,
                 "trackingAreas": view.trackingAreas.count, "constraints": view.constraints.count,
                 "children": view.subviews.map(record)]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: record(root), options: [.prettyPrinted, .sortedKeys]) else { return }
            let path = "/tmp/catlive-view-tree-\(ProcessInfo.processInfo.processIdentifier).json"
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
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

private final class WorkspaceSplitView<Leading: View, Trailing: View>: NSView, NativeTimelineBodyInputHost, NativeTimelineInputObserver, NativeTimelineDefaultCursorHost {
    override func resetCursorRects() {
        guard let window, window.attachedSheet == nil, !NativeTimelineInputGate.shared.isBlocked(window),
              !isHiddenOrHasHiddenAncestor else { return }
        // A default cursor on the workspace lets AppKit resolve blank areas
        // without traversing both hosting trees. Descendant cursors take priority.
        let rect = bounds.intersection(visibleRect)
        guard !rect.isEmpty else { return }
        addCursorRect(rect, cursor: .arrow)
    }
    func timelineInputGateChanged(blocked: Bool) {
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
    }

    @objc private func workspaceWindowBecameKey(_ notification: Notification) {
        window?.invalidateCursorRects(for: self)
    }

    weak var timelineBodyInput: (NSView & NativeTimelineBodyInput)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        timelineBodyHit(at: point) ?? timelineControlHit(at: point) ?? super.hitTest(point)
    }
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
        // AppKit lays out dirty descendants after applying these frames. A
        // timeline-only update must not explicitly walk the setlist host too.
        // Divider tracking keeps its synchronous commit through resizeLayout.
        applyFrames(layoutHosts: false)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            NativeTimelineInputGate.shared.add(self)
            NotificationCenter.default.addObserver(self, selector: #selector(workspaceWindowBecameKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: window)
        }
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
            leading.needsLayout = true
        }
        if divider.frame != barFrame { divider.frame = barFrame }
        if trailing.frame != rightFrame {
            trailing.layoutProfile?.sizeChanged(trailing, from: trailing.frame.size, to: rightFrame.size)
            trailing.frame = rightFrame
            trailing.needsLayout = true
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

private final class TimelineColumnsNativeView<Mixer: View, Divider: View, Timeline: View, Identity: Equatable>: NSView, NativeTimelineBodyInputHost {
    weak var timelineBodyInput: (NSView & NativeTimelineBodyInput)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        timelineBodyHit(at: point) ?? timelineControlHit(at: point) ?? super.hitTest(point)
    }
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
    var viewportWidth: CGFloat? = nil
    let fileDrop: (([URL], CGPoint) -> Bool)?
    let fileDropPreview: (([URL], CGPoint?) -> Void)?
    let content: Content
    @Environment(\.openFX) private var openFX
    @Environment(\.openClipFXChain) private var openClipFXChain
    @Environment(\.editTextItem) private var editTextItem
    @Environment(\.editTrackDetails) private var editTrackDetails
    @Environment(\.gridInteractionBlocked) private var gridInteractionBlocked
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    private var hostedViewportWidth: CGFloat? {
        horizontal ? viewportWidth.map { max(0, $0) } : nil
    }
    private var hostedSize: NSSize {
        NSSize(width: hostedViewportWidth ?? contentWidth, height: contentHeight)
    }
    private func hosted(_ coordinator: Coordinator) -> GridHostedContent<Content> {
        coordinator.actions.fx = openFX; coordinator.actions.clipFX = openClipFXChain; coordinator.actions.text = editTextItem
        coordinator.actions.trackDetails = editTrackDetails
        return GridHostedContent(content: content, viewportWidth: hostedViewportWidth, gridInteractionBlocked: gridInteractionBlocked,
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
        if horizontal {
            scroll.registerForDraggedTypes([.fileURL])
            SidebarScrollController.registerTimelineWheelClip(scroll.contentView)
        }
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
        host.layoutProfile?.sizeChanged(host, from: host.frame.size, to: hostedSize)
        host.didLayout = { [weak scroll] in scroll?.commitHostedProjection() }
        if #available(macOS 13, *) { host.sizingOptions = [] }
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        host.setFrameSize(hostedSize)
        scroll.contentView.wantsLayer = true
        let document = GridDocumentView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
        document.wantsLayer = true
        document.autoresizesSubviews = false
        document.host = host; document.addSubview(host)
        scroll.hostedProjectionDidLayout = { [weak document] in document?.commitHostedProjection() ?? true }
        scroll.documentView = document
        document.setHostedViewport(width: hostedViewportWidth, clip: scroll.contentView)
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
        // An internal zoom may already have committed a newer logical width
        // than this structural representable captured. Environment-only root
        // updates must preserve that width; parent row-height changes still
        // apply immediately and the live bridge commits any new zoom/extent.
        let size = NSSize(width: document.liveLogicalWidth ?? contentWidth, height: contentHeight)
        document.applySize(size, in: scroll, retainingCapacity: document.liveLogicalWidth != nil)
        let layoutSize = NSSize(width: document.liveHostedWidth ?? hostedSize.width, height: contentHeight)
        if host.frame.size != layoutSize {
            host.layoutProfile?.sizeChanged(host, from: host.frame.size, to: layoutSize)
            host.setFrameSize(layoutSize)
            host.needsLayout = true
            // SwiftUI invalidates the changed Canvas tiles. Forcing the whole
            // hosting document and clip to redraw discards their backing reuse.
        }
        document.setHostedViewport(width: hostedViewportWidth, clip: scroll.contentView)
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
    var viewportWidth: CGFloat? = nil
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
            .frame(width: viewportWidth, alignment: .topLeading)
    }
}
/// Explicit document geometry terminates AppKit fitting-size propagation here.
/// Rescaling the timeline must not ask the track controls and meters for sizes.
private final class GridDocumentView: NSView {
    var host: NSView?
    private weak var logicalSizeInput: GridDocumentSizeView?
    private var usesHostedViewport = false
    private weak var hostedClip: NSClipView?
    private var hostedClipObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }

    var liveLogicalWidth: CGFloat? {
        guard let input = logicalSizeInput, input.isDescendant(of: self),
              input.documentSize.width.isFinite, input.documentSize.width > 0 else {
            logicalSizeInput = nil
            return nil
        }
        return input.documentSize.width
    }
    var liveHostedWidth: CGFloat? {
        guard liveLogicalWidth != nil else { return nil }
        return logicalSizeInput?.hostingWidth
    }
    func adoptLogicalSizeInput(_ input: GridDocumentSizeView) { logicalSizeInput = input }
    func commitHostedProjection() -> Bool { logicalSizeInput?.hostedProjectionDidLayout?() ?? true }
    func releaseLogicalSizeInput(_ input: GridDocumentSizeView) {
        if logicalSizeInput === input {
            logicalSizeInput = nil
            (enclosingScrollView as? GridNativeScrollView)?.logicalDocumentWidth = nil
        }
    }

    /// The native document and hosting plane retain capacity together. Only
    /// the clip's logical extent changes on ordinary zoom ticks, avoiding a
    /// document frame mutation that invalidates unrelated ancestor layout.
    @discardableResult
    func applySize(_ size: NSSize, in scroll: GridNativeScrollView, retainingCapacity: Bool) -> Bool {
        let logicalWidth: CGFloat? = retainingCapacity ? size.width : nil
        let logicalChanged = scroll.logicalDocumentWidth != logicalWidth
        scroll.logicalDocumentWidth = logicalWidth
        var physicalSize = size
        if retainingCapacity {
            let required = max(size.width, liveHostedWidth ?? 0)
            physicalSize.width = required > frame.width ? max(required, frame.width * 2) : frame.width
        }
        let physicalChanged = frame.size != physicalSize
        if physicalChanged { setFrameSize(physicalSize) }
        if logicalChanged {
            let clip = scroll.contentView
            // A pending zoom owns its origin until the matching projection is
            // ready. Other extent changes immediately keep the viewport valid.
            if scroll.zoomAnchor == nil {
                let origin = clip.constrainBoundsRect(clip.bounds).origin
                if origin != clip.bounds.origin { clip.scroll(to: origin) }
            }
            scroll.reflectScrolledClipView(clip)
        }
        return logicalChanged || physicalChanged
    }

    func setHostedViewport(width: CGFloat?, clip: NSClipView) {
        usesHostedViewport = width != nil
        let nextClip = usesHostedViewport ? clip : nil
        if hostedClip !== nextClip {
            if let hostedClipObserver { NotificationCenter.default.removeObserver(hostedClipObserver) }
            hostedClipObserver = nil
            hostedClip = nextClip
            if let nextClip {
                nextClip.postsBoundsChangedNotifications = true
                hostedClipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: nextClip, queue: .main) { [weak self] _ in self?.synchronizeHostedViewport() }
            }
        }
        synchronizeHostedViewport()
    }

    /// Equal frame and bounds origins preserve all descendant document-space
    /// coordinates. The host itself stays over the visible range, so AppKit
    /// still reaches native controls far beyond the initial viewport.
    func synchronizeHostedViewport() {
        guard let host else { return }
        let origin = NSPoint(x: usesHostedViewport ? max(0, hostedClip?.bounds.minX ?? 0) : 0, y: 0)
        if host.frame.origin != origin { host.setFrameOrigin(origin) }
        if host.bounds.origin != origin { host.setBoundsOrigin(origin) }
    }

    deinit {
        if let hostedClipObserver { NotificationCenter.default.removeObserver(hostedClipObserver) }
    }
}

/// The zoom observer lives inside the stable hosting root. It updates only the
/// native scroll extent; the hosting view remains sized to its viewport.
struct GridDocumentSizeInput: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    var hostingWidth: CGFloat? = nil
    func makeNSView(context: Context) -> GridDocumentSizeView { GridDocumentSizeView() }
    func updateNSView(_ view: GridDocumentSizeView, context: Context) {
        view.documentSize = NSSize(width: width, height: height)
        view.hostingWidth = hostingWidth
        view.applyDocumentSize()
    }
}
final class GridDocumentSizeView: NSView {
    var documentSize = NSSize.zero
    var hostingWidth: CGFloat?
    var waitsForHostedProjection = true
    var hostedProjectionDidLayout: (() -> Bool)?
    private weak var ownedDocument: GridDocumentView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyDocumentSize()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyDocumentSize()
    }
    func applyDocumentSize() {
        guard documentSize.width.isFinite, documentSize.height.isFinite,
              documentSize.width > 0, documentSize.height > 0 else { return }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? GridNativeScrollView {
                guard let document = scroll.documentView as? GridDocumentView,
                      isDescendant(of: document) else { return }
                if ownedDocument !== document {
                    ownedDocument?.releaseLogicalSizeInput(self)
                    ownedDocument = document
                }
                document.adoptLogicalSizeInput(self)
                if let hostingWidth, hostingWidth.isFinite, hostingWidth >= documentSize.width, let host = document.host {
                    let size = NSSize(width: hostingWidth, height: documentSize.height)
                    if host.frame.size != size { host.setFrameSize(size); host.needsLayout = true }
                }
                if document.applySize(documentSize, in: scroll, retainingCapacity: true) {
                    document.synchronizeHostedViewport()
                    if waitsForHostedProjection { document.host?.needsLayout = true }
                }
                // GridHostingView commits a queued zoom anchor after its
                // descendants have laid out this logical document scale.
                if waitsForHostedProjection, scroll.zoomAnchor != nil { document.host?.needsLayout = true }
                return
            }
            ancestor = view.superview
        }
        ownedDocument?.releaseLogicalSizeInput(self)
        ownedDocument = nil
    }
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
final class GridNativeScrollView: NSScrollView, NativeTimelineBodyInputHost {
    /// Nil keeps ordinary, unbridged scroll views tied to their document frame.
    var logicalDocumentWidth: CGFloat?
    weak var timelineBodyInput: (NSView & NativeTimelineBodyInput)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        TimelineViewTreeDiagnostics.schedule(from: self)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !isHiddenOrHasHiddenAncestor, contentView.frame.contains(local),
           let target = timelineBodyInput, target.window === window,
           let hit = target.hitTestTimelineBody(atWindowPoint: convert(local, to: nil)) {
            return hit
        }
        if contentView.frame.contains(local), let hit = timelineControlHit(at: point) { return hit }
        return super.hitTest(point)
    }
    private let layoutProfile = TimelineLayoutDiagnostics.make("zoom-native")
    override func scrollWheel(with event: NSEvent) {
        layoutProfile?.event("scroll-input", view: self, input: event)
        super.scrollWheel(with: event)
    }
    /// The destination bucket must exist before AppKit reveals its pixels.
    /// Only the horizontal timeline installs this callback.
    var prepareHorizontalScroll: ((CGFloat) -> Bool)?
    var prepareHostedHorizontalScroll: ((CGFloat) -> Bool)?
    var prepareHostedVerticalScroll: ((CGFloat) -> Bool)?
    private var preparingVerticalScroll = false
    private var preparingHorizontalScroll = false
    func prepareHorizontalViewport(at x: CGFloat) {
        guard !preparingHorizontalScroll, zoomAnchor == nil, let document = documentView else { return }
        preparingHorizontalScroll = true
        defer { preparingHorizontalScroll = false }
        // Ordinary movement inside the prepared bucket does not need a
        // transaction/layout flush. Prepare changed buckets before revealing them.
        let viewportChanged = prepareHorizontalScroll?(x) ?? false
        let hostedChanged = prepareHostedHorizontalScroll?(x) ?? false
        if viewportChanged || hostedChanged { document.layoutSubtreeIfNeeded() }
    }
    func prepareVerticalViewport(at y: CGFloat) {
        guard !preparingVerticalScroll, let document = documentView,
              let prepareHostedVerticalScroll else { return }
        preparingVerticalScroll = true
        defer { preparingVerticalScroll = false }
        if prepareHostedVerticalScroll(y) { document.layoutSubtreeIfNeeded() }
    }
    var hostedProjectionDidLayout: (() -> Bool)?
    func commitHostedProjection() {
        guard hostedProjectionDidLayout?() != false else { return }
        applyZoomAnchor()
    }
    var fileDrop: (([URL], CGPoint) -> Bool)?
    var fileDropPreview: (([URL], CGPoint?) -> Void)?
    var fileDropModifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    private var fileDropURLs: [URL] = []
    private var fileDropPasteboardChange: Int?
    private var lastFileDropPreview: CGPoint?
    private var lastFileDropModifierFlags: NSEvent.ModifierFlags = []
    private func updateFileDropPreview(_ point: CGPoint?) {
        // Shift changes magnetic snapping even when the dragged file has not moved.
        let modifiers: NSEvent.ModifierFlags = point == nil ? [] : fileDropModifierFlags()
        guard point != lastFileDropPreview || (point != nil && modifiers != lastFileDropModifierFlags) else { return }
        lastFileDropPreview = point
        lastFileDropModifierFlags = modifiers
        fileDropPreview?(point == nil ? [] : fileDropURLs, point)
        if point == nil { fileDropURLs = []; fileDropPasteboardChange = nil }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileDrop != nil, let documentView,
              sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            updateFileDropPreview(nil)
            return []
        }
        if fileDropPasteboardChange != sender.draggingPasteboard.changeCount {
            fileDropURLs = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            fileDropPasteboardChange = sender.draggingPasteboard.changeCount
            lastFileDropPreview = nil
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

    // A committed layout clears zoomAnchor between frames, but the gesture
    // still owns the viewport until its animation and quiet period finish.
    var playbackFollowSuspendedUntil: TimeInterval = 0
    var permitsPlaybackFollow: Bool {
        zoomAnchor == nil && ProcessInfo.processInfo.systemUptime >= playbackFollowSuspendedUntil
    }
    func prioritizeZoom() { playbackFollowSuspendedUntil = ProcessInfo.processInfo.systemUptime + 0.18 }
    var zoomAnchor: (fraction: Double, screenX: CGFloat, width: CGFloat)?
    func applyZoomAnchor() {
        guard let anchor = zoomAnchor, documentView != nil else { return }
        let width = contentView.documentRect.width
        var origin = contentView.bounds.origin
        origin.x = min(max(0, CGFloat(anchor.fraction) * width - anchor.screenX),
                       max(0, width - contentView.bounds.width))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        // SwiftUI may commit an intermediate scale after a newer wheel event.
        // Center that actual frame too, retaining the target for the next layout.
        // Fractional zoom steps can be smaller than one point. A two-point
        // tolerance acknowledged the previous layout as the new one, leaving
        // the final cursor/waveform scale with its previous viewport origin.
        let tolerance = max(1e-7, abs(anchor.width).ulp * 8)
        if abs(width - anchor.width) <= tolerance {
            layoutProfile?.event("geometry-commit", view: self, value: Double(width))
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
    override var documentRect: NSRect {
        var rect = super.documentRect
        if let width = (superview as? GridNativeScrollView)?.logicalDocumentWidth {
            rect.size.width = width
        }
        return rect
    }
    private func boundedOrigin(_ origin: NSPoint) -> NSPoint {
        var result = origin
        let maximum = max(0, documentRect.width - bounds.width)
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
        if origin.y != bounds.minY { (superview as? GridNativeScrollView)?.prepareVerticalViewport(at: origin.y) }
        super.setBoundsOrigin(origin)
    }
    override func scroll(to newOrigin: NSPoint) {
        let origin = boundedOrigin(newOrigin)
        if origin.x != bounds.minX { (superview as? GridNativeScrollView)?.prepareHorizontalViewport(at: origin.x) }
        if origin.y != bounds.minY { (superview as? GridNativeScrollView)?.prepareVerticalViewport(at: origin.y) }
        super.scroll(to: origin)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        let maximum = max(0, documentRect.width - proposedBounds.width)
        constrained.origin.x = min(max(0, proposedBounds.minX), maximum)
        let maximumY = max(0, (documentView?.frame.height ?? 0) - proposedBounds.height)
        constrained.origin.y = min(max(0, proposedBounds.minY), maximumY)
        return constrained
    }
}
#endif

#if os(macOS)
private struct TimelinePinnedContent<Content: View>: View {
    let content: Content
    let locale: Locale
    var body: some View { content.environment(\.locale, locale) }
}
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
        // Preserve the root's concrete type across zoom frames so the hosting
        // graph can retain unchanged header/input descendants.
        let root = TimelinePinnedContent(content: content, locale: locale)
        if let host = view.host as? GridHostingView<TimelinePinnedContent<Content>> {
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
        let size = NSSize(width: width, height: height)
        if let host = view.host as? GridHostingView<TimelinePinnedContent<Content>>, host.frame.size != size {
            host.layoutProfile?.sizeChanged(host, from: host.frame.size, to: size)
            host.setFrameSize(size)
        }
        view.observeScroll()
    }
}
/// The item input is already AppKit. Pin it directly instead of placing an
/// NSHostingView around a representable around the same native input view.
struct NativeTimelinePinnedInput: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    let input: GridSelectionInput
    func makeNSView(context: Context) -> NativeTimelinePinnedView {
        let view = NativeTimelinePinnedView()
        view.pinHorizontally = true; view.hostHandlesInput = true
        let input = GridSelectionView(); view.host = input; view.addSubview(input)
        return view
    }
    func updateNSView(_ view: NativeTimelinePinnedView, context: Context) {
        guard let target = view.host as? GridSelectionView else { return }
        input.apply(to: target)
        let size = CGSize(width: width, height: height)
        if target.frame.size != size { target.setFrameSize(size) }
        view.observeScroll()
    }
}
final class NativeTimelinePinnedView: NSView {
    var hostHandlesInput = false
    var host: NSView?
    var pinHorizontally = false
    private weak var clip: NSClipView?
    private weak var horizontalClip: NSClipView?
    private var observer: NSObjectProtocol?
    private var horizontalObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || (hit === host && !hostHandlesInput) ? nil : hit
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
        let origin = NSPoint(x: max(0, horizontalClip?.bounds.minX ?? 0), y: max(0, clip.bounds.minY))
        guard host.frame.origin != origin else { return }
        // Direct AppKit positioning is immediate. A separate CA commit for
        // every scroll sample can flush the entire window between display frames.
        host.setFrameOrigin(origin)
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
    private static let timelineWheelClips = NSHashTable<NSClipView>.weakObjects()
    static func registerTimelineWheelClip(_ clip: NSClipView) { timelineWheelClips.add(clip) }
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
        // The outer vertical document also contains the horizontal timeline.
        // Its wheel input owns this viewport; decline before hit-testing the
        // entire SwiftUI window merely to discover that nested scroll view.
        // Returning false also leaves any overlapping panel on its normal route.
        for clip in Self.timelineWheelClips.allObjects where clip !== scroll.contentView &&
            clip.window === scroll.window && clip.isDescendant(of: scroll.contentView) &&
            !clip.isHiddenOrHasHiddenAncestor {
            if clip.visibleRect.contains(clip.convert(event.locationInWindow, from: nil)) { return false }
        }
        // Start at the window, not the covered scroll view: playlist creation
        // and Add regions are sibling overlays above the ordinary Setlist.
        // Hit-testing only our own clip would steal their physical-wheel events.
        guard let root = scroll.window?.contentView else { return false }
        let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var hit = root.hitTest(point)
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
