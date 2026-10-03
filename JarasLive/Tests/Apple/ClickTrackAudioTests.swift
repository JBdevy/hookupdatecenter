import AVFoundation
import Foundation

let asset = URL(fileURLWithPath: CommandLine.arguments[1])
for rate in [44100.0, 48000.0] {
    let sound = try ClickAudioSample.load(sampleRate: rate, url: asset)
    precondition(sound.count > Int(rate * 0.1) * 4 && sound.count < Int(rate * 1.6) * 4)
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let bus = AVAudioMixerNode(); engine.attach(bus)
    let generators = (0..<2).map { _ in JarasMetronomeGenerator(format: format) }
    for (index, generator) in generators.enumerated() {
        engine.attach(generator.node)
        engine.connect(generator.node, to: bus, fromBus: 0, toBus: AVAudioNodeBus(index), format: format)
        generator.setClickSections([["start": 0.25, "end": 1.9, "origin": 0.25, "bpm": 120, "beats": 4, "unit": 4]], sound: sound)
    }
    engine.connect(bus, to: engine.mainMixerNode, format: format)
    engine.prepare(); try engine.start()
    defer { engine.stop() }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func capture(seconds: Double) throws -> [Float] {
        var samples: [Float] = []
        while samples.count < Int(seconds * rate) {
            let count = AVAudioFrameCount(min(512, Int(seconds * rate) - samples.count))
            let status = try engine.renderOffline(count, to: buffer)
            precondition(status == .success)
            samples += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }
    func start(_ generator: JarasMetronomeGenerator, position: Double = 0) {
        generator.configurePosition(position, hostTime: mach_absolute_time(), running: true, loopStart: 0, loopEnd: 0, sampleTime: Double(engine.manualRenderingSampleTime))
    }
    func stop(_ generator: JarasMetronomeGenerator) {
        generator.configurePosition(0, hostTime: mach_absolute_time(), running: false, loopStart: 0, loopEnd: 0, sampleTime: Double(engine.manualRenderingSampleTime))
    }
    start(generators[0])
    let normal = try capture(seconds: 2.1)
    let peak = normal.map { abs($0) }.max()!
    precondition(peak > 0.1, "Bundled MP3 must reach the output")
    precondition(normal[0..<Int(rate * 0.25)].allSatisfy { $0 == 0 })
    precondition(normal[Int(rate * 1.9)...].allSatisfy { $0 == 0 }, "Item edge truncates the one-shot")
    stop(generators[0]); _ = try capture(seconds: 0.02)
    bus.outputVolume = 0.5
    start(generators[1]) // the second head plays independently
    let half = try capture(seconds: 2.1)
    precondition(abs(half.map { abs($0) }.max()! / peak - 0.5) < 0.002, "Track fader controls Sub Play")
    stop(generators[1]); _ = try capture(seconds: 0.02)
    bus.outputVolume = 0
    start(generators[0]); start(generators[1])
    let muted = try capture(seconds: 1)
    precondition(muted.allSatisfy { abs($0) < 0.000001 }, "Track mute gates both heads")
    stop(generators[0]); stop(generators[1]); bus.outputVolume = 1
    _ = try capture(seconds: 0.02)
    let stopped = try capture(seconds: 0.6)
    precondition(stopped.allSatisfy { $0 == 0 })
    print("CLICK_BUNDLED_AUDIO_OK \(Int(rate)) Hz: MP3, item edges, two heads, track gain/mute, stop")
}
