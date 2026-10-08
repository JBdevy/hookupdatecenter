// The shell fixture extracts the production coverage query, gate, SwiftUI
// item scope, commit sentinel and native hosting/scroll classes into this file.
// Windows remain hidden; this is a deterministic correctness fixture.
@MainActor private enum HostedGateChecks {
    static var count = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        precondition(condition(), message)
    }
}

@MainActor private func runHostedCoverageChecks() {
    let size = CGSize(width: 20000, height: 20000)
    let origin = CGRect(x: 0, y: 0, width: 512, height: 256)
    func visible(_ item: CGRect, viewport: CGRect = CGRect(x: 0, y: 0, width: 512, height: 256),
                 scale: CGFloat = 1, document: CGSize = CGSize(width: 20000, height: 20000)) -> Bool {
        TimelineHostedItemCoverage(items: [item]).containsItems(viewport: viewport, documentSize: document, scale: scale)
    }
    HostedGateChecks.require(!TimelineHostedItemCoverage(items: []).containsItems(viewport: origin, documentSize: size, scale: 1),
        "an empty fallback set must leave the native body independent of hosted scale")
    HostedGateChecks.require(visible(CGRect(x: 30, y: 40, width: 80, height: 24)),
        "fallback inside the visible viewport must activate")
    HostedGateChecks.require(!visible(CGRect(x: 8000, y: 40, width: 80, height: 24)),
        "a distant fallback in a visible row must not activate")
    HostedGateChecks.require(!visible(CGRect(x: 30, y: 8000, width: 80, height: 24)),
        "fallback in a distant row must not activate")
    HostedGateChecks.require(visible(CGRect(x: 1148, y: 40, width: 2, height: 24)),
        "waveform trailing coverage beyond the Canvas tile must activate")
    HostedGateChecks.require(!visible(CGRect(x: 1160, y: 40, width: 2, height: 24)),
        "horizontal content beyond both reserves and pixel overscan must stay inactive")
    HostedGateChecks.require(visible(CGRect(x: 30, y: 1028, width: 80, height: 2)),
        "Canvas vertical coverage beyond the waveform tile must activate")
    HostedGateChecks.require(!visible(CGRect(x: 30, y: 1031, width: 80, height: 2)),
        "a lane beyond vertical reserve and overscan must stay inactive")
    let later = CGRect(x: 2048, y: 2048, width: 512, height: 256)
    HostedGateChecks.require(visible(CGRect(x: 1527.5, y: 2100, width: 0, height: 24), viewport: later),
        "the minimum two-point item body must enter the leading pixel overscan")
    HostedGateChecks.require(!visible(CGRect(x: 1524, y: 2100, width: 0, height: 24), viewport: later),
        "a minimum-width item wholly before leading overscan must stay inactive")
    HostedGateChecks.require(visible(CGRect(x: 2100, y: 1787, width: 80, height: 2), viewport: later),
        "lane geometry must include the leading six-point vertical overscan")
    HostedGateChecks.require(!visible(CGRect(x: 2100, y: 1782, width: 80, height: 2), viewport: later),
        "a different lane above the preparation reserve must stay inactive")
    let bucketItem = CGRect(x: 1610, y: 40, width: 20, height: 24)
    HostedGateChecks.require(!visible(bucketItem, viewport: CGRect(x: 511.999, y: 0, width: 512, height: 256)),
        "movement inside one unpublished horizontal bucket must retain its coverage")
    HostedGateChecks.require(visible(bucketItem, viewport: CGRect(x: 512, y: 0, width: 512, height: 256)),
        "crossing a horizontal bucket must prepare the new fallback reserve")
    let rowItem = CGRect(x: 30, y: 1490, width: 80, height: 24)
    HostedGateChecks.require(!visible(rowItem, viewport: CGRect(x: 0, y: 511.999, width: 512, height: 256)),
        "movement inside one unpublished vertical bucket must retain its coverage")
    HostedGateChecks.require(visible(rowItem, viewport: CGRect(x: 0, y: 512, width: 512, height: 256)),
        "crossing a vertical bucket must prepare the new row reserve")
    HostedGateChecks.require(visible(CGRect(x: 8500, y: 40, width: 80, height: 24),
        viewport: CGRect(x: 8192, y: 0, width: 512, height: 256)),
        "a large horizontal destination must query its own coverage")
    HostedGateChecks.require(visible(CGRect(x: 30, y: 8500, width: 80, height: 24),
        viewport: CGRect(x: 0, y: 8192, width: 512, height: 256)),
        "a large vertical destination must query its own coverage")
    HostedGateChecks.require(visible(bucketItem, viewport: CGRect(x: 0, y: 0, width: 1024, height: 256)),
        "widening a viewport must expose fallback without a scroll event")
    HostedGateChecks.require(visible(rowItem, viewport: CGRect(x: 0, y: 0, width: 512, height: 1024)),
        "increasing viewport height must expose fallback rows without scrolling")
    let scaled = CGRect(x: 100, y: 40, width: 20, height: 24)
    HostedGateChecks.require(visible(scaled, scale: 10) && !visible(scaled, scale: 20),
        "horizontal projection must use the incoming zoom scale")
    HostedGateChecks.require(visible(scaled, viewport: CGRect(x: 1536, y: 0, width: 512, height: 256), scale: 20),
        "an anticipated zoom-anchor viewport must activate fallback at its new scale")
    HostedGateChecks.require(visible(CGRect(x: 30, y: 40, width: 80, height: 24),
        viewport: CGRect(x: -100, y: -100, width: 512, height: 256)),
        "elastic negative origins must conservatively prepare document time zero")
    for scale in [CGFloat.zero, -1, .infinity, .nan] {
        HostedGateChecks.require(visible(CGRect(x: 8000, y: 8000, width: 80, height: 24), scale: scale),
            "invalid scales must keep hosted fallback conservative")
    }
    let clipped = CGSize(width: 512, height: 256)
    HostedGateChecks.require(!visible(CGRect(x: 1000, y: 40, width: 80, height: 24), document: clipped),
        "preparation must stop at the current logical document width")
    HostedGateChecks.require(!visible(CGRect(x: 30, y: 500, width: 80, height: 24), document: clipped),
        "preparation must stop at the document height")
}

