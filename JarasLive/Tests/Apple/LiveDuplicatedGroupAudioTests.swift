import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)
// A real Core Audio graph reproduces newly attached mixer fanouts; offline
// rendering alone cannot cover a copied track becoming silent on hardware.
// Disable the final physical output before starting. No microphone is opened.
@MainActor func run() async throws {
    UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-track-graph-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 60))!
    pcm.frameLength = pcm.frameCapacity
    for ch in 0..<2 { pcm.floatChannelData![ch].update(repeating: 0.125, count: Int(pcm.frameLength)) }
    try AVAudioFile(forWriting: folder.appendingPathComponent("tone.wav"), settings: format.settings).write(from: pcm)
    let engine = AVAudioEngine()
    let audio = StemAudioPlayback(engine: engine, auxiliarySelectedHardware: true)
    audio.setLicenseAllowed(false)
    try audio.startDeviceSession(); audio.open(directory: folder)
    defer { audio.prepareForClosing() }
    let emptyGraphNodeCount = engine.attachedNodes.count
    var project = Project.empty(name: "Isolated group copy")
    var group = Track(id: UUID(), name: "Group", role: .other); group.volume = 0.5
    var original = Track(id: UUID(), name: "Original", role: .keys); original.parentTrackID = group.id
    original.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 60, audioFile: AudioFile(path: "tone.wav"))]
    let benchmark = CommandLine.arguments.contains("--benchmark")
    project.songs[0].tracks = [group, original] + (0..<(benchmark ? 143 : 6)).map { Track(id: UUID(), name: "Empty \($0)", role: .other) }
    project.songs[0].duration = 60
    var state = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    var revision: UInt64 = 1
    try audio.update(state, revision: revision)
    try await Task.sleep(nanoseconds: 300_000_000)
    for trial in 0..<(benchmark ? 3 : 1) {
        state.project.songs[0].tracks += (0..<8).map { Track(id: UUID(), name: "Copy \($0)", role: .other) }
        revision += 1
        let start = ProcessInfo.processInfo.systemUptime
        try audio.update(state, revision: revision)
        print("REAL_TRACK_GRAPH_INSERT_8", trial, "ms", (ProcessInfo.processInfo.systemUptime-start)*1000)
        precondition(engine.isRunning && engine.mainMixerNode.outputVolume == 0)
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    func copyTrack() -> Track {
        var copied = original; copied.id = UUID()
        copied.clips = original.clips.map { c in var v=c;v.id=UUID();return v }
        return copied
    }
    let stoppedCopy=copyTrack(); state.project.songs[0].tracks.append(stoppedCopy);revision += 1
    try audio.update(state, revision: revision)
    try await Task.sleep(nanoseconds: 200_000_000)
    state.transport.playing = true
    let start = ProcessInfo.processInfo.systemUptime
    func peak(_ label: String, expected: Double) async throws {
        var result=0.0
        for n in 0..<35 {
            state.transport.position=ProcessInfo.processInfo.systemUptime-start
            try audio.update(state, revision: revision)
            try await Task.sleep(nanoseconds: 30_000_000)
            if n>20 { result=max(result,audio.masterMeter.level) }
        }
        print("REAL_GROUP_COPY", label, "peak",result,"expected",expected)
        precondition(abs(result-expected)<0.005, "New group member did not reach its group output")
        precondition(engine.isRunning && engine.mainMixerNode.outputVolume == 0)
    }
    try await peak("copy while stopped", expected: 0.125)
    let playingCopy=copyTrack();state.project.songs[0].tracks.append(playingCopy);revision += 1
    try await peak("copy while playing", expected: 0.1875)
    audio.previewVolume(group.id, gain: 0.25)
    try await peak("group volume", expected: 0.09375)
    audio.previewMute(group.id, muted: true)
    try await peak("group mute", expected: 0)
    // Cross the sixteen-input boundary while audio is already playing.
    // Removing/restoring those same track identities must leave one route per
    // child even when the previous group sends have vacant mixer inputs.
    state.project.songs[0].tracks[0].volume = 0.125
    state.project.songs[0].tracks[0].mute = false
    state.project.songs[0].tracks += (0..<15).map { _ in copyTrack() }
    revision += 1
    try await peak("eighteen group members", expected: 18 * 0.125 * 0.125)
    let restored = state.project
    state.project.songs[0].tracks.removeAll { $0.parentTrackID == group.id && $0.id != original.id }
    revision += 1
    try await peak("remove group copies", expected: 0.125 * 0.125)
    state.project = restored; revision += 1
    try await peak("restore group copies", expected: 18 * 0.125 * 0.125)
    audio.previewPatches(original.id, patches: [.master])
    try await peak("original direct Master", expected: 0.125 + 17 * 0.125 * 0.125)
    audio.previewPatches(original.id, patches: [.masterGroup])
    try await peak("original returns to group", expected: 18 * 0.125 * 0.125)
    audio.open(directory: folder)
    precondition(engine.attachedNodes.count == emptyGraphNodeCount,
                 "Reopening a project must detach every intermediate track mixer")
    print("REAL_TRACK_GRAPH_DUPLICATED_GROUP_OK")
}
Task { @MainActor in do {try await run();exit(0)} catch {print("FAILED",error);exit(1)} }
dispatchMain()
