import AVFoundation
import Foundation

setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

@MainActor func testWaveLFOPlayback() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
    input.frameLength = input.frameCapacity
    for channel in 0..<2 {
        for n in 0..<Int(input.frameLength) { input.floatChannelData![channel][n] = channel == 0 ? 0.2 : -0.1 }
    }
    try AVAudioFile(forWriting: directory.appendingPathComponent("tone.wav"), settings: format.settings).write(from: input)
    var parent = NativeFXSettings(); parent.appendNative(NativeFXSettings.waveLFOName)
    parent.waveLFOParameters.attack = 0.2; parent.waveLFOParameters.hold = 0.1; parent.waveLFOParameters.decay = 0.1
    parent.waveLFOParameters.sustain = 0.5; parent.waveLFOParameters.release = 0.2
    var child = parent; child.waveLFOParameters.sustain = 0.75

    enum LiveEdit { case none, track, item }
    func play(trackFX: NativeFXSettings?, itemFX: NativeFXSettings?, edit: LiveEdit = .none,
              start: Double = 0) throws -> [[Float]] {
        var project = Project.empty(name: "Wave LFO Play")
        var track = Track(id: UUID(), name: "Wave", role: .other)
        var item = AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 1, audioFile: AudioFile(path: "tone.wav"))
        track.fx = trackFX; item.fx = itemFX; track.clips = [item]; project.songs[0].tracks = [track]
        var timing = project.songs[0].projectTime; timing.timebase = .free; project.songs[0].timeSettings = timing
        let state = ShowSnapshot(project: project, transport: TransportState(playing: true,
            songId: project.songs[0].id, position: start, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let audio = StemAudioPlayback(engine: engine, realtime: true)
        defer { audio.prepareForClosing() }
        audio.open(directory: directory)
        try audio.update(state, revision: 1, sampledAt: ProcessInfo.processInfo.systemUptime)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var output = [[Float](), [Float]()], changed = false
        while output[0].count < Int(rate * (1 - start)) {
            if edit != .none && !changed && output[0].count >= Int(rate * 0.52) {
                var revised = parent; revised.waveLFOParameters.sustain = 0.125
                if edit == .track { audio.previewFX(track.id, settings: revised) }
                else { audio.previewClipFX(item.id, settings: revised) }
                changed = true
            }
            let result = try engine.renderOffline(512, to: buffer); precondition(result == .success)
            for channel in 0..<2 {
                output[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel],
                                                                      count: Int(buffer.frameLength)))
            }
        }
        return output
    }
    let dry = try play(trackFX: nil, itemFX: nil)
    for (name, local, edit) in [("track", false, false), ("item", true, false), ("live", false, true)] {
        let wet = try play(trackFX: parent, itemFX: local ? child : nil, edit: edit ? .track : .none)
        let sustain = local ? 0.75 : 0.5, late = edit ? 0.125 : sustain
        for (seconds, expected) in [(0.1, 0.5), (0.25, 1), (0.35, (1 + sustain) / 2), (0.45, sustain), (0.70, late), (0.90, late / 2)] {
            let index = Int(seconds * rate)
            for channel in 0..<2 {
                let reference = Double(dry[channel][index])
                let measured = Double(wet[channel][index]) / reference
                print("PLAY_WAVE", name, "rate", rate, "time", seconds, "channel", channel, "ratio", measured, "expected", expected)
                precondition(abs(reference) > 0.05 && abs(measured - expected) < 0.025, "Playback envelope mismatch")
            }
        }
    }
    for target in [LiveEdit.track, .item] {
        let inserted = try play(trackFX: nil, itemFX: nil, edit: target)
        for channel in 0..<2 {
            for (seconds, expected) in [(0.45, 1.0), (0.70, 0.125), (0.90, 0.0625)] {
                let i = Int(seconds * rate), ratio = Double(inserted[channel][i] / dry[channel][i])
                precondition(abs(ratio - expected) < 0.025, "Inserting the envelope during Play must change this item")
            }
        }
    }
    let sought = try play(trackFX: parent, itemFX: nil, start: 0.4)
    for channel in 0..<2 {
        for (seconds, expected) in [(0.10, 0.5), (0.5, 0.25)] {
            let i = Int(seconds * rate), ratio = Double(sought[channel][i] / dry[channel][i])
            precondition(abs(ratio - expected) < 0.025, "Seek must enter the existing item envelope at its actual position")
        }
    }
    print("WAVE_PLAY_LIVE_INSERT_TRACK_ITEM_AND_SEEK_OK", rate)
}
try MainActor.assumeIsolated { try testWaveLFOPlayback() }
