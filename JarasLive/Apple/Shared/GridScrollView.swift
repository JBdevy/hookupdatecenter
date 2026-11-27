import SwiftUI
import Combine

/// Transient sidebar widths update only their layout scope. Publishing each
/// drag through MainView or the timeline editor also invalidated unrelated
/// transport controls, modal hosts and native input callbacks.
final class SidebarResizeState: ObservableObject {
    @Published private(set) var width: CGFloat?
    #if os(macOS)
    let nativeWidth = NativeTimelineMixerWidth()
    #endif
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

struct TimelineGeometrySize { let size: CGSize }
/// Keep drawing coverage separate from the native viewport's actual width.
/// Other platforms retain the ordinary GeometryReader behavior.
struct TimelineGeometryReader<Content: View>: View {
    var minimumRetainedWidth: CGFloat = 800
    var documentHeight: (() -> CGFloat)? = nil
    #if os(macOS)
    let builderIdentity = UUID()
    #endif
    @ViewBuilder let content: (TimelineGeometrySize) -> Content
    var body: some View {
        #if os(macOS)
        NativeTimelineGeometryReader(minimumRetainedWidth: minimumRetainedWidth, documentHeight: documentHeight, builderIdentity: builderIdentity, content: content)
        #else
        GeometryReader { geometry in content(TimelineGeometrySize(size: geometry.size)) }
        #endif
    }
}

struct GridRowReveal: Equatable {
    let id: UUID
    let offset: CGFloat
    let height: CGFloat
    let headerHeight: CGFloat
}

/// The grid owns these scroll views. SwiftUI cannot recreate scrollers or reserve gutters.
enum TimelineVerticalBar {
    #if os(macOS)
    static let width: CGFloat = 14
    #else
    static let width: CGFloat = 20
    #endif
}

struct GridScrollView<Content: View>: View {
    let axis: Axis.Set
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    /// A horizontal timeline may keep its hosting geometry at the viewport
    /// width while the native document retains the full scrollable extent.
    var viewportWidth: CGFloat? = nil
    var trackHeight: CGFloat? = nil
    var timelineVerticalBarTop: CGFloat? = nil
    var rowHeights: [CGFloat] = []
    var selectedRow: Int? = nil
    var rowReveal: GridRowReveal? = nil
    var fileDrop: (([URL], CGPoint) -> Bool)? = nil
    var fileDropPreview: (([URL], CGPoint?) -> Void)? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        #if os(macOS)
        NativeGridScroll(horizontal: axis == .horizontal, contentWidth: contentWidth, contentHeight: contentHeight, viewportWidth: viewportWidth, trackHeight: trackHeight, timelineVerticalBarTop: timelineVerticalBarTop, rowHeights: rowHeights, selectedRow: selectedRow, rowReveal: rowReveal, fileDrop: fileDrop, fileDropPreview: fileDropPreview, content: content())
        #else
        ScrollView(axis, showsIndicators: false, content: content)
        #endif
    }
}

#if os(iOS)
import UIKit

@MainActor final class TimelineTouchScrollConnection {
    fileprivate weak var bar: TimelineTouchScrollBarView? {
        didSet { bar?.observe(scroll) }
    }
    weak var scroll: UIScrollView? {
        didSet { if oldValue !== scroll { bar?.observe(scroll) } }
    }
}

struct TimelineSetlistResize {
    let change: (CGFloat) -> Void
    let finish: () -> Void
}
private struct TimelineSetlistResizeKey: EnvironmentKey {
    static let defaultValue: TimelineSetlistResize? = nil
}
extension EnvironmentValues {
    var timelineSetlistResize: TimelineSetlistResize? {
        get { self[TimelineSetlistResizeKey.self] }
        set { self[TimelineSetlistResizeKey.self] = newValue }
    }
}

struct TimelineTouchScrollBar: UIViewRepresentable {
    @Environment(\.timelineSetlistResize) private var resize
    let connection: TimelineTouchScrollConnection
    let move: (CGFloat) -> Void
    func makeUIView(context: Context) -> TimelineTouchScrollBarView { TimelineTouchScrollBarView() }
    func updateUIView(_ view: TimelineTouchScrollBarView, context: Context) {
        view.resize = resize
        view.move = move
        if connection.bar !== view { connection.bar = view }
    }
}

final class TimelineTouchScrollBarView: UIView {
    private weak var scroll: UIScrollView?
    private var observers: [NSKeyValueObservation] = []
    private let slot = CALayer()
    private let knob = CALayer()
    private var grabOffset: CGFloat = 0
    private var lastPercentage: Int?
    var move: ((CGFloat) -> Void)?

