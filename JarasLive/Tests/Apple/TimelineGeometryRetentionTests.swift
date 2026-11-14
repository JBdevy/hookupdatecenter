// Appended to the native workspace fixture so this exercises the production
// geometry boundary, scroll documents, columns, environment and responder chain.
@MainActor private final class GeometryRetentionState: ObservableObject {
    @Published var revision = 0
    @Published var actionGeneration = 0
    var sizes: [CGSize] = []
    var builds: [(size: CGSize, revision: Int)] = []
    var buildTokens: [UUID] = []
    var actions: [String] = []
    @Published var project = UUID()
}
private final class CoverageControl: NSView {
    var coverage = CGSize.zero
    var project: UUID?
    var action: () -> Void = {}
    var openFX: () -> Void = {}
    var language = ""
    var dark = false
    var blocked = false
    var font: Font?
    var controlSize: ControlSize = .regular
    var typeSize: DynamicTypeSize = .medium
    var enabled = true
    var scale: CGFloat = 1
    var direction: LayoutDirection = .leftToRight
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // Represents the fallback, recording and cut overlays that render
        // using geometry coverage but remain clipped to the live viewport.
        NSColor.magenta.setFill()
        NSRect(origin: .zero, size: coverage).intersection(bounds).fill()
    }
}
private struct CoverageProbe: NSViewRepresentable {
    let coverage: CGSize
    let project: UUID
    var action: () -> Void = {}
    @Environment(\.font) private var font
    @Environment(\.controlSize) private var size
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.isEnabled) private var enabled
    @Environment(\.displayScale) private var scale
    @Environment(\.layoutDirection) private var direction
    @Environment(\.openFX) private var fx
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.gridInteractionBlocked) private var blocked
    func makeNSView(context: Context) -> CoverageControl { CoverageControl() }
    func updateNSView(_ view: CoverageControl, context: Context) {
        view.coverage = coverage; view.project = project; view.font = font; view.controlSize = size; view.typeSize = type
        view.action = action
        view.openFX = { fx(nil, "eq") }
        view.language = locale.identifier; view.dark = scheme == .dark; view.blocked = blocked
        view.enabled = enabled; view.scale = scale; view.direction = direction; view.needsDisplay = true
    }
}
private struct GeometryRetentionFixture: View {
    @ObservedObject var state: GeometryRetentionState
    var body: some View {
        let revision = state.revision
        let project = state.project
        let actionGeneration = state.actionGeneration
        TimelineGeometryReader { geometry in
            let _ = state.sizes.append(geometry.size)
            let _ = state.builds.append((geometry.size, revision))
            let _ = state.buildTokens.append(WorkspaceGeometryIdentityProbe.tokens.last!)
            // The real timeline uses this same maximum control-body width.
            let mixerWidth = max(161, min(486.5, geometry.size.width - 260))
            GridScrollView(axis: .vertical, contentWidth: geometry.size.width, contentHeight: 1800) {
                NativeTimelineColumns(mixerWidth: mixerWidth, viewportWidth: geometry.size.width,
                                      height: 1800, dividerWidth: 6, project: project, mixerIdentity: revision) {
                    StatefulControl(role: "coverage-mixer", revision: revision).frame(maxWidth: .infinity).frame(height: 1800)
                } divider: { Color.gray } timeline: {
                    GridScrollView(axis: .horizontal, contentWidth: 4000, contentHeight: 1800) {
                        StatefulControl(role: "coverage-timeline", revision: revision).frame(width: 4000, height: 1800)
                    }.frame(maxWidth: .infinity).frame(height: 1800)
                }.frame(maxWidth: .infinity).frame(height: 1800)
            }.frame(maxWidth: .infinity).frame(height: geometry.size.height)
                .overlay(CoverageProbe(coverage: geometry.size, project: project,
                    action: { state.actions.append("direct\(actionGeneration)") }).allowsHitTesting(false))
        }
        .environment(\.locale, Locale(identifier: revision == 0 ? "en" : "pt_BR"))
        .environment(\.colorScheme, revision == 0 ? .dark : .light)
        .environment(\.gridInteractionBlocked, revision % 2 == 1)
        .environment(\.openFX, { _, _ in state.actions.append("fx\(revision)") })
        .font(revision == 0 ? .body : .title)
        .controlSize(revision == 0 ? .regular : .large)
        .environment(\.dynamicTypeSize, revision == 0 ? .medium : .xxxLarge)
        .environment(\.displayScale, revision == 0 ? 1 : 2)
        .disabled(revision != 0)
    }
}
MainActor.assumeIsolated {
    let state = GeometryRetentionState()
    let root = NSHostingView(rootView: GeometryRetentionFixture(state: state))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; settle(root)
    let boundary = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "timeline-geometry" }!
    let scrolls = descendants(GridNativeScrollView.self, in: root)
    let vertical = scrolls[0], horizontal = scrolls[1]
    let mixer = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "columns-mixer" }!
    let timeline = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "columns-timeline" }!
    let control = descendants(WorkspaceControl.self, in: timeline).first!
    let coverage = descendants(CoverageControl.self, in: root).first!
    precondition(state.sizes.last == CGSize(width: 1200, height: 600))
    horizontal.contentView.scroll(to: CGPoint(x: 1500, y: 0))
    vertical.contentView.scroll(to: CGPoint(x: 0, y: 200)); settle(root)
    precondition(window.makeFirstResponder(control))
    control.increment(); settle(root)
    NativeSidebarResizeActivity.shared.begin(owner: root, retainsTimelineCoverage: true); settle(root)
    precondition(state.sizes.last == CGSize(width: 1536, height: 600))
    let retainedCount = state.sizes.count
    for width: CGFloat in [1250, 1300, 1410, 1500] {
        window.setContentSize(NSSize(width: width, height: 600)); settle(root)
        precondition(state.sizes.count == retainedCount,
                     "Native pixel changes in one coverage bucket must not execute the heavy timeline builder")
        precondition(abs(boundary.frame.width - width) < 0.5 && abs(boundary.subviews[0].frame.width - width) < 0.5)
        precondition(abs(vertical.documentView!.frame.width - width) < 0.5 && abs(vertical.contentView.bounds.width - width) < 0.5)
        precondition(abs(horizontal.contentView.bounds.width - (width - 492.5)) <= 0.5,
                     "width=\(width), mixer=\(mixer.frame), timeline=\(timeline.frame), horizontal=\(horizontal.frame), clip=\(horizontal.contentView.bounds)")
        precondition(window.firstResponder === control && control.count == 1)
        precondition(abs(horizontal.contentView.bounds.minX - 1500) < 0.5 && abs(vertical.contentView.bounds.minY - 200) < 0.5)
        precondition(coverage.coverage.width >= coverage.bounds.width && abs(coverage.bounds.width - width) < 0.5)
    }
    window.setContentSize(NSSize(width: 1600, height: 640)); settle(root)
    precondition(state.sizes.last == CGSize(width: 2048, height: 640), "Expansion must install new drawing coverage before exposing the edge")
    precondition(abs(coverage.bounds.width - 1600) < 0.5 && coverage.coverage.width == 2048 && coverage.coverage.height == 640)
    precondition(abs(timeline.convert(NSSize(width: 10, height: 10), to: nil).width - 10) < 0.01, "Coverage must never scale inputs or graphics")
    state.revision = 1; settle(root)
    precondition(descendants(WorkspaceControl.self, in: timeline).first === control && control.revision == 1 && control.count == 1)
    precondition(control.language == "pt_BR" && !control.dark && control.blocked)
    precondition(coverage.font == .title && coverage.controlSize == .large && coverage.typeSize == .xxxLarge && !coverage.enabled && coverage.scale == 2)
    control.actions(); precondition(state.actions == ["fx1"], "Model, actions and environment must refresh within the retained bucket")
    for width: CGFloat in [799, 720, 600] {
        window.setContentSize(NSSize(width: width, height: 640)); settle(root)
        precondition(state.sizes.last == CGSize(width: width, height: 640), "Narrow widths must use exact geometry for header/mixer limits")
        precondition(abs(mixer.frame.width - max(161, min(486.5, width - 260))) < 0.5)
        precondition(abs(horizontal.contentView.bounds.width - (width - mixer.frame.width - 6)) <= 0.5)
    }
    window.setContentSize(NSSize(width: 900, height: 640)); settle(root)
    precondition(state.sizes.last?.width == 1024)
    NativeSidebarResizeActivity.shared.end(owner: root); settle(root)
    precondition(state.sizes.last == CGSize(width: 900, height: 640), "Mouse-up must restore exact geometry without a model publication")
    NativeSidebarResizeActivity.shared.begin(owner: root); settle(root)
    window.setContentSize(NSSize(width: 940, height: 640)); settle(root)
    precondition(state.sizes.last?.width == 940, "Mixer resize must not retain timeline geometry")
    NativeSidebarResizeActivity.shared.end(owner: root)
    NativeSidebarResizeActivity.shared.begin(owner: root, retainsTimelineCoverage: true); settle(root)
    precondition(state.sizes.last?.width == 1024)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window); settle(root)
    precondition(state.sizes.last?.width == 940, "Cancel must restore exact viewport geometry")
    print("SETLIST_TIMELINE_COVERAGE_RETAINS_BUILDER_WITH_LIVE_NATIVE_VIEWPORT_FOCUS_SCROLL_EXPANSION_MODEL_ENVIRONMENT_ACTIONS_AND_CANCEL_OK")
    window.close()
}

