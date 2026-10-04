import AppKit

private func close(_ actual: CGFloat, _ expected: CGFloat) -> Bool { abs(actual - expected) < 0.000001 }

MainActor.assumeIsolated {
    for width: CGFloat in [360, 800, 1240] {
        var policy = TimelinePlaybackFollowPolicy()
        var viewport = CGRect(x: 1000, y: 71, width: width, height: 500)
        let center = viewport.midX
        precondition(policy.destination(position: Double(center - 1) / 10, pixelsPerSecond: 10, contentWidth: 10000,
                                        viewport: viewport, source: "song/main") == nil, "before center the viewport remains still")
        precondition(policy.destination(position: Double(center) / 10, pixelsPerSecond: 10, contentWidth: 10000,
                                        viewport: viewport, source: "song/main") == nil, "touching center does not scroll")
        for distance: CGFloat in [0.125, 0.5, 1.25, 2, 5.75] {
            let x = policy.destination(position: Double(center + distance) / 10, pixelsPerSecond: 10, contentWidth: 10000,
                                       viewport: viewport, source: "song/main")!
            precondition(close(x, 1000 + distance), "each display sample follows continuously after the midpoint")
            viewport.origin.x = x
        }
    }
    var policy = TimelinePlaybackFollowPolicy()
    let viewport = CGRect(x: 2000, y: 30, width: 800, height: 500)
    precondition(policy.destination(position: 225, pixelsPerSecond: 10, contentWidth: 10000,
                                    viewport: viewport, source: "song/main") == nil)
    precondition(policy.destination(position: 225, pixelsPerSecond: 10, contentWidth: 10000,
                                    viewport: viewport, source: "song/sub") == 1850, "SubPlay takes visual priority in the left half too")
    precondition(policy.destination(position: 120, pixelsPerSecond: 10, contentWidth: 10000,
                                    viewport: viewport, source: "song/main") == 800, "cancelling SubPlay returns to an earlier main playhead")
    precondition(policy.destination(position: 110, pixelsPerSecond: 10, contentWidth: 10000,
                                    viewport: viewport, source: "song/main") == 700, "backward seek or loop reveals the new position")
    precondition(policy.destination(position: nil, pixelsPerSecond: 10, contentWidth: 10000,
                                    viewport: viewport, source: "song/main") == nil, "paused and stopped transport does not follow")
    precondition(policy.destination(position: 225, pixelsPerSecond: 10, contentWidth: 10000,
                                    viewport: viewport, source: "song/main") == nil, "resuming before center stays still")
    precondition(policy.destination(position: 2000, pixelsPerSecond: 10, contentWidth: 10000,
                                    viewport: viewport, source: "song/main") == 9200, "document end clamps the scroll origin")
    precondition(policy.destination(position: 0, pixelsPerSecond: 10, contentWidth: 10000,
                                    viewport: viewport, source: "song/main") == 0, "time zero never scrolls negative")
    for invalid in [Double.nan, Double.infinity, -Double.infinity] {
        precondition(policy.destination(position: invalid, pixelsPerSecond: 10, contentWidth: 10000,
                                        viewport: viewport, source: "song/main") == nil)
    }
    policy.reset()
    precondition(policy.destination(position: 239, pixelsPerSecond: 10, contentWidth: 10000,
                                    viewport: viewport, source: "song/main") == nil)
    precondition(policy.destination(position: 235, pixelsPerSecond: 10, contentWidth: 10000,
                                    viewport: viewport, source: "song/main") == 1950,
                 "backward playback is revealed even when the needle remains visible before center")
    print("PLAYBACK_FOLLOW_MIDPOINT_PRIORITY_BACKWARD_STOP_AND_LIMITS_OK")

    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1700, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 1700, height: 600))
    window.contentView = root
    let scroll = GridNativeScrollView(frame: CGRect(x: 300, y: 0, width: 800, height: 500))
    scroll.contentView = TimelineClipView()
    scroll.borderType = .noBorder
    scroll.horizontalScrollElasticity = .none
    scroll.verticalScrollElasticity = .none
    let document = NSView(frame: CGRect(x: 0, y: 0, width: 10000, height: 1000))
    let follow = TimelinePlaybackFollowView(frame: document.bounds)
    root.addSubview(scroll)
    scroll.documentView = document
    document.addSubview(follow)
    scroll.tile()
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 30))
    var updating = false
    var publications = 0
    var lastBucket: CGFloat = 0
    var preparedOrigins: [CGFloat] = []
    var latest: (position: Double?, scale: CGFloat, width: CGFloat, source: String) = (nil, 10, 10000, "song/main")
    scroll.prepareHorizontalScroll = { x in
        precondition(!updating, "tile publication must happen after the representable update returns")
        precondition(scroll.contentView.bounds.minX != x, "prepare destination before exposing it")
        preparedOrigins.append(x)
        let bucket = floor(x / 512) * 512
        guard bucket != lastBucket else { return false }
        lastBucket = bucket
        publications += 1
        // Reproduce the representable update produced by publishing its bucket.
        follow.update(position: latest.position, pixelsPerSecond: latest.scale, contentWidth: latest.width, source: latest.source)
        return true
    }
    func update(_ position: Double?, scale: CGFloat = 10, width: CGFloat = 10000, source: String = "song/main") {
        latest = (position, scale, width, source)
        updating = true
        follow.update(position: position, pixelsPerSecond: scale, contentWidth: width, source: source)
        updating = false
    }
    func flush() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    update(39); flush()
    precondition(close(scroll.contentView.bounds.minX, 0))
    update(41)
    precondition(close(scroll.contentView.bounds.minX, 0), "applying leaves SwiftUI's update stack")
    flush()
    precondition(close(scroll.contentView.bounds.minX, 10), "uses the 800-point clip, independent of 1700-point window and sidebars")
    precondition(close(scroll.contentView.bounds.minY, 30), "horizontal follow preserves vertical scrolling")
    update(200); update(210); flush()
    precondition(close(scroll.contentView.bounds.minX, 1700), "one queued operation consumes the latest presentation sample")
    precondition(publications == 1, "one bucket update does not create a publication loop")
    let preparesAfterFollow = preparedOrigins.count
    flush()
    precondition(preparedOrigins.count == preparesAfterFollow, "native preparation does not keep scheduling itself")
    update(180, source: "song/sub"); flush()
    precondition(close(scroll.contentView.bounds.minX, 1400), "SubPlay reveals an earlier position")
    update(180, source: "song/main"); flush()
    precondition(close(scroll.contentView.bounds.minX, 1400), "promotion into main preserves the incoming SubPlay viewport")
    update(180, source: "song/sub"); flush()
    update(60, source: "song/main"); flush()
    precondition(close(scroll.contentView.bounds.minX, 200), "cancelling SubPlay returns to main")
    update(300)
    update(nil); flush()
    precondition(close(scroll.contentView.bounds.minX, 200), "stop invalidates an already queued scroll")

    scroll.playbackFollowSuspendedUntil = ProcessInfo.processInfo.systemUptime + 10
    update(300); flush()
    precondition(close(scroll.contentView.bounds.minX, 200), "follow yields between committed zoom frames even without an anchor")
    update(301); flush()
    precondition(close(scroll.contentView.bounds.minX, 200), "playback samples cannot take back the viewport during a zoom burst")
    scroll.playbackFollowSuspendedUntil = 0
    scroll.zoomAnchor = (0.5, 400, 10000)
    update(300, source: "song/sub"); flush()
    precondition(close(scroll.contentView.bounds.minX, 200), "follow yields to an active wheel zoom")
    scroll.zoomAnchor = nil
    update(300, source: "song/sub"); flush()
    precondition(close(scroll.contentView.bounds.minX, 2600), "the deferred head switch survives zoom")
    update(100, scale: 20, width: 20000, source: "song/main"); flush()
    precondition(close(scroll.contentView.bounds.minX, 2600), "future scale cannot scroll the old document geometry")
    document.setFrameSize(CGSize(width: 20000, height: 1000))
    update(100, scale: 20, width: 20000, source: "song/main"); flush()
    precondition(close(scroll.contentView.bounds.minX, 1600), "handoff waits for the matching document scale")

    NativeTimelineInputGate.shared.setBlocked(true, for: window)
    update(300, scale: 20, width: 20000); flush()
    precondition(close(scroll.contentView.bounds.minX, 1600), "modal input gate suspends follow")
    NativeTimelineInputGate.shared.setBlocked(false, for: window)
    update(300, scale: 20, width: 20000); flush()
    precondition(close(scroll.contentView.bounds.minX, 5600))
    scroll.setFrameSize(CGSize(width: 1200, height: 500)); scroll.tile()
    update(311, scale: 20, width: 20000); flush()
    precondition(close(scroll.contentView.bounds.minX, 5620), "resized grid uses its new midpoint")
    update(nil)
    precondition(follow.hitTest(.zero) == nil, "the helper never intercepts timeline gestures")
    weak var released: TimelinePlaybackFollowView?
    do {
        let pending = TimelinePlaybackFollowView(frame: document.bounds)
        released = pending
        pending.update(position: 300, pixelsPerSecond: 20, contentWidth: 20000, source: "song/main")
    }
    precondition(released == nil, "queued work never retains a removed follow view")
    flush()
    window.orderOut(nil)
    print("PLAYBACK_FOLLOW_NATIVE_CLIP_PREPARATION_COALESCING_ZOOM_GATE_AND_RESIZE_OK")
}