    init() {
        super.init(frame: .zero)
        slot.backgroundColor = UIColor(white: 0.12, alpha: 1).cgColor
        knob.backgroundColor = UIColor(red: 84.0 / 255, green: 1, blue: 147.0 / 255, alpha: 1).cgColor
        for layer in [slot, knob] {
            layer.cornerRadius = 3
            self.layer.addSublayer(layer)
        }
        isAccessibilityElement = true
        accessibilityLabel = NSLocalizedString("Vertical timeline scroll", comment: "")
        accessibilityTraits = .adjustable
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func observe(_ scroll: UIScrollView?) {
        observers.removeAll()
        self.scroll = scroll
        if let scroll {
            observers = [scroll.observe(\.contentOffset) { [weak self] _, _ in self?.updateThumb() },
                         scroll.observe(\.contentSize) { [weak self] _, _ in self?.updateThumb() },
                         scroll.observe(\.bounds) { [weak self] _, _ in self?.updateThumb() }]
        }
        updateThumb()
    }

    private var range: CGFloat {
        guard let scroll else { return 0 }
        return max(0, scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom - scroll.bounds.height)
    }
    override func layoutSubviews() { super.layoutSubviews(); updateThumb() }

    private func updateThumb() {
        let available = range
        let viewport = scroll?.bounds.height ?? 0
        let value = available > 0 ? min(1, max(0, ((scroll?.contentOffset.y ?? 0) + (scroll?.adjustedContentInset.top ?? 0)) / available)) : 0
        let height = min(bounds.height, max(18, bounds.height * viewport / max(1, viewport + available)))
        let trackFrame = CGRect(x: bounds.midX - 3, y: 0, width: 6, height: bounds.height)
        let thumbFrame = CGRect(x: trackFrame.minX, y: (bounds.height - height) * value, width: 6, height: height)
        let opacity: Float = available > 0 ? 1 : 0.28
        if slot.frame != trackFrame || knob.frame != thumbFrame || knob.opacity != opacity {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            slot.frame = trackFrame
            knob.frame = thumbFrame
            knob.opacity = opacity
            CATransaction.commit()
        }
        let percentage = Int((value * 100).rounded())
        if lastPercentage != percentage {
            lastPercentage = percentage
            accessibilityValue = "\(percentage)%"
        }
    }

    private func scroll(to y: CGFloat) {
        guard let scroll else { return }
        move?(min(range, max(0, y)) - scroll.adjustedContentInset.top)
    }

    var resize: TimelineSetlistResize?
    private var startPoint: CGPoint?
    private enum DragAxis { case pending, scroll, resize }
    private var dragAxis = DragAxis.pending

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let y = touch.location(in: self).y
        grabOffset = (knob.frame.minY...knob.frame.maxY).contains(y) ? y - knob.frame.minY : knob.frame.height / 2
        startPoint = touch.location(in: window)
        dragAxis = resize == nil ? .scroll : .pending
        if dragAxis == .scroll { drag(to: y) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let startPoint else { return }
        let point = touch.location(in: window)
        let dx = point.x - startPoint.x, dy = point.y - startPoint.y
        if dragAxis == .pending {
            guard max(abs(dx), abs(dy)) >= 3 else { return }
            dragAxis = abs(dx) > abs(dy) ? .resize : .scroll
        }
        if dragAxis == .resize { resize?.change(dx) }
        else { drag(to: touch.location(in: self).y) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesMoved(touches, with: event)
        if dragAxis == .pending, let touch = touches.first { drag(to: touch.location(in: self).y) }
        if dragAxis == .resize { resize?.finish() }
        startPoint = nil
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if dragAxis == .resize { resize?.finish() }
        startPoint = nil
    }
    private func drag(to y: CGFloat) {
        let distance = bounds.height - knob.frame.height
        if distance > 0 { scroll(to: (y - grabOffset) / distance * range) }
    }
    override func accessibilityIncrement() { page(by: 1) }
    override func accessibilityDecrement() { page(by: -1) }
    private func page(by direction: CGFloat) {
        guard let scroll else { return }
        self.scroll(to: scroll.contentOffset.y + scroll.adjustedContentInset.top + direction * scroll.bounds.height * 0.85)
    }
}
#endif

#if os(macOS)
import AppKit

extension View {
    /// The workspace owns the colors of its controls. Keep nested hosting
    /// graphs from restyling those controls when a tool or system menu takes focus.
    @ViewBuilder func workspaceControlsAppearActive() -> some View {
        if #available(macOS 15, *) {
            environment(\.appearsActive, true).environment(\.controlActiveState, .active)
        } else {
            environment(\.controlActiveState, .active)
        }
    }
}

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
        var inputAgeMS: Double? = nil
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
        private weak var resizeView: NSView?
        private weak var resizeWindow: NSWindow?
        private var resizeUpdateObserver: NSObjectProtocol?
        private var pendingResizeUpdate: (received: TimeInterval, timestamp: TimeInterval, value: Double?)?
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
                record.inputAgeMS = max(0, ProcessInfo.processInfo.systemUptime - input.timestamp) * 1000
                // AppKit raises an exception when scroll-only properties are
                // requested from a mouse drag/up. Diagnostics must never abort input.
                if input.type == .scrollWheel {
                    record.deltaX = Double(input.scrollingDeltaX); record.deltaY = Double(input.scrollingDeltaY)
                }
                record.modifiers = input.modifierFlags.rawValue
            }
            record.value = value
            session.append(record)
            if name == "resize-input", let input, let view, let window = view.window {
                resizeView = view
                pendingResizeUpdate = (ProcessInfo.processInfo.systemUptime, input.timestamp, value)
                if resizeWindow !== window {
                    if let resizeUpdateObserver { NotificationCenter.default.removeObserver(resizeUpdateObserver) }
                    resizeWindow = window
                    resizeUpdateObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                        self?.recordResizeWindowUpdate()
                    }
                }
            }
        }
        /// This boundary includes the descendant layouts omitted by a host's
        /// own layout() timer. It is a window update, not a GPU-present timestamp.
        private func recordResizeWindowUpdate() {
            guard let pending = pendingResizeUpdate, let view = resizeView else { return }
            pendingResizeUpdate = nil
            var record = makeRecord("resize-window-update", view)
            let now = ProcessInfo.processInfo.systemUptime
            record.durationMS = (now - pending.received) * 1000
            record.inputTimestampMS = pending.timestamp * 1000
            record.inputAgeMS = max(0, now - pending.timestamp) * 1000
            record.value = pending.value
            session.append(record)
        }
        deinit {
            if let resizeUpdateObserver { NotificationCenter.default.removeObserver(resizeUpdateObserver) }
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
        private var heartbeat: Timer?
        private var inputMonitor: Any?
        private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
        private let writer = DispatchQueue(label: "catlive.layout-diagnostics", qos: .utility)
        private var file: FileHandle?
        init() {
            flushTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.flush(wait: false) }
            RunLoop.main.add(flushTimer!, forMode: .common)
            let heartbeat = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in self?.measureMainThread() }
            heartbeat.tolerance = 0.001
            self.heartbeat = heartbeat
            RunLoop.main.add(heartbeat, forMode: .common)
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.recordMainThread("mouse-up", window: event.windowNumber, input: event.timestamp)
                return event
            }
        }
        private func measureMainThread() {
            let now = ProcessInfo.processInfo.systemUptime
            let gap = now - lastHeartbeat
            lastHeartbeat = now
            if gap >= 0.030 { recordMainThread("main-thread-gap", duration: gap) }
        }
        private func recordMainThread(_ event: String, window: Int = -1, input: Double? = nil,
                                      duration: Double? = nil) {
            let now = ProcessInfo.processInfo.systemUptime
            let bucket = Int((now - start) * 60)
            append(Record(event: event, host: 0, role: "workspace-input", window: window,
                          timeMS: (now - start) * 1000, frame: bucket, frameSource: "timer",
                          bucket60Hz: bucket, width: 0, height: 0, durationMS: duration.map { $0 * 1000 },
                          inputTimestampMS: input.map { $0 * 1000 }, inputAgeMS: input.map { max(0, now - $0) * 1000 },
                          rootAssignments: 0, sizeChanges: 0))
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

private struct TimelineGeometryEnvironmentContent<Content: View>: View {
    let content: Content
    let font: Font?
    let controlSize: ControlSize
    let dynamicTypeSize: DynamicTypeSize
    let displayScale: CGFloat
    let layoutDirection: LayoutDirection
    let isEnabled: Bool
    var body: some View {
        content.environment(\.font, font).environment(\.controlSize, controlSize)
            .environment(\.dynamicTypeSize, dynamicTypeSize).environment(\.displayScale, displayScale)
            .environment(\.layoutDirection, layoutDirection).environment(\.isEnabled, isEnabled)
    }
}
/// Identifies one constructed builder, including every environment value passed
/// into its hosted tree. A new parent body creates a new token even when its
/// model metadata compares equal. Ventura can repeat updateNSView for the same
/// value after applying the final native size; that is only a layout proposal.
private struct TimelineGeometryContentIdentity: Equatable {
    let builder: UUID
    let blocked: Bool
    let locale: Locale
    let colorScheme: ColorScheme
    let font: Font?
    let controlSize: ControlSize
    let dynamicTypeSize: DynamicTypeSize
    let displayScale: CGFloat
    let layoutDirection: LayoutDirection
    let isEnabled: Bool
}
private struct NativeTimelineGeometryReader<Content: View>: NSViewRepresentable {
    let minimumRetainedWidth: CGFloat
    let documentHeight: (() -> CGFloat)?
    let builderIdentity: UUID
    let content: (TimelineGeometrySize) -> Content
    @Environment(\.openFX) private var openFX
    @Environment(\.openClipFXChain) private var openClipFX
    @Environment(\.editTextItem) private var editText
    @Environment(\.editTrackDetails) private var editTrack
    @Environment(\.gridInteractionBlocked) private var blocked
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.font) private var font
    @Environment(\.controlSize) private var controlSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.isEnabled) private var isEnabled
    private typealias HostedContent = GridHostedContent<TimelineGeometryEnvironmentContent<Content>>
    func makeNSView(context: Context) -> NSView { TimelineGeometryNativeView<HostedContent>() }
    func updateNSView(_ native: NSView, context: Context) {
        guard let view = native as? TimelineGeometryNativeView<HostedContent> else { return }
        let actions = view.actions
        actions.fx = openFX; actions.clipFX = openClipFX; actions.text = editText; actions.trackDetails = editTrack
        // Always refresh actions, including closure-only environment changes.
        // A fresh parent builder is never identified by partial model metadata.
        let identity = TimelineGeometryContentIdentity(builder: builderIdentity, blocked: blocked,
            locale: locale, colorScheme: colorScheme, font: font, controlSize: controlSize,
            dynamicTypeSize: dynamicTypeSize, displayScale: displayScale,
            layoutDirection: layoutDirection, isEnabled: isEnabled)
        view.documentHeight = documentHeight
        view.update(minimumRetainedWidth: minimumRetainedWidth, identity: identity) { size in
            GridHostedContent(content: TimelineGeometryEnvironmentContent(content: content(TimelineGeometrySize(size: size)),
                font: font, controlSize: controlSize, dynamicTypeSize: dynamicTypeSize,
                displayScale: displayScale, layoutDirection: layoutDirection, isEnabled: isEnabled),
                gridInteractionBlocked: blocked, locale: locale, colorScheme: colorScheme,
                openFX: actions.openFX, openClipFXChain: actions.openClipFX, editTextItem: actions.editText,
                editTrackDetails: actions.editTrack)
        }
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: nsView.bounds.size)
    }
}
private final class TimelineGeometryNativeView<Content: View>: NSView, NativeSidebarResizeViewportObserver {
    let actions = GridHostedActions()
    var documentHeight: (() -> CGFloat)?
    private var host: WorkspaceHostingView<Content>?
    private var builder: ((CGSize) -> Content)?
    private var contentSize: CGSize?
    private var minimumRetainedWidth: CGFloat = 800
    private var updating = false
    private var retainedCoverageActive = false
    private var retainedHeight: CGFloat?
    private var awaitsFinalLayout = false
    private var pendingBuilderUpdate = false
    private var contentIdentity: TimelineGeometryContentIdentity?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    override init(frame: NSRect) {
        super.init(frame: frame); autoresizesSubviews = false
        identifier = NSUserInterfaceItemIdentifier("timeline-geometry")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(minimumRetainedWidth: CGFloat, identity: TimelineGeometryContentIdentity,
                builder: @escaping (CGSize) -> Content) {
        let changed = contentIdentity != identity || self.minimumRetainedWidth != minimumRetainedWidth
        pendingBuilderUpdate = pendingBuilderUpdate || changed
        contentIdentity = identity
        self.minimumRetainedWidth = minimumRetainedWidth; self.builder = builder
        // Mouse-up changes the native parent's frame before AppKit propagates
        // its final proposal to this representable. Keep the latest builder,
        // actions and environment, but do not build against the previous width.
        if awaitsFinalLayout { needsLayout = true; return }
        if host != nil, window != nil {
            // A dock toggle can deliver content before the parent finishes
            // resizing. Apply the newest content and viewport in one pass.
            if changed { needsLayout = true }
            return
        }
        placeContent()
    }
    override func setFrameSize(_ size: NSSize) {
        guard frame.size != size else { return }
        super.setFrameSize(size)
        // Commit the proposal and the corresponding content together in layout().
        // Sizing the old hosting root here first reflows the outgoing viewport.
        needsLayout = true
    }
    override func layout() {
        super.layout()
        awaitsFinalLayout = false
        placeContent()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { NativeSidebarResizeActivity.shared.observeViewport(self) }
        needsLayout = true
    }
    func sidebarResizeActivityChanged() {
        let activity = NativeSidebarResizeActivity.shared
        let retainsCoverage = activity.canRetainTimelineCoverage(in: window)
        let retainsHeight = activity.canRetainTimelineHeight(in: window)
        let releasedHeight = retainedHeight != nil && !retainsHeight
        retainedHeight = retainsHeight ? (retainedHeight ?? bounds.height) : nil
        if (retainedCoverageActive && !retainsCoverage) || releasedHeight {
            // Reconcile with the actual viewport once after the divider settles.
            awaitsFinalLayout = true
        } else if retainsCoverage {
            awaitsFinalLayout = false
            placeContent()
        }
        retainedCoverageActive = retainsCoverage
        needsLayout = true
    }
    private func placeContent() {
        guard !updating, let builder, bounds.width > 0, bounds.height > 0 else { return }
        updating = true; defer { updating = false }
        retainedCoverageActive = NativeSidebarResizeActivity.shared.canRetainTimelineCoverage(in: window)
        let retainsWidth = bounds.width >= minimumRetainedWidth && retainedCoverageActive
        // The clip view still tracks the exact height. When extra grid is
        // exposed, extend drawing coverage in bands instead of rebuilding
        // the hosted timeline at every pixel of a mixer drag.
        if let height = retainedHeight, bounds.height > height {
            retainedHeight = ceil(bounds.height / 128) * 128
        }
        var size = CGSize(width: retainsWidth ? ceil(bounds.width / 512) * 512 : bounds.width,
                          height: retainedHeight ?? bounds.height)
        if !pendingBuilderUpdate, !retainedCoverageActive, retainedHeight == nil,
           let documentHeight, let prepared = contentSize {
            // Dock panels crop the existing document. Reuse its row and waveform
            // coverage while the native clip owns the visible size and scroll limits.
            // A short song still grows and shrinks to exactly fill the empty grid.
            if prepared.height >= bounds.height && prepared.height <= documentHeight() {
                size.height = prepared.height
            }
            if bounds.width >= minimumRetainedWidth && prepared.width >= bounds.width {
                size.width = prepared.width
            }
        }
        if pendingBuilderUpdate || contentSize != size {
            pendingBuilderUpdate = false
            contentSize = size
            let content = builder(size)
            if let host {
                host.layoutProfile?.rootAssigned(host); host.rootView = content
            } else {
                let host = WorkspaceHostingView(rootView: content)
                if #available(macOS 13, *) { host.sizingOptions = [] }
                if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
                host.layoutProfile = TimelineLayoutDiagnostics.make("timeline-geometry")
                host.layoutProfile?.rootAssigned(host)
                self.host = host; addSubview(host)
            }
        }
        // Coverage is never a visual frame or transform. The same live host,
        // clip, columns and hit targets receive the real width on every pass.
        if host?.frame != bounds { host?.frame = bounds }
    }
}

private final class WorkspaceHostingView<Content: View>: NSHostingView<Content>, SidebarResizeLayoutBoundary {
    var layoutProfile: TimelineLayoutDiagnostics.Profile?
    var defersHiddenLayout = false
    // Only independent mixer rows opt in. Scrolling/viewport roots and the
    // timeline must continue processing their own geometry every display pass.
    var retainsSidebarLayout = false
    // The mixer column can retain its layout while the sibling Setlist changes
    // only the timeline viewport. Its visible band also participates in the key:
    // simultaneous scrolling must still update the hosted row pool.
    var retainsSidebarViewportLayout = false
    private var rowContentRevision: UInt64 = 0
    private var laidOutRowRevision: UInt64?
    private var laidOutModelRevision: UInt64?
    private var laidOutBounds: CGRect?
    private var laidOutVisibleRect: CGRect?
    func updateRowContent(_ content: Content) {
        rowContentRevision &+= 1
        rootView = content
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); laidOutBounds = nil }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        // The mixer column already tracks its row band, bounds and model revision.
        // Reopening at the same width can reuse the layout of its mounted rows.
        if !retainsSidebarViewportLayout { laidOutBounds = nil }
        needsLayout = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // NSHostingView on Ventura updates its SwiftUI graph before rejecting
        // an outside point. Reject other rows/panes before entering that graph.
        let local = convert(point, from: superview)
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local), visibleRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
    override func layout() {
        if (defersHiddenLayout || retainsSidebarLayout || retainsSidebarViewportLayout) && isHiddenOrHasHiddenAncestor { return }
        let modelRevision = NativeSidebarResizeActivity.shared.contentRevision
        if retainsSidebarLayout || retainsSidebarViewportLayout {
            var visible: CGRect?
            if retainsSidebarViewportLayout {
                var viewport = bounds.intersection(visibleRect)
                if !viewport.isNull {
                    if let grid = enclosingScrollView as? GridNativeScrollView, let destination = grid.preparingVerticalOrigin {
                        let clip = grid.contentView
                        let target = convert(NSPoint(x: clip.bounds.minX, y: destination), from: clip)
                        viewport.origin.y += target.y - convert(clip.bounds.origin, from: clip).y
                    }
                    // The hosted row pool prepares 512-point bands. Within a
                    // band the native clip translates already-mounted controls.
                    viewport.origin.y = floor(viewport.minY / 512) * 512
                    // The retained pool covers its largest docked viewport.
                    // A shorter visible clip still uses that same row layout.
                    viewport.size.height = 0
                }
                visible = viewport
            }
            NativeSidebarResizeActivity.shared.recordLayout(retainsSidebarViewportLayout ? "column" : "row", view: self,
                sameBounds: laidOutBounds == bounds && laidOutVisibleRect == visible,
                sameContent: laidOutRowRevision == rowContentRevision && laidOutModelRevision == modelRevision)
            if laidOutBounds == bounds, laidOutRowRevision == rowContentRevision,
               laidOutModelRevision == modelRevision,
               laidOutVisibleRect == visible,
               retainsSidebarViewportLayout || NativeSidebarResizeActivity.shared.deferUnchangedLayout(self, duringScroll: true) {
                // The column's layout inputs are its root and visible row band.
                // AppKit can also ask it to lay out when the workspace regains
                // focus. The individual row hosts still own their own updates.
                return
            }
            let revision = rowContentRevision, geometry = bounds
            let start = layoutProfile?.beginLayout(self)
            super.layout()
            if let start { layoutProfile?.endLayout(start) }
            laidOutBounds = geometry; laidOutRowRevision = revision; laidOutModelRevision = modelRevision
            laidOutVisibleRect = visible
            return
        }
        guard let profile = layoutProfile else { super.layout(); return }
        let start = profile.beginLayout(self)
        super.layout()
        profile.endLayout(start)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    func commitSidebarResizeLayout() { layoutSubtreeIfNeeded() }
}

struct NativeTimelineMixerRowSpec<Version: Equatable> {
    let id: Int
    let frame: CGRect
    let version: Version
    var retained = false
    var libraryDrop: NativeLibraryTrackDrop?
}

