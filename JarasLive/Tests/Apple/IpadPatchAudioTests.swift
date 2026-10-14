import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

@MainActor func verifyPatchChannels() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 6)!
    let hardware = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-patch-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(rate * 15))!
    source.frameLength = source.frameCapacity
    source.floatChannelData![0].update(repeating: 0.08, count: Int(source.frameLength))
    source.floatChannelData![1].update(repeating: 0.12, count: Int(source.frameLength))
    do {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("stereo.wav"), settings: stereo.settings)
        try file.write(from: source)
    }
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: hardware, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: true)
    audio.open(directory: directory)
    defer { audio.prepareForClosing() }
    var project = Project.empty(name: "iPad shared Patch PCM")
    let folder = Track(id: UUID(), name: "Folder", role: .other, volume: 0.5)
    var child = Track(id: UUID(), name: "Stereo source", role: .other)
    child.parentTrackID = folder.id
    child.outputs = [.masterGroup]
    child.clips = [AudioClip(id: UUID(), name: "Stereo", startTime: 0, duration: 15, audioFile: AudioFile(path: "stereo.wav"))]
    project.songs[0].tracks = [folder, child]
    try project.validate()
    let snapshot = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
        position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(snapshot, revision: 1)
    let buffer = AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: 512)!
    let nodes = engine.attachedNodes
    func check(_ expected: [Float], _ label: String) throws {
        var actual = Array(repeating: Float(0), count: 6)
        for block in 0..<24 {
            let status = try engine.renderOffline(512, to: buffer)
            precondition(status == .success, "\(label): render")
            if block >= 16 {
                for channel in 0..<6 { for frame in 0..<Int(buffer.frameLength) {
                    actual[channel] = max(actual[channel], abs(buffer.floatChannelData![channel][frame]))
                } }
            }
        }
        precondition(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.00003 }, "\(label): \(actual), expected \(expected)")
        precondition(engine.isRunning && engine.attachedNodes == nodes, "Patch must preserve prepared nodes")
        print("PATCH_PCM_OK rate=\(rate) \(label): \(actual)")
    }
    try check([0.04, 0.06, 0, 0, 0, 0], "group to Master 1+2")
    audio.previewPatches(child.id, patches: [OutputPatch(firstChannel: 3, channelCount: 2)])
    try check([0, 0, 0.08, 0.12, 0, 0], "direct 3+4 preserves L/R without leaking to Master")
    audio.previewPatches(child.id, patches: [OutputPatch(firstChannel: 4, channelCount: 1)])
    try check([0, 0, 0, 0.1, 0, 0], "mono downmix to channel 4 only")
    audio.previewPatches(nil, patches: [OutputPatch(firstChannel: 5, channelCount: 2)])
    audio.previewPatches(child.id, patches: [.master])
    try check([0, 0, 0, 0, 0.08, 0.12], "Master output 5+6")
    audio.previewPatches(child.id, patches: [.masterGroup, OutputPatch(firstChannel: 3, channelCount: 2)])
    try check([0, 0, 0.08, 0.12, 0.04, 0.06], "parallel group and direct outputs")
    audio.previewMute(nil, muted: true)
    try check([0, 0, 0.08, 0.12, 0, 0], "Master mute leaves direct output independent")
    audio.previewPatches(child.id, patches: [.none])
    try check([0, 0, 0, 0, 0, 0], "None silences all destinations")
    audio.previewMute(nil, muted: false)
    audio.previewPatches(child.id, patches: [.masterGroup])
    try check([0, 0, 0, 0, 0.04, 0.06], "group route restores during playback")
    var restored = snapshot
    restored.transport.playing = false
    audio.prepareAfterDeviceChange = { try audio.update(restored, revision: 2) }
    for (nextRate, channels) in [(48000.0, 2), (44100.0, 6)] {
        audio.suspendDeviceSession()
        precondition(!engine.isRunning, "Suspend must release hardware before route rebuilding")
        engine.disableManualRenderingMode()
        let nextLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        let nextFormat = AVAudioFormat(standardFormatWithSampleRate: nextRate, channelLayout: nextLayout)
        try engine.enableManualRenderingMode(.offline, format: nextFormat, maximumFrameCount: 512)
        try audio.startDeviceSession()
        let connected = engine.mainMixerNode.outputFormat(forBus: 0)
        precondition(connected.sampleRate == nextRate && connected.channelCount == channels,
                     "Session restart must reconnect the changed hardware format")
        let nextBuffer = AVAudioPCMBuffer(pcmFormat: nextFormat, frameCapacity: 512)!
        for _ in 0..<8 {
            let status = try engine.renderOffline(512, to: nextBuffer)
            precondition(status == .success)
            for channel in 0..<channels { for frame in 0..<Int(nextBuffer.frameLength) {
                precondition(abs(nextBuffer.floatChannelData![channel][frame]) < 0.000001, "Route recovery must not resume the stopped transport")
            } }
        }
        print("IPAD_ROUTE_SUSPEND_SESSION_RECONNECT_FORMAT_AND_IDLE_SILENCE_OK rate=\(nextRate) channels=\(channels)")
    }
    // Host-time scheduling requires an actual realtime render clock. Pull PCM
    // after device format changes with the engine's sample-clock renderer.
    let offlineEngine = AVAudioEngine()
    try offlineEngine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 512)
    let offline = StemAudioPlayback(engine: offlineEngine, realtime: false)
    offline.open(directory: directory)
    defer { offline.prepareForClosing() }
    var playback = snapshot
    try offline.update(playback, revision: 1)
    for (nextRate, channels) in [(48000.0, 6), (44100.0, 2)] {
        offline.suspendDeviceSession()
        offlineEngine.disableManualRenderingMode()
        let nextLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        let nextFormat = AVAudioFormat(standardFormatWithSampleRate: nextRate, channelLayout: nextLayout)
        try offlineEngine.enableManualRenderingMode(.offline, format: nextFormat, maximumFrameCount: 512)
        playback.transport.playing = false
        offline.prepareAfterDeviceChange = { try offline.update(playback, revision: 2) }
        try offline.reconfigureDevice()
        playback.transport.playing = true
        try offline.update(playback, revision: 2)
        let nextBuffer = AVAudioPCMBuffer(pcmFormat: nextFormat, frameCapacity: 512)!
        var levels = Array(repeating: Float(0), count: channels)
        for block in 0..<24 {
            let status = try offlineEngine.renderOffline(512, to: nextBuffer)
            precondition(status == .success)
            if block >= 16 { for channel in 0..<channels { for frame in 0..<Int(nextBuffer.frameLength) {
                levels[channel] = max(levels[channel], abs(nextBuffer.floatChannelData![channel][frame]))
            } } }
        }
        let expected: [Float] = [0.04, 0.06] + Array(repeating: 0, count: channels - 2)
        precondition(zip(levels, expected).allSatisfy { abs($0 - $1) < 0.00003 }, "Play after route rebuild: \(levels)")
        print("IPAD_REBUILT_ROUTE_NEXT_PLAY_SAMPLE_CLOCK_PCM_OK rate=\(nextRate) channels=\(channels)")
    }
}
try MainActor.assumeIsolated { try verifyPatchChannels() }
