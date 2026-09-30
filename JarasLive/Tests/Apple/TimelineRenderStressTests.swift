
@MainActor func renderStress() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("jaras-many-items-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let url = temporary.appendingPathComponent("audio.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000)!
    buffer.frameLength = 441000
    for index in 0..<441000 { for channel in 0..<2 { buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 0.02) * 0.3) } }
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
    let cache = TimelineAudioWaveform.shared
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if let header = cache.header(url), cache.geometry(url, header: header, block: 0, pixelsPerSecond: 1) != nil { break }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    let header = cache.header(url)!
    var song = Song(id: UUID(), name: "Stress", duration: 500, bpm: 120, tracks: [], parts: [])
    for index in 0..<100 {
        var track = Track(id: UUID(), name: "Track \(index)", role: .click, volume: 1, pan: 0, mute: false, solo: false)
        for item in 0..<40 {
            track.clips.append(AudioClip(id: UUID(), name: "Audio \(index) / \(item)", startTime: Double(item) * 12, duration: 10, audioFile: AudioFile(path: "audio.wav")))
        }
        song.tracks.append(track)
    }
    let key = TimelineRenderKey(revision: 1, songID: song.id, movingClip: nil, movingStart: 0, movingTrack: nil, movingRegion: nil, regionDelta: 0, resizingRegion: nil, resizedStart: 0, resizedEnd: 0)
    var durations: [Double] = []
    for scale in [1.0, 1.05, 1.1, 1.2, 1.35, 1.5, 1.65, 1.8, 2.0, 2.2] {
        // Warm the corresponding level, independently of the render clock.
        let until = Date().addingTimeInterval(5)
        while Date() < until && cache.geometry(url, header: header, block: 0, pixelsPerSecond: scale) == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        let content = TimelineDrawing(visibleRect: CGRect(x: 0, y: 0, width: 1100, height: 720), song: song, renderKey: key, rowHeight: 64, rulerHeight: 55, extent: 500, selectedClips: [], movingClip: nil, movingStart: 0, mediaDirectory: temporary)
            .frame(width: 500 * scale, height: 7000, alignment: .topLeading)
            .frame(width: 1100, height: 720, alignment: .topLeading).clipped()
        let start = ProcessInfo.processInfo.systemUptime
        let renderer = ImageRenderer(content: content); renderer.scale = 1
        guard let image = renderer.cgImage else { preconditionFailure("real grid must produce a frame") }
        precondition(image.width == 1100 && image.height == 720)
        durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    print("REAL_GRID_4000_ITEMS_WARM_ZOOM_RENDER_MS=\(durations)")
    precondition(durations.allSatisfy { $0 < 1000 }, "a cached grid must not stall for a second when zooming")
    precondition(cache.drawing(url, header: header, start: 0, end: 10, pixelsPerSecond: 0.16478).paths.allSatisfy { !$0.isEmpty }, "extreme zoom retains a curve covering the whole file")
}
try MainActor.assumeIsolated { try renderStress() }
