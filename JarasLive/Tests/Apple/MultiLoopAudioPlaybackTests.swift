import AVFoundation
import Foundation
import Darwin

setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

@MainActor func verifyLoopAudio() async throws {
    let rate = 48000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-loop-audio-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 8)!
    pcm.frameLength = pcm.frameCapacity
    for c in 0..<2 { pcm.floatChannelData![c].initialize(repeating: 0.01, count: Int(pcm.frameLength)) }
    try AVAudioFile(forWriting: folder.appendingPathComponent("tone.wav"), settings: format.settings).write(from: pcm)
    var project = Project.empty(name: "Armed loop audio")
    let group = Track(id: UUID(), name: "Group", role: .other)
    var child = Track(id: UUID(), name: "Member", role: .other)
    var normal = Track(id: UUID(), name: "Normal", role: .other)
    child.parentTrackID = group.id; child.outputs = [.masterGroup]
    for track in [0, 1] {
        let clip = AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 8, audioFile: AudioFile(path: "tone.wav"))
        if track == 0 { child.clips = [clip] } else { normal.clips = [clip] }
    }
    var first = TimelineMarker(id: UUID(), name: "Start", position: 2, color: 0)
    var last = TimelineMarker(id: UUID(), name: "End", position: 4, color: 0)
    first.section = true; first.loopSection = true; last.section = true; last.loopSection = true
    var loop = MultiLoop(name: "Passage", marker1: first.id, marker2: last.id)
    loop.fadeSeconds = 1
    var groupRule = MultiLoopTrack(id: group.id, gain: 0.25); groupRule.autoFader = true
    var normalRule = MultiLoopTrack(id: normal.id, gain: 0.5); normalRule.autoFader = true
    loop.tracks = [groupRule, normalRule]
    var region = Part(id: UUID(), name: "Song", startTime: 0, endTime: 8)
    region.multiLoops = [loop]
    project.songs[0].duration = 8
    project.songs[0].tracks = [group, child, normal]
    project.songs[0].markers = [first, last]; project.songs[0].parts = [region]
    for realtime in [false, true] {
        let core = JarasCoreBridge()
        try core.load(projectData: JSONEncoder().encode(project))
        try core.execute(command: "play", target: nil, value: 0)
        let engine = AVAudioEngine()
        if !realtime { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512) }
        let audio = StemAudioPlayback(engine: engine, realtime: realtime, auxiliarySelectedHardware: realtime)
        if realtime { audio.setLicenseAllowed(false); try audio.startDeviceSession() }
        audio.open(directory: folder)
        defer { audio.prepareForClosing() }
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var checked = 0
        let began = ProcessInfo.processInfo.systemUptime
        var previous = began
        for block in 0..<(realtime ? 175 : 310) {
            if realtime {
                try await Task.sleep(nanoseconds: 20_000_000)
                let now = ProcessInfo.processInfo.systemUptime
                core.advance(now - previous); previous = now
            }
            let state = try JSONDecoder().decode(ShowSnapshot.self, from: core.snapshot())
            try audio.update(state, revision: 1)
            if !realtime {
                let renderStatus = try engine.renderOffline(512, to: out)
                precondition(renderStatus == .success)
            } else { precondition(engine.mainMixerNode.outputVolume == 0) }
            if realtime ? state.transport.position > 2.6 && state.transport.position < 3.6 : block > 220 {
                precondition(state.transport.multiLoop?.amount == 1)
                let value = realtime ? Float(audio.masterMeter.level) : out.floatChannelData![0][511]
                if abs(value - 0.0075) >= (realtime ? 0.0003 : 0.00002) {
                    print("MULTILOOP_AUDIO_FAILURE", "realtime", realtime, "block", block, "actual", value, "expected", 0.0075)
                    exit(1)
                }
                checked += 1
            }
            if !realtime { core.advance(512 / rate) }
        }
        precondition(checked > (realtime ? 10 : 80))
        print("MULTILOOP_CORE_TO_AUDIO_GROUP_AND_NORMAL_AUTOFADER_OK realtime=\(realtime)")
    }
}
Task { @MainActor in
    do { try await verifyLoopAudio(); exit(0) }
    catch { print("MULTILOOP_AUDIO_ERROR", error); exit(1) }
}
dispatchMain()