@MainActor private protocol TimelineMixerLibraryDropRows: AnyObject {
    func libraryDropOperation(_ sender: NSDraggingInfo) -> NSDragOperation
    func acceptLibraryDrop(_ sender: NSDraggingInfo) -> Bool
}

@MainActor private protocol TimelineMixerLibraryDropHost: AnyObject {
    var libraryDropRows: TimelineMixerLibraryDropRows? { get set }
}

/// Independently retained row roots prevent selection/layout changes in one
/// track from walking the SwiftUI controls in every other warm row.
struct NativeTimelineMixerRows<Version: Equatable, Content: View>: NSViewRepresentable {
    let size: CGSize
    let rows: [NativeTimelineMixerRowSpec<Version>]
    var followsContainerWidth = false
    var limitsWidthToViewport = false
    var limitsVisibilityToViewport = false
    @ViewBuilder let content: (Int) -> Content
    @Environment(\.openFX) private var openFX
    @Environment(\.openClipFXChain) private var openClipFX
    @Environment(\.editTextItem) private var editText
    @Environment(\.editTrackDetails) private var editTrack
    @Environment(\.gridInteractionBlocked) private var blocked
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> NSView { TimelineMixerRowsNativeView<Version>() }
    func updateNSView(_ native: NSView, context: Context) {
        guard let view = native as? TimelineMixerRowsNativeView<Version> else { return }
        view.followsContainerWidth = followsContainerWidth
        view.limitsWidthToViewport = limitsWidthToViewport
        view.limitsVisibilityToViewport = limitsVisibilityToViewport
        let actions = view.actions
        actions.fx = openFX; actions.clipFX = openClipFX; actions.text = editText; actions.trackDetails = editTrack
        let environment = AnyHashable(WorkspaceHostingIdentity(content: 0, locale: locale.identifier,
            colorScheme: colorScheme, interactionBlocked: blocked))
        view.update(rows: rows, environment: environment) { index in
            AnyView(GridHostedContent(content: content(index), gridInteractionBlocked: blocked,
                locale: locale, colorScheme: colorScheme, openFX: actions.openFX,
                openClipFXChain: actions.openClipFX, editTextItem: actions.editText, editTrackDetails: actions.editTrack))
        }
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: followsContainerWidth ? (proposal.width ?? size.width) : size.width, height: size.height)
    }
}
private final class TimelineMixerRowsNativeView<Version: Equatable>: NSView, TimelineMixerLibraryDropRows {
    let actions = GridHostedActions()
    private struct Row {
        let host: WorkspaceHostingView<AnyView>
        var frame: CGRect
        var version: Version
        var environment: AnyHashable
        var retained: Bool
        var libraryDrop: NativeLibraryTrackDrop?
    }
    private var mounted: [Int: Row] = [:]
    var followsContainerWidth = false
    var limitsWidthToViewport = false
    var limitsVisibilityToViewport = false
    private weak var widthClip: NSClipView?
    private var widthObservations: [NSObjectProtocol] = []
    private var accessibilityObservations: [NSKeyValueObservation] = []
    private var retainsAccessibilityRows = false
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    override init(frame: NSRect) {
        super.init(frame: frame); autoresizesSubviews = false
        updateAccessibility()
        accessibilityObservations = [\NSWorkspace.isVoiceOverEnabled, \NSWorkspace.isSwitchControlEnabled].map { key in
            NSWorkspace.shared.observe(key, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateAccessibility(); self?.placeRowWidths() }
            }
        }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func libraryRow(at windowPoint: NSPoint) -> Row? {
        mounted.values.first { row in
            let point = row.host.convert(windowPoint, from: nil)
            return row.libraryDrop != nil && !row.host.isHiddenOrHasHiddenAncestor && row.host.visibleRect.contains(point)
        }
    }
    func libraryDropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let row = libraryRow(at: sender.draggingLocation) else { return [] }
        return row.libraryDrop?.operation(for: sender, in: row.host) ?? []
    }
    func acceptLibraryDrop(_ sender: NSDraggingInfo) -> Bool {
        guard let row = libraryRow(at: sender.draggingLocation) else { return false }
        return row.libraryDrop?.perform(sender, in: row.host) ?? false
    }
    func update(rows: [NativeTimelineMixerRowSpec<Version>], environment: AnyHashable, content: (Int) -> AnyView) {
        let wanted = Set(rows.map(\.id))
        for id in Array(mounted.keys) where !wanted.contains(id) { mounted.removeValue(forKey: id)?.host.removeFromSuperview() }
        for (index, spec) in rows.enumerated() {
            if var row = mounted[spec.id] {
                row.libraryDrop = spec.libraryDrop
                if row.version != spec.version || row.environment != environment {
                    row.host.updateRowContent(content(index)); row.version = spec.version; row.environment = environment
                }
                row.frame = spec.frame
                row.retained = spec.retained; mounted[spec.id] = row
            } else {
                let host = WorkspaceHostingView(rootView: content(index))
                host.retainsSidebarLayout = true
                if #available(macOS 13, *) { host.sizingOptions = [] }
                if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
                mounted[spec.id] = Row(host: host, frame: spec.frame, version: spec.version,
                    environment: environment, retained: spec.retained, libraryDrop: spec.libraryDrop)
                addSubview(host)
            }
        }
        placeRowWidths()
    }
    override func layout() {
        super.layout()
        placeRowWidths()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeWidthClip(); registerLibraryDropHost() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeWidthClip(); registerLibraryDropHost() }
    private func registerLibraryDropHost() {
        var ancestor = superview
        while let view = ancestor {
            if let host = view as? TimelineMixerLibraryDropHost {
                host.libraryDropRows = self
                return
            }
            ancestor = view.superview
        }
    }
    private func observeWidthClip() {
        let clip = window == nil ? nil : enclosingScrollView?.contentView
        guard widthClip !== clip else { return }
        widthObservations.forEach(NotificationCenter.default.removeObserver)
        widthObservations.removeAll(); widthClip = clip
        if let clip {
            updateAccessibility()
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                widthObservations.append(NotificationCenter.default.addObserver(forName: name,
                object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.placeRowWidths() }
                })
            }
            widthObservations.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let wasRetaining = self.retainsAccessibilityRows
                        self.updateAccessibility()
                        if wasRetaining != self.retainsAccessibilityRows { self.placeRowWidths() }
                    }
                })
        }
        placeRowWidths()
    }
    private func placeRowWidths() {
        let visible = widthClip.map { convert($0.bounds, from: $0) }
        let revealBand = visible?.insetBy(dx: 0, dy: -256)
        let retainBand = visible?.insetBy(dx: 0, dy: -512)
        let responder = window?.firstResponder as? NSView
        for row in mounted.values {
            // Setting an NSHostingView's frame still invalidates SwiftUI while
            // hidden. Use the current row geometry to decide which warm roots
            // to resize, then place each incoming row before revealing it.
            var frame = row.frame
            let band = row.host.isHidden ? revealBand : retainBand
            let outside = limitsVisibilityToViewport && band?.intersects(frame) == false
            let hidden = outside && !row.retained && !retainsAccessibilityRows &&
                responder !== row.host && responder?.isDescendant(of: row.host) != true
            if hidden {
                if !row.host.isHidden { row.host.isHidden = true }
                continue
            }
            if followsContainerWidth, bounds.width > 0 {
                if !limitsWidthToViewport || visible?.intersects(frame) != false {
                    frame.size.width = bounds.width
                } else if row.host.frame.width > 0 {
                    frame.size.width = row.host.frame.width
                }
            }
            if row.host.frame != frame { row.host.frame = frame }
            if row.host.isHidden { row.host.isHidden = false }
        }
    }
    private func updateAccessibility() {
        retainsAccessibilityRows = NSApp.isFullKeyboardAccessEnabled || NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    }
    deinit { widthObservations.forEach(NotificationCenter.default.removeObserver) }
}

private struct WorkspaceHostingIdentity: Hashable {
    let content: AnyHashable
    let locale: String
    let colorScheme: ColorScheme
    let interactionBlocked: Bool
}

/// Keep the sidebar's controls at their last usable size while closed.
/// Only the dock's contribution to the workspace width becomes zero.
struct RetainedWorkspacePane<Content: View>: NSViewRepresentable {
    let width: CGFloat
    let visible: Bool
    let identity: AnyHashable
    @ViewBuilder let content: () -> Content
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.gridInteractionBlocked) private var blocked
    @Environment(\.openFX) private var openFX
    @Environment(\.openClipFXChain) private var openClipFXChain
    @Environment(\.editTextItem) private var editTextItem
    @Environment(\.editTrackDetails) private var editTrackDetails

    func makeNSView(context: Context) -> RetainedWorkspacePaneView { RetainedWorkspacePaneView() }

    func updateNSView(_ view: RetainedWorkspacePaneView, context: Context) {
        let actions = view.actions
        actions.fx = openFX
        actions.clipFX = openClipFXChain
        actions.text = editTextItem
        actions.trackDetails = editTrackDetails
        let key = WorkspaceHostingIdentity(content: identity, locale: locale.identifier,
            colorScheme: colorScheme, interactionBlocked: blocked)
        view.update(visible: visible, identity: AnyHashable(key)) {
            AnyView(GridHostedContent(content: content(), gridInteractionBlocked: blocked,
                locale: locale, colorScheme: colorScheme, openFX: actions.openFX,
                openClipFXChain: actions.openClipFX, editTextItem: actions.editText,
                editTrackDetails: actions.editTrack))
        }
    }

    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RetainedWorkspacePaneView, context: Context) -> CGSize? {
        CGSize(width: visible ? width : 0, height: max(0, proposal.height ?? nsView.bounds.height))
    }
}

final class RetainedWorkspacePaneView: NSView {
    fileprivate let actions = GridHostedActions()
    private var host: WorkspaceHostingView<AnyView>?
    private var identity: AnyHashable?
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func update(visible: Bool, identity: AnyHashable, makeContent: () -> AnyView) {
        guard visible else {
            if let host, !host.isHidden {
                if let window, let responder = window.firstResponder as? NSView,
                   responder === host || responder.isDescendant(of: host) {
                    window.makeFirstResponder(nil)
                }
                host.isHidden = true
            }
            return
        }
        if let host {
            if self.identity != identity { host.rootView = makeContent() }
            if host.isHidden { host.isHidden = false; needsLayout = true }
        } else {
            let host = WorkspaceHostingView(rootView: makeContent())
            host.defersHiddenLayout = true
            if #available(macOS 13, *) { host.sizingOptions = [] }
            if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
            addSubview(host)
            self.host = host
            needsLayout = true
        }
        self.identity = identity
    }

    override func layout() {
        super.layout()
        if let host, !host.isHidden, bounds.width > 0, host.frame != bounds { host.frame = bounds }
    }
}

/// The workspace divider changes native sibling frames without publishing a
/// new MainView layout for every pointer event. Both hosting roots stay alive.
struct NativeWorkspaceSplit<Leading: View, Trailing: View>: NSViewRepresentable {
    let width: CGFloat
    let restoreWidth: CGFloat
    let minimum: CGFloat
    var minimumTimelineWidth: CGFloat = 420
    let scrollController: SidebarScrollController
    var sidebarLeading = false
    var sidebarDetached = false
    var contentIdentity: AnyHashable? = nil
    var trailingContentIdentity: AnyHashable? = nil
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
    private func hostingIdentity(_ content: AnyHashable?) -> AnyHashable? {
        content.map { AnyHashable(WorkspaceHostingIdentity(content: $0,
            locale: locale.identifier, colorScheme: colorScheme, interactionBlocked: gridInteractionBlocked)) }
    }
    func makeNSView(context: Context) -> NSView {
        let actions = GridHostedActions()
        updateActions(actions)
        let view = WorkspaceSplitView(actions: actions, leading: hosted(leading(), actions: actions),
                                      trailing: hosted(trailing(), actions: actions))
        view.leadingIdentity = hostingIdentity(contentIdentity)
        view.trailingIdentity = hostingIdentity(trailingContentIdentity ?? contentIdentity)
        view.configure(width: width, restoreWidth: restoreWidth, minimum: minimum, minimumTimelineWidth: minimumTimelineWidth,
                       sidebarLeading: sidebarLeading, sidebarDetached: sidebarDetached,
                       scrollController: scrollController, onToggle: onToggle, onEnd: onEnd)
        return view
    }
    func updateNSView(_ native: NSView, context: Context) {
        guard let view = native as? WorkspaceSplitView<Leading, Trailing> else { return }
        updateActions(view.actions)
        view.updateLeading(identity: hostingIdentity(contentIdentity)) { hosted(leading(), actions: view.actions) }
        view.updateTrailing(identity: hostingIdentity(trailingContentIdentity ?? contentIdentity)) {
            hosted(trailing(), actions: view.actions)
        }
        view.configure(width: width, restoreWidth: restoreWidth, minimum: minimum, minimumTimelineWidth: minimumTimelineWidth,
                       sidebarLeading: sidebarLeading, sidebarDetached: sidebarDetached,
                       scrollController: scrollController, onToggle: onToggle, onEnd: onEnd)
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? nsView.frame.height)
    }
}

