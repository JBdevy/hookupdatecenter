import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)

@MainActor func run() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-group-copy-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 30))!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: 0.125, count: Int(pcm.frameLength)) }
    do { let file = try AVAudioFile(forWriting: directory.appendingPathComponent("tone.wav"), settings: format.settings); try file.write(from: pcm) }
    for explicitPatch in [false, true] {
        var project = Project.empty(name: "Group member copy")
        var parent = Track(id: UUID(), name: "Group", role: .other); parent.volume = 0.5
        var original = Track(id: UUID(), name: "Original", role: .keys)
        original.parentTrackID = parent.id
        if explicitPatch { original.outputs = [.masterGroup] }
        original.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 30, audioFile: AudioFile(path: "tone.wav"))]
        project.songs[0].tracks = [parent, original]
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let audio = StemAudioPlayback(engine: engine, realtime: false)
        audio.open(directory: directory)
        defer { audio.prepareForClosing() }
        var state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
            position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
        var revision: UInt64 = 1
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func check(_ expected: Float, _ label: String, update: Bool = true) throws {
            state.transport.position = Double(engine.manualRenderingSampleTime) / rate
            if update { revision += 1; try audio.update(state, revision: revision) }
            var peak: Float = 0
            for block in 0..<48 {
                let rendered = try engine.renderOffline(512, to: buffer); precondition(rendered == .success)
                if block >= 40 { for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(buffer.floatChannelData![0][frame])) } }
            }
            print("GROUP_COPY", explicitPatch, label, "peak", peak, "expected", expected)
            precondition(abs(peak - expected) < 0.001, "Duplicated group member lost its group output: \(label)")
        }
        try check(0.0625, "original")
        var copy = original; copy.id = UUID(); copy.name = "Copy"
        copy.clips = original.clips.map { item in var copied = item; copied.id = UUID(); return copied }
        state.project.songs[0].tracks.append(copy)
        try check(0.125, "original and copied member")
        state.project.songs[0].tracks[1].mute = true
        try check(0.0625, "copied member only")
        audio.previewPatches(copy.id, patches: [.master])
        try check(0.125, "copied member direct Master", update: false)
        audio.previewPatches(copy.id, patches: [.masterGroup])
        try check(0.0625, "copied member returns to group", update: false)
        audio.previewVolume(parent.id, gain: 0.25)
        try check(0.03125, "copy follows group fader", update: false)
        audio.previewMute(parent.id, muted: true)
        try check(0, "copy follows group mute", update: false)
        // New nested groups and their first children are attached in the same
        // project edit. Undo/redo must reuse their routes without leaving a
        // silent branch or creating a second send to the hardware master.
        state.project.songs[0].tracks[2].mute = true
        var nested = Track(id: UUID(), name: "Nested group", role: .other)
        nested.parentTrackID = parent.id; nested.volume = 0.25
        var nestedCopy = copy; nestedCopy.id = UUID(); nestedCopy.parentTrackID = nested.id
        nestedCopy.clips = copy.clips.map { item in var copied = item; copied.id = UUID(); return copied }
        state.project.songs[0].tracks += [nested, nestedCopy]
        try check(0.015625, "first copied member in a new nested group")
        let saved = state.project
        state.project.songs[0].tracks.removeLast(2)
        try check(0, "undo removes the nested group")
        state.project = saved
        try check(0.015625, "redo restores the nested group and copied member")
    }
    print("DUPLICATED_GROUP_MEMBER_LIVE_GRAPH_MASTER_GROUP_FADER_MUTE_AND_PATCH_RETURN_OK")
}
Task { @MainActor in do { try run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()
