import Foundation
import AVFoundation

// Uses the same waveform preparation and missing-media filtering as opening
// a project. One bad source must not stop the valid stems or erase references.
@MainActor func run() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for rate in [44100.0, 48000.0] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let valid = root.appendingPathComponent("Valid-\(Int(rate)).wav")
        let broken = root.appendingPathComponent("Unreadable-\(Int(rate)).wav")
        try Data("invalid audio".utf8).write(to: broken)
        do {
            let output = try AVAudioFile(forWriting: valid, settings: format.settings)
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
            pcm.frameLength = pcm.frameCapacity
            for channel in 0..<2 {
                for index in 0..<Int(pcm.frameLength) { pcm.floatChannelData![channel][index] = 0.2 * sin(Float(index) * 0.07) }
            }
            try output.write(from: pcm)
        }
        var project = Project.empty(name: "Unreadable source")
        project.songs[0].tracks = [valid, broken].map { url in
            var track = Track(id: UUID(), name: url.lastPathComponent, role: .other)
            track.clips = [AudioClip(id: UUID(), name: track.name, startTime: 0, duration: 1, audioFile: AudioFile(path: url.lastPathComponent))]
            return track
        }
        project.songs[0].duration = 1
        var ignored = Set<String>()
        let prepared = try StemProjectImporter.populateChannelOverviews(project, directory: root, onUnreadable: { path, _ in ignored.insert(path) })
        precondition(ignored == [broken.lastPathComponent])
        precondition(prepared.songs[0].tracks[1].clips[0].audioFile?.path == broken.lastPathComponent)
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        let audio = StemAudioPlayback(engine: engine, realtime: false)
        audio.open(directory: root)
        audio.setMissingAudioPaths(ignored)
        defer { audio.prepareForClosing() }
        let snapshot = ShowSnapshot(project: prepared, transport: TransportState(playing: true, songId: prepared.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
        try audio.update(snapshot, revision: 1)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        var peak: Float = 0
        for _ in 0..<48 {
            if try engine.renderOffline(256, to: pcm) == .success {
                for index in 0..<Int(pcm.frameLength) { peak = max(peak, abs(pcm.floatChannelData![0][index])) }
            }
        }
        precondition(peak > 0.15, "Unreadable source prevented valid stem playback")
        print("PASS: unreadable source skipped; valid PCM and original reference preserved", rate, peak)
    }
}
Task { @MainActor in
    do { try await run(); exit(0) }
    catch { print(error); exit(1) }
}
dispatchMain()