@MainActor private func runHostedGenerationChecks() {
    let first = TimelineHostedItemCoverage(items: [CGRect(x: 30, y: 40, width: 80, height: 24)])
    let changed = TimelineHostedItemCoverage(items: [CGRect(x: 30, y: 80, width: 80, height: 24)])
    let gate = TimelineHostedItemsGate()
    HostedGateChecks.require(gate.update(coverage: first, active: true, deferred: false),
        "the first structural coverage must start a commit generation")
    HostedGateChecks.require(gate.published == gate.requested && gate.needsCommit,
        "native activation must publish synchronously and wait for its hosted commit")
    HostedGateChecks.require(!gate.commitHostedProjection(),
        "a host layout without a matching staged sentinel must not acknowledge activation")
    gate.stage(gate.published, coverage: first)
    HostedGateChecks.require(gate.commitHostedProjection() && !gate.needsCommit,
        "the staged current snapshot must acknowledge activation")
    HostedGateChecks.require(gate.requiresHosted(coverage: first),
        "visible fallback must continue requiring hosted zoom after initial commit")
    let initial = gate.requested
    HostedGateChecks.require(!gate.update(coverage: first, active: true, deferred: false) && gate.requested == initial,
        "unchanged visibility and structure must not create another generation")
    var publications = 0
    let observation = gate.$published.dropFirst().sink { _ in publications += 1 }
    HostedGateChecks.require(gate.update(coverage: first, active: false, deferred: false),
        "leaving fallback coverage must request retirement")
    let retiring = gate.requested
    HostedGateChecks.require(publications == 1 && gate.requiresHosted(coverage: first),
        "retirement must publish once and retain the hosted requirement until layout")
    gate.stage(initial, coverage: first)
    HostedGateChecks.require(!gate.commitHostedProjection() && gate.needsCommit,
        "a previously mounted active sentinel must not acknowledge retirement")
    gate.stage(retiring, coverage: first)
    HostedGateChecks.require(gate.commitHostedProjection() && !gate.requiresHosted(coverage: first),
        "matching retirement layout must release the hosted zoom requirement")
    HostedGateChecks.require(gate.requiresHosted(coverage: changed),
        "a structural mismatch must keep the new fallback tree conservative")
    gate.update(coverage: first, active: true, deferred: false)
    let entering = gate.requested
    gate.stage(retiring, coverage: first)
    HostedGateChecks.require(!gate.commitHostedProjection() && gate.needsCommit,
        "a stale retirement sentinel must not acknowledge reentry")
    gate.stage(entering, coverage: first)
    HostedGateChecks.require(gate.commitHostedProjection(), "the current activation generation must commit")
    gate.update(coverage: first, active: false, deferred: false)
    let staleOff = gate.requested
    gate.update(coverage: first, active: true, deferred: false)
    let newOn = gate.requested
    HostedGateChecks.require(newOn.generation > staleOff.generation && newOn.generation > entering.generation,
        "false-to-true reversal must create distinct generations even when final visibility repeats")
    gate.stage(staleOff, coverage: first)
    HostedGateChecks.require(!gate.commitHostedProjection(),
        "a superseded off generation must not release the newer activation")
    gate.stage(newOn, coverage: first)
    HostedGateChecks.require(gate.commitHostedProjection(), "the latest reversal generation must commit")
    let beforeDeferred = gate.published
    let beforePublications = publications
    gate.update(coverage: changed, active: false, deferred: true)
    HostedGateChecks.require(gate.published == beforeDeferred && gate.requested != gate.published,
        "configure must be able to request new structure without publishing during SwiftUI update")
    HostedGateChecks.require(gate.requiresHosted(coverage: changed) && !gate.commitHostedProjection(),
        "unpublished structural retirement must keep the anchor waiting")
    gate.stage(gate.requested, coverage: first)
    HostedGateChecks.require(!gate.commitHostedProjection(),
        "a sentinel carrying old structural coverage must not acknowledge a new request")
    gate.update(coverage: first, active: false, deferred: true)
    let newestDeferred = gate.requested
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    HostedGateChecks.require(gate.published == newestDeferred && publications == beforePublications + 1,
        "deferred structural reconciliations must coalesce to the latest snapshot")
    gate.stage(gate.published, coverage: first)
    HostedGateChecks.require(gate.commitHostedProjection() && !gate.requiresHosted(coverage: first),
        "the latest deferred retirement must release the gate after layout")
    gate.update(coverage: changed, active: true, deferred: true)
    gate.update(coverage: first, active: true, deferred: false)
    let synchronouslyActivated = gate.published
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    HostedGateChecks.require(gate.published == synchronouslyActivated && gate.published == gate.requested,
        "a queued publication must not overwrite a newer synchronous preflight")
    let newIdentity = TimelineHostedItemCoverage(items: first.items, identity: 1)
    let beforeIdentity = gate.requested
    gate.update(coverage: newIdentity, active: true, deferred: false)
    HostedGateChecks.require(gate.requested.generation > beforeIdentity.generation && gate.needsCommit,
        "a content revision with identical item rectangles must still receive a new commit generation")
    withExtendedLifetime(observation) {}
}