private protocol TimelineSetlistResizeHost: AnyObject {
    var trailingSetlistDivider: MixerDividerView? { get }
}

private final class WorkspaceSplitView<Leading: View, Trailing: View>: NSView, TimelineSetlistResizeHost, NativeTimelineBodyInputHost, NativeTimelineInputObserver, NativeTimelineDefaultCursorHost {
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
    private var minimumTimelineWidth: CGFloat = 420
    private var sidebarLeading = false
    private var sidebarDetached = false
    private var liveWidth: CGFloat?
    private var pendingSavedWidth: CGFloat?
    private var footerResizeHeight: CGFloat?
    @objc private func footerResizeBegan(_ notification: Notification) { footerResizeHeight = bounds.height }
    @objc private func footerResizeEnded(_ notification: Notification) {
        footerResizeHeight = nil; needsLayout = true
    }
    private var resizing = false
    private var applyingFrames = false
    private var onEnd: (CGFloat) -> Void = { _ in }
    fileprivate var trailingSetlistDivider: MixerDividerView? {
        !sidebarLeading && !sidebarDetached ? divider : nil
    }
    private let dividerWidth: CGFloat = 6

    init(actions: GridHostedActions, leading: GridHostedContent<Leading>, trailing: GridHostedContent<Trailing>) {
        self.actions = actions
        self.leading = WorkspaceHostingView(rootView: leading)
        self.trailing = WorkspaceHostingView(rootView: trailing)
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        autoresizesSubviews = false
        if #available(macOS 13, *) { self.leading.sizingOptions = []; self.trailing.sizingOptions = [] }
        if #available(macOS 13.3, *) { self.leading.safeAreaRegions = []; self.trailing.safeAreaRegions = [] }
        self.leading.layoutProfile = TimelineLayoutDiagnostics.make("workspace-timeline")
        self.trailing.layoutProfile = TimelineLayoutDiagnostics.make("workspace-setlist")
        self.trailing.defersHiddenLayout = true
        self.leading.layoutProfile?.rootAssigned(self.leading)
        self.trailing.layoutProfile?.rootAssigned(self.trailing)
        self.leading.identifier = NSUserInterfaceItemIdentifier("workspace-timeline")
        self.trailing.identifier = NSUserInterfaceItemIdentifier("workspace-setlist")
        addSubview(self.leading); addSubview(divider); addSubview(self.trailing)
        divider.direction = -1
        divider.showsScrollRail = false
        divider.showsRail = false
        divider.setAccessibilityElement(true)
        divider.setAccessibilityRole(.splitter)
        divider.setAccessibilityLabel("Resize setlist")
        divider.retainsTimelineCoverage = true
        divider.maximumResizeFrequency = 60
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

    var leadingIdentity: AnyHashable?
    var trailingIdentity: AnyHashable?
    func updateLeading(identity: AnyHashable?, content: () -> GridHostedContent<Leading>) {
        if let identity, leadingIdentity == identity { return }
        leadingIdentity = identity
        leading.layoutProfile?.rootAssigned(leading)
        leading.rootView = content()
    }
    func updateTrailing(identity: AnyHashable?, content: () -> GridHostedContent<Trailing>) {
        // Library and mixer visibility changes don't modify Setlist content.
        // Keep its root and input state while the workspace reserves its size.
        if let identity, trailingIdentity == identity { return }
        trailingIdentity = identity
        trailing.layoutProfile?.rootAssigned(trailing)
        trailing.rootView = content()
    }
    func configure(width: CGFloat, restoreWidth: CGFloat, minimum: CGFloat, minimumTimelineWidth: CGFloat,
                   sidebarLeading: Bool, sidebarDetached: Bool,
                   scrollController: SidebarScrollController, onToggle: @escaping () -> Void,
                   onEnd: @escaping (CGFloat) -> Void) {
        // An unrelated parent update during tracking still carries the last
        // saved width. Only acknowledge the final value or a newer external edit.
        if let pendingSavedWidth, width == pendingSavedWidth || width != savedWidth { self.pendingSavedWidth = nil }
        savedWidth = width; self.restoreWidth = restoreWidth; self.minimum = minimum
        self.minimumTimelineWidth = minimumTimelineWidth
        if self.sidebarLeading != sidebarLeading || self.sidebarDetached != sidebarDetached {
            resizing = false; liveWidth = nil; pendingSavedWidth = nil
        }
        self.sidebarLeading = sidebarLeading; self.sidebarDetached = sidebarDetached
        divider.direction = sidebarLeading ? 1 : -1
        self.onEnd = onEnd
        divider.scrollController = scrollController; divider.onToggle = onToggle
        applyFrames(layoutHosts: false)
    }
    override func layout() {
        super.layout()
        // AppKit lays out dirty descendants after applying these frames. A
        // timeline-only update must not explicitly walk the setlist host too.
        // Divider tracking shares the normal display pass; release commits
        // the final geometry through resizeLayout.
        applyFrames(layoutHosts: false)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        for name in ["CatLiveFooterResizeBegan", "CatLiveFooterResizeEnded"] {
            NotificationCenter.default.removeObserver(self, name: Notification.Name(name), object: nil)
        }
        footerResizeHeight = nil
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(footerResizeBegan(_:)),
                name: Notification.Name("CatLiveFooterResizeBegan"), object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(footerResizeEnded(_:)),
                name: Notification.Name("CatLiveFooterResizeEnded"), object: window)
            NativeTimelineInputGate.shared.add(self)
            NotificationCenter.default.addObserver(self, selector: #selector(workspaceWindowBecameKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: window)
        }
        if window == nil {
            resizing = false; liveWidth = nil; pendingSavedWidth = nil
        }
    }
    private func applyFrames(layoutHosts: Bool) {
        guard !applyingFrames else { return }
        applyingFrames = true
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled); applyingFrames = false }
        let available = bounds.size
        // Growing the footer only crops this workspace. Keep its timeline and
        // Setlist layout stable until release rather than rebuilding all rows
        // for each vertical pixel. If more space is exposed, grow once to cover it.
        if let height = footerResizeHeight { footerResizeHeight = max(height, available.height) }
        let hostedHeight = footerResizeHeight ?? available.height
        let maximum = max(0, min(486.5, available.width - minimumTimelineWidth))
        func bounded(_ width: CGFloat) -> CGFloat { width <= 0 ? 0 : min(maximum, max(minimum, width)) }
        let visibleWidth = sidebarDetached ? 0 : bounded((resizing ? liveWidth : nil) ?? pendingSavedWidth ?? savedWidth)
        let barWidth = sidebarLeading && !sidebarDetached ? dividerWidth : 0
        let primaryWidth = max(0, available.width - visibleWidth - barWidth)
        let mountedWidth = visibleWidth > 0 ? visibleWidth : bounded(max(minimum, restoreWidth))
        divider.minimum = minimum; divider.maximum = maximum; divider.columnWidth = visibleWidth
        // The hosts retain their identities when changing sides. Only native
        // sibling frames move, so Setlist selection and timeline focus survive.
        let leftFrame = CGRect(x: sidebarLeading ? visibleWidth + barWidth : 0, y: 0,
                               width: primaryWidth, height: hostedHeight)
        let barFrame = CGRect(x: sidebarLeading ? visibleWidth : primaryWidth, y: 0,
                              width: barWidth, height: available.height)
        let rightFrame = CGRect(x: sidebarLeading ? 0 : primaryWidth + barWidth, y: 0,
                                width: mountedWidth, height: hostedHeight)
        if leading.frame.size != leftFrame.size {
            leading.layoutProfile?.sizeChanged(leading, from: leading.frame.size, to: leftFrame.size)
            leading.frame = leftFrame
            leading.needsLayout = true
        } else if leading.frame.origin != leftFrame.origin {
            leading.setFrameOrigin(leftFrame.origin)
        }
        if divider.frame != barFrame { divider.frame = barFrame }
        if trailing.frame.size != rightFrame.size {
            trailing.layoutProfile?.sizeChanged(trailing, from: trailing.frame.size, to: rightFrame.size)
            trailing.frame = rightFrame
            trailing.needsLayout = true
        } else if trailing.frame.origin != rightFrame.origin {
            trailing.setFrameOrigin(rightFrame.origin)
        }
        let hidesSetlist = visibleWidth <= 0
        if trailing.isHidden != hidesSetlist { trailing.isHidden = hidesSetlist }
        let hidesDivider = barWidth == 0
        if divider.isHidden != hidesDivider { divider.isHidden = hidesDivider }
        if layoutHosts {
            leading.layoutSubtreeIfNeeded()
            if !trailing.isHidden { trailing.layoutSubtreeIfNeeded() }
        }
    }
}

private protocol NativeTimelineMixerWidthTarget: AnyObject {
    func mixerWidthChanged()
}

/// The document columns and the pinned header share actual native frames.
/// A drag does not replace the vertical scroll/timeline SwiftUI roots per pixel.
final class NativeTimelineMixerWidth {
    private(set) var width: CGFloat?
    private(set) var resizing = false
    private let targets = NSHashTable<AnyObject>.weakObjects()
    fileprivate func add(_ target: NativeTimelineMixerWidthTarget) { targets.add(target) }
    fileprivate func remove(_ target: NativeTimelineMixerWidthTarget) { targets.remove(target) }
    func begin(width: CGFloat) { resizing = true; update(width) }
    func update(_ width: CGFloat) {
        guard self.width != width else { return }
        self.width = width
        for case let target as NativeTimelineMixerWidthTarget in targets.allObjects { target.mixerWidthChanged() }
    }
    func finish(width: CGFloat) { update(width); resizing = false }
    func cancel() {
        resizing = false; width = nil
        for case let target as NativeTimelineMixerWidthTarget in targets.allObjects { target.mixerWidthChanged() }
    }
    /// Keep the final native position until SwiftUI acknowledges the saved width.
    func acknowledge(_ savedWidth: CGFloat) {
        if !resizing, width == savedWidth { width = nil }
    }
}

struct NativeTimelineMixerOverlay<Header: View>: NSViewRepresentable {
    let width: CGFloat
    let maximum: CGFloat
    let minimum: CGFloat
    let dividerWidth: CGFloat
    let headerHeight: CGFloat
    let liveWidth: NativeTimelineMixerWidth
    var onStart: () -> Void = {}
    var onWidthModeChanged: (CGFloat) -> Void = { _ in }
    var onToggle: () -> Void = {}
    var onCancel: () -> Void = {}
    let onEnd: (CGFloat) -> Void
    @ViewBuilder let header: () -> Header
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.gridInteractionBlocked) private var blocked
    @Environment(\.openFX) private var openFX
    @Environment(\.openClipFXChain) private var openClipFX
    @Environment(\.editTextItem) private var editText
    @Environment(\.editTrackDetails) private var editTrack
    private func content() -> GridHostedContent<Header> {
        GridHostedContent(content: header(), gridInteractionBlocked: blocked, locale: locale,
            colorScheme: colorScheme, openFX: openFX, openClipFXChain: openClipFX,
            editTextItem: editText, editTrackDetails: editTrack)
    }
    func makeNSView(context: Context) -> NSView {
        let view = TimelineMixerOverlayView(header: content())
        configure(view)
        return view
    }
    func updateNSView(_ native: NSView, context: Context) {
        guard let view = native as? TimelineMixerOverlayView<Header> else { return }
        view.header.rootView = content()
        configure(view)
    }
    private func configure(_ view: TimelineMixerOverlayView<Header>) {
        view.configure(width: width, maximum: maximum, minimum: minimum, dividerWidth: dividerWidth,
                       headerHeight: headerHeight, liveWidth: liveWidth, onStart: onStart,
                       onWidthModeChanged: onWidthModeChanged, onToggle: onToggle, onCancel: onCancel, onEnd: onEnd)
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: nsView.frame.size)
    }
}

