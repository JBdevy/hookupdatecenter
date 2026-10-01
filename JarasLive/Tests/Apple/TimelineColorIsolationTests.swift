private enum TimelineColorDrawProbe {
    private static let lock = NSLock()
    private static var count = 0
    static var items: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func record() { lock.lock(); count += 1; lock.unlock() }
}
@MainActor func checkColorIsolation() {
    _ = NSApplication.shared
    let key = "jaras.test.appearance." + UUID().uuidString
    let color = AppearanceColor.shared(key, default: 0x181818)
    color.value = 0x334455
    precondition(UserDefaults.standard.object(forKey: key) == nil, "Dragging must never persist individual samples")
    color.save(0x334455)
    precondition(UserDefaults.standard.integer(forKey: key) == 0x334455)
    UserDefaults.standard.removeObject(forKey: key)
    var song = Song(id: UUID(), name: "Colors", duration: 120, bpm: 120, tracks: [], parts: [])
    for index in 0..<16 {
        var track = Track(id: UUID(), name: "Track \(index)", role: .click)
        for item in 0..<10 { track.clips.append(AudioClip(id: UUID(), name: "Audio", startTime: Double(item) * 12, duration: 10, waveform: [0.2,0.8,0.4,0.6])) }
        song.tracks.append(track)
    }
    let renderKey = TimelineRenderKey(revision: 1, songID: song.id, movingClip: nil, movingStart: 0, movingTrack: nil, movingRegion: nil, regionDelta: 0, resizingRegion: nil, resizedStart: 0, resizedEnd: 0)
    let content = TimelineDrawing(visibleRect: CGRect(x: 0,y: 0,width: 800,height: 600), song: song, renderKey: renderKey, rowHeight: 64, rulerHeight: 55, extent: 120, selectedClips: [], movingClip: nil, movingStart: 0)
        .frame(width: 800,height: 1100,alignment: .topLeading).frame(width: 800,height: 600,alignment: .topLeading).clipped()
    let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 800,height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: content); window.contentView = host
    window.orderFrontRegardless()
    func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
    pump(); pump()
    precondition(TimelineColorDrawProbe.items > 0, "Fixture must paint real items before checking invalidation")
    let before = TimelineColorDrawProbe.items
    for index in 1...12 {
        AppearanceColor.shared("jaras.timeline.background", default: 0x181818).value = 0x181818 + index
        AppearanceColor.shared("jaras.timeline.primaryGrid", default: 0x657789).value = 0x657789 + index
        AppearanceColor.shared("jaras.timeline.secondaryGrid", default: 0x657789).value = 0x657789 - index
        pump()
    }
    precondition(TimelineColorDrawProbe.items == before, "RGB previews must not repaint audio items or waveforms")
    window.orderOut(nil)
    print("TIMELINE_COLOR_PREVIEW_ZERO_ITEM_REDRAWS_AND_PERSIST_ONLY_ON_CONFIRM_OK")
}
MainActor.assumeIsolated { checkColorIsolation() }