private struct GeometryReleaseFixture: View {
    @ObservedObject var workspace: WorkspaceTestState
    let geometry: GeometryRetentionState
    var body: some View {
        NativeWorkspaceSplit(width: workspace.width, restoreWidth: workspace.restore, minimum: 277,
            scrollController: workspace.scroll, contentIdentity: 0, onToggle: workspace.toggle,
            onEnd: { width in
                workspace.width = width; workspace.restore = width
                geometry.revision += 1
                geometry.project = UUID()
            }) {
                GeometryRetentionFixture(state: geometry)
            } trailing: { Color.gray }
    }
}
MainActor.assumeIsolated {
    for windowWidth: CGFloat in [1600, 1000] {
    let workspace = WorkspaceTestState(), geometry = GeometryRetentionState()
    let root = NSHostingView(rootView: GeometryReleaseFixture(workspace: workspace, geometry: geometry))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: windowWidth, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; settle(root)
    let divider = descendants(MixerDividerView.self, in: root).first!
    let left = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "workspace-timeline" }!
    let boundary = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "timeline-geometry" }!
    let timeline = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "columns-timeline" }!
    let mixer = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "columns-mixer" }!
    let control = descendants(WorkspaceControl.self, in: timeline).first!
    let coverage = descendants(CoverageControl.self, in: root).first!
    let scrolls = descendants(GridNativeScrollView.self, in: root)
    scrolls[0].contentView.scroll(to: CGPoint(x: 0, y: 200))
    scrolls[1].contentView.scroll(to: CGPoint(x: 1200, y: 0)); settle(root)
    precondition(window.makeFirstResponder(control))
    control.increment(); settle(root)
    var point = divider.convert(CGPoint(x: 3, y: 200), to: nil)
    func event(_ type: NSEvent.EventType, delta: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x + delta, y: point.y),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    divider.mouseDown(with: event(.leftMouseDown, delta: 0))
    divider.mouseDragged(with: event(.leftMouseDragged, delta: -40)); settle(root)
    precondition(geometry.sizes.last?.width == (windowWidth >= 1200 ? 1536 : windowWidth - 366))
    geometry.builds.removeAll()
    divider.mouseUp(with: event(.leftMouseUp, delta: -55)); settle(root)
    let expected = CGSize(width: windowWidth - 375 - 6, height: 600)
    let descriptions = geometry.builds.map { "\($0.size.width):\($0.revision)" }
    print("GEOMETRY_RELEASE_BUILDS \(descriptions)")
    print("GEOMETRY_RELEASE_STATE left=\(left.frame.size) boundary=\(boundary.frame.size) hosted=\(boundary.subviews[0].frame.size) mixer=\(mixer.frame.width) focus=\(window.firstResponder === control) count=\(control.count) revision=\(control.revision) language=\(control.language) dark=\(control.dark) blocked=\(control.blocked) project=\(coverage.project == geometry.project) enabled=\(coverage.enabled) scroll=\(scrolls.map { $0.contentView.bounds.origin })")
    precondition(left.frame.size == expected && geometry.builds.last?.size == expected)
    precondition(geometry.builds.count == 1 && geometry.builds[0].size == expected && geometry.builds[0].revision == 1,
        "release must rebuild once using final native bounds and the latest parent model/environment/actions")
    precondition(boundary.frame.size == expected && boundary.subviews[0].frame.size == expected)
    precondition(abs(mixer.frame.width - max(161, min(486.5, expected.width - 260))) < 0.5,
        "the exact final width must also clamp the mixer in narrow viewports")
    precondition(window.firstResponder === control && control.count == 1)
    precondition(control.revision == 1 && control.language == "pt_BR" && !control.dark && control.blocked)
    precondition(coverage.project == geometry.project && coverage.font == .title && !coverage.enabled)
    precondition(coverage.controlSize == .large && coverage.typeSize == .xxxLarge && coverage.scale == 2)
    control.actions(); precondition(geometry.actions == ["fx1"])
    precondition(scrolls[0].contentView.bounds.minY == 200 && scrolls[1].contentView.bounds.minX == 1200)
    let priorBuilder = WorkspaceGeometryIdentityProbe.tokens.last
    geometry.actionGeneration = 1; settle(root)
    precondition(WorkspaceGeometryIdentityProbe.tokens.last != priorBuilder,
        "a fresh parent closure must have a fresh construction token even with identical model metadata")
    coverage.action(); precondition(geometry.actions.last == "direct1")

    // Cancellation does not publish a width. It must still restore exact
    // geometry after the last native frame propagates, with a concurrent model.
    point = divider.convert(CGPoint(x: 3, y: 200), to: nil)
    divider.mouseDown(with: event(.leftMouseDown, delta: 0))
    divider.mouseDragged(with: event(.leftMouseDragged, delta: 20)); settle(root)
    geometry.builds.removeAll()
    divider.mouseDragged(with: event(.leftMouseDragged, delta: 30))
    divider.cancelTracking(); geometry.revision = 2; geometry.project = UUID()
    settle(root)
    precondition(geometry.builds.count == 1 && geometry.builds[0].size == left.frame.size && geometry.builds[0].revision == 2,
        "cancel coalesces the latest model and final native bounds into one exact root")
    precondition(boundary.subviews[0].frame.size == left.frame.size && coverage.project == geometry.project)
    precondition(!control.blocked && window.firstResponder === control)
    control.actions(); precondition(geometry.actions.last == "fx2")

    // A sheet and the input gate must survive an exact-geometry commit. The
    // wrapper never activates a document or changes its responder to finish.
    let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 150),
                         styleMask: [.titled], backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    window.beginSheet(sheet)
    NativeSidebarResizeActivity.shared.begin(owner: root, retainsTimelineCoverage: true); settle(root)
    geometry.builds.removeAll(); geometry.buildTokens.removeAll()
    NativeSidebarResizeActivity.shared.end(owner: root); geometry.revision = 3
    settle(root)
    precondition(window.attachedSheet === sheet && control.blocked && coverage.project == geometry.project)
    print("GEOMETRY_SHEET_BUILDS \(geometry.builds.map { "\($0.size.width):\($0.size.height):\($0.revision)" }) tokens=\(geometry.buildTokens) key=\(window.isKeyWindow) visible=\(window.isVisible) active=\(NSApp.isActive)")
    // Ventura can synchronously lay out the attached sheet inside end(),
    // before the following assignment publishes revision 3. That is a real
    // model change, not a repeated proposal of the same immutable builder.
    precondition(geometry.builds.last?.revision == 3 && geometry.builds.count <= 2 &&
                 geometry.builds.allSatisfy { $0.size == left.frame.size && (2...3).contains($0.revision) } &&
                 Set(geometry.builds.map(\.revision)).count == geometry.builds.count &&
                 Set(geometry.buildTokens).count == geometry.buildTokens.count,
                 "sheet release must deliver exact bounds and the latest model, without rebuilding an identical value")
    window.endSheet(sheet); sheet.orderOut(nil); sheet.close()

    // Leaving the window during a retained gesture cancels its ownership;
    // reattaching at another width must not revive a provisional-size builder.
    NativeSidebarResizeActivity.shared.begin(owner: divider, retainsTimelineCoverage: true); settle(root)
    geometry.builds.removeAll()
    window.contentView = NSView()
    geometry.revision = 4; geometry.project = UUID()
    window.setContentSize(CGSize(width: windowWidth - 80, height: 610))
    window.contentView = root; settle(root)
    precondition(!NativeSidebarResizeActivity.shared.canRetainTimelineCoverage(in: window))
    precondition(geometry.builds.last?.size == left.frame.size && geometry.builds.last?.revision == 4)
    precondition(boundary.subviews[0].frame.size == left.frame.size && coverage.project == geometry.project && !control.blocked)
    control.actions(); precondition(geometry.actions.last == "fx4")
    precondition(window.makeFirstResponder(control) && control.count == 1)
    print("GEOMETRY_FINAL_BOUNDS_SINGLE_BUILD_END_CANCEL_NARROW_CLAMP_MODEL_PROJECT_ENV_ACTIONS_FOCUS_SHEET_REMOUNT_OK width=\(windowWidth)")
    window.close()
    }
}

