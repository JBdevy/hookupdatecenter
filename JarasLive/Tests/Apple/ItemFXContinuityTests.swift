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
    // EQ gain before compression and after compression must sound different.
    // This verifies actual DSP order, not merely the list shown in the manager.
    func level(_ settings: NativeFXSettings) throws -> Double {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let chain = NativeEffectsChain(reorderable: false)
        engine.attach(player)
        chain.attach(to: engine, input: player, format: format, destinations: [AVAudioConnectionPoint(node: engine.mainMixerNode, bus: 0)])
        chain.apply(settings)
        let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        tone.frameLength = tone.frameCapacity
        for channel in 0..<2 { for frame in 0..<Int(tone.frameLength) {
            tone.floatChannelData![channel][frame] = 0.2 * Float(sin(Double(frame) * 2 * .pi * 440 / rate))
        } }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        player.scheduleBuffer(tone, at: nil, options: .loops, completionHandler: nil)
        try engine.start(); player.play()
        defer { engine.stop(); chain.detach(from: engine) }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var sum = 0.0, count = 0
        for block in 0..<80 {
            let status = try engine.renderOffline(512, to: buffer)
            precondition(status == .success)
            if block > 40 { for frame in 0..<512 {
                let value = Double(buffer.floatChannelData![0][frame]); sum += value * value; count += 1
            } }
        }
        return sqrt(sum / Double(count))
    }
    var orderedFX = NativeFXSettings(); orderedFX.appendNative("EQ"); orderedFX.appendNative("Compressor")
    for index in orderedFX.bands.indices { orderedFX.bands[index].enabled = false }
    orderedFX.bands[1].enabled = true; orderedFX.bands[1].frequency = 440; orderedFX.bands[1].gain = 12
    orderedFX.threshold = -30; orderedFX.ratio = 20; orderedFX.attack = 0.001
    let compressedBoost = try level(orderedFX)
    precondition(orderedFX.reorderClipEffect("EQ", before: nil) != nil)
    let boostedCompression = try level(orderedFX)
    precondition(boostedCompression > compressedBoost * 2, "Moved EQ must process after the compressor")
    print("ITEM_FX_REORDER_CHANGES_ACTUAL_DSP_ORDER_OK rate=\(rate)")
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
                        "\(label), loop=\(looping), block=\(block), sample=\(frame): expected=\(expected) actual=\(output.floatChannelData![channel][frame])")
                } }
                lastSample = output.floatChannelData![0][511]
            }
        }
        try verifyPCM("Before editing")
        var legacy = NativeFXSettings()
        legacy.appendNative("EQ"); legacy.appendNative("Delay"); legacy.delayMix = 0
        for index in legacy.bands.indices { legacy.bands[index].type = "bell"; legacy.bands[index].gain = 0 }
        audio.previewClipFX(clip.id, settings: legacy)
        try verifyPCM("Legacy fixed native chain")
        precondition(legacy.reorderClipEffect("EQ", before: nil) != nil)
        audio.previewClipFX(clip.id, settings: legacy)
        try verifyPCM("Promote and reorder legacy native stages")
        audio.previewClipFX(clip.id, settings: NativeFXSettings())
        try verifyPCM("Remove promoted native stages")
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
