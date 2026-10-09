@MainActor private func verifyCountdownAndPlaybackEndpoint() {
    _ = NSApplication.shared
    let view = NativeSectionProgressView(frame: CGRect(x: 0, y: 0, width: 340, height: 34))
    let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 340, height: 34),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
    defer { view.stop(); window.close() }
    let identity = ObjectIdentifier(view)
    var position = 10.0
    var sampledAt = ProcessInfo.processInfo.systemUptime
    func configure(end: Double, running: Bool = false, countdown: Bool = true) {
        view.configure(running: running, countdown: countdown, start: 10, end: end,
            sample: { (position, sampledAt) })
        view.layoutSubtreeIfNeeded()
    }
    let bar = view.layer!.sublayers!.first!
    // An armed destination at the end of the current song has the same smooth
    // countdown as a section-marker trigger, even without another marker.
    configure(end: 20)
    precondition(bar.frame.width == 340 && bar.backgroundColor == NSColor(JarasTheme.yellow).cgColor)
    position = 15; configure(end: 20)
    precondition(abs(bar.frame.width - 170) < 0.5, "The song-end trigger must show half of its remaining countdown")
    position = 20; configure(end: 20)
    precondition(bar.frame.width == 0, "The countdown reaches zero exactly at the song-end jump")
    // Ignore Next owns the last-item endpoint, not the region boundary.
    position = 20; configure(end: 35)
    precondition(abs(bar.frame.width - 204) < 0.5, "The item tail keeps the countdown visible after the region end")
    position = 30; configure(end: 35)
    precondition(abs(bar.frame.width - 68) < 0.5)
    position = 35; configure(end: 35)
    precondition(bar.frame.width == 0)
    position = 20; configure(end: 35, countdown: false)
    precondition(abs(bar.frame.width - 136) < 0.5 && bar.backgroundColor == NSColor(JarasTheme.green).cgColor,
        "The current section's normal progress uses the same effective endpoint")
    // Display-link cadence is local: no new transport sample or whole-panel
    // layout is required for the yellow bar to continue moving smoothly.
    position = 15; sampledAt = ProcessInfo.processInfo.systemUptime
    configure(end: 20, running: true)
    let initialWidth = bar.frame.width
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.10))
    precondition(bar.frame.width < initialWidth && bar.frame.width > initialWidth - 9,
        "The countdown must advance smoothly between authoritative samples")
    precondition(ObjectIdentifier(view) == identity, "The endpoint change must retain the native progress view")
    view.stop()
    let stoppedWidth = bar.frame.width
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
    precondition(bar.frame.width == stoppedWidth, "Closing or stopping the progress view releases its timer")
    print("SECTION_NATIVE_COUNTDOWN_REGION_END_IGNORE_NEXT_TAIL_LOCAL_PLAYBACK_AND_SMOOTH_SAMPLE_CLOCK_OK")
}
MainActor.assumeIsolated { verifyCountdownAndPlaybackEndpoint() }