// Hold the same constructed reader while only its inherited environment changes.
private struct HeldGeometryReaderFixture: View {
    @ObservedObject var state: GeometryRetentionState
    let reader: TimelineGeometryReader<CoverageProbe>
    init(state: GeometryRetentionState) {
        self.state = state
        reader = TimelineGeometryReader { size in
            state.sizes.append(size.size)
            return CoverageProbe(coverage: size.size, project: state.project)
        }
    }
    var body: some View {
        let generation = state.actionGeneration
        reader.font(state.revision == 0 ? .body : .title)
            .controlSize(state.revision == 0 ? .regular : .large)
            .environment(\.dynamicTypeSize, state.revision == 0 ? .medium : .xxxLarge)
            .environment(\.displayScale, state.revision == 0 ? 1 : 2)
            .environment(\.layoutDirection, state.revision == 0 ? .leftToRight : .rightToLeft)
            .environment(\.locale, Locale(identifier: state.revision == 0 ? "en" : "pt_BR"))
            .environment(\.colorScheme, state.revision == 0 ? .dark : .light)
            .environment(\.gridInteractionBlocked, state.revision != 0)
            .environment(\.openFX, { _, _ in state.actions.append("heldfx\(generation)") })
            .disabled(state.revision != 0)
    }
}
MainActor.assumeIsolated {
    let state = GeometryRetentionState()
    let root = NSHostingView(rootView: HeldGeometryReaderFixture(state: state))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; settle(root)
    NativeSidebarResizeActivity.shared.begin(owner: root, retainsTimelineCoverage: true); settle(root)
    NativeSidebarResizeActivity.shared.end(owner: root); settle(root)
    let token = WorkspaceGeometryIdentityProbe.tokens.last!
    let previousBuilds = state.sizes.count
    let control = descendants(CoverageControl.self, in: root).first!
    state.actionGeneration = 1; settle(root)
    precondition(WorkspaceGeometryIdentityProbe.tokens.last == token && state.sizes.count == previousBuilds)
    control.openFX(); precondition(state.actions.last == "heldfx1",
        "closure-only environment changes must update action relays even when the final root is identical")
    state.revision = 1; settle(root)
    precondition(WorkspaceGeometryIdentityProbe.tokens.last == token,
        "this fixture must keep the representable construction token while changing its environment")
    precondition(state.sizes.count > previousBuilds && control.font == .title && control.controlSize == .large)
    precondition(control.typeSize == .xxxLarge && control.scale == 2 && control.direction == .rightToLeft && !control.enabled)
    precondition(control.language == "pt_BR" && !control.dark && control.blocked)
    window.close()
    print("GEOMETRY_SAME_BUILDER_TOKEN_CHANGED_ENVIRONMENT_REBUILDS_OK")
}