private final class TimelineMixerOverlayView<Header: View>: NSView, NativeTimelineMixerWidthTarget {
    let header: WorkspaceHostingView<GridHostedContent<Header>>
    let divider = MixerDividerView()
    private var liveWidth: NativeTimelineMixerWidth?
    private var savedWidth: CGFloat = 0
    private var dividerWidth: CGFloat = 6
    private var headerHeight: CGFloat = 0
    private var widthMode = false
    private var onStart: () -> Void = {}
    private var onWidthModeChanged: (CGFloat) -> Void = { _ in }
    private var onEnd: (CGFloat) -> Void = { _ in }
    private var onCancel: () -> Void = {}
    init(header: GridHostedContent<Header>) {
        self.header = WorkspaceHostingView(rootView: header)
        super.init(frame: .zero)
        autoresizesSubviews = false
        if #available(macOS 13, *) { self.header.sizingOptions = [] }
        if #available(macOS 13.3, *) { self.header.safeAreaRegions = [] }
        self.header.identifier = NSUserInterfaceItemIdentifier("mixer-pinned-header")
        addSubview(self.header); addSubview(divider)
        divider.setAccessibilityElement(true); divider.setAccessibilityRole(.splitter)
        divider.setAccessibilityLabel("Resize mixer")
        divider.showsScrollRail = false
        divider.showsRail = false
        divider.maximumResizeFrequency = 60
        divider.onStart = { [weak self] in
            guard let self else { return }
            self.widthMode = self.divider.columnWidth >= 180
            self.liveWidth?.begin(width: self.divider.columnWidth)
            self.onStart()
        }
        divider.onResize = { [weak self] width in
            guard let self else { return }
            self.liveWidth?.update(width)
            if self.widthMode != (width >= 180) {
                self.widthMode = width >= 180; self.onWidthModeChanged(width)
            }
        }
        divider.onEnd = { [weak self] width in
            guard let self else { return }
            self.liveWidth?.finish(width: width); self.onEnd(width)
        }
        divider.onCancel = { [weak self] in
            guard let self else { return }
            self.liveWidth?.cancel(); self.onCancel()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { NativeTimelineOverlayInputRegistration.addPinnedControls(header) }
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if divider.frame.contains(local) { return divider.hitTest(local) }
        if !header.isHidden, header.frame.contains(local) { return header.hitTest(local) }
        return nil
    }
    func configure(width: CGFloat, maximum: CGFloat, minimum: CGFloat, dividerWidth: CGFloat,
                   headerHeight: CGFloat, liveWidth: NativeTimelineMixerWidth, onStart: @escaping () -> Void,
                   onWidthModeChanged: @escaping (CGFloat) -> Void, onToggle: @escaping () -> Void,
                   onCancel: @escaping () -> Void, onEnd: @escaping (CGFloat) -> Void) {
        if !liveWidth.resizing, width != savedWidth { liveWidth.cancel() }
        savedWidth = width; self.dividerWidth = dividerWidth; self.headerHeight = headerHeight
        self.onStart = onStart; self.onWidthModeChanged = onWidthModeChanged; self.onEnd = onEnd
        self.onCancel = onCancel
        if self.liveWidth !== liveWidth {
            self.liveWidth?.remove(self); self.liveWidth = liveWidth; liveWidth.add(self)
        }
        liveWidth.acknowledge(width)
        divider.maximum = maximum; divider.minimum = minimum; divider.onToggle = onToggle
        applyFrames()
    }
    func mixerWidthChanged() { applyFrames() }
    override func layout() { super.layout(); applyFrames() }
    private func applyFrames() {
        let width = liveWidth?.width ?? savedWidth
        let disabled = CATransaction.disableActions(); CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        let headerFrame = CGRect(x: 0, y: 0, width: max(0, width), height: headerHeight)
        let dividerFrame = CGRect(x: width, y: 0, width: dividerWidth, height: bounds.height)
        if header.frame != headerFrame { header.frame = headerFrame }
        if divider.frame != dividerFrame { divider.frame = dividerFrame }
        header.isHidden = width <= 0; divider.columnWidth = width
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
    var liveWidth: NativeTimelineMixerWidth? = nil
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
    @AppStorage(JarasInterfaceTheme.preferenceKey) private var mixerTheme = JarasInterfaceTheme.defaultTheme

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
            interactionBlocked: gridInteractionBlocked)
    }
    func makeNSView(context: Context) -> NSView {
        let actions = GridHostedActions()
        updateActions(actions)
        let view = TimelineColumnsNativeView(actions: actions,
            mixer: hosted(mixer(), actions: actions), divider: hosted(divider(), actions: actions),
            timeline: hosted(timeline(), actions: actions), identity: identity)
        view.setMixerBackground(mixerTheme.panelHex)
        view.configure(mixerWidth: mixerWidth, viewportWidth: viewportWidth, height: height, dividerWidth: dividerWidth, liveWidth: liveWidth)
        return view
    }
    func updateNSView(_ native: NSView, context: Context) {
        guard let view = native as? TimelineColumnsNativeView<Mixer, Divider, Timeline, Identity> else { return }
        updateActions(view.actions)
        view.updateContent(mixer: hosted(mixer(), actions: view.actions),
            divider: hosted(divider(), actions: view.actions), timeline: hosted(timeline(), actions: view.actions),
            identity: identity)
        view.setMixerBackground(mixerTheme.panelHex)
        view.configure(mixerWidth: mixerWidth, viewportWidth: viewportWidth, height: height, dividerWidth: dividerWidth, liveWidth: liveWidth)
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? viewportWidth, height: height)
    }
}

private struct TimelineColumnsMixerIdentity<Content: Equatable>: Equatable {
    let content: Content
    let project: UUID
    let locale: String
    let colorScheme: ColorScheme
    let interactionBlocked: Bool
}

private final class TimelineMixerBackingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class TimelineColumnsNativeView<Mixer: View, Divider: View, Timeline: View, Identity: Equatable>: NSView, NativeTimelineBodyInputHost, NativeTimelineMixerWidthTarget, TimelineMixerLibraryDropHost {
    weak var libraryDropRows: TimelineMixerLibraryDropRows?
    weak var timelineBodyInput: (NSView & NativeTimelineBodyInput)?
    // Keep the drag target outside the individual hosting views. AppKit can
    // hit a row's native control directly, including recycled row controls.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        libraryDropRows?.libraryDropOperation(sender) ?? []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        libraryDropRows?.acceptLibraryDrop(sender) ?? false
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        timelineBodyHit(at: point) ?? timelineControlHit(at: point) ?? super.hitTest(point)
    }
    let actions: GridHostedActions
    let mixerHost: WorkspaceHostingView<GridHostedContent<Mixer>>
    let dividerHost: WorkspaceHostingView<GridHostedContent<Divider>>
    let timelineHost: WorkspaceHostingView<GridHostedContent<Timeline>>
    private var mixerIdentity: TimelineColumnsMixerIdentity<Identity>
    private let mixerBacking = TimelineMixerBackingView()
    private var mixerBackground: UInt32?
    private var mixerWidth: CGFloat = 0
    private var viewportWidth: CGFloat = 0
    private var documentHeight: CGFloat = 0
    private var dividerWidth: CGFloat = 0
    private var liveWidth: NativeTimelineMixerWidth?

    init(actions: GridHostedActions, mixer: GridHostedContent<Mixer>, divider: GridHostedContent<Divider>,
         timeline: GridHostedContent<Timeline>, identity: TimelineColumnsMixerIdentity<Identity>) {
        self.actions = actions; mixerIdentity = identity
        mixerHost = WorkspaceHostingView(rootView: mixer)
        mixerHost.retainsSidebarViewportLayout = true
        dividerHost = WorkspaceHostingView(rootView: divider)
        timelineHost = WorkspaceHostingView(rootView: timeline)
        super.init(frame: .zero)
        registerForDraggedTypes([NativeLibraryTrackDrop.type])
        wantsLayer = true; autoresizesSubviews = false
        mixerHost.defersHiddenLayout = true
        mixerBacking.identifier = NSUserInterfaceItemIdentifier("track-mixer-background")
        mixerBacking.wantsLayer = true
        addSubview(mixerBacking)
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
    override var fittingSize: NSSize { CGSize(width: bounds.width > 0 ? bounds.width : viewportWidth, height: documentHeight) }

    func setMixerBackground(_ color: UInt32) {
        guard mixerBackground != color else { return }
        mixerBackground = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mixerBacking.layer?.backgroundColor = NSColor(srgbRed: CGFloat(color >> 16 & 255) / 255,
            green: CGFloat(color >> 8 & 255) / 255, blue: CGFloat(color & 255) / 255, alpha: 1).cgColor
        CATransaction.commit()
    }

    func updateContent(mixer: @autoclosure () -> GridHostedContent<Mixer>, divider: GridHostedContent<Divider>,
                       timeline: GridHostedContent<Timeline>, identity: TimelineColumnsMixerIdentity<Identity>) {
        if mixerIdentity != identity {
            mixerIdentity = identity
            mixerHost.layoutProfile?.rootAssigned(mixerHost)
            mixerHost.updateRowContent(mixer())
        }
        dividerHost.layoutProfile?.rootAssigned(dividerHost)
        dividerHost.rootView = divider
        timelineHost.layoutProfile?.rootAssigned(timelineHost)
        timelineHost.rootView = timeline
    }
    func configure(mixerWidth: CGFloat, viewportWidth: CGFloat, height: CGFloat, dividerWidth: CGFloat, liveWidth: NativeTimelineMixerWidth?) {
        self.mixerWidth = mixerWidth; self.viewportWidth = viewportWidth
        documentHeight = height; self.dividerWidth = dividerWidth
        if self.liveWidth !== liveWidth {
            self.liveWidth?.remove(self); self.liveWidth = liveWidth; liveWidth?.add(self)
        }
        applyFrames()
    }
    func mixerWidthChanged() { applyFrames() }
    override func layout() {
        super.layout()
        applyFrames()
    }
    private func applyFrames() {
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        let mixerWidth = liveWidth?.width ?? self.mixerWidth
        let viewportWidth = bounds.width > 0 ? bounds.width : self.viewportWidth
        func update<Content: View>(_ host: WorkspaceHostingView<Content>, frame: CGRect) {
            guard host.frame != frame else { return }
            host.layoutProfile?.sizeChanged(host, from: host.frame.size, to: frame.size)
            host.frame = frame
        }
        let mixerFrame = CGRect(x: 0, y: 0, width: max(0, mixerWidth), height: documentHeight)
        if mixerBacking.frame != mixerFrame { mixerBacking.frame = mixerFrame }
        // Collapsing the mixer only uncovers the timeline. A hidden zero-width
        // proposal would lay out every row twice across a close/open cycle.
        if mixerWidth > 0 { update(mixerHost, frame: mixerFrame) }
        if mixerHost.isHidden != (mixerWidth <= 0) { mixerHost.isHidden = mixerWidth <= 0 }
        update(dividerHost, frame: CGRect(x: mixerWidth, y: 0, width: dividerWidth, height: documentHeight))
        update(timelineHost, frame: CGRect(x: mixerWidth + dividerWidth, y: 0,
            width: max(0, viewportWidth - mixerWidth - dividerWidth), height: documentHeight))
        // Do not synchronously lay out both sibling hosts here. A zoom changes
        // only the timeline's descendants; AppKit processes that dirty subtree.
    }
}


