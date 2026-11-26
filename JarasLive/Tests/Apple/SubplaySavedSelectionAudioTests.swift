import AVFoundation
import Foundation
import Darwin
setbuf(stdout, nil)

@MainActor private func run() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-saved-subplay-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 30))!
    pcm.frameLength = pcm.frameCapacity
    for c in 0..<2 { pcm.floatChannelData![c].update(repeating: 0.1, count: Int(pcm.frameLength)) }
    try AVAudioFile(forWriting: directory.appendingPathComponent("tone.wav"), settings: format.settings).write(from: pcm)
    var project = Project.empty(name: "Saved exclusive tracks")
    let outgoing = UUID(), incoming = UUID()
    project.songs[0].duration = 40
    project.songs[0].parts = [Part(id: outgoing, name: "Outgoing", startTime: 0, endTime: 10),
        Part(id: incoming, name: "Incoming", startTime: 20, endTime: 30)]
    project.songs[0].regionOwnershipInitialized = true
    project.songs[0].regionOwnershipVersion = 4
    project.songs[0].tracks = (0..<2).map { index in
        var track = Track(id: UUID(), name: index == 0 ? "CLICK" : "Other", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Outgoing tail", startTime: 0, duration: 25,
            audioFile: AudioFile(path: "tone.wav"), regionOwnerID: outgoing),
            AudioClip(id: UUID(), name: "Incoming", startTime: 20, duration: 10,
                audioFile: AudioFile(path: "tone.wav"), gain: 2, regionOwnerID: incoming)]
        return track
    }
    var setlist = RegionSetlist()
    setlist.automaticSubplay = true; setlist.automaticSubplaySeconds = 1
    setlist.subplayExclusiveTrackIDs = [project.songs[0].tracks[0].id]
    project.regionSetlist = setlist
    // Persist and decode into a fresh engine; never open or reapply the chooser.
    let saved = try JSONEncoder().encode(project)
    for automatic in [false, true] {
        let restored = try JSONDecoder().decode(Project.self, from: saved)
        let core = JarasCoreBridge()
        try core.load(projectData: JSONEncoder().encode(restored))
        func execute(_ command: String, _ target: UUID? = nil, _ value: Double = 0) throws {
            try core.execute(command: command, target: target?.uuidString, value: value)
        }
        func snapshot() throws -> ShowSnapshot { try JSONDecoder().decode(ShowSnapshot.self, from: core.snapshot()) }
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let audio = StemAudioPlayback(engine: engine, realtime: false)
        audio.open(directory: directory)
        defer { audio.prepareForClosing() }
        try audio.update(snapshot(), revision: 1)
        try execute("selectRegion", outgoing); try execute("play"); try execute("queueRegion", incoming)
        if automatic { core.advance(9) }
        else { try execute("seek", nil, 9); try execute("subPlay") }
        let state = try snapshot()
        precondition(state.transport.subExclusivePlaybackRegionId == incoming, "Saved selection must be active on the first secondary head")
        try audio.update(state, revision: 1)
        if !engine.isRunning { try engine.start() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func check(_ expected: Float) throws {
            var peak: Float = 0
            for block in 0..<96 {
                let status = try engine.renderOffline(512, to: output)
                precondition(status == .success)
                if block > 80 { for i in 0..<Int(output.frameLength) { peak = max(peak, abs(output.floatChannelData![0][i])) } }
            }
            print("SUBPLAY_SAVED_PCM", automatic ? "automatic" : "manual", "peak", peak, "expected", expected, "sampleRate", rate)
            precondition(abs(peak - expected) < 0.002, "The saved track selection must filter PCM before reopening the chooser")
        }
        try check(0.6)
        try execute("stop")
        let promoted = try snapshot()
        precondition(promoted.transport.exclusivePlaybackRegionId == incoming && !promoted.transport.subPlay.playing)
        try audio.update(promoted, revision: 1)
        try check(0.5)
    }
    print("SUBPLAY_PERSISTED_SELECTION_MANUAL_AUTOMATIC_AND_PROMOTED_PCM_OK")
}
try MainActor.assumeIsolated { try run() }