@MainActor private final class HostedGateFixtureState: ObservableObject {
    @Published var coverage: TimelineHostedItemCoverage?
    @Published var hasItems = true
    let gate = TimelineHostedItemsGate()
    let zoom = TimelineZoomState()
    init(coverage: TimelineHostedItemCoverage?) { self.coverage = coverage }
}

@MainActor private final class HostedGateBodyCounts {
    var mounts = 0
    var updates = 0
    var dismantles = 0
}

private final class HostedGateBodyView: NSView {
    var scale: CGFloat = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.green.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

private struct HostedGateBody: NSViewRepresentable {
    let scale: CGFloat
    let counts: HostedGateBodyCounts
    func makeCoordinator() -> HostedGateBodyCounts { counts }
    func makeNSView(context: Context) -> HostedGateBodyView {
        counts.mounts += 1
        return HostedGateBodyView()
    }
    func updateNSView(_ view: HostedGateBodyView, context: Context) {
        counts.updates += 1
        view.scale = scale
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: HostedGateBodyView, coordinator: HostedGateBodyCounts) {
        coordinator.dismantles += 1
    }
}

private struct HostedGateFixture: View {
    @ObservedObject var state: HostedGateFixtureState
    let counts: HostedGateBodyCounts
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            TimelineItemsScaleLayer(state: state.zoom, extent: 200, hasItems: state.hasItems,
                gate: state.gate, coverage: state.coverage) { _, _, scale in
                HostedGateBody(scale: scale, counts: counts)
                    .frame(width: 4000, height: 4096)
            }
        }.frame(width: 4000, height: 4096, alignment: .topLeading)
    }
}

