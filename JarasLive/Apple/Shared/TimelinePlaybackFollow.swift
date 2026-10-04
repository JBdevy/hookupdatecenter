#if os(macOS)
import AppKit
import SwiftUI

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
                              viewport: CGRect, source: String) -> CGFloat? {
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
        let origin = min(max(0, x - viewport.width / 2), max(0, contentWidth - viewport.width))
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
            pending = nil
            needsApply = false
            policy.reset()
            return
        }
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

    private func geometryMatches(_ sample: Sample, document: NSView) -> Bool {
        let width = document.frame.width
        let tolerance = max(0.0000001, max(abs(width).ulp, abs(sample.contentWidth).ulp) * 8)
        return sample.contentWidth.isFinite && sample.contentWidth > 0 &&
            abs(width - sample.contentWidth) <= tolerance
    }

    private func applyLatestSample() {
        guard needsApply, let sample, sample.position != nil, let window,
              window.attachedSheet == nil, !NativeTimelineInputGate.shared.isBlocked(window),
              let scroll = horizontalScroll, scroll.permitsPlaybackFollow,
              let document = scroll.documentView, geometryMatches(sample, document: document) else { return }
        let clip = scroll.contentView
        let viewport = clip.bounds
        var nextPolicy = policy
        guard let x = nextPolicy.destination(position: sample.position, pixelsPerSecond: sample.pixelsPerSecond,
                                             contentWidth: sample.contentWidth, viewport: viewport, source: sample.source) else {
            policy = nextPolicy
            needsApply = false
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        scroll.prepareHorizontalViewport(at: x)
        // Tile preparation can finish a pending layout. Never apply a position
        // calculated for another scale or viewport width, or consume its handoff.
        guard self.sample == sample, scroll.permitsPlaybackFollow,
              geometryMatches(sample, document: document), clip.bounds == viewport else { return }
        policy = nextPolicy
        needsApply = false
        clip.scroll(to: CGPoint(x: x, y: viewport.minY))
        scroll.reflectScrolledClipView(clip)
    }
}
#endif