private struct NativeGridScroll<Content: View>: NSViewRepresentable {
    struct RootIdentity: Equatable {
        let content: UUID
        let viewport: CGFloat?
        let blocked: Bool
        let locale: Locale
        let colorScheme: ColorScheme
    }
    private let contentGeneration = UUID()
    private var rootIdentity: RootIdentity {
        RootIdentity(content: contentGeneration, viewport: hostedViewportWidth, blocked: gridInteractionBlocked,
                     locale: locale, colorScheme: colorScheme)
    }
    final class Coordinator {
        var lastRoot: RootIdentity?
        let actions = GridHostedActions()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    let horizontal: Bool
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    var viewportWidth: CGFloat? = nil
    var trackHeight: CGFloat? = nil
    var timelineVerticalBarTop: CGFloat? = nil
    var rowHeights: [CGFloat] = []
    var selectedRow: Int? = nil
    var rowReveal: GridRowReveal? = nil
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
    private func bindActions(_ coordinator: Coordinator) {
        coordinator.actions.fx = openFX; coordinator.actions.clipFX = openClipFXChain; coordinator.actions.text = editTextItem
        coordinator.actions.trackDetails = editTrackDetails
    }
    private func hosted(_ coordinator: Coordinator) -> GridHostedContent<Content> {
        GridHostedContent(content: content, viewportWidth: hostedViewportWidth, gridInteractionBlocked: gridInteractionBlocked,
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
        scroll.contentView = TimelineClipView(leadingSpace: horizontal ? TimelineAppearanceDefaults.leadingSpace : 0)
        if horizontal {
            scroll.registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType(LibrarySamplerTransfer.type.identifier)])
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
        bindActions(context.coordinator)
        context.coordinator.lastRoot = rootIdentity
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
        document.followsViewportWidth = !horizontal
        document.host = host; document.addSubview(host)
        scroll.hostedProjectionDidLayout = { [weak document] in document?.commitHostedProjection() ?? true }
        scroll.documentView = document
        if horizontal {
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.documentRect.minX, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        document.setHostedViewport(width: hostedViewportWidth, clip: scroll.contentView)
        if let timelineVerticalBarTop { scroll.showTimelineVerticalBar(inset: timelineVerticalBarTop) }
        return scroll
    }
    func updateNSView(_ scroll: GridNativeScrollView, context: Context) {
        guard let document = scroll.documentView as? GridDocumentView, let host = document.host as? GridHostingView<GridHostedContent<Content>> else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        scroll.fileDrop = fileDrop
        scroll.fileDropPreview = fileDropPreview
        if let trackHeight, let anchoredY = scroll.trackHeightOffset(height: trackHeight, rows: rowHeights, selected: selectedRow) {
            scroll.prepareTrackHeightAnchor(to: anchoredY, height: trackHeight)
        }
        // Update the existing, typed hosting root directly so SwiftUI can diff
        // unchanged descendants. An ObservableObject relay invalidated the
        // entire hosted root again on every parent layout/resize transaction.
        bindActions(context.coordinator)
        let identity = rootIdentity
        if context.coordinator.lastRoot != identity {
            context.coordinator.lastRoot = identity
            host.layoutProfile?.rootAssigned(host)
            host.rootView = hosted(context.coordinator)
        }
        // An internal zoom may already have committed a newer logical width
        // than this structural representable captured. Environment-only root
        // updates must preserve that width; parent row-height changes still
        // apply immediately and the live bridge commits any new zoom/extent.
        let size = NSSize(width: document.liveLogicalWidth ?? contentWidth, height: contentHeight)
        document.applySize(size, in: scroll, retainingCapacity: document.liveLogicalWidth != nil)
        let layoutSize = NSSize(width: document.followsViewportWidth ? document.frame.width : (document.liveHostedWidth ?? hostedSize.width), height: contentHeight)
        if host.frame.size != layoutSize {
            host.layoutProfile?.sizeChanged(host, from: host.frame.size, to: layoutSize)
            host.setFrameSize(layoutSize)
            host.needsLayout = true
            // SwiftUI invalidates the changed Canvas tiles. Forcing the whole
            // hosting document and clip to redraw discards their backing reuse.
        }
        document.setHostedViewport(width: hostedViewportWidth, clip: scroll.contentView)
        if let timelineVerticalBarTop { scroll.showTimelineVerticalBar(inset: timelineVerticalBarTop) }
        // Commit the viewport after the hosting view has laid out this scale.
        // Scrolling here exposed old item geometry at the next scale's origin.
        if scroll.zoomAnchor != nil { host.needsLayout = true }
        if !horizontal, let rowReveal { scroll.revealRow(rowReveal) }
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
            // Mixer/timeline colors are app-owned. Opening another tool must
            // not restyle every retained row for the main window's key state.
            .workspaceControlsAppearActive()
            .frame(width: viewportWidth, alignment: .topLeading)
    }
}
/// Explicit document geometry terminates AppKit fitting-size propagation here.
/// Rescaling the timeline must not ask the track controls and meters for sizes.
private final class GridDocumentView: NSView {
    var host: NSView?
    // A vertical document has no independent horizontal extent. Adopt the
    // actual native clip width without rebuilding its SwiftUI content root.
    var followsViewportWidth = false
    private var synchronizingViewport = false
    private weak var logicalSizeInput: GridDocumentSizeView?
    private var usesHostedViewport = false
    private weak var hostedClip: NSClipView?
    private var hostedClipObserver: NSObjectProtocol?
    private var hostedClipFrameObserver: NSObjectProtocol?
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
        if followsViewportWidth, scroll.contentView.bounds.width > 0 {
            physicalSize.width = scroll.contentView.bounds.width
        }
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
        let nextClip = usesHostedViewport || followsViewportWidth ? clip : nil
        if hostedClip !== nextClip {
            if let hostedClipObserver { NotificationCenter.default.removeObserver(hostedClipObserver) }
            if let hostedClipFrameObserver { NotificationCenter.default.removeObserver(hostedClipFrameObserver) }
            hostedClipObserver = nil
            hostedClipFrameObserver = nil
            hostedClip = nextClip
            if let nextClip {
                nextClip.postsBoundsChangedNotifications = true
                hostedClipObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: nextClip, queue: .main) { [weak self] _ in self?.synchronizeHostedViewport() }
                nextClip.postsFrameChangedNotifications = true
                hostedClipFrameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                    object: nextClip, queue: .main) { [weak self] _ in self?.synchronizeHostedViewport() }
            }
        }
        synchronizeHostedViewport()
    }

    /// Equal frame and bounds origins preserve all descendant document-space
    /// coordinates. The host itself stays over the visible range, so AppKit
    /// still reaches native controls far beyond the initial viewport.
    func synchronizeHostedViewport() {
        guard let host, !synchronizingViewport else { return }
        synchronizingViewport = true
        defer { synchronizingViewport = false }
        if followsViewportWidth, let width = hostedClip?.bounds.width, width > 0 {
            if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
            if host.frame.width != width {
                host.setFrameSize(NSSize(width: width, height: host.frame.height))
                host.needsLayout = true
            }
        }
        let origin = NSPoint(x: usesHostedViewport ? max(0, hostedClip?.bounds.minX ?? 0) : 0, y: 0)
        if host.frame.origin != origin { host.setFrameOrigin(origin) }
        if host.bounds.origin != origin { host.setBoundsOrigin(origin) }
    }

    deinit {
        if let hostedClipObserver { NotificationCenter.default.removeObserver(hostedClipObserver) }
        if let hostedClipFrameObserver { NotificationCenter.default.removeObserver(hostedClipFrameObserver) }
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
final class GridNativeScrollView: NSScrollView, NativeTimelineBodyInputHost, NativeTimelineSelectionScrollHost, NativeTimelineFollowPresentation {
    class GreenScroller: NSScroller {
        var slotColor = NSColor(white: 0.12, alpha: 1) {
            didSet { if oldValue != slotColor { needsDisplay = true } }
        }
        private func drawBar(_ rect: NSRect, color: NSColor) {
            let bar = bounds.height > bounds.width
                ? NSRect(x: bounds.midX - 3, y: rect.minY, width: 6, height: rect.height)
                : NSRect(x: rect.minX, y: bounds.midY - 3, width: rect.width, height: 6)
            color.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        }

        override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
            drawBar(slotRect, color: slotColor)
        }

        override func drawKnob() {
            drawBar(rect(for: .knob), color: NSColor(calibratedRed: 84.0 / 255, green: 1, blue: 147.0 / 255, alpha: 1))
        }
    }

    private final class SetlistGridScroller: GreenScroller {
        private weak var resizing: MixerDividerView?
        private var resizeCursorTracking: NSTrackingArea?

        var divider: MixerDividerView? {
            var next = superview
            while let view = next {
                if let host = view as? TimelineSetlistResizeHost { return host.trailingSetlistDivider }
                next = view.superview
            }
            return nil
        }

        private var showsResizeCursor: Bool {
            guard let window, window.attachedSheet == nil, !NativeTimelineInputGate.shared.isBlocked(window),
                  !isHiddenOrHasHiddenAncestor else { return false }
            return divider != nil
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard showsResizeCursor, !visibleRect.isEmpty else { return }
            addCursorRect(visibleRect, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard resizeCursorTracking == nil else { return }
            let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved,
                                                            .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            resizeCursorTracking = area
        }

        private func updateResizeCursor(at event: NSEvent) {
            guard showsResizeCursor, visibleRect.contains(convert(event.locationInWindow, from: nil)),
                  NSCursor.current !== NSCursor.resizeLeftRight else { return }
            NSCursor.resizeLeftRight.set()
        }

        override func cursorUpdate(with event: NSEvent) {
            if showsResizeCursor { updateResizeCursor(at: event) }
            else { super.cursorUpdate(with: event) }
        }

        override func mouseEntered(with event: NSEvent) { updateResizeCursor(at: event) }
        override func mouseMoved(with event: NSEvent) { updateResizeCursor(at: event) }

        override func mouseDown(with event: NSEvent) {
            guard let divider, let window, event.clickCount == 1 else { super.mouseDown(with: event); return }
            let origin = event.locationInWindow
            // Let AppKit track the original scrollbar click or vertical drag.
            // Only take ownership after the user has chosen the horizontal axis.
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                              until: .distantFuture, inMode: .eventTracking, dequeue: true) {
                let dx = abs(next.locationInWindow.x - origin.x)
                let dy = abs(next.locationInWindow.y - origin.y)
                if next.type == .leftMouseDragged && max(dx, dy) < 3 { continue }
                if next.type == .leftMouseDragged && dx > dy {
                    resizing = divider
                    divider.mouseDown(with: event)
                    divider.mouseDragged(with: next)
                } else {
                    window.postEvent(next, atStart: true)
                    super.mouseDown(with: event)
                }
                return
            }
        }
        override func mouseDragged(with event: NSEvent) {
            if let resizing { resizing.mouseDragged(with: event) } else { super.mouseDragged(with: event) }
        }
        override func mouseUp(with event: NSEvent) {
            if let resizing { resizing.mouseUp(with: event); self.resizing = nil }
            else { super.mouseUp(with: event) }
        }
    }

    private var timelineVerticalBar: SetlistGridScroller?
    private var timelineVerticalBarTop: CGFloat?

    func showTimelineVerticalBar(inset: CGFloat) {
        guard timelineVerticalBarTop != inset else { syncTimelineVerticalBar(); return }
        timelineVerticalBarTop = inset
        if timelineVerticalBar == nil {
            let bar = SetlistGridScroller(frame: NSRect(x: 0, y: 0, width: TimelineVerticalBar.width, height: 200))
            bar.scrollerStyle = .legacy
            bar.controlSize = .small
            bar.target = self
            bar.action = #selector(scrollWithTimelineVerticalBar)
            bar.setAccessibilityLabel(NSLocalizedString("Vertical timeline scroll", comment: ""))
            timelineVerticalBar = bar
            addSubview(bar, positioned: .above, relativeTo: contentView)
        }
        tile()
    }

    private func syncTimelineVerticalBar() {
        guard let bar = timelineVerticalBar else { return }
        let clip = contentView
        let height = documentView?.frame.height ?? 0
        let range = max(0, height - clip.bounds.height)
        let value = range > 0 ? min(1, max(0, clip.bounds.minY / range)) : 0
        let proportion = height > 0 ? min(1, clip.bounds.height / height) : 1
        let interactive = range > 0 || bar.divider != nil
        if bar.isEnabled != interactive { bar.isEnabled = interactive }
        if bar.knobProportion != proportion { bar.knobProportion = proportion }
        if bar.doubleValue != value { bar.doubleValue = value }
    }

    @objc private func scrollWithTimelineVerticalBar() {
        guard let bar = timelineVerticalBar, let documentView else { return }
        let clip = contentView
        var origin = clip.bounds.origin
        let page = clip.bounds.height * 0.85
        switch bar.hitPart {
        case .decrementPage: origin.y -= page
        case .incrementPage: origin.y += page
        case .decrementLine: origin.y -= 40
        case .incrementLine: origin.y += 40
        default: origin.y = bar.doubleValue * max(0, documentView.frame.height - clip.bounds.height)
        }
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        reflectScrolledClipView(clip)
    }

    override func reflectScrolledClipView(_ clip: NSClipView) {
        super.reflectScrolledClipView(clip)
        if clip === contentView { syncTimelineVerticalBar() }
    }

    private var lastRowReveal: UUID?
    private var pendingRowReveal: GridRowReveal?
    func revealRow(_ request: GridRowReveal?) {
        pendingRowReveal = request?.id == lastRowReveal ? nil : request
        applyPendingRowReveal()
    }
    private func applyPendingRowReveal() {
        guard let request = pendingRowReveal, let document = documentView,
              contentView.bounds.height > 0, request.height > 0 else { return }
        let bottom = request.headerHeight + request.offset + request.height
        // The model and the native document can commit on different layout
        // passes. Keep the newest request until the new row actually fits.
        guard bottom <= contentView.documentRect.height + 0.5 else { return }
        pendingRowReveal = nil; lastRowReveal = request.id
        let clip = contentView, maximum = max(0, clip.documentRect.height - clip.bounds.height)
        let raw = clip.bounds.minY - clip.documentRect.minY
        let offset = document.isFlipped ? raw : maximum - raw
        var target = offset
        if request.offset < offset || request.height + request.headerHeight > clip.bounds.height {
            target = request.offset
        } else if bottom > offset + clip.bounds.height { target = bottom - clip.bounds.height }
        target = min(maximum, max(0, target))
        guard abs(target - offset) > 0.001 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX,
            y: clip.documentRect.minY + (document.isFlipped ? target : maximum - target)))
        reflectScrolledClipView(clip)
    }
    private var previousTrackHeight: CGFloat?
    private var previousRowHeights: [CGFloat] = []
    func trackHeightOffset(height: CGFloat?, rows: [CGFloat], selected: Int?) -> CGFloat? {
        defer { previousTrackHeight = height; previousRowHeights = rows }
        guard let height, let previousTrackHeight, height != previousTrackHeight,
              rows.count == previousRowHeights.count,
              let anchor = TrackHeightGeometry.ScrollAnchor(heights: previousRowHeights.map(Double.init),
                  offset: Double(contentView.bounds.minY + contentView.bounds.height / 2), selected: nil),
              let offset = anchor.offset(heights: rows.map(Double.init)) else { return nil }
        return max(0, CGFloat(offset) - contentView.bounds.height / 2)
    }
    var manualNavigation: (() -> Void)?
    private var manualScrollMonitor: Any?
    private(set) var isPlaybackFollowing = false
    func setPlaybackFollowing(_ active: Bool) {
        guard active != isPlaybackFollowing else { return }
        isPlaybackFollowing = active
        NotificationCenter.default.post(name: Notification.Name("CatLiveTimelineFollowPresentation"), object: window,
                                        userInfo: ["active": active])
    }
    func pauseManualPlaybackFollow() {
        playbackFollowSuspendedUntil = ProcessInfo.processInfo.systemUptime + 5
        setPlaybackFollowing(false)
        manualNavigation?()
    }
    deinit { if let manualScrollMonitor { NSEvent.removeMonitor(manualScrollMonitor) } }
    /// Nil keeps ordinary, unbridged scroll views tied to their document frame.
    var logicalDocumentWidth: CGFloat?
    weak var timelineBodyInput: (NSView & NativeTimelineBodyInput)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let manualScrollMonitor { NSEvent.removeMonitor(manualScrollMonitor); self.manualScrollMonitor = nil }
        if window == nil { setPlaybackFollowing(false) }
        else {
            manualScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                if event.type == .scrollWheel || self.horizontalScroller?.isHighlighted == true || self.verticalScroller?.isHighlighted == true {
                    self.pauseManualPlaybackFollow()
                }
                return event
            }
        }
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
    fileprivate private(set) var preparingVerticalOrigin: CGFloat?
    private var laidOutVerticalBucket: CGFloat?
    private var pendingTrackHeightAnchor: (y: CGFloat, height: CGFloat)?
    func prepareTrackHeightAnchor(to y: CGFloat, height: CGFloat) {
        pendingTrackHeightAnchor = (y, height)
    }
    func trackHeightAnchor(for height: CGFloat, documentHeight: CGFloat) -> CGFloat? {
        guard let anchor = pendingTrackHeightAnchor, anchor.height == height else { return nil }
        return min(anchor.y, max(0, documentHeight - contentView.bounds.height))
    }
    func commitTrackHeightAnchor() {
        guard let anchor = pendingTrackHeightAnchor else { return }
        pendingTrackHeightAnchor = nil
        let clip = contentView
        var rect = clip.bounds
        rect.origin.y = anchor.y
        anchorTrackHeight(to: clip.constrainBoundsRect(rect).origin)
    }

    private var applyingTrackHeightAnchor = false
    private var preparingHorizontalScroll = false
    var requiresHostedHorizontalLayout: (() -> Bool)?
    func prepareHorizontalViewport(at x: CGFloat) {
        guard !preparingHorizontalScroll, zoomAnchor == nil, let document = documentView else { return }
        preparingHorizontalScroll = true
        defer { preparingHorizontalScroll = false }
        // Ordinary movement inside the prepared bucket does not need a
        // transaction/layout flush. Prepare changed buckets before revealing them.
        let viewportChanged = prepareHorizontalScroll?(x) ?? false
        let hostedChanged = prepareHostedHorizontalScroll?(x) ?? false
        if (viewportChanged || hostedChanged) && requiresHostedHorizontalLayout?() != false {
            document.layoutSubtreeIfNeeded()
        }
    }
    func scrollToPreparedHorizontalOrigin(_ origin: NSPoint) {
        if let clip = contentView as? TimelineClipView { clip.scroll(toPreparedHorizontalOrigin: origin) }
        else { contentView.scroll(to: origin) }
        reflectScrolledClipView(contentView)
    }
    func prepareVerticalViewport(at y: CGFloat) {
        guard !preparingVerticalScroll, let document = documentView,
              let prepareHostedVerticalScroll else { return }
        preparingVerticalScroll = true
        preparingVerticalOrigin = y
        defer { preparingVerticalScroll = false; preparingVerticalOrigin = nil }
        let hostedContentChanged = prepareHostedVerticalScroll(y)
        // Compare with the last completed layout, including when several wheel
        // events arrive before AppKit presents a frame. Normal tile crossings
        // are inside the existing mixer and canvas overscan.
        let bucket = laidOutVerticalBucket ?? floor(max(0, contentView.bounds.minY) / 512) * 512
        // TimelineMixerRowPool keeps 512 points above the published origin
        // and 1024 below the viewport. The waveform projection is updated by
        // prepareHostedVerticalScroll on every movement independently.
        if hostedContentChanged || y < bucket - 512 || y > bucket + 1024 {
            if applyingTrackHeightAnchor {
                // updateNSView has already assigned this height's root and
                // frames. Re-entering its SwiftUI layout here evaluates the
                // old and new row geometry in the same update on Ventura.
                // The destination is published now; AppKit lays it out before
                // presenting the changed clip in the current display pass.
                document.needsLayout = true
            } else { document.layoutSubtreeIfNeeded() }
        }
    }
    func anchorTrackHeight(to origin: NSPoint) {
        applyingTrackHeightAnchor = true
        defer { applyingTrackHeightAnchor = false }
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
    var hostedProjectionDidLayout: (() -> Bool)?
    func commitHostedProjection() {
        guard hostedProjectionDidLayout?() != false else { return }
        if prepareHostedVerticalScroll != nil {
            laidOutVerticalBucket = floor(max(0, preparingVerticalOrigin ?? contentView.bounds.minY) / 512) * 512
        }
        applyZoomAnchor()
        applyPendingRowReveal()
    }
    var fileDrop: (([URL], CGPoint) -> Bool)?
    var fileDropPreview: (([URL], CGPoint?) -> Void)?
    var fileDropModifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    private var fileDropURLs: [URL] = []
    private var fileDropPasteboardChange: Int?
    private var lastFileDropPreview: CGPoint?
    private var lastFileDropModifierFlags: NSEvent.ModifierFlags = []
    private var acceptedFileDrop = false
    private func restoreFileDropFocus() {
        guard acceptedFileDrop else { return }
        NativeTimelineKeyboardFocus.activate(window: window, responder: nil)
    }
    private func updateFileDropPreview(_ point: CGPoint?) {
        // Shift changes magnetic snapping even when the dragged file has not moved.
        let modifiers: NSEvent.ModifierFlags = point == nil ? [] : fileDropModifierFlags()
        guard point != lastFileDropPreview || (point != nil && modifiers != lastFileDropModifierFlags) else { return }
        lastFileDropPreview = point
        lastFileDropModifierFlags = modifiers
        fileDropPreview?(point == nil ? [] : fileDropURLs, point)
        if point == nil { fileDropURLs = []; fileDropPasteboardChange = nil }
    }
    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let sampleType = NSPasteboard.PasteboardType(LibrarySamplerTransfer.type.identifier)
        if let sample = LibrarySamplerTransfer.url(pasteboard.data(forType: sampleType)) { return [sample] }
        return pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileDrop != nil, let documentView,
              sender.draggingSourceOperationMask.contains(.copy) else {
            updateFileDropPreview(nil)
            return []
        }
        if fileDropPasteboardChange != sender.draggingPasteboard.changeCount {
            fileDropURLs = fileURLs(from: sender.draggingPasteboard)
            fileDropPasteboardChange = sender.draggingPasteboard.changeCount
            lastFileDropPreview = nil
        }
        guard !fileDropURLs.isEmpty else { updateFileDropPreview(nil); return [] }
        updateFileDropPreview(documentView.convert(sender.draggingLocation, from: nil))
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { updateFileDropPreview(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        updateFileDropPreview(nil); restoreFileDropFocus()
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        updateFileDropPreview(nil)
        // AppKit finishes the cross-application drag after performDragOperation.
        // Reassert the destination here as well, without waiting for the async
        // audio import (which must never steal focus from a later user action).
        restoreFileDropFocus(); acceptedFileDrop = false
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptedFileDrop = false
        defer { updateFileDropPreview(nil) }
        guard let documentView, let fileDrop, sender.draggingSourceOperationMask.contains(.copy) else { return false }
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        acceptedFileDrop = fileDrop(urls, documentView.convert(sender.draggingLocation, from: nil))
        restoreFileDropFocus()
        return acceptedFileDrop
    }

    // A committed layout clears zoomAnchor between frames, but the gesture
    // still owns the viewport until its animation and quiet period finish.
    var playbackFollowSuspendedUntil: TimeInterval = 0
    var permitsPlaybackFollow: Bool {
        zoomAnchor == nil &&
            ProcessInfo.processInfo.systemUptime >= playbackFollowSuspendedUntil
    }
    func prepareSelectionScroll(to origin: CGPoint, horizontal: Bool) {
        prioritizeZoom()
        if horizontal { prepareHorizontalViewport(at: origin.x) }
        else { prepareVerticalViewport(at: origin.y) }
    }
    func prioritizeZoom() { pauseManualPlaybackFollow() }
    var zoomAnchor: (fraction: Double, screenX: CGFloat, width: CGFloat)?
    func applyZoomAnchor() {
        guard let anchor = zoomAnchor, documentView != nil else { return }
        let rect = contentView.documentRect
        let width = rect.maxX
        var origin = contentView.bounds.origin
        origin.x = min(max(rect.minX, CGFloat(anchor.fraction) * width - anchor.screenX),
                       max(rect.minX, width - contentView.bounds.width))
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
        var viewport = bounds
        if let bar = timelineVerticalBar {
            viewport.size.width = max(0, viewport.width - TimelineVerticalBar.width)
            let inset = min(bounds.height, max(0, timelineVerticalBarTop ?? 0))
            let barFrame = NSRect(x: viewport.maxX, y: isFlipped ? bounds.minY + inset : bounds.minY,
                                  width: bounds.maxX - viewport.maxX, height: bounds.height - inset)
            if bar.frame != barFrame { bar.frame = barFrame }
        }
        if contentView.frame != viewport { contentView.frame = viewport }
        syncTimelineVerticalBar()
        if let document = documentView as? GridDocumentView, document.followsViewportWidth {
            document.synchronizeHostedViewport()
        }
        applyPendingRowReveal()
    }
}
#endif

#if os(macOS)
/// Keep the document inside the viewport on both axes, including momentum scroll.
private final class TimelineClipView: NSClipView {
    private let leadingSpace: CGFloat
    init(leadingSpace: CGFloat = 0) {
        self.leadingSpace = leadingSpace
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override var documentRect: NSRect {
        var rect = super.documentRect
        if let width = (superview as? GridNativeScrollView)?.logicalDocumentWidth {
            rect.size.width = width
        }
        rect.origin.x -= leadingSpace
        rect.size.width += leadingSpace
        return rect
    }
    private func boundedOrigin(_ origin: NSPoint) -> NSPoint {
        var result = origin
        let rect = documentRect
        let maximum = max(rect.minX, rect.maxX - bounds.width)
        result.x = min(maximum, max(rect.minX, origin.x))
        let maximumY = max(0, (documentView?.frame.height ?? 0) - bounds.height)
        result.y = min(maximumY, max(0, origin.y))
        return result
    }
    // Momentum scrolling can update bounds directly, bypassing the proposed
    // rectangle constraint. Keep the leading margin on both AppKit entry points.
    private var committingScroll = false
    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        let origin = boundedOrigin(newOrigin)
        if !committingScroll { prepareDestination(origin) }
        super.setBoundsOrigin(origin)
    }
    override func scroll(to newOrigin: NSPoint) {
        let origin = boundedOrigin(newOrigin)
        guard origin != bounds.origin else { return }
        prepareDestination(origin)
        commitScroll(to: origin)
    }
    func scroll(toPreparedHorizontalOrigin newOrigin: NSPoint) {
        let origin = boundedOrigin(newOrigin)
        guard origin != bounds.origin else { return }
        if origin.x != newOrigin.x || origin.y != bounds.minY { prepareDestination(origin) }
        commitScroll(to: origin)
    }
    private func commitScroll(to origin: NSPoint) {
        // NSClipView.scroll(to:) calls setBoundsOrigin itself. Keep both entry
        // points supported without preparing the same rows/waveforms twice.
        committingScroll = true
        defer { committingScroll = false }
        super.scroll(to: origin)
    }
    private func prepareDestination(_ origin: NSPoint) {
        if origin.x != bounds.minX { (superview as? GridNativeScrollView)?.prepareHorizontalViewport(at: origin.x) }
        if origin.y != bounds.minY {
            NativeSidebarResizeActivity.shared.verticalScroll(in: window)
            (superview as? GridNativeScrollView)?.prepareVerticalViewport(at: origin.y)
        }
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        let rect = documentRect
        let maximum = max(rect.minX, rect.maxX - proposedBounds.width)
        constrained.origin.x = min(max(rect.minX, proposedBounds.minX), maximum)
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
    var horizontalTileStep: CGFloat = 0
    var hostOriginChanged: (() -> Void)?
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
        let left = max(0, horizontalClip?.bounds.minX ?? 0)
        let x = horizontalTileStep > 0 ? floor(left / horizontalTileStep) * horizontalTileStep : left
        let origin = NSPoint(x: x, y: max(0, clip.bounds.minY))
        guard host.frame.origin != origin else { return }
        // Direct AppKit positioning is immediate. A separate CA commit for
        // every scroll sample can flush the entire window between display frames.
        host.setFrameOrigin(origin)
        hostOriginChanged?()
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
    private let limitsScrollVelocity: Bool
    private var wheelVelocity = NativeMixerScrollVelocity()
    init(limitsScrollVelocity: Bool = false) { self.limitsScrollVelocity = limitsScrollVelocity }
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

    private weak var wheelTarget: NSScrollView?
    private weak var wheelRoot: NSView?
    private var wheelPoint: NSPoint?
    private var wheelTime: TimeInterval = -.infinity
    private var wheelRootFrame: NSRect = .zero
    private var wheelClipSize: NSSize = .zero
    func invalidateWheelTarget() {
        wheelTarget = nil; wheelRoot = nil; wheelPoint = nil; wheelTime = -.infinity
        wheelVelocity.reset()
    }
    private func wheelDestination(_ event: NSEvent, root: NSView) -> NSScrollView? {
        let point = event.locationInWindow
        // A wheel gesture owns its destination while the pointer stays put.
        // Ventura's SwiftUI hit test walks the entire window; repeating it for
        // every trackpad/mouse delta consumed most of the measured input time.
        if let target = wheelTarget, wheelRoot === root, let previous = wheelPoint,
           target.window === event.window, !target.isHiddenOrHasHiddenAncestor,
           root.frame == wheelRootFrame, target.contentView.bounds.size == wheelClipSize,
           abs(point.x - previous.x) < 0.5, abs(point.y - previous.y) < 0.5,
           event.timestamp.isFinite, event.timestamp >= wheelTime, event.timestamp - wheelTime <= 0.16 {
            wheelTime = event.timestamp
            return target
        }
        let local = root.superview?.convert(point, from: nil) ?? point
        var hit = root.hitTest(local)
        var nearest: NSScrollView?
        while let current = hit {
            if let candidate = current as? NSScrollView { nearest = candidate; break }
            hit = current.superview
        }
        wheelTarget = nearest; wheelRoot = root; wheelPoint = point; wheelTime = event.timestamp
        wheelRootFrame = root.frame; wheelClipSize = nearest?.contentView.bounds.size ?? .zero
        return nearest
    }
    private var wheelMonitor: Any?
    @discardableResult func handleWheel(_ event: NSEvent) -> Bool {
        guard let scroll = scrollView, event.window === scroll.window, scroll.window?.attachedSheet == nil,
              !scroll.isHiddenOrHasHiddenAncestor,
              scroll.contentView.visibleRect.contains(scroll.contentView.convert(event.locationInWindow, from: nil)) else { return false }
        if !event.phase.intersection([.began, .ended, .cancelled]).isEmpty { invalidateWheelTarget() }
        // Visible native scrollers keep AppKit momentum. When indicators are
        // removed, route precise deltas here too: older AppKit can decline
        // scrolling on that axis. Modifier gestures remain with the timeline.
        // Reject them before traversing the entire SwiftUI document for hit testing.
        guard (!event.hasPreciseScrollingDeltas || !scroll.hasVerticalScroller || limitsScrollVelocity),
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
        guard wheelDestination(event, root: root) === scroll else { return false }
        // Peeking through nextEvent runs AppKit's display observers on Ventura.
        // During fast scrolling that nested layout/cursor pass costs more than
        // handling the wheel itself. Let the normal event loop coalesce display.
        let rawMovement = -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 16)
        let movement = limitsScrollVelocity ? wheelVelocity.limit(rawMovement, timestamp: event.timestamp,
            viewport: scroll.contentView.bounds.height, precise: event.hasPreciseScrollingDeltas) : rawMovement
        guard rawMovement != 0 else { return false }
        // A duplicate timestamp has no remaining time budget. Consume it so
        // AppKit cannot apply the original unlimited delta as a fallback.
        if movement == 0 { return limitsScrollVelocity }
        refresh()
        // Apply each native delta once, including trackpad momentum events.
        // No additional inertia or deferred movement is introduced here.
        // The track list needs more travel per mouse-wheel notch. Scale after
        // limiting so fast notches also retain four times their original distance;
        // precise trackpad gestures and the Setlist keep their native travel.
        let wheelScale: CGFloat = limitsScrollVelocity && !event.hasPreciseScrollingDeltas ? 4 : 1
        applyScroll(to: metrics.offset + movement * wheelScale)
        return true
    }
    func attach(_ scroll: NSScrollView?, owner: NSView? = nil) {
        attachmentOwner = owner
        guard scrollView !== scroll else { refresh(); return }
        invalidateWheelTarget()
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor); self.wheelMonitor = nil }
        if scroll != nil {
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown, .flagsChanged]) { [weak self] event in
                guard let self else { return event }
                if event.type != .scrollWheel { self.invalidateWheelTarget(); return event }
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
    /// Both panes share this vertical clip. Horizontal navigation targets only
    /// the timeline document and uses the same preparation/follow rules as wheel input.
    @discardableResult func scrollTimelineByArrow(_ keyCode: UInt16) -> Bool {
        guard let scroll = scrollView else { return false }
        if keyCode == 125 || keyCode == 126 {
            refresh()
            applyScroll(to: metrics.offset + (keyCode == 125 ? 72 : -72))
            return true
        }
        guard keyCode == 123 || keyCode == 124, let document = scroll.documentView else { return false }
        func horizontal(in view: NSView) -> GridNativeScrollView? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let grid = view as? GridNativeScrollView,
               grid.logicalDocumentWidth != nil || grid.prepareHorizontalScroll != nil { return grid }
            for child in view.subviews { if let grid = horizontal(in: child) { return grid } }
            return nil
        }
        guard let grid = horizontal(in: document) else { return false }
        let clip = grid.contentView
        var point = clip.bounds.origin
        point.x += keyCode == 124 ? 72 : -72
        point = clip.constrainBoundsRect(CGRect(origin: point, size: clip.bounds.size)).origin
        grid.pauseManualPlaybackFollow()
        grid.prepareHorizontalViewport(at: point.x)
        clip.scroll(to: point); grid.reflectScrolledClipView(clip)
        return true
    }
    func scroll(to offset: CGFloat) { applyScroll(to: offset) }
    func revealRow(offset: CGFloat, height: CGFloat, pinnedHeaderHeight: CGFloat) {
        refresh()
        guard height > 0, metrics.viewportHeight > 0 else { return }
        let bottom = offset + height + pinnedHeaderHeight
        if offset >= metrics.offset, bottom <= metrics.offset + metrics.viewportHeight { return }
        scrollView?.documentView?.layoutSubtreeIfNeeded()
        refresh()
        if offset < metrics.offset || height + pinnedHeaderHeight > metrics.viewportHeight {
            applyScroll(to: offset)
        } else if bottom > metrics.offset + metrics.viewportHeight {
            applyScroll(to: bottom - metrics.viewportHeight)
        }
    }
    private func applyScroll(to offset: CGFloat) {
        guard offset.isFinite, let scroll = scrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let maximum = max(0, clip.documentRect.height - clip.bounds.height)
        let bounded = min(maximum, max(0, offset))
        var origin = clip.bounds.origin
        origin.y = clip.documentRect.minY + (document.isFlipped ? bounded : maximum - bounded)
        guard abs(origin.y - clip.bounds.minY) > 0.001 else { return }
        let nativePreparesScroll = clip is TimelineClipView && (scroll as? GridNativeScrollView)?.prepareHostedVerticalScroll != nil
        let largeUnpreparedJump = !nativePreparesScroll && prepareScroll == nil && abs(origin.y - clip.bounds.minY) > clip.bounds.height / 2
        // Only a new tile or a thumb jump needs an atomic layout commit.
        // Committing a transaction for every in-bucket wheel delta forces an
        // entire AppKit display/layout cycle on Ventura instead of coalescing it.
        let prepared = !nativePreparesScroll && prepareScroll?(bounded) == true
        let synchronous = prepared || largeUnpreparedJump
        if synchronous { CATransaction.begin(); CATransaction.setDisableActions(true) }
        defer { if synchronous { CATransaction.commit() } }
        if prepared { document.layoutSubtreeIfNeeded() }
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
    override func layout() { super.layout(); if window != nil { attach() } }
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

#if os(macOS)
/// Native dragging runs in tracking mode. Keep scrolling while the pointer is
/// held still at an edge, and retire the timer with the dragging session.
@MainActor final class NativeDragEdgeScroll {
    private weak var scroll: NSScrollView?
    private var timer: Timer?
    private var lastTime: TimeInterval = 0
    func begin(from view: NSView) {
        stop()
        guard let scroll = view.enclosingScrollView else { return }
        self.scroll = scroll; lastTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.step(pointer: NSEvent.mouseLocation, pressedButtons: NSEvent.pressedMouseButtons,
                           time: ProcessInfo.processInfo.systemUptime)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    static func velocity(position: CGFloat, length: CGFloat) -> CGFloat {
        guard length > 0, position >= 0, position <= length else { return 0 }
        let edge = min(40, length / 3)
        if position < edge { return -600 * (1 - position / edge) }
        if position > length - edge { return 600 * (1 - (length - position) / edge) }
        return 0
    }
    func step(pointer: NSPoint, pressedButtons: Int, time: TimeInterval) {
        guard let scroll, let window = scroll.window, let document = scroll.documentView else { stop(); return }
        guard pressedButtons != 0 else { stop(); return }
        let clip = scroll.contentView
        let point = clip.convert(window.convertPoint(fromScreen: pointer), from: nil)
        let local = CGPoint(x: point.x - clip.bounds.minX, y: point.y - clip.bounds.minY)
        let elapsed = min(0.05, max(0, time - lastTime))
        lastTime = time
        guard local.x >= 0, local.x <= clip.bounds.width else { return }
        let velocity = Self.velocity(position: local.y, length: clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(max(document.bounds.minY, origin.y + velocity * elapsed), max(document.bounds.minY, document.bounds.maxY - clip.bounds.height))
        guard origin != clip.bounds.origin else { return }
        (scroll as? NativeTimelineSelectionScrollHost)?.prepareSelectionScroll(to: origin, horizontal: false)
        clip.scroll(to: origin); scroll.reflectScrolledClipView(clip)
    }
    func stop() { timer?.invalidate(); timer = nil; scroll = nil }
    deinit { timer?.invalidate() }
}
#endif
