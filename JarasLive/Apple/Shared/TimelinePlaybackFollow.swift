#if os(macOS)
import AppKit
import SwiftUI

/// Opt-in cadence evidence for profiling. The normal path starts no clocks,
/// writes no files and retains no samples. Do not compare CPU by silently
/// reducing the number of applied scroll frames.
private enum TimelineFollowCadenceDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["CATLIVE_PROFILE_FOLLOW"] == "1"
    private static var requests: [Double] = []
    private static var applications: [Double] = []
    static func requested() {
        guard enabled else { return }
        requests.append(ProcessInfo.processInfo.systemUptime)
    }
    static func applied() {
        guard enabled else { return }
        applications.append(ProcessInfo.processInfo.systemUptime)
    }
    static func stopped() {
        guard enabled, !requests.isEmpty else { return }
        let requested = requests, applied = applications
        requests.removeAll(keepingCapacity: true); applications.removeAll(keepingCapacity: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .utility).async {
            let report: [String: Any] = ["requests": requested, "applications": applied]
            guard let data = try? JSONSerialization.data(withJSONObject: report) else { return }
            try? data.write(to: URL(fileURLWithPath: "/tmp/catlive-follow-cadence-\(pid).json"), options: .atomic)
        }
    }
}

/// Advance only after the active needle crosses the visible grid's center.
/// Head changes and backward transport jumps also reveal an earlier position.
struct TimelinePlaybackFollowPolicy {
    private var previousSource: String?
    private var previousPosition: Double?

    mutating func reset() {
        previousSource = nil
        previousPosition = nil
    }

    mutating func destination(position: Double?, pixelsPerSecond: CGFloat, contentWidth: CGFloat,
                              viewport: CGRect, source: String, backingScale: CGFloat = 0) -> CGFloat? {
        guard let position else { reset(); return nil }
        guard position.isFinite, pixelsPerSecond.isFinite, pixelsPerSecond > 0,
              contentWidth.isFinite, contentWidth > 0, viewport.minX.isFinite,
              viewport.width.isFinite, viewport.width > 0 else { return nil }
        let x = CGFloat(max(0, position)) * pixelsPerSecond
        guard x.isFinite else { return nil }
        let changedHead = previousSource.map { $0 != source } ?? false
        let movedBackward = previousPosition.map { position < $0 - 0.000001 } ?? false
        previousSource = source
        previousPosition = position
        guard changedHead || movedBackward || x < viewport.minX || x > viewport.midX else { return nil }
        let limit = max(0, contentWidth - viewport.width)
        var origin = min(max(0, x - viewport.width / 2), limit)
        // At distant zoom levels the viewport moves only a few physical pixels
        // per second. Do not invalidate every hosting/tracking subtree at 60 Hz
        // for movement smaller than a display pixel. The needle still paints
        // continuously, independently of this viewport offset.
        if backingScale.isFinite && backingScale > 0 {
            origin = min(limit, max(0, (origin * backingScale).rounded() / backingScale))
        }
        return abs(origin - viewport.minX) > 0.0000001 ? origin : nil
    }
}

/// Place inside the horizontal grid document. The caller supplies its current
/// presentation sample; this helper owns neither a transport clock nor a timer.
struct TimelinePlaybackFollow: NSViewRepresentable {
    let position: Double?
    let pixelsPerSecond: CGFloat
    let contentWidth: CGFloat
    let source: String

    func makeNSView(context: Context) -> TimelinePlaybackFollowView { TimelinePlaybackFollowView() }
    func updateNSView(_ view: TimelinePlaybackFollowView, context: Context) {
        view.update(position: position, pixelsPerSecond: pixelsPerSecond, contentWidth: contentWidth, source: source)
    }
}

final class TimelinePlaybackFollowView: NSView {
    private struct Sample: Equatable {
        let position: Double?
        let pixelsPerSecond: CGFloat
        let contentWidth: CGFloat
        let source: String
    }
    private var sample: Sample?
    private var policy = TimelinePlaybackFollowPolicy()
    private var needsApply = false
    private var pending: UUID?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(position: Double?, pixelsPerSecond: CGFloat, contentWidth: CGFloat, source: String) {
        let next = Sample(position: position, pixelsPerSecond: pixelsPerSecond, contentWidth: contentWidth, source: source)
        guard sample != next || needsApply else { return }
        sample = next
        guard position != nil else {
            TimelineFollowCadenceDiagnostics.stopped()
            pending = nil
            needsApply = false
            policy.reset()
            return
        }
        TimelineFollowCadenceDiagnostics.requested()
        needsApply = true
        scheduleApply()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { pending = nil }
        else if needsApply { scheduleApply() }
    }

    private func scheduleApply() {
        guard pending == nil else { return }
        let request = UUID()
        pending = request
        // Preparing a new tile bucket can publish SwiftUI state. Leave the
        // representable update before publishing, and consume only its latest
        // sample when several updates arrive in this run-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pending == request else { return }
            self.pending = nil
            self.applyLatestSample()
        }
    }

    private var horizontalScroll: GridNativeScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? GridNativeScrollView { return scroll }
            ancestor = view.superview
        }
        return nil
    }

    private func geometryMatches(_ sample: Sample, clip: NSClipView) -> Bool {
        let width = clip.documentRect.width
        let tolerance = max(0.0000001, max(abs(width).ulp, abs(sample.contentWidth).ulp) * 8)
        return sample.contentWidth.isFinite && sample.contentWidth > 0 &&
            abs(width - sample.contentWidth) <= tolerance
    }

    private func applyLatestSample() {
        guard needsApply, let sample, sample.position != nil, let window,
              window.attachedSheet == nil, !NativeTimelineInputGate.shared.isBlocked(window),
              let scroll = horizontalScroll, scroll.permitsPlaybackFollow,
              scroll.documentView != nil, geometryMatches(sample, clip: scroll.contentView) else { return }
        let clip = scroll.contentView
        let viewport = clip.bounds
        var nextPolicy = policy
        guard let x = nextPolicy.destination(position: sample.position, pixelsPerSecond: sample.pixelsPerSecond,
                                             contentWidth: sample.contentWidth, viewport: viewport, source: sample.source,
                                             backingScale: window.backingScaleFactor) else {
            policy = nextPolicy
            needsApply = false
            return
        }
        // NSClipView.scroll applies the origin directly. A nested Core
        // Animation commit here flushes unrelated hosting layouts at 60 Hz.
        // Let the normal display cycle commit the updated viewport and layers.
        scroll.prepareHorizontalViewport(at: x)
        // Tile preparation can finish a pending layout. Never apply a position
        // calculated for another scale or viewport width, or consume its handoff.
        guard self.sample == sample, scroll.permitsPlaybackFollow,
              geometryMatches(sample, clip: clip), clip.bounds == viewport else { return }
        policy = nextPolicy
        needsApply = false
        clip.scroll(to: CGPoint(x: x, y: viewport.minY))
        scroll.reflectScrolledClipView(clip)
        TimelineFollowCadenceDiagnostics.applied()
    }
}
#endif
