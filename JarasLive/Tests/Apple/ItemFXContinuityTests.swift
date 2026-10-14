import Foundation
import AVFoundation

setbuf(stdout, nil)
// The test must not mix a metronome enabled by another command-line fixture.
// A volatile argument domain changes only this process, never saved preferences.
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

@MainActor func runItemFXContinuityTests() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 8))!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 { for frame in 0..<Int(pcm.frameLength) {
        pcm.floatChannelData![channel][frame] = Float(frame % 4096 + 1) / 65536
    } }
    do {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("continuity.wav"), settings: format.settings)
        try file.write(from: pcm)
    }
    for looping in [false, true] {
        var project = Project.empty(name: "Item FX continuity")
        var track = Track(id: UUID(), name: "Track", role: .other)
        var clip = AudioClip(id: UUID(), name: "Source", startTime: 0, duration: 6,
                            audioFile: AudioFile(path: "continuity.wav"))
        if looping { clip.loopStart = 0; clip.loopLength = 2048 / rate }
        track.clips = [clip]; project.songs[0].tracks = [track]
        var timing = project.songs[0].projectTime
        timing.timebase = .free; project.songs[0].timeSettings = timing
        let state = ShowSnapshot(project: project, transport: TransportState(playing: true,
            songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        // Use the application's realtime/free-grid path, with direct item
        // players. Manual rendering does not open or change an audio device.
        let audio = StemAudioPlayback(engine: engine, realtime: true)
        audio.open(directory: directory)
        var errors: [Error] = []
        audio.onError = { errors.append($0) }
        defer { audio.prepareForClosing() }
        try audio.update(state, revision: 1)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var lastSample: Float = 0
        for _ in 0..<32 {
            let status = try engine.renderOffline(512, to: output)
            precondition(status == .success)
            lastSample = output.floatChannelData![0][511]
        }
        precondition(lastSample > 0, "The fixture must already be sounding before changing FX")
        let period = looping ? 2048 : 4096
        func verifyPCM(_ label: String) throws {
            for block in 0..<8 {
                let expectedIndex = Int((lastSample * 65536).rounded()) % period
                let status = try engine.renderOffline(512, to: output)
                precondition(status == .success)
                for channel in 0..<2 { for frame in 0..<512 {
                    let expected = Float((expectedIndex + frame) % period + 1) / 65536
                    precondition(abs(output.floatChannelData![channel][frame] - expected) < 0.00001,
                        "\(label), loop=\(looping), block=\(block), sample=\(frame): source position/PCM changed")
                } }
                lastSample = output.floatChannelData![0][511]
            }
        }
        try verifyPCM("Before editing")
        var dryDelay = NativeFXSettings()
        dryDelay.inserted = ["Delay"]; dryDelay.delayEnabled = true; dryDelay.delayMix = 0
        let first = NativeFXInstance(kind: "Delay", settings: dryDelay)
        let second = NativeFXInstance(kind: "Delay", settings: dryDelay)
        var settings = NativeFXSettings()
        for iteration in 0..<4 {
            settings.instances = [first, second]; settings.inserted = [first.effectKey, second.effectKey]
            try settings.validateForClip()
            audio.previewClipFX(clip.id, settings: settings)
            try verifyPCM("Insert \(iteration)")
            settings.inserted = [second.effectKey, first.effectKey]
            try settings.validateForClip()
            audio.previewClipFX(clip.id, settings: settings)
            try verifyPCM("Reorder \(iteration)")
            settings.instances = [first]; settings.inserted = [first.effectKey]
            try settings.validateForClip()
            audio.previewClipFX(clip.id, settings: settings)
            try verifyPCM("Remove one \(iteration)")
            settings.instances = nil; settings.inserted = []
            try settings.validateForClip()
            audio.previewClipFX(clip.id, settings: settings)
            try verifyPCM("Remove all \(iteration)")
        }
        // Track and Master inserts also reconnect a live upstream player.
        // Exercise the realtime path with a single sample-clocked source.
        for target in [Optional(track.id), nil] {
            settings.instances = [first, second]; settings.inserted = [first.effectKey, second.effectKey]
            audio.previewFX(target, settings: settings)
            try verifyPCM(target == nil ? "Insert Master FX" : "Insert track FX")
            settings.instances = [first]; settings.inserted = [first.effectKey]
            audio.previewFX(target, settings: settings)
            try verifyPCM(target == nil ? "Remove one Master FX" : "Remove one track FX")
            settings.instances = nil; settings.inserted = []
            audio.previewFX(target, settings: settings)
            try verifyPCM(target == nil ? "Remove all Master FX" : "Remove all track FX")
        }
        precondition(errors.isEmpty, "Unexpected audio error: \(errors)")
        print("ITEM_FX_STEM_PCM_CONTINUITY_OK rate=\(rate) loop=\(looping)")
    }
    // Editing queued and already sounding items must preserve both the onset
    // and buffered time-pitch samples. Compare with an untouched graph rather
    // than assuming the stretcher's preroll or latency.
    for usesStretch in [false, true] { for editBlock in [0, 12, 96, 128] {
        var project = Project.empty(name: "Future item FX continuity")
        var track = Track(id: UUID(), name: "Track", role: .other)
        let clip = AudioClip(id: UUID(), name: "Future source", startTime: 0.7, duration: 1.2,
                             audioFile: AudioFile(path: "continuity.wav"))
        track.clips = [clip]; project.songs[0].tracks = [track]
        var timing = project.songs[0].projectTime
        timing.timebase = .free; project.songs[0].timeSettings = timing
        let state = ShowSnapshot(project: project, transport: TransportState(playing: true,
            songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
        func makePlayback() throws -> (AVAudioEngine, StemAudioPlayback) {
            let engine = AVAudioEngine()
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
            let audio = StemAudioPlayback(engine: engine, realtime: !usesStretch)
            audio.open(directory: directory)
            try audio.update(state, revision: 1)
            return (engine, audio)
        }
        let (reference, referenceAudio) = try makePlayback()
        let (changing, changingAudio) = try makePlayback()
        defer { referenceAudio.prepareForClosing(); changingAudio.prepareForClosing() }
        let before = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        let after = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var dryDelay = NativeFXSettings()
        dryDelay.inserted = ["Delay"]; dryDelay.delayEnabled = true; dryDelay.delayMix = 0
        let instance = NativeFXInstance(kind: "Delay", settings: dryDelay)
        var settings = NativeFXSettings()
        settings.instances = [instance]; settings.inserted = [instance.effectKey]
        try settings.validateForClip()
        var maximumError: Float = 0
        var firstReference: Int?, firstChanging: Int?
        for block in 0..<200 {
            if block == editBlock { changingAudio.previewClipFX(clip.id, settings: settings) }
            let referenceStatus = try reference.renderOffline(512, to: before)
            let changingStatus = try changing.renderOffline(512, to: after)
            precondition(referenceStatus == .success && changingStatus == .success)
            for frame in 0..<512 {
                if firstReference == nil && abs(before.floatChannelData![0][frame]) > 0.01 { firstReference = block * 512 + frame }
                if firstChanging == nil && abs(after.floatChannelData![0][frame]) > 0.01 { firstChanging = block * 512 + frame }
                for channel in 0..<2 {
                    maximumError = max(maximumError, abs(before.floatChannelData![channel][frame] - after.floatChannelData![channel][frame]))
                }
            }
        }
        precondition(firstReference != nil && firstReference == firstChanging && maximumError < 0.00001,
            "Item PCM changed: stretch=\(usesStretch), editBlock=\(editBlock), error=\(maximumError), reference=\(String(describing: firstReference)), changing=\(String(describing: firstChanging))")
        print("ITEM_FX_QUEUED_AND_RUNNING_PCM_CONTINUITY_OK rate=\(rate) stretch=\(usesStretch) editBlock=\(editBlock)")
    } }
}

try MainActor.assumeIsolated { try runItemFXContinuityTests() }