private func hostedGateBodies(_ view: NSView) -> [HostedGateBodyView] {
    if let body = view as? HostedGateBodyView { return [body] }
    return view.subviews.flatMap(hostedGateBodies)
}

@MainActor private func runHostedLayoutChecks() {
    _ = NSApplication.shared
    let first = TimelineHostedItemCoverage(items: [CGRect(x: 30, y: 40, width: 80, height: 24)])
    let state = HostedGateFixtureState(coverage: first)
    let counts = HostedGateBodyCounts()
    state.gate.update(coverage: first, active: true, deferred: false)
    let scroll = GridNativeScrollView(frame: CGRect(x: 0, y: 0, width: 512, height: 256))
    scroll.contentView = TimelineClipView()
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.horizontalScrollElasticity = .none
    scroll.verticalScrollElasticity = .none
    let host = GridHostingView(rootView: HostedGateFixture(state: state, counts: counts))
    if #available(macOS 13, *) { host.sizingOptions = [] }
    if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
    host.frame = CGRect(x: 0, y: 0, width: 4000, height: 4096)
    let document = GridDocumentView(frame: host.frame)
    document.autoresizesSubviews = false
    document.host = host
    document.addSubview(host)
    scroll.documentView = document
    let sizeInput = GridDocumentSizeView(frame: .zero)
    sizeInput.documentSize = document.frame.size
    sizeInput.hostingWidth = document.frame.width
    document.addSubview(sizeInput)

    struct Commit {
        let generation: UInt64
        let active: Bool
        let bodyCount: Int
        let scale: CGFloat?
        let anchorWasPending: Bool
        let originBeforeAnchor: CGFloat
    }
    var commits: [Commit] = []
    sizeInput.hostedProjectionDidLayout = {
        let needed = state.gate.needsCommit
        let committed = state.gate.commitHostedProjection()
        if needed && committed {
            let bodies = hostedGateBodies(host)
            commits.append(Commit(generation: state.gate.requested.generation,
                active: state.gate.requested.active, bodyCount: bodies.count, scale: bodies.first?.scale,
                anchorWasPending: scroll.zoomAnchor != nil, originBeforeAnchor: scroll.contentView.bounds.minX))
        }
        sizeInput.waitsForHostedProjection = state.gate.requiresHosted(coverage: state.coverage)
        return committed
    }
    // This is the production NativeGridScroll -> GridHostingView -> document
    // size input chain; only the controller's final gate callback is supplied
    // by the fixture, allowing the removal order to be observed directly.
    scroll.hostedProjectionDidLayout = { [weak document] in document?.commitHostedProjection() ?? true }
    host.didLayout = { [weak scroll] in scroll?.commitHostedProjection() }
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    sizeInput.applyDocumentSize()
    for _ in 0..<3 {
        document.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    func layoutNow() {
        host.needsLayout = true
        document.layoutSubtreeIfNeeded()
    }
    func requirePixel(green: Bool, _ message: String) {
        // No run-loop turn or delayed repair is allowed before this first-frame
        // read. Cache only the visible viewport, never the large document.
        guard let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else {
            preconditionFailure("could not capture the native viewport")
        }
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
        let isGreen = color.greenComponent > color.redComponent + 0.4 && color.alphaComponent > 0.9
        let isWhite = color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9
        HostedGateChecks.require(green ? isGreen : isWhite, message)
    }
    HostedGateChecks.require(hostedGateBodies(host).count == 1 && !state.gate.needsCommit,
        "the actual item scope and commit sentinel must mount and acknowledge active fallback")
    HostedGateChecks.require(commits.last?.bodyCount == 1 && commits.last?.scale == 10,
        "initial acknowledgement must follow creation of the hosted item body")
    requirePixel(green: true, "active fallback must draw in the actual hosting surface")
    state.zoom.value = 2
    layoutNow()
    HostedGateChecks.require(hostedGateBodies(host).first?.scale == 20,
        "a mounted fallback body must observe incoming zoom")

    let beforeRetirementOrigin = scroll.contentView.bounds.minX
    scroll.zoomAnchor = (fraction: 0.75, screenX: 64, width: 4000)
    state.gate.update(coverage: first, active: false, deferred: false)
    scroll.commitHostedProjection()
    HostedGateChecks.require(scroll.zoomAnchor != nil && scroll.contentView.bounds.minX == beforeRetirementOrigin,
        "native commit must not apply an anchor before the retiring graph has laid out")
    layoutNow()
    HostedGateChecks.require(hostedGateBodies(host).isEmpty && counts.dismantles == 1,
        "retirement must remove the real NSViewRepresentable body")
    HostedGateChecks.require(commits.last?.active == false && commits.last?.bodyCount == 0 && commits.last?.anchorWasPending == true,
        "the host callback must acknowledge retirement only after removing the body and before applying its anchor")
    HostedGateChecks.require(!state.gate.needsCommit && !sizeInput.waitsForHostedProjection,
        "retirement must immediately release the document's hosted layout requirement")
    HostedGateChecks.require(scroll.zoomAnchor == nil && abs(scroll.contentView.bounds.minX - 2936) < 0.001,
        "the matching host commit must apply the queued anchor after retirement")
    requirePixel(green: false, "retired fallback must leave no old pixels in the first committed frame")
    let offscreenUpdates = counts.updates
    let inactiveGeneration = state.gate.requested.generation
    for zoom in [1.25, 1.75, 2.5, 3.0] { state.zoom.value = zoom; layoutNow() }
    HostedGateChecks.require(counts.updates == offscreenUpdates && hostedGateBodies(host).isEmpty,
        "offscreen fallback must stop receiving zoom-driven hosted updates")
    HostedGateChecks.require(state.gate.requested.generation == inactiveGeneration,
        "native zoom inside empty prepared coverage must not churn gate generations")

    scroll.zoomAnchor = (fraction: 0.2, screenX: 20, width: 4000)
    state.gate.update(coverage: first, active: true, deferred: false)
    scroll.commitHostedProjection()
    HostedGateChecks.require(scroll.zoomAnchor != nil && state.gate.needsCommit,
        "reentry must wait for the newly mounted fallback body")
    layoutNow()
    HostedGateChecks.require(hostedGateBodies(host).first?.scale == 30 && counts.mounts == 2,
        "reentry must mount the latest zoom scale rather than reuse a retired projection")
    HostedGateChecks.require(commits.last?.scale == 30 && commits.last?.anchorWasPending == true,
        "activation acknowledgement must observe the new scale before anchor movement")
    HostedGateChecks.require(scroll.zoomAnchor == nil && abs(scroll.contentView.bounds.minX - 780) < 0.001,
        "reentry must complete the anchor only after the current body is mounted")
    requirePixel(green: true, "the reentered hosted body must be present in the first committed frame")

    state.gate.update(coverage: first, active: false, deferred: false)
    state.gate.update(coverage: first, active: true, deferred: false)
    let reversal = state.gate.requested.generation
    scroll.zoomAnchor = (fraction: 0.25, screenX: 0, width: 4000)
    scroll.commitHostedProjection()
    HostedGateChecks.require(state.gate.needsCommit && scroll.zoomAnchor != nil,
        "a repeated active value with a new generation must reject the prior hosted sentinel")
    layoutNow()
    HostedGateChecks.require(commits.last?.generation == reversal && commits.last?.bodyCount == 1 && scroll.zoomAnchor == nil,
        "rapid retirement reversal must acknowledge exactly the latest rendered generation")

    let structural = TimelineHostedItemCoverage(items: first.items, identity: 2)
    state.coverage = structural
    state.gate.update(coverage: structural, active: false, deferred: true)
    scroll.zoomAnchor = (fraction: 0.3, screenX: 0, width: 4000)
    layoutNow()
    HostedGateChecks.require(hostedGateBodies(host).count == 1 && state.gate.needsCommit && scroll.zoomAnchor != nil,
        "a new structural scope must stay mounted and block the anchor until its deferred request is published")
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    layoutNow()
    HostedGateChecks.require(hostedGateBodies(host).isEmpty && !state.gate.needsCommit && scroll.zoomAnchor == nil,
        "the deferred structural generation must retire and acknowledge its own rendered graph")

    // Exercise both native preflight entry points with an actual dormant
    // hosted scope. Each jump must finish mounting/removal before it returns.
    scroll.contentView.scroll(to: .zero)
    let horizontal = TimelineHostedItemCoverage(items: [CGRect(x: 100, y: 40, width: 10, height: 24)], identity: 3)
    state.coverage = horizontal
    state.gate.update(coverage: horizontal, active: false, deferred: false)
    layoutNow()
    var horizontalPreparedBeforeMove = false
    scroll.prepareHostedHorizontalScroll = { x in
        horizontalPreparedBeforeMove = horizontalPreparedBeforeMove || scroll.contentView.bounds.minX != x
        let viewport = CGRect(x: x, y: scroll.contentView.bounds.minY, width: 512, height: 256)
        let active = horizontal.containsItems(viewport: viewport, documentSize: document.frame.size, scale: state.zoom.value * 10)
        let changed = state.gate.update(coverage: horizontal, active: active, deferred: false)
        return changed || state.gate.needsCommit
    }
    scroll.contentView.scroll(to: CGPoint(x: 2560, y: 0))
    HostedGateChecks.require(horizontalPreparedBeforeMove && state.gate.requested.active && !state.gate.needsCommit,
        "horizontal native scroll must mount fallback before revealing a distant destination")
    requirePixel(green: true, "horizontal preflight must draw the fallback in the first exposed frame")
    scroll.contentView.setBoundsOrigin(.zero)
    HostedGateChecks.require(!state.gate.requested.active && !state.gate.needsCommit && hostedGateBodies(host).isEmpty,
        "direct horizontal bounds movement must retire fallback before exposing native-only content")
    requirePixel(green: false, "horizontal retirement must not leave pixels from the previous destination")
    scroll.prepareHostedHorizontalScroll = nil
    let vertical = TimelineHostedItemCoverage(items: [CGRect(x: 30, y: 3000, width: 10, height: 24)], identity: 4)
    state.coverage = vertical
    state.gate.update(coverage: vertical, active: false, deferred: false)
    layoutNow()
    var verticalPreparedBeforeMove = false
    scroll.prepareHostedVerticalScroll = { y in
        verticalPreparedBeforeMove = verticalPreparedBeforeMove || scroll.contentView.bounds.minY != y
        let viewport = CGRect(x: scroll.contentView.bounds.minX, y: y, width: 512, height: 256)
        let active = vertical.containsItems(viewport: viewport, documentSize: document.frame.size, scale: state.zoom.value * 10)
        let changed = state.gate.update(coverage: vertical, active: active, deferred: false)
        return changed || state.gate.needsCommit
    }
    scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 2560))
    HostedGateChecks.require(verticalPreparedBeforeMove && state.gate.requested.active && !state.gate.needsCommit,
        "direct vertical bounds movement must mount fallback before exposing a distant row")
    requirePixel(green: true, "vertical preflight must draw fallback in the first exposed frame")
    scroll.contentView.scroll(to: .zero)
    HostedGateChecks.require(!state.gate.requested.active && !state.gate.needsCommit && hostedGateBodies(host).isEmpty,
        "vertical native scrolling must acknowledge retirement before exposing earlier rows")
    requirePixel(green: false, "vertical retirement must leave no old fallback pixels")
    scroll.prepareHostedVerticalScroll = nil

    state.coverage = nil
    state.gate.update(coverage: nil, active: true, deferred: false)
    layoutNow()
    HostedGateChecks.require(hostedGateBodies(host).count == 1 && state.gate.requiresHosted(coverage: nil),
        "unavailable native coverage must retain the ordinary hosted fallback path")
    state.hasItems = false
    state.gate.update(coverage: nil, active: false, deferred: false)
    layoutNow()
    HostedGateChecks.require(hostedGateBodies(host).isEmpty && !state.gate.needsCommit,
        "removing the last hosted item must also commit the empty scope")
    sizeInput.hostedProjectionDidLayout = nil
    host.didLayout = nil
    window.close()
}

MainActor.assumeIsolated {
    runHostedCoverageChecks()
    runHostedGenerationChecks()
    runHostedLayoutChecks()
    print("TIMELINE_HOSTED_ITEMS_GATE_\(HostedGateChecks.count)_CHECKS_OK")
}
