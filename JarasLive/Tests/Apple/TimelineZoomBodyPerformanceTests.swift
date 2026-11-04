@MainActor private func benchmarkZoomBody() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-zoom-bench-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)!
    pcm.frameLength = 96000
    for i in 0..<Int(pcm.frameLength) { for channel in 0..<2 { pcm.floatChannelData![channel][i] = Float(sin(Double(i)*0.031)*0.5) } }
    for i in 0..<64 {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("audio-\(i).wav"), settings: format.settings)
        try file.write(from: pcm)
    }
    let deadline = Date().addingTimeInterval(15)
    while !MetalWaveformRenderer.isSupported, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(MetalWaveformRenderer.isSupported)
    for count in (ProcessInfo.processInfo.environment["CATLIVE_ZOOM_PROFILE"] == "1" ? [500] : [50, 500]) {
        let parts = (0..<count).map { Part(id: UUID(), name: "Region \($0)", startTime: Double($0)*3, endTime: Double($0)*3+2.8) }
        let tracks = (0..<64).map { index -> Track in
            var track = Track(id: UUID(), name: "Stem \(index)", role: TrackRole(rawValue: "standard"))
            track.clips = (0..<count).map { AudioClip(id: UUID(), name: "Audio \($0)", startTime: Double($0)*3, duration: 2,
                audioFile: AudioFile(path: "audio-\(index).wav")) }
            return track
        }
        let song = Song(id: UUID(), name: "Zoom benchmark", duration: Double(count)*3, bpm: 120, tracks: tracks, parts: parts)
        let rows = TrackRowLayout(tracks: tracks, baseHeight: 64)
        let metadata = TimelineRenderMetadata(song: song)
        let key = TimelineRenderKey(revision: 1, songID: song.id, movingClip: nil, movingStart: 0, movingTrack: nil,
            movingRegion: nil, regionDelta: 0, resizingRegion: nil, resizedStart: 0, resizedEnd: 0)
        let body = NativeTimelineAudioBodyView()
        body.configure(NativeTimelineAudioBodyConfiguration.make(song: song, key: key, rows: rows, metadata: metadata,
            rulerHeight: 55, selectedClips: [], mediaDirectory: directory, missingAudioPaths: []))
        for distant in (ProcessInfo.processInfo.environment["CATLIVE_ZOOM_PROFILE"] == "1" ? [true] : [false, true]) {
            var timings: [Double] = []
            for frame in 0..<(ProcessInfo.processInfo.environment["CATLIVE_ZOOM_PROFILE"] == "1" ? 1500 : 100) {
                let scale = (distant ? 1 : 80) * exp(sin(Double(frame)/17)*0.6)
                let viewport = CGRect(x: max(0, song.duration*0.5*scale-550), y: 0, width: 1100, height: 700)
                let start = ProcessInfo.processInfo.systemUptime
                body.project(viewport: viewport, documentSize: CGSize(width: song.duration*scale, height: rows.totalHeight+55), scale: scale)
                if frame > 5 { timings.append((ProcessInfo.processInfo.systemUptime-start)*1000) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            }
            timings.sort()
            print("ZOOM_BODY clips=\(count*64) distant=\(distant) medianMS=\(timings[timings.count/2]) p95MS=\(timings[Int(Double(timings.count-1)*0.95)])")
        }
        body.configure(nil)
    }
}
setbuf(stdout,nil)
try MainActor.assumeIsolated { try benchmarkZoomBody() }