MainActor.assumeIsolated {
    let workspace = WorkspaceTestState(), geometry = GeometryRetentionState()
    let root = NSHostingView(rootView: GeometryReleaseFixture(workspace: workspace, geometry: geometry))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1600, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; settle(root)
    let divider = descendants(MixerDividerView.self, in: root).first!
    let point = divider.convert(CGPoint(x: 3, y: 200), to: nil)
    func event(_ type: NSEvent.EventType, delta: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x + delta, y: point.y),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    divider.mouseDown(with: event(.leftMouseDown, delta: 0))
    divider.mouseDragged(with: event(.leftMouseDragged, delta: -40)); settle(root)
    let replacement = UUID()
    WorkspaceGeometryFinalLayoutProbe.commit = {
        WorkspaceGeometryFinalLayoutProbe.commit = nil
        geometry.revision = 9; geometry.project = replacement; geometry.actionGeneration = 7
    }
    geometry.builds.removeAll()
    divider.mouseUp(with: event(.leftMouseUp, delta: -55)); settle(root)
    let control = descendants(CoverageControl.self, in: root).first!
    precondition(WorkspaceGeometryFinalLayoutProbe.commit == nil)
    precondition(geometry.builds.contains { $0.revision == 1 } && geometry.builds.last?.revision == 9,
        "a real model/project update between final layout and framework reproposal must never be deduplicated")
    precondition(geometry.builds.allSatisfy { $0.size == CGSize(width: 1219, height: 600) } && control.project == replacement)
    control.action(); precondition(geometry.actions.last == "direct7")
    window.close()
    print("GEOMETRY_MODEL_PROJECT_CLOSURE_CHANGED_BETWEEN_COMMIT_AND_REPROPOSAL_OK")
}
